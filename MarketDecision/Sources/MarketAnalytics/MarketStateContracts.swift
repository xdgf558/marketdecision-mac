import Foundation
import CoreDomain

public enum MarketStateError: Error, Equatable { case invalidInput, incompatibleReport, unsupportedVersion }
public enum MarketInputOrigin: String, Codable, Sendable { case synthetic, manual }
/// releaseCycle is reserved and rejected by the current closed 29-series catalog.
public enum MarketFrequency: String, Codable, Sendable { case daily, weekly, releaseCycle }
public enum MarketUnit: String, Codable, Sendable { case price, totalReturnIndex, volume, ratio, volatilityPercent, basisPoints, exposurePercent }
public enum MarketSeriesKey: String, Codable, CaseIterable, Sendable {
    case spyPrice, qqqPrice, iwmPrice, rspPrice, spyTotalReturn, rspTotalReturn, iwmTotalReturn, hygTotalReturn, iefTotalReturn, lqdTotalReturn
    case spyVolume, spyRelativeSpread, hygRelativeSpread, advancingFraction, aboveMA50Fraction, aboveMA200Fraction, newHighMinusLowFraction, advancingVolumeFraction
    case vix, vix3m, highYieldOAS, totalPutCall, indexPutCall, etfPutCall, equityPutCall, put25MinusATM30, naaim, assetManagerNetOverOI, leveragedFundsNetOverOI
    public var unit: MarketUnit {
        switch self {
        case .spyPrice, .qqqPrice, .iwmPrice, .rspPrice: .price
        case .spyTotalReturn, .rspTotalReturn, .iwmTotalReturn, .hygTotalReturn, .iefTotalReturn, .lqdTotalReturn: .totalReturnIndex
        case .spyVolume: .volume
        case .vix, .vix3m: .volatilityPercent
        case .highYieldOAS: .basisPoints
        case .naaim: .exposurePercent
        default: .ratio
        }
    }
    public var requiresPopulation: Bool {
        switch self {
        case .advancingFraction, .aboveMA50Fraction, .aboveMA200Fraction, .newHighMinusLowFraction, .advancingVolumeFraction,
             .totalPutCall, .indexPutCall, .etfPutCall, .equityPutCall, .assetManagerNetOverOI, .leveragedFundsNetOverOI: true
        default: false
        }
    }
}

/// Offline evidence only. sourceID identifies a declared source, not a supplier authorization.
public struct MarketSeries: Codable, Equatable, Sendable {
    public let key: MarketSeriesKey
    public let unit: MarketUnit
    public let frequency: MarketFrequency
    public let origin: MarketInputOrigin
    public let sourceID: String
    public let feedID: String
    public let methodology: String
    public let population: String?
    /// All price series use one split-adjusted basis. TR inputs remain separate series.
    public let basisVersion: String
    public let observations: [MarketObservation]
    public init(key: MarketSeriesKey, unit: MarketUnit, frequency: MarketFrequency = .daily,
                origin: MarketInputOrigin, sourceID: String, feedID: String, methodology: String,
                population: String? = nil, basisVersion: String, observations: [MarketObservation]) {
        self.key = key; self.unit = unit; self.frequency = frequency; self.origin = origin
        self.sourceID = sourceID; self.feedID = feedID; self.methodology = methodology
        self.population = population; self.basisVersion = basisVersion; self.observations = observations
    }
}

public struct MarketObservation: Codable, Equatable, Sendable {
    /// Stable across revisions. Repeated vintages never increase the independent sample count.
    public let observationID: String
    public let vintageID: String
    public let observationDate: String
    public let releasedAt: Date
    public let availableAt: Date
    public let validUntil: Date?
    public let value: Money
    public let rawValue: String
    public init(observationID: String, vintageID: String, observationDate: String, releasedAt: Date,
                availableAt: Date, validUntil: Date? = nil, value: Money, rawValue: String) {
        self.observationID = observationID; self.vintageID = vintageID; self.observationDate = observationDate
        self.releasedAt = releasedAt; self.availableAt = availableAt; self.validUntil = validUntil
        self.value = value; self.rawValue = rawValue
    }
}

public struct MarketTradingSession: Codable, Equatable, Sendable {
    public let date: String
    public let closeAt: Date
    public init(date: String, closeAt: Date) { self.date = date; self.closeAt = closeAt }
}

public struct MarketStateInput: Codable, Equatable, Sendable {
    public static let currentMethodVersion = "market-state.v1"
    public let id: UUID
    public let createdAt: Date
    /// Precise cutoff on sessionDate in America/New_York; createdAt may be a later reconstruction time.
    public let asOf: Date
    public let sessionDate: String
    /// Explicit ordered exchange sessions. Missing input on a session breaks label confirmation.
    public let sessions: [MarketTradingSession]
    public let calendarEvidence: String
    public let series: [MarketSeries]
    public let methodVersion: String
    public init(id: UUID = UUID(), createdAt: Date, asOf: Date, sessionDate: String,
                sessions: [MarketTradingSession], calendarEvidence: String, series: [MarketSeries],
                methodVersion: String = currentMethodVersion) {
        self.id = id; self.createdAt = createdAt; self.asOf = asOf; self.sessionDate = sessionDate
        self.sessions = sessions; self.calendarEvidence = calendarEvidence; self.series = series; self.methodVersion = methodVersion
    }
}

public enum MarketScoreKind: String, Codable, CaseIterable, Sendable { case heat, stress, sentiment }
public enum MarketRegimeLabel: String, Codable, CaseIterable, Sendable {
    case unreliable, transition, expansion, volatileRally, contraction, quietConsolidation
    public var title: String {
        switch self {
        case .unreliable: "暂无可靠判断"
        case .transition: "过渡环境"
        case .expansion: "强势扩张"
        case .volatileRally: "高波动追涨环境"
        case .contraction: "风险收缩"
        case .quietConsolidation: "低波动整理"
        }
    }
}
public enum MarketMissingReason: String, Codable, Sendable {
    case missingSeries, unavailableVintage, stale, insufficientWindow, insufficientHistory, invalidDenominator, incompatibleBasis, insufficientCoverage, nonFinite
}
/// Explicit raw window consumed by a formula. Every calendar session in the range
/// must be present; versions are selected from the frozen input using the enclosing
/// day's exact asOf. This is not a claim that the last observation is the whole input.
public struct MarketObservationWindow: Codable, Equatable, Sendable {
    public let series: MarketSeriesKey
    public let firstDate: String
    public let lastDate: String
    public let sessionCount: Int
    public let memberIdentitySHA256: String
}
public struct MarketAtomResult: Codable, Equatable, Sendable {
    public let id: String
    public let rawValue: Double?
    public let score: Double?
    public let independentHistoryCount: Int
    public let observationReferences: [String]
    public let consumedWindows: [MarketObservationWindow]
    public let missingReason: MarketMissingReason?
}
public struct MarketComponentResult: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let originalWeightBps: Int
    public let atoms: [MarketAtomResult]
    public let value: Double?
    /// Effective contribution after top-level missing-weight normalization.
    public let contribution: Double?
    public let validAtomCount: Int
    public let missingReason: MarketMissingReason?
}
public struct MarketScoreResult: Codable, Equatable, Sendable {
    public let kind: MarketScoreKind
    public let value: Double?
    public let effectiveWeightBps: Int
    public let components: [MarketComponentResult]
    public var droppedComponents: [MarketComponentResult] { components.filter { $0.value == nil } }
}
public struct MarketStateDay: Codable, Equatable, Sendable {
    public let sessionDate: String
    public let asOf: Date
    public let heat: MarketScoreResult
    public let stress: MarketScoreResult
    public let sentiment: MarketScoreResult
    public let rawLabel: MarketRegimeLabel
    public let confirmedLabel: MarketRegimeLabel
    public let confirmationStreak: Int
    /// Only an explicit closed session can contribute to daily confirmation and statistics.
    public let isClosedSession: Bool
}
public struct MarketCorrelation: Codable, Equatable, Sendable {
    public let first: MarketScoreKind
    public let second: MarketScoreKind
    public let commonCount: Int
    public let coefficient: Double?
    public let overlapWarning: Bool
}
public struct MarketLabelFrequency: Codable, Equatable, Sendable {
    public let label: MarketRegimeLabel
    public let count: Int
    public let fraction: Double?
}
public struct MarketHistoryDiagnostics: Codable, Equatable, Sendable {
    public let eligibleSessionCount: Int
    public let commonValidDayCount: Int
    public let coverage: Double?
    public let correlations: [MarketCorrelation]
    public let frequencies: [MarketLabelFrequency]
}
public struct MarketStateReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let input: MarketStateInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let history: [MarketStateDay]
    public let current: MarketStateDay
    public let diagnostics: MarketHistoryDiagnostics
    public let containsSynthetic: Bool
    public let researchOnly: Bool
    public let limitations: [String]
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
}
