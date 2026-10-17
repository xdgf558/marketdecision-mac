import Foundation
import CoreDomain

public enum OptionLabDistributionError: Error, Equatable, Sendable {
    case invalidInput, unsafeNumericRepresentation, numericalFailure
}
public struct OptionLabDistributionOutcome: Codable, Equatable, Sendable {
    public let probabilityProfit: Double
    /// Undiscounted terminal PnL under the stated risk-neutral lognormal model.
    public let expectedPnL: Double
    /// No PV choice is made by this slice; absence must remain visible.
    public let presentValueExpectedPnL: Double?
    public let signedTailMean: Double
    public let tailLoss: Double
    /// Estimated absolute USD integration/roundoff error, not model uncertainty.
    public let numericalErrorBound: Double
    public let tailSubintervals: Int
}
public struct OptionLabDistributionReport: Codable, Equatable, Sendable {
    public let modelVersion: String
    public let confidence: Double
    public let tailMass: Double
    public let absoluteUSDTolerance: Double
    public let relativeTolerance: Double
    public let maximumSubintervals: Int
    public let volatility: Double
    public let volatilitySourceContractID: String
    public let rate: Double
    public let dividendYield: Double
    public let timeYears: Double
    public let riskNeutralOnly: Bool
    public let mid: OptionLabDistributionOutcome
    public let conservative: OptionLabDistributionOutcome
    public let limitations: [String]
}

/// Only the four explicitly implemented monotone payoffs are supported. The
/// canonical caller supplies the short leg's locally solved IV; a separately
/// labelled long-leg sensitivity may supply that leg's IV. Manual-volatility
/// fallback, historical frequencies and real-world Bootstrap are absent.
public enum OptionLabDistribution {
    public static let version = "option-risk-neutral.CVAR_DRAFT_2.v1"
    public static let confidence = 0.95
    public static let alpha = 0.05
    public static let absoluteTolerance = 1e-8
    public static let relativeTolerance = 1e-8
    public static let maximumSubintervals = 10_000

    // Module-only: OptionLabPricingEngine supplies validated input and freshly
    // calculated deterministic outcomes. There is no unvalidated public shortcut.
    static func analyze(input: OptionLabInput, mid: OptionLabOutcome, conservative: OptionLabOutcome,
                               underlyingMid: Money, assumptions: OptionLabPricingInput, volatility: Double,
                               volatilitySourceContractID: String) throws -> OptionLabDistributionReport {
        try analyze(input: input, mid: mid, conservative: conservative, underlyingMid: underlyingMid,
            assumptions: assumptions, volatility: volatility, volatilitySourceContractID: volatilitySourceContractID,
            intervalBudget: maximumSubintervals)
    }

    // A smaller test-only budget verifies fail-closed exhaustion without changing
    // the production policy. No public caller can relax the fixed error target.
    static func analyze(input: OptionLabInput, mid: OptionLabOutcome, conservative: OptionLabOutcome,
                        underlyingMid: Money, assumptions: OptionLabPricingInput, volatility: Double,
                        volatilitySourceContractID: String, intervalBudget: Int) throws -> OptionLabDistributionReport {
        try Task.checkCancellation()
        let seconds = input.expiry.settlementAt.timeIntervalSince(input.asOf)
        guard seconds.isFinite, seconds > 0, volatility.isFinite, volatility >= 0, volatility <= 20,
              mid.pricing == .mid, conservative.pricing == .conservative,
              volatilitySourceContractID == input.shortLeg.contractID || volatilitySourceContractID == input.longLeg?.contractID,
              (1...maximumSubintervals).contains(intervalBudget) else { throw OptionLabDistributionError.invalidInput }
        let spot = try finite(underlyingMid), rate = try finite(assumptions.rate), dividend = try finite(assumptions.dividendYield)
        let carry = try finite(assumptions.rate.subtracting(assumptions.dividendYield)), time = seconds / 31_536_000
        guard spot > 0, time.isFinite, time > 0 else { throw OptionLabDistributionError.invalidInput }
        let distribution = try Lognormal(spot: spot, carry: carry, time: time, sigma: volatility)
        let a = try evaluate(Payoff(input: input, outcome: mid, basis: underlyingMid), distribution: distribution, intervalBudget: intervalBudget)
        let b = try evaluate(Payoff(input: input, outcome: conservative, basis: underlyingMid), distribution: distribution, intervalBudget: intervalBudget)
        return .init(modelVersion: version, confidence: confidence, tailMass: alpha,
            absoluteUSDTolerance: absoluteTolerance, relativeTolerance: relativeTolerance,
            maximumSubintervals: maximumSubintervals, volatility: volatility,
            volatilitySourceContractID: volatilitySourceContractID, rate: rate, dividendYield: dividend, timeYears: time,
            riskNeutralOnly: true, mid: a, conservative: b, limitations: [
                "风险中性到期分布，只反映同一局部 IV、连续股息率与对数正态假设；不是真实世界盈利概率。",
                "EV 为未折现到期损益；本次未选择现值口径。费用沿用对应 Mid／保守损益且只计一次。",
                "最差 5% 按精确质量计入封顶／封底原子，零损益平台不算盈利；保留带符号尾均值。",
                "欧式分布不模拟提前行权、指派、跳跃或离散股息；未启用历史 Bootstrap 或概率校准。"
            ])
    }

    private struct Segment {
        let low: Double
        let high: Double
        let slope: Double
        let intercept: Double
        let lowValue: Double
        func value(_ spot: Double) -> Double { slope == 0 ? intercept : lowValue + slope * (spot - low) }
    }
    private struct Payoff {
        let segments: [Segment]
        let increasing: Bool
        let maximumMagnitude: Double
        let conversionError: Double
        let unchangedSpotPnL: Double
        init(input: OptionLabInput, outcome: OptionLabOutcome, basis: Money) throws {
            let (units, overflow) = input.shortLeg.quantity.multipliedReportingOverflow(by: input.shortLeg.multiplier)
            guard !overflow, units > 0, input.shortLeg.multiplier == 100, input.shortLeg.quantity > 0 else {
                throw OptionLabDistributionError.invalidInput
            }
            let n = Double(units), k = try finite(input.shortLeg.strike), c = try finite(outcome.netCreditTotal)
            guard n.isFinite, Int(exactly: n) == units, k > 0, c > 0 else { throw OptionLabDistributionError.invalidInput }
            let credit = outcome.netCreditTotal, zero = try Money("0")
            func piece(_ low: Double, _ high: Double, _ slope: Double, _ intercept: Money, _ lowValue: Money) throws -> Segment {
                .init(low: low, high: high, slope: slope, intercept: try finite(intercept), lowValue: try finite(lowValue))
            }
            let minValue: Money, maxValue: Money
            switch input.strategy {
            case .cashSecuredPut, .coveredCall:
                guard input.longLeg == nil else { throw OptionLabDistributionError.invalidInput }
                let cost = try (input.strategy == .coveredCall ? basis : input.shortLeg.strike).multiplied(by: String(units))
                minValue = try credit.subtracting(cost)
                maxValue = try minValue.adding(input.shortLeg.strike.multiplied(by: String(units)))
                segments = try [piece(0, k, n, minValue, minValue), piece(k, .infinity, 0, maxValue, maxValue)]
                increasing = true
            case .putCreditSpread, .callCreditSpread:
                guard let long = input.longLeg, long.quantity == input.shortLeg.quantity, long.multiplier == input.shortLeg.multiplier,
                      long.symbol == input.shortLeg.symbol, long.expirationDate == input.shortLeg.expirationDate else {
                    throw OptionLabDistributionError.invalidInput
                }
                let l = try finite(long.strike)
                let put = input.strategy == .putCreditSpread
                guard put ? (l < k) : (l > k) else { throw OptionLabDistributionError.unsafeNumericRepresentation }
                let width = try (put ? input.shortLeg.strike.subtracting(long.strike) : long.strike.subtracting(input.shortLeg.strike)).multiplied(by: String(units))
                minValue = try credit.subtracting(width); maxValue = credit
                if put {
                    let intercept = try credit.subtracting(input.shortLeg.strike.multiplied(by: String(units)))
                    segments = try [piece(0, l, 0, minValue, minValue), piece(l, k, n, intercept, minValue), piece(k, .infinity, 0, credit, credit)]
                } else {
                    let intercept = try credit.adding(input.shortLeg.strike.multiplied(by: String(units)))
                    segments = try [piece(0, k, 0, credit, credit), piece(k, l, -n, intercept, credit), piece(l, .infinity, 0, minValue, minValue)]
                }
                increasing = put
            }
            guard minValue < zero, outcome.maxLoss == (try minValue.multiplied(by: "-1")), outcome.maxProfit == maxValue else {
                throw OptionLabDistributionError.invalidInput
            }
            maximumMagnitude = max(abs(try finite(minValue)), abs(try finite(maxValue)))
            func intrinsic(_ leg: OptionLabLeg) throws -> Money {
                try max(zero, leg.right == .put ? leg.strike.subtracting(basis) : basis.subtracting(leg.strike)).multiplied(by: String(units))
            }
            var exact = try credit.subtracting(intrinsic(input.shortLeg))
            if let long = input.longLeg { exact = try exact.adding(intrinsic(long)) }
            unchangedSpotPnL = try finite(exact)
            // Float64 derived calculations do not silently accept inputs whose
            // decimal geometry has collapsed at a strike or cash boundary.
            conversionError = segments.reduce(0) { $0 + $1.intercept.ulp + $1.lowValue.ulp + (abs($1.slope) * $1.low.ulp) }
            guard conversionError.isFinite, conversionError <= tolerance(maximumMagnitude) / 8 else {
                throw OptionLabDistributionError.unsafeNumericRepresentation
            }
        }
        func value(_ spot: Double) throws -> Double {
            guard spot.isFinite, spot >= 0, let segment = segments.first(where: { spot < $0.high }) else {
                throw OptionLabDistributionError.numericalFailure
            }
            let result = segment.value(spot)
            guard result.isFinite else { throw OptionLabDistributionError.numericalFailure }
            return result
        }
    }

    private struct Lognormal {
        let mean: Double
        let mu: Double
        let scale: Double
        let unchangedSpot: Bool
        init(spot: Double, carry: Double, time: Double, sigma: Double) throws {
            mean = spot * exp(carry * time)
            scale = sigma * sqrt(time)
            mu = log(spot) + carry * time - scale * scale / 2
            unchangedSpot = carry == 0
            guard mean.isFinite, mean > 0, scale.isFinite, mu.isFinite,
                  sigma == 0 || scale > 0 else { throw OptionLabDistributionError.numericalFailure }
        }
        func z(_ spot: Double) -> Double {
            if spot == 0 { return -.infinity }
            if spot == .infinity { return .infinity }
            return (log(spot) - mu) / scale
        }
        func mass(_ low: Double, _ high: Double) -> Double { normalMass(z(low), z(high)) }
        func firstMoment(_ low: Double, _ high: Double) -> Double { mean * normalMass(z(low) - scale, z(high) - scale) }
        func adverseMass(_ spot: Double, increasing: Bool) -> Double {
            increasing ? cdf(z(spot)) : cdf(-z(spot))
        }
        func adverseSpot(_ mass: Double, increasing: Bool) throws -> Double {
            let adverse = try inverseLowerNormal(mass), z = increasing ? adverse : -adverse
            let value = exp(mu + scale * z)
            guard value.isFinite else { throw OptionLabDistributionError.numericalFailure }
            return value
        }
    }

    private static func evaluate(_ payoff: Payoff, distribution: Lognormal, intervalBudget: Int) throws -> OptionLabDistributionOutcome {
        if distribution.scale == 0 {
            // With zero carry and sigma, use the exact decimal payoff. A binary
            // subtraction at a break-even point must not turn zero into profit.
            let pnl = distribution.unchangedSpot ? payoff.unchangedSpotPnL : try payoff.value(distribution.mean)
            return .init(probabilityProfit: pnl > 0 ? 1 : 0, expectedPnL: pnl, presentValueExpectedPnL: nil,
                signedTailMean: pnl, tailLoss: max(0, -pnl), numericalErrorBound: payoff.conversionError, tailSubintervals: 0)
        }
        var probability = 0.0, ev = 0.0, evRoundoff = payoff.conversionError
        var constantTail = 0.0, continuous: (Double, Double)?
        for segment in payoff.segments {
            try Task.checkCancellation()
            let mass = distribution.mass(segment.low, segment.high)
            let moment = distribution.firstMoment(segment.low, segment.high)
            let firstTerm = segment.slope * moment, secondTerm = segment.intercept * mass
            ev += firstTerm + secondTerm
            evRoundoff += 32 * Double.ulpOfOne * (abs(firstTerm) + abs(secondTerm))
            if segment.slope == 0 {
                if segment.intercept > 0 { probability += mass }
            } else {
                let root = -segment.intercept / segment.slope
                if segment.slope > 0 {
                    let lower = max(segment.low, root)
                    if lower < segment.high { probability += distribution.mass(lower, segment.high) }
                } else {
                    let upper = min(segment.high, root)
                    if upper > segment.low { probability += distribution.mass(segment.low, upper) }
                }
            }
            let a = distribution.adverseMass(payoff.increasing ? segment.low : segment.high, increasing: payoff.increasing)
            let b = distribution.adverseMass(payoff.increasing ? segment.high : segment.low, increasing: payoff.increasing)
            let low = min(alpha, a), high = min(alpha, b)
            guard low.isFinite, high.isFinite, low <= high else { throw OptionLabDistributionError.numericalFailure }
            if high > low {
                if segment.slope == 0 { constantTail += segment.intercept * (high - low) }
                else {
                    // Four supported strategies each have exactly one non-flat
                    // segment. Extending to a nonmonotone payoff needs a new model.
                    guard continuous == nil else { throw OptionLabDistributionError.invalidInput }
                    continuous = (low, high)
                }
            }
        }
        guard ev.isFinite, probability.isFinite, probability >= -1e-14, probability <= 1 + 1e-14,
              evRoundoff <= tolerance(ev) else { throw OptionLabDistributionError.numericalFailure }
        let integral: Integral
        if let (low, high) = continuous {
            integral = try integrate(low: low, high: high, constant: constantTail, budget: intervalBudget) { mass in
                try payoff.value(distribution.adverseSpot(mass, increasing: payoff.increasing))
            }
        } else { integral = .init(value: 0, error: 0, intervals: 0) }
        let tail = (constantTail + integral.value) / alpha
        let error = integral.error / alpha + payoff.conversionError + 32 * Double.ulpOfOne * abs(constantTail / alpha)
        guard tail.isFinite, error.isFinite, error <= tolerance(tail) else { throw OptionLabDistributionError.numericalFailure }
        return .init(probabilityProfit: min(1, max(0, probability)), expectedPnL: ev, presentValueExpectedPnL: nil,
            signedTailMean: tail, tailLoss: max(0, -tail), numericalErrorBound: max(error, evRoundoff), tailSubintervals: integral.intervals)
    }

    private struct Integral { let value: Double; let error: Double; let intervals: Int }
    private struct Panel { let low: Double; let high: Double; let value: Double; let error: Double }
    private static func integrate(low: Double, high: Double, constant: Double, budget: Int,
                                  function: (Double) throws -> Double) throws -> Integral {
        var panels = [try panel(low: low, high: high, function: function)]
        var value = panels[0].value, error = panels[0].error
        while error > alpha * tolerance((constant + value) / alpha) / 2 {
            try Task.checkCancellation()
            guard panels.count < budget, let index = panels.indices.max(by: { panels[$0].error < panels[$1].error }) else {
                throw OptionLabDistributionError.numericalFailure
            }
            let old = panels[index], middle = old.low + (old.high - old.low) / 2
            guard middle > old.low, middle < old.high else { throw OptionLabDistributionError.numericalFailure }
            let left = try panel(low: old.low, high: middle, function: function)
            let right = try panel(low: middle, high: old.high, function: function)
            panels[index] = left; panels.append(right)
            value = panels.reduce(0) { $0 + $1.value }; error = panels.reduce(0) { $0 + $1.error }
            guard value.isFinite, error.isFinite else { throw OptionLabDistributionError.numericalFailure }
        }
        return .init(value: value, error: error, intervals: panels.count)
    }
    private static func panel(low: Double, high: Double, function: (Double) throws -> Double) throws -> Panel {
        // Mathematical GK15 nodes/weights, cross-checked against Netlib QUADPACK dqk15.
        let nodes = [0.9914553711208126, 0.9491079123427585, 0.8648644233597691, 0.7415311855993945,
                     0.5860872354676911, 0.4058451513773972, 0.2077849550078985]
        let weights = [0.02293532201052922, 0.06309209262997855, 0.1047900103222502, 0.1406532597155259,
                       0.1690047266392679, 0.1903505780647854, 0.2044329400752989]
        let gauss = [0.1294849661688697, 0.2797053914892767, 0.3818300505051189]
        let half = (high - low) / 2, center = low + half, f0 = try function(center)
        guard half > 0, f0.isFinite else { throw OptionLabDistributionError.numericalFailure }
        var kronrod = 0.2094821410847278 * f0, g7 = 0.4179591836734694 * f0
        var absolute = 0.2094821410847278 * abs(f0), values: [(Double, Double)] = []
        for index in nodes.indices {
            let x = nodes[index] * half
            let a = try function(center - x), b = try function(center + x)
            guard a.isFinite, b.isFinite else { throw OptionLabDistributionError.numericalFailure }
            values.append((a, b)); kronrod += weights[index] * (a + b)
            absolute += weights[index] * (abs(a) + abs(b))
            if index % 2 == 1 { g7 += gauss[index / 2] * (a + b) }
        }
        let average = kronrod / 2
        var deviation = 0.2094821410847278 * abs(f0 - average)
        for index in values.indices { deviation += weights[index] * (abs(values[index].0 - average) + abs(values[index].1 - average)) }
        deviation *= half; absolute *= half
        var error = abs((kronrod - g7) * half)
        if error > 0, deviation > 0 { error = deviation * min(1, pow(200 * error / deviation, 1.5)) }
        error = max(error, 50 * Double.ulpOfOne * absolute)
        return .init(low: low, high: high, value: kronrod * half, error: error)
    }
    private static func cdf(_ x: Double) -> Double { 0.5 * erfc(-x / sqrt(2)) }
    private static func normalMass(_ low: Double, _ high: Double) -> Double {
        if low >= high { return 0 }
        return low > 0 ? cdf(-low) - cdf(-high) : cdf(high) - cdf(low)
    }
    private static func inverseLowerNormal(_ probability: Double) throws -> Double {
        guard probability > 0, probability <= alpha else { throw OptionLabDistributionError.numericalFailure }
        var low = -40.0, high = 0.0
        for _ in 0..<100 {
            let middle = low + (high - low) / 2
            if middle == low || middle == high { break }
            if cdf(middle) < probability { low = middle } else { high = middle }
        }
        let result = low + (high - low) / 2
        guard abs(cdf(result) - probability) <= max(1e-320, probability * 1e-12) else {
            throw OptionLabDistributionError.numericalFailure
        }
        return result
    }
    private static func tolerance(_ value: Double) -> Double { max(absoluteTolerance, relativeTolerance * abs(value)) }
    private static func finite(_ value: Money) throws -> Double {
        guard let number = Double(value.decimalString), number.isFinite,
              value.amount == 0 || number != 0 else { throw OptionLabDistributionError.unsafeNumericRepresentation }
        return number
    }
}
