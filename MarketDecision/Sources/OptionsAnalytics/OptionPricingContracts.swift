import Foundation
import CoreDomain

/// Explicit continuous-rate assumptions. volatility is ONLY the independent
/// theoretical-price sigma; canonical Greeks/distributions never fall back to it.
public struct OptionLabPricingInput: Sendable, Codable, Equatable {
    public static let currentMethodVersion = "options.bsm-risk-neutral.v1"
    public let rate: Money
    public let dividendYield: Money
    public let volatility: Money
    public let source: OptionLabSource
    public let methodVersion: String
    public init(rate: Money, dividendYield: Money, volatility: Money, source: OptionLabSource,
                methodVersion: String = currentMethodVersion) {
        self.rate = rate; self.dividendYield = dividendYield; self.volatility = volatility
        self.source = source; self.methodVersion = methodVersion
    }
}
public enum OptionLabPricingState: String, Sendable, Codable {
    case available, expiryBoundary, zeroVolatilityBoundary, zeroSpotBoundary
    case tooNearExpiry, boundaryPrice, arbitrageViolation, ivNotBracketed, ivIterationLimit
    case residualNotMet, numericFailure, invalidInput, missingLegIV, notApplicable
}

/// Per-share BSM derivatives: theta per calendar day; vega/rho per ONE percentage
/// point (0.01 change in sigma/r). Position aggregation multiplies signed shares.
public struct OptionLabGreeks: Sendable, Codable, Equatable {
    public let delta: Double
    public let gamma: Double
    public let thetaPerDay: Double
    public let vegaPerPercentagePoint: Double
    public let rhoPerPercentagePoint: Double
    public init(delta: Double, gamma: Double, thetaPerDay: Double, vegaPerPercentagePoint: Double, rhoPerPercentagePoint: Double) {
        self.delta = delta; self.gamma = gamma; self.thetaPerDay = thetaPerDay
        self.vegaPerPercentagePoint = vegaPerPercentagePoint; self.rhoPerPercentagePoint = rhoPerPercentagePoint
    }
    var values: [Double] { [delta, gamma, thetaPerDay, vegaPerPercentagePoint, rhoPerPercentagePoint] }
}
public struct OptionBSMMarket: Sendable, Equatable {
    public let right: OptionLabRight
    public let spot: Double
    public let strike: Double
    public let rate: Double
    public let dividendYield: Double
    public let timeYears: Double
    public init(right: OptionLabRight, spot: Double, strike: Double, rate: Double, dividendYield: Double, timeYears: Double) {
        self.right = right; self.spot = spot; self.strike = strike; self.rate = rate
        self.dividendYield = dividendYield; self.timeYears = timeYears
    }
}
public struct OptionBSMResult: Sendable, Codable, Equatable {
    public let state: OptionLabPricingState
    public let price: Double?
    public let greeks: OptionLabGreeks?
    public let itmProbability: Double?
}
public struct OptionLabIVResult: Sendable, Codable, Equatable {
    public let state: OptionLabPricingState
    public let volatility: Double?
    public let iterations: Int
    public let residual: Double?
    public let bracketLower: Double?
    public let bracketUpper: Double?
    public let sigmaTolerance: Double?
    public let priceTolerance: Double?
}
public struct OptionLabLegPricing: Sendable, Codable, Equatable {
    public let contractID: String
    public let direction: OptionLabDirection
    public let quoteMid: Money
    public let theoreticalPrice: Double?
    public let theoryState: OptionLabPricingState
    public let expiryIntrinsicValue: Double
    public let impliedVolatility: OptionLabIVResult
    public let canonicalGreeks: OptionLabGreeks?
    public let itmProbability: Double?
    public let absoluteDelta: Double?
    /// absDelta minus risk-neutral ITM probability, not a probability correction.
    public let itmDeltaDifference: Double?
    public let warnings: [String]
}
public struct OptionLabPricingReport: Sendable, Codable, Equatable {
    public let input: OptionLabPricingInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
    public let numericPolicyVersion: String
    public let timeYears: Double
    public let legs: [OptionLabLegPricing]
    public let aggregateGreeks: OptionLabGreeks?
    public let aggregateState: OptionLabPricingState
    public let distribution: OptionLabDistributionReport?
    public let distributionState: OptionLabPricingState
    public let longLegSensitivity: OptionLabDistributionReport?
    public let longLegSensitivityState: OptionLabPricingState
    public let warnings: [String]
}
