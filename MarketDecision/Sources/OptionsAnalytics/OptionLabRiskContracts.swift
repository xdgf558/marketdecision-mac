import Foundation
import CoreDomain
import DataContracts

public enum OptionLabLiquidityGrade: String, Sendable, Codable, CaseIterable {
    case excellent, acceptable, weak, avoid, dataInsufficient
}
public enum OptionLabLiquidityFactor: String, Sendable, Codable, CaseIterable {
    case relativeSpread, openInterest, volume, quoteAge, size, neighborContinuity
}
public enum OptionLabVolumeBasis: String, Sendable, Codable, CaseIterable {
    case fullSession, sameElapsedTime, unverified
}

/// Offline declarations, never provider admission. OI age counts published trading
/// sessions, not calendar days; unverified volume cannot be compared with full-day thresholds.
public struct OptionLabLiquidityInput: Sendable, Codable, Equatable {
    public let contractID: String
    public let openInterest: Int?
    public let oiSessionsAgo: Int?
    public let oiIsLatestPublished: Bool
    public let volume: Int?
    public let volumeBasis: OptionLabVolumeBasis
    public let neighbors: [OptionLabLeg]
    public let neighborsComplete: Bool
    public init(contractID: String, openInterest: Int? = nil, oiSessionsAgo: Int? = nil,
                oiIsLatestPublished: Bool = false, volume: Int? = nil,
                volumeBasis: OptionLabVolumeBasis = .unverified, neighbors: [OptionLabLeg] = [],
                neighborsComplete: Bool = false) {
        self.contractID = contractID; self.openInterest = openInterest; self.oiSessionsAgo = oiSessionsAgo
        self.oiIsLatestPublished = oiIsLatestPublished; self.volume = volume; self.volumeBasis = volumeBasis
        self.neighbors = neighbors; self.neighborsComplete = neighborsComplete
    }
}

/// One explicitly declared calendar date. Closed dates must be included so a missing
/// holiday cannot silently become a trading day. Times are never inferred from weekdays.
public struct OptionLabRiskSession: Sendable, Codable, Equatable {
    public let date: MarketDate
    public let state: MarketSessionState
    public let opensAt: Date?
    public let closesAt: Date?
    public init(date: MarketDate, state: MarketSessionState, opensAt: Date? = nil, closesAt: Date? = nil) {
        self.date = date; self.state = state; self.opensAt = opensAt; self.closesAt = closesAt
    }
}
public struct OptionLabRiskCalendar: Sendable, Codable, Equatable {
    public let version: String
    public let source: OptionLabSource
    public let from: MarketDate
    public let through: MarketDate
    public let sessions: [OptionLabRiskSession]
    public init(version: String, source: OptionLabSource, from: MarketDate, through: MarketDate,
                sessions: [OptionLabRiskSession]) {
        self.version = version; self.source = source; self.from = from; self.through = through; self.sessions = sessions
    }
}
public struct OptionLabStraddleQuote: Sendable, Codable, Equatable {
    public let strike: Money
    public let settlementAt: Date
    public let callBid: Money
    public let callAsk: Money
    public let putBid: Money
    public let putAsk: Money
    public let quotedAt: Date
    public let source: OptionLabSource
    public init(strike: Money, settlementAt: Date, callBid: Money, callAsk: Money,
                putBid: Money, putAsk: Money, quotedAt: Date, source: OptionLabSource) {
        self.strike = strike; self.settlementAt = settlementAt; self.callBid = callBid; self.callAsk = callAsk
        self.putBid = putBid; self.putAsk = putAsk; self.quotedAt = quotedAt; self.source = source
    }
}
public struct OptionLabEarningsInput: Sendable, Codable, Equatable {
    public let eventVersion: String
    public let source: OptionLabSource
    public let announcedAt: Date
    public let eventDate: MarketDate
    public let timing: CorporateEventTiming
    public let certainty: CorporateEventCertainty
    public let calendar: OptionLabRiskCalendar?
    public let allowsHoldingAcrossEvent: Bool?
    /// Declared complete expiry/strike candidate universe. Without this declaration
    /// a straddle cannot be called the nearest post-event ATM selection.
    public let straddles: [OptionLabStraddleQuote]
    public let straddleCoverageComplete: Bool
    public init(eventVersion: String, source: OptionLabSource, announcedAt: Date, eventDate: MarketDate,
                timing: CorporateEventTiming, certainty: CorporateEventCertainty,
                calendar: OptionLabRiskCalendar? = nil, allowsHoldingAcrossEvent: Bool? = nil,
                straddles: [OptionLabStraddleQuote] = [], straddleCoverageComplete: Bool = false) {
        self.eventVersion = eventVersion; self.source = source; self.announcedAt = announcedAt
        self.eventDate = eventDate; self.timing = timing; self.certainty = certainty; self.calendar = calendar
        self.allowsHoldingAcrossEvent = allowsHoldingAcrossEvent; self.straddles = straddles
        self.straddleCoverageComplete = straddleCoverageComplete
    }
}
public struct OptionLabDividendInput: Sendable, Codable, Equatable {
    public let eventVersion: String
    public let source: OptionLabSource
    public let announcedAt: Date
    public let exDate: MarketDate
    public let paymentAt: Date?
    public let amountPerShare: Money?
    public let currency: String
    public let certainty: CorporateEventCertainty
    public let calendar: OptionLabRiskCalendar?
    public init(eventVersion: String, source: OptionLabSource, announcedAt: Date, exDate: MarketDate,
                paymentAt: Date? = nil, amountPerShare: Money? = nil, currency: String = "USD",
                certainty: CorporateEventCertainty, calendar: OptionLabRiskCalendar? = nil) {
        self.eventVersion = eventVersion; self.source = source; self.announcedAt = announcedAt
        self.exDate = exDate; self.paymentAt = paymentAt; self.amountPerShare = amountPerShare
        self.currency = currency; self.certainty = certainty; self.calendar = calendar
    }
}
public struct OptionLabRiskInput: Sendable, Codable, Equatable {
    public static let currentMethodVersion = "options.offline-risk.v1"
    public let source: OptionLabSource
    public let liquidity: [OptionLabLiquidityInput]
    public let earnings: OptionLabEarningsInput?
    public let dividend: OptionLabDividendInput?
    public let methodVersion: String
    public init(source: OptionLabSource, liquidity: [OptionLabLiquidityInput] = [],
                earnings: OptionLabEarningsInput? = nil, dividend: OptionLabDividendInput? = nil,
                methodVersion: String = currentMethodVersion) {
        self.source = source; self.liquidity = liquidity; self.earnings = earnings; self.dividend = dividend
        self.methodVersion = methodVersion
    }
}
public struct OptionLabLiquidityComponent: Sendable, Codable, Equatable {
    public let factor: OptionLabLiquidityFactor
    public let weightBasisPoints: Int
    public let value: Money?
    public let grade: OptionLabLiquidityGrade
    public let score: Int?
    public let reason: String?
}
public struct OptionLabLegLiquidity: Sendable, Codable, Equatable {
    public let contractID: String
    public let components: [OptionLabLiquidityComponent]
    public let coverageBasisPoints: Int
    /// Nil unless all six inputs are qualified; missing is never zero or normalized away.
    public let score: Money?
    public let grade: OptionLabLiquidityGrade
    public let hardDowngrades: [String]
}
public struct OptionLabLiquidityReport: Sendable, Codable, Equatable {
    public let legs: [OptionLabLegLiquidity]
    public let grade: OptionLabLiquidityGrade
    public let score: Money?
    public let researchOnly: Bool
    public let mayRankLive: Bool
}
public enum OptionLabRiskEvidenceState: String, Sendable, Codable {
    case available, dataInsufficient, outsideHoldingWindow, notApplicable
}
public struct OptionLabEarningsReport: Sendable, Codable, Equatable {
    public let state: OptionLabRiskEvidenceState
    public let eventVersion: String?
    public let calendarVersion: String?
    public let windowStart: Date?
    public let windowEnd: Date?
    public let holdingOverlaps: Bool?
    public let allowsHoldingAcrossEvent: Bool?
    public let expectedMove: Money?
    public let expectedMoveFraction: Money?
    public let selectedStraddle: OptionLabStraddleQuote?
    /// No historical sample is accepted in this model; do not manufacture frequencies.
    public let historicalEventCount: Int
    public let historicalFrequency: Double?
    public let warnings: [String]
}
public enum OptionLabAssignmentLevel: String, Sendable, Codable {
    case high, elevated, noTrigger, dataInsufficient, notApplicable
}
public struct OptionLabAssignmentReport: Sendable, Codable, Equatable {
    public let contractID: String
    public let level: OptionLabAssignmentLevel
    public let intrinsicValue: Money
    /// Signed quote Mid minus intrinsic value. Negative extrinsic is not silently clamped.
    public let extrinsicValue: Money
    public let threshold: Double?
    public let dividendPresentValue: Double?
    public let nearExpiry: Bool
    public let deepInTheMoney: Bool
    public let priorExDividendSession: MarketDate?
    public let europeanApproximationLimited: Bool
    public let reasons: [String]
}
public struct OptionLabRiskReport: Sendable, Codable, Equatable {
    public let input: OptionLabRiskInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
    public let liquidity: OptionLabLiquidityReport
    public let earnings: OptionLabEarningsReport
    public let assignment: OptionLabAssignmentReport
    public let warnings: [String]
}
public enum OptionLabRiskError: Error, Equatable {
    case invalidInput, invalidCalendar, invalidEvent, invalidNeighbor, invalidStraddle
}

extension OptionLabRiskInput {
    public var containsSyntheticInput: Bool {
        source.origin == .synthetic || liquidity.contains { $0.neighbors.contains { $0.source.origin == .synthetic } }
        || earnings.map { event in
            event.source.origin == .synthetic || event.calendar?.source.origin == .synthetic
            || event.straddles.contains { $0.source.origin == .synthetic }
        } == true || dividend.map { $0.source.origin == .synthetic || $0.calendar?.source.origin == .synthetic } == true
    }
}
