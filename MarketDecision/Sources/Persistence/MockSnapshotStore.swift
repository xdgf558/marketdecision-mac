import Foundation
import DataContracts

public enum MockCommitError: Error { case injectedFailure, requiresSyntheticObjects }

/// Phase 0 reference implementation only: synthetic content in memory, no business database,
/// file deletion, ZIP extraction, notifications or Keychain dependency. Actor transactions have
/// no await between revision validation and commit. Real storage requires its own atomic evidence.
public actor MockSnapshotStore: SnapshotStorage {
    private struct StoredObject: Sendable { let object: FrozenObject; let source: ObjectAddress; let targets: [String: ObjectAddress] }
    private struct StoredRoot: Sendable { let root: SnapshotRoot; let source: ObjectAddress; let targets: [String: ObjectAddress] }
    private struct OriginContent: Hashable { let source: ObjectAddress; let hash: String }
    private func addressKey(_ address: ObjectAddress) -> String { address.namespace.uuidString + "/" + address.identity.id + "/" + address.identity.version }
    private struct Candidate: Sendable {
        let summary: StoragePlan
        let objects: [ObjectAddress: StoredObject]
        let roots: [ObjectAddress: StoredRoot]
    }
    private var currentRevision = UUID()
    private var objects: [ObjectAddress: StoredObject] = [:]
    private var roots: [ObjectAddress: StoredRoot] = [:]
    private var plans: [UUID: Candidate] = [:]
    private var failNextCommit = false
    public init() {}
    public func revision() -> UUID { currentRevision }
    public func counts() -> (objects: Int, roots: Int) { (objects.count, roots.count) }
    public func injectFailureOnNextCommit() { failNextCommit = true }
    private func checkRevision(_ revision: UUID) throws {
        guard revision == currentRevision else { throw SnapshotError.stalePlan }
    }
    private func validateSynthetic(_ bundle: SnapshotBundle) throws {
        try bundle.validate()
        guard bundle.objects.allSatisfy(\.synthetic) else { throw MockCommitError.requiresSyntheticObjects }
    }
    public func freeze(_ bundle: SnapshotBundle, expectedRevision: UUID) throws {
        try checkRevision(expectedRevision); try validateSynthetic(bundle)
        var nextObjects = objects, nextRoots = roots
        let mapping = Dictionary(uniqueKeysWithValues: bundle.objects.map { ($0.identity, ObjectAddress(namespace: bundle.sourceNamespace, identity: $0.identity)) })
        for object in bundle.objects {
            let address = mapping[object.identity]!
            if let old = nextObjects[address] {
                guard try old.object.contentHash() == object.contentHash() else { throw SnapshotError.duplicateObject }
            } else { nextObjects[address] = StoredObject(object: object, source: address, targets: targets(object.references, using: mapping)) }
        }
        for root in bundle.roots {
            let address = ObjectAddress(namespace: bundle.sourceNamespace, identity: root.identity)
            guard nextRoots[address] == nil else { throw SnapshotError.duplicateObject }
            nextRoots[address] = StoredRoot(root: root, source: address, targets: targets(root.references, using: mapping))
        }
        objects = nextObjects; roots = nextRoots; currentRevision = UUID()
    }
    public func content(at address: ObjectAddress, expectedHash: String) throws -> Data {
        guard let stored = objects[address] else { throw SnapshotError.missingReference }
        let bytes = try stored.object.contentBytes()
        guard digest(bytes) == expectedHash else { throw SnapshotError.hashMismatch }
        return bytes
    }
    public func resolvedTargets(at address: ObjectAddress) throws -> [String: ObjectAddress] {
        guard let object = objects[address] else { throw SnapshotError.missingReference }
        return object.targets
    }
    private func targets(_ refs: [ObjectReference], using mapping: [ObjectIdentity: ObjectAddress]) -> [String: ObjectAddress] {
        Dictionary(uniqueKeysWithValues: refs.map { ($0.role, mapping[$0.target]!) })
    }
    public func prepareRestore(_ bundle: SnapshotBundle, inventory: BackupInventory, mode: RestoreMode, expectedRevision: UUID) throws -> StoragePlan {
        try checkRevision(expectedRevision); try validateSynthetic(bundle); try inventory.validate(bundle: bundle)
        var nextObjects = mode == .replace ? [:] : objects
        var nextRoots = mode == .replace ? [:] : roots
        let importedNamespace = UUID()
        var mapping: [ObjectIdentity: ObjectAddress] = [:], deduplicated = 0
        // Index original and current namespaces so repeated imports reuse the same content.
        var objectIndex: [OriginContent: ObjectAddress] = [:], rootIndex: [OriginContent: ObjectAddress] = [:]
        for address in nextObjects.keys.sorted(by: { addressKey($0) < addressKey($1) }) {
            let stored = nextObjects[address]!, hash = try stored.object.contentHash()
            objectIndex[.init(source: stored.source, hash: hash)] = address
            objectIndex[.init(source: address, hash: hash)] = address
        }
        for address in nextRoots.keys.sorted(by: { addressKey($0) < addressKey($1) }) {
            let stored = nextRoots[address]!, hash = try stored.root.contentHash()
            rootIndex[.init(source: stored.source, hash: hash)] = address
            rootIndex[.init(source: address, hash: hash)] = address
        }
        // Map the entire incoming graph before linking any edges. No rewriting frozen IDs/hashes.
        for object in bundle.objects {
            let sourceAddress = ObjectAddress(namespace: bundle.sourceNamespace, identity: object.identity)
            if let existing = objectIndex[.init(source: sourceAddress, hash: try object.contentHash())] {
                mapping[object.identity] = existing; deduplicated += 1
            } else {
                mapping[object.identity] = ObjectAddress(namespace: importedNamespace, identity: object.identity)
            }
        }
        for object in bundle.objects {
            let address = mapping[object.identity]!
            if nextObjects[address] == nil { nextObjects[address] = StoredObject(object: object, source: .init(namespace: bundle.sourceNamespace, identity: object.identity), targets: targets(object.references, using: mapping)) }
        }
        var rootMapping: [ObjectIdentity: ObjectAddress] = [:]
        for root in bundle.roots {
            let sourceAddress = ObjectAddress(namespace: bundle.sourceNamespace, identity: root.identity)
            if let existing = rootIndex[.init(source: sourceAddress, hash: try root.contentHash())] {
                rootMapping[root.identity] = existing
            } else {
                let address = ObjectAddress(namespace: importedNamespace, identity: root.identity)
                nextRoots[address] = StoredRoot(root: root, source: sourceAddress, targets: targets(root.references, using: mapping))
                rootMapping[root.identity] = address
            }
        }
        return try retainPlan(operation: mode == .merge ? .restoreMerge : .restoreReplace, objects: nextObjects,
                              roots: nextRoots, mapping: mapping, rootMapping: rootMapping, deduplicated: deduplicated)
    }
    private func protectedAddresses() -> Set<ObjectAddress> {
        var protected = Set(roots.values.flatMap { $0.targets.values }), queue = Array(roots.values.flatMap { $0.targets.values }), i = 0
        while i < queue.count {
            let address = queue[i]; i += 1
            for target in objects[address]?.targets.values ?? Dictionary<String, ObjectAddress>().values {
                if protected.insert(target).inserted { queue.append(target) }
            }
        }
        return protected
    }
    public func prepareDeletion(_ scope: DeletionScope, expectedRevision: UUID) throws -> StoragePlan {
        try checkRevision(expectedRevision)
        var nextObjects = objects, nextRoots = roots
        let operation: StorageOperation
        switch scope {
        case let .unreferencedCache(addresses):
            operation = .cleanup
            guard addresses.isDisjoint(with: protectedAddresses()) else { throw SnapshotError.protectedObject }
            guard addresses.allSatisfy({ objects[$0] != nil }) else { throw SnapshotError.missingReference }
            // Also retain dependencies of unrooted objects not included in this deletion.
            guard !objects.contains(where: { !addresses.contains($0.key) && !$0.value.targets.values.allSatisfy { !addresses.contains($0) } }) else {
                throw SnapshotError.protectedObject
            }
            for address in addresses { nextObjects.removeValue(forKey: address) }
        case let .roots(addresses):
            operation = .deleteRoots
            guard addresses.allSatisfy({ roots[$0] != nil }) else { throw SnapshotError.missingReference }
            for address in addresses { nextRoots.removeValue(forKey: address) }
        case .allBusiness:
            operation = .clearBusiness; nextObjects = [:]; nextRoots = [:]
        }
        return try retainPlan(operation: operation, objects: nextObjects, roots: nextRoots, mapping: [:], rootMapping: [:], deduplicated: 0)
    }
    private func retainPlan(operation: StorageOperation, objects: [ObjectAddress: StoredObject], roots: [ObjectAddress: StoredRoot],
                            mapping: [ObjectIdentity: ObjectAddress], rootMapping: [ObjectIdentity: ObjectAddress], deduplicated: Int) throws -> StoragePlan {
        let id = UUID()
        var fields: [CanonicalMember] = [.init("plan", .string(id.uuidString)), .init("base", .string(currentRevision.uuidString)), .init("operation", .string(operation.rawValue))]
        func links(_ refs: [String: ObjectAddress]) -> CanonicalValue {
            .object(refs.map { CanonicalMember($0.key, .string(addressKey($0.value))) })
        }
        let contents = try objects.map { address, stored in CanonicalMember(addressKey(address),
            .object([.init("hash", .string(try stored.object.contentHash())), .init("source", .string(addressKey(stored.source))), .init("resolvedReferences", links(stored.targets))])) }
        fields.append(.init("objects", .object(contents)))
        let rootContents = try roots.map { address, stored in CanonicalMember(addressKey(address),
            .object([.init("hash", .string(try stored.root.contentHash())), .init("source", .string(addressKey(stored.source))), .init("resolvedReferences", links(stored.targets))])) }
        fields.append(.init("roots", .object(rootContents)))
        func imported(_ mapping: [ObjectIdentity: ObjectAddress]) -> CanonicalValue {
            .object(mapping.map { CanonicalMember($0.key.id + "/" + $0.key.version, .string(addressKey($0.value))) })
        }
        fields.append(.init("importedObjects", imported(mapping)))
        fields.append(.init("importedRoots", imported(rootMapping)))
        let summary = StoragePlan(id: id, baseRevision: currentRevision, operation: operation,
            digest: digest(try CanonicalValue.object(fields).canonicalData()), objectCount: objects.count, rootCount: roots.count,
            importedAddresses: mapping, importedRoots: rootMapping, deduplicatedObjects: deduplicated,
            removedObjects: Set(self.objects.keys).subtracting(objects.keys), removedRoots: Set(self.roots.keys).subtracting(roots.keys))
        plans[id] = Candidate(summary: summary, objects: objects, roots: roots)
        return summary
    }
    public func commit(_ approval: PlanApproval) throws -> StorageCommit {
        guard let candidate = plans[approval.planID] else { throw SnapshotError.unknownPlan }
        guard candidate.summary.digest == approval.digest else { throw SnapshotError.approvalMismatch }
        plans.removeValue(forKey: approval.planID)
        try checkRevision(candidate.summary.baseRevision)
        if failNextCommit { failNextCommit = false; throw MockCommitError.injectedFailure }
        objects = candidate.objects; roots = candidate.roots; currentRevision = UUID()
        return StorageCommit(revision: currentRevision, operation: candidate.summary.operation)
    }
    public func cancel(planID: UUID) { plans.removeValue(forKey: planID) }
}
