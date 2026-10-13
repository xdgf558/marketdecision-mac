import Foundation
import CoreDomain

/// PARAMETERS_V1 / CALC-017. These are local evidence-based proxies, never a
/// provider admission decision or a claim that Treasury quotes are zero rates.
public enum PortfolioRates {
    public static let version = "portfolio-rates.v1"

    /// Combine separately imported tenors only for one observation day. The
    /// complete curve becomes available when its last supplied tenor is published.
    public static func combinePublishedCurve(_ curves: [PerformanceRateCurve]) throws -> PerformanceRateCurve {
        guard !curves.isEmpty, Set(curves.map(\.id)).count == curves.count,
              Set(curves.map(\.observationAt)).count == 1,
              curves.allSatisfy({ $0.source != .explicitUserConstant }) else { throw PerformanceError.invalidInput }
        for curve in curves { try validate(curve) }
        let points = curves.flatMap(\.points).sorted { $0.termYears < $1.termYears }
        guard Set(points.map(\.termYears)).count == points.count else { throw PerformanceError.duplicateIdentity }
        let available = curves.map { $0.evidence.availableAt }.max()!
        let from = max(available, curves.map(\.validFrom).max()!), through = curves.map(\.validThrough).min()!
        guard from <= through else { throw PerformanceError.invalidEvidence }
        let ordered = curves.sorted { $0.id < $1.id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let evidence = PerformanceEvidence(id: "rate-curve/" + ordered.map { $0.evidence.id }.joined(separator: "+"),
            source: version, kind: curves.contains { $0.evidence.kind == .synthetic } ? .synthetic : .localDocument,
            availableAt: available, reference: ordered.map { $0.evidence.reference }.joined(separator: "; "), rawDocument: try encoder.encode(ordered))
        let result = PerformanceRateCurve(id: evidence.id, source: .fredTreasuryCurve,
            observationAt: curves[0].observationAt, validFrom: from, validThrough: through, points: points, evidence: evidence)
        try validate(result)
        return result
    }

    /// Effective calendar-day rate (365), not a trading-day MAR (252). A consumer
    /// compounding a trading interval must account for its intervening calendar days.
    public static func dailyEffective(at: Date, curves: [PerformanceRateCurve]) -> PerformanceNumber {
        let result = effectiveAnnual(at: at, termYears: 0.25, curves: curves, dailyUse: true)
        guard let annual = result.value else { return result }
        return .init(value: expm1(log1p(annual) / 365), status: .available,
                     reason: result.reason, sampleCount: result.sampleCount, evidenceIDs: result.evidenceIDs)
    }

    /// Continuous pricing rate. Interpolation is on effective annual y first,
    /// then log1p(y); never interpolate the logarithms or silently extrapolate.
    public static func evaluatePricing(at: Date, termYears: Double, curves: [PerformanceRateCurve]) -> PerformanceNumber {
        let result = effectiveAnnual(at: at, termYears: termYears, curves: curves, dailyUse: false)
        guard let annual = result.value else { return result }
        return .init(value: log1p(annual), status: .available,
                     reason: result.reason, sampleCount: result.sampleCount, evidenceIDs: result.evidenceIDs)
    }

    public static func validate(_ curve: PerformanceRateCurve) throws {
        try FREDPublishedRateImport.validateFrozenCurve(curve)
        let dates = [curve.observationAt, curve.validFrom, curve.validThrough, curve.evidence.availableAt]
        guard !curve.id.isEmpty, dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              curve.validFrom <= curve.validThrough, curve.observationAt <= curve.evidence.availableAt,
              !curve.evidence.id.isEmpty, !curve.evidence.reference.isEmpty,
              !curve.evidence.source.isEmpty, !curve.evidence.rawDocument.isEmpty,
              !curve.points.isEmpty, Set(curve.points.map(\.termYears)).count == curve.points.count
        else { throw PerformanceError.invalidEvidence }
        for point in curve.points {
            guard point.termYears.isFinite, point.termYears > 0,
                  let annual = annual(point), annual.isFinite, annual > -1 else { throw PerformanceError.invalidInput }
            if curve.source != .explicitUserConstant {
                guard point.unit == .annualPercent,
                      [1.0 / 12, 0.25, 0.5, 1, 2].contains(point.termYears) else { throw PerformanceError.invalidInput }
            }
        }
        switch curve.source {
        case .fredDGS3MO:
            guard curve.points.count == 1, curve.points[0].termYears == 0.25 else { throw PerformanceError.invalidInput }
        case .explicitUserConstant:
            // An explicit constant is authorized only through its supplied maximum tenor.
            guard curve.points.count == 1 else { throw PerformanceError.invalidInput }
        case .fredTreasuryCurve: break
        }
    }

    private static func effectiveAnnual(at: Date, termYears: Double, curves: [PerformanceRateCurve], dailyUse: Bool) -> PerformanceNumber {
        guard at.timeIntervalSinceReferenceDate.isFinite, termYears.isFinite, termYears > 0 else { return missing(.invalidInput, "INVALID_RATE_TIME_OR_TENOR") }
        guard Set(curves.map(\.id)).count == curves.count else { return missing(.invalidInput, "DUPLICATE_RATE_CURVE") }
        do { for curve in curves { try validate(curve) } }
        catch { return missing(.invalidInput, "INVALID_RATE_EVIDENCE") }
        let eligible = curves.filter { curve in
            guard curve.observationAt <= at, curve.evidence.availableAt <= at,
                  curve.validFrom <= at, at <= curve.validThrough else { return false }
            if curve.source == .explicitUserConstant { return true }
            // Observation dates and seven-day age use the US publication calendar.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: curve.observationAt), to: calendar.startOfDay(for: at)).day
            return age.map({ (0...7).contains($0) }) ?? false
        }.filter { curve in
            if dailyUse { return curve.source != .fredTreasuryCurve || curve.points.contains { $0.termYears == 0.25 } }
            return true
        }
        // An explicitly supplied user rate wins over published proxies only when
        // valid for this date and tenor. No default infinite constant is invented.
        let constants = eligible.filter { $0.source == .explicitUserConstant && termYears <= $0.points[0].termYears }
        let candidates = constants.isEmpty ? eligible.filter { $0.source != .explicitUserConstant } : constants
        guard !candidates.isEmpty else { return missing(.missingInput, "NO_PUBLISHED_OR_VALID_USER_RATE") }
        guard termYears <= 2 || !constants.isEmpty else { return missing(.outsideRange, "RATE_TENOR_OVER_TWO_YEARS") }
        let lastObservation = candidates.map(\.observationAt).max()!
        let latest = candidates.filter { $0.observationAt == lastObservation }
        let latestAvailable = latest.map { $0.evidence.availableAt }.max()!
        let selected = latest.filter { $0.evidence.availableAt == latestAvailable }
        guard selected.count == 1, let curve = selected.first else { return missing(.invalidInput, "AMBIGUOUS_RATE_VERSION") }
        let points = curve.points.sorted { $0.termYears < $1.termYears }
        let y: Double
        if curve.source == .explicitUserConstant { y = annual(points[0])! }
        else {
            let term = max(1.0 / 12, termYears)
            if let exact = points.first(where: { $0.termYears == term }) { y = annual(exact)! }
            else if let lower = points.last(where: { $0.termYears < term }), let upper = points.first(where: { $0.termYears > term }) {
                let weight = (term - lower.termYears) / (upper.termYears - lower.termYears)
                y = annual(lower)! + weight * (annual(upper)! - annual(lower)!)
            } else { return missing(.missingInput, "MISSING_RATE_TENOR_NO_EXTRAPOLATION") }
        }
        guard y.isFinite, y > -1 else { return missing(.invalidInput, "INVALID_INTERPOLATED_RATE") }
        return .init(value: y, status: .available,
                     reason: curve.source == .explicitUserConstant ? "RATE_USER_INPUT_PROXY" : "TREASURY_EFFECTIVE_ANNUAL_PROXY",
                     sampleCount: points.count, evidenceIDs: [curve.evidence.id])
    }
    private static func annual(_ point: PerformanceRatePoint) -> Double? {
        guard let value = Double(point.annualRate.decimalString) else { return nil }
        return point.unit == .annualPercent ? value / 100 : value
    }
    private static func missing(_ status: PerformanceStatus, _ reason: String) -> PerformanceNumber {
        .init(value: nil, status: status, reason: reason)
    }
}
