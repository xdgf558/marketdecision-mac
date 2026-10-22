import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
@testable import AppComposition

@Suite("Everyday investment summary and private share cards")
struct InvestmentPresentationTests {
    private func report(days: [PerformanceDayInput]? = nil, events: [LedgerEvent]? = nil,
                        complete: Bool = true) throws -> PerformanceReport {
        let original = try PortfolioSyntheticExample.input(), request = original.request
        let revised = PerformanceRequest(accountID: request.accountID, calculatedAt: request.calculatedAt,
            calendar: request.calendar, days: days ?? request.days, externalFlowsComplete: complete,
            flowCompletenessEvidence: complete ? request.flowCompletenessEvidence : nil)
        return try PerformanceEngine.calculate(.init(request: revised, ledgerRevision: original.ledgerRevision,
            accounts: original.accounts, events: events ?? original.events))
    }
    private func saved(_ report: PerformanceReport, matched: Bool = true, current: Bool = true) -> SavedPerformanceReport {
        .init(id: UUID(), createdAt: report.input.request.calculatedAt, report: report,
              inputHash: "private-input-hash", reportHash: "private-report-hash", ledgerRevision: report.input.ledgerRevision,
              isCurrentLedger: current, replayMatched: matched)
    }
    private func text(_ card: InvestmentShareCardContent) -> String {
        [card.period, card.amount, card.returnText, card.holdings.joined(), card.evidenceLabel,
         card.valuationLabel, card.versionLabel, card.scope, card.footnote].joined(separator: "\n")
    }

    @Test func defaultShareHidesAmountsHoldingsAndAllAccountMetadata() throws {
        let value = try report(), snapshot = try InvestmentShareSnapshot(saved: saved(value))
        let card = snapshot.card(options: .init()), rendered = text(card)
        let account = try #require(value.input.accounts.first)
        #expect(card.amount == "金额已隐藏")
        #expect(card.holdings.isEmpty)
        #expect(!rendered.contains(value.input.request.accountID))
        #expect(!rendered.contains(account.name))
        #expect(!rendered.contains("private-input-hash"))
        #expect(!rendered.contains("synthetic-deposit"))
        #expect(!rendered.contains("equity:DEMO"))
        #expect(card.evidenceLabel.contains("SYNTHETIC"))
        #expect(card.period == "2026-01-02 → 2026-01-07")
        #expect(card.valuationLabel.contains("非实时"))
    }

    @Test func depositsDoNotBecomeProfitOnDashboardOrSharedCard() throws {
        let original = try PortfolioSyntheticExample.input()
        let deposit = try LedgerEvent(id: "second-deposit", accountID: original.request.accountID,
            effectiveAt: LedgerCSV.timestamp("2026-01-06T14:00:00Z"),
            source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: "second-deposit", evidence: "合成资金存入"),
            payload: .cash(.init(kind: .deposit, amount: Money("500"))))
        let baseline = try report(), changed = try report(events: original.events + [deposit])
        #expect(changed.daily.last?.nav != baseline.daily.last?.nav)
        #expect(InvestmentSummary(report: baseline).netPnL == (try Money("4")))
        #expect(InvestmentSummary(report: changed).netPnL == (try Money("4")))
        var options = InvestmentShareOptions(); options.showAmounts = true
        #expect(try InvestmentShareSnapshot(saved: saved(changed)).card(options: options).amount == "+4.00 USD")
    }

    @Test func missingPricesOrUnconfirmedFlowsCannotProduceShareableProfit() throws {
        let original = try PortfolioSyntheticExample.input()
        let days = original.request.days.enumerated().map { index, day in
            PerformanceDayInput(day: day.day, valuationAt: day.valuationAt, sessions: day.sessions,
                                prices: index == original.request.days.count - 1 ? [] : day.prices)
        }
        let missing = try report(days: days)
        #expect(InvestmentSummary(report: missing).netPnL == nil)
        #expect(throws: InvestmentShareError.missingReconciledProfit) { try InvestmentShareSnapshot(saved: saved(missing)) }
        let incomplete = try report(complete: false)
        #expect(InvestmentSummary(report: incomplete).netPnL == nil)
        #expect(throws: InvestmentShareError.missingReconciledProfit) { try InvestmentShareSnapshot(saved: saved(incomplete)) }
    }

    @Test func unverifiedSavedReportCannotCreateCard() throws {
        let value = try report()
        #expect(throws: InvestmentShareError.unverifiedReport) { try InvestmentShareSnapshot(saved: saved(value, matched: false)) }
        let mismatched = SavedPerformanceReport(id: UUID(), createdAt: value.input.request.calculatedAt, report: value,
            inputHash: "x", reportHash: "y", ledgerRevision: UUID(), isCurrentLedger: true, replayMatched: true)
        #expect(throws: InvestmentShareError.unverifiedReport) { try InvestmentShareSnapshot(saved: mismatched) }
    }

    @Test func lossesKeepTheirSignAndPrivacyChoicesCannotRemoveEvidenceLabels() throws {
        let input = try PortfolioSyntheticExample.input()
        let losingPrice = try Money("8")
        let days = input.request.days.map { day in
            PerformanceDayInput(day: day.day, valuationAt: day.valuationAt, sessions: day.sessions,
                prices: day.prices.map { old in
                    PerformancePrice(id: old.id, instrumentID: old.instrumentID, sessionID: old.sessionID,
                        quoteAt: old.quoteAt, bid: day.day == "2026-01-07" ? losingPrice : old.bid,
                        ask: day.day == "2026-01-07" ? losingPrice : old.ask, quality: old.quality, evidence: old.evidence)
                })
        }
        let snapshot = try InvestmentShareSnapshot(saved: saved(report(days: days), current: false))
        var options = InvestmentShareOptions(); options.showAmounts = true; options.showHoldingNames = true; options.showReturn = false
        let card = snapshot.card(options: options)
        #expect(card.amount == "-4.00 USD")
        #expect(card.returnText == "收益率已隐藏")
        #expect(card.holdings == ["equity:DEMO"])
        #expect(card.evidenceLabel.contains("非真实账户业绩"))
        #expect(card.versionLabel == "历史账本版本")
    }

    @Test func noReturnEstimateIsInventedForZeroCapital() throws {
        let value = try report(events: [])
        #expect(value.twr.value == nil)
        let card = try InvestmentShareSnapshot(saved: saved(value)).card(options: .init())
        #expect(card.returnText == "收益率未核对")
        #expect(!card.returnText.contains("0.00%"))
    }

    @Test func xDestinationCarriesNoFinancialOrAccountPayload() {
        let url = InvestmentShareSnapshot.composeURL
        #expect(url.absoluteString == "https://x.com/compose/post")
        #expect(url.query == nil && url.fragment == nil && url.user == nil && url.password == nil)
    }
}
