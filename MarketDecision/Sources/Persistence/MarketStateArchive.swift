import Foundation
import GRDB
import PortfolioEngine

public enum MarketStateRestoreMode: String, Codable, Equatable, Sendable { case merge, replace }
public enum MarketStateTransferOperation: String, Codable, Equatable, Sendable { case merge, replace, clear, delete }
public struct MarketStateArchiveCounts: Codable, Equatable, Sendable {
    public let marketReports: Int
    public let attributionReports: Int
    public let documentBodies: Int
    public let conflictCopies: Int
    public let cachedSources: Int
    public var totalReports: Int { marketReports + attributionReports }
    public init(marketReports: Int, attributionReports: Int, documentBodies: Int? = nil, conflictCopies: Int = 0, cachedSources: Int) {
        self.marketReports = marketReports; self.attributionReports = attributionReports
        self.documentBodies = documentBodies ?? marketReports + attributionReports; self.conflictCopies = conflictCopies; self.cachedSources = cachedSources
    }
}
public struct MarketStateArchiveStatus: Equatable, Sendable {
    public let revision: UUID
    public let counts: MarketStateArchiveCounts
    public init(revision: UUID, counts: MarketStateArchiveCounts) { self.revision = revision; self.counts = counts }
}
public struct MarketStateTransferPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let digest: String
    public let baseRevision: UUID
    public let operation: MarketStateTransferOperation
    public let previous: MarketStateArchiveCounts
    public let result: MarketStateArchiveCounts
    public let details: [String]
    public let canCommit: Bool
    public init(id: UUID, digest: String, baseRevision: UUID, operation: MarketStateTransferOperation,
                previous: MarketStateArchiveCounts, result: MarketStateArchiveCounts, details: [String], canCommit: Bool) {
        self.id = id; self.digest = digest; self.baseRevision = baseRevision; self.operation = operation
        self.previous = previous; self.result = result; self.details = details; self.canCommit = canCommit
    }
}
public struct MarketStateTransferApproval: Equatable, Sendable {
    public let planID: UUID
    public let digest: String
    public let revision: UUID
    public init(planID: UUID, digest: String, revision: UUID) { self.planID = planID; self.digest = digest; self.revision = revision }
    public init(plan: MarketStateTransferPlan) { self.init(planID: plan.id, digest: plan.digest, revision: plan.baseRevision) }
}
public struct MarketStateTransferResult: Equatable, Sendable {
    public let revision: UUID
    public let counts: MarketStateArchiveCounts
    public init(revision: UUID, counts: MarketStateArchiveCounts) { self.revision = revision; self.counts = counts }
}
public protocol MarketStateArchiveStorage: Sendable {
    func status() async throws -> MarketStateArchiveStatus
    func exportArchive() async throws -> Data
    func prepareRestore(_ data: Data, mode: MarketStateRestoreMode, expectedRevision: UUID) async throws -> MarketStateTransferPlan
    func prepareClear(expectedRevision: UUID) async throws -> MarketStateTransferPlan
    func prepareDelete(ids: Set<UUID>, expectedRevision: UUID) async throws -> MarketStateTransferPlan
    func commit(_ approval: MarketStateTransferApproval) async throws -> MarketStateTransferResult
    func cancel(_ id: UUID) async
}

/// A distinct MDM1 format. ZIP paths use the shared strict two-entry profile;
/// purpose/version and exact manifests make other product ZIPs non-interchangeable.
/// Cached sources and credentials are excluded. This is not a whole-product backup.
public enum MarketStateArchiveCodec {
    public static let maximumArchiveBytes = 128 * 1_024 * 1_024
    static let format = "market-state-archive.v1"
    static let scope = "Frozen market reports and embedded trade evidence only. Source caches, research, options, ledger databases and credentials are not restored."
    struct Manifest: Codable, Equatable {
        let format: String
        let purpose: String
        let encrypted: Bool
        let stateBytes: Int
        let stateHash: String
        let marketReports: Int
        let attributionReports: Int
        let scope: String
    }
    private struct FormatHeader: Decodable { let format: String; let purpose: String }
    static func encode(_ state: MarketArchiveState) throws -> Data {
        try state.validate()
        let bytes = try MarketStateStore.encode(state)
        guard bytes.count < maximumArchiveBytes - 4096 else { throw MarketStateStorageError.budgetExceeded }
        let counts = state.counts(cache: 0)
        let manifest = Manifest(format: format, purpose: "MDM1", encrypted: false, stateBytes: bytes.count,
            stateHash: LedgerCSV.hash(bytes), marketReports: counts.marketReports, attributionReports: counts.attributionReports, scope: scope)
        return try ResearchZIP.encode(["manifest.json": MarketStateStore.encode(manifest), "research-state.json": bytes])
    }
    static func decode(_ data: Data) throws -> MarketArchiveState {
        try Task.checkCancellation()
        guard data.count <= maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }
        do {
            let files = try ResearchZIP.decode(data)
            guard let manifestBytes = files["manifest.json"], let bytes = files["research-state.json"], manifestBytes.count <= 4096 else { throw MarketStateStorageError.corruptedArchive }
            // Reject a well-formed archive for another product before decoding
            // fields that only exist in the market manifest. Malformed manifests
            // still fail as corruption; this never accepts an incomplete state.
            let header = try JSONDecoder().decode(FormatHeader.self, from: manifestBytes)
            guard header.format == format, header.purpose == "MDM1" else { throw MarketStateStorageError.unsupportedFormat }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
            guard manifest.format == format, manifest.purpose == "MDM1", !manifest.encrypted, manifest.scope == scope else { throw MarketStateStorageError.unsupportedFormat }
            guard manifest.stateBytes == bytes.count, manifest.stateHash == LedgerCSV.hash(bytes),
                  try MarketStateStore.encode(manifest) == manifestBytes else { throw MarketStateStorageError.corruptedArchive }
            let state = try JSONDecoder().decode(MarketArchiveState.self, from: bytes)
            guard try MarketStateStore.encode(state) == bytes else { throw MarketStateStorageError.corruptedArchive }
            try state.validate()
            let counts = state.counts(cache: 0)
            guard counts.marketReports == manifest.marketReports, counts.attributionReports == manifest.attributionReports else { throw MarketStateStorageError.corruptedArchive }
            return state
        } catch is CancellationError { throw CancellationError() }
        catch let error as MarketStateStorageError { throw error }
        catch { throw MarketStateStorageError.corruptedArchive }
    }
}

struct MarketArchiveState: Codable, Equatable, Sendable {
    static let format = "market-state-frozen.v1"
    let format: String
    var entries: [MarketStoredEntry]
    static let empty = Self(format: format, entries: [])
    func counts(cache: Int) -> MarketStateArchiveCounts {
        .init(marketReports: entries.filter { $0.summary.kind == .marketState }.count,
            attributionReports: entries.filter { $0.summary.kind == .tradeAttribution }.count,
            conflictCopies: entries.filter { $0.summary.id != $0.summary.originalID }.count, cachedSources: cache)
    }
    func validate() throws {
        guard format == Self.format else { throw MarketStateStorageError.unsupportedFormat }
        guard entries.count <= MarketStateStore.maximumReports else { throw MarketStateStorageError.budgetExceeded }
        let ids = entries.map { $0.summary.id.uuidString }
        guard Set(ids).count == ids.count, ids == ids.sorted(), Set(entries.map(\.originKey)).count == entries.count else { throw MarketStateStorageError.corruptedArchive }
        var size = 0
        for entry in entries {
            try Task.checkCancellation()
            size += entry.input.count + entry.report.count + entry.summaryBytes.count
            guard size < MarketStateArchiveCodec.maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }
            _ = try entry.replay()
        }
    }
    static func capture(_ db: Database) throws -> Self {
        _ = try MarketStateStore.revision(db)
        guard try MarketStateStore.count("market_state_catalog", db) <= MarketStateStore.maximumReports else { throw MarketStateStorageError.budgetExceeded }
        let ids = try String.fetchAll(db, sql: "SELECT document_id FROM market_state_catalog ORDER BY document_id")
        var entries: [MarketStoredEntry] = [], size = 0
        for raw in ids {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: raw), raw == id.uuidString,
                  let entry = try MarketStateStore.load(id, db) else { throw MarketStateStorageError.corruptedStorage }
            size += entry.input.count + entry.report.count + entry.summaryBytes.count
            guard size < MarketStateArchiveCodec.maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }
            entries.append(entry)
        }
        guard try MarketStateStore.count("market_state_documents", db) == entries.count else { throw MarketStateStorageError.corruptedStorage }
        return .init(format: format, entries: entries)
    }
    static func merge(_ current: Self, _ incoming: Self) throws -> Self {
        var indexed = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.summary.id, $0) })
        var origins = Set(current.entries.map(\.originKey))
        for entry in incoming.entries {
            try Task.checkCancellation()
            // A prior merge may have retained this exact frozen body under a
            // different directory ID. Origin + hashes prevents duplicate copies.
            if origins.contains(entry.originKey) { continue }
            if indexed[entry.summary.id] != nil {
                let id = try entry.conflictStorageID()
                guard indexed[id] == nil else { throw MarketStateStorageError.identityConflict }
                indexed[id] = try entry.retainedCopy(id: id)
            } else { indexed[entry.summary.id] = entry }
            origins.insert(entry.originKey)
        }
        let result = Self(format: format, entries: indexed.values.sorted { $0.summary.id.uuidString < $1.summary.id.uuidString })
        try result.validate(); return result
    }
    static func clearFrozen(_ db: Database) throws {
        // Only this purpose's two owned tables; no namespace-wide shared deletion.
        try db.execute(sql: "DELETE FROM market_state_documents")
        try db.execute(sql: "DELETE FROM market_state_catalog")
    }
    func insert(_ db: Database) throws {
        for entry in entries { try Task.checkCancellation(); try entry.insert(db) }
    }
}
