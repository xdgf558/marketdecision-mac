import Foundation
import CoreDomain
import DataContracts

public enum OptionProviderField: String, Codable, CaseIterable, Sendable {
    case iv, delta, gamma, theta, vega, rho
    public var unit: OptionProviderUnit {
        switch self {
        case .iv: .annualVolatilityDecimal
        case .delta: .perShareDelta
        case .gamma: .perShareGammaPerUSD
        case .theta: .perShareThetaPerCalendarDay
        case .vega: .perShareVegaPerPercentagePoint
        case .rho: .perShareRhoPerPercentagePoint
        }
    }
}

/// Closed units are evidence, not a request to guess a conversion. In particular,
/// a contract Greek, annual theta or vega per 1.0 cannot silently become per-share.
public enum OptionProviderUnit: String, Codable, Sendable {
    case annualVolatilityDecimal, perShareDelta, perShareGammaPerUSD
    case perShareThetaPerCalendarDay, perShareVegaPerPercentagePoint, perShareRhoPerPercentagePoint
    case volatilityPercent, perContract, perShareThetaPerYear, perShareVegaPerUnit, perShareRhoPerUnit
}
public struct OptionProviderValue: Codable, Equatable, Sendable {
    public let value: Double
    public let unit: OptionProviderUnit
    public init(value: Double, unit: OptionProviderUnit) { self.value = value; self.unit = unit }
}

/// Quantity and strategy direction do not belong to a contract's per-share identity.
public struct OptionProviderContract: Codable, Equatable, Sendable {
    public let contractID: String
    public let symbol: String
    public let right: OptionLabRight
    public let strike: Money
    public let multiplier: Int
    public let exerciseStyle: OptionLabExerciseStyle
    public let delivery: OptionLabDelivery
    public let specificationVersion: String
    public let expirationDate: MarketDate
    public let settlementAt: Date
    public init(leg: OptionLabLeg, expiry: OptionLabExpiry) {
        contractID = leg.contractID; symbol = leg.symbol; right = leg.right; strike = leg.strike
        multiplier = leg.multiplier; exerciseStyle = leg.exerciseStyle; delivery = leg.delivery
        specificationVersion = leg.specificationVersion; expirationDate = leg.expirationDate
        settlementAt = expiry.settlementAt
    }
}

public enum OptionProviderModelFamily: String, Codable, Sendable {
    case europeanBSMContinuousDividend, american, other, unknown
}
public struct OptionProviderModel: Codable, Equatable, Sendable {
    public let family: OptionProviderModelFamily
    public let version: String
    public let spot: Money?
    public let continuousRate: Money?
    public let continuousDividendYield: Money?
    public let volatilityUsedForGreeks: Double?
    public let reference: String
    public init(family: OptionProviderModelFamily, version: String, spot: Money?, continuousRate: Money?,
                continuousDividendYield: Money?, volatilityUsedForGreeks: Double?, reference: String) {
        self.family = family; self.version = version; self.spot = spot; self.continuousRate = continuousRate
        self.continuousDividendYield = continuousDividendYield; self.volatilityUsedForGreeks = volatilityUsedForGreeks
        self.reference = reference
    }
}

/// An explicit offline observation. These declarations never grant provider admission,
/// real-time qualification or historical availability; the complete local report is retained.
public struct OptionProviderObservation: Codable, Equatable, Sendable {
    public let id: String
    public let providerID: String
    public let feedID: String
    public let contract: OptionProviderContract
    public let valuationAt: Date
    public let quoteTime: Date
    public let underlyingQuoteTime: Date
    public let receivedAt: Date
    public let source: OptionLabSource
    public let model: OptionProviderModel
    public let values: [OptionProviderField: OptionProviderValue]
    public init(id: String, providerID: String, feedID: String, contract: OptionProviderContract,
                valuationAt: Date, quoteTime: Date, underlyingQuoteTime: Date, receivedAt: Date,
                source: OptionLabSource, model: OptionProviderModel, values: [OptionProviderField: OptionProviderValue]) {
        self.id = id; self.providerID = providerID; self.feedID = feedID; self.contract = contract
        self.valuationAt = valuationAt; self.quoteTime = quoteTime; self.underlyingQuoteTime = underlyingQuoteTime
        self.receivedAt = receivedAt; self.source = source; self.model = model; self.values = values
    }
}
public struct OptionProviderComparisonInput: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let localReport: OptionLabReport
    /// For manual/synthetic reports this is an explicit offline label; for a captured
    /// chain it must equal the frozen capture's feed ID. It cannot qualify either feed.
    public let localFeedID: String
    public let observations: [OptionProviderObservation]
    public init(id: UUID = UUID(), createdAt: Date, localReport: OptionLabReport, localFeedID: String,
                observations: [OptionProviderObservation]) {
        self.id = id; self.createdAt = createdAt; self.localReport = localReport
        self.localFeedID = localFeedID; self.observations = observations
    }
}
public enum OptionProviderComparisonState: String, Codable, Sendable {
    case compared, missingLocalValue, missingProviderValue, missingBothValues
}
public enum OptionProviderModelComparison: String, Codable, Sendable {
    case sameEuropeanReference, differentAssumptions, differentModel, unknownModel, missingLocalPricing
}
public struct OptionProviderComparisonField: Codable, Equatable, Sendable {
    public let field: OptionProviderField
    public let unit: OptionProviderUnit
    public let local: Double?
    public let provider: Double?
    /// Signed local minus provider, never an aggregate/position Greek.
    public let difference: Double?
    public let state: OptionProviderComparisonState
    /// Nil means no approved numerical alert threshold, not "within tolerance".
    public let absoluteThreshold: Double?
    public let thresholdExceeded: Bool?
}
public struct OptionProviderComparisonLeg: Codable, Equatable, Sendable {
    public let contractID: String
    public let observationID: String?
    public let modelComparison: OptionProviderModelComparison
    public let fields: [OptionProviderComparisonField]
    public let warnings: [String]
}
public struct OptionProviderComparisonReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let input: OptionProviderComparisonInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let rows: [OptionProviderComparisonLeg]
    public let containsSynthetic: Bool
    public let researchOnly: Bool
    public let limitations: [String]
}
public enum OptionProviderComparisonError: Error, Equatable, LocalizedError {
    case invalidInput, duplicateObservation, mismatchedContract, mismatchedFeed, mismatchedTime, invalidUnit, invalidValue, incompatibleReport
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "供应商对照须保留完整离线来源、模型和输入。"
        case .duplicateObservation: "同一合约只能绑定一份供应商观察，观察标识也不得重复。"
        case .mismatchedContract: "供应商观察与本地合约的身份、规格或到期时刻不一致。"
        case .mismatchedFeed: "供应商观察与本地报价的数据源不一致。"
        case .mismatchedTime: "供应商观察与本地报价、标的和估值时刻不一致，或接收时刻无效。"
        case .invalidUnit: "供应商字段单位不一致；不会猜测合约、年度或百分比换算。"
        case .invalidValue: "供应商字段必须是有限值，并满足字段取值范围。"
        case .incompatibleReport: "对照报告与完整输入重放不一致，不能展示为已核对结果。"
        }
    }
}
