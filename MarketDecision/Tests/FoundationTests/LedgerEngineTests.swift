import Foundation
import Testing
import CoreDomain
import PortfolioEngine

@Suite("Ledger exact management replay")
struct LedgerEngineTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let stock = LedgerSecurity(id: "security-ABC", symbol: "ABC")
    func m(_ text: String) throws -> Money { try Money(text) }
    var account: LedgerAccount { LedgerAccount(id: "account", name: "Synthetic USD") }
    func event(_ id: String, _ second: TimeInterval, _ payload: LedgerPayload, sequence: Int? = nil,
               roll: String? = nil, group: String? = nil) -> LedgerEvent {
        LedgerEvent(id: id, accountID: account.id, effectiveAt: base.addingTimeInterval(second), providerSequence: sequence,
                    source: LedgerSource(sourceSystem: "synthetic", externalTransactionID: id, evidence: "independent test vector"),
                    payload: payload, rollGroupID: roll, multiLegGroupID: group)
    }
    func strategy(_ id: String = "purpose") -> LedgerStrategy {
        LedgerStrategy(id: id, purpose: .totalReturn, successDefinition: "Completed stock and option cash flows, net of actual fees")
    }
    func option(_ right: LedgerOptionRight = .put, version: String = "v1", units: String = "100", consideration: String = "10000") throws -> LedgerOptionVersion {
        LedgerOptionVersion(occSymbol: "ABC   231117" + (right == .put ? "P" : "C") + "00100000", versionID: version,
            effectiveFrom: base.addingTimeInterval(-100), quoteMultiplier: try m("100"), exerciseConsideration: try m(consideration),
            deliverables: [LedgerDeliverable(security: stock, quantity: try m(units), basisWeight: try m("1"))], deliverableCash: try m("0"),
            tradingEndsAt: base.addingTimeInterval(1000), exerciseDeadline: base.addingTimeInterval(2000),
            settlementAt: base.addingTimeInterval(3000), memoReferences: ["SYNTHETIC official contract fixture"])
    }
    func stockBuy(_ id: String, _ seconds: TimeInterval, quantity: String, price: String, fee: String = "0", sequence: Int? = nil) throws -> LedgerEvent {
        event(id, seconds, .trade(LedgerTrade(instrument: .equity(stock), side: .buy, effect: .open, quantity: try m(quantity),
              unitPrice: try m(price), fee: try m(fee), openingLotID: id + "-lot")), sequence: sequence)
    }
    func stockSell(_ id: String, _ seconds: TimeInterval, quantity: String, price: String, fee: String = "0", selections: [LedgerLotSelection] = []) throws -> LedgerEvent {
        event(id, seconds, .trade(LedgerTrade(instrument: .equity(stock), side: .sell, effect: .close, quantity: try m(quantity),
              unitPrice: try m(price), fee: try m(fee), selections: selections)))
    }
    func totalPnL(_ state: LedgerState) throws -> Money { try state.realizations.reduce(m("0")) { try $0.adding($1.pnl) } }

    @Test func feeCapitalizationAndPartialDisposalConserveCashAndCost() throws {
        let events = [event("deposit", 0, .cash(LedgerCashEntry(kind: .deposit, amount: try m("1000")))),
                      try stockBuy("buy", 1, quantity: "3", price: "10", fee: "0.01"),
                      try stockSell("sell", 2, quantity: "1", price: "12", fee: "0.01")]
        let result = try LedgerEngine.replay(accounts: [account], events: events)
        #expect(result.cashByAccount[account.id] == (try m("981.98")))
        #expect(result.lots[0].quantityRemaining == (try m("2")))
        #expect(result.lots[0].managementCostRemaining == (try m("20.01")))
        #expect(result.realizations[0].removedManagementCost == (try m("10")))
        #expect(try totalPnL(result) == m("1.99"))
        #expect(try result.cashByAccount[account.id]!.adding(result.lots[0].managementCostRemaining) == m("1001.99"))
        #expect(result.postings.map(\.transactionFee) == [try m("0"), try m("0.01"), try m("0.01")])
    }

    @Test func fifoUsesAcquisitionTimeThenLotIDRegardlessOfProviderOrder() throws {
        let z = try stockBuy("z", 1, quantity: "1", price: "20", sequence: 0)
        let a = try stockBuy("a", 1, quantity: "1", price: "10", sequence: 1)
        let state = try LedgerEngine.replay(accounts: [account], events: [z, a, try stockSell("close", 2, quantity: "1", price: "30")])
        #expect(state.realizations[0].lotID == "a-lot")
        #expect(state.realizations[0].pnl == (try m("20")))
        #expect(state.lots.first { $0.id == "z-lot" }?.quantityRemaining == (try m("1")))
    }

    @Test func specifiedLotsOverrideFIFOAndMissingChoiceIsRejectedForSpecificAccount() throws {
        let buys = [try stockBuy("a", 1, quantity: "2", price: "10"), try stockBuy("b", 2, quantity: "2", price: "20")]
        let sale = try stockSell("close", 3, quantity: "1", price: "30", selections: [LedgerLotSelection(lotID: "b-lot", quantity: m("1"))])
        let state = try LedgerEngine.replay(accounts: [account], events: buys + [sale])
        #expect(state.realizations[0].lotID == "b-lot")
        #expect(try totalPnL(state) == m("10"))
        let specified = LedgerAccount(id: account.id, name: account.name, costBasisMethod: .specificLot)
        #expect(throws: LedgerError.invalidLotSelection) {
            try LedgerEngine.replay(accounts: [specified], events: buys + [stockSell("missing", 3, quantity: "1", price: "30")])
        }
        #expect(throws: LedgerError.invalidLotSelection) {
            try LedgerEngine.replay(accounts: [account], events: buys + [stockSell("over", 3, quantity: "3", price: "30", selections: [LedgerLotSelection(lotID: "b-lot", quantity: m("3"))])])
        }
    }

    @Test func weightedCloseRemainderUsesAscendingLotIDsIncludingNegativeProceeds() throws {
        let buys = [try stockBuy("c", 1, quantity: "1", price: "1"), try stockBuy("a", 2, quantity: "1", price: "1"), try stockBuy("b", 3, quantity: "1", price: "1")]
        let positive = try LedgerEngine.replay(accounts: [account], events: buys + [stockSell("close", 4, quantity: "3", price: "0.34", fee: "0.02")])
        #expect(positive.realizations.map(\.lotID) == ["a-lot", "b-lot", "c-lot"])
        #expect(positive.realizations.map(\.netProceedsOrCloseCost) == [try m("0.33"), try m("0.33"), try m("0.34")])
        let negative = try LedgerEngine.replay(accounts: [account], events: buys + [stockSell("close", 4, quantity: "3", price: "0", fee: "1")])
        #expect(negative.realizations.map(\.netProceedsOrCloseCost) == [try m("-0.33"), try m("-0.33"), try m("-0.34")])
        #expect(try totalPnL(negative) == m("-4"))
    }

    @Test func completeWheelWithRollCountsEachPremiumAndFeeExactlyOnce() throws {
        let old = try option(version: "old"), current = try option(version: "next"), call = try option(.call)
        func open(_ id: String, _ at: TimeInterval, _ o: LedgerOptionVersion, price: String, roll: String? = nil) throws -> LedgerEvent {
            event(id, at, .trade(LedgerTrade(instrument: .option(o), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m(price), fee: try m("2"), openingLotID: id + "-lot", strategy: strategy())), roll: roll)
        }
        let events = [event("deposit", 0, .cash(LedgerCashEntry(kind: .deposit, amount: try m("20000")))),
            try open("put1", 1, old, price: "2"),
            event("close1", 2, .trade(LedgerTrade(instrument: .option(old), side: .buy, effect: .close, quantity: try m("1"), unitPrice: try m("0.5"), fee: try m("1"))), roll: "roll"),
            try open("put2", 3, current, price: "3", roll: "roll"),
            event("assigned", 4, .optionSettlement(LedgerOptionSettlement(contract: current, action: .assignment, side: .short, quantity: try m("1"), fee: try m("1"), acquiredLotIDs: [stock.id: "shares"], evidence: "actual assignment"))),
            try open("call", 5, call, price: "2"),
            event("called", 6, .optionSettlement(LedgerOptionSettlement(contract: call, action: .assignment, side: .short, quantity: try m("1"), fee: try m("1"), evidence: "actual call assignment")))]
        let state = try LedgerEngine.replay(accounts: [account], events: events)
        // Cash independently: 20,000 +198 -51 +298 -10,001 +198 +9,999 =20,641.
        #expect(state.cashByAccount[account.id] == (try m("20641")))
        #expect(state.lots.allSatisfy { $0.isClosed })
        #expect(try totalPnL(state) == m("641"))
        #expect(state.realizations.filter { $0.lotID == "put1-lot" }.map(\.pnl) == [try m("147")])
        #expect(state.realizations.filter { $0.lotID == "put2-lot" || $0.lotID == "call-lot" }.allSatisfy { $0.pnl.amount == 0 })
        #expect(state.realizations.first { $0.lotID == "shares" }?.removedManagementCost == (try m("9703")))
        #expect(state.realizations.first { $0.lotID == "shares" }?.netProceedsOrCloseCost == (try m("10197")))
    }

    @Test func longCallAndShortPutFollowIndependentApprovedCostVectors() throws {
        for (side, right, action, expected) in [(LedgerSide.buy, LedgerOptionRight.call, LedgerSettlementAction.exercise, "10203"), (.sell, .put, .assignment, "9803")] {
            let contract = try option(right)
            let events = [event("open", 0, .trade(LedgerTrade(instrument: .option(contract), side: side, effect: .open, quantity: try m("1"), unitPrice: try m("2"), fee: try m("2"), openingLotID: "option", strategy: strategy()))),
                          event("settle", 1, .optionSettlement(LedgerOptionSettlement(contract: contract, action: action, side: side == .buy ? .long : .short, quantity: try m("1"), fee: try m("1"), acquiredLotIDs: [stock.id: "shares"], evidence: "oracle")))]
            let state = try LedgerEngine.replay(accounts: [account], events: events)
            #expect(state.lots.first { $0.id == "shares" }?.managementCostRemaining == (try m(expected)))
            #expect(try totalPnL(state) == m("0"))
            #expect(state.cashByAccount[account.id] == (try m(expected).multiplied(by: "-1")))
        }
    }

    @Test func longPutExerciseUsesNetDebitOnceAndRequiresOwnedShares() throws {
        let contract = try option()
        let put = event("put", 1, .trade(LedgerTrade(instrument: .option(contract), side: .buy, effect: .open, quantity: try m("1"), unitPrice: try m("2"), fee: try m("2"), openingLotID: "put", strategy: strategy())))
        let exercise = event("exercise", 2, .optionSettlement(LedgerOptionSettlement(contract: contract, action: .exercise, side: .long, quantity: try m("1"), fee: try m("1"), evidence: "oracle")))
        let state = try LedgerEngine.replay(accounts: [account], events: [stockBuy("stock", 0, quantity: "100", price: "90"), put, exercise])
        #expect(state.realizations.first { $0.lotID == "stock-lot" }?.netProceedsOrCloseCost == (try m("9797")))
        #expect(try totalPnL(state) == m("797"))
        #expect(throws: LedgerError.insufficientLots) { try LedgerEngine.replay(accounts: [account], events: [put, exercise]) }
    }

    @Test func partialAssignmentTransfersOnlyMatchedNetPremium() throws {
        let contract = try option()
        let open = event("open", 0, .trade(LedgerTrade(instrument: .option(contract), side: .sell, effect: .open, quantity: try m("3"), unitPrice: try m("1"), fee: try m("0.01"), openingLotID: "option", strategy: strategy())))
        let assigned = event("assign", 1, .optionSettlement(LedgerOptionSettlement(contract: contract, action: .assignment, side: .short, quantity: try m("1"), fee: try m("0"), acquiredLotIDs: [stock.id: "shares"], evidence: "one contract")))
        let state = try LedgerEngine.replay(accounts: [account], events: [open, assigned])
        #expect(state.lots.first { $0.id == "option" }?.managementCostRemaining == (try m("200")))
        #expect(state.lots.first { $0.id == "shares" }?.managementCostRemaining == (try m("9900.01")))
        #expect(state.lots.first { $0.id == "shares" }?.originatingOptionLotIDs == ["option"])
    }

    @Test func expirationRealizesNetPremiumAndRejectsEarlyExpiration() throws {
        let contract = try option()
        for side in [LedgerSide.buy, .sell] {
            let open = event("open", 0, .trade(LedgerTrade(instrument: .option(contract), side: side, effect: .open, quantity: try m("1"), unitPrice: try m("2"), fee: try m("2"), openingLotID: "option", strategy: strategy())))
            let settle = LedgerOptionSettlement(contract: contract, action: .expiration, side: side == .buy ? .long : .short, quantity: try m("1"), fee: try m("1"), evidence: "expiration evidence")
            #expect(throws: LedgerError.invalidContract) { try LedgerEngine.replay(accounts: [account], events: [open, event("early", 1, .optionSettlement(settle))]) }
            let state = try LedgerEngine.replay(accounts: [account], events: [open, event("expired", 2000, .optionSettlement(settle))])
            #expect(try totalPnL(state) == m(side == .buy ? "-203" : "197"))
            #expect(state.lots.allSatisfy { $0.isClosed })
        }
    }

    @Test func adjustedDeliverableUsesConfirmedUnitsAndCashNotOneHundred() throws {
        let contract = LedgerOptionVersion(occSymbol: "ABC1  231117P00100000", versionID: "adjusted", effectiveFrom: base.addingTimeInterval(-1),
            quoteMultiplier: try m("100"), exerciseConsideration: try m("10000"), deliverables: [LedgerDeliverable(security: stock, quantity: try m("25"), basisWeight: try m("1"))],
            deliverableCash: try m("7500"), tradingEndsAt: base.addingTimeInterval(100), exerciseDeadline: base.addingTimeInterval(200), settlementAt: base.addingTimeInterval(300), memoReferences: ["explicit adjusted delivery"])
        let events = [event("open", 0, .trade(LedgerTrade(instrument: .option(contract), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m("2"), fee: try m("2"), openingLotID: "option", strategy: strategy()))),
            event("assign", 1, .optionSettlement(LedgerOptionSettlement(contract: contract, action: .assignment, side: .short, quantity: try m("1"), fee: try m("1"), acquiredLotIDs: [stock.id: "shares"], evidence: "adjusted contract assignment")))]
        let state = try LedgerEngine.replay(accounts: [account], events: events)
        #expect(state.lots.first { $0.id == "shares" }?.quantityRemaining == (try m("25")))
        #expect(state.lots.first { $0.id == "shares" }?.managementCostRemaining == (try m("2303")))
        #expect(state.cashByAccount[account.id] == (try m("-2303")))
    }

    @Test func contractAdjustmentKeepsPremiumAndSwitchesImmutableDeliveryVersion() throws {
        let before = try option(), after = try option(version: "adjusted", units: "50")
        let events = [event("open", 0, .trade(LedgerTrade(instrument: .option(before), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m("2"), fee: try m("2"), openingLotID: "option", strategy: strategy()))),
            event("adjust", 1, .contractAdjustment(LedgerContractAdjustment(previous: before, replacement: after, contractQuantityRatio: try m("1"), evidence: "memo", confirmedBy: "user"))),
            event("assign", 2, .optionSettlement(LedgerOptionSettlement(contract: after, action: .assignment, side: .short, quantity: try m("1"), fee: try m("1"), acquiredLotIDs: [stock.id: "shares"], evidence: "adjusted assignment")))]
        let state = try LedgerEngine.replay(accounts: [account], events: events)
        #expect(state.lots.first { $0.id == "shares" }?.quantityRemaining == (try m("50")))
        #expect(state.lots.first { $0.id == "shares" }?.managementCostRemaining == (try m("9803")))
    }

    @Test func negativeEconomicBasisIsPreservedAndNotPresentedAsTaxBasis() throws {
        let contract = try option(consideration: "100")
        let events = [event("open", 0, .trade(LedgerTrade(instrument: .option(contract), side: .sell, effect: .open, quantity: try m("1"), unitPrice: try m("2"), fee: try m("0"), openingLotID: "option", strategy: strategy()))),
            event("assign", 1, .optionSettlement(LedgerOptionSettlement(contract: contract, action: .assignment, side: .short, quantity: try m("1"), fee: try m("0"), acquiredLotIDs: [stock.id: "shares"], evidence: "synthetic")))]
        let state = try LedgerEngine.replay(accounts: [account], events: events)
        let shares = try #require(state.lots.first { $0.id == "shares" })
        #expect(shares.hasNegativeEconomicBasis)
        #expect(shares.managementCostRemaining == (try m("-100")))
        #expect(shares.userReportedOriginalTaxBasis == nil)
    }

    @Test func splitAndOfficialFractionCashPreserveCostAndQuantity() throws {
        let buy = try stockBuy("buy", 0, quantity: "10", price: "80")
        let split = event("split", 1, .split(LedgerSplit(securityID: stock.id, ratio: try m("2"), evidence: "official 2:1", confirmedBy: "user")))
        let forward = try LedgerEngine.replay(accounts: [account], events: [buy, split])
        #expect(forward.lots[0].quantityRemaining == (try m("20")))
        #expect(forward.lots[0].managementCostRemaining == (try m("800")))
        let reverse = event("reverse", 2, .split(LedgerSplit(securityID: stock.id, ratio: try m("0.075"), fractions: [LedgerSplitFraction(lotID: "buy-lot", quantityDisposed: try m("0.5"), cash: try m("300"))], evidence: "official reverse split cash", confirmedBy: "user")))
        let state = try LedgerEngine.replay(accounts: [account], events: [buy, split, reverse])
        #expect(state.lots[0].quantityRemaining == (try m("1")))
        #expect(state.lots[0].managementCostRemaining == (try m("533.34")))
        #expect(state.realizations[0].removedManagementCost == (try m("266.66")))
        #expect(try totalPnL(state) == m("33.34"))
    }

    @Test func spinoffAllocationAndSubsequentMergerKeepTotalCost() throws {
        let child = LedgerSecurity(id: "child", symbol: "CHILD"), merged = LedgerSecurity(id: "merged", symbol: "MERGED")
        let buy = try stockBuy("buy", 0, quantity: "10", price: "80")
        let spin = event("spin", 1, .reorganization(LedgerReorganization(kind: .spinoff, rows: [LedgerReorganizationRow(sourceLotID: "buy-lot", outputs: [
            LedgerReorganizationOutput(lotID: "parent", security: stock, quantity: try m("10"), basisWeight: try m("0.75")),
            LedgerReorganizationOutput(lotID: "child", security: child, quantity: try m("5"), basisWeight: try m("0.25"))])], evidence: "confirmed official allocation", confirmedBy: "user")))
        let merger = event("merge", 2, .reorganization(LedgerReorganization(kind: .merger, rows: [LedgerReorganizationRow(sourceLotID: "child", outputs: [LedgerReorganizationOutput(lotID: "merged", security: merged, quantity: try m("2"), basisWeight: try m("1"))])], evidence: "merger allocation", confirmedBy: "user")))
        let state = try LedgerEngine.replay(accounts: [account], events: [buy, spin, merger])
        #expect(state.lots.first { $0.id == "parent" }?.managementCostRemaining == (try m("600")))
        #expect(state.lots.first { $0.id == "merged" }?.managementCostRemaining == (try m("200")))
        #expect(state.lots.first { $0.id == "merged" }?.acquiredAt == base)
        #expect(try state.lots.reduce(m("0")) { try $0.adding($1.managementCostRemaining) } == m("800"))
        #expect(try totalPnL(state) == m("0"))
    }

    @Test func returnOfCapitalClipsOnlyItsReductionAndSeparatesExcess() throws {
        let buy = try stockBuy("buy", 0, quantity: "1", price: "80")
        for (distribution, remaining, excess) in [("30", "50", "0"), ("100", "0", "20")] {
            let roc = event("roc", 1, .returnOfCapital(LedgerReturnOfCapital(allocations: ["buy-lot": try m(distribution)], evidence: "official ROC", confirmedBy: "user")))
            let state = try LedgerEngine.replay(accounts: [account], events: [buy, roc])
            #expect(state.lots[0].managementCostRemaining == (try m(remaining)))
            #expect(try totalPnL(state) == m(excess))
            #expect(state.realizations.allSatisfy { $0.kind == .rocExcess })
        }
    }

    @Test func transfersKeepHistoricalCostAndSeparateExternalMarketValueBridge() throws {
        let incoming = event("transfer-in", 1, .transferIn(LedgerTransferIn(lotID: "transferred", instrument: .equity(stock), quantity: try m("10"), historicalCost: try m("80"), acquiredAt: base.addingTimeInterval(-86400), eventMarketValue: try m("120"), userReportedTaxBasis: try m("75"), evidence: "confirmed transfer statement")))
        let outgoing = event("transfer-out", 2, .transferOut(LedgerTransferOut(instrument: .equity(stock), quantity: try m("5"), eventMarketValue: try m("65"), evidence: "confirmed transfer value")))
        let state = try LedgerEngine.replay(accounts: [account], events: [incoming, outgoing])
        #expect(state.lots[0].managementCostRemaining == (try m("40")))
        #expect(state.lots[0].userReportedOriginalTaxBasis == (try m("75")))
        #expect(state.postings.map(\.externalFlow) == [try m("120"), try m("-65")])
        #expect(state.postings.map(\.transferredEmbeddedGain) == [try m("40"), try m("-25")])
        #expect(state.cashByAccount[account.id] == (try m("0")))
        #expect(state.realizations.isEmpty)
    }

    @Test func appendReversalReplaysDependentsAndDoesNotDestroyAuditHistory() throws {
        let buy = try stockBuy("buy", 0, quantity: "10", price: "10")
        let sell = try stockSell("sell", 2, quantity: "5", price: "20")
        let reversal = event("void", 3, .reversal(LedgerReversal(originalEventID: "buy", reason: "broker correction")))
        #expect(throws: LedgerError.insufficientLots) { try LedgerEngine.replay(accounts: [account], events: [buy, sell, reversal]) }
        let replacement = try stockBuy("corrected", 0, quantity: "10", price: "11")
        let state = try LedgerEngine.replay(accounts: [account], events: [buy, sell, reversal, replacement])
        #expect(state.auditEventIDs == ["buy", "sell", "void", "corrected"])
        #expect(state.activeEventIDs == ["corrected", "sell"])
        #expect(state.reversedEventIDs == ["buy"])
        #expect(state.realizations[0].removedManagementCost == (try m("55")))
        #expect(try totalPnL(state) == m("45"))
        let twice = event("void-again", 4, .reversal(LedgerReversal(originalEventID: "buy", reason: "duplicate")))
        #expect(throws: LedgerError.invalidReversal) { try LedgerEngine.replay(accounts: [account], events: [buy, reversal, twice]) }
    }

    @Test func ambiguousSameInstantCorporateSequenceAndInvalidAllocationAreRejected() throws {
        let buy = try stockBuy("buy", 0, quantity: "10", price: "10")
        let split = event("split", 0, .split(LedgerSplit(securityID: stock.id, ratio: try m("2"), evidence: "split", confirmedBy: "user")))
        #expect(throws: LedgerError.ambiguousOrdering) { try LedgerEngine.replay(accounts: [account], events: [buy, split]) }
        let reorg = event("reorg", 1, .reorganization(LedgerReorganization(kind: .spinoff, rows: [LedgerReorganizationRow(sourceLotID: "buy-lot", outputs: [LedgerReorganizationOutput(lotID: "new", security: stock, quantity: try m("10"), basisWeight: try m("0.9"))])], evidence: "bad weights", confirmedBy: "user")))
        #expect(throws: LedgerError.invalidCorporateAction) { try LedgerEngine.replay(accounts: [account], events: [buy, reorg]) }
    }

    @Test func replayIsStableAcrossJSONRoundTripAndSeparatesCashCategories() throws {
        let cash = try zip([LedgerCashKind.deposit, .withdrawal, .dividend, .interest, .fee, .dividendWithholding, .interestWithholding, .otherTax], ["1000", "100", "10", "2", "3", "1", "0.2", "0.3"]).enumerated().map { i, pair in
            event("cash-\(i)", Double(i), .cash(LedgerCashEntry(kind: pair.0, amount: try m(pair.1))))
        }
        let expected = try LedgerEngine.replay(accounts: [account], events: cash)
        #expect(expected.cashByAccount[account.id] == (try m("907.5")))
        #expect(expected.postings.map(\.externalFlow) == [try m("1000"), try m("-100"), try m("0"), try m("0"), try m("0"), try m("0"), try m("0"), try m("0")])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode([LedgerEvent].self, from: encoder.encode(cash))
        #expect(try LedgerEngine.replay(accounts: [account], events: decoded) == expected)
        #expect(expected.engineVersion == LedgerEngine.version)
        #expect(expected.parameterVersion == "PARAMETERS_V1")
        #expect(expected.numericPolicyVersion == Money.numericPolicyVersion)
    }
    @Test func mergerCashAndStockAllocationReconcilesAndPureCashMergerCloses() throws {
        let buy = try stockBuy("buy", 0, quantity: "10", price: "10")
        let new = LedgerSecurity(id: "new", symbol: "NEW")
        let mixed = event("merger", 1, .reorganization(LedgerReorganization(kind: .merger,
            rows: [LedgerReorganizationRow(sourceLotID: "buy-lot", outputs: [LedgerReorganizationOutput(lotID: "replacement", security: new, quantity: try m("5"), basisWeight: try m("0.6"))], netCashConsideration: try m("50"), cashBasisWeight: try m("0.4"))], evidence: "official stock and net cash allocation", confirmedBy: "user")))
        let state = try LedgerEngine.replay(accounts: [account], events: [buy, mixed])
        #expect(state.lots.first { $0.id == "replacement" }?.managementCostRemaining == (try m("60")))
        #expect(state.cashByAccount[account.id] == (try m("-50")))
        #expect(try totalPnL(state) == m("10"))
        let cash = event("cash-merger", 1, .reorganization(LedgerReorganization(kind: .merger,
            rows: [LedgerReorganizationRow(sourceLotID: "buy-lot", outputs: [], netCashConsideration: try m("120"), cashBasisWeight: try m("1"))], evidence: "official all cash consideration", confirmedBy: "user")))
        let closed = try LedgerEngine.replay(accounts: [account], events: [buy, cash])
        #expect(closed.lots.allSatisfy { $0.isClosed })
        #expect(try totalPnL(closed) == m("20"))
    }

    @Test func correctionCanRepairMistakenFutureEconomicDate() throws {
        let wrong = try stockBuy("wrong", 10_000, quantity: "1", price: "10")
        let reverse = event("reverse", 0, .reversal(LedgerReversal(originalEventID: wrong.id, reason: "incorrect future timestamp")))
        let replacement = try stockBuy("corrected", -1, quantity: "1", price: "11")
        let state = try LedgerEngine.replay(accounts: [account], events: [wrong, reverse, replacement])
        #expect(state.activeEventIDs == ["corrected"])
        #expect(state.cashByAccount[account.id] == (try m("-11")))
        #expect(state.reversedEventIDs == ["wrong"])
    }

}
