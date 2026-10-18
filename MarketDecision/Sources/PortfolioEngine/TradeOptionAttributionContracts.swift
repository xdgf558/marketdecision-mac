import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

public enum TradeOptionAttributionMode: String, Codable, Sendable { case ledger, synthetic }
public enum TradeOptionIVRankBasis: String, Codable, Sendable { case recordedUnverified, replayedHistory }
/// An explicit historical record, not proof that a source was genuinely available at that time.
/// The complete record bytes and declared source/availability remain frozen for inspection.
public struct TradeOptionIVRankObservation: Codable, Equatable, Sendable {
    public let value: Double
    public let symbol: String
    public let feedID: String
    public let session: MarketDate
    public let observedAt: Date
    public let knownAt: Date
    public let methodReference: String
    public let source: PerformanceEvidence
    /// Nil means a recorded value with unverified methodology, never a canonical local IV Rank.
    public let history: OptionVolatilityHistoryReport?
    public var basis: TradeOptionIVRankBasis { history == nil ? .recordedUnverified : .replayedHistory }
    public init(value: Double, symbol: String, feedID: String, session: MarketDate, observedAt: Date,
                knownAt: Date, methodReference: String, source: PerformanceEvidence, history: OptionVolatilityHistoryReport? = nil) {
        self.value = value; self.symbol = symbol; self.feedID = feedID; self.session = session
        self.observedAt = observedAt; self.knownAt = knownAt; self.methodReference = methodReference
        self.source = source; self.history = history
    }
}
public struct TradeOptionObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let openingEventID: String
    public let lotID: String
    public let instrumentIdentity: String
    public let contractID: String
    /// An explicit source identifier. A manual identifier is not a provider entitlement.
    public let feedID: String
    public let session: MarketDate
    public let observedAt: Date
    public let knownAt: Date
    public let source: PerformanceEvidence
    public let report: OptionLabReport
    public let ivRank: TradeOptionIVRankObservation?
    public init(id: String, accountID: String, openingEventID: String, lotID: String, instrumentIdentity: String,
                contractID: String, feedID: String, session: MarketDate, observedAt: Date, knownAt: Date,
                source: PerformanceEvidence, report: OptionLabReport, ivRank: TradeOptionIVRankObservation? = nil) {
        self.id = id; self.accountID = accountID; self.openingEventID = openingEventID; self.lotID = lotID
        self.instrumentIdentity = instrumentIdentity; self.contractID = contractID; self.feedID = feedID; self.session = session
        self.observedAt = observedAt; self.knownAt = knownAt; self.source = source; self.report = report; self.ivRank = ivRank
    }
}
public struct TradeOptionAttributionInput: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let mode: TradeOptionAttributionMode
    public let performance: PerformanceInput
    public let observations: [TradeOptionObservation]
    public var containsSynthetic: Bool { mode == .synthetic }
    public init(id: UUID = UUID(), createdAt: Date, mode: TradeOptionAttributionMode,
                performance: PerformanceInput, observations: [TradeOptionObservation]) {
        self.id = id; self.createdAt = createdAt; self.mode = mode; self.performance = performance; self.observations = observations
    }
}
public enum TradeOptionAttributionGap: String, Codable, Sendable {
    case missingObservation, missingCanonicalIV, missingIVRank, transferredOpening
}
public enum TradeOptionAttributionAxis: String, Codable, Sendable { case absoluteDelta, ivRank }
public struct TradeOptionAttributionRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String { round.roundLotID }
    public let round: PerformanceRound
    public let openingEventID: String
    public let instrument: LedgerInstrument
    public let observationID: String?
    /// Canonical per-share long-option Delta, independent of trade side and quantity.
    public let delta: Double?
    public let impliedVolatility: Double?
    public let ivRank: Double?
    public let ivRankBasis: TradeOptionIVRankBasis?
    public let deltaGap: TradeOptionAttributionGap?
    public let ivRankGap: TradeOptionAttributionGap?
}
public struct TradeOptionAttributionGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let axis: TradeOptionAttributionAxis
    public let label: String
    /// Recorded values and locally replayed history never share a statistics bucket.
    public let ivRankBasis: TradeOptionIVRankBasis?
    public let roundIDs: [String]
    public let completedNetPnL: Money?
    public let statistics: PerformanceTradeStatistics
}
public struct TradeOptionAttributionReport: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { input.id }
    public var containsSynthetic: Bool { input.containsSynthetic }
    public let schemaVersion: String
    public let input: TradeOptionAttributionInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let performanceEngineVersion: String
    public let performanceParametersVersion: String
    public let rows: [TradeOptionAttributionRow]
    public let groupedStatistics: [TradeOptionAttributionGroup]
    public let excludedNonOptionRoundIDs: [String]
    public let researchOnly: Bool
    public let limitations: [String]
}
public enum TradeOptionAttributionError: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, duplicateObservation, unknownOpening, mismatchedContract, invalidTiming, invalidEvidence, syntheticEvidence, incompatibleReport
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "交易归因输入、账户或记录不完整。"
        case .duplicateObservation: "同一开仓事件或 lot 存在多个观察，不能猜测选择。"
        case .unknownOpening: "观察未对应冻结账本中的唯一活动期权开仓。"
        case .mismatchedContract: "观察与开仓合约、标的、会话或数据源不一致。"
        case .invalidTiming: "观察或可得时间晚于开仓，或 Delta 报价不在开仓前 60 秒内。"
        case .invalidEvidence: "来源、数值或记录方法证据不完整。"
        case .syntheticEvidence: "合成记录只能留在独立合成示例。"
        case .incompatibleReport: "完整输入、模型或结果无法一致重放。"
        }
    }
}
