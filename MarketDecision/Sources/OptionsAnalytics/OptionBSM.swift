import Foundation

/// CALC-023 Float64 European BSM with continuous dividend yield. No American
/// exercise premium, discrete-dividend substitution or provider fallback.
public enum OptionBSM {
    public static let numericPolicyVersion = "bsm-float64-erfc.v1"
    public static func evaluate(_ m: OptionBSMMarket, volatility sigma: Double) -> OptionBSMResult {
        guard valid(m), sigma.isFinite, sigma >= 0 else { return result(.invalidInput) }
        let s = m.spot, k = m.strike, t = m.timeYears, r = m.rate, q = m.dividendYield
        if t == 0 { return result(.expiryBoundary, price: max(0, m.right == .call ? s - k : k - s)) }
        let dq = exp(-q * t), dr = exp(-r * t), sd = s * dq, kd = k * dr
        guard [dq, dr, sd, kd].allSatisfy(\.isFinite) else { return result(.numericFailure) }
        if s == 0 {
            return result(.zeroSpotBoundary, price: m.right == .call ? 0 : kd, probability: m.right == .call ? 0 : 1)
        }
        if sigma == 0 {
            let difference = m.right == .call ? sd - kd : kd - sd
            return result(.zeroVolatilityBoundary, price: max(0, difference), probability: difference > 0 ? 1 : 0)
        }
        let rootT = sqrt(t), scale = sigma * rootT
        let variance = sigma * sigma
        guard scale.isFinite, scale > 0, variance.isFinite else { return result(.numericFailure) }
        let d1 = (log(s) - log(k) + (r - q + 0.5 * variance) * t) / scale, d2 = d1 - scale
        guard d1.isFinite, d2.isFinite else { return result(.numericFailure) }
        let n1 = cdf(d1), n2 = cdf(d2), nm1 = cdf(-d1), nm2 = cdf(-d2), density = exp(-0.5 * d1 * d1) / sqrt(2 * .pi)
        // Compute the out-of-money side and use put/call parity on the other
        // side. This avoids cancellation between two almost equal large terms.
        let price: Double
        if m.right == .call {
            price = sd >= kd ? (sd - kd) + (kd * nm2 - sd * nm1) : sd * n1 - kd * n2
        } else {
            price = kd >= sd ? (kd - sd) + (sd * n1 - kd * n2) : kd * nm2 - sd * nm1
        }
        let gamma = dq * density / (s * scale), vega = sd * density * rootT / 100
        let thetaBase = -sd * density * sigma / (2 * rootT)
        let delta = m.right == .call ? dq * n1 : -dq * nm1
        let theta = (m.right == .call ? thetaBase - r * kd * n2 + q * sd * n1 : thetaBase + r * kd * nm2 - q * sd * nm1) / 365
        let rho = (m.right == .call ? k * t * dr * n2 : -k * t * dr * nm2) / 100
        let greeks = OptionLabGreeks(delta: delta, gamma: gamma, thetaPerDay: theta, vegaPerPercentagePoint: vega, rhoPerPercentagePoint: rho)
        let probability = m.right == .call ? n2 : nm2
        guard price.isFinite, price >= 0, greeks.values.allSatisfy(\.isFinite), probability.isFinite else { return result(.numericFailure) }
        return .init(state: .available, price: price, greeks: greeks, itmProbability: probability)
    }
    public static func priceBounds(_ m: OptionBSMMarket) -> (lower: Double, upper: Double)? {
        guard valid(m) else { return nil }
        let sd = m.spot * exp(-m.dividendYield * m.timeYears), kd = m.strike * exp(-m.rate * m.timeYears)
        guard sd.isFinite, kd.isFinite else { return nil }
        return m.right == .call ? (max(0, sd - kd), sd) : (max(0, kd - sd), kd)
    }
    static func valid(_ m: OptionBSMMarket) -> Bool {
        [m.spot, m.strike, m.rate, m.dividendYield, m.timeYears].allSatisfy(\.isFinite)
            && m.spot >= 0 && m.strike > 0 && m.dividendYield >= 0 && m.timeYears >= 0
    }
    static func cdf(_ x: Double) -> Double { 0.5 * erfc(-x / sqrt(2)) }
    private static func result(_ state: OptionLabPricingState, price: Double? = nil, probability: Double? = nil) -> OptionBSMResult {
        .init(state: state, price: price, greeks: nil, itmProbability: probability)
    }
}

/// Safeguarded Brent-Dekker interpolation/bisection. Both the retained volatility
/// bracket and the price residual must meet selected tolerances before success.
public enum OptionIVSolver {
    public static let lowerVolatility = 0.000001
    public static let upperVolatilities: [Double] = [5, 10, 20]
    public static let maximumIterations = 200
    public static let absoluteSigmaTolerance = 0.00000001
    public static let relativeSigmaTolerance = 0.000000000001
    public static let minimumSeconds = 60.0
    public static func solve(_ market: OptionBSMMarket, price target: Double) throws -> OptionLabIVResult {
        try Task.checkCancellation()
        guard OptionBSM.valid(market), target.isFinite, target >= 0 else { return failure(.invalidInput) }
        guard market.spot > 0 else { return failure(.zeroSpotBoundary) }
        guard market.timeYears >= minimumSeconds / 31_536_000 else { return failure(.tooNearExpiry) }
        guard let bounds = OptionBSM.priceBounds(market) else { return failure(.numericFailure) }
        guard target >= bounds.lower, target <= bounds.upper else { return failure(.arbitrageViolation) }
        // Equality is an asymptotic/degenerate boundary, not an identified positive IV.
        guard target > bounds.lower, target < bounds.upper else { return failure(.boundaryPrice) }
        let priceTolerance = max(0.00000001, abs(target) * 0.00000001)
        func f(_ sigma: Double) -> Double? {
            let result = OptionBSM.evaluate(market, volatility: sigma)
            guard let price = result.price, price.isFinite else { return nil }
            let value = price - target
            return value.isFinite ? value : nil
        }
        var a = lowerVolatility
        guard var fa = f(a) else { return failure(.numericFailure) }
        var b = upperVolatilities[0], fb: Double = 0, found = false
        for upper in upperVolatilities {
            try Task.checkCancellation()
            guard let value = f(upper) else { return failure(.numericFailure) }
            b = upper; fb = value
            if fa <= 0 && fb >= 0 { found = true; break }
        }
        guard found else { return failure(.ivNotBracketed, lower: a, upper: b, priceTolerance: priceTolerance) }
        var c = a, fc = fa, d = b - a, e = d
        for iteration in 1...maximumIterations {
            try Task.checkCancellation()
            if (fb > 0 && fc > 0) || (fb < 0 && fc < 0) {
                c = a; fc = fa; d = b - a; e = d
            }
            if abs(fc) < abs(fb) {
                let oldB = b, oldFB = fb
                a = oldB; fa = oldFB; b = c; fb = fc; c = oldB; fc = oldFB
            }
            let tolerance = absoluteSigmaTolerance + relativeSigmaTolerance * abs(b)
            let midpoint = 0.5 * (c - b), width = abs(c - b)
            if width <= tolerance {
                guard abs(fb) <= priceTolerance else {
                    return failure(.residualNotMet, iterations: iteration, residual: abs(fb), lower: min(b,c), upper: max(b,c), sigmaTolerance: tolerance, priceTolerance: priceTolerance)
                }
                return .init(state: .available, volatility: b, iterations: iteration, residual: abs(fb), bracketLower: min(b,c), bracketUpper: max(b,c), sigmaTolerance: tolerance, priceTolerance: priceTolerance)
            }
            if abs(e) >= tolerance, abs(fa) > abs(fb), fb != 0 {
                let ratio = fb / fa
                var p: Double, q: Double
                if a == c {
                    p = 2 * midpoint * ratio; q = 1 - ratio
                } else {
                    let q0 = fa / fc, r0 = fb / fc
                    p = ratio * (2 * midpoint * q0 * (q0 - r0) - (b - a) * (r0 - 1))
                    q = (q0 - 1) * (r0 - 1) * (ratio - 1)
                }
                if p > 0 { q = -q } else { p = -p }
                let prior = e; e = d
                if p.isFinite, q.isFinite, q != 0,
                   2 * p < min(3 * midpoint * q - abs(tolerance * q), abs(prior * q)) {
                    d = p / q
                } else { d = midpoint; e = midpoint }
            } else { d = midpoint; e = midpoint }
            a = b; fa = fb
            // Do not jump across a narrow bracket merely to satisfy a minimum step.
            let step = abs(d) > tolerance * 0.5 ? d : copysign(min(tolerance * 0.5, abs(midpoint)), midpoint)
            b += step
            guard b.isFinite, let next = f(b) else { return failure(.numericFailure, iterations: iteration) }
            fb = next
        }
        return failure(.ivIterationLimit, iterations: maximumIterations, residual: abs(fb), lower: min(b,c), upper: max(b,c), sigmaTolerance: absoluteSigmaTolerance + relativeSigmaTolerance * abs(b), priceTolerance: priceTolerance)
    }
    static func failure(_ state: OptionLabPricingState, iterations: Int = 0, residual: Double? = nil,
                        lower: Double? = nil, upper: Double? = nil, sigmaTolerance: Double? = nil,
                        priceTolerance: Double? = nil) -> OptionLabIVResult {
        .init(state: state, volatility: nil, iterations: iterations, residual: residual,
              bracketLower: lower, bracketUpper: upper, sigmaTolerance: sigmaTolerance, priceTolerance: priceTolerance)
    }
}
