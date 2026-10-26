import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence

private func olDate(_ value: String = "2026-10-16T14:00:00.0004Z") throws -> Date { try LedgerCSV.timestamp(value) }
private func olInput(id: UUID = UUID(), capital: OptionLabCapital? = nil, fee: String = "0.65") throws -> OptionLabInput {
    let time = try olDate(), source = OptionLabSource(origin: .synthetic, reference: "synthetic/storage-fixture", enteredAt: time)
    let expiry = MarketDate(year: 2026, month: 11, day: 20)
    return try .init(id: id, createdAt: time, asOf: time, strategy: .cashSecuredPut,
        shortLeg: .init(contractID: "SYN-20261120-P-100", symbol: "SYN", right: .put, strike: Money("100"), quantity: 1,
            expirationDate: expiry, bid: Money("2"), ask: Money("4"), bidSize: 10, askSize: 10, tick: Money("0.01"),
            quotedAt: time, receivedAt: time, source: source), longLeg: nil,
        underlying: .init(symbol: "SYN", bid: Money("99"), ask: Money("101"), quotedAt: time, receivedAt: time, source: source),
        capital: capital ?? .init(origin: .synthetic, reference: "synthetic balances", asOf: time,
            cashBeforeTrade: Money("20000"), committedCash: Money("0"), availableShares: Money("100"), committedShares: Money("0")),
        policy: .init(lambda: Money("0.25"), openingFeePerContract: Money(fee), ticketFee: Money("0"), terminalFeeTotal: Money("0")),
        expiry: .init(date: expiry, settlementAt: olDate("2026-11-20T21:00:00Z"), source: source),
        scenarioPrices: [Money("0"), Money("100"), Money("200")])
}
private func olDatabase() throws -> DatabaseStore { try .init(path: ":memory:", purpose: .optionsLab) }
private func olPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("option-lab-" + UUID().uuidString + ".sqlite") }
private func olRows(_ db: DatabaseStore) throws -> [[Row]] {
    try db.read { connection in try ["option_lab_metadata", "option_lab_catalog", "option_lab_documents"].map {
        try Row.fetchAll(connection, sql: "SELECT * FROM " + $0 + " ORDER BY 1")
    } }
}
private func olEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
}
private let olSecurity = LedgerSecurity(id: "SYN", symbol: "SYN")
private func olEvent(_ id: String, seconds: Double, payload: LedgerPayload) throws -> LedgerEvent {
    .init(id: id, accountID: "A", effectiveAt: try olDate("2026-10-15T14:00:00Z").addingTimeInterval(seconds),
        source: .init(sourceSystem: "synthetic-option-basis", externalTransactionID: id, evidence: "synthetic " + id), payload: payload)
}
private func olSnapshot(_ events: [LedgerEvent], revision: UUID = UUID()) throws -> LedgerSnapshot {
    let accounts = [LedgerAccount(id: "A", name: "Synthetic account")]
    return .init(revision: revision, accounts: accounts, events: events, state: try LedgerEngine.replay(accounts: accounts, events: events))
}
private func olContract(_ right: LedgerOptionRight, strike: String = "100") throws -> LedgerOptionVersion {
    let suffix = right == .call ? "C" : "P"
    return try .init(occSymbol: "SYN   261120" + suffix + "00100000", versionID: "synthetic-standard-v1",
        effectiveFrom: olDate("2026-01-01T00:00:00Z"), quoteMultiplier: Money("100"), exerciseConsideration: Money(strike).multiplied(by: "100"),
        deliverables: [.init(security: olSecurity, quantity: Money("100"), basisWeight: Money("1"))], deliverableCash: Money("0"),
        tradingEndsAt: olDate("2026-11-20T21:00:00Z"), exerciseDeadline: olDate("2026-11-20T22:00:00Z"),
        settlementAt: olDate("2026-11-23T14:00:00Z"), memoReferences: ["synthetic specification"])
}
private func olTrade(_ id: String, seconds: Double, instrument: LedgerInstrument, side: LedgerSide, quantity: String, price: String) throws -> LedgerEvent {
    let strategy: LedgerStrategy?
    if case .option = instrument {
        strategy = .init(id: "synthetic-premium", purpose: .premiumIncome,
            successDefinition: "synthetic terminal premium fixture")
    } else { strategy = nil }
    return try olEvent(id, seconds: seconds, payload: .trade(.init(instrument: instrument, side: side, effect: .open,
        quantity: Money(quantity), unitPrice: Money(price), fee: Money("0"), openingLotID: id + "-lot", strategy: strategy)))
}
private func olFundedEvents() throws -> [LedgerEvent] {
    try [olEvent("cash", seconds: 0, payload: .cash(.init(kind: .deposit, amount: Money("50000")))),
         olTrade("stock", seconds: 1, instrument: .equity(olSecurity), side: .buy, quantity: "200", price: "100")]
}

@Suite("Isolated option laboratory snapshots and ledger capital basis")
struct OptionLabStorageTests {
    @Test func purposeMarkerKeepsLedgerResearchAndOptionsSchemasSeparate() async throws {
        let path = olPath(); defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .optionsLab)
        #expect(try database.migrationVersions() == ["foundation.v1", "options-lab.v1", "options-lab.v2", "options-lab.v3", "options-lab.v4", "options-lab.v5"])
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'p1_%' OR name LIKE 'ledger_%' OR name LIKE 'performance_%'") } == 0)
        for purpose in [DatabasePurpose.business, .offlineIssuerResearch, .secResearch, .portfolioLedger] {
            #expect(throws: MigrationError.incompatiblePurpose) { try DatabaseStore(path: path.path, purpose: purpose) }
            let foreign = try DatabaseStore(path: ":memory:", purpose: purpose)
            #expect(throws: OptionLabStoreError.incompatiblePurpose) { try OptionLabStore(database: foreign) }
            #expect(try foreign.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'option_lab_%'") } == 0)
        }
        let store = try OptionLabStore(database: database)
        #expect(try await store.summaries().isEmpty)
    }

    @Test func freezeReopenRecomputesExactInputAndBindingsBeforeReturningValues() async throws {
        let path = olPath(); defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .optionsLab), store = try OptionLabStore(database: database)
        let input = try olInput(), revision = try await store.revision()
        let saved = try await store.save(id: input.id, input: input, expectedRevision: revision)
        #expect(saved.replayMatched); #expect(saved.report == (try OptionLabEngine.calculate(input)))
        let reopened = try OptionLabStore(path: path.path), result = try await reopened.open(id: input.id)
        #expect(result == saved); #expect(result.report.input == input)
        #expect(result.report.input.asOf.timeIntervalSinceReferenceDate.bitPattern == input.asOf.timeIntervalSinceReferenceDate.bitPattern)
        #expect(result.report.modelReference == saved.report.modelReference)
        #expect(result.report.parameterReference == saved.report.parameterReference)
        let summaries = try await reopened.summaries()
        #expect(summaries.count == 1); #expect(summaries[0].origin == .synthetic)
        #expect(summaries[0].underlyingSymbol == "SYN")
    }

    @Test func enteredPricesSurviveDatabaseReopenAndArchiveRestoreWithoutInventedQuotes() async throws {
        let path = olPath(), restoredPath = olPath()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: restoredPath)
        }
        let database = try DatabaseStore(path: path.path, purpose: .optionsLab)
        let store = try OptionLabStore(database: database), base = try olInput()
        let input = try OptionLabInput(id: base.id, createdAt: base.createdAt, asOf: base.asOf,
            strategy: base.strategy,
            shortLeg: .init(contractID: base.shortLeg.contractID, symbol: base.shortLeg.symbol,
                right: base.shortLeg.right, strike: base.shortLeg.strike, quantity: base.shortLeg.quantity,
                expirationDate: base.shortLeg.expirationDate, bid: nil, ask: nil, bidSize: nil, askSize: nil,
                tick: nil, quotedAt: base.asOf, receivedAt: base.asOf, source: base.shortLeg.source,
                enteredPrice: Money("3.25")), longLeg: nil,
            underlying: .init(symbol: base.underlying.symbol, bid: nil, ask: nil,
                quotedAt: base.asOf, receivedAt: base.asOf, source: base.underlying.source,
                enteredPrice: Money("101.25")), capital: base.capital, policy: base.policy,
            expiry: base.expiry, scenarioPrices: base.scenarioPrices)
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let reopened = try OptionLabStore(path: path.path)
        #expect(try await reopened.open(id: input.id) == saved)
        #expect(saved.report.schemaVersion == OptionLabEngine.enteredSchemaVersion)
        #expect(saved.report.modelReference == (try OptionLabEngine.enteredDefinitions().1.reference))

        let original = try database.read(OptionLabArchiveState.capture)
        let archive = try await store.makeArchiveStore().exportArchive()
        let target = try DatabaseStore(path: restoredPath.path, purpose: .optionsLab)
        let transfer = try OptionLabArchiveStore(database: target)
        let plan = try await transfer.prepareRestore(archive, mode: .replace, expectedRevision: transfer.status().revision)
        #expect(try await transfer.commit(.init(plan: plan)).counts.experiments == 1)
        #expect(try target.read(OptionLabArchiveState.capture).tables == original.tables)
        let restored = try OptionLabStore(path: restoredPath.path)
        let opened = try await restored.open(id: input.id)
        #expect(opened == saved && opened.replayMatched)
        #expect(opened.report.input == input)
        #expect(opened.report.input.shortLeg.enteredPrice == (try Money("3.25")))
        #expect(opened.report.input.underlying.enteredPrice == (try Money("101.25")))
        #expect(opened.report.input.shortLeg.bid == nil && opened.report.input.shortLeg.ask == nil)
        #expect(opened.report.input.shortLeg.bidSize == nil && opened.report.input.shortLeg.askSize == nil)
        #expect(opened.report.input.shortLeg.tick == nil)
        #expect(opened.report.input.underlying.bid == nil && opened.report.input.underlying.ask == nil)
        #expect(opened.report.selectedOutcome.pricing == .entered)
        #expect(try OptionLabEngine.replay(opened.report) == saved.report)
    }

    @Test func identicalFreezeIsIdempotentButDifferentInputCannotOverwriteAnID() async throws {
        let database = try olDatabase(), store = try OptionLabStore(database: database), input = try olInput()
        let first = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let rows = try olRows(database), current = try await store.revision()
        #expect(try await store.save(id: input.id, input: input, expectedRevision: current) == first)
        #expect(try olRows(database) == rows)
        let changed = try olInput(id: input.id, fee: "1")
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(id: input.id, input: changed, expectedRevision: current) }
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(id: UUID(), input: input, expectedRevision: current) }
        #expect(try olRows(database) == rows)
    }

    @Test func contractOnlySnapshotPreservesUnknownCapitalAcrossReopenAndArchiveRestore() async throws {
        let path = olPath(), restoredPath = olPath()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: restoredPath)
        }
        let database = try DatabaseStore(path: path.path, purpose: .optionsLab)
        let store = try OptionLabStore(database: database), base = try olInput()
        let source = OptionLabSource(origin: .manual, reference: "MANUAL parameter recording; no market quote timestamps", enteredAt: base.asOf)
        let input = try OptionLabInput(id: base.id, createdAt: base.createdAt, asOf: base.asOf,
            strategy: base.strategy,
            shortLeg: .init(contractID: "LOCAL-SHORT", symbol: "BASIC", right: .put, strike: Money("100"),
                quantity: 1, expirationDate: base.expiry.date, quotedAt: base.asOf, receivedAt: base.asOf,
                source: source, enteredPrice: Money("3.25")), longLeg: nil,
            underlying: .init(symbol: "BASIC", quotedAt: base.asOf, receivedAt: base.asOf,
                source: source, enteredPrice: Money("101.25")), capital: nil, policy: base.policy,
            expiry: .init(date: base.expiry.date, settlementAt: base.expiry.settlementAt, source: source),
            scenarioPrices: [Money("100"), Money("101.25")], entryMode: .contractParameters)
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let reopened = try OptionLabStore(path: path.path), opened = try await reopened.open(id: input.id)
        #expect(opened == saved && opened.replayMatched)
        #expect(opened.report.input.capital == nil && opened.ledgerBasis == nil)
        #expect(opened.report.input.entryMode == .contractParameters)
        #expect(opened.report.selectedOutcome.funding == .notAssessed)
        #expect(opened.report.selectedOutcome.availableCashAfterFees == nil)
        #expect(opened.report.pricing == nil && opened.report.risk == nil && opened.report.scenario == nil)
        #expect(opened.report.modelReference == (try OptionLabEngine.contractDefinitions().1.reference))
        #expect(try await reopened.summaries().first?.origin == .manual)

        let original = try database.read(OptionLabArchiveState.capture)
        let archive = try await store.makeArchiveStore().exportArchive()
        let target = try DatabaseStore(path: restoredPath.path, purpose: .optionsLab)
        let transfer = try OptionLabArchiveStore(database: target)
        let plan = try await transfer.prepareRestore(archive, mode: .replace, expectedRevision: transfer.status().revision)
        #expect(try await transfer.commit(.init(plan: plan)).counts.experiments == 1)
        #expect(try target.read(OptionLabArchiveState.capture).tables == original.tables)
        let restored = try OptionLabStore(path: restoredPath.path), restoredValue = try await restored.open(id: input.id)
        #expect(restoredValue == saved && restoredValue.report.input.capital == nil)
        #expect(restoredValue.report.selectedOutcome.funding == .notAssessed)
        #expect(try OptionLabEngine.replay(restoredValue.report) == saved.report)
    }

    @Test func failedTransactionRollsBackAndSameFrozenInputCanRetry() async throws {
        let database = try olDatabase(), store = try OptionLabStore(database: database), input = try olInput()
        let original = try olRows(database), revision = try await store.revision()
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) { try await store.save(id: input.id, input: input, expectedRevision: revision) }
        #expect(try olRows(database) == original)
        #expect(try await store.save(id: input.id, input: input, expectedRevision: revision).replayMatched)
    }

    @Test func separateConnectionCannotAcquireANewerRevisionForAnOldSave() async throws {
        let path = olPath(); defer { try? FileManager.default.removeItem(at: path) }
        let first = try OptionLabStore(path: path.path), second = try OptionLabStore(path: path.path)
        let baseline = try await second.revision(), a = try olInput(), b = try olInput()
        _ = try await first.save(id: a.id, input: a, expectedRevision: baseline)
        await #expect(throws: OptionLabStoreError.staleRevision) { try await second.save(id: b.id, input: b, expectedRevision: baseline) }
        #expect(try await second.summaries().map(\.id) == [a.id])
    }

    @Test func damagedBodyMetadataOrBindingsFailClosedOnOpenAndDuplicateSave() async throws {
        for sql in [
            "UPDATE option_lab_documents SET input_json = x'00'",
            "UPDATE option_lab_documents SET report_json = x'00'",
            "UPDATE option_lab_catalog SET model_reference_hash = '" + String(repeating: "0", count: 64) + "'",
            "UPDATE option_lab_catalog SET parameter_reference_hash = '" + String(repeating: "0", count: 64) + "'",
            "UPDATE option_lab_catalog SET summary_json = x'00'",
            "DELETE FROM option_lab_documents"
        ] {
            let database = try olDatabase(), store = try OptionLabStore(database: database), input = try olInput()
            _ = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
            let revision = try await store.revision()
            try database.transaction { try $0.execute(sql: sql) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.save(id: input.id, input: input, expectedRevision: revision) }
        }
    }

    @Test func rehashedButChangedCachedValueIsRejectedByRecalculation() async throws {
        let database = try olDatabase(), store = try OptionLabStore(database: database), input = try olInput()
        _ = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        try database.transaction { db in
            let bytes = try #require(try Data.fetchOne(db, sql: "SELECT report_json FROM option_lab_documents"))
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var outcome = try #require(object["conservative"] as? [String: Any]); outcome["maxProfit"] = "9999"; object["conservative"] = outcome
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), hash = LedgerCSV.hash(changed)
            let summaryBytes = try #require(try Data.fetchOne(db, sql: "SELECT summary_json FROM option_lab_catalog"))
            var metadata = try #require(JSONSerialization.jsonObject(with: summaryBytes) as? [String: Any]); metadata["reportHash"] = hash
            let changedMetadata = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
            try db.execute(sql: "UPDATE option_lab_documents SET report_json = ?", arguments: [changed])
            try db.execute(sql: "UPDATE option_lab_catalog SET report_hash = ?, summary_json = ?, summary_hash = ?", arguments: [hash, changedMetadata, LedgerCSV.hash(changedMetadata)])
        }
        // The metadata list is not a calculation; opening must still replay.
        #expect(try await store.summaries().count == 1)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
    }

    @Test func ledgerBasisReservesAllShortObligationsWithoutSpreadNettingOrWritingLedger() async throws {
        var events = try olFundedEvents()
        events.append(try olTrade("short-put", seconds: 2, instrument: .option(olContract(.put)), side: .sell, quantity: "1", price: "2"))
        events.append(try olTrade("short-call", seconds: 3, instrument: .option(olContract(.call)), side: .sell, quantity: "1", price: "2"))
        let snapshot = try olSnapshot(events), basis = try OptionLabLedgerBridge.inspect(snapshot: snapshot, accountID: "A",
            underlying: olSecurity, asOf: olDate(), completenessEvidence: "synthetic complete local history; no external obligations")
        #expect(basis.cashBeforeTrade == (try Money("30400")))
        #expect(basis.committedCash == (try Money("10000")))
        #expect(basis.heldShares == (try Money("200"))); #expect(basis.committedShares == (try Money("100")))
        #expect(basis.capital?.availableShares == (try Money("200")))
        #expect(basis.capital?.ledgerRevision == snapshot.revision); #expect(basis.capital?.accountID == "A")
        #expect(try OptionLabLedgerBridge.replay(basis) == basis)
        #expect(try LedgerEngine.replay(accounts: snapshot.accounts, events: events) == snapshot.state)
    }

    @Test func missingHistoryIncompleteEvidenceOrUncoveredCallsNeverBecomeAvailableCollateral() throws {
        let empty = try OptionLabLedgerBridge.inspect(snapshot: olSnapshot([]), accountID: "A", underlying: olSecurity,
            asOf: olDate(), completenessEvidence: "explicit but empty")
        #expect(empty.capital == nil); #expect(empty.gaps.contains(.noAccountHistory))
        let unconfirmed = try OptionLabLedgerBridge.inspect(snapshot: olSnapshot(olFundedEvents()), accountID: "A", underlying: olSecurity,
            asOf: olDate(), completenessEvidence: " ")
        #expect(unconfirmed.capital == nil); #expect(unconfirmed.gaps == [.completenessNotConfirmed])
        let uncoveredEvents = try [olEvent("cash", seconds: 0, payload: .cash(.init(kind: .deposit, amount: Money("100")))),
            olTrade("uncovered", seconds: 1, instrument: .option(olContract(.call)), side: .sell, quantity: "1", price: "2")]
        let uncovered = try OptionLabLedgerBridge.inspect(snapshot: olSnapshot(uncoveredEvents), accountID: "A", underlying: olSecurity,
            asOf: olDate(), completenessEvidence: "complete")
        #expect(uncovered.capital == nil); #expect(uncovered.gaps.contains(.uncoveredExistingCall))
    }

    @Test func ledgerBasisRejectsInventedStateAndFutureEvents() throws {
        let correct = try olSnapshot(olFundedEvents())
        var badState = correct.state; badState.cashByAccount["A"] = try Money("999999")
        let bad = LedgerSnapshot(revision: correct.revision, accounts: correct.accounts, events: correct.events, state: badState)
        #expect(throws: OptionLabLedgerBasisError.inconsistentSnapshot) { try OptionLabLedgerBridge.inspect(snapshot: bad,
            accountID: "A", underlying: olSecurity, asOf: olDate(), completenessEvidence: "complete") }
        #expect(throws: OptionLabLedgerBasisError.invalidAsOf) { try OptionLabLedgerBridge.inspect(snapshot: correct,
            accountID: "A", underlying: olSecurity, asOf: olDate("2026-10-14T00:00:00Z"), completenessEvidence: "complete") }
    }

    @Test func ledgerProofMustMatchCapitalAndSurviveIndependentReopen() async throws {
        let path = olPath(); defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .optionsLab), store = try OptionLabStore(database: database)
        let basis = try OptionLabLedgerBridge.inspect(snapshot: olSnapshot(olFundedEvents()), accountID: "A", underlying: olSecurity,
            asOf: olDate(), completenessEvidence: "synthetic full history")
        let capital = try #require(basis.capital), input = try olInput(capital: capital), baseline = try await store.revision()
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(id: input.id, input: input, expectedRevision: baseline) }
        let saved = try await store.save(id: input.id, input: input, ledgerBasis: basis, expectedRevision: baseline)
        let reopened = try OptionLabStore(path: path.path), opened = try await reopened.open(id: input.id)
        #expect(opened == saved); #expect(opened.ledgerBasis == basis)
        try database.transaction { try $0.execute(sql: "UPDATE option_lab_documents SET ledger_basis_json = x'00'") }
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await reopened.open(id: input.id) }
    }

    @Test func actualLedgerBridgeIsReadOnlyAndHistoricalBasisNeverAdoptsANewerLedgerRevision() async throws {
        let ledgerDB = try DatabaseStore(path: ":memory:", purpose: .portfolioLedger), ledger = try LedgerStore(database: ledgerDB)
        let empty = try await ledger.snapshot(), account = try await ledger.createAccount(.init(id: "A", name: "Synthetic account"), expectedRevision: empty.revision)
        let preview = try await ledger.previewManual(events: olFundedEvents(), expectedRevision: account.revision)
        let original = try await ledger.commit(planID: preview.id, expectedRevision: account.revision)
        let basis = try OptionLabLedgerBridge.inspect(snapshot: original, accountID: "A", underlying: olSecurity,
            asOf: olDate(), completenessEvidence: "synthetic complete account history")
        let capital = try #require(basis.capital), input = try olInput(capital: capital)
        let laboratory = try OptionLabStore(database: olDatabase())
        let saved = try await laboratory.save(id: input.id, input: input, ledgerBasis: basis, expectedRevision: laboratory.revision())
        #expect(try await ledger.snapshot() == original)
        let extra = try olEvent("later", seconds: 20, payload: .cash(.init(kind: .deposit, amount: Money("1"))))
        let change = try await ledger.previewManual(events: [extra], expectedRevision: original.revision)
        let changed = try await ledger.commit(planID: change.id, expectedRevision: original.revision)
        let opened = try await laboratory.open(id: saved.id)
        #expect(opened == saved); #expect(opened.ledgerBasis?.ledgerRevision == original.revision)
        #expect(changed.revision != original.revision)
        #expect(opened.report.input.capital?.cashBeforeTrade == (try Money("30000")))
        #expect(changed.state.cashByAccount["A"] == (try Money("30001")))
    }
}
