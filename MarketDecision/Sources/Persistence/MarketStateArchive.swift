import Foundation
import GRDB
import PortfolioEngine

public enum MarketStateRestoreMode: String, Codable, Equatable, Sendable { case merge, replace }
public enum MarketStateTransferOperation: String, Codable, Equatable, Sendable { case merge, replace, clear, delete }
public struct MarketStateArchiveCounts: Codable, Equatable, Sendable {
    public let marketReports: Int
    public let attributionReports: Int
    public let macroReports: Int
    public let bridgeReports: Int
    public let frozenSources: Int
    public let sourceObservations: Int
    public let documentBodies: Int
    public let conflictCopies: Int
    public let cachedSources: Int
    public var totalReports: Int { marketReports + attributionReports + macroReports + bridgeReports }
    public init(marketReports: Int, attributionReports: Int, macroReports: Int = 0, bridgeReports: Int = 0, frozenSources: Int = 0, sourceObservations: Int = 0, documentBodies: Int? = nil, conflictCopies: Int = 0, cachedSources: Int) {
        self.marketReports = marketReports; self.attributionReports = attributionReports
        self.macroReports = macroReports; self.bridgeReports = bridgeReports; self.frozenSources = frozenSources; self.sourceObservations = sourceObservations
        self.documentBodies = documentBodies ?? marketReports + attributionReports + macroReports + bridgeReports; self.conflictCopies = conflictCopies; self.cachedSources = cachedSources
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
    static let format = "market-state-archive.v2"
    static let legacyFormat = "market-state-archive.v1"
    static let legacyScope = "Frozen market reports and embedded trade evidence only. Source caches, research, options, ledger databases and credentials are not restored."
    static let scope = "Frozen market reports, embedded trade evidence, local macro source bytes, typed vintages and replayable source bridges only. Source caches, research, options, ledger databases and credentials are not restored."
    struct Manifest: Codable, Equatable {
        let format: String
        let purpose: String
        let encrypted: Bool
        let stateBytes: Int
        let stateHash: String
        let marketReports: Int
        let attributionReports: Int
        let macroReports: Int?
        let bridgeReports: Int?
        let frozenSources: Int?
        let sourceObservations: Int?
        let scope: String
    }
    private struct FormatHeader: Decodable { let format: String; let purpose: String }
    static func encode(_ state: MarketArchiveState) throws -> Data {
        guard state.format == MarketArchiveState.format else { throw MarketStateStorageError.unsupportedFormat }
        try state.validate()
        let bytes = try MarketStateStore.encode(state)
        guard bytes.count < maximumArchiveBytes - 4096 else { throw MarketStateStorageError.budgetExceeded }
        let counts = state.counts(cache: 0)
        let manifest = Manifest(format: format, purpose: "MDM1", encrypted: false, stateBytes: bytes.count,
            stateHash: LedgerCSV.hash(bytes), marketReports: counts.marketReports, attributionReports: counts.attributionReports, macroReports: counts.macroReports, bridgeReports: counts.bridgeReports, frozenSources: counts.frozenSources, sourceObservations: counts.sourceObservations, scope: scope)
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
            guard [format, legacyFormat].contains(header.format), header.purpose == "MDM1" else { throw MarketStateStorageError.unsupportedFormat }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
            guard manifest.purpose == "MDM1", !manifest.encrypted, manifest.scope == (manifest.format == legacyFormat ? legacyScope : scope) else { throw MarketStateStorageError.unsupportedFormat }
            guard manifest.stateBytes == bytes.count, manifest.stateHash == LedgerCSV.hash(bytes),
                  try MarketStateStore.encode(manifest) == manifestBytes else { throw MarketStateStorageError.corruptedArchive }
            let state = try JSONDecoder().decode(MarketArchiveState.self, from: bytes)
            guard try MarketStateStore.encode(state) == bytes else { throw MarketStateStorageError.corruptedArchive }
            guard (manifest.format == legacyFormat && state.format == MarketArchiveState.legacyFormat && manifest.macroReports == nil && manifest.bridgeReports == nil && manifest.frozenSources == nil && manifest.sourceObservations == nil)
                || (manifest.format == format && state.format == MarketArchiveState.format) else { throw MarketStateStorageError.unsupportedFormat }
            try state.validate()
            let counts = state.counts(cache: 0)
            guard counts.marketReports == manifest.marketReports, counts.attributionReports == manifest.attributionReports else { throw MarketStateStorageError.corruptedArchive }
            if manifest.format == format {
                guard manifest.macroReports == counts.macroReports, manifest.bridgeReports == counts.bridgeReports, manifest.frozenSources == counts.frozenSources, manifest.sourceObservations == counts.sourceObservations else { throw MarketStateStorageError.corruptedArchive }
            }
            return state.upgraded()
        } catch is CancellationError { throw CancellationError() }
        catch let error as MarketStateStorageError { throw error }
        catch { throw MarketStateStorageError.corruptedArchive }
    }
}

struct MarketArchiveState: Codable, Equatable, Sendable {
    static let format = "market-state-frozen.v2"
    static let legacyFormat = "market-state-frozen.v1"
    let format: String
    var entries: [MarketStoredEntry]
    var macroEntries: [MacroStoredEntry]
    init(format: String, entries: [MarketStoredEntry], macroEntries: [MacroStoredEntry] = []) {
        self.format = format; self.entries = entries; self.macroEntries = macroEntries
    }
    private enum CodingKeys: String, CodingKey { case format, entries, macroEntries }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        entries = try values.decode([MarketStoredEntry].self, forKey: .entries)
        macroEntries = format == Self.legacyFormat ? [] : try values.decode([MacroStoredEntry].self, forKey: .macroEntries)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format); try values.encode(entries, forKey: .entries)
        if format != Self.legacyFormat { try values.encode(macroEntries, forKey: .macroEntries) }
    }
    static let empty = Self(format: format, entries: [])
    func upgraded() -> Self { .init(format: Self.format, entries: entries, macroEntries: macroEntries) }
    func counts(cache: Int) -> MarketStateArchiveCounts {
        .init(marketReports: entries.filter { $0.summary.kind == .marketState }.count,
            attributionReports: entries.filter { $0.summary.kind == .tradeAttribution }.count,
            macroReports: macroEntries.filter { $0.summary.kind == .source }.count,
            bridgeReports: macroEntries.filter { $0.summary.kind == .marketBridge }.count,
            frozenSources: macroEntries.reduce(0) { $0 + $1.summary.sourceCount },
            sourceObservations: macroEntries.reduce(0) { $0 + $1.summary.observationCount },
            conflictCopies: entries.filter { $0.summary.id != $0.summary.originalID }.count + macroEntries.filter { $0.summary.id != $0.summary.originalID }.count,
            cachedSources: cache)
    }
    func validate() throws {
        guard [Self.format, Self.legacyFormat].contains(format), format != Self.legacyFormat || macroEntries.isEmpty else { throw MarketStateStorageError.unsupportedFormat }
        guard entries.count + macroEntries.count <= MarketStateStore.maximumReports else { throw MarketStateStorageError.budgetExceeded }
        let ids = entries.map { $0.summary.id.uuidString }, macroIDs = macroEntries.map { $0.summary.id.uuidString }
        guard Set(ids + macroIDs).count == ids.count + macroIDs.count, ids == ids.sorted(), macroIDs == macroIDs.sorted(),
              Set(entries.map(\.originKey)).count == entries.count, Set(macroEntries.map(\.contentKey)).count == macroEntries.count else { throw MarketStateStorageError.corruptedArchive }
        var size = 0
        for entry in entries {
            try Task.checkCancellation()
            size += entry.input.count + entry.report.count + entry.summaryBytes.count
            guard size < MarketStateArchiveCodec.maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }
            _ = try entry.replay()
        }
        for entry in macroEntries {
            try Task.checkCancellation()
            size += entry.input.count + entry.report.count + entry.summaryBytes.count
            guard size < MarketStateArchiveCodec.maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }
            _ = try entry.replay()
        }
        try MacroStoredEntry.validateVersions(macroEntries)
    }
    static func capture(_ db: Database) throws -> Self {
        _ = try MarketStateStore.revision(db)
        let count = try MarketStateStore.count("market_state_catalog", db) + MarketStateStore.count("market_macro_catalog", db)
        guard count <= MarketStateStore.maximumReports else { throw MarketStateStorageError.budgetExceeded }
        var entries: [MarketStoredEntry] = [], macroEntries: [MacroStoredEntry] = [], size = 0
        for raw in try String.fetchAll(db, sql: "SELECT document_id FROM market_state_catalog ORDER BY document_id") {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: raw), raw == id.uuidString, let entry = try MarketStateStore.load(id, db) else { throw MarketStateStorageError.corruptedStorage }
            size += entry.input.count + entry.report.count + entry.summaryBytes.count
            guard size < MarketStateArchiveCodec.maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }; entries.append(entry)
        }
        for raw in try String.fetchAll(db, sql: "SELECT document_id FROM market_macro_catalog ORDER BY document_id") {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: raw), raw == id.uuidString, let entry = try MacroSourceStore.load(id, db) else { throw MarketStateStorageError.corruptedStorage }
            size += entry.input.count + entry.report.count + entry.summaryBytes.count
            guard size < MarketStateArchiveCodec.maximumArchiveBytes else { throw MarketStateStorageError.budgetExceeded }; macroEntries.append(entry)
        }
        guard try MarketStateStore.count("market_state_documents", db) == entries.count,
              try MarketStateStore.count("market_macro_documents", db) == macroEntries.count,
              try MarketStateStore.count("market_macro_sources", db) == macroEntries.reduce(0, { $0 + $1.summary.sourceCount }),
              try MarketStateStore.count("market_macro_observations", db) == macroEntries.reduce(0, { $0 + $1.summary.observationCount }) else { throw MarketStateStorageError.corruptedStorage }
        return .init(format: format, entries: entries, macroEntries: macroEntries)
    }
    static func merge(_ current: Self, _ incoming: Self) throws -> Self {
        var indexed = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.summary.id, $0) })
        var macro = Dictionary(uniqueKeysWithValues: current.macroEntries.map { ($0.summary.id, $0) })
        var origins = Set(current.entries.map(\.originKey)), contentKeys = Set(current.macroEntries.map(\.contentKey))
        for entry in incoming.entries {
            try Task.checkCancellation()
            if origins.contains(entry.originKey) { continue }
            if indexed[entry.summary.id] != nil || macro[entry.summary.id] != nil {
                let id = try entry.conflictStorageID()
                guard indexed[id] == nil, macro[id] == nil else { throw MarketStateStorageError.identityConflict }
                indexed[id] = try entry.retainedCopy(id: id)
            } else { indexed[entry.summary.id] = entry }
            origins.insert(entry.originKey)
        }
        for entry in incoming.macroEntries {
            try Task.checkCancellation()
            if contentKeys.contains(entry.contentKey) { continue }
            if indexed[entry.summary.id] != nil || macro[entry.summary.id] != nil {
                let id = try entry.conflictStorageID()
                guard indexed[id] == nil, macro[id] == nil else { throw MarketStateStorageError.identityConflict }
                macro[id] = try entry.retainedCopy(id: id)
            } else { macro[entry.summary.id] = entry }
            contentKeys.insert(entry.contentKey)
        }
        let result = Self(format: format, entries: indexed.values.sorted { $0.summary.id.uuidString < $1.summary.id.uuidString },
            macroEntries: macro.values.sorted { $0.summary.id.uuidString < $1.summary.id.uuidString })
        try result.validate(); return result
    }
    static func clearFrozen(_ db: Database) throws {
        // Only tables owned by this purpose. Cache and every other database stay separate.
        try db.execute(sql: "DELETE FROM market_macro_observations")
        try db.execute(sql: "DELETE FROM market_macro_sources")
        try db.execute(sql: "DELETE FROM market_macro_documents")
        try db.execute(sql: "DELETE FROM market_macro_catalog")
        try db.execute(sql: "DELETE FROM market_state_documents")
        try db.execute(sql: "DELETE FROM market_state_catalog")
    }
    func insert(_ db: Database) throws {
        for entry in entries { try Task.checkCancellation(); try entry.insert(db) }
        for entry in macroEntries { try Task.checkCancellation(); try entry.insert(db) }
    }
}
