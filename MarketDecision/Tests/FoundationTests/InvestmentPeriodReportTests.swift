import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
@testable import AppComposition

@Suite("Quick investment periods summarize posted facts without inventing valuations")
struct InvestmentPeriodReportTests {
    private let account = LedgerAccount(id: "account-a", name: "Account A")
    private let other = LedgerAccount(id: "account-b", name: "SYNTHETIC demo")
    private let stock = LedgerSecurity(id: "ABC", symbol: "ABC")

    private func date(_ value: String) throws -> Date { try LedgerCSV.timestamp(value) }
    private func event(_ id: String, at value: String, accountID: String? = nil,
                       source: String = "local-confirmed", group: String? = nil,
                       payload: LedgerPayload) throws -> LedgerEvent {
        try .init(id: id, accountID: accountID ?? account.id, effectiveAt: date(value),
                  source: .init(sourceSystem: source, externalTransactionID: id,
                                evidence: "Independent in-memory period fixture"),
                  payload: payload, multiLegGroupID: group)
    }
    private func trade(_ id: String, at value: String, accountID: String? = nil,
                       effect: LedgerTradeEffect, quantity: String = "1", price: String,
                       fee: String = "0", source: String = "local-confirmed",
                       group: String? = nil) throws -> LedgerEvent {
        try event(id, at: value, accountID: accountID, source: source, group: group,
                  payload: .trade(.init(instrument: .equity(stock),
                    side: effect == .open ? .buy : .sell, effect: effect,
                    quantity: Money(quantity), unitPrice: Money(price), fee: Money(fee),
                    openingLotID: effect == .open ? id + "-lot" : nil)))
    }
    private func cash(_ id: String, at value: String, kind: LedgerCashKind,
                      amount: String, accountID: String? = nil,
                      source: String = "local-confirmed") throws -> LedgerEvent {
        try event(id, at: value, accountID: accountID, source: source,
                  payload: .cash(.init(kind: kind, amount: Money(amount))))
    }
    private func snapshot(_ events: [LedgerEvent]) throws -> LedgerSnapshot {
        try .init(revision: UUID(), accounts: [account, other], events: events,
                  state: LedgerEngine.replay(accounts: [account, other], events: events))
    }
    private func reports(_ events: [LedgerEvent], at cutoff: String = "2026-10-26T14:00:00Z",
                         accountID: String? = nil) throws -> [InvestmentPeriodReport] {
        try InvestmentPeriodReport.generate(ledger: snapshot(events), accountID: accountID ?? account.id,
                                            at: date(cutoff))
    }

    @Test func periodCloseRetainsCostAndFeesOfAnOpeningBeforeEveryWindow() throws {
        let events = try [
            trade("old-open", at: "2025-01-02T15:00:00Z", effect: .open,
                  quantity: "2", price: "100", fee: "2"),
            trade("close", at: "2026-10-20T15:00:00Z", effect: .close,
                  quantity: "2", price: "150", fee: "1")
        ]
        let ledger = try snapshot(events)
        let values = try InvestmentPeriodReport.generate(ledger: ledger, accountID: account.id,
                                                         at: date("2026-10-26T14:00:00Z"))
        #expect(values.map(\.period) == [.year, .quarter, .month])
        for value in values {
            #expect(value.realizedPnL == (try Money("97")))
            #expect(value.bookedPnL == value.realizedPnL)
            #expect(value.cashCharges == (try Money("0")))
            #expect(value.openingCash == (try Money("-202")))
            #expect(value.closingCash == (try Money("97")))
            #expect(value.realizedEventCount == 1)
            #expect(value.timeline.map(\.id) == ["close"])
            #expect(value.timeline.first?.cumulativePnL == value.realizedPnL)
            #expect(value.ledgerRevision == ledger.revision)
        }
    }

    @Test func oneMultiLotCloseIsOneEventAndChargesTransactionFeesOnlyOnce() throws {
        let values = try reports([
            trade("first", at: "2026-09-01T14:00:00Z", effect: .open, price: "100", fee: "2"),
            trade("second", at: "2026-09-02T14:00:00Z", effect: .open, price: "120", fee: "3"),
            trade("both", at: "2026-10-20T14:00:00Z", effect: .close,
                  quantity: "2", price: "150", fee: "1")
        ])
        let month = try #require(values.first { $0.period == .month })
        #expect(month.realizedPnL == (try Money("74")))
        #expect(month.bookedPnL == (try Money("74")))
        #expect(month.realizedEventCount == 1 && month.timeline.count == 1)
        #expect(month.contributions.count == 1)
        #expect(month.contributions.first?.symbol == "ABC")
        #expect(month.contributions.first?.amount == month.realizedPnL)
    }

    @Test func anotherAccountAndItsSyntheticRecordsDoNotLeakIntoSelectedResults() throws {
        let events = try [
            trade("a-open", at: "2026-09-01T14:00:00Z", effect: .open, price: "100"),
            trade("b-open", at: "2026-09-01T14:00:00Z", accountID: other.id,
                  effect: .open, price: "1000", source: "SYNTHETIC"),
            trade("a-close", at: "2026-10-20T14:00:00Z", effect: .close, price: "120"),
            trade("b-close", at: "2026-10-20T14:00:00Z", accountID: other.id,
                  effect: .close, price: "2000", source: "SYNTHETIC")
        ]
        let a = try #require(reports(events).first)
        let b = try #require(reports(events, accountID: other.id).first)
        #expect(a.realizedPnL == (try Money("20")))
        #expect(b.realizedPnL == (try Money("1000")))
        #expect(a.timeline.map(\.id) == ["a-close"])
        #expect(b.timeline.map(\.id) == ["b-close"])
        #expect(!a.containsSyntheticRecords && b.containsSyntheticRecords)
        #expect(a.closingCash == (try Money("20")))
    }

    @Test func externalCapitalAndStandaloneCashIncomeStaySeparateFromTradingProfit() throws {
        let values = try reports([
            cash("prior-cash", at: "2025-01-01T15:00:00Z", kind: .deposit, amount: "1000"),
            cash("deposit", at: "2026-10-01T14:00:00Z", kind: .deposit, amount: "2000"),
            cash("withdraw", at: "2026-10-02T14:00:00Z", kind: .withdrawal, amount: "100"),
            cash("dividend", at: "2026-10-03T14:00:00Z", kind: .dividend, amount: "20"),
            cash("interest", at: "2026-10-04T14:00:00Z", kind: .interest, amount: "3"),
            cash("fee", at: "2026-10-05T14:00:00Z", kind: .fee, amount: "4"),
            cash("tax", at: "2026-10-06T14:00:00Z", kind: .otherTax, amount: "2"),
            cash("withholding", at: "2026-10-07T14:00:00Z", kind: .dividendWithholding, amount: "1")
        ])
        for value in values {
            #expect(value.realizedPnL == (try Money("0")))
            #expect(value.realizedEventCount == 0 && value.contributions.isEmpty)
            #expect(value.deposits == (try Money("2000")))
            #expect(value.withdrawals == (try Money("100")))
            #expect(value.cashIncome == (try Money("23")))
            #expect(value.cashCharges == (try Money("7")))
            #expect(value.bookedPnL == (try Money("16")))
            #expect(value.openingCash == (try Money("1000")))
            #expect(value.closingCash == (try Money("2916")))
        }
    }

    @Test func anOpenShortOptionCreditIsNotRealizedProfitWithoutAConfirmedClose() throws {
        let contract = try LedgerOptionVersion(occSymbol: "ABC   261120P00100000", versionID: "v1",
            effectiveFrom: date("2026-01-01T15:00:00Z"), quoteMultiplier: Money("100"),
            exerciseConsideration: Money("10000"),
            deliverables: [.init(security: stock, quantity: Money("100"), basisWeight: Money("1"))],
            deliverableCash: Money("0"), tradingEndsAt: date("2026-11-20T21:00:00Z"),
            exerciseDeadline: date("2026-11-20T22:30:00Z"), settlementAt: date("2026-11-23T15:00:00Z"),
            memoReferences: ["Independent local contract fixture"])
        let open = try event("short-open", at: "2026-10-01T14:00:00Z",
            payload: .trade(.init(instrument: .option(contract), side: .sell, effect: .open,
                                 quantity: Money("1"), unitPrice: Money("2"), fee: Money("2"),
                                 openingLotID: "short-lot")))
        for value in try reports([open]) {
            #expect(value.closingCash == (try Money("198")))
            #expect(value.realizedPnL == (try Money("0")))
            #expect(value.bookedPnL == (try Money("0")))
            #expect(value.cashIncome == (try Money("0")))
            #expect(value.realizedEventCount == 0)
        }
    }

    @Test func correctionsRestateTheClosedEventWithoutCountingTheReversalAsCashOrProfit() throws {
        let open = try trade("open", at: "2026-01-01T15:00:00Z", effect: .open, price: "100")
        let close = try trade("close", at: "2026-10-01T14:00:00Z", effect: .close, price: "120")
        let reversal = try event("correction", at: "2026-10-10T14:00:00Z",
            payload: .reversal(.init(originalEventID: close.id, reason: "Withdraw incorrect broker event")))
        let before = try #require(reports([open, close]).first)
        let after = try #require(reports([open, close, reversal]).first)
        #expect(before.realizedPnL == (try Money("20")))
        #expect(after.realizedPnL == (try Money("0")))
        #expect(after.timeline.isEmpty && after.contributions.isEmpty)
        #expect(after.closingCash == (try Money("-100")))
    }

    @Test func rollingMonthsUseNewYorkCalendarIncludingDSTAndMonthEndClamping() throws {
        let november = try reports([], at: "2026-11-30T15:00:00Z")
        #expect(november.map(\.startDate) == (try [date("2025-11-30T15:00:00Z"),
            date("2026-08-30T14:00:00Z"), date("2026-10-30T14:00:00Z")]))
        #expect(november.allSatisfy { $0.endDate == $0.generatedAt })
        let march = try #require(reports([], at: "2024-03-31T14:00:00Z").first { $0.period == .month })
        #expect(march.startDate == (try date("2024-02-29T15:00:00Z")))
    }

    @Test func startAndEndAreIncludedAndFutureRecordsDoNotBecomeBookedFacts() throws {
        let values = try reports([
            cash("before", at: "2026-09-26T13:59:59Z", kind: .dividend, amount: "1"),
            cash("start", at: "2026-09-26T14:00:00Z", kind: .dividend, amount: "2"),
            cash("end", at: "2026-10-26T14:00:00Z", kind: .interest, amount: "3"),
            cash("future", at: "2026-10-26T14:00:01Z", kind: .interest,
                 amount: "1000", source: "SYNTHETIC")
        ])
        let month = try #require(values.first { $0.period == .month })
        #expect(month.cashIncome == (try Money("5")))
        #expect(month.openingCash == (try Money("1")))
        #expect(month.closingCash == (try Money("6")))
        #expect(!month.containsSyntheticRecords)
        #expect(values.first?.cashIncome == (try Money("6")))
    }

    @Test func cutoffBetweenValidatedGroupLegsDoesNotRejectOrIncludeTheFutureLeg() throws {
        let values = try reports([
            trade("present", at: "2026-10-20T14:00:00Z", effect: .open,
                  price: "10", group: "navigation-group"),
            trade("future", at: "2026-11-20T14:00:00Z", effect: .open,
                  price: "100", group: "navigation-group")
        ])
        #expect(values.allSatisfy { $0.realizedEventCount == 0 })
        for value in values { #expect(value.closingCash == (try Money("-10"))) }
    }

    @Test func unknownAccountInvalidDateAndMismatchedSnapshotStateAreRejected() throws {
        let ledger = try snapshot([])
        let cutoff = try date("2026-10-26T14:00:00Z")
        #expect(throws: LedgerError.missingAccount) {
            try InvestmentPeriodReport.generate(ledger: ledger, accountID: "missing", at: cutoff)
        }
        #expect(throws: InvestmentPeriodReportError.invalidDate) {
            try InvestmentPeriodReport.generate(ledger: ledger, accountID: account.id,
                                                at: Date(timeIntervalSinceReferenceDate: .infinity))
        }
        let entry = try cash("deposit", at: "2026-10-01T14:00:00Z", kind: .deposit, amount: "5")
        let mismatched = LedgerSnapshot(revision: ledger.revision, accounts: ledger.accounts,
                                        events: [entry], state: ledger.state)
        #expect(throws: LedgerError.arithmeticInvariant) {
            try InvestmentPeriodReport.generate(ledger: mismatched, accountID: account.id, at: cutoff)
        }
    }
}
