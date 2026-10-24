import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
@testable import AppComposition

@Suite("Current investment ledger facts stay separate from frozen valuation reports")
struct InvestmentLedgerSummaryTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let account = LedgerAccount(id: "account-a", name: "Synthetic account A")
    private let other = LedgerAccount(id: "account-b", name: "Synthetic account B")
    private let stock = LedgerSecurity(id: "ABC", symbol: "ABC")

    private func event(_ id: String, at seconds: TimeInterval, accountID: String? = nil,
                       payload: LedgerPayload) -> LedgerEvent {
        .init(id: id, accountID: accountID ?? account.id, effectiveAt: base.addingTimeInterval(seconds),
              source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: id,
                            evidence: "Independent ledger summary fixture"), payload: payload)
    }
    private func contract() throws -> LedgerOptionVersion {
        try .init(occSymbol: "ABC   231117P00100000", versionID: "v1",
            effectiveFrom: base.addingTimeInterval(-100), quoteMultiplier: Money("100"),
            exerciseConsideration: Money("10000"),
            deliverables: [.init(security: stock, quantity: Money("100"), basisWeight: Money("1"))],
            deliverableCash: Money("0"), tradingEndsAt: base.addingTimeInterval(1000),
            exerciseDeadline: base.addingTimeInterval(2000), settlementAt: base.addingTimeInterval(3000),
            memoReferences: ["SYNTHETIC contract fixture"])
    }
    private func trade(_ id: String, at seconds: TimeInterval, accountID: String? = nil,
                       side: LedgerSide, effect: LedgerTradeEffect, quantity: String = "1",
                       price: String, fee: String) throws -> LedgerEvent {
        try event(id, at: seconds, accountID: accountID, payload: .trade(.init(instrument: .option(contract()),
            side: side, effect: effect, quantity: Money(quantity), unitPrice: Money(price), fee: Money(fee),
            openingLotID: effect == .open ? id + "-lot" : nil,
            strategy: effect == .open ? .init(id: "purpose", purpose: .totalReturn,
                successDefinition: "Closed cash flows net of confirmed fees") : nil)))
    }
    private func snapshot(_ events: [LedgerEvent], revision: UUID = UUID()) throws -> LedgerSnapshot {
        try .init(revision: revision, accounts: [account, other], events: events,
                  state: LedgerEngine.replay(accounts: [account, other], events: events))
    }
    private func summary(_ events: [LedgerEvent], accountID: String? = nil) throws -> InvestmentLedgerSummary {
        try .init(ledger: snapshot(events), accountID: accountID ?? account.id)
    }

    @Test func anEmptyEstablishedAccountHasKnownZeroButUnknownAccountIsRejected() throws {
        let ledger = try snapshot([]), value = try InvestmentLedgerSummary(ledger: ledger, accountID: account.id)
        #expect(value.realizedPnL == (try Money("0")))
        #expect(value.cash == (try Money("0")))
        #expect(value.openLots.isEmpty)
        #expect(value.ledgerRevision == ledger.revision)
        #expect(throws: LedgerError.missingAccount) { try InvestmentLedgerSummary(ledger: ledger, accountID: "absent") }
    }

    @Test func openingCreditIsCashAndRemainingCostWithoutRealizedProfit() throws {
        let value = try summary([trade("open", at: 0, side: .sell, effect: .open, price: "2", fee: "2")])
        #expect(value.cash == (try Money("198")))
        #expect(value.realizedPnL == (try Money("0")))
        #expect(value.openLots.count == 1)
        #expect(value.openLots.first?.quantityRemaining == (try Money("1")))
        #expect(value.openLots.first?.managementCostRemaining == (try Money("198")))
        #expect(value.containsSyntheticRecords)
        // No price input or frozen report is required, and no market value or
        // unrealized P&L is fabricated from the opening cost or premium credit.
    }

    @Test func partialClosePreservesExactFeeAllocationAndRemainingLot() throws {
        let value = try summary([
            trade("open", at: 0, side: .sell, effect: .open, quantity: "3", price: "1", fee: "0.01"),
            trade("close", at: 1, side: .buy, effect: .close, price: "0.5", fee: "0.01")
        ])
        // 299.99 opening credit; the consumed cent allocation is 99.99.
        // Closing one contract costs 50.01, so exactly 49.98 is realized.
        #expect(value.realizedPnL == (try Money("49.98")))
        #expect(value.cash == (try Money("249.98")))
        #expect(value.openLots.first?.quantityRemaining == (try Money("2")))
        #expect(value.openLots.first?.managementCostRemaining == (try Money("200")))
    }

    @Test func identicalContractsInOtherAccountsDoNotLeakCashLotsOrRealizations() throws {
        let events = try [
            trade("a-open", at: 0, side: .sell, effect: .open, price: "2", fee: "2"),
            trade("b-open", at: 1, accountID: other.id, side: .sell, effect: .open, quantity: "2", price: "4", fee: "2"),
            trade("a-close", at: 2, side: .buy, effect: .close, price: "0.5", fee: "1"),
            trade("b-close", at: 3, accountID: other.id, side: .buy, effect: .close, price: "1", fee: "1")
        ]
        let a = try summary(events), b = try summary(events, accountID: other.id)
        #expect(a.realizedPnL == (try Money("147")))
        #expect(a.cash == (try Money("147")) && a.openLots.isEmpty)
        #expect(b.realizedPnL == (try Money("298")))
        #expect(b.cash == (try Money("697")))
        #expect(b.openLots.map(\.id) == ["b-open-lot"])
        #expect(b.openLots.first?.quantityRemaining == (try Money("1")))
    }

    @Test func confirmedExpirationRealizesBothLongAndShortResultsIncludingFees() throws {
        for side in [LedgerSide.buy, .sell] {
            let open = try trade("open", at: 0, side: side, effect: .open, price: "2", fee: "2")
            let expired = try event("expiration", at: 2000, payload: .optionSettlement(.init(contract: contract(),
                action: .expiration, side: side == .buy ? .long : .short, quantity: Money("1"),
                fee: Money("1"), evidence: "SYNTHETIC confirmed expiration")))
            let value = try summary([open, expired])
            #expect(value.realizedPnL == (try Money(side == .buy ? "-203" : "197")))
            #expect(value.openLots.isEmpty)
        }
    }

    @Test func assignmentKeepsZeroOptionRealizationAndTransfersCostExactlyOnce() throws {
        let open = try trade("open", at: 0, side: .sell, effect: .open, price: "2", fee: "2")
        let assigned = try event("assignment", at: 1, payload: .optionSettlement(.init(contract: contract(),
            action: .assignment, side: .short, quantity: Money("1"), fee: Money("1"),
            acquiredLotIDs: [stock.id: "assigned-shares"], evidence: "SYNTHETIC confirmed assignment")))
        let beforeSale = try summary([open, assigned])
        #expect(beforeSale.realizedPnL == (try Money("0")))
        #expect(beforeSale.openLots.map(\.id) == ["assigned-shares"])
        #expect(beforeSale.openLots.first?.managementCostRemaining == (try Money("9803")))
        let sale = try event("share-sale", at: 2, payload: .trade(.init(instrument: .equity(stock), side: .sell,
            effect: .close, quantity: Money("100"), unitPrice: Money("105"), fee: Money("1"))))
        let afterSale = try summary([open, assigned, sale])
        #expect(afterSale.realizedPnL == (try Money("696")))
        #expect(afterSale.openLots.isEmpty)
    }

    @Test func reversalRemovesClosedProfitAndRestoresTheOpenLotFromReplay() throws {
        let open = try trade("open", at: 0, side: .sell, effect: .open, price: "2", fee: "2")
        let close = try trade("close", at: 1, side: .buy, effect: .close, price: "0.5", fee: "1")
        let before = try summary([open, close])
        let reversal = event("reverse-close", at: 2,
            payload: .reversal(.init(originalEventID: close.id, reason: "Confirmed broker correction")))
        let after = try summary([open, close, reversal])
        #expect(before.realizedPnL == (try Money("147")) && before.openLots.isEmpty)
        #expect(after.realizedPnL == (try Money("0")))
        #expect(after.cash == (try Money("198")))
        #expect(after.openLots.map(\.id) == ["open-lot"])
    }

    @Test func cashFlowsAndStandaloneIncomeOrExpensesStaySeparateFromRealizedTradingProfit() throws {
        let kinds: [LedgerCashKind] = [.deposit, .withdrawal, .dividend, .interest, .fee, .otherTax]
        let amounts = ["2000", "100", "20", "3", "4", "2"]
        let events = try kinds.indices.map { index in
            try event("cash-\(index)", at: TimeInterval(index),
                payload: .cash(.init(kind: kinds[index], amount: Money(amounts[index]))))
        }
        let value = try summary(events)
        #expect(value.realizedPnL == (try Money("0")))
        #expect(value.cash == (try Money("1917")))
        #expect(value.openLots.isEmpty)
    }

    @Test func syntheticLabelsFollowActiveRecordsOfTheSelectedAccount() throws {
        let a = try event("a-template", at: 0, payload: .cash(.init(kind: .deposit, amount: Money("10"))))
        let b = try event("b-template", at: 1, accountID: other.id,
            payload: .cash(.init(kind: .deposit, amount: Money("20"))))
        let reverse = event("reverse-a", at: 2,
            payload: .reversal(.init(originalEventID: a.id, reason: "Remove template entry")))
        #expect(try summary([a, b]).containsSyntheticRecords)
        #expect(try !summary([a, b, reverse]).containsSyntheticRecords)
        #expect(try summary([a, b, reverse], accountID: other.id).containsSyntheticRecords)
    }

    @Test func newerLedgerSummaryDoesNotReplaceFrozenPeriodValuesOrSharingInput() throws {
        let input = try PortfolioSyntheticExample.input(), report = try PerformanceEngine.calculate(input)
        let saved = SavedPerformanceReport(id: UUID(), createdAt: input.request.calculatedAt, report: report,
            inputHash: "frozen-input", reportHash: "frozen-report", ledgerRevision: input.ledgerRevision,
            isCurrentLedger: false, replayMatched: true)
        let sale = try LedgerEvent(id: "later-sale", accountID: input.request.accountID,
            effectiveAt: LedgerCSV.timestamp("2026-01-09T15:00:00Z"),
            source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: "later-sale", evidence: "Later synthetic trade"),
            payload: .trade(.init(instrument: .equity(.init(id: "DEMO", symbol: "DEMO")), side: .sell,
                effect: .close, quantity: Money("2"), unitPrice: Money("13"), fee: Money("1"))))
        let events = input.events + [sale]
        let ledger = try LedgerSnapshot(revision: UUID(), accounts: input.accounts, events: events,
            state: LedgerEngine.replay(accounts: input.accounts, events: events))
        let current = try InvestmentLedgerSummary(ledger: ledger, accountID: input.request.accountID)
        #expect(current.realizedPnL == (try Money("5")) && current.openLots.isEmpty)
        #expect(InvestmentSummary(report: saved.report).netPnL == (try Money("4")))
        #expect(saved.report.daily.last?.positions.count == 1)
        var options = InvestmentShareOptions(); options.showAmounts = true
        let card = try InvestmentShareSnapshot(saved: saved).card(options: options)
        #expect(card.amount == "+4.00 USD")
        #expect(card.versionLabel == "历史账本版本")
    }
}
