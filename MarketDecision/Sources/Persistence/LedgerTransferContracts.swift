import Foundation

public enum LedgerArchiveError: Error, Equatable, Sendable {
    case incompatiblePurpose, unsupportedFormat, corruptedArchive, corruptedStorage, budgetExceeded
    case invalidPlan, stalePlan, identityConflict, injectedFailure, notFound
}
public enum LedgerRestoreMode: String, Codable, Sendable { case merge, replace, retainConflict }
public enum LedgerTransferOperation: String, Codable, Sendable { case merge, replace, clear, retainConflict }
public struct LedgerArchiveCounts: Codable, Equatable, Sendable {
    public let accounts: Int
    public let events: Int
    public let batches: Int
    public let reports: Int
    public let conflicts: Int
    public init(accounts:Int,events:Int,batches:Int,reports:Int,conflicts:Int) {
        self.accounts = accounts; self.events = events; self.batches = batches; self.reports = reports; self.conflicts = conflicts
    }
}
public struct LedgerArchiveStatus: Equatable, Sendable {
    public let ledgerRevision: UUID
    public let performanceRevision: UUID
    public let counts: LedgerArchiveCounts
    public init(ledgerRevision:UUID,performanceRevision:UUID,counts:LedgerArchiveCounts) {
        self.ledgerRevision = ledgerRevision; self.performanceRevision = performanceRevision; self.counts = counts
    }
}
public struct LedgerTransferPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let digest: String
    public let baseLedgerRevision: UUID
    public let basePerformanceRevision: UUID
    public let operation: LedgerTransferOperation
    public let previous: LedgerArchiveCounts
    public let result: LedgerArchiveCounts
    public let details: [String]
    public let canCommit: Bool
    public init(id:UUID,digest:String,baseLedgerRevision:UUID,basePerformanceRevision:UUID,operation:LedgerTransferOperation,
                previous:LedgerArchiveCounts,result:LedgerArchiveCounts,details:[String],canCommit:Bool) {
        self.id = id; self.digest = digest; self.baseLedgerRevision = baseLedgerRevision; self.basePerformanceRevision = basePerformanceRevision
        self.operation = operation; self.previous = previous; self.result = result; self.details = details; self.canCommit = canCommit
    }
}
public struct LedgerTransferApproval: Equatable, Sendable {
    public let planID: UUID
    public let digest: String
    public let ledgerRevision: UUID
    public let performanceRevision: UUID
    public init(planID:UUID,digest:String,ledgerRevision:UUID,performanceRevision:UUID) {
        self.planID = planID; self.digest = digest; self.ledgerRevision = ledgerRevision; self.performanceRevision = performanceRevision
    }
    public init(plan:LedgerTransferPlan) {
        self.init(planID:plan.id,digest:plan.digest,ledgerRevision:plan.baseLedgerRevision,performanceRevision:plan.basePerformanceRevision)
    }
}
public struct LedgerTransferResult: Equatable, Sendable {
    public let ledgerRevision: UUID
    public let performanceRevision: UUID
    public let counts: LedgerArchiveCounts
    public init(ledgerRevision:UUID,performanceRevision:UUID,counts:LedgerArchiveCounts) {
        self.ledgerRevision = ledgerRevision; self.performanceRevision = performanceRevision; self.counts = counts
    }
}
public struct LedgerArchiveConflictSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sourceHash: String
    public let reason: String
    public let counts: LedgerArchiveCounts
    public init(id:UUID,createdAt:Date,sourceHash:String,reason:String,counts:LedgerArchiveCounts) {
        self.id = id; self.createdAt = createdAt; self.sourceHash = sourceHash; self.reason = reason; self.counts = counts
    }
}
public protocol LedgerArchiveStorage: Sendable {
    /// Metadata/counts only: corrupt replaceable bodies do not block repair.
    func status() async throws -> LedgerArchiveStatus
    func exportArchive() async throws -> Data
    func prepareRestore(_ data:Data,mode:LedgerRestoreMode,expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) async throws -> LedgerTransferPlan
    func prepareClear(expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) async throws -> LedgerTransferPlan
    func commit(_ approval:LedgerTransferApproval) async throws -> LedgerTransferResult
    func cancel(_ id:UUID) async
    func conflicts() async throws -> [LedgerArchiveConflictSummary]
    func exportConflict(id:UUID) async throws -> Data
}
