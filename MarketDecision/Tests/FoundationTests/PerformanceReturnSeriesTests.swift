import Foundation
import Testing
import CoreDomain
@testable import PortfolioEngine

@Suite("Verified performance return series")
struct PerformanceReturnSeriesTests {
    private let f = PerformanceVectors()
    private let days = ["2026-01-05", "2026-01-06", "2026-01-07"]

    @Test func actualEngineReturnsExcludeExternalFlowsAndSupportSubintervals() throws {
        let events = [try f.cash("start", days[0], .deposit, "100"), try f.cash("gain", days[1], .interest, "10"),
                      try f.cash("add", days[1], .deposit, "50"), try f.cash("remove", days[2], .withdrawal, "20"),
                      try f.cash("fee", days[2], .fee, "16")]
        let report = try PerformanceEngine.calculate(f.input(days, events: events))
        let series = PerformanceReturnSeries(report: report)
        let full = series.timeWeightedReturn(from: f.close(days[0]), to: f.close(days[2]))
        let first = series.timeWeightedReturn(from: f.close(days[0]), to: f.close(days[1]))
        let last = series.timeWeightedReturn(from: f.close(days[1]), to: f.close(days[2]))
        #expect(full.status == .available && full.sampleCount == 2)
        #expect(abs(try #require(full.value) + 0.01) < 1e-12)
        #expect(abs(try #require(first.value) - 0.1) < 1e-12)
        #expect(abs(try #require(last.value) + 0.1) < 1e-12)
    }

    @Test func verifiedZeroReturnRemainsZeroWithoutTreatingMissingDataAsZero() throws {
        let report = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fund", days[0], .deposit, "100")]))
        let result = PerformanceReturnSeries(report: report).timeWeightedReturn(from: f.close(days[0]), to: f.close(days[2]))
        #expect(result.status == .available && result.value == 0)
    }

    @Test func exactValuationTimesCannotBeReplacedBySameDayOrNearbyTimes() throws {
        let report = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fund", days[0], .deposit, "100")]))
        let series = PerformanceReturnSeries(report: report), first = f.close(days[0]), last = f.close(days[2])
        #expect(series.timeWeightedReturn(from: first.addingTimeInterval(-3600), to: last).value == nil)
        #expect(series.timeWeightedReturn(from: first, to: last.addingTimeInterval(0.001)).value == nil)
        #expect(series.latestValuation(onOrBefore: last.addingTimeInterval(-1), notBefore: first) == f.close(days[1]))
        #expect(series.latestValuation(onOrBefore: last, notBefore: last) == last)
        #expect(series.latestValuation(onOrBefore: first.addingTimeInterval(-1), notBefore: first) == nil)
    }

    @Test func missingInteriorValuationCannotBeBridgedButValidTailCanBeUsed() throws {
        let calendar = days + ["2026-01-08", "2026-01-09"]
        let definitions = calendar.enumerated().filter { $0.offset != 2 }.map { f.day($0.element) }
        let events = [try f.cash("fund", calendar[0], .deposit, "100"), try f.cash("gain", calendar[1], .interest, "10"),
                      try f.cash("gain2", calendar[4], .interest, "22")]
        let report = try PerformanceEngine.calculate(f.input(calendar, definitions: definitions, events: events))
        let series = PerformanceReturnSeries(report: report)
        #expect(series.timeWeightedReturn(from: f.close(calendar[0]), to: f.close(calendar[4])).value == nil)
        #expect(series.timeWeightedReturn(from: f.close(calendar[2]), to: f.close(calendar[4])).value == nil)
        let tail = series.timeWeightedReturn(from: f.close(calendar[3]), to: f.close(calendar[4]))
        #expect(tail.status == .available)
        #expect(abs(try #require(tail.value) - 0.2) < 1e-12)
    }

    @Test func unconfirmedFlowsNeverProduceAComparisonRate() throws {
        let report = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fund", days[0], .deposit, "100")], complete: false))
        let series = PerformanceReturnSeries(report: report)
        let result = series.timeWeightedReturn(from: f.close(days[0]), to: f.close(days[2]))
        #expect(result.value == nil && result.status == .missingInput)
        #expect(result.reason.contains("出入金"))
        #expect(series.latestValuation(onOrBefore: f.close(days[2]), notBefore: f.close(days[0])) == nil)
    }

    @Test func zeroOrNegativeStartingNAVAndInvalidBoundariesRemainUnavailable() throws {
        let empty = try PerformanceEngine.calculate(f.input(days, events: []))
        let negative = try PerformanceEngine.calculate(f.input(days, events: [f.cash("fee", days[0], .fee, "10")]))
        let emptySeries = PerformanceReturnSeries(report: empty), negativeSeries = PerformanceReturnSeries(report: negative)
        #expect(emptySeries.timeWeightedReturn(from: f.close(days[0]), to: f.close(days[2])).value == nil)
        #expect(negativeSeries.timeWeightedReturn(from: f.close(days[0]), to: f.close(days[2])).value == nil)
        for end in [f.close(days[0]), f.close(days[0]).addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity)] {
            #expect(emptySeries.timeWeightedReturn(from: f.close(days[0]), to: end).status == .invalidInput)
        }
        #expect(emptySeries.timeWeightedReturn(from: Date(timeIntervalSince1970: .nan), to: f.close(days[2])).value == nil)
    }

    @Test func zeroNAVBreaksSegmentsAndDoesNotAuthorizeNewFundingAsReturn() throws {
        let calendar = days + ["2026-01-08"]
        let events = [try f.cash("fund", calendar[0], .deposit, "100"), try f.cash("loss", calendar[1], .fee, "100"),
                      try f.cash("fund2", calendar[2], .deposit, "100"), try f.cash("gain", calendar[3], .interest, "10")]
        let report = try PerformanceEngine.calculate(f.input(calendar, events: events))
        let series = PerformanceReturnSeries(report: report)
        #expect(series.timeWeightedReturn(from: f.close(calendar[0]), to: f.close(calendar[1])).value == -1)
        #expect(series.timeWeightedReturn(from: f.close(calendar[0]), to: f.close(calendar[3])).value == nil)
        let tail = series.timeWeightedReturn(from: f.close(calendar[2]), to: f.close(calendar[3]))
        #expect(abs(try #require(tail.value) - 0.1) < 1e-12)
    }

    @Test func staleOrMissingMarksCannotEnterEvenWhenOtherEndpointsAreValid() throws {
        let first = try f.valuedInput(age: 0), instrument = LedgerInstrument.equity(f.stock)
        func calculate(stale: Bool) throws -> PerformanceReport {
            let definitions = try days.enumerated().map { index, day -> PerformanceDayInput in
                let close = f.close(day)
                let session = PerformanceSession(id: "session/" + day, instrumentID: instrument.identity,
                    opensAt: close.addingTimeInterval(-23400), closesAt: close, evidence: f.evidence())
                let price = PerformancePrice(id: "price/" + day, instrumentID: instrument.identity, sessionID: session.id,
                    quoteAt: close.addingTimeInterval(index == 1 && stale ? -301 : 0),
                    bid: try Money("9"), ask: try Money("11"), last: try Money("12"), evidence: f.evidence())
                return f.day(day, prices: index == 1 && !stale ? [] : [price], sessions: [session])
            }
            return try PerformanceEngine.calculate(f.input(days, definitions: definitions, events: first.events))
        }
        for stale in [true, false] {
            let report = try calculate(stale: stale), series = PerformanceReturnSeries(report: report)
            #expect(series.timeWeightedReturn(from: f.close(days[0]), to: f.close(days[2])).value == nil)
            #expect(series.latestValuation(onOrBefore: f.close(days[1]), notBefore: f.close(days[0])) == f.close(days[0]))
        }
    }

    @Test func earlyCloseKeepsItsActualInstantRatherThanBecomingFourPM() throws {
        let calendar = ["2026-11-27", "2026-11-30"]
        let early = f.date("2026-11-27T18:00:00Z"), regular = f.close(calendar[1])
        let definitions = [PerformanceDayInput(day: calendar[0], valuationAt: early, sessions: [], prices: []), f.day(calendar[1])]
        let events = [f.event("fund", at: early.addingTimeInterval(-60), payload: .cash(.init(kind: .deposit, amount: try Money("100")))),
                      try f.cash("gain", calendar[1], .interest, "10")]
        let report = try PerformanceEngine.calculate(f.input(calendar, definitions: definitions, events: events))
        let series = PerformanceReturnSeries(report: report)
        #expect(abs(try #require(series.timeWeightedReturn(from: early, to: regular).value) - 0.1) < 1e-12)
        #expect(series.timeWeightedReturn(from: f.close(calendar[0]), to: regular).value == nil)
    }
}
