import Foundation

public struct ObjectAddress: Sendable, Hashable, Codable {
    public let namespace: UUID
    public let identity: ObjectIdentity
    public init(namespace: UUID, identity: ObjectIdentity) { self.namespace = namespace; self.identity = identity }
}
public enum ArchiveEntryKind: String, Sendable, Codable { case regularFile, directory, symbolicLink }
public enum ArchiveContentClass: String, Sendable, Codable { case business, credential, deviceCredentialReference }
public struct BackupObjectEntry: Sendable, Codable {
    public let identity: ObjectIdentity
    public let path: String, contentHash: String
    public let bytes: Int64, compressedBytes: Int64
    public let kind: ArchiveEntryKind
    public let contentClass: ArchiveContentClass
    public init(identity: ObjectIdentity, path: String, contentHash: String, bytes: Int64, compressedBytes: Int64,
                kind: ArchiveEntryKind = .regularFile, contentClass: ArchiveContentClass = .business) {
        self.identity = identity; self.path = path; self.contentHash = contentHash; self.bytes = bytes
        self.compressedBytes = compressedBytes; self.kind = kind; self.contentClass = contentClass
    }
}
/// Read-only inventory of staged object files. No ZIP parser/extractor or credential store.
/// A future archive reader must verify physical bytes, entry metadata and manifest overhead.
public struct BackupInventory: Sendable, Codable {
    public let entries: [BackupObjectEntry]
    public init(entries: [BackupObjectEntry]) { self.entries = entries }
    public func validateDeclarations() throws {
        guard entries.count <= 100_000 else { throw SnapshotError.resourceLimit }
        var paths = Set<String>(), ids = Set<ObjectIdentity>(), bytes: Int64 = 0, compressed: Int64 = 0
        for entry in entries {
            try entry.identity.validate()
            guard entry.contentClass == .business else { throw SnapshotError.credentialMaterial }
            guard entry.kind == .regularFile, entry.path.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./-]*\z"#, options: .regularExpression) != nil,
                  entry.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(entry.path.lowercased()).inserted, ids.insert(entry.identity).inserted else { throw SnapshotError.unsafeArchive }
            guard hashString(entry.contentHash) else { throw SnapshotError.hashMismatch }
            guard entry.bytes >= 0, entry.bytes <= 1_073_741_824, entry.compressedBytes >= 0,
                  entry.compressedBytes <= 2_147_483_648,
                  entry.bytes <= entry.compressedBytes * 100 else { throw SnapshotError.resourceLimit }
            bytes += entry.bytes; compressed += entry.compressedBytes
            guard bytes <= 8_589_934_592, compressed <= 2_147_483_648 else { throw SnapshotError.resourceLimit }
        }
    }
    public func validate(bundle: SnapshotBundle) throws {
        try validateDeclarations(); try bundle.validate(forBackup: true)
        guard Set(entries.map(\.identity)) == Set(bundle.objects.map(\.identity)) else { throw SnapshotError.missingReference }
        let objects = Dictionary(uniqueKeysWithValues: bundle.objects.map { ($0.identity, $0) })
        for entry in entries {
            let object = objects[entry.identity]!
            guard try entry.contentHash == object.contentHash(), entry.bytes == Int64(try object.contentBytes().count) else { throw SnapshotError.hashMismatch }
        }
    }
}
public enum RestoreMode: String, Sendable, Codable { case merge, replace }
public enum DeletionScope: Sendable { case unreferencedCache(Set<ObjectAddress>), roots(Set<ObjectAddress>), allBusiness }
public enum StorageOperation: String, Sendable { case restoreMerge, restoreReplace, cleanup, deleteRoots, clearBusiness }
public struct StoragePlan: Sendable {
    public let id: UUID, baseRevision: UUID
    public let operation: StorageOperation
    public let digest: String
    public let objectCount: Int, rootCount: Int
    public let importedAddresses: [ObjectIdentity: ObjectAddress]
    public let importedRoots: [ObjectIdentity: ObjectAddress]
    public let deduplicatedObjects: Int
    public let removedObjects: Set<ObjectAddress>, removedRoots: Set<ObjectAddress>
    public init(id: UUID, baseRevision: UUID, operation: StorageOperation, digest: String, objectCount: Int, rootCount: Int,
                importedAddresses: [ObjectIdentity: ObjectAddress], importedRoots: [ObjectIdentity: ObjectAddress], deduplicatedObjects: Int,
                removedObjects: Set<ObjectAddress>, removedRoots: Set<ObjectAddress>) {
        self.id = id; self.baseRevision = baseRevision; self.operation = operation; self.digest = digest
        self.objectCount = objectCount; self.rootCount = rootCount; self.importedAddresses = importedAddresses
        self.importedRoots = importedRoots; self.deduplicatedObjects = deduplicatedObjects
        self.removedObjects = removedObjects; self.removedRoots = removedRoots
    }
}
/// Caller supplies this only after presenting and confirming this exact plan. Not an auth token.
/// The store must use its own retained plan; a caller-constructed StoragePlan cannot authorize work.
public struct PlanApproval: Sendable {
    public let planID: UUID
    public let digest: String
    public init(planID: UUID, digest: String) { self.planID = planID; self.digest = digest }
}
public struct StorageCommit: Sendable {
    public let revision: UUID
    public let operation: StorageOperation
    public let credentialAction: CredentialBoundaryAction
    public init(revision: UUID, operation: StorageOperation) {
        self.revision = revision; self.operation = operation; self.credentialAction = .untouched
    }
}
public enum CredentialBoundaryAction: String, Sendable { case untouched }
public protocol SnapshotStorage: Sendable {
    func revision() async -> UUID
    func freeze(_ bundle: SnapshotBundle, expectedRevision: UUID) async throws
    func content(at address: ObjectAddress, expectedHash: String) async throws -> Data
    func prepareRestore(_ bundle: SnapshotBundle, inventory: BackupInventory, mode: RestoreMode, expectedRevision: UUID) async throws -> StoragePlan
    func prepareDeletion(_ scope: DeletionScope, expectedRevision: UUID) async throws -> StoragePlan
    func commit(_ approval: PlanApproval) async throws -> StorageCommit
    func cancel(planID: UUID) async
}
