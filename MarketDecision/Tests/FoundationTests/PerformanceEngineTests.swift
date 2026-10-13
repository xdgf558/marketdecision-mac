import Foundation
import Testing
import CoreDomain
@testable import PortfolioEngine

struct PerformanceVectors {
    let account = LedgerAccount(id: "account", name: "Synthetic USD")
    let stock = LedgerSecurity(id: "stock", symbol: "SYN")
    func money(_ text: String) throws -> Money { try Money(text) }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func close(_ day: String) -> Date { date(day + "T21:00:00Z") }
    func evidence(_ id: String = "fixture") -> PerformanceEvidence {
        PerformanceEvidence(id: id, source: "synthetic", kind: .synthetic, availableAt: date("2020-01-01T00:00:00Z"), reference: "independent test vector", rawDocument: Data("fixture".utf8))
    }
    func event(_ id: String, at: Date, payload: LedgerPayload) -> LedgerEvent {
        LedgerEvent(id: id, accountID: account.id, effectiveAt: at,
            source: LedgerSource(sourceSystem: "synthetic", externalTransactionID: id, evidence: "independent vector"), payload: payload)
    }
    func cash(_ id: String, _ day: String, _ kind: LedgerCashKind, _ amount: String) throws -> LedgerEvent {
        event(id, at: close(day).addingTimeInterval(-3600), payload: .cash(.init(kind: kind, amount: try money(amount))))
    }
    func day(_ text: String, prices: [PerformancePrice] = [], sessions: [PerformanceSession] = []) -> PerformanceDayInput {
        PerformanceDayInput(day: text, valuationAt: close(text), sessions: sessions, prices: prices)
    }
    func input(_ days: [String], definitions: [PerformanceDayInput]? = nil, events: [LedgerEvent], accruals: [PerformanceAccrual] = [], complete: Bool = true) -> PerformanceInput {
        PerformanceInput(request: PerformanceRequest(accountID: account.id, calculatedAt: close(days.last!).addingTimeInterval(3600),
            calendar: PerformanceCalendar(tradingDays: days, evidence: evidence()), days: definitions ?? days.map { day($0) }, accruals: accruals,
            externalFlowsComplete: complete, flowCompletenessEvidence: complete ? evidence() : nil), ledgerRevision: UUID(), accounts: [account], events: events)
    }
    func valuedInput(age: TimeInterval, bid: String? = "9", ask: String? = "11", last: String? = "12", quality: [PerformancePriceQuality] = [], duplicate: Bool = false) throws -> PerformanceInput {
        let day = "2026-01-05", end = close(day), instrument = LedgerInstrument.equity(stock)
        let session = PerformanceSession(id: "session", instrumentID: instrument.identity, opensAt: end.addingTimeInterval(-23400), closesAt: end, evidence: evidence())
        let price = PerformancePrice(id: "price", instrumentID: instrument.identity, sessionID: session.id, quoteAt: end.addingTimeInterval(-age),
            bid: try bid.map(money), ask: try ask.map(money), last: try last.map(money), quality: quality, evidence: evidence())
        let prices = duplicate ? [price, PerformancePrice(id: "other", instrumentID: instrument.identity, sessionID: session.id, quoteAt: price.quoteAt, bid: try money("10"), ask: try money("12"), evidence: evidence())] : [price]
        return input([day], definitions: [self.day(day, prices: prices, sessions: [session])], events: [
            try cash("fund", day, .deposit, "100"), event("buy", at: end.addingTimeInterval(-1800), payload: .trade(.init(instrument: instrument, side: .buy, effect: .open, quantity: try money("2"), unitPrice: try money("8"), fee: try money("1"), openingLotID: "lot")))])
    }
}

@Suite("Portfolio EOD exact accounting")
struct PerformanceEngineTests {
    let f = PerformanceVectors()
    @Test func midBoundaryUsesExactPositionsAndFeeOnlyOnce() throws {
        let report = try PerformanceEngine.calculate(f.valuedInput(age: 300))
        let day = try #require(report.daily.first), position = try #require(day.positions.first)
        #expect(position.priceKind == .mid)
        #expect(day.cash == (try Money("83")))
        #expect(position.marketValue == (try Money("20")))
        #expect(position.unrealizedPnL == (try Money("3")))
        #expect(day.nav == (try Money("103")))
        #expect(report.researchOnly)
    }
    @Test func lastFallbackIsAlwaysStaleAndNeverCrossSession() throws {
        let report = try PerformanceEngine.calculate(f.valuedInput(age: 301))
        #expect(report.daily[0].positions[0].priceKind == .lastStale)
        #expect(report.daily[0].nav == (try Money("107")))
        let edge = try PerformanceEngine.calculate(f.valuedInput(age: 1800))
        #expect(edge.daily[0].positions[0].priceKind == .lastStale)
        let old = try PerformanceEngine.calculate(f.valuedInput(age: 1801))
        #expect(old.daily[0].nav == nil)
        let priorSession = try PerformanceEngine.calculate(f.valuedInput(age: 86400))
        #expect(priorSession.daily[0].nav == nil)
    }
    @Test func invalidIndicativeMissingAndConflictingMarksCannotValue() throws {
        for flag in [PerformancePriceQuality.invalid, .indicative, .missing] {
            #expect(try PerformanceEngine.calculate(f.valuedInput(age: 0, quality: [flag])).daily[0].nav == nil)
        }
        #expect(try PerformanceEngine.calculate(f.valuedInput(age: 0, duplicate: true)).daily[0].nav == nil)
        #expect(try PerformanceEngine.calculate(f.valuedInput(age: 0, bid: "11", ask: "9", last: nil)).daily[0].nav == nil)
    }
    @Test func dailyExternalFlowConventionMatchesIndependentOracles() throws {
        let days = ["2026-01-05", "2026-01-06", "2026-01-07"]
        let events = [try f.cash("start", days[0], .deposit, "100"), try f.cash("gain", days[1], .interest, "10"),
                      try f.cash("add", days[1], .deposit, "50"), try f.cash("remove", days[2], .withdrawal, "20"), try f.cash("loss", days[2], .fee, "16")]
        let report = try PerformanceEngine.calculate(f.input(days, events: events))
        #expect(report.daily.map { $0.nav?.decimalString } == ["100", "160", "124"])
        #expect(report.segments[0].returns.map(\.value) == [0.1, -0.1])
        #expect(abs(try #require(report.twr.value) + 0.01) < 1e-12)
        #expect(report.cagr.status == .notApplicable)
        #expect(report.attribution?.reconciliationDifference == (try Money("0")))
    }
    @Test func accrualPaidInCashIsNotRecognizedTwice() throws {
        let days = ["2026-01-05", "2026-01-06", "2026-01-07"]
        let events = [try f.cash("fund", days[0], .deposit, "100"), try f.cash("paid", days[2], .dividend, "5")]
        let accrual = PerformanceAccrual(id: "dividend", kind: .dividendReceivable, recognizedAt: f.close(days[1]).addingTimeInterval(-3600), amount: try Money("5"),
            settlements: [.init(ledgerEventID: "paid", amount: try Money("5"))], evidence: f.evidence())
        let report = try PerformanceEngine.calculate(f.input(days, events: events, accruals: [accrual]))
        #expect(report.daily.map { $0.nav?.decimalString } == ["100", "105", "105"])
        #expect(report.daily.map { $0.receivables?.decimalString } == ["0", "5", "0"])
        #expect(report.segments[0].returns.map(\.value) == [0.05, 0])
        #expect(report.attribution?.reconciliationDifference == (try Money("0")))
    }
    @Test func overallocatedAccrualAndDepositSettlementAreRejected() throws {
        let days = ["2026-01-05", "2026-01-06"]
        let events = [try f.cash("fund", days[0], .deposit, "100"), try f.cash("paid", days[1], .dividend, "5")]
        let a = PerformanceAccrual(id: "a", kind: .dividendReceivable, recognizedAt: f.close(days[0]), amount: try Money("6"), settlements: [.init(ledgerEventID: "paid", amount: try Money("6"))], evidence: f.evidence())
        #expect(throws: PerformanceError.invalidAccrual) { try PerformanceEngine.calculate(f.input(days, events: events, accruals: [a])) }
        let b = PerformanceAccrual(id: "b", kind: .dividendReceivable, recognizedAt: f.close(days[0]).addingTimeInterval(-7200), amount: try Money("1"), settlements: [.init(ledgerEventID: "fund", amount: try Money("1"))], evidence: f.evidence())
        #expect(throws: PerformanceError.invalidAccrual) { try PerformanceEngine.calculate(f.input(days, events: events, accruals: [b])) }
    }
    @Test func missingDailyValueBreaksTWRButNotEndpointXIRR() throws {
        let days = ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08", "2026-01-09"]
        let events = [try f.cash("fund", days[0], .deposit, "100"), try f.cash("gain", days[1], .interest, "10"), try f.cash("gain2", days[4], .interest, "22")]
        let definitions = days.enumerated().filter { $0.offset != 2 }.map { f.day($0.element) }
        let report = try PerformanceEngine.calculate(f.input(days, definitions: definitions, events: events))
        #expect(report.segments.count == 2)
        #expect(report.segments.map(\.cumulativeReturn).map { ($0 * 100).rounded() } == [10, 20])
        #expect(report.twr.value == nil)
        // This extremely short observation has a root outside the approved search range.
        #expect(report.xirr.status == .unresolved)
        #expect(report.daily[2].nav == nil)
    }
    @Test func zeroNAVEndsDrawdownAtMinusOneAndNewFundingStartsNewSegment() throws {
        let days = ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"]
        let report = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fund", days[0], .deposit, "100"), f.cash("loss", days[1], .fee, "100"), f.cash("fund2", days[2], .deposit, "100"), f.cash("gain", days[3], .interest, "10")]))
        #expect(report.segments.count == 2)
        #expect(report.risk.drawdown?.value == -1)
        #expect(report.risk.navDrawdown?.value == -1)
        #expect(report.twr.value == nil)
    }
    @Test func negativeNAVAndUnconfirmedFlowsDoNotGetPerformanceRates() throws {
        let days = ["2026-01-05", "2026-01-06"]
        let negative = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fee", days[0], .fee, "10"), f.cash("fund", days[1], .deposit, "20")]))
        #expect(negative.twr.value == nil)
        #expect(negative.xirr.value == nil)
        let unknown = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fund", days[0], .deposit, "100")], complete: false))
        #expect(unknown.twr.value == nil)
        #expect(unknown.xirr.value == nil)
    }
    @Test func optionUsesEvidencedMultiplierAndShortLiabilitySign() throws {
        let day = "2026-01-05", at = f.close(day), expiration = f.close("2026-01-16")
        let contract = LedgerOptionVersion(occSymbol: "SYN   260116P00020000", versionID: "adjusted", effectiveFrom: at.addingTimeInterval(-86400),
            quoteMultiplier: try Money("10"), exerciseConsideration: try Money("500"),
            deliverables: [.init(security: f.stock, quantity: try Money("25"), basisWeight: try Money("1"))], deliverableCash: try Money("0"),
            tradingEndsAt: expiration, exerciseDeadline: expiration.addingTimeInterval(1800), settlementAt: expiration.addingTimeInterval(86400), memoReferences: ["explicit synthetic delivery"])
        let instrument = LedgerInstrument.option(contract)
        let session = PerformanceSession(id: "option-session", instrumentID: instrument.identity, opensAt: at.addingTimeInterval(-23400), closesAt: at, evidence: f.evidence())
        let price = PerformancePrice(id: "option-mark", instrumentID: instrument.identity, sessionID: session.id, quoteAt: at, bid: try Money("2"), ask: try Money("4"), evidence: f.evidence())
        let events = [try f.cash("fund", day, .deposit, "100"), f.event("short", at: at.addingTimeInterval(-1800), payload: .trade(.init(instrument: instrument, side: .sell, effect: .open, quantity: try Money("1"), unitPrice: try Money("2"), fee: try Money("1"), openingLotID: "short", strategy: LedgerStrategy(id: "premium", purpose: .premiumIncome, successDefinition: "positive closed income"))))]
        let report = try PerformanceEngine.calculate(f.input([day], definitions: [f.day(day, prices: [price], sessions: [session])], events: events))
        #expect(report.daily[0].cash == (try Money("119")))
        #expect(report.daily[0].positions[0].side == .short)
        #expect(report.daily[0].positions[0].marketValue == (try Money("-30")))
        #expect(report.daily[0].positions[0].unrealizedPnL == (try Money("-11")))
        #expect(report.daily[0].nav == (try Money("89")))
    }
    @Test func endpointXIRRDoesNotRequireMissingIntermediateEOD() throws {
        let days = ["2025-01-02", "2025-07-01", "2026-01-02"]
        let report = try PerformanceEngine.calculate(f.input(days, definitions: [f.day(days[0]), f.day(days[2])], events: [f.cash("fund", days[0], .deposit, "100"), f.cash("income", days[2], .interest, "10")]))
        #expect(report.twr.value == nil)
        #expect(abs(try #require(report.xirr.value) - 0.1) < 1e-10)
        #expect(report.xirr.status == .available)
    }
    @Test func frozenInputRoundTripRecomputesAllOutputsExactly() throws {
        let report = try PerformanceEngine.calculate(f.valuedInput(age: 120))
        let data = try JSONEncoder().encode(report)
        let reopened = try JSONDecoder().decode(PerformanceReport.self, from: data)
        #expect(try PerformanceEngine.recompute(reopened) == report)
    }
}

@Suite("Portfolio return numerical oracles")
struct PerformanceReturnTests {
    let f = PerformanceVectors()
    @Test func xirrReportsBothApprovedRootsInsteadOfChoosing() throws {
        let r = try PerformanceXIRRSolver.solve([.init(day: "2021-01-01", amount: Money("-100")), .init(day: "2022-01-01", amount: Money("230")), .init(day: "2023-01-01", amount: Money("-132"))])
        #expect(r.status == .multipleRoots)
        #expect(r.value == nil)
        #expect(r.roots.count == 2)
        #expect(abs(r.roots[0] - 0.1) < 1e-8)
        #expect(abs(r.roots[1] - 0.2) < 1e-8)
        #expect(r.residuals.allSatisfy { $0 <= 1e-8 })
    }
    @Test func xirrSameDayNettingAndRangeRejection() throws {
        let r = try PerformanceXIRRSolver.solve([.init(day: "2021-01-01", amount: Money("-200")), .init(day: "2021-01-01", amount: Money("100")), .init(day: "2022-01-01", amount: Money("110"))])
        #expect(abs(try #require(r.value) - 0.1) < 1e-10)
        #expect(try PerformanceXIRRSolver.solve([.init(day: "2021-01-01", amount: Money("-100")), .init(day: "2022-01-01", amount: Money("1200"))]).status == .unresolved)
        #expect(try PerformanceXIRRSolver.solve([.init(day: "2021-01-01", amount: Money("100")), .init(day: "2022-01-01", amount: Money("110"))]).status == .missingInput)
    }
    @Test func monthlyAndRollingReturnsNeverCrossMissingDailyObservation() throws {
        let start = try PerformanceDates.parse("2026-01-30")
        let days = (0...31).map { PerformanceDates.calendar.date(byAdding: .day, value: $0, to: start)! }
            .filter { ![1, 7].contains(PerformanceDates.calendar.component(.weekday, from: $0)) }.map(PerformanceDates.text)
        let events = [try f.cash("fund", "2026-01-30", .deposit, "100"), try f.cash("i1", "2026-02-02", .interest, "10"),
                      try f.cash("i2", "2026-02-03", .interest, "11"), try f.cash("i3", "2026-03-02", .interest, "12.10")]
        let full = try PerformanceEngine.calculate(f.input(days, events: events))
        #expect(abs(try #require(full.monthly.first { $0.month == "2026-02" }?.result.value) - 0.21) < 1e-12)
        #expect(abs(try #require(full.monthly.first { $0.month == "2026-03" }?.result.value) - 0.1) < 1e-12)
        #expect(abs(try #require(full.rolling.first { $0.calendarDays == 30 }?.result.value) - 0.331) < 1e-12)
        let gap = try PerformanceEngine.calculate(f.input(days, definitions: days.filter { $0 != "2026-02-03" }.map { f.day($0) }, events: events))
        #expect(gap.monthly.first { $0.month == "2026-02" }?.result.value == nil)
        #expect(gap.rolling.first { $0.calendarDays == 30 }?.result.value == nil)
        #expect(abs(try #require(gap.monthly.first { $0.month == "2026-03" }?.result.value) - 0.1) < 1e-12)
    }
    @Test func alignedSPYTotalReturnsProduceIndependentBetaTwo() throws {
        let start = f.date("2026-01-01T00:00:00Z")
        let days = (0...60).map { PerformanceDates.text(start.addingTimeInterval(Double($0) * 86400)) }
        var index = 1.0
        let returns = (1...60).map { i -> PerformanceDailyReturn in
            let benchmark = i.isMultiple(of: 2) ? -1.0 / 101 : 0.01
            let value = 2 * benchmark; index *= 1 + value
            return PerformanceDailyReturn(day: days[i], startDay: days[i - 1], value: value, index: index)
        }
        let points = try days.enumerated().map { try PerformanceBenchmarkPoint(day: $0.element, totalReturnIndex: Money($0.offset.isMultiple(of: 2) ? "100" : "101"), evidence: f.evidence()) }
        let benchmark = PerformanceBenchmark(points: points, isTotalReturn: true)
        let request = PerformanceRequest(accountID: f.account.id, calculatedAt: f.close(days.last!), calendar: .init(tradingDays: days, evidence: f.evidence()), days: [], benchmark: benchmark)
        let input = PerformanceInput(request: request, ledgerRevision: UUID(), accounts: [f.account], events: [])
        let daily = try days.map { try PerformanceDailyValue(day: $0, valuationAt: f.close($0), cash: Money("100"), positions: [], receivables: Money("0"), payables: Money("0"), nav: Money("100"), externalFlow: Money("0"), status: .available, reason: "independent synthetic vector") }
        let segment = PerformanceSegment(startDay: days[0], endDay: days[60], returns: returns, cumulativeReturn: index - 1)
        let risk = try PerformanceReturns.risk(daily: daily, segments: [segment], input: input)
        #expect(abs(try #require(risk.beta.value) - 2) < 1e-12)
        #expect(risk.beta.sampleCount == 60)
        #expect(risk.beta.status == .shortSample)
    }
    @Test func earliestEqualDrawdownPeakAndTroughAreRetained() {
        let dd = PerformanceReturns.drawdown([("2026-01-01", 100), ("2026-01-02", 100), ("2026-01-03", 80), ("2026-01-04", 80), ("2026-01-05", 100)])
        #expect(dd?.peakDay == "2026-01-01")
        #expect(dd?.troughDay == "2026-01-03")
        #expect(dd?.recoveredDay == "2026-01-05")
    }
    @Test func sixtyReturnSampleUsesSampleVarianceAndCalendarRiskFree() throws {
        let start = f.date("2026-01-01T00:00:00Z")
        let days = (0...60).map { PerformanceDates.text(start.addingTimeInterval(Double($0) * 86400)) }
        var level = 1.0
        let observations = (1...60).map { i -> PerformanceDailyReturn in
            let value = i.isMultiple(of: 2) ? -0.01 : 0.01; level *= 1 + value
            return PerformanceDailyReturn(day: days[i], startDay: days[i - 1], value: value, index: level)
        }
        let segment = PerformanceSegment(startDay: days[0], endDay: days[60], returns: observations, cumulativeReturn: level - 1)
        let curve = PerformanceRateCurve(id: "rate", source: .explicitUserConstant, observationAt: start, validFrom: start, validThrough: start.addingTimeInterval(100 * 86400), points: [.init(termYears: 1, annualRate: try Money("5"), unit: .annualPercent)], evidence: PerformanceEvidence(id: "rate-source", source: "synthetic", kind: .synthetic, availableAt: start, reference: "fixed 5 percent", rawDocument: Data("5".utf8)))
        let request = PerformanceRequest(accountID: f.account.id, calculatedAt: start.addingTimeInterval(100 * 86400), calendar: .init(tradingDays: days, evidence: f.evidence()), days: days.map { f.day($0) }, rateCurves: [curve])
        let input = PerformanceInput(request: request, ledgerRevision: UUID(), accounts: [f.account], events: [])
        let daily = try days.map { try PerformanceDailyValue(day: $0, valuationAt: f.close($0), cash: Money("100"), positions: [], receivables: Money("0"), payables: Money("0"), nav: Money("100"), externalFlow: Money("0"), status: .available, reason: "fixture") }
        let result = try PerformanceReturns.risk(daily: daily, segments: [segment], input: input)
        #expect(result.annualizedVolatility.status == .shortSample)
        #expect(abs(try #require(result.annualizedVolatility.value) - sqrt(0.006 / 59 * 252)) < 1e-12)
        #expect(abs(try #require(result.annualizedRiskFree.value) - 0.05) < 1e-11)
        let expectedAnnual = pow(0.9999, 126.0) - 1
        #expect(abs(try #require(result.annualizedTWR.value) - expectedAnnual) < 1e-12)
        #expect(result.beta.value == nil)
        let short = PerformanceSegment(startDay: days[0], endDay: days[59], returns: Array(observations.prefix(59)), cumulativeReturn: observations[58].index - 1)
        let shortRisk = try PerformanceReturns.risk(daily: Array(daily.prefix(60)), segments: [short], input: input)
        #expect(shortRisk.annualizedVolatility.status == .insufficientSample)
        #expect(shortRisk.sharpe.value == nil)
    }
}
