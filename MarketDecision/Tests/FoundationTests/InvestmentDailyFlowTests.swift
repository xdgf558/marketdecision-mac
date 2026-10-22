import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
@testable import Persistence
@testable import AppComposition

/// Hand-authored test records exercise ordinary, explicitly user-confirmed input.
/// They are not provider observations or real-account acceptance evidence, and
/// never derive from or relabel PortfolioSyntheticExample's synthetic sources.
@Suite("Investment daily flow with real SQLite replay") @MainActor
struct InvestmentDailyFlowTests {
    private let accountID = "manual-test-account"
    private let firstDays = ["2026-01-05", "2026-01-06"]

    private func date(_ text: String) throws -> Date { try LedgerCSV.timestamp(text) }
    private func proof(_ id: String, at: String = "2026-01-01T00:00:00.0004Z") throws -> PerformanceEvidence {
        .init(id: "manual-test/" + id, source: "Explicit local test record", kind: .userConfirmed,
              availableAt: try date(at), reference: "test-only/" + id,
              rawDocument: Data(("Hand-authored local test record: " + id).utf8))
    }
    private func draftProof(_ id: String, at: String) throws -> PortfolioEvidenceDraft {
        let original = try proof(id, at: at)
        var value = PortfolioEvidenceDraft()
        value.id = original.id; value.source = original.source; value.reference = original.reference
        value.availableAt = at; value.text = String(decoding: original.rawDocument, as: UTF8.self)
        value.kind = original.kind
        return value
    }
    private func buy(_ symbol: String, day: String, quantity: String, price: String) throws -> LedgerEvent {
        let id = "manual-buy-" + symbol
        return try .init(id: id, accountID: accountID, effectiveAt: date(day + "T15:00:00Z"),
            source: .init(sourceSystem: "local-test-entry", externalTransactionID: id,
                          evidence: "Explicit test-only trade entry " + symbol),
            payload: .trade(.init(instrument: .equity(.init(id: symbol, symbol: symbol)), side: .buy, effect: .open,
                quantity: Money(quantity), unitPrice: Money(price), fee: Money("0"), openingLotID: "lot-" + symbol)))
    }
    private func request() throws -> PerformanceRequest {
        let prices = ["10", "12"]
        let days = try firstDays.enumerated().map { index, day in
            let close = try date(day + "T21:00:00.0004Z")
            let session = try PerformanceSession(id: "session/AAA/" + day, instrumentID: "equity:AAA",
                opensAt: date(day + "T14:30:00Z"), closesAt: close, evidence: proof("session/AAA/" + day))
            let quote = try PerformancePrice(id: "price/AAA/" + day, instrumentID: session.instrumentID,
                sessionID: session.id, quoteAt: close, bid: Money(prices[index]), ask: Money(prices[index]),
                evidence: proof("price/AAA/" + day, at: day + "T21:00:00.0004Z"))
            return PerformanceDayInput(day: day, valuationAt: close, sessions: [session], prices: [quote])
        }
        return try .init(accountID: accountID, calculatedAt: date("2026-01-07T12:00:00.0006Z"),
            calendar: .init(tradingDays: firstDays, evidence: proof("calendar/v1")), days: days,
            externalFlowsComplete: true, flowCompletenessEvidence: proof("flows/v1"))
    }
    private func seed(_ database: DatabaseStore) async throws -> (LedgerWorkspaceModel, PerformanceStore, PortfolioWorkspaceModel) {
        let ledger = try LedgerStore(database: database), entry = LedgerWorkspaceModel(storage: ledger)
        await entry.load()
        await entry.createAccount(.init(id: accountID, name: "Local test-only manual account"))
        #expect(!entry.hasError)
        let deposit = try LedgerEvent(id: "manual-deposit", accountID: accountID,
            effectiveAt: date("2026-01-02T14:00:00Z"),
            source: .init(sourceSystem: "local-test-entry", externalTransactionID: "manual-deposit",
                          evidence: "Explicit test-only funding receipt"),
            payload: .cash(.init(kind: .deposit, amount: Money("1000"))))
        await entry.prepareManual(events: [deposit, try buy("AAA", day: firstDays[0], quantity: "2", price: "10")])
        let preview = try #require(entry.preview)
        #expect(await entry.confirm(id: preview.id, expectedRevision: preview.targetRevision))
        let store = try await ledger.makePerformanceStore(), model = PortfolioWorkspaceModel(storage: store)
        await model.load()
        #expect(model.selectedAccountID == accountID)
        return (entry, store, model)
    }
    private func freeze(_ model: PortfolioWorkspaceModel, _ request: PerformanceRequest) async throws -> SavedPerformanceReport {
        let baseline = try #require(model.preparationBaseline)
        await model.prepare(request, baseline: baseline)
        let preview = try #require(model.preview)
        #expect(model.savedReport == nil && model.origin == .preview)
        #expect(await model.save(id: preview.id, ledgerRevision: preview.ledgerRevision,
                                 performanceRevision: preview.performanceRevision))
        return try #require(model.savedReport)
    }
    private func amountCard(_ saved: SavedPerformanceReport) throws -> InvestmentShareCardContent {
        var options = InvestmentShareOptions(); options.showAmounts = true
        return try InvestmentShareSnapshot(saved: saved).card(options: options)
    }
    private func body(_ database: DatabaseStore, id: UUID) throws -> Data {
        try #require(try database.read { db in
            try Data.fetchOne(db, sql: "SELECT report_json FROM performance_report_documents WHERE report_id = ?",
                              arguments: [id.uuidString])
        })
    }

    @Test func recordReuseSupplementFreezeReopenAndSharePreserveBothReportVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("investment-daily-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("portfolio-ledger.sqlite")
        let database = try DatabaseStore(path: path.path, purpose: .portfolioLedger)
        let (entry, _, model) = try await seed(database)
        let original = try await freeze(model, request()), originalBytes = try body(database, id: original.id)
        let originalCard = try amountCard(original)
        #expect(originalCard.amount == "+4.00 USD")
        #expect(!originalCard.evidenceLabel.contains("SYNTHETIC"))
        await model.open(original.id)
        let checked = try #require(model.savedReport)
        #expect(checked.replayMatched && checked.report == original.report)
        var draft = try InvestmentCalculationDraft(accountID: accountID, reusing: checked.report.input.request)
        let oldBaseline = try #require(model.preparationBaseline)
        #expect(!draft.externalFlowsComplete)
        #expect(draft.reusedRequest == original.report.input.request)

        // The new entry goes through the same preview/confirmation model as the UI.
        await entry.prepareManual(events: [try buy("BBB", day: firstDays[1], quantity: "1", price: "20")])
        let trade = try #require(entry.preview)
        #expect(await entry.confirm(id: trade.id, expectedRevision: trade.targetRevision))
        let unchangedRequest = try draft.build(calculatedAt: date("2026-01-08T12:00:00Z"))
        await model.prepare(unchangedRequest, baseline: oldBaseline)
        #expect(model.preview == nil && model.context == nil && model.hasError)
        // Reloading cannot quietly make an already bound draft's approval current.
        await model.load()
        await model.prepare(unchangedRequest, baseline: oldBaseline)
        #expect(model.preview == nil && model.hasError)
        let context = try #require(model.context), newBaseline = try #require(model.preparationBaseline)
        #expect(context.ledger.revision != original.ledgerRevision)

        draft.endDay = "2026-01-07"
        #expect(throws: InvestmentDraftError.invalidCalendar) { try draft.selectedCalendar() }
        draft.replacesCalendar = true
        draft.replacementTradingDays = (firstDays + [draft.endDay]).joined(separator: "\n")
        draft.replacementCalendarEvidence = try draftProof("calendar/v2", at: "2026-01-07T22:00:00Z")
        try draft.fillMissingQuotes(accounts: context.ledger.accounts, events: context.ledger.events)
        let newDayIndex = try #require(draft.supplementalDays.firstIndex { $0.day == "2026-01-07" })
        #expect(draft.supplementalDays[newDayIndex].valuationAt.isEmpty)
        #expect(draft.supplementalDays[newDayIndex].quotes.isEmpty)
        let requirements = try draft.requirements(accounts: context.ledger.accounts, events: context.ledger.events)
        #expect(requirements.first { $0.day == "2026-01-06" }?.missingInstrumentIDs == ["equity:BBB"])
        #expect(requirements.first { $0.day == "2026-01-07" }?.valuationAt == nil)
        draft.supplementalDays[newDayIndex].valuationAt = "2026-01-07T21:00:00Z"
        try draft.fillMissingQuotes(accounts: context.ledger.accounts, events: context.ledger.events)
        for dayIndex in draft.supplementalDays.indices {
            let day = draft.supplementalDays[dayIndex].day
            for quoteIndex in draft.supplementalDays[dayIndex].quotes.indices {
                var quote = draft.supplementalDays[dayIndex].quotes[quoteIndex]
                #expect(quote.bid.isEmpty && quote.ask.isEmpty && quote.quoteAt.isEmpty && quote.priceEvidence.text.isEmpty)
                let value = day == "2026-01-06" ? "20" : (quote.instrumentID == "equity:AAA" ? "13" : "25")
                quote.opensAt = day + "T14:30:00Z"; quote.closesAt = day + "T21:00:00Z"
                quote.quoteAt = quote.closesAt; quote.bid = value; quote.ask = value
                let key = quote.instrumentID + "/" + day
                quote.sessionEvidence = try draftProof("supplement-session/" + key, at: quote.closesAt)
                quote.priceEvidence = try draftProof("supplement-price/" + key, at: quote.quoteAt)
                draft.supplementalDays[dayIndex].quotes[quoteIndex] = quote
            }
        }
        draft.externalFlowsComplete = true; draft.usesNewFlowEvidence = true
        draft.flowEvidence = try draftProof("flows/v2", at: "2026-01-07T22:00:00Z")
        let supplemented = try draft.build(calculatedAt: date("2026-01-08T12:00:00Z"))
        for previous in original.report.input.request.days {
            let day = try #require(supplemented.days.first { $0.day == previous.day })
            #expect(day.valuationAt.timeIntervalSinceReferenceDate.bitPattern == previous.valuationAt.timeIntervalSinceReferenceDate.bitPattern)
            #expect(previous.sessions.allSatisfy { day.sessions.contains($0) })
            #expect(previous.prices.allSatisfy { day.prices.contains($0) })
        }
        await model.prepare(supplemented, baseline: newBaseline)
        let preview = try #require(model.preview)
        #expect(model.savedReport == nil && model.origin == .preview)
        #expect(InvestmentSummary(report: preview.report).netPnL == (try Money("11")))
        #expect(await model.save(id: preview.id, ledgerRevision: preview.ledgerRevision,
                                 performanceRevision: preview.performanceRevision))
        let current = try #require(model.savedReport)
        #expect(current.id != original.id && current.report.input.request == supplemented)
        #expect(try body(database, id: original.id) == originalBytes)
        #expect(try amountCard(original) == originalCard)

        let reopened = PortfolioWorkspaceModel(storage: try PerformanceStore(path: path.path))
        await reopened.load(); await reopened.open(current.id)
        let replayed = try #require(reopened.savedReport)
        #expect(replayed.replayMatched && replayed.isCurrentLedger && replayed.report == current.report)
        #expect(try amountCard(replayed).amount == "+11.00 USD")
        await reopened.open(original.id)
        let historical = try #require(reopened.savedReport)
        #expect(historical.replayMatched && !historical.isCurrentLedger && historical.report == original.report)
        #expect(historical.inputHash == original.inputHash && historical.reportHash == original.reportHash)
        #expect(try amountCard(historical).amount == "+4.00 USD")
        #expect(try amountCard(historical).versionLabel == "历史账本版本")
        #expect(reopened.saved.count == 2)
    }

    @Test func savedMissingPriceAndUnconfirmedFlowReportsCannotBypassShareGate() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .portfolioLedger)
        let (_, _, model) = try await seed(database)
        let full = try await freeze(model, request())
        await model.open(full.id)
        let checked = try #require(model.savedReport)
        let notReconfirmed = try InvestmentCalculationDraft(accountID: accountID, reusing: checked.report.input.request)
        let withoutFlows = try notReconfirmed.build(calculatedAt: date("2026-01-08T12:00:00Z"))
        #expect(!withoutFlows.externalFlowsComplete && withoutFlows.flowCompletenessEvidence == nil)
        let incomplete = try await freeze(model, withoutFlows)
        await model.open(incomplete.id)
        let incompleteReplayed = try #require(model.savedReport)
        #expect(incompleteReplayed.replayMatched)
        #expect(throws: InvestmentShareError.missingReconciledProfit) { try InvestmentShareSnapshot(saved: incompleteReplayed) }

        let old = full.report.input.request
        let missing = PerformanceRequest(accountID: old.accountID, calculatedAt: old.calculatedAt, calendar: old.calendar,
            days: old.days.enumerated().map { index, day in
                .init(day: day.day, valuationAt: day.valuationAt, sessions: day.sessions,
                      prices: index == old.days.count - 1 ? [] : day.prices)
            }, externalFlowsComplete: true, flowCompletenessEvidence: old.flowCompletenessEvidence)
        let missingSaved = try await freeze(model, missing)
        await model.open(missingSaved.id)
        let missingReplayed = try #require(model.savedReport)
        #expect(missingReplayed.replayMatched && missingReplayed.report.daily.last?.nav == nil)
        #expect(throws: InvestmentShareError.missingReconciledProfit) { try InvestmentShareSnapshot(saved: missingReplayed) }
        await model.open(full.id)
        #expect(try amountCard(#require(model.savedReport)).amount == "+4.00 USD")
    }

    @Test func syntheticExampleCannotSeedAnOrdinaryDraftOrModifyItsSavedHistory() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .portfolioLedger)
        let (_, store, model) = try await seed(database)
        let full = try await freeze(model, request()), originalBytes = try body(database, id: full.id)
        await model.showSyntheticExample()
        let synthetic = try #require(model.report)
        #expect(model.origin == .synthetic && model.savedReport == nil && !model.canSave)
        #expect(throws: InvestmentDraftError.accountMismatch) {
            try InvestmentCalculationDraft(accountID: accountID, reusing: synthetic.input.request)
        }
        #expect(throws: InvestmentDraftError.syntheticEvidence) {
            try InvestmentCalculationDraft(accountID: synthetic.input.request.accountID, reusing: synthetic.input.request)
        }
        #expect(try await store.reports(accountID: accountID).map(\.id) == [full.id])
        #expect(try body(database, id: full.id) == originalBytes)
        await model.open(full.id)
        #expect(try amountCard(#require(model.savedReport)).amount == "+4.00 USD")
    }
}
