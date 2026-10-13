import Foundation
import Testing
import CoreDomain
@testable import PortfolioEngine

@Suite("Portfolio complete strategy rounds")
struct PerformanceRoundTests {
    let f = LedgerEngineTests()
    func input(_ events: [LedgerEvent], allocations: [PerformanceRoundAllocation] = [], income: [PerformanceIncomeAllocation] = []) -> PerformanceInput {
        let source = PerformanceEvidence(id: "fixture", source: "synthetic", kind: .synthetic, availableAt: f.base.addingTimeInterval(-1), reference: "independent round oracle", rawDocument: Data("fixture".utf8))
        let request = PerformanceRequest(accountID: f.account.id, calculatedAt: f.base.addingTimeInterval(5000), calendar: .init(tradingDays: ["2023-11-14"], evidence: source), days: [], roundAllocations: allocations, incomeAllocations: income)
        return PerformanceInput(request: request, ledgerRevision: UUID(), accounts: [f.account], events: events)
    }
    func calculate(_ events: [LedgerEvent], allocations: [PerformanceRoundAllocation] = [], income: [PerformanceIncomeAllocation] = []) throws -> [PerformanceRound] {
        let state = try LedgerEngine.replay(accounts: [f.account], events: events)
        return try PerformanceRounds.calculate(input: input(events, allocations: allocations, income: income), state: state, activeEvents: events)
    }
    func open(_ id: String, _ at: TimeInterval, _ option: LedgerOptionVersion, price: String, fee: String = "2", roll: String? = nil, purpose: LedgerStrategy? = nil) throws -> LedgerEvent {
        f.event(id, at, .trade(.init(instrument: .option(option), side: .sell, effect: .open, quantity: try f.m("1"), unitPrice: try f.m(price), fee: try f.m(fee), openingLotID: id, strategy: purpose ?? f.strategy())), roll: roll)
    }
    func wheel() throws -> [LedgerEvent] {
        let old = try f.option(version: "old"), put = try f.option(version: "new"), call = try f.option(.call)
        return [try open("put1", 1, old, price: "2"),
            f.event("close1", 2, .trade(.init(instrument: .option(old), side: .buy, effect: .close, quantity: try f.m("1"), unitPrice: try f.m("0.5"), fee: try f.m("1"))), roll: "roll"),
            try open("put2", 3, put, price: "3", roll: "roll"),
            f.event("assignPut", 4, .optionSettlement(.init(contract: put, action: .assignment, side: .short, quantity: try f.m("1"), fee: try f.m("1"), acquiredLotIDs: [f.stock.id: "shares"], evidence: "assignment"))),
            try open("call", 5, call, price: "2"),
            f.event("assignCall", 6, .optionSettlement(.init(contract: call, action: .assignment, side: .short, quantity: try f.m("1"), fee: try f.m("1"), evidence: "assignment")))]
    }
    @Test func wheelSeparatesRollAndCountsStockAndOptionCashOnlyOnce() throws {
        let rounds = try calculate(wheel())
        #expect(rounds.count == 3)
        #expect(rounds.allSatisfy { $0.economicState == .closed })
        #expect(rounds.first { $0.id == "put1" }?.netPnL == (try Money("147")))
        #expect(rounds.first { $0.id == "put2" }?.netPnL == (try Money("297")))
        #expect(rounds.first { $0.id == "call" }?.netPnL == (try Money("197")))
        #expect(try rounds.reduce(Money("0")) { try $0.adding($1.netPnL!) } == Money("641"))
        let stats = try PerformanceRounds.statistics(rounds)
        #expect(stats.eligibleN == 3)
        #expect(stats.winRate.value == nil)
    }
    @Test func groupingUsesSharedUnderlyingWithoutDoubleCountingRounds() throws {
        let call = try f.option(.call)
        let events = [try f.stockBuy("stock", 0, quantity: "100", price: "90"), try open("call", 1, call, price: "2"),
            f.event("assignment", 2, .optionSettlement(.init(contract: call, action: .assignment, side: .short, quantity: try f.m("1"), fee: try f.m("1"), evidence: "fixture")))]
        let rounds = try calculate(events)
        let groups = try PerformanceGrouping.summarize(rounds: rounds, input: input(events))
        let underlying = groups.filter { $0.axis == .underlying }
        #expect(underlying.count == 1)
        #expect(underlying[0].label == "ABC")
        #expect(underlying[0].roundIDs.count == 2)
        #expect(underlying[0].statistics.eligibleN == 2)
        #expect(underlying[0].completedNetPnL == (try Money("1197")))
        #expect(try groups.filter { $0.axis == .strategy }.reduce(Money("0")) { try $0.adding($1.completedNetPnL!) } == Money("1197"))
    }
    @Test func groupingIgnoresReversedLaterOpeningWithReusedLotID() throws {
        let other = LedgerSecurity(id: "wrong", symbol: "WRONG")
        let events = [try f.stockBuy("stock", 0, quantity: "1", price: "10"),
            f.event("wrong", 1, .trade(.init(instrument: .equity(other), side: .buy, effect: .open, quantity: try Money("1"), unitPrice: try Money("50"), fee: try Money("0"), openingLotID: "stock-lot"))),
            f.event("void", 2, .reversal(.init(originalEventID: "wrong", reason: "wrong security and duplicate lot"))),
            try f.stockSell("close", 3, quantity: "1", price: "12")]
        let rounds = try calculate(events)
        let groups = try PerformanceGrouping.summarize(rounds: rounds, input: input(events)).filter { $0.axis == .underlying }
        #expect(groups.count == 1)
        #expect(groups[0].label == "ABC")
        #expect(groups[0].completedNetPnL == (try Money("2")))
    }
    @Test func assignmentDoesNotCloseEconomicRoundUntilSharesDisposed() throws {
        let events = Array(try wheel().prefix(4))
        let result = try calculate(events)
        let assigned = try #require(result.first { $0.id == "put2" })
        #expect(assigned.economicState == .open)
        #expect(assigned.relatedLotIDs == ["put2", "shares"])
        #expect(try PerformanceRounds.statistics(result).eligibleN == 1)
    }
    @Test func coveredCallAndProtectivePutDoNotDuplicateUnderlyingPnL() throws {
        let call = try f.option(.call)
        let events = [try f.stockBuy("stock", 0, quantity: "100", price: "90"), try open("call", 1, call, price: "2"),
            f.event("assignment", 2, .optionSettlement(.init(contract: call, action: .assignment, side: .short, quantity: try f.m("1"), fee: try f.m("1"), evidence: "fixture")))]
        let result = try calculate(events)
        #expect(result.first { $0.id == "stock-lot" }?.netPnL == (try Money("1000")))
        #expect(result.first { $0.id == "call" }?.netPnL == (try Money("197")))
        let put = try f.option()
        let protective = [try f.stockBuy("stock", 0, quantity: "100", price: "90"),
            f.event("put", 1, .trade(.init(instrument: .option(put), side: .buy, effect: .open, quantity: try f.m("1"), unitPrice: try f.m("2"), fee: try f.m("2"), openingLotID: "put", strategy: f.strategy()))),
            f.event("exercise", 2, .optionSettlement(.init(contract: put, action: .exercise, side: .long, quantity: try f.m("1"), fee: try f.m("1"), evidence: "fixture")))]
        let protected = try calculate(protective)
        #expect(protected.first { $0.id == "stock-lot" }?.netPnL == (try Money("1000")))
        #expect(protected.first { $0.id == "put" }?.netPnL == (try Money("-203")))
    }
    @Test func sharedAssignmentRequiresExplicitFractionsAndConservesCents() throws {
        let option = try f.option()
        let events = [try open("a", 1, option, price: "1", fee: "0"), try open("b", 2, option, price: "1", fee: "0"),
            f.event("assignment", 3, .optionSettlement(.init(contract: option, action: .assignment, side: .short, quantity: try f.m("2"), fee: try f.m("0"), acquiredLotIDs: [f.stock.id: "shares"], evidence: "fixture"))),
            try f.stockSell("sale", 4, quantity: "200", price: "100", fee: "0.01")]
        let unresolved = try calculate(events)
        #expect(unresolved.allSatisfy { $0.economicState == .allocationRequired && $0.netPnL == nil })
        let evidence = input(events).request.calendar.evidence
        let allocated = try calculate(events, allocations: [.init(lotID: "shares", roundLotID: "a", fraction: Money("0.5"), evidence: evidence), .init(lotID: "shares", roundLotID: "b", fraction: Money("0.5"), evidence: evidence)])
        #expect(allocated.first { $0.id == "a" }?.netPnL == (try Money("99.99")))
        #expect(allocated.first { $0.id == "b" }?.netPnL == (try Money("100")))
        let negativeEvents = Array(events.dropLast()) + [try f.stockSell("sale", 4, quantity: "200", price: "100", fee: "200.01")]
        let negative = try calculate(negativeEvents, allocations: [.init(lotID: "shares", roundLotID: "a", fraction: Money("0.5"), evidence: evidence), .init(lotID: "shares", roundLotID: "b", fraction: Money("0.5"), evidence: evidence)])
        #expect(negative.first { $0.id == "a" }?.netPnL == (try Money("0")))
        #expect(negative.first { $0.id == "b" }?.netPnL == (try Money("-0.01")))
        #expect(throws: PerformanceError.invalidInput) {
            try calculate(events, allocations: [.init(lotID: "shares", roundLotID: "a", fraction: Money("0.5"), evidence: evidence)])
        }
    }
    @Test func transferDoesNotManufactureACompletedProfitableRound() throws {
        let option = try f.option()
        let events = [try open("put", 1, option, price: "2"),
            f.event("assign", 2, .optionSettlement(.init(contract: option, action: .assignment, side: .short, quantity: try f.m("1"), fee: try f.m("0"), acquiredLotIDs: [f.stock.id: "shares"], evidence: "fixture"))),
            f.event("transfer", 3, .transferOut(.init(instrument: .equity(f.stock), quantity: try f.m("100"), eventMarketValue: try f.m("11000"), evidence: "transfer statement")))]
        let result = try calculate(events)
        #expect(result[0].economicState == .transferredUnresolved)
        #expect(result[0].netPnL == nil)
        #expect(try PerformanceRounds.statistics(result).eligibleN == 0)
    }
    @Test func acquireSharesUnassignedIsSeparateFromProfitWin() throws {
        let option = try f.option()
        let strategy = LedgerStrategy(id: "acquire", purpose: .acquireShares, successDefinition: "Acquire below 100", maximumAcquisitionPrice: try f.m("100"), unassignedCountsAsSuccess: true)
        let events = [try open("put", 1, option, price: "2", purpose: strategy),
            f.event("expire", 2000, .optionSettlement(.init(contract: option, action: .expiration, side: .short, quantity: try f.m("1"), fee: try f.m("0"), evidence: "expired")))]
        let result = try calculate(events), stats = try PerformanceRounds.statistics(result)
        #expect(result[0].purposeState == .unassigned)
        #expect(stats.wins == 1)
        #expect(stats.unassigned == 1)
        #expect(stats.successes == 0)
        #expect(stats.purposeSuccessRate.sampleCount == 0)
    }
    @Test func explicitIncomeAllocationIsRequiredAndRecognizedOnce() throws {
        let events = [try f.stockBuy("stock", 0, quantity: "10", price: "10"),
            f.event("income", 1, .cash(.init(kind: .dividend, amount: try Money("5"), securityID: f.stock.id))),
            try f.stockSell("close", 2, quantity: "10", price: "11")]
        let missing = try calculate(events)
        #expect(missing[0].netPnL == nil)
        let source = input(events).request.calendar.evidence
        let result = try calculate(events, income: [.init(ledgerEventID: "income", roundLotID: "stock-lot", amount: Money("5"), evidence: source)])
        #expect(result[0].netPnL == (try Money("15")))
        let paidAfterSale = [events[0], try f.stockSell("close", 2, quantity: "10", price: "11"),
            f.event("income", 3, .cash(.init(kind: .dividend, amount: try Money("5"), securityID: f.stock.id)))]
        #expect(try calculate(paidAfterSale)[0].netPnL == nil)
        #expect(try calculate(paidAfterSale, income: [.init(ledgerEventID: "income", roundLotID: "stock-lot", amount: Money("5"), evidence: source)])[0].netPnL == Money("15"))
        #expect(throws: PerformanceError.invalidInput) { try calculate(events, income: [.init(ledgerEventID: "income", roundLotID: "stock-lot", amount: Money("6"), evidence: source)]) }
    }
    func round(_ id: Int, pnl: String) throws -> PerformanceRound {
        PerformanceRound(roundLotID: String(id), strategy: nil, familyID: nil, economicState: .closed, accountingState: .available, purposeState: .unverified,
            netPnL: try Money(pnl), relatedLotIDs: [String(id)], closedAt: f.base.addingTimeInterval(Double(id)), reason: "independent stats oracle")
    }
    @Test func zeroRoundsAreNotLossesAndSmallSamplesHideEstimates() throws {
        let stats = try PerformanceRounds.statistics([round(0, pnl: "100"), round(1, pnl: "-50"), round(2, pnl: "0")])
        #expect(stats.eligibleN == 3 && stats.wins == 1 && stats.losses == 1 && stats.zeros == 1)
        #expect(stats.winRate.value == nil && stats.lossRate.value == nil && stats.expectancy.value == nil)
        let empty = try PerformanceRounds.statistics([])
        #expect(empty.winRate.value == nil && empty.profitFactor.value == nil)
    }
    @Test func thirtyRoundsUseAbsoluteLossMeanAndSeparateInfinity() throws {
        let mixed = try (0..<30).map { try round($0, pnl: $0 < 15 ? "10" : "-10") }
        let stats = try PerformanceRounds.statistics(mixed)
        #expect(stats.winRate.value == 0.5 && stats.lossRate.value == 0.5)
        #expect(stats.averageWin.value == 10 && stats.averageLoss.value == 10)
        #expect(stats.expectancy.value == 0 && stats.profitFactor.value == 1)
        #expect(stats.maximumConsecutiveLosses == 15)
        #expect(stats.winRateInterval.sampleCount == stats.winRate.sampleCount)
        #expect(abs(try #require(stats.winRateInterval.low) - 0.3315412564053376) < 1e-12)
        #expect(abs(try #require(stats.winRateInterval.high) - 0.6684587435946624) < 1e-12)
        #expect(stats.purposeSuccessInterval.low == nil)
        let wins = try PerformanceRounds.statistics((0..<30).map { try round($0, pnl: "1") })
        #expect(wins.profitFactorInfinite && wins.profitFactor.value == nil && wins.averageLoss.value == nil)
        let zeros = try PerformanceRounds.statistics((0..<30).map { try round($0, pnl: "0") })
        #expect(!zeros.profitFactorInfinite && zeros.profitFactor.value == nil)
        #expect(zeros.zeros == 30 && zeros.lossRate.value == 0)
    }
}
