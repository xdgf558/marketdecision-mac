import Foundation

public enum OptionLabArchiveError: Error, Equatable, Sendable {
    case incompatiblePurpose, unsupportedFormat, corruptedArchive, corruptedStorage, budgetExceeded
    case invalidPlan, stalePlan, identityConflict, injectedFailure, notFound
}
public enum OptionLabRestoreMode: String, Codable, Sendable { case merge, replace }
public enum OptionLabTransferOperation: String, Codable, Sendable { case merge, replace, clear }
public struct OptionLabArchiveCounts: Codable, Equatable, Sendable {
    public let experiments: Int
    public let dailySummaries: Int
    public let historyReports: Int
    public let contractSummaries: Int
    /// Embedded read-only account/event evidence, not a backup of the ledger DB.
    public let embeddedLedgerBases: Int
    public let chainCaptures: Int
    public let portfolioReports: Int
    public let evidenceReports: Int
    public init(experiments: Int, dailySummaries: Int, historyReports: Int, contractSummaries: Int = 0, embeddedLedgerBases: Int = 0, chainCaptures: Int = 0, portfolioReports: Int = 0, evidenceReports: Int = 0) {
        self.experiments = experiments; self.dailySummaries = dailySummaries; self.historyReports = historyReports
        self.contractSummaries = contractSummaries; self.embeddedLedgerBases = embeddedLedgerBases
        self.chainCaptures = chainCaptures; self.portfolioReports = portfolioReports
        self.evidenceReports = evidenceReports
    }
}
public struct OptionLabArchiveStatus: Equatable, Sendable {
    public let revision: UUID
    public let counts: OptionLabArchiveCounts
    public init(revision: UUID, counts: OptionLabArchiveCounts) { self.revision = revision; self.counts = counts }
}
public struct OptionLabTransferPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let digest: String
    public let baseRevision: UUID
    public let operation: OptionLabTransferOperation
    public let previous: OptionLabArchiveCounts
    public let result: OptionLabArchiveCounts
    public let details: [String]
    public let canCommit: Bool
    public init(id: UUID, digest: String, baseRevision: UUID, operation: OptionLabTransferOperation, previous: OptionLabArchiveCounts,
                result: OptionLabArchiveCounts, details: [String], canCommit: Bool) {
        self.id = id; self.digest = digest; self.baseRevision = baseRevision; self.operation = operation
        self.previous = previous; self.result = result; self.details = details; self.canCommit = canCommit
    }
}
public struct OptionLabTransferApproval: Equatable, Sendable {
    public let planID: UUID
    public let digest: String
    public let revision: UUID
    public init(planID: UUID, digest: String, revision: UUID) { self.planID = planID; self.digest = digest; self.revision = revision }
    public init(plan: OptionLabTransferPlan) { self.init(planID: plan.id, digest: plan.digest, revision: plan.baseRevision) }
}
public struct OptionLabTransferResult: Equatable, Sendable {
    public let revision: UUID
    public let counts: OptionLabArchiveCounts
    public init(revision: UUID, counts: OptionLabArchiveCounts) { self.revision = revision; self.counts = counts }
}
public protocol OptionLabArchiveStorage: Sendable {
    /// Metadata/counts only. Replace may repair damaged bodies; merge may not.
    func status() async throws -> OptionLabArchiveStatus
    func exportArchive() async throws -> Data
    func prepareRestore(_ data: Data, mode: OptionLabRestoreMode, expectedRevision: UUID) async throws -> OptionLabTransferPlan
    func prepareClear(expectedRevision: UUID) async throws -> OptionLabTransferPlan
    func commit(_ approval: OptionLabTransferApproval) async throws -> OptionLabTransferResult
    func cancel(_ id: UUID) async
}
