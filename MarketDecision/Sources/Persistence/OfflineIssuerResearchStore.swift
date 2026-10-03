import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

public struct SavedOfflineIssuerResearch: Sendable, Identifiable {
    public var id: String { offlineAddressKey(address) }
    public let address: ObjectAddress
    public let document: OfflineIssuerResearchDocument
}

public struct OfflineIssuerRestorePlan: Sendable {
    public let storagePlan: StoragePlan
    public let importedObjects: [ObjectAddress: ObjectAddress]
    public let importedRoots: [ObjectAddress: ObjectAddress]
    public var id: UUID { storagePlan.id }
    public var digest: String { storagePlan.digest }
    public var baseRevision: UUID { storagePlan.baseRevision }
    public var operation: StorageOperation { storagePlan.operation }
    public var objectCount: Int { storagePlan.objectCount }
    public var rootCount: Int { storagePlan.rootCount }
    public var deduplicatedObjects: Int { storagePlan.deduplicatedObjects }
    public var removedObjects: Set<ObjectAddress> { storagePlan.removedObjects }
    public var removedRoots: Set<ObjectAddress> { storagePlan.removedRoots }
}

/// Explicitly separate from the synthetic DEMO database. This store archives
/// reviewed local issuer excerpts, not original issuer documents or licensed feeds.
/// Loading and restoring validate the frozen record; formula replay is an explicit
/// OfflineIssuerResearchDocument.recompute() call by the caller.
public actor OfflineIssuerResearchStore {
    private let database: DatabaseStore
    private let snapshots: BusinessDataStore

    public init(path: String) throws {
        let database = try DatabaseStore(path: path, purpose: .offlineIssuerResearch)
        try self.init(database: database)
    }

    init(database: DatabaseStore) throws {
        guard database.purpose == .offlineIssuerResearch else { throw MigrationError.incompatiblePurpose }
        try database.read { db in try Self.checkScope(db); _ = try Self.revision(db) }
        self.database = database
        self.snapshots = try BusinessDataStore(database: database)
    }

    public func writeRevision() throws -> UUID {
        try database.read { db in
            try Self.checkPurpose(db)
            return try Self.revision(db)
        }
    }

    public func save(_ document: OfflineIssuerResearchDocument) async throws {
        let revision = try writeRevision()
        try await save(document, expectedRevision: revision)
    }

    public func save(_ document: OfflineIssuerResearchDocument, expectedRevision: UUID) async throws {
        // The caller's baseline is never refreshed after validation or an actor hop.
        try document.validate()
        guard document.retention.mayStore else { throw SnapshotError.retentionDenied }
        _ = try database.read { db in
            try BusinessDataStore.checkRevision(expectedRevision, db: db)
            return try Self.state(db).graph(forBackup: false)
        }
        let bundle = try Self.bundle(document)
        try Task.checkCancellation()
        try await snapshots.freeze(bundle, expectedRevision: expectedRevision)
    }

    public func savedResearch() throws -> [SavedOfflineIssuerResearch] {
        let frozen = try database.read(Self.state)
        return try frozen.records(forBackup: false)
    }

    public func exportBackup() throws -> Data {
        let frozen = try database.read(Self.state)
        try Task.checkCancellation()
        return try OfflineIssuerResearchArchiveCodec.encode(frozen)
    }

    public func prepareRestore(_ bytes: Data, mode: RestoreMode, expectedRevision: UUID) async throws -> OfflineIssuerRestorePlan {
        let incoming = try OfflineIssuerResearchArchiveCodec.decode(bytes)
        let graph = try incoming.graph(forBackup: true)
        try database.read { db in
            try BusinessDataStore.checkRevision(expectedRevision, db: db)
            if mode == .replace { try Self.checkScope(db) }
            else { _ = try Self.state(db).graph(forBackup: false) }
        }
        try Task.checkCancellation()
        let prepared = try await snapshots.prepareRestoreGraph(graph, mode: mode, expectedRevision: expectedRevision)
        if Task.isCancelled {
            await snapshots.cancel(planID: prepared.summary.id)
            throw CancellationError()
        }
        return OfflineIssuerRestorePlan(storagePlan: prepared.summary,
            importedObjects: prepared.importedObjects, importedRoots: prepared.importedRoots)
    }

    public func commit(_ approval: PlanApproval) async throws -> StorageCommit {
        try database.read(Self.checkScope)
        try Task.checkCancellation()
        // The retained generic storage candidate owns revision validation,
        // transaction rollback, stale consumption and ordinary-failure retry.
        return try await snapshots.commit(approval)
    }

    public func cancel(planID: UUID) async { await snapshots.cancel(planID: planID) }

    private static func checkPurpose(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "PRAGMA application_id") == DatabasePurpose.offlineIssuerResearch.applicationID else {
            throw MigrationError.incompatiblePurpose
        }
    }

    private static func revision(_ db: Database) throws -> UUID {
        guard let text = try String.fetchOne(db, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1"),
              let revision = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
        return revision
    }

    private static func checkScope(_ db: Database) throws {
        try checkPurpose(db)
        let tables = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*'"))
        let supported = Set(ResearchTransferStore.clearTables + ["p1_store_metadata", "grdb_migrations"])
        guard tables == supported else { throw SnapshotError.unsupportedFormat }
        // Do not silently omit other business content from this archive's scope.
        for table in ResearchTransferStore.clearTables where !table.hasPrefix("p1_snapshot_") {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0 else { throw SnapshotError.unsupportedFormat }
        }
    }

    private static func state(_ db: Database) throws -> OfflineIssuerResearchArchiveState {
        try checkScope(db)
        return OfflineIssuerResearchArchiveState(graph: try BusinessDataStore.loadGraph(db))
    }

    static func bundle(_ document: OfflineIssuerResearchDocument) throws -> SnapshotBundle {
        let permission = RetentionPermission(mayStore: document.retention.mayStore,
            mayBackup: document.retention.mayBackup, evidenceReference: document.retention.evidenceReference)
        let prefix = document.id.uuidString.lowercased()
        let values: [(String, FrozenObjectKind, Data)] = try [
            ("offline-document", .result, ResearchDocument.encoded(document)),
            ("excerpt", .input, document.excerptData),
            ("input-snapshot", .input, ResearchDocument.encoded(document.inputSnapshot)),
            ("models", .model, ResearchDocument.encoded(document.models)),
            ("parameters", .parameters, ResearchDocument.encoded(document.parameters)),
            ("base-report", .result, ResearchDocument.encoded(document.baseReport)),
            ("growth-report", .result, ResearchDocument.encoded(document.growthReport)),
            ("completion-report", .result, ResearchDocument.encoded(document.completionReport))
        ]
        let objects = values.map { role, kind, bytes in
            FrozenObject(identity: .init(id: prefix + "." + role, version: "v1"), kind: kind,
                payload: .string(bytes.base64EncodedString()), references: [], capturedAt: document.baseReport.executionAt,
                permission: permission, synthetic: false)
        }
        let references = try zip(values, objects).map { value, object in
            ObjectReference(role: value.0, target: object.identity, contentHash: try object.contentHash())
        }
        let root = SnapshotRoot(identity: .init(id: prefix, version: "offline-issuer.v1"), kind: .analysisRun, references: references)
        return SnapshotBundle(sourceNamespace: document.id, objects: objects, roots: [root])
    }
}

struct OfflineIssuerResearchArchiveState: Sendable, Codable {
    let format: String
    let profile: String
    let objects: [ArchiveObject]
    let roots: [ArchiveRoot]

    init(graph: SnapshotGraph) {
        format = "offline-issuer-research-state.v1"
        profile = "offline-issuer-research.v1"
        objects = graph.objects.map {
            ArchiveObject(address: $0.key, origin: $0.value.source, object: $0.value.object, targets: $0.value.targets)
        }.sorted { offlineAddressKey($0.address) < offlineAddressKey($1.address) }
        roots = graph.roots.map {
            ArchiveRoot(address: $0.key, origin: $0.value.source, root: $0.value.root, targets: $0.value.targets)
        }.sorted { offlineAddressKey($0.address) < offlineAddressKey($1.address) }
    }

    func graph(forBackup: Bool) throws -> SnapshotGraph {
        let graph = try checkedGraph()
        _ = try Self.decodeRecords(graph, forBackup: forBackup)
        return graph
    }

    private func checkedGraph() throws -> SnapshotGraph {
        guard format == "offline-issuer-research-state.v1", profile == "offline-issuer-research.v1" else {
            throw SnapshotError.unsupportedFormat
        }
        guard objects.count + roots.count <= 100_000 else { throw SnapshotError.resourceLimit }
        guard Set(objects.map(\.address)).count == objects.count, Set(roots.map(\.address)).count == roots.count else {
            throw SnapshotError.duplicateObject
        }
        let graph = SnapshotGraph(objects: Dictionary(uniqueKeysWithValues: objects.map {
            ($0.address, PersistedObject(object: $0.object, source: $0.origin, targets: $0.targets))
        }), roots: Dictionary(uniqueKeysWithValues: roots.map {
            ($0.address, PersistedRoot(root: $0.root, source: $0.origin, targets: $0.targets))
        }))
        try BusinessDataStore.validate(graph)
        return graph
    }

    func records(forBackup: Bool) throws -> [SavedOfflineIssuerResearch] {
        let graph = try checkedGraph()
        return try Self.decodeRecords(graph, forBackup: forBackup)
    }

    private static func decodeRecords(_ graph: SnapshotGraph, forBackup: Bool) throws -> [SavedOfflineIssuerResearch] {
        var referenced = Set<ObjectAddress>(), records: [SavedOfflineIssuerResearch] = []
        for (address, stored) in graph.roots {
            try Task.checkCancellation()
            guard stored.root.kind == .analysisRun, let target = stored.targets["offline-document"],
                  let object = graph.objects[target]?.object, object.kind == .result, !object.synthetic,
                  case let .string(text) = object.payload, let bytes = Data(base64Encoded: text) else {
                throw SnapshotError.unsupportedFormat
            }
            let document = try JSONDecoder().decode(OfflineIssuerResearchDocument.self, from: bytes)
            try document.validate()
            guard document.retention.mayStore, !forBackup || document.retention.mayBackup else { throw SnapshotError.retentionDenied }
            let expected = try OfflineIssuerResearchStore.bundle(document)
            guard let root = expected.roots.first, root.identity == address.identity,
                  stored.source == ObjectAddress(namespace: document.id, identity: root.identity),
                  try root.contentHash() == stored.root.contentHash(),
                  Set(stored.targets.keys) == Set(root.references.map(\.role)) else { throw SnapshotError.hashMismatch }
            let byIdentity = Dictionary(uniqueKeysWithValues: expected.objects.map { ($0.identity, $0) })
            for reference in root.references {
                guard let address = stored.targets[reference.role], address.identity == reference.target,
                      let actual = graph.objects[address], let expectedObject = byIdentity[reference.target],
                      actual.source == ObjectAddress(namespace: document.id, identity: reference.target),
                      actual.object.references.isEmpty, actual.targets.isEmpty,
                      try actual.object.contentBytes() == expectedObject.contentBytes() else { throw SnapshotError.hashMismatch }
                guard actual.object.permission.mayStore, !forBackup || actual.object.permission.mayBackup else {
                    throw SnapshotError.retentionDenied
                }
                referenced.insert(address)
            }
            records.append(SavedOfflineIssuerResearch(address: address, document: document))
        }
        guard referenced == Set(graph.objects.keys) else { throw SnapshotError.missingReference }
        return records.sorted { a, b in
            let left = a.document.baseReport.executionAt, right = b.document.baseReport.executionAt
            return left == right ? a.id < b.id : left > right
        }
    }
}

private struct OfflineIssuerArchiveManifest: Codable {
    let format: String, schema: String, scope: String, profile: String, application: String
    let file: String, sha256: String
    let size: Int, objects: Int, roots: Int
}

public enum OfflineIssuerResearchArchiveCodec {
    static func encode(_ state: OfflineIssuerResearchArchiveState) throws -> Data {
        _ = try state.graph(forBackup: true)
        let bytes = try ResearchDocument.encoded(state)
        let manifest = OfflineIssuerArchiveManifest(format: "offline-issuer-research-backup.v1",
            schema: "offline-issuer-research-state.v1", scope: "local-reviewed-issuer-excerpts", profile: "offline-issuer-research.v1",
            application: "MarketDecision", file: "research-state.json", sha256: digest(bytes), size: bytes.count,
            objects: state.objects.count, roots: state.roots.count)
        return try ResearchZIP.encode(["manifest.json": ResearchDocument.encoded(manifest), "research-state.json": bytes])
    }

    static func decode(_ data: Data) throws -> OfflineIssuerResearchArchiveState {
        let files = try ResearchZIP.decode(data), manifestBytes = files["manifest.json"]!, bytes = files["research-state.json"]!
        try exactKeys(manifestBytes, ["format", "schema", "scope", "profile", "application", "file", "sha256", "size", "objects", "roots"])
        let manifest = try JSONDecoder().decode(OfflineIssuerArchiveManifest.self, from: manifestBytes)
        guard manifest.format == "offline-issuer-research-backup.v1", manifest.schema == "offline-issuer-research-state.v1",
              manifest.scope == "local-reviewed-issuer-excerpts", manifest.profile == "offline-issuer-research.v1",
              manifest.application == "MarketDecision", manifest.file == "research-state.json" else { throw SnapshotError.unsupportedFormat }
        guard manifest.size == bytes.count, manifest.sha256 == digest(bytes) else { throw SnapshotError.hashMismatch }
        try exactKeys(bytes, ["format", "profile", "objects", "roots"])
        let state = try JSONDecoder().decode(OfflineIssuerResearchArchiveState.self, from: bytes)
        guard state.objects.count == manifest.objects, state.roots.count == manifest.roots else { throw SnapshotError.hashMismatch }
        _ = try state.graph(forBackup: true)
        return state
    }

    private static func exactKeys(_ bytes: Data, _ expected: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == expected else {
            throw SnapshotError.unsupportedFormat
        }
    }
}

private func offlineAddressKey(_ address: ObjectAddress) -> String {
    address.namespace.uuidString.lowercased() + "/" + address.identity.id + "/" + address.identity.version
}
