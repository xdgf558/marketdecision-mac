import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence

private func olaLab(_ database: DatabaseStore, id: UUID = UUID(), fee: String = "0.65") async throws -> SavedOptionLab {
    let store = try OptionLabStore(database: database), b = try OptionLabDemo.input()
    let input = try OptionLabInput(id: id, createdAt: b.createdAt, asOf: b.asOf, strategy: b.strategy, shortLeg: b.shortLeg,
        longLeg: b.longLeg, underlying: b.underlying, capital: b.capital,
        policy: .init(lambda: b.policy.lambda, openingFeePerContract: Money(fee), ticketFee: b.policy.ticketFee, terminalFeeTotal: b.policy.terminalFeeTotal),
        expiry: b.expiry, scenarioPrices: b.scenarioPrices)
    return try await store.save(id: input.id, input: input, expectedRevision: store.revision())
}
private func olaPlan(_ store: OptionLabArchiveStore, _ data: Data, _ mode: OptionLabRestoreMode = .replace) async throws -> OptionLabTransferPlan {
    try await store.prepareRestore(data, mode: mode, expectedRevision: store.status().revision)
}
private func olaRawRows(_ db: DatabaseStore) throws -> [[Row]] {
    try db.read { connection in
        try (OptionLabArchiveState.definitions.map(\.name) + ["option_lab_metadata"]).map { try Row.fetchAll(connection, sql: "SELECT * FROM " + $0 + " ORDER BY 1") }
    }
}

@Suite("Isolated options archive and exact transactional restore")
struct OptionLabArchiveTests {
    @Test func archivePreservesV1V2V3DailyAndHistoryBytesThenReopensAllReports() async throws {
        let source = try odsDB(), lab = try OptionLabStore(database: source), daily = try OptionDailyStore(database: source)
        var studies: [SavedOptionLab] = []
        for version in ["options-legacy-v1", "options-legacy-v2"] {
            let url = try #require(Bundle.module.url(forResource: version, withExtension: "json"))
            let bytes = try Data(contentsOf: url), old = try JSONDecoder().decode(OptionLabReport.self, from: bytes)
            let saved = try await lab.save(id: old.input.id, input: old.input, expectedRevision: lab.revision()); studies.append(saved)
            #expect(try source.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents WHERE snapshot_id=?", arguments: [old.input.id.uuidString]) } == bytes)
        }
        let b = try OptionLabDemo.input(), v3 = OptionLabInput(createdAt: b.createdAt, asOf: b.asOf, strategy: b.strategy,
            shortLeg: b.shortLeg, longLeg: b.longLeg, underlying: b.underlying, capital: b.capital, policy: b.policy, expiry: b.expiry,
            scenarioPrices: b.scenarioPrices, risk: .init(source: b.underlying.source))
        let savedV3 = try await lab.save(id: v3.id, input: v3, expectedRevision: lab.revision()); studies.append(savedV3)
        #expect(savedV3.report.schemaVersion == "option-lab-report.v3")
        let savedDaily = try await daily.saveDaily(odsInput(), expectedRevision: daily.revision())
        let savedHistory = try await daily.saveHistory(odsHistory(), expectedRevision: daily.revision())
        let original = try source.read(OptionLabArchiveState.capture), raw = try await lab.makeArchiveStore().exportArchive()
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let target = try DatabaseStore(path: path.path, purpose: .optionsLab), archive = try OptionLabArchiveStore(database: target)
        let plan = try await olaPlan(archive, raw), result = try await archive.commit(.init(plan: plan))
        #expect(result.revision != original.revision)
        #expect(result.counts.experiments == 3); #expect(result.counts.dailySummaries == 1); #expect(result.counts.historyReports == 1)
        #expect(try target.read(OptionLabArchiveState.capture).tables == original.tables)
        let reopened = try OptionLabStore(path: path.path), reopenedDaily = try OptionDailyStore(path: path.path)
        for study in studies { #expect(try await reopened.open(id: study.id) == study) }
        #expect(try await reopenedDaily.openDaily(id: savedDaily.id) == savedDaily)
        #expect(try await reopenedDaily.openHistory(id: savedHistory.id) == savedHistory)
    }
    @Test func mergeDisjointRecordsAndRepeatedImportNeverDuplicateOrRewriteBytes() async throws {
        let a = try odsDB(), b = try odsDB(), left = try OptionLabArchiveStore(database: a), right = try OptionLabArchiveStore(database: b)
        _ = try await olaLab(a); _ = try await olaLab(b)
        let d = try OptionDailyStore(database: b); _ = try await d.saveDaily(odsInput(), expectedRevision: d.revision())
        let raw = try await right.exportArchive(), plan = try await olaPlan(left, raw, .merge)
        #expect(plan.result.experiments == 2); _ = try await left.commit(.init(plan: plan))
        let first = try a.read(OptionLabArchiveState.capture).tables
        _ = try await left.commit(.init(plan: olaPlan(left, raw, .merge)))
        #expect(try a.read(OptionLabArchiveState.capture).tables == first)
        #expect(try await left.status().counts.dailySummaries == 1)
    }
    @Test func conflictingExperimentOrDailyIdentityRejectsWholeMergeWithoutOverwriting() async throws {
        for dailyConflict in [false, true] {
            let a = try odsDB(), b = try odsDB(), id = UUID()
            if dailyConflict {
                let x = try OptionDailyStore(database: a), y = try OptionDailyStore(database: b)
                _ = try await x.saveDaily(odsInput(id: id), expectedRevision: x.revision())
                _ = try await y.saveDaily(odsInput(id: id, volatility: 0.35), expectedRevision: y.revision())
            } else { _ = try await olaLab(a, id: id); _ = try await olaLab(b, id: id, fee: "1") }
            let target = try OptionLabArchiveStore(database: a), source = try OptionLabArchiveStore(database: b), bytes = try await source.exportArchive()
            let before = try a.read(OptionLabArchiveState.capture)
            await #expect(throws: OptionLabArchiveError.identityConflict) { try await olaPlan(target, bytes, .merge) }
            #expect(try a.read(OptionLabArchiveState.capture) == before)
        }
    }
    @Test func replaceRepairsCorruptExistingBodiesButMergeStillRequiresTheirIntegrity() async throws {
        let source = try odsDB(); _ = try await olaLab(source)
        let bytes = try await OptionLabArchiveStore(database: source).exportArchive()
        for sql in ["UPDATE option_lab_documents SET input_json=x'00'", "UPDATE option_daily_documents SET report_json=x'00'", "UPDATE option_daily_contracts SET summary_json=x'00'", "UPDATE option_history_documents SET input_json=x'00'"] {
            let target = try odsDB(); _ = try await olaLab(target)
            let daily = try OptionDailyStore(database: target)
            _ = try await daily.saveDaily(odsInput(), expectedRevision: daily.revision()); _ = try await daily.saveHistory(odsHistory(), expectedRevision: daily.revision())
            try target.transaction { try $0.execute(sql: sql) }
            let store = try OptionLabArchiveStore(database: target)
            await #expect(throws: (any Error).self) { try await olaPlan(store, bytes, .merge) }
            let plan = try await olaPlan(store, bytes), result = try await store.commit(.init(plan: plan))
            #expect(result.counts.experiments == 1); #expect(result.counts.dailySummaries == 0); #expect(result.counts.historyReports == 0)
            #expect(try target.read(OptionLabArchiveState.capture).tables == source.read(OptionLabArchiveState.capture).tables)
        }
    }
    @Test func failedReplacementRollsBackCorruptBytesAndSameApprovalRetries() async throws {
        let source = try odsDB(); _ = try await olaLab(source)
        let bytes = try await OptionLabArchiveStore(database: source).exportArchive()
        let target = try odsDB(); _ = try await olaLab(target)
        try target.transaction { try $0.execute(sql: "UPDATE option_lab_documents SET input_json=x'00'") }
        let store = try OptionLabArchiveStore(database: target), before = try olaRawRows(target), plan = try await olaPlan(store, bytes)
        await store.injectFailureOnNextCommit()
        await #expect(throws: OptionLabArchiveError.injectedFailure) { try await store.commit(.init(plan: plan)) }
        #expect(try olaRawRows(target) == before)
        let result = try await store.commit(.init(plan: plan)); #expect(result.counts.experiments == 1)
        #expect(try target.read(OptionLabArchiveState.capture).tables == source.read(OptionLabArchiveState.capture).tables)
    }
    @Test func exactApprovalCancelAndStalePlanCannotAuthorizeDifferentOrLaterState() async throws {
        let db = try odsDB(), store = try OptionLabArchiveStore(database: db)
        _ = try await olaLab(db)
        let before = try db.read(OptionLabArchiveState.capture), plan = try await store.prepareClear(expectedRevision: store.status().revision)
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await store.commit(.init(planID: plan.id, digest: String(repeating: "0", count: 64), revision: plan.baseRevision)) }
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await store.commit(.init(planID: plan.id, digest: plan.digest, revision: UUID())) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        await store.cancel(plan.id)
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await store.commit(.init(plan: plan)) }
        let stale = try await store.prepareClear(expectedRevision: store.status().revision)
        _ = try await olaLab(db)
        let afterWrite = try db.read(OptionLabArchiveState.capture)
        await #expect(throws: OptionLabArchiveError.stalePlan) { try await store.commit(.init(plan: stale)) }
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await store.commit(.init(plan: stale)) }
        #expect(try db.read(OptionLabArchiveState.capture) == afterWrite)
    }
    @Test func actualSQLiteFailureAfterWritesRollsBackAndAllowsRetry() async throws {
        let source = try odsDB(); _ = try await olaLab(source)
        let target = try odsDB(); _ = try await olaLab(target)
        let store = try OptionLabArchiveStore(database: target), bytes = try await OptionLabArchiveStore(database: source).exportArchive()
        let plan = try await olaPlan(store, bytes), before = try olaRawRows(target)
        try target.transaction { try $0.execute(sql: "CREATE TRIGGER archive_reject BEFORE UPDATE ON option_lab_metadata BEGIN SELECT RAISE(ABORT,'synthetic failure'); END") }
        await #expect(throws: (any Error).self) { try await store.commit(.init(plan: plan)) }
        #expect(try olaRawRows(target) == before)
        try target.transaction { try $0.execute(sql: "DROP TRIGGER archive_reject") }
        #expect(try await store.commit(.init(plan: plan)).counts.experiments == 1)
    }
    @Test func mergePreparedBeforeUndeclaredBodyDamageRefusesCommitAndLeavesDamageUntouched() async throws {
        let a = try odsDB(), b = try odsDB(); _ = try await olaLab(a); _ = try await olaLab(b)
        let store = try OptionLabArchiveStore(database: a), raw = try await OptionLabArchiveStore(database: b).exportArchive()
        let plan = try await olaPlan(store, raw, .merge)
        try a.transaction { try $0.execute(sql: "UPDATE option_lab_documents SET input_json=x'00'") }
        let damaged = try olaRawRows(a)
        await #expect(throws: OptionLabArchiveError.corruptedStorage) { try await store.commit(.init(plan: plan)) }
        #expect(try olaRawRows(a) == damaged)
    }
    @Test func wrongPurposeReadableExportsAndMalformedArchivesCannotPrepare() async throws {
        let db = try odsDB(), store = try OptionLabArchiveStore(database: db), bytes = try await store.exportArchive()
        let before = try db.read(OptionLabArchiveState.capture)
        for raw in [Data("# Option report\nNot a backup".utf8), Data("id,IV30\n1,0.25\n".utf8), Data(bytes.dropLast()), bytes + Data([0])] {
            await #expect(throws: (any Error).self) { try await olaPlan(store, raw) }
        }
        var files = try ResearchZIP.decode(bytes)
        let manifestBytes = try #require(files["manifest.json"])
        var manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any]); manifest["purpose"] = "MDL1"
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
        await #expect(throws: OptionLabArchiveError.unsupportedFormat) { try await olaPlan(store, ResearchZIP.encode(files)) }
        let ledger = try LedgerArchiveStore(database: DatabaseStore(path: ":memory:", purpose: .portfolioLedger))
        await #expect(throws: (any Error).self) { try await olaPlan(store, ledger.exportArchive()) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        for purpose in [DatabasePurpose.business, .offlineIssuerResearch, .secResearch, .portfolioLedger] {
            let foreign = try DatabaseStore(path: ":memory:", purpose: purpose)
            #expect(throws: OptionLabArchiveError.incompatiblePurpose) { try OptionLabArchiveStore(database: foreign) }
            #expect(throws: OptionLabStoreError.incompatiblePurpose) { try OptionDailyStore(database: foreign) }
        }
    }
    @Test func restartedStoreHasNoApprovalAndBadRevisionCannotBeRepairedByGuessing() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let db = try DatabaseStore(path: path.path, purpose: .optionsLab), store = try OptionLabArchiveStore(database: db)
        let raw = try await store.exportArchive(), plan = try await store.prepareClear(expectedRevision: store.status().revision)
        let reopened = try OptionLabArchiveStore(path: path.path)
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await reopened.commit(.init(plan: plan)) }
        try db.transaction { try $0.execute(sql: "UPDATE option_lab_metadata SET revision='invalid'") }
        await #expect(throws: OptionLabArchiveError.corruptedStorage) { try await reopened.prepareRestore(raw, mode: .replace, expectedRevision: plan.baseRevision) }
    }
    @Test func cancelBeforeCommitDoesNotMutateOrConsumeApproval() async throws {
        let db = try odsDB(), store = try OptionLabArchiveStore(database: db)
        _ = try await olaLab(db)
        let plan = try await store.prepareClear(expectedRevision: store.status().revision), before = try olaRawRows(db)
        let gate = OptionArchiveGate()
        let task = Task { await gate.wait(); return try await store.commit(.init(plan: plan)) }
        await gate.arrived(); task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try olaRawRows(db) == before)
        #expect(try await store.commit(.init(plan: plan)).counts.experiments == 0)
    }
    @Test func schemaDriftCannotBeSilentlyDeletedByClearOrReplace() async throws {
        let db = try odsDB(), store = try OptionLabArchiveStore(database: db), raw = try await store.exportArchive(), revision = try await store.status().revision
        try db.transaction { try $0.execute(sql: "CREATE TABLE future_options_protected(id TEXT)"); try $0.execute(sql: "INSERT INTO future_options_protected VALUES ('retain')") }
        await #expect(throws: OptionLabArchiveError.unsupportedFormat) { try await store.prepareClear(expectedRevision: revision) }
        await #expect(throws: OptionLabArchiveError.unsupportedFormat) { try await store.prepareRestore(raw, mode: .replace, expectedRevision: revision) }
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT id FROM future_options_protected") } == "retain")
    }
    @Test func archiveDeclaresEmbeddedReadOnlyLedgerHistoryWithoutOpeningLedgerDatabase() async throws {
        let b = try OptionLabDemo.input(), account = LedgerAccount(id: "A", name: "Synthetic basis")
        let event = LedgerEvent(id: "cash", accountID: "A", effectiveAt: b.asOf.addingTimeInterval(-1),
            source: .init(sourceSystem: "synthetic", externalTransactionID: "cash", evidence: "Synthetic cash"),
            payload: .cash(.init(kind: .deposit, amount: try Money("20000"))))
        let state = try LedgerEngine.replay(accounts: [account], events: [event])
        let snapshot = LedgerSnapshot(revision: UUID(), accounts: [account], events: [event], state: state)
        let basis = try OptionLabLedgerBridge.inspect(snapshot: snapshot, accountID: "A", underlying: .init(id: "DEMO", symbol: "DEMO"),
            asOf: b.asOf, completenessEvidence: "Synthetic complete account history")
        let capital = try #require(basis.capital)
        let input = OptionLabInput(createdAt: b.createdAt, asOf: b.asOf, strategy: b.strategy, shortLeg: b.shortLeg, longLeg: b.longLeg,
            underlying: b.underlying, capital: capital, policy: b.policy, expiry: b.expiry, scenarioPrices: b.scenarioPrices)
        let source = try odsDB(), lab = try OptionLabStore(database: source)
        let saved = try await lab.save(id: input.id, input: input, ledgerBasis: basis, expectedRevision: lab.revision())
        let archive = try await lab.makeArchiveStore(), raw = try await archive.exportArchive(), files = try ResearchZIP.decode(raw)
        let manifest = try JSONDecoder().decode(OptionLabArchiveCodec.Manifest.self, from: #require(files["manifest.json"]))
        #expect(manifest.embeddedLedgerBases == 1); #expect(!manifest.encrypted)
        #expect(manifest.ledgerBasisScope.contains("account and event evidence"))
        let target = try odsDB(), restore = try OptionLabArchiveStore(database: target), plan = try await olaPlan(restore, raw)
        #expect(plan.result.embeddedLedgerBases == 1); #expect(plan.details.contains { $0.contains("只读账户") })
        _ = try await restore.commit(.init(plan: plan))
        #expect(try await OptionLabStore(database: target).open(id: saved.id) == saved)
        #expect(try target.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'ledger_%'") } == 0)
    }
}

private actor OptionArchiveGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; arrival?.resume(); arrival = nil; await withCheckedContinuation { waiting = $0 } }
    func arrived() async { if entered { return }; await withCheckedContinuation { arrival = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}
