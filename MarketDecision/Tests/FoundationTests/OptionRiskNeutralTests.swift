import Foundation
import Testing
import CoreDomain
@testable import OptionsAnalytics

private func rnInput(strategy: OptionLabStrategy = .cashSecuredPut, spot: String = "100", flatPremium: Bool = false) throws -> OptionLabInput {
    // June/July contains no NY DST boundary: exactly 30 * 86400 seconds.
    let base = try OptionLabDemo.input(strategy: strategy, at: Date(timeIntervalSince1970: 1_782_864_000))
    let old = base.shortLeg
    let short = flatPremium ? OptionLabLeg(contractID: old.contractID, symbol: old.symbol, right: old.right, strike: old.strike,
        quantity: old.quantity, expirationDate: old.expirationDate, bid: try Money("0.1"), ask: try Money("0.1"),
        bidSize: old.bidSize, askSize: old.askSize, tick: old.tick, quotedAt: old.quotedAt, receivedAt: old.receivedAt, source: old.source) : old
    return try .init(createdAt: base.createdAt, asOf: base.asOf, strategy: strategy, shortLeg: short, longLeg: base.longLeg,
        underlying: .init(symbol: base.underlying.symbol, bid: Money(spot), ask: Money(spot), quotedAt: base.asOf,
            receivedAt: base.asOf, source: base.underlying.source), capital: base.capital,
        policy: flatPremium ? .init(lambda: Money("0.25"), openingFeePerContract: Money("0"), ticketFee: Money("0"), terminalFeeTotal: Money("0")) : base.policy,
        expiry: base.expiry, scenarioPrices: base.scenarioPrices)
}
private func rnAnalyze(_ input: OptionLabInput, rate: String = "0.03", dividend: String = "0.01", sigma: Double = 0.2,
                       intervalBudget: Int = 10_000, theorySigma: String = "0.77", sourceID: String? = nil) throws -> OptionLabDistributionReport {
    let payoff = try OptionLabEngine.calculate(input)
    let assumptions = OptionLabPricingInput(rate: try Money(rate), dividendYield: try Money(dividend), volatility: try Money(theorySigma), source: input.shortLeg.source)
    return try OptionLabDistribution.analyze(input: input, mid: payoff.mid, conservative: payoff.conservative,
        underlyingMid: payoff.underlyingMid, assumptions: assumptions, volatility: sigma,
        volatilitySourceContractID: sourceID ?? input.shortLeg.contractID, intervalBudget: intervalBudget)
}
private struct RNOracle {
    let strategy: OptionLabStrategy
    let spot: String
    let sigma: Double
    let rate: String
    let dividend: String
    let mid: [Double]
    let conservative: [Double]
}
// Independent 90-digit Python Decimal oracle: erf power series + exact truncated
// lognormal moments for BOTH EV and tail (no Float64/GK implementation reuse).
// Ordered outputs: strict POP, undiscounted EV, signed 5% tail mean.
// The 0.1 spread cases have floor atoms of 0.03346437 / 0.04857464;
// the 0.2 cases have atoms greater than 5%, so only 5% of the atom is used.
private let rnOracles: [String: RNOracle] = [
    "csp": .init(strategy: .cashSecuredPut, spot: "100", sigma: 0.2, rate: "0.03", dividend: "0.01",
        mid: [0.65055255052962535, -1.4213026784988965, -894.11289090218565], conservative: [0.64393251051749145, -11.421302678498897, -904.11289090218565]),
    "covered": .init(strategy: .coveredCall, spot: "100", sigma: 0.2, rate: "0.03", dividend: "0.01",
        mid: [0.65055255052962535, -1.4213026784988965, -894.11289090218565], conservative: [0.64393251051749145, -11.421302678498897, -904.11289090218565]),
    "put-partial": .init(strategy: .putCreditSpread, spot: "100", sigma: 0.1, rate: "0.03", dividend: "0.01",
        mid: [0.68964089111554128, 25.822623103269585, -362.39205809231407], conservative: [0.67070823552267655, 10.822623103269585, -377.39205809231407]),
    "call-partial": .init(strategy: .callCreditSpread, spot: "100", sigma: 0.1, rate: "0.03", dividend: "0.01",
        mid: [0.65654330726952093, 11.970141330308937, -371.23979247834677], conservative: [0.63733814229722907, -3.0298586696910617, -386.23979247834677]),
    "negative-rate": .init(strategy: .cashSecuredPut, spot: "100", sigma: 0.3, rate: "-0.02", dividend: "0.01",
        mid: [0.57385695508083068, -135.69576581952583, -1453.5511854626448], conservative: [0.56919329946292696, -145.69576581952583, -1463.5511854626448]),
    "covered-zero": .init(strategy: .coveredCall, spot: "102.1935", sigma: 0.2, rate: "0.03", dividend: "0.01",
        mid: [0, -132.24287221256668, -918.53669941412511], conservative: [0, -142.24287221256668, -928.53669941412511]),
    "covered-all-loss": .init(strategy: .coveredCall, spot: "110", sigma: 0.2, rate: "0.03", dividend: "0.01",
        mid: [0, -791.89932045760543, -1005.6364091521081], conservative: [0, -801.89932045760543, -1015.6364091521081]),
    "put-atom": .init(strategy: .putCreditSpread, spot: "100", sigma: 0.2, rate: "0.03", dividend: "0.01",
        mid: [0.58936604769538348, -38.264460255613116, -371.30000000000001], conservative: [0.57903797440197735, -53.264460255613116, -386.30000000000001]),
    "call-atom": .init(strategy: .callCreditSpread, spot: "100", sigma: 0.2, rate: "0.03", dividend: "0.01",
        mid: [0.58824217416301394, -40.584801892573438, -371.30000000000001], conservative: [0.57815596046042095, -55.584801892573438, -386.30000000000001]),
]

@Suite("Risk-neutral piecewise payoff distribution and independent numerical vectors")
struct OptionRiskNeutralTests {
    @Test(arguments: ["csp", "covered", "put-partial", "call-partial", "negative-rate", "covered-zero", "covered-all-loss", "put-atom", "call-atom"])
    func independentHighPrecisionVectors(_ name: String) throws {
        let vector = try #require(rnOracles[name])
        let report = try rnAnalyze(rnInput(strategy: vector.strategy, spot: vector.spot), rate: vector.rate, dividend: vector.dividend, sigma: vector.sigma)
        #expect(abs(report.timeYears - 30.0 / 365) < 1e-15)
        for (result, oracle) in [(report.mid, vector.mid), (report.conservative, vector.conservative)] {
            try #require(oracle.count == 3)
            #expect(abs(result.probabilityProfit - oracle[0]) < 1e-11)
            #expect(abs(result.expectedPnL - oracle[1]) < 1e-8)
            #expect(abs(result.signedTailMean - oracle[2]) <= max(1e-8, abs(oracle[2]) * 1e-8))
            #expect(result.tailLoss == max(0, -result.signedTailMean))
            #expect(result.presentValueExpectedPnL == nil)
            #expect(result.numericalErrorBound <= max(1e-8, max(abs(result.expectedPnL), abs(result.signedTailMean)) * 1e-8))
        }
        let creditDifference = vector.strategy == .cashSecuredPut || vector.strategy == .coveredCall ? 10.0 : 15.0
        #expect(abs(report.mid.expectedPnL - report.conservative.expectedPnL - creditDifference) < 1e-9)
        #expect(abs(report.mid.signedTailMean - report.conservative.signedTailMean - creditDifference) < 1e-6)
    }

    @Test func atomLargerThanTailUsesOnlyFivePercentWithoutNumericalQuadrature() throws {
        for strategy in [OptionLabStrategy.putCreditSpread, .callCreditSpread] {
            let report = try rnAnalyze(rnInput(strategy: strategy))
            #expect(abs(report.mid.signedTailMean + 371.3) < 1e-10)
            #expect(report.mid.tailSubintervals == 0)
            #expect(report.conservative.tailSubintervals == 0)
        }
    }

    @Test func partialAtomIncludesOnlyRemainingContinuousMass() throws {
        for strategy in [OptionLabStrategy.putCreditSpread, .callCreditSpread] {
            let report = try rnAnalyze(rnInput(strategy: strategy), sigma: 0.1)
            #expect(report.mid.signedTailMean > -371.3)
            #expect(report.mid.tailSubintervals > 0)
        }
    }

    @Test func coveredCallZeroPlateauAndAllLossNeverCountAsProfit() throws {
        let zero = try rnAnalyze(rnInput(strategy: .coveredCall, spot: "102.1935"))
        let loss = try rnAnalyze(rnInput(strategy: .coveredCall, spot: "110"))
        #expect(zero.mid.probabilityProfit == 0); #expect(zero.conservative.probabilityProfit == 0)
        #expect(loss.mid.probabilityProfit == 0); #expect(loss.conservative.probabilityProfit == 0)
        #expect(zero.mid.expectedPnL < 0); #expect(loss.mid.expectedPnL < 0)
    }

    @Test func zeroVolatilityIsDeterministicAndPositiveTailKeepsItsSign() throws {
        let positive = try rnAnalyze(rnInput(flatPremium: true), rate: "0", dividend: "0", sigma: 0)
        #expect(positive.mid.probabilityProfit == 1)
        #expect(positive.mid.expectedPnL == 10)
        #expect(positive.mid.signedTailMean == 10)
        #expect(positive.mid.tailLoss == 0)
        #expect(positive.mid.tailSubintervals == 0)
        let exactZero = try rnAnalyze(rnInput(spot: "97.8065"), rate: "0", dividend: "0", sigma: 0)
        #expect(exactZero.mid.expectedPnL == 0)
        #expect(exactZero.mid.probabilityProfit == 0)
        #expect(exactZero.mid.signedTailMean == 0)
        #expect(exactZero.conservative.expectedPnL == -10)
        #expect(exactZero.conservative.tailLoss == 10)
    }

    @Test func zeroVolatilityStillUsesNegativeCarryAndExactExpiryDuration() throws {
        let report = try rnAnalyze(rnInput(), rate: "-0.02", dividend: "0.01", sigma: 0)
        // Closed deterministic forward, independent of quantile/GK code.
        let expected = 219.35 + 100 * (100 * exp(-0.03 * 30 / 365) - 100)
        #expect(abs(report.mid.expectedPnL - expected) < 1e-9)
        #expect(report.mid.probabilityProfit == 1)
        #expect(report.mid.signedTailMean == report.mid.expectedPnL)
        #expect(report.mid.tailLoss == 0)
    }

    @Test func insufficientQuadratureBudgetRejectsRatherThanReturningAnEstimate() throws {
        #expect(throws: OptionLabDistributionError.numericalFailure) {
            try rnAnalyze(rnInput(), intervalBudget: 1)
        }
        let report = try rnAnalyze(rnInput())
        #expect(report.mid.tailSubintervals > 1)
        #expect(report.mid.tailSubintervals <= 10_000)
    }

    @Test func volatilitySourceAndManualTheorySigmaStayDistinctAcrossReplay() throws {
        let input = try rnInput(strategy: .putCreditSpread)
        let canonical = try rnAnalyze(input, sigma: 0.1, theorySigma: "0.77")
        #expect(try rnAnalyze(input, sigma: 0.1, theorySigma: "0.05") == canonical)
        #expect(canonical.volatility == 0.1)
        #expect(canonical.volatilitySourceContractID == input.shortLeg.contractID)
        let sensitivity = try rnAnalyze(input, sigma: 0.2, sourceID: input.longLeg?.contractID)
        #expect(sensitivity.volatilitySourceContractID == input.longLeg?.contractID)
        #expect(sensitivity.mid.probabilityProfit != canonical.mid.probabilityProfit)
        #expect(try JSONDecoder().decode(OptionLabDistributionReport.self, from: JSONEncoder().encode(canonical)) == canonical)
        #expect(canonical.riskNeutralOnly)
        #expect(canonical.maximumSubintervals == 10_000)
        #expect(canonical.absoluteUSDTolerance == 1e-8 && canonical.relativeTolerance == 1e-8)
        #expect(canonical.confidence == 0.95 && canonical.tailMass == 0.05)
    }

    @Test func invalidOrUnrepresentableInputsDoNotProduceFinancialValues() throws {
        let input = try rnInput()
        for sigma in [-0.1, Double.nan, Double.infinity, 20.1] {
            #expect(throws: OptionLabDistributionError.invalidInput) { try rnAnalyze(input, sigma: sigma) }
        }
        #expect(throws: OptionLabDistributionError.invalidInput) { try rnAnalyze(input, sourceID: "unrelated-contract") }
        #expect(throws: OptionLabDistributionError.numericalFailure) { try rnAnalyze(input, rate: "100000") }
    }

    @Test func alreadyCancelledAnalysisReturnsNoPartialDistribution() async throws {
        let input = try rnInput()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try rnAnalyze(input)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
