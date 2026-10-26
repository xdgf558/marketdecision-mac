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
        ([card.period, card.periodTitle, card.dateRange, card.periodBoundaryLabel, card.asOfLabel, card.profitLabel,
          card.returnLabel ?? "", card.amount, card.returnText, card.holdings.joined(), card.evidenceLabel,
          card.valuationLabel, card.versionLabel, card.scope, card.footnote]
         + card.breakdown.flatMap { [$0.title, $0.value] }).joined(separator: "\n")
    }

    @Test func defaultShareHidesAmountsHoldingsAndAllAccountMetadata() throws {
        let value = try report(), snapshot = try InvestmentShareSnapshot(saved: saved(value))
        let card = snapshot.card(options: .init()), rendered = text(card)
        let account = try #require(value.input.accounts.first)
        #expect(card.amount == "金额已隐藏")
        #expect(snapshot.supportsReturn && snapshot.supportsHoldingNames)
        #expect(card.profitLabel == "区间净盈亏" && card.returnLabel == "时间加权收益")
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

    private var quickAccount: LedgerAccount {
        LedgerAccount(id: "private-share-account-id", name: "Private account name")
    }
    private func quickEvent(_ id: String, payload: LedgerPayload,
                            source: String = "private-broker-system",
                            at timestamp: String = "2026-10-20T14:00:00Z") throws -> LedgerEvent {
        try .init(id: id, accountID: quickAccount.id,
                  effectiveAt: LedgerCSV.timestamp(timestamp),
                  source: .init(sourceSystem: source, externalTransactionID: id,
                                evidence: "private-source-evidence"), payload: payload)
    }
    private func quickReports(events: [LedgerEvent], at cutoff: String = "2026-10-26T14:00:00Z") throws -> [InvestmentPeriodReport] {
        let accounts = [quickAccount]
        let ledger = try LedgerSnapshot(revision: UUID(), accounts: accounts, events: events,
                                         state: LedgerEngine.replay(accounts: accounts, events: events))
        return try InvestmentPeriodReport.generate(ledger: ledger, accountID: quickAccount.id,
                                                    at: LedgerCSV.timestamp(cutoff))
    }

    @Test func quickReportShareUsesBookedIncomeAndHidesPrivateMetadata() throws {
        let events = try [
            quickEvent("private-deposit", payload: .cash(.init(kind: .deposit, amount: Money("2000")))),
            quickEvent("private-interest", payload: .cash(.init(kind: .interest, amount: Money("23")))),
            quickEvent("private-fee", payload: .cash(.init(kind: .fee, amount: Money("7"))))
        ]
        for report in try quickReports(events: events) {
            #expect(report.closingCash == (try Money("2016")))
            let snapshot = InvestmentShareSnapshot(periodReport: report)
            let hidden = snapshot.card(options: .init())
            #expect(hidden.amount == "金额已隐藏")
            #expect(!snapshot.supportsReturn && !snapshot.supportsHoldingNames)
            var options = InvestmentShareOptions()
            options.showAmounts = true; options.showReturn = true; options.showHoldingNames = true
            let visible = snapshot.card(options: options), rendered = text(visible)
            #expect(visible.amount == "+16.00 USD")
            #expect(visible.profitLabel == "已入账收益" && visible.returnLabel == nil)
            #expect(visible.returnText.isEmpty && visible.holdings.isEmpty)
            for privateText in [quickAccount.id, quickAccount.name, "private-broker-system", "private-source-evidence",
                                "private-deposit", "private-interest", "private-fee", "2016", "2000"] {
                #expect(!rendered.contains(privateText))
            }
            #expect(visible.scope.contains("入出金不计收益"))
            #expect(visible.evidenceLabel == "本地记录 · 按当前有效入账记录汇总")
        }
    }

    @Test func unclosedOptionCreditSharesZeroBookedProfitWithoutValuation() throws {
        let stock = LedgerSecurity(id: "private-stock-id", symbol: "ABC")
        let contract = try LedgerOptionVersion(occSymbol: "ABC   261120P00100000", versionID: "private-contract-v1",
            effectiveFrom: LedgerCSV.timestamp("2026-01-01T15:00:00Z"), quoteMultiplier: Money("100"),
            exerciseConsideration: Money("10000"),
            deliverables: [.init(security: stock, quantity: Money("100"), basisWeight: Money("1"))],
            deliverableCash: Money("0"), tradingEndsAt: LedgerCSV.timestamp("2026-11-20T21:00:00Z"),
            exerciseDeadline: LedgerCSV.timestamp("2026-11-20T22:30:00Z"), settlementAt: LedgerCSV.timestamp("2026-11-23T15:00:00Z"),
            memoReferences: ["private-contract-memo"])
        let opening = try quickEvent("private-option-opening", payload: .trade(.init(instrument: .option(contract),
            side: .sell, effect: .open, quantity: Money("1"), unitPrice: Money("2"), fee: Money("2"),
            openingLotID: "private-option-lot",
            strategy: .init(id: "private-option-purpose", purpose: .totalReturn,
                successDefinition: "Closed economic return net of confirmed fees"))))
        for report in try quickReports(events: [opening]) {
            #expect(report.closingCash == (try Money("198")))
            #expect(report.realizedEventCount == 0)
            let snapshot = InvestmentShareSnapshot(periodReport: report)
            var options = InvestmentShareOptions(); options.showAmounts = true; options.showHoldingNames = true
            let card = snapshot.card(options: options), rendered = text(card)
            #expect(card.amount == "0.00 USD")
            #expect(card.valuationLabel == "不含持仓浮盈、净值或收益率")
            #expect(card.footnote.contains("开仓权利金不直接计为利润"))
            #expect(!rendered.contains("198") && !rendered.contains("ABC"))
            #expect(card.holdings.isEmpty && card.returnLabel == nil && card.returnText.isEmpty)
        }
    }

    @Test func quickShareLabelsSyntheticLossAndCannotInventReturnOrHoldings() throws {
        let charge = try quickEvent("private-synthetic-fee", payload: .cash(.init(kind: .fee, amount: Money("4"))),
                                   source: "SYNTHETIC")
        let report = try #require(quickReports(events: [charge]).first)
        let snapshot = InvestmentShareSnapshot(periodReport: report)
        var options = InvestmentShareOptions()
        options.showAmounts = true; options.showReturn = true; options.showHoldingNames = true
        let card = snapshot.card(options: options)
        #expect(card.amount == "-4.00 USD")
        #expect(card.evidenceLabel.contains("SYNTHETIC") && card.evidenceLabel.contains("非真实账户业绩"))
        #expect(card.returnLabel == nil && card.returnText.isEmpty && card.holdings.isEmpty)
        #expect(!text(card).contains("0.00%"))
        options.showAmounts = false; options.showReturn = false; options.showHoldingNames = false
        #expect(snapshot.card(options: options).evidenceLabel == card.evidenceLabel)
    }

    @Test func quickSharePeriodsUseNewYorkOffsetsAcrossDST() throws {
        let values = try quickReports(events: [], at: "2026-11-30T15:00:00Z")
        #expect(values.map(\.period) == [.year, .quarter, .month])
        for report in values {
            let card = InvestmentShareSnapshot(periodReport: report).card(options: .init())
            #expect(card.period.hasPrefix(report.title + " · "))
            #expect(card.period.contains("2026-11-30 10:00:00.000 -05:00"))
            #expect(card.period.contains("America/New_York，含起止时刻"))
        }
        let month = try #require(values.first { $0.period == .month })
        #expect(InvestmentShareSnapshot(periodReport: month).card(options: .init()).period
            .contains("2026-10-30 10:00:00.000 -04:00"))
        #expect(InvestmentShareSnapshot(periodReport: month).card(options: .init()).periodBoundaryLabel
            == "美东 10:00:00.000 -04:00 → 10:00:00.000 -05:00 · 含起止时刻")
    }

    @Test func quickShareBreakdownUsesAllocatedFeesOnceAndMasksEveryAmount() throws {
        let stock = LedgerSecurity(id: "private-share-stock", symbol: "ABC")
        let events = try [
            quickEvent("private-open", payload: .trade(.init(instrument: .equity(stock),
                side: .buy, effect: .open, quantity: Money("2"), unitPrice: Money("100"),
                fee: Money("2"), openingLotID: "private-share-lot")), at: "2025-01-02T15:00:00Z"),
            quickEvent("private-close", payload: .trade(.init(instrument: .equity(stock),
                side: .sell, effect: .close, quantity: Money("2"), unitPrice: Money("150"), fee: Money("1")))),
            quickEvent("private-income", payload: .cash(.init(kind: .interest, amount: Money("23")))),
            quickEvent("private-charge", payload: .cash(.init(kind: .fee, amount: Money("7"))))
        ]
        for report in try quickReports(events: events) {
            let snapshot = InvestmentShareSnapshot(periodReport: report)
            #expect(snapshot.periodSelection == report.period)
            let hidden = snapshot.card(options: .init())
            #expect(hidden.amount == "金额已隐藏")
            #expect(hidden.breakdown.map(\.value) == Array(repeating: "金额已隐藏", count: 3))
            var options = InvestmentShareOptions(); options.showAmounts = true
            let shown = snapshot.card(options: options)
            #expect(shown.amount == "+113.00 USD")
            #expect(shown.breakdown.map(\.title) == ["交易盈亏", "股息与利息", "费用与税款"])
            // The three trade fees are already in 97; the last row must not charge them again.
            #expect(shown.breakdown.map(\.value) == ["+97.00 USD", "+23.00 USD", "+7.00 USD"])
            #expect(shown.evidenceLabel == hidden.evidenceLabel)
            #expect(shown.periodTitle == report.title)
            for privateText in [quickAccount.id, quickAccount.name, "private-open", "private-share-lot", "ABC"] {
                #expect(!text(shown).contains(privateText))
            }
        }
    }

    @Test func quickShareCompactDatesKeepNewYorkDayAndExactPeriodEvidence() throws {
        let month = try #require(quickReports(events: [], at: "2026-11-01T00:30:00Z").first { $0.period == .month })
        let card = InvestmentShareSnapshot(periodReport: month).card(options: .init())
        #expect(card.periodTitle == "近1个月")
        #expect(card.dateRange == "2026.09.30 至 2026.10.31")
        #expect(card.asOfLabel == "截至 2026.10.31")
        #expect(card.periodBoundaryLabel == "美东 20:30:00.000 -04:00 → 20:30:00.000 -04:00 · 含起止时刻")
        #expect(card.period.contains("2026-10-31 20:30:00.000 -04:00"))
        #expect(card.period.contains("America/New_York，含起止时刻"))
    }

    @Test func frozenShareDoesNotInventBookedBreakdownOrRollingPeriod() throws {
        let snapshot = try InvestmentShareSnapshot(saved: saved(report()))
        let card = snapshot.card(options: .init())
        #expect(snapshot.periodSelection == nil)
        #expect(card.breakdown.isEmpty)
        #expect(card.periodTitle == "区间报告")
        #expect(card.dateRange == "2026.01.02 至 2026.01.07")
        #expect(card.asOfLabel == "截至 2026.01.07")
        #expect(card.periodBoundaryLabel == "冻结报告 · 日终估值")
        #expect(card.profitLabel == "区间净盈亏" && card.returnLabel == "时间加权收益")
    }

}
