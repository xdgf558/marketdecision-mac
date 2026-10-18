import Foundation
import CoreDomain
import DataContracts

public enum OptionDailyCoverage: String, Codable, Sendable { case complete, partial }
public enum OptionDailyState: String, Codable, Sendable {
    case available, partialChain, unknownQuoteTime, staleQuote, quoteSkew, invalidQuote, missingTick
    case missingATMCallOrPut, missingCanonicalIV, noBracket, numericFailure, unverifiedSessionClose
}
public enum OptionDailyError: Error, Equatable, LocalizedError {
    case invalidIdentity, duplicateContract, mismatchedSource, invalidTime, invalidInput, incompatibleReport, invalidCalendar
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "日摘要须保留唯一身份、标的、数据源及来源说明。"
        case .duplicateContract: "日摘要包含重复合约或相同到期、行权价和方向的重复报价。"
        case .mismatchedSource: "链、标的与合约的会话、数据源或标的报价引用不一致。"
        case .invalidTime: "日摘要时间或独立持仓量发布时间无效。"
        case .invalidInput: "日摘要输入超出支持范围。"
        case .incompatibleReport: "日摘要或历史结果与固定输入重算不一致，不能作为已核对结果。"
        case .invalidCalendar: "须提供明确、唯一的离线会话日历；不会由工作日推定真实交易日。"
        }
    }
}

/// Only an explicitly declared offline session calendar. Neither a manual declaration
/// nor the synthetic weekday fixture grants official trading-calendar or PIT eligibility.
public struct OptionDailyCalendar: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let sessions: [MarketDate]
    public let source: OptionLabSource
    public init(id: String, version: String, sessions: [MarketDate], source: OptionLabSource) {
        self.id = id; self.version = version; self.sessions = sessions; self.source = source
    }
}
public struct OptionDailyUnderlying: Codable, Equatable, Sendable {
    public let quoteID: String
    public let symbol: String
    public let feedID: String
    public let session: MarketDate
    public let bid: Money
    public let ask: Money
    public let quoteTime: Date?
    public let receivedAt: Date?
    public let source: OptionLabSource
    public init(quoteID: String, symbol: String, feedID: String, session: MarketDate, bid: Money, ask: Money,
                quoteTime: Date?, receivedAt: Date?, source: OptionLabSource) {
        self.quoteID = quoteID; self.symbol = symbol; self.feedID = feedID; self.session = session
        self.bid = bid; self.ask = ask; self.quoteTime = quoteTime; self.receivedAt = receivedAt; self.source = source
    }
}
/// Volume is the declared full-session count in contracts. OI retains its own
/// observation session and release instant; neither is inferred from quote time.
public struct OptionDailyActivity: Codable, Equatable, Sendable {
    public let volume: Int?
    public let volumeSession: MarketDate?
    public let openInterest: Int?
    public let openInterestAsOf: MarketDate?
    public let openInterestReleasedAt: Date?
    /// Explicit offline declaration; nil is unknown, not an implicit latest vintage.
    public let openInterestLatestPublished: Bool?
    public let source: OptionLabSource
    public init(volume: Int? = nil, volumeSession: MarketDate? = nil, openInterest: Int? = nil,
                openInterestAsOf: MarketDate? = nil, openInterestReleasedAt: Date? = nil, openInterestLatestPublished: Bool? = nil, source: OptionLabSource) {
        self.volume = volume; self.volumeSession = volumeSession; self.openInterest = openInterest
        self.openInterestAsOf = openInterestAsOf; self.openInterestReleasedAt = openInterestReleasedAt
        self.openInterestLatestPublished = openInterestLatestPublished; self.source = source
    }
}
public struct OptionDailyContractInput: Codable, Equatable, Sendable {
    public let contractID: String
    public let symbol: String
    public let feedID: String
    public let session: MarketDate
    public let underlyingQuoteID: String
    public let right: OptionLabRight
    public let strike: Money
    public let expiry: OptionLabExpiry
    public let exerciseStyle: OptionLabExerciseStyle
    public let multiplier: Int
    public let specificationVersion: String
    public let bid: Money
    public let ask: Money
    public let bidSize: Int
    public let askSize: Int
    public let tick: Money?
    public let quoteTime: Date?
    public let receivedAt: Date?
    public let activity: OptionDailyActivity
    public let source: OptionLabSource
    public init(contractID: String, symbol: String, feedID: String, session: MarketDate, underlyingQuoteID: String,
                right: OptionLabRight, strike: Money, expiry: OptionLabExpiry,
                exerciseStyle: OptionLabExerciseStyle = .american, multiplier: Int = 100,
                specificationVersion: String = "assumed-us-equity-standard.v1", bid: Money, ask: Money,
                bidSize: Int, askSize: Int, tick: Money?, quoteTime: Date?, receivedAt: Date?,
                activity: OptionDailyActivity, source: OptionLabSource) {
        self.contractID = contractID; self.symbol = symbol; self.feedID = feedID; self.session = session
        self.underlyingQuoteID = underlyingQuoteID; self.right = right; self.strike = strike; self.expiry = expiry
        self.exerciseStyle = exerciseStyle; self.multiplier = multiplier; self.specificationVersion = specificationVersion
        self.bid = bid; self.ask = ask; self.bidSize = bidSize; self.askSize = askSize; self.tick = tick
        self.quoteTime = quoteTime; self.receivedAt = receivedAt; self.activity = activity; self.source = source
    }
}
public struct OptionDailyInput: Codable, Equatable, Sendable {
    public static let currentMethodVersion = "options.iv-daily.v1"
    public let id: UUID
    public let createdAt: Date
    public let asOf: Date
    /// Explicit offline close declaration, not an official exchange closing-time assertion.
    public let sessionCloseAt: Date?
    public let session: MarketDate
    public let sessionTimeZoneID: String
    public let symbol: String
    public let feedID: String
    public let coverage: OptionDailyCoverage
    /// Complete means only this declared set of expirations/strikes; never a provider-wide claim.
    public let declaredScope: String
    public let underlying: OptionDailyUnderlying
    public let contracts: [OptionDailyContractInput]
    public let rate: Money
    public let dividendYield: Money
    public let source: OptionLabSource
    public let calendar: OptionDailyCalendar?
    public let methodVersion: String
    public let chainEvidence: OptionChainCapture?
    public init(id: UUID = UUID(), createdAt: Date, asOf: Date, session: MarketDate,
                sessionTimeZoneID: String = "America/New_York", symbol: String, feedID: String,
                coverage: OptionDailyCoverage, declaredScope: String, underlying: OptionDailyUnderlying,
                contracts: [OptionDailyContractInput], rate: Money, dividendYield: Money, source: OptionLabSource,
                calendar: OptionDailyCalendar? = nil, sessionCloseAt: Date? = nil, methodVersion: String = currentMethodVersion,
                chainEvidence: OptionChainCapture? = nil) {
        self.id = id; self.createdAt = createdAt; self.asOf = asOf; self.sessionCloseAt = sessionCloseAt; self.session = session
        self.sessionTimeZoneID = sessionTimeZoneID; self.symbol = symbol; self.feedID = feedID; self.coverage = coverage
        self.declaredScope = declaredScope; self.underlying = underlying; self.contracts = contracts
        self.rate = rate; self.dividendYield = dividendYield; self.source = source; self.calendar = calendar; self.methodVersion = methodVersion; self.chainEvidence = chainEvidence
    }
}
public struct OptionDailyContractSummary: Codable, Equatable, Sendable {
    public let contractID: String
    public let closingBid: Money
    public let closingAsk: Money
    public let closingMid: Money?
    public let state: OptionDailyState
    public let localIV: OptionLabIVResult?
    public let canonicalIV: Double?
    public let canonicalDelta: Double?
    public let eligibleVolume: Int?
    public let eligibleOpenInterest: Int?
    public let pricingModelVersion: String
}
public struct OptionDailyChainSummary: Codable, Equatable, Sendable {
    public let symbol: String
    public let feedID: String
    public let session: MarketDate
    public let underlyingQuoteID: String
    public let underlyingMid: Money?
    public let coverage: OptionDailyCoverage
    public let observedContractCount: Int
    public let totalVolume: Int?
    public let totalOpenInterest: Int?
    public let maxSkewSeconds: Double?
    public let rate: Money
    public let dividendYield: Money
    public let iv30: Double?
    /// The expiry summaries retain same-strike ATM call/put IV. No unapproved
    /// delta selection/interpolation rule is invented for the 25-delta fields.
    public let put25DeltaIV: Double?
    public let call25DeltaIV: Double?
    public let delta25UnavailableReason: String
}
public struct OptionDailyExpirySummary: Codable, Equatable, Sendable {
    public let settlementAt: Date
    public let timeYears: Double
    public let strike: Money?
    public let callContractID: String?
    public let putContractID: String?
    public let callIV: Double?
    public let putIV: Double?
    public let atmIV: Double?
    public let state: OptionDailyState
}
public struct OptionDailyReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let input: OptionDailyInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let pricingModel: ModelDefinition
    public let pricingParameters: ParameterSet
    public let chainSummary: OptionDailyChainSummary
    public let contractSummaries: [OptionDailyContractSummary]
    public let expiries: [OptionDailyExpirySummary]
    public let iv30: Double?
    public let state: OptionDailyState
    public let iv30ExpiryInstants: [Date]
    public let containsSynthetic: Bool
    public let researchOnly: Bool
    public let limitations: [String]
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
}
