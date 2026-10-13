import Foundation
import CoreDomain
import DataContracts

public enum FREDTreasurySeries: String, Codable, Sendable {
    case dgs1mo = "DGS1MO", dgs3mo = "DGS3MO", dgs6mo = "DGS6MO", dgs1 = "DGS1", dgs2 = "DGS2"
    public var termYears: Double {
        switch self { case .dgs1mo: 1.0 / 12; case .dgs3mo: 0.25; case .dgs6mo: 0.5; case .dgs1: 1; case .dgs2: 2 }
    }
}

/// A release assertion for this exact row/version. FRED realtime_start/end alone
/// are vintage dates, not intraday publication timestamps. An absent assertion
/// remains missing; neither retrieval time nor the observation date is substituted.
public struct PublishedRateRelease: Codable, Equatable, Sendable {
    public let observationDay: String
    public let realtimeStart: String
    public let realtimeEnd: String
    public let availability: AvailabilityEvidence
    public init(observationDay: String, realtimeStart: String, realtimeEnd: String, availability: AvailabilityEvidence) {
        self.observationDay = observationDay; self.realtimeStart = realtimeStart; self.realtimeEnd = realtimeEnd
        self.availability = availability
    }
    fileprivate var identity: String { observationDay + "/" + realtimeStart + "/" + realtimeEnd }
}
public struct PublishedRateImport: Sendable, Equatable {
    public let curves: [PerformanceRateCurve]
    public let missingValueDays: [String]
    public let unverifiedReleaseDays: [String]
}

/// Offline decoding of an explicitly supplied complete FRED JSON page. No HTTP,
/// key lookup or automatic provider authorization. The original bytes are frozen
/// as localDocument (or synthetic), with exact decimal strings and explicit units.
public enum FREDPublishedRateImport {
    public static let version = "fred-local-published-rates.v1"
    public static func validateFrozenCurve(_ curve: PerformanceRateCurve) throws {
        guard (curve.sourceInput == nil) == (curve.sourceVersion == nil) else { throw PerformanceError.invalidEvidence }
        guard let bytes = curve.sourceInput else { return }
        guard curve.sourceVersion == version, bytes.count <= 2 * 1_024 * 1_024 else { throw PerformanceError.incompatibleVersion }
        let source = try JSONDecoder().decode(FrozenRateInput.self, from: bytes)
        let document = PerformanceEvidence(id: source.documentID, source: source.source, kind: source.kind,
            availableAt: source.documentAvailableAt, reference: source.reference, rawDocument: curve.evidence.rawDocument)
        let replay = try decode(curve.evidence.rawDocument, series: source.series, document: document, releases: [source.release])
        guard replay.curves.count == 1, replay.curves.first == curve else { throw PerformanceError.invalidEvidence }
    }
    public static func decode(_ data: Data, series: FREDTreasurySeries,
                              document: PerformanceEvidence, releases: [PublishedRateRelease]) throws -> PublishedRateImport {
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024, document.rawDocument == data,
              !document.id.isEmpty, !document.source.isEmpty, !document.reference.isEmpty,
              document.availableAt.timeIntervalSinceReferenceDate.isFinite,
              Set(releases.map(\.identity)).count == releases.count else { throw PerformanceError.invalidEvidence }
        // Codable does not reject duplicate object keys. Refuse ambiguous source
        // documents before typed decoding so replay cannot depend on decoder order.
        _ = try ExactMarketJSON.parse(data)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.units == "lin", response.offset == 0, response.count == response.observations.count,
              response.count > 0, response.count <= 2_000,
              Set(response.observations.map(\.identity)).count == response.count else { throw PerformanceError.invalidInput }
        let identities = Set(response.observations.map(\.identity))
        guard releases.allSatisfy({ identities.contains($0.identity) }) else { throw PerformanceError.invalidEvidence }
        let releaseMap = Dictionary(uniqueKeysWithValues: releases.map { ($0.identity, $0) })
        var curves: [PerformanceRateCurve] = [], missing: [String] = [], unverified: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for row in response.observations {
            let day = try MarketDate(iso8601: row.date)
            let vintageStart = try MarketDate(iso8601: row.realtime_start)
            let vintageEnd = try MarketDate(iso8601: row.realtime_end)
            guard vintageStart <= vintageEnd else { throw PerformanceError.invalidEvidence }
            if row.value == "." { missing.append(row.date); continue }
            let value = try Money(row.value)
            guard value.amount > -100 else { throw PerformanceError.invalidInput }
            guard let release = releaseMap[row.identity], let published = try? release.availability.upperBound() else {
                unverified.append(row.date); continue
            }
            let observation = try day.start(in: calendar.timeZone)
            guard observation <= published, published <= document.availableAt,
                  let through = calendar.date(byAdding: .day, value: 8, to: observation) else { throw PerformanceError.invalidEvidence }
            // A daily boundary is conservative. It is not replaced by vintageStart.
            let evidence = PerformanceEvidence(id: document.id + "/" + row.identity,
                source: document.source + ":" + series.rawValue, kind: document.kind,
                availableAt: published, reference: document.reference, rawDocument: data)
            let curve = PerformanceRateCurve(id: series.rawValue + "/" + row.identity,
                source: series == .dgs3mo ? .fredDGS3MO : .fredTreasuryCurve,
                observationAt: observation, validFrom: published, validThrough: max(published, through),
                points: [.init(termYears: series.termYears, annualRate: value, unit: .annualPercent)], evidence: evidence)
            try PortfolioRates.validate(curve)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let source = try encoder.encode(FrozenRateInput(series: series, documentID: document.id,
                source: document.source, kind: document.kind, documentAvailableAt: document.availableAt,
                reference: document.reference, release: release))
            curves.append(.init(id: curve.id, source: curve.source, observationAt: curve.observationAt,
                validFrom: curve.validFrom, validThrough: curve.validThrough, points: curve.points,
                evidence: curve.evidence, sourceInput: source, sourceVersion: version))
        }
        return .init(curves: curves, missingValueDays: missing, unverifiedReleaseDays: unverified)
    }
    private struct Response: Decodable {
        let units: String, count: Int, offset: Int, observations: [Row]
    }
    private struct FrozenRateInput: Codable {
        let series: FREDTreasurySeries
        let documentID: String
        let source: String
        let kind: PerformanceEvidenceKind
        let documentAvailableAt: Date
        let reference: String
        let release: PublishedRateRelease
    }
    private struct Row: Decodable {
        let date: String, realtime_start: String, realtime_end: String, value: String
        var identity: String { date + "/" + realtime_start + "/" + realtime_end }
    }
}

public enum PerformanceBenchmarkBasis: String, Codable, Sendable {
    case unadjustedWithExplicitActions, totalReturnAdjustedClose
}
public struct PerformanceBenchmarkClose: Codable, Equatable, Sendable {
    public let day: String
    public let close: Money
    /// Per post-split share, reinvested at this close. Explicit zero/one are required
    /// in the unadjusted mode; adjusted close mode must not also supply these legs.
    public let cashDividend: Money?
    public let splitRatio: Money?
    public let evidence: PerformanceEvidence
    public init(day: String, close: Money, cashDividend: Money? = nil, splitRatio: Money? = nil, evidence: PerformanceEvidence) {
        self.day = day; self.close = close; self.cashDividend = cashDividend; self.splitRatio = splitRatio; self.evidence = evidence
    }
}
public enum PortfolioBenchmarkSource {
    public static let version = "portfolio-benchmark-total-return.v1"
    public static func validate(_ benchmark: PerformanceBenchmark) throws {
        guard (benchmark.sourceInput == nil) == (benchmark.sourceVersion == nil) else { throw PerformanceError.invalidEvidence }
        guard let raw = benchmark.sourceInput else { return }
        guard benchmark.sourceVersion == version, raw.count <= 8 * 1_024 * 1_024 else { throw PerformanceError.incompatibleVersion }
        let source = try JSONDecoder().decode(FrozenBenchmarkInput.self, from: raw)
        let rebuilt = try build(symbol: benchmark.symbol, calendarDays: source.closes.map(\.day), closes: source.closes, basis: source.basis)
        guard rebuilt.points == benchmark.points, benchmark.isTotalReturn else { throw PerformanceError.invalidEvidence }
    }
    /// Caller supplies every requested trading session. Missing sessions must be
    /// represented by an incomplete benchmark, never bridged by this constructor.
    public static func build(symbol: String = "SPY", calendarDays: [String], closes: [PerformanceBenchmarkClose],
                             basis: PerformanceBenchmarkBasis) throws -> PerformanceBenchmark {
        guard !symbol.isEmpty, closes.count >= 2, closes.count <= 10_000,
              calendarDays == calendarDays.sorted(), Set(calendarDays).count == calendarDays.count,
              closes.map(\.day) == calendarDays else { throw PerformanceError.invalidCalendar }
        var index = try Money("100"), points: [PerformanceBenchmarkPoint] = []
        let one = try Money("1"), zero = try Money("0")
        for (position, row) in closes.enumerated() {
            _ = try MarketDate(iso8601: row.day)
            guard row.close.amount > 0, !row.evidence.id.isEmpty, !row.evidence.reference.isEmpty,
                  !row.evidence.source.isEmpty, !row.evidence.rawDocument.isEmpty,
                  row.evidence.availableAt.timeIntervalSinceReferenceDate.isFinite else { throw PerformanceError.invalidEvidence }
            switch basis {
            case .totalReturnAdjustedClose:
                guard row.cashDividend == nil, row.splitRatio == nil else { throw PerformanceError.invalidInput }
                index = try row.close.multiplied(by: "100").divided(by: closes[0].close.decimalString)
            case .unadjustedWithExplicitActions:
                guard let dividend = row.cashDividend, let ratio = row.splitRatio,
                      dividend.amount >= 0, ratio.amount > 0 else { throw PerformanceError.invalidInput }
                if position == 0 {
                    guard dividend == zero, ratio == one else { throw PerformanceError.invalidInput }
                } else {
                    let distribution = try row.close.adding(dividend)
                    index = try index.multiplied(by: ratio.decimalString)
                        .multiplied(by: distribution.decimalString).divided(by: closes[position - 1].close.decimalString)
                }
            }
            let evidence = PerformanceEvidence(id: "benchmark/" + row.day + "/" + row.evidence.id, source: symbol + ":" + version,
                kind: closes.prefix(position + 1).contains(where: { $0.evidence.kind == .synthetic }) ? .synthetic : .localDocument,
                availableAt: closes.prefix(position + 1).map { $0.evidence.availableAt }.max()!,
                reference: row.evidence.reference, rawDocument: row.evidence.rawDocument)
            points.append(.init(day: row.day, totalReturnIndex: index, evidence: evidence))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let source = try encoder.encode(FrozenBenchmarkInput(basis: basis, closes: closes))
        return .init(symbol: symbol, points: points, isTotalReturn: true, sourceInput: source, sourceVersion: version)
    }
    private struct FrozenBenchmarkInput: Codable {
        let basis: PerformanceBenchmarkBasis
        let closes: [PerformanceBenchmarkClose]
    }
}
