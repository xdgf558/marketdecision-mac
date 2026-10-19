import Foundation
import CoreDomain
import MarketAnalytics

public enum MarketTradeAttributionMode: String, Codable, Sendable { case synthetic, ledger }
/// Declares the first scheduled close after the snapshot's closed session. The
/// calendar bytes are frozen, but manually supplied schedules are not exchange
/// calendar certification. Absence is a gap, never unlimited snapshot validity.
public struct MarketNextCloseEvidence: Codable, Equatable, Sendable {
    public let sessionDate: String
    public let closeAt: Date
    public let calendar: PerformanceEvidence
    public init(sessionDate: String, closeAt: Date, calendar: PerformanceEvidence) {
        self.sessionDate = sessionDate; self.closeAt = closeAt; self.calendar = calendar
    }
}
/// A declared, frozen opening-time snapshot. Neither a later reconstruction nor
/// a currently displayed market label can supply this evidence implicitly.
public struct MarketTradeObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let openingEventID: String
    public let lotID: String
    public let knownAt: Date
    public let source: PerformanceEvidence
    public let snapshot: MarketStateReport
    public let nextScheduledClose: MarketNextCloseEvidence?
    public init(id: String, accountID: String, openingEventID: String, lotID: String,
                knownAt: Date, source: PerformanceEvidence, snapshot: MarketStateReport,
                nextScheduledClose: MarketNextCloseEvidence? = nil) {
        self.id = id; self.accountID = accountID; self.openingEventID = openingEventID
        self.lotID = lotID; self.knownAt = knownAt; self.source = source; self.snapshot = snapshot
        self.nextScheduledClose = nextScheduledClose
    }
}
public struct MarketTradeAttributionInput: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let mode: MarketTradeAttributionMode
    public let performance: PerformanceInput
    public let observations: [MarketTradeObservation]
    public var containsSynthetic: Bool { mode == .synthetic }
    public init(id: UUID = UUID(), createdAt: Date, mode: MarketTradeAttributionMode,
                performance: PerformanceInput, observations: [MarketTradeObservation]) {
        self.id = id; self.createdAt = createdAt; self.mode = mode
        self.performance = performance; self.observations = observations
    }
}
public enum MarketTradeAttributionGap: String, Codable, Sendable {
    case missingSnapshot, missingSessionValidity, staleSnapshot, unavailableMarketState, transferredOpening
}
public struct MarketTradeAttributionRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String { round.roundLotID }
    public let round: PerformanceRound
    public let openingEventID: String
    public let snapshotID: UUID?
    public let snapshotModel: RegistryReference?
    public let snapshotSession: String?
    public let label: String?
    public let gap: MarketTradeAttributionGap?
}
public struct MarketTradeAttributionGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let snapshotModel: RegistryReference?
    public let roundIDs: [String]
    public let completedNetPnL: Money?
    public let statistics: PerformanceTradeStatistics
}
public struct MarketTradeAttributionReport: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { input.id }
    public var createdAt: Date { input.createdAt }
    public var containsSynthetic: Bool { input.containsSynthetic }
    public let schemaVersion: String
    public let input: MarketTradeAttributionInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let performanceEngineVersion: String
    public let performanceParametersVersion: String
    public let rows: [MarketTradeAttributionRow]
    public let groupedStatistics: [MarketTradeAttributionGroup]
    public let researchOnly: Bool
    public let limitations: [String]
}
public enum MarketTradeAttributionError: Error, Equatable, Sendable {
    case invalidInput, duplicateObservation, unknownOpening, invalidTiming, invalidEvidence
    case syntheticEvidence, incompatibleReport
}
