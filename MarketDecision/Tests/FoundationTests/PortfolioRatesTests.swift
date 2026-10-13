import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import DataContracts

@Suite struct PortfolioRatesTests {
    private let time = Date(timeIntervalSince1970: 1_783_080_000)
    private func evidence(_ id: String = "rate", at: Date? = nil, raw: Data = Data("synthetic local source".utf8)) -> PerformanceEvidence {
        .init(id: id, source: "synthetic", kind: .synthetic, availableAt: at ?? time, reference: "fixture", rawDocument: raw)
    }
    private func curve(_ value: String, source: PerformanceRateSource = .fredDGS3MO, points: [PerformanceRatePoint]? = nil,
                       published: Date? = nil, through: Date? = nil, id: String = "rate") throws -> PerformanceRateCurve {
        .init(id: id, source: source, observationAt: time, validFrom: time, validThrough: through ?? time.addingTimeInterval(20 * 86400),
              points: try points ?? [.init(termYears: 0.25, annualRate: Money(value), unit: .annualPercent)], evidence: evidence(id, at: published))
    }
    @Test func percentConversionAndCalendarDailyRate() throws {
        let values = [try curve("5")]
        #expect(abs(PortfolioRates.evaluatePricing(at: time, termYears: 0.25, curves: values).value! - log(1.05)) < 1e-14)
        let daily = try #require(PortfolioRates.dailyEffective(at: time, curves: values).value)
        #expect(abs(pow(1 + daily, 365) - 1.05) < 1e-12)
        #expect(PortfolioRates.dailyEffective(at: time, curves: values).evidenceIDs == ["rate"])
    }
    @Test func negativeRatesAllowedButMinusOneRejected() throws {
        #expect(PortfolioRates.dailyEffective(at: time, curves: [try curve("-2")]).value! < 0)
        #expect(PortfolioRates.dailyEffective(at: time, curves: [try curve("-100")]).status == .invalidInput)
    }
    @Test func unpublishedAndStaleValuesCannotFillHistory() throws {
        #expect(PortfolioRates.dailyEffective(at: time, curves: [try curve("5", published: time.addingTimeInterval(0.0004))]).value == nil)
        #expect(PortfolioRates.dailyEffective(at: time.addingTimeInterval(0.0002), curves: [try curve("5", published: time.addingTimeInterval(0.0004))]).value == nil)
        #expect(PortfolioRates.dailyEffective(at: time.addingTimeInterval(8 * 86400), curves: [try curve("5")]).value == nil)
        #expect(PortfolioRates.dailyEffective(at: time.addingTimeInterval(7 * 86400), curves: [try curve("5")]).value != nil)
        #expect(PortfolioRates.dailyEffective(at: time.addingTimeInterval(1), curves: [try curve("5", through: time)]).value == nil)
    }
    @Test func interpolateYBeforeLogAndNeverExtrapolate() throws {
        let c = try curve("0", source: .fredTreasuryCurve, points: [
            .init(termYears: 1.0 / 12, annualRate: Money("2"), unit: .annualPercent),
            .init(termYears: 1, annualRate: Money("4"), unit: .annualPercent),
            .init(termYears: 2, annualRate: Money("8"), unit: .annualPercent)])
        #expect(abs(PortfolioRates.evaluatePricing(at: time, termYears: 1.5, curves: [c]).value! - log(1.06)) < 1e-14)
        #expect(abs(PortfolioRates.evaluatePricing(at: time, termYears: 0.01, curves: [c]).value! - log(1.02)) < 1e-14)
        #expect(PortfolioRates.evaluatePricing(at: time, termYears: 2.1, curves: [c]).status == .outsideRange)
        #expect(PortfolioRates.evaluatePricing(at: time, termYears: 1, curves: [try curve("5")]).value == nil)
    }
    @Test func explicitConstantRequiresTenorAndValidity() throws {
        let c = try curve("0", source: .explicitUserConstant, points: [.init(termYears: 5, annualRate: Money("0.03"), unit: .annualDecimal)])
        #expect(abs(PortfolioRates.evaluatePricing(at: time, termYears: 4, curves: [c]).value! - log(1.03)) < 1e-14)
        #expect(PortfolioRates.evaluatePricing(at: time, termYears: 6, curves: [c]).value == nil)
        #expect(PortfolioRates.dailyEffective(at: time.addingTimeInterval(21 * 86400), curves: [c]).value == nil)
    }
    @Test func ambiguousVersionsRejectedAndEarlierPublishedVersionRetained() throws {
        let a = try curve("5", id: "a"), b = try curve("6", id: "b")
        #expect(PortfolioRates.dailyEffective(at: time, curves: [a,b]).status == .invalidInput)
        let later = try curve("6", published: time.addingTimeInterval(10), id: "later")
        #expect(PortfolioRates.dailyEffective(at: time, curves: [a,later]).evidenceIDs == ["a"])
        #expect(PortfolioRates.dailyEffective(at: time.addingTimeInterval(10), curves: [a,later]).evidenceIDs == ["later"])
    }
    @Test func combineTenorsPinsLastPublicationAndRejectsDuplicateMaturities() throws {
        let a = try curve("0", source: .fredTreasuryCurve, points: [.init(termYears: 1, annualRate: Money("4"), unit: .annualPercent)], id: "a")
        let b = try curve("0", source: .fredTreasuryCurve, points: [.init(termYears: 2, annualRate: Money("8"), unit: .annualPercent)], published: time.addingTimeInterval(10), id: "b")
        let combined = try PortfolioRates.combinePublishedCurve([a,b])
        #expect(PortfolioRates.evaluatePricing(at: time, termYears: 1.5, curves: [combined]).value == nil)
        #expect(abs(PortfolioRates.evaluatePricing(at: time.addingTimeInterval(10), termYears: 1.5, curves: [combined]).value! - log(1.06)) < 1e-14)
        #expect(throws: (any Error).self) { try PortfolioRates.combinePublishedCurve([a,a]) }
    }
}

@Suite struct PerformanceSourceImportTests {
    private let publication = Date(timeIntervalSince1970: 1_783_123_200)
    private func evidence(raw: Data) -> PerformanceEvidence {
        .init(id: "raw", source: "local-fixture", kind: .synthetic, availableAt: publication, reference: "local published evidence", rawDocument: raw)
    }
    private func body(_ rows: String, count: Int = 1, offset: Int = 0) -> Data {
        Data("{\"units\":\"lin\",\"count\":\(count),\"offset\":\(offset),\"observations\":[\(rows)]}".utf8)
    }
    private let row = #"{"date":"2026-07-01","realtime_start":"2026-07-02","realtime_end":"9999-12-31","value":"4.50"}"#
    @Test func fredNeedsExplicitReleaseAndPreservesSourceBytesAndDecimal() throws {
        let raw = body(row)
        let empty = try FREDPublishedRateImport.decode(raw, series: .dgs3mo, document: evidence(raw: raw), releases: [])
        #expect(empty.curves.isEmpty && empty.unverifiedReleaseDays == ["2026-07-01"])
        let release = PublishedRateRelease(observationDay: "2026-07-01", realtimeStart: "2026-07-02", realtimeEnd: "9999-12-31", availability: .instant(publication, evidence: "actual release fixture"))
        let actual = try FREDPublishedRateImport.decode(raw, series: .dgs3mo, document: evidence(raw: raw), releases: [release])
        #expect(actual.curves.count == 1)
        #expect(actual.curves[0].points[0].annualRate == (try Money("4.5")))
        #expect(actual.curves[0].evidence.rawDocument == raw)
        #expect(actual.curves[0].evidence.availableAt == publication)
        let frozen = try JSONDecoder().decode(PerformanceRateCurve.self, from: JSONEncoder().encode(actual.curves[0]))
        try PortfolioRates.validate(frozen)
        let metadata = try #require(frozen.sourceInput)
        #expect(String(decoding: metadata, as: UTF8.self).contains("actual release fixture"))
        let changed = PerformanceRateCurve(id: frozen.id, source: frozen.source, observationAt: frozen.observationAt,
            validFrom: frozen.validFrom, validThrough: frozen.validThrough,
            points: [.init(termYears: 0.25, annualRate: try Money("8"), unit: .annualPercent)],
            evidence: frozen.evidence, sourceInput: frozen.sourceInput, sourceVersion: frozen.sourceVersion)
        #expect(throws: (any Error).self) { try PortfolioRates.validate(changed) }
    }
    @Test func fredMissingIsNotZeroAndPartialOrWrongSourceRejected() throws {
        let raw = body(row.replacingOccurrences(of: "4.50", with: "."))
        let actual = try FREDPublishedRateImport.decode(raw, series: .dgs3mo, document: evidence(raw: raw), releases: [])
        #expect(actual.curves.isEmpty && actual.missingValueDays == ["2026-07-01"])
        let partial = body(row, count: 2)
        #expect(throws: (any Error).self) { try FREDPublishedRateImport.decode(partial, series: .dgs3mo, document: evidence(raw: partial), releases: []) }
        #expect(throws: (any Error).self) { try FREDPublishedRateImport.decode(raw, series: .dgs3mo, document: evidence(raw: Data("other".utf8)), releases: []) }
        let duplicateValue = body(row.replacingOccurrences(of: #""value":"4.50""#, with: #""value":"4.50","value":"9.99""#))
        #expect(throws: (any Error).self) { try FREDPublishedRateImport.decode(duplicateValue, series: .dgs3mo, document: evidence(raw: duplicateValue), releases: []) }
        let duplicateUnits = Data(String(decoding: body(row), as: UTF8.self).replacingOccurrences(of: #""units":"lin""#, with: #""units":"pc1","units":"lin""#).utf8)
        #expect(throws: (any Error).self) { try FREDPublishedRateImport.decode(duplicateUnits, series: .dgs3mo, document: evidence(raw: duplicateUnits), releases: []) }
    }
    @Test func totalReturnDividendAndSplitAreAppliedOnce() throws {
        let days = ["2026-07-01", "2026-07-02", "2026-07-06"]
        let e = evidence(raw: Data("synthetic prices and actions".utf8))
        let rows = try [PerformanceBenchmarkClose(day: days[0], close: Money("100"), cashDividend: Money("0"), splitRatio: Money("1"), evidence: e),
                        .init(day: days[1], close: Money("99"), cashDividend: Money("1"), splitRatio: Money("1"), evidence: e),
                        .init(day: days[2], close: Money("50"), cashDividend: Money("0"), splitRatio: Money("2"), evidence: e)]
        let result = try PortfolioBenchmarkSource.build(calendarDays: days, closes: rows, basis: .unadjustedWithExplicitActions)
        #expect(result.points[1].totalReturnIndex == (try Money("100")))
        #expect(result.points[2].totalReturnIndex == (try Money("101.010101010101010101")))
        #expect(result.sourceInput != nil && result.sourceVersion == PortfolioBenchmarkSource.version)
        try PortfolioBenchmarkSource.validate(result)
        let changed = PerformanceBenchmark(symbol: result.symbol,
            points: [.init(day: days[0], totalReturnIndex: try Money("1"), evidence: e)], isTotalReturn: true,
            sourceInput: result.sourceInput, sourceVersion: result.sourceVersion)
        #expect(throws: (any Error).self) { try PortfolioBenchmarkSource.validate(changed) }
        #expect(throws: (any Error).self) { try PortfolioBenchmarkSource.build(calendarDays: days, closes: rows, basis: .totalReturnAdjustedClose) }
    }
    @Test func adjustedCloseDoesNotAddDividendsAndMissingSessionsRejected() throws {
        let days = ["2026-07-01", "2026-07-02"]
        let e = evidence(raw: Data("total return adjusted fixture".utf8))
        let rows = try [PerformanceBenchmarkClose(day: days[0], close: Money("80"), evidence: e), .init(day: days[1], close: Money("88"), evidence: e)]
        let result = try PortfolioBenchmarkSource.build(calendarDays: days, closes: rows, basis: .totalReturnAdjustedClose)
        #expect(result.points[1].totalReturnIndex == (try Money("110")))
        #expect(throws: (any Error).self) { try PortfolioBenchmarkSource.build(calendarDays: days + ["2026-07-06"], closes: rows, basis: .totalReturnAdjustedClose) }
    }
}
