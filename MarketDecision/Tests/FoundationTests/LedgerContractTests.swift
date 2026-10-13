import Foundation
import Testing
import CoreDomain
import PortfolioEngine

@Suite("Ledger fact and contract boundaries")
struct LedgerContractTests {
    let fixtures = LedgerEngineTests()
    func m(_ s: String) throws -> Money { try Money(s) }

    @Test func sourceIdentityUsesExternalIdentityOrExactFileRowNotDateAmount() throws {
        let a = LedgerSource(sourceSystem: "broker", externalTransactionID: "execution", fileHash: String(repeating: "a", count: 64), rowIndex: 1, evidence: "statement")
        let b = LedgerSource(sourceSystem: "broker", externalTransactionID: "execution", fileHash: String(repeating: "b", count: 64), rowIndex: 9, evidence: "statement")
        #expect(try a.identity(accountID: "A") == b.identity(accountID: "A"))
        #expect(try a.identity(accountID: "A") != b.identity(accountID: "B"))
        let row1 = LedgerSource(sourceSystem: "broker", fileHash: String(repeating: "a", count: 64), rowIndex: 1, evidence: "statement")
        let row2 = LedgerSource(sourceSystem: "broker", fileHash: String(repeating: "a", count: 64), rowIndex: 2, evidence: "statement")
        #expect(try row1.identity(accountID: "A") != row2.identity(accountID: "A"))
        #expect(throws: LedgerError.invalidEvidence) { try LedgerSource(sourceSystem: "broker", evidence: "missing identity").validate() }
        #expect(throws: LedgerError.invalidEvidence) { try LedgerSource(sourceSystem: "broker", fileHash: "not-a-hash", rowIndex: 1, evidence: "statement").validate() }
    }

    @Test func missingFeeCannotDecodeAndNegativeFeeCannotEnterLedger() throws {
        let trade = LedgerTrade(instrument: .equity(fixtures.stock), side: .buy, effect: .open, quantity: try m("1"), unitPrice: try m("10"), fee: try m("0"), openingLotID: "lot")
        let data = try JSONEncoder().encode(trade)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "fee")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LedgerTrade.self, from: missing) }
        let negative = fixtures.event("bad", 0, .trade(LedgerTrade(instrument: .equity(fixtures.stock), side: .buy, effect: .open, quantity: try m("1"), unitPrice: try m("10"), fee: try m("-0.01"), openingLotID: "lot")))
        #expect(throws: LedgerError.invalidAmount) { try negative.validate() }
    }

    @Test func malformedOCCAndUnsupportedCashSettlementAreRejected() throws {
        let good = try fixtures.option()
        func changed(symbol: String, settlement: LedgerSettlementType = .physicalEquity, evidence: [String] = ["memo"]) -> LedgerOptionVersion {
            LedgerOptionVersion(occSymbol: symbol, versionID: good.versionID, effectiveFrom: good.effectiveFrom,
                quoteMultiplier: good.quoteMultiplier, exerciseConsideration: good.exerciseConsideration,
                deliverables: good.deliverables, deliverableCash: good.deliverableCash, settlementType: settlement,
                tradingEndsAt: good.tradingEndsAt, exerciseDeadline: good.exerciseDeadline, settlementAt: good.settlementAt, memoReferences: evidence)
        }
        #expect(throws: LedgerError.invalidContract) { try changed(symbol: "ABC   230231P00100000").validate() }
        #expect(throws: LedgerError.invalidContract) { try changed(symbol: "ABC231117P100").validate() }
        #expect(throws: LedgerError.invalidContract) { try changed(symbol: good.occSymbol, evidence: []).validate() }
        #expect(throws: LedgerError.unsupportedSettlement) { try changed(symbol: good.occSymbol, settlement: .cash).validate() }
        try good.validate()
        #expect(good.right == .put)
    }

    @Test func fractionalOptionAndOverprecisionSharesAreRejected() throws {
        let option = try fixtures.option()
        let fractional = fixtures.event("bad", 0, .trade(LedgerTrade(instrument: .option(option), side: .sell, effect: .open, quantity: try m("0.5"), unitPrice: try m("1"), fee: try m("0"), openingLotID: "lot", strategy: fixtures.strategy())))
        #expect(throws: LedgerError.invalidQuantity) { try fractional.validate() }
        let fineShares = try fixtures.stockBuy("fine", 0, quantity: "0.000000001", price: "10")
        #expect(throws: LedgerError.invalidQuantity) { try fineShares.validate() }
    }

    @Test func sharedStrategyIDCannotChangePurposeOrSuccessDefinition() throws {
        let option = try fixtures.option()
        let first = fixtures.event("a", 0, .trade(LedgerTrade(instrument: .option(option), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m("1"), fee: try m("0"), openingLotID: "a", strategy: fixtures.strategy())))
        let changed = LedgerStrategy(id: "purpose", purpose: .premiumIncome, successDefinition: "Unrelated purpose")
        let second = fixtures.event("b", 1, .trade(LedgerTrade(instrument: .option(option), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m("1"), fee: try m("0"), openingLotID: "b", strategy: changed)))
        #expect(throws: LedgerError.invalidStrategy) { try LedgerEngine.replay(accounts: [fixtures.account], events: [first, second]) }
        let missingTarget = LedgerStrategy(id: "target", purpose: .acquireShares, successDefinition: "Effective cost below my maximum")
        #expect(throws: LedgerError.invalidStrategy) { try missingTarget.validate() }
    }

    @Test func optionTransferRequiresActiveVersionAndNotExpired() throws {
        let option = try fixtures.option()
        let transfer = LedgerTransferIn(lotID: "option", instrument: .option(option), quantity: try m("1"), historicalCost: try m("200"), acquiredAt: fixtures.base.addingTimeInterval(-1000), eventMarketValue: try m("150"), strategy: fixtures.strategy(), evidence: "transfer statement")
        #expect(throws: LedgerError.invalidContract) { try fixtures.event("early", -101, .transferIn(transfer)).validate() }
        #expect(throws: LedgerError.invalidContract) { try fixtures.event("expired", 2000, .transferIn(transfer)).validate() }
        let valid = try LedgerEngine.replay(accounts: [fixtures.account], events: [fixtures.event("valid", 0, .transferIn(transfer))])
        #expect(valid.lots.count == 1)
    }

    @Test func isolatedRollAndDuplicateEventIdentityAreRejected() throws {
        let contract = try fixtures.option()
        let open = fixtures.event("open", 0, .trade(LedgerTrade(instrument: .option(contract), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m("1"), fee: try m("0"), openingLotID: "lot", strategy: fixtures.strategy())), roll: "incomplete")
        #expect(throws: LedgerError.invalidRoll) { try LedgerEngine.replay(accounts: [fixtures.account], events: [open]) }
        let cash = fixtures.event("cash", 0, .cash(LedgerCashEntry(kind: .deposit, amount: try m("1"))))
        #expect(throws: LedgerError.duplicateIdentity) { try LedgerEngine.replay(accounts: [fixtures.account], events: [cash, cash]) }
        #expect(throws: LedgerError.invalidAccount) { try LedgerEngine.replay(accounts: [LedgerAccount(id: "EUR", name: "EUR", currency: "EUR")], events: []) }
    }
    @Test func independentSimultaneousAcquisitionsAreDistinctAndUseLotFIFO() throws {
        let a = try fixtures.stockBuy("a", 0, quantity: "1", price: "10")
        let b = try fixtures.stockBuy("b", 0, quantity: "1", price: "10")
        let close = try fixtures.stockSell("sell", 1, quantity: "1", price: "11")
        let state = try LedgerEngine.replay(accounts: [fixtures.account], events: [b, a, close])
        #expect(state.lots.count == 2)
        #expect(state.realizations.first?.lotID == "a-lot")
        #expect(state.cashByAccount[fixtures.account.id] == (try m("-9")))
    }

    @Test func unitPriceBeyondApprovedPrecisionIsRejectedWithoutRounding() throws {
        let event = try fixtures.stockBuy("too-precise", 0, quantity: "1", price: "1.0000001")
        #expect(throws: LedgerError.invalidAmount) { try event.validate() }
        try fixtures.stockBuy("boundary", 0, quantity: "1", price: "1.000001").validate()
    }

    @Test func unrelatedProviderSequencesCannotOrderDependentEvents() throws {
        let buy = try fixtures.stockBuy("buy", 0, quantity: "1", price: "10", sequence: 1)
        let sell = LedgerEvent(id: "sell", accountID: fixtures.account.id, effectiveAt: fixtures.base, providerSequence: 2,
            source: LedgerSource(sourceSystem: "unrelated-broker", externalTransactionID: "sell", evidence: "separate sequence domain"),
            payload: .trade(LedgerTrade(instrument: .equity(fixtures.stock), side: .sell, effect: .close, quantity: try m("1"), unitPrice: try m("11"), fee: try m("0"))))
        #expect(throws: LedgerError.ambiguousOrdering) { try LedgerEngine.replay(accounts: [fixtures.account], events: [buy, sell]) }
    }

}
