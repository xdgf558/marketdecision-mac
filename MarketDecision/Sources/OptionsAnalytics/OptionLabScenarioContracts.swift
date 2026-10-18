import Foundation
import CoreDomain

/// Explicit instantaneous sensitivities, not probabilities or forecasts. The
/// price axis uses ratios (-0.10 = -10%); the IV axis uses percentage points
/// (-10 = minus 10 points, or -0.10 in annualized sigma). No calendar advance.
public struct OptionLabScenarioInput: Sendable, Codable, Equatable {
    public static let currentMethodVersion = "options.scenario-matrix.v1"
    public let source: OptionLabSource
    public let spotShocks: [Money]
    public let volatilityPointShocks: [Money]
    public let methodVersion: String
    public init(source: OptionLabSource, spotShocks: [Money], volatilityPointShocks: [Money],
                methodVersion: String = currentMethodVersion) {
        self.source = source; self.spotShocks = spotShocks
        self.volatilityPointShocks = volatilityPointShocks; self.methodVersion = methodVersion
    }
}

public enum OptionLabScenarioState: String, Sendable, Codable {
    case available, zeroVolatilityBoundary, zeroSpotPayoffBoundary
    case missingPricing, missingLegIV, negativeVolatility, numericFailure
}

public struct OptionLabScenarioLeg: Sendable, Codable, Equatable {
    public let contractID: String
    public let direction: OptionLabDirection
    public let baseIV: Double?
    public let shockedIV: Double?
    public let theoreticalUnitPrice: Double?
    public let state: OptionLabScenarioState
    /// The original local inversion failure remains distinct from matrix state.
    public let ivState: OptionLabPricingState?
}

public struct OptionLabScenarioOutcome: Sendable, Codable, Equatable {
    public let pricing: OptionLabPricing
    public let grossCredit: Money
    public let totalFees: Money
    public let netCreditTotal: Money
    /// Signed option market value plus covered-call stock market value, USD.
    public let theoreticalPositionValue: Double
    /// Change in the covered stock from the original underlying Mid; otherwise 0.
    public let stockPnL: Double
    /// Opening net credit + signed option value + stock PnL. Original full fee
    /// allowance is charged once; no new exit spread/fee or financing is invented.
    public let closeoutPnL: Double
}

public struct OptionLabScenarioCell: Sendable, Codable, Equatable {
    public let spotShock: Money
    public let volatilityPointShock: Money
    /// Effective scenario price. Nonpositive raw shocked price has the explicit
    /// CALC-035 zero-spot terminal-payoff boundary, not a negative stock price.
    public let spot: Money?
    public let state: OptionLabScenarioState
    public let legs: [OptionLabScenarioLeg]
    public let mid: OptionLabScenarioOutcome?
    public let conservative: OptionLabScenarioOutcome?
}

public struct OptionLabScenarioReport: Sendable, Codable, Equatable {
    public let input: OptionLabScenarioInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
    public let valuationAt: Date
    public let baseSpot: Money
    /// Input axis order is retained, price-major then IV-point-minor.
    public let cells: [OptionLabScenarioCell]
    public let warnings: [String]
}

public enum OptionLabScenarioError: Error, Equatable, LocalizedError {
    case invalidGrid, invalidSource, incompatibleContext
    public var errorDescription: String? {
        switch self {
        case .invalidGrid: "价格与 IV 冲击各须 1 至 21 个不重复值；IV 按绝对百分点填写。"
        case .invalidSource: "请提供有效的手工或合成情景来源。"
        case .incompatibleContext: "情景矩阵与本次固定定价、完整策略输入不一致。"
        }
    }
}
