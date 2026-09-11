import Foundation
import GRDB
import CoreDomain
import DataContracts

public enum BusinessStoreError: Error, Equatable {
    case invalidSourceDocument
    case sourceMismatch
    case immutableConflict
    case unsupportedDerivedObservation
    case corruptedStorage
    case injectedFailure
}

/// Raw provider/filing bytes with the exact storage and license evidence used at ingest time.
/// `reference` is an opaque local identifier, never a URL, header or credential container.
public struct SourceDocument: Sendable {
    public let reference: String
    public let providerID: String
    public let feedID: String
    public let endpoint: EndpointDescriptor
    public let receivedAt: MillisecondInstant
    public let availableAt: MillisecondInstant
    public let mediaType: String
    public let evidenceRef: String
    public let licenseRef: String
    public let payload: Data
    public let contentHash: String

    public init(reference: String, providerID: String, feedID: String, endpoint: EndpointDescriptor,
                receivedAt: MillisecondInstant, availableAt: MillisecondInstant, mediaType: String,
                evidenceRef: String, licenseRef: String, payload: Data) throws {
        guard localReference(reference), storageIdentifier(providerID), storageIdentifier(feedID), endpoint.providerCapability != nil,
              mediaType.range(of: #"^[A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*\z"#,
                              options: .regularExpression) != nil,
              nonempty(evidenceRef), nonempty(licenseRef), !payload.isEmpty, payload.count <= 100 * 1_024 * 1_024,
              availableAt <= receivedAt else { throw BusinessStoreError.invalidSourceDocument }
        self.reference = reference; self.providerID = providerID; self.feedID = feedID; self.endpoint = endpoint
        self.receivedAt = receivedAt; self.availableAt = availableAt; self.mediaType = mediaType
        self.evidenceRef = evidenceRef; self.licenseRef = licenseRef; self.payload = payload
        self.contentHash = digest(payload)
    }

    fileprivate var metadataHash: String {
        get throws {
            digest(try CanonicalValue.object([
                .init("reference", .string(reference)), .init("provider", .string(providerID)),
                .init("feed", .string(feedID)), .init("endpoint", .string(endpoint.rawValue)),
                .init("receivedAt", .string(receivedAt.iso8601)), .init("availableAt", .string(availableAt.iso8601)),
                .init("mediaType", .string(mediaType)), .init("evidence", .string(evidenceRef)),
                .init("license", .string(licenseRef)), .init("contentHash", .string(contentHash))
            ]).canonicalData())
        }
    }
}

/// A source observation placed in a stable logical series. Derived results remain in the
/// calculation/snapshot layer because their complete model context is required to reconstruct them.
public struct SeriesObservation: Sendable {
    public let seriesID: String
    public let value: NumericObservation
    public init(seriesID: String, value: NumericObservation) throws {
        guard storageIdentifier(seriesID), value.calculation == nil, value.provenance.origin != .derived
        else { throw value.provenance.origin == .derived ? BusinessStoreError.unsupportedDerivedObservation : BusinessStoreError.sourceMismatch }
        try value.provenance.validate()
        guard value.provenance.versionKind == .sourceVersion,
              value.provenance.observationDate != nil,
              value.provenance.versionID != nil,
              value.provenance.rawObjectRef != nil,
              value.provenance.rawHash != nil,
              (try? value.provenance.availability.upperBound()) != nil
        else { throw BusinessStoreError.sourceMismatch }
        self.seriesID = seriesID; self.value = value
    }
}

public struct BusinessIngestReceipt: Sendable, Equatable {
    public let insertedDocuments: Int
    public let insertedObservations: Int
    public let revision: UUID
}

public struct BusinessStoreCounts: Sendable, Equatable {
    public let sourceDocuments: Int
    public let observations: Int
    public let snapshotObjects: Int
    public let snapshotRoots: Int
    public init(sourceDocuments: Int, observations: Int, snapshotObjects: Int, snapshotRoots: Int) {
        self.sourceDocuments = sourceDocuments; self.observations = observations
        self.snapshotObjects = snapshotObjects; self.snapshotRoots = snapshotRoots
    }
}

public struct CachePurgeReceipt: Sendable, Equatable {
    public let removedDocuments: Int
    public let removedObservations: Int
    public let revision: UUID
}

private struct ObservationEnvelope: Codable {
    let recordID: String
    let provenance: Provenance
    let rawValue: String?
    let canonicalValue: String?
    let state: ValueState
    let unit: ValueUnit
    let currency: String?
    let numericPolicyRef: String
    let reasons: [String]

    init(_ observation: NumericObservation) {
        recordID = observation.recordID; provenance = observation.provenance; rawValue = observation.rawValue
        canonicalValue = observation.value?.decimalString; state = observation.state; unit = observation.unit
        currency = observation.currency; numericPolicyRef = observation.numericPolicyRef; reasons = observation.reasons
    }
    func decoded() throws -> NumericObservation {
        try NumericObservation(recordID: recordID, provenance: provenance, rawValue: rawValue,
                               value: try canonicalValue.map(Money.init), state: state, unit: unit,
                               currency: currency, numericPolicyRef: numericPolicyRef, reasons: reasons)
    }
}

private struct PersistedObject: Sendable {
    let object: FrozenObject
    let source: ObjectAddress
    let targets: [String: ObjectAddress]
}
private struct PersistedRoot: Sendable {
    let root: SnapshotRoot
    let source: ObjectAddress
    let targets: [String: ObjectAddress]
}
private struct SnapshotGraph: Sendable {
    var objects: [ObjectAddress: PersistedObject]
    var roots: [ObjectAddress: PersistedRoot]
}
private struct OriginContent: Hashable {
    let source: ObjectAddress
    let hash: String
}
private struct SQLiteCandidate: Sendable {
    let summary: StoragePlan
    let graph: SnapshotGraph
}

/// Phase 1 SQLite boundary for raw source records, point-in-time observations and immutable
/// snapshot graphs. All mutations compare a persisted revision inside the same transaction.
public actor BusinessDataStore: SnapshotStorage {
    private let database: DatabaseStore
    private var currentRevision: UUID
    private var plans: [UUID: SQLiteCandidate] = [:]
    private var failNextCommit = false

    public init(path: String) throws {
        let database = try DatabaseStore(path: path)
        self.database = database
        self.currentRevision = try Self.readRevision(database)
    }
    public init(database: DatabaseStore) throws {
        self.database = database
        self.currentRevision = try Self.readRevision(database)
    }

    public func revision() -> UUID {
        if let persisted = try? Self.readRevision(database) { currentRevision = persisted }
        return currentRevision
    }

    public func counts() throws -> BusinessStoreCounts {
        try database.read { db in
            BusinessStoreCounts(
                sourceDocuments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_source_documents")!,
                observations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_observations")!,
                snapshotObjects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_objects")!,
                snapshotRoots: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_roots")!)
        }
    }

    /// Document and observation rows enter together. Replaying identical bytes is a no-op;
    /// reusing an immutable identity with different bytes or metadata fails the whole transaction.
    /// Production pipelines must accept the provider result against its dispatched request before
    /// calling this storage boundary. This method rechecks document/observation coherence, but it
    /// cannot infer the original request capability; direct callers in this slice are synthetic tests.
    @discardableResult
    public func ingest(document: SourceDocument, observations: [SeriesObservation], expectedRevision: UUID) throws -> BusinessIngestReceipt {
        try observations.forEach { try Self.validate($0, against: document) }
        let documentHash = try document.metadataHash
        let encoded = try observations.map { ($0, try Self.encode(ObservationEnvelope($0.value))) }
        let nextRevision = UUID()
        let inserted = try database.transaction { db -> (Int, Int) in
            try Self.checkRevision(expectedRevision, db: db)
            var documents = 0, values = 0
            if let existing = try String.fetchOne(db, sql: "SELECT metadata_hash FROM p1_source_documents WHERE reference = ?", arguments: [document.reference]) {
                guard existing == documentHash else { throw BusinessStoreError.immutableConflict }
            } else {
                try db.execute(sql: """
                    INSERT INTO p1_source_documents
                    (reference, metadata_hash, content_hash, provider_id, feed_id, endpoint_descriptor,
                     received_at_ms, available_at_ms, media_type, evidence_ref, license_ref, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [document.reference, documentHash, document.contentHash, document.providerID,
                                      document.feedID, document.endpoint.rawValue, document.receivedAt.milliseconds,
                                      document.availableAt.milliseconds, document.mediaType, document.evidenceRef,
                                      document.licenseRef, document.payload])
                documents = 1
            }
            for (item, bytes) in encoded {
                let observation = item.value, provenance = observation.provenance
                let version = provenance.versionID!, day = Self.dateString(provenance.observationDate!)
                let recordHash = digest(bytes)
                if let existing = try String.fetchOne(db, sql: """
                    SELECT record_hash FROM p1_observations
                    WHERE series_id = ? AND record_id = ? AND version_id = ?
                    """, arguments: [item.seriesID, observation.recordID, version]) {
                    guard existing == recordHash else { throw BusinessStoreError.immutableConflict }
                } else {
                    let available = try MillisecondInstant(rounding: provenance.availability.upperBound())
                    try db.execute(sql: """
                        INSERT INTO p1_observations
                        (series_id, record_id, version_id, observation_date, available_at_ms, state, unit,
                         currency, raw_value, canonical_value, numeric_policy_ref, source_reference, record_hash, record_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [item.seriesID, observation.recordID, version, day, available.milliseconds,
                                          observation.state.rawValue, observation.unit.rawValue, observation.currency,
                                          observation.rawValue, observation.value?.decimalString, observation.numericPolicyRef,
                                          document.reference, recordHash, bytes])
                    values += 1
                }
            }
            if documents + values > 0 { try Self.writeRevision(nextRevision, db: db) }
            return (documents, values)
        }
        if inserted.0 + inserted.1 > 0 { currentRevision = nextRevision }
        return BusinessIngestReceipt(insertedDocuments: inserted.0, insertedObservations: inserted.1, revision: currentRevision)
    }

    public func sourceDocument(reference: String) throws -> SourceDocument {
        guard localReference(reference), let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM p1_source_documents WHERE reference = ?", arguments: [reference])
        }) else { throw SnapshotError.missingReference }
        guard let endpoint = EndpointDescriptor(rawValue: row["endpoint_descriptor"]),
              let received = try? MillisecondInstant(milliseconds: row["received_at_ms"]),
              let available = try? MillisecondInstant(milliseconds: row["available_at_ms"]) else { throw BusinessStoreError.corruptedStorage }
        let document = try SourceDocument(reference: row["reference"], providerID: row["provider_id"], feedID: row["feed_id"],
                                          endpoint: endpoint, receivedAt: received, availableAt: available,
                                          mediaType: row["media_type"], evidenceRef: row["evidence_ref"],
                                          licenseRef: row["license_ref"], payload: row["payload"])
        guard document.contentHash == row["content_hash"], try document.metadataHash == row["metadata_hash"]
        else { throw BusinessStoreError.corruptedStorage }
        return document
    }

    /// Returns one unambiguous version per stable record identity using the version's own
    /// availability evidence. No current/latest fallback is performed for an as-of query.
    public func observations(seriesID: String, range: MarketDateRange, asOf cutoff: Date) throws -> [NumericObservation] {
        guard storageIdentifier(seriesID) else { throw BusinessStoreError.sourceMismatch }
        try range.validate()
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint_descriptor,
                       d.evidence_ref AS source_evidence_ref, d.license_ref AS source_license_ref
                FROM p1_observations o
                JOIN p1_source_documents d ON d.reference = o.source_reference
                WHERE o.series_id = ? AND o.observation_date >= ? AND o.observation_date <= ? AND o.available_at_ms <= ?
                ORDER BY o.observation_date, o.record_id, o.available_at_ms, o.version_id
                """, arguments: [seriesID, Self.dateString(range.start), Self.dateString(range.end), cutoffMS])
        }
        var versions: [String: [NumericObservation]] = [:]
        for row in rows {
            let bytes: Data = row["record_json"]
            guard digest(bytes) == row["record_hash"] else { throw BusinessStoreError.corruptedStorage }
            let value = try Self.decode(ObservationEnvelope.self, from: bytes).decoded()
            let currency: String? = row["currency"], rawValue: String? = row["raw_value"]
            let canonicalValue: String? = row["canonical_value"]
            let available = try MillisecondInstant(rounding: value.provenance.availability.upperBound()).milliseconds
            guard row["series_id"] == seriesID, row["record_id"] == value.recordID,
                  row["version_id"] == value.provenance.versionID,
                  row["observation_date"] == Self.dateString(value.provenance.observationDate!),
                  row["available_at_ms"] == available, row["state"] == value.state.rawValue,
                  row["unit"] == value.unit.rawValue, currency == value.currency, rawValue == value.rawValue,
                  canonicalValue == value.value?.decimalString, row["numeric_policy_ref"] == value.numericPolicyRef,
                  row["source_reference"] == value.provenance.rawObjectRef,
                  row["source_content_hash"] == value.provenance.rawHash,
                  row["source_provider_id"] == value.provenance.providerID,
                  row["source_feed_id"] == value.provenance.feedID,
                  row["source_endpoint_descriptor"] == value.provenance.endpointDescriptor,
                  row["source_evidence_ref"] == value.provenance.evidenceRef,
                  row["source_license_ref"] == value.provenance.licenseRef
            else { throw BusinessStoreError.corruptedStorage }
            versions[value.recordID, default: []].append(value)
        }
        return try versions.keys.sorted().map { try AsOfSelector.select(versions[$0]!, cutoff: cutoff) }
            .sorted { lhs, rhs in
                let ld = lhs.provenance.observationDate!, rd = rhs.provenance.observationDate!
                return ld == rd ? lhs.recordID < rhs.recordID : ld < rd
            }
    }

    /// Deletes mutable source cache only. Frozen snapshot bytes and roots live in separate tables
    /// and are intentionally untouched, so a saved research snapshot remains reproducible offline.
    @discardableResult
    public func purgeCache(seriesIDs: Set<String>, expectedRevision: UUID) throws -> CachePurgeReceipt {
        guard !seriesIDs.isEmpty, seriesIDs.allSatisfy(storageIdentifier) else { throw BusinessStoreError.sourceMismatch }
        let nextRevision = UUID()
        let removed = try database.transaction { db -> (Int, Int) in
            try Self.checkRevision(expectedRevision, db: db)
            let beforeObservations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_observations")!
            let beforeDocuments = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_source_documents")!
            for series in seriesIDs { try db.execute(sql: "DELETE FROM p1_observations WHERE series_id = ?", arguments: [series]) }
            try db.execute(sql: """
                DELETE FROM p1_source_documents
                WHERE NOT EXISTS (SELECT 1 FROM p1_observations WHERE source_reference = p1_source_documents.reference)
                """)
            let afterObservations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_observations")!
            let afterDocuments = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_source_documents")!
            if beforeObservations != afterObservations || beforeDocuments != afterDocuments { try Self.writeRevision(nextRevision, db: db) }
            return (beforeDocuments - afterDocuments, beforeObservations - afterObservations)
        }
        if removed.0 + removed.1 > 0 { currentRevision = nextRevision }
        return CachePurgeReceipt(removedDocuments: removed.0, removedObservations: removed.1, revision: currentRevision)
    }

    func injectFailureOnNextCommit() { failNextCommit = true }

    public func freeze(_ bundle: SnapshotBundle, expectedRevision: UUID) throws {
        try bundle.validate()
        let newRevision = UUID()
        try database.transaction { db in
            try Self.checkRevision(expectedRevision, db: db)
            var graph = try Self.loadGraph(db)
            let mapping = Dictionary(uniqueKeysWithValues: bundle.objects.map {
                ($0.identity, ObjectAddress(namespace: bundle.sourceNamespace, identity: $0.identity))
            })
            for object in bundle.objects {
                let address = mapping[object.identity]!
                if let old = graph.objects[address] {
                    guard try old.object.contentHash() == object.contentHash() else { throw SnapshotError.duplicateObject }
                } else {
                    graph.objects[address] = PersistedObject(object: object, source: address,
                                                             targets: Self.targets(object.references, using: mapping))
                }
            }
            for root in bundle.roots {
                let address = ObjectAddress(namespace: bundle.sourceNamespace, identity: root.identity)
                guard graph.roots[address] == nil else { throw SnapshotError.duplicateObject }
                graph.roots[address] = PersistedRoot(root: root, source: address,
                                                     targets: Self.targets(root.references, using: mapping))
            }
            try Self.save(graph, revision: newRevision, db: db)
        }
        currentRevision = newRevision
    }

    public func content(at address: ObjectAddress, expectedHash: String) throws -> Data {
        guard let row = try database.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT content_hash, content FROM p1_snapshot_objects
                WHERE namespace = ? AND object_id = ? AND object_version = ?
                """, arguments: Self.arguments(address))
        }) else { throw SnapshotError.missingReference }
        let bytes: Data = row["content"]
        guard row["content_hash"] == expectedHash, digest(bytes) == expectedHash else { throw SnapshotError.hashMismatch }
        return bytes
    }

    public func resolvedTargets(at address: ObjectAddress) throws -> [String: ObjectAddress] {
        let graph = try database.read(Self.loadGraph)
        guard let object = graph.objects[address] else { throw SnapshotError.missingReference }
        return object.targets
    }

    public func prepareRestore(_ bundle: SnapshotBundle, inventory: BackupInventory, mode: RestoreMode,
                               expectedRevision: UUID) throws -> StoragePlan {
        try bundle.validate(); try inventory.validate(bundle: bundle)
        try database.read { try Self.checkRevision(expectedRevision, db: $0) }
        let current = try database.read(Self.loadGraph)
        var graph = mode == .replace ? SnapshotGraph(objects: [:], roots: [:]) : current
        let importedNamespace = UUID()
        var mapping: [ObjectIdentity: ObjectAddress] = [:], rootMapping: [ObjectIdentity: ObjectAddress] = [:]
        var objectIndex: [OriginContent: ObjectAddress] = [:], rootIndex: [OriginContent: ObjectAddress] = [:]
        for address in graph.objects.keys.sorted(by: { Self.addressKey($0) < Self.addressKey($1) }) {
            let stored = graph.objects[address]!, hash = try stored.object.contentHash()
            objectIndex[.init(source: stored.source, hash: hash)] = address
            objectIndex[.init(source: address, hash: hash)] = address
        }
        for address in graph.roots.keys.sorted(by: { Self.addressKey($0) < Self.addressKey($1) }) {
            let stored = graph.roots[address]!, hash = try stored.root.contentHash()
            rootIndex[.init(source: stored.source, hash: hash)] = address
            rootIndex[.init(source: address, hash: hash)] = address
        }
        var deduplicated = 0
        for object in bundle.objects {
            let source = ObjectAddress(namespace: bundle.sourceNamespace, identity: object.identity)
            if let existing = objectIndex[.init(source: source, hash: try object.contentHash())] {
                mapping[object.identity] = existing; deduplicated += 1
            } else { mapping[object.identity] = .init(namespace: importedNamespace, identity: object.identity) }
        }
        for object in bundle.objects {
            let address = mapping[object.identity]!
            if graph.objects[address] == nil {
                graph.objects[address] = PersistedObject(object: object,
                    source: .init(namespace: bundle.sourceNamespace, identity: object.identity),
                    targets: Self.targets(object.references, using: mapping))
            }
        }
        for root in bundle.roots {
            let source = ObjectAddress(namespace: bundle.sourceNamespace, identity: root.identity)
            if let existing = rootIndex[.init(source: source, hash: try root.contentHash())] {
                rootMapping[root.identity] = existing
            } else {
                let address = ObjectAddress(namespace: importedNamespace, identity: root.identity)
                graph.roots[address] = PersistedRoot(root: root, source: source,
                                                     targets: Self.targets(root.references, using: mapping))
                rootMapping[root.identity] = address
            }
        }
        return try retainPlan(operation: mode == .merge ? .restoreMerge : .restoreReplace, graph: graph,
                              mapping: mapping, rootMapping: rootMapping, deduplicated: deduplicated,
                              baseRevision: expectedRevision)
    }

    public func prepareDeletion(_ scope: DeletionScope, expectedRevision: UUID) throws -> StoragePlan {
        try database.read { try Self.checkRevision(expectedRevision, db: $0) }
        var graph = try database.read(Self.loadGraph)
        let operation: StorageOperation
        switch scope {
        case let .unreferencedCache(addresses):
            operation = .cleanup
            guard addresses.isDisjoint(with: Self.protectedAddresses(graph)) else { throw SnapshotError.protectedObject }
            guard addresses.allSatisfy({ graph.objects[$0] != nil }) else { throw SnapshotError.missingReference }
            guard !graph.objects.contains(where: {
                !addresses.contains($0.key) && !$0.value.targets.values.allSatisfy { !addresses.contains($0) }
            }) else { throw SnapshotError.protectedObject }
            for address in addresses { graph.objects.removeValue(forKey: address) }
        case let .roots(addresses):
            operation = .deleteRoots
            guard addresses.allSatisfy({ graph.roots[$0] != nil }) else { throw SnapshotError.missingReference }
            for address in addresses { graph.roots.removeValue(forKey: address) }
        case .allBusiness:
            operation = .clearBusiness; graph = .init(objects: [:], roots: [:])
        }
        return try retainPlan(operation: operation, graph: graph, mapping: [:], rootMapping: [:],
                              deduplicated: 0, baseRevision: expectedRevision)
    }

    public func commit(_ approval: PlanApproval) throws -> StorageCommit {
        guard let candidate = plans[approval.planID] else { throw SnapshotError.unknownPlan }
        guard candidate.summary.digest == approval.digest else { throw SnapshotError.approvalMismatch }
        do { try database.read { try Self.checkRevision(candidate.summary.baseRevision, db: $0) } }
        catch {
            if error as? SnapshotError == .stalePlan { plans.removeValue(forKey: approval.planID) }
            throw error
        }
        let inject = failNextCommit
        if inject { failNextCommit = false }
        let newRevision = UUID()
        do {
            try database.transaction { db in
                try Self.checkRevision(candidate.summary.baseRevision, db: db)
                if inject { throw BusinessStoreError.injectedFailure }
                try Self.save(candidate.graph, revision: newRevision, db: db)
            }
        } catch {
            if error as? SnapshotError == .stalePlan { plans.removeValue(forKey: approval.planID) }
            throw error
        }
        plans.removeValue(forKey: approval.planID)
        currentRevision = newRevision
        return StorageCommit(revision: newRevision, operation: candidate.summary.operation)
    }

    public func cancel(planID: UUID) { plans.removeValue(forKey: planID) }

    private func retainPlan(operation: StorageOperation, graph: SnapshotGraph,
                            mapping: [ObjectIdentity: ObjectAddress], rootMapping: [ObjectIdentity: ObjectAddress],
                            deduplicated: Int, baseRevision: UUID) throws -> StoragePlan {
        let current = try database.read(Self.loadGraph), id = UUID()
        func list(_ values: Set<ObjectAddress>) -> CanonicalValue {
            .array(values.sorted(by: { Self.addressKey($0) < Self.addressKey($1) }).map { .string(Self.addressKey($0)) })
        }
        let imported = mapping.sorted(by: { $0.key.id + $0.key.version < $1.key.id + $1.key.version })
            .map { CanonicalValue.string($0.key.id + "/" + $0.key.version + "=" + Self.addressKey($0.value)) }
        let importedRoots = rootMapping.sorted(by: { $0.key.id + $0.key.version < $1.key.id + $1.key.version })
            .map { CanonicalValue.string($0.key.id + "/" + $0.key.version + "=" + Self.addressKey($0.value)) }
        let removedObjects = Set(current.objects.keys).subtracting(graph.objects.keys)
        let removedRoots = Set(current.roots.keys).subtracting(graph.roots.keys)
        let fields: [CanonicalMember] = [
            .init("planID", .string(id.uuidString.lowercased())), .init("baseRevision", .string(baseRevision.uuidString.lowercased())),
            .init("operation", .string(operation.rawValue)), .init("objectCount", .integer(Int64(graph.objects.count))),
            .init("rootCount", .integer(Int64(graph.roots.count))), .init("deduplicated", .integer(Int64(deduplicated))),
            .init("removedObjects", list(removedObjects)), .init("removedRoots", list(removedRoots)),
            .init("imported", .array(imported)), .init("importedRoots", .array(importedRoots))
        ]
        let summary = StoragePlan(id: id, baseRevision: baseRevision, operation: operation,
                                  digest: digest(try CanonicalValue.object(fields).canonicalData()),
                                  objectCount: graph.objects.count, rootCount: graph.roots.count,
                                  importedAddresses: mapping, importedRoots: rootMapping,
                                  deduplicatedObjects: deduplicated, removedObjects: removedObjects, removedRoots: removedRoots)
        plans[id] = SQLiteCandidate(summary: summary, graph: graph)
        return summary
    }

    private static func validate(_ item: SeriesObservation, against document: SourceDocument) throws {
        let source = item.value.provenance
        guard source.providerID == document.providerID, source.feedID == document.feedID,
              source.endpointDescriptor == document.endpoint.rawValue, source.rawObjectRef == document.reference,
              source.rawHash == document.contentHash, source.licenseRef == document.licenseRef,
              source.evidenceRef == document.evidenceRef,
              try MillisecondInstant(rounding: source.receivedAt) >= document.receivedAt,
              try MillisecondInstant(rounding: source.availability.upperBound()) == document.availableAt
        else { throw BusinessStoreError.sourceMismatch }
    }

    private static func readRevision(_ database: DatabaseStore) throws -> UUID {
        let value = try database.read { try String.fetchOne($0, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1") }
        guard let value, let revision = UUID(uuidString: value) else { throw BusinessStoreError.corruptedStorage }
        return revision
    }
    private static func checkRevision(_ expected: UUID, db: Database) throws {
        guard let value = try String.fetchOne(db, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1"),
              UUID(uuidString: value) == expected else { throw SnapshotError.stalePlan }
    }
    private static func writeRevision(_ revision: UUID, db: Database) throws {
        try db.execute(sql: "UPDATE p1_store_metadata SET revision = ? WHERE singleton = 1",
                       arguments: [revision.uuidString.lowercased()])
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer(); try value.encode(MillisecondInstant(rounding: date).iso8601)
        }
        return try encoder.encode(value)
    }
    private static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try MillisecondInstant(iso8601: value).date
        }
        return try decoder.decode(type, from: bytes)
    }
    private static func dateString(_ date: MarketDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
    private static func arguments(_ address: ObjectAddress) -> StatementArguments {
        [address.namespace.uuidString.lowercased(), address.identity.id, address.identity.version]
    }
    private static func addressKey(_ address: ObjectAddress) -> String {
        address.namespace.uuidString.lowercased() + "/" + address.identity.id + "/" + address.identity.version
    }
    private static func targets(_ refs: [ObjectReference], using mapping: [ObjectIdentity: ObjectAddress]) -> [String: ObjectAddress] {
        Dictionary(uniqueKeysWithValues: refs.map { ($0.role, mapping[$0.target]!) })
    }
    private static func protectedAddresses(_ graph: SnapshotGraph) -> Set<ObjectAddress> {
        var protected = Set(graph.roots.values.flatMap { $0.targets.values })
        var queue = Array(protected), index = 0
        while index < queue.count {
            let address = queue[index]; index += 1
            for target in graph.objects[address]?.targets.values ?? Dictionary<String, ObjectAddress>().values {
                if protected.insert(target).inserted { queue.append(target) }
            }
        }
        return protected
    }

    private static func loadGraph(_ db: Database) throws -> SnapshotGraph {
        var objects: [ObjectAddress: (FrozenObject, ObjectAddress)] = [:]
        var objectTargets: [ObjectAddress: [String: ObjectAddress]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_objects") {
            guard let namespace = UUID(uuidString: row["namespace"]), let sourceNamespace = UUID(uuidString: row["source_namespace"])
            else { throw BusinessStoreError.corruptedStorage }
            let address = ObjectAddress(namespace: namespace, identity: .init(id: row["object_id"], version: row["object_version"]))
            let source = ObjectAddress(namespace: sourceNamespace, identity: .init(id: row["source_object_id"], version: row["source_object_version"]))
            let json: Data = row["object_json"], content: Data = row["content"], hash: String = row["content_hash"]
            let object = try decode(FrozenObject.self, from: json)
            guard try object.contentBytes() == content, digest(content) == hash else { throw BusinessStoreError.corruptedStorage }
            objects[address] = (object, source)
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_object_edges") {
            guard let namespace = UUID(uuidString: row["namespace"]), let targetNamespace = UUID(uuidString: row["target_namespace"])
            else { throw BusinessStoreError.corruptedStorage }
            let source = ObjectAddress(namespace: namespace, identity: .init(id: row["object_id"], version: row["object_version"]))
            let target = ObjectAddress(namespace: targetNamespace, identity: .init(id: row["target_id"], version: row["target_version"]))
            guard objects[source] != nil, objects[target] != nil else { throw BusinessStoreError.corruptedStorage }
            objectTargets[source, default: [:]][row["role"]] = target
        }
        var roots: [ObjectAddress: (SnapshotRoot, ObjectAddress)] = [:]
        var rootTargets: [ObjectAddress: [String: ObjectAddress]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_roots") {
            guard let namespace = UUID(uuidString: row["namespace"]), let sourceNamespace = UUID(uuidString: row["source_namespace"])
            else { throw BusinessStoreError.corruptedStorage }
            let address = ObjectAddress(namespace: namespace, identity: .init(id: row["root_id"], version: row["root_version"]))
            let source = ObjectAddress(namespace: sourceNamespace, identity: .init(id: row["source_root_id"], version: row["source_root_version"]))
            let json: Data = row["root_json"], hash: String = row["content_hash"]
            let root = try decode(SnapshotRoot.self, from: json)
            guard try root.contentHash() == hash else { throw BusinessStoreError.corruptedStorage }
            roots[address] = (root, source)
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_root_edges") {
            guard let namespace = UUID(uuidString: row["namespace"]), let targetNamespace = UUID(uuidString: row["target_namespace"])
            else { throw BusinessStoreError.corruptedStorage }
            let source = ObjectAddress(namespace: namespace, identity: .init(id: row["root_id"], version: row["root_version"]))
            let target = ObjectAddress(namespace: targetNamespace, identity: .init(id: row["target_id"], version: row["target_version"]))
            guard roots[source] != nil, objects[target] != nil else { throw BusinessStoreError.corruptedStorage }
            rootTargets[source, default: [:]][row["role"]] = target
        }
        let graph = SnapshotGraph(
            objects: Dictionary(uniqueKeysWithValues: objects.map { ($0.key, PersistedObject(object: $0.value.0, source: $0.value.1, targets: objectTargets[$0.key] ?? [:])) }),
            roots: Dictionary(uniqueKeysWithValues: roots.map { ($0.key, PersistedRoot(root: $0.value.0, source: $0.value.1, targets: rootTargets[$0.key] ?? [:])) }))
        try validate(graph)
        return graph
    }

    private static func validate(_ graph: SnapshotGraph) throws {
        for (address, stored) in graph.objects {
            try address.identity.validate(); try stored.source.identity.validate(); try stored.object.validate()
            guard address.identity == stored.object.identity,
                  Set(stored.object.references.map(\.role)) == Set(stored.targets.keys),
                  stored.object.references.count == stored.targets.count else { throw BusinessStoreError.corruptedStorage }
            for reference in stored.object.references {
                guard let target = stored.targets[reference.role], let object = graph.objects[target],
                      try object.object.contentHash() == reference.contentHash else { throw BusinessStoreError.corruptedStorage }
            }
        }
        for (address, stored) in graph.roots {
            try address.identity.validate(); try stored.source.identity.validate(); try stored.root.identity.validate()
            guard address.identity == stored.root.identity, !stored.root.references.isEmpty,
                  Set(stored.root.references.map(\.role)) == Set(stored.targets.keys),
                  stored.root.references.count == stored.targets.count else { throw BusinessStoreError.corruptedStorage }
            for reference in stored.root.references {
                guard let target = stored.targets[reference.role], let object = graph.objects[target],
                      try object.object.contentHash() == reference.contentHash else { throw BusinessStoreError.corruptedStorage }
            }
        }
    }

    private static func save(_ graph: SnapshotGraph, revision: UUID, db: Database) throws {
        try db.execute(sql: "DELETE FROM p1_snapshot_root_edges")
        try db.execute(sql: "DELETE FROM p1_snapshot_object_edges")
        try db.execute(sql: "DELETE FROM p1_snapshot_roots")
        try db.execute(sql: "DELETE FROM p1_snapshot_objects")
        for address in graph.objects.keys.sorted(by: { addressKey($0) < addressKey($1) }) {
            let stored = graph.objects[address]!, bytes = try stored.object.contentBytes(), hash = digest(bytes)
            try db.execute(sql: """
                INSERT INTO p1_snapshot_objects
                (namespace, object_id, object_version, source_namespace, source_object_id, source_object_version,
                 content_hash, object_json, content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [address.namespace.uuidString.lowercased(), address.identity.id, address.identity.version,
                                  stored.source.namespace.uuidString.lowercased(), stored.source.identity.id, stored.source.identity.version,
                                  hash, try encode(stored.object), bytes])
        }
        for address in graph.roots.keys.sorted(by: { addressKey($0) < addressKey($1) }) {
            let stored = graph.roots[address]!
            try db.execute(sql: """
                INSERT INTO p1_snapshot_roots
                (namespace, root_id, root_version, source_namespace, source_root_id, source_root_version,
                 content_hash, root_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [address.namespace.uuidString.lowercased(), address.identity.id, address.identity.version,
                                  stored.source.namespace.uuidString.lowercased(), stored.source.identity.id, stored.source.identity.version,
                                  try stored.root.contentHash(), try encode(stored.root)])
        }
        for address in graph.objects.keys.sorted(by: { addressKey($0) < addressKey($1) }) {
            for role in graph.objects[address]!.targets.keys.sorted() {
                let target = graph.objects[address]!.targets[role]!
                try db.execute(sql: """
                    INSERT INTO p1_snapshot_object_edges
                    (namespace, object_id, object_version, role, target_namespace, target_id, target_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [address.namespace.uuidString.lowercased(), address.identity.id, address.identity.version,
                                      role, target.namespace.uuidString.lowercased(), target.identity.id, target.identity.version])
            }
        }
        for address in graph.roots.keys.sorted(by: { addressKey($0) < addressKey($1) }) {
            for role in graph.roots[address]!.targets.keys.sorted() {
                let target = graph.roots[address]!.targets[role]!
                try db.execute(sql: """
                    INSERT INTO p1_snapshot_root_edges
                    (namespace, root_id, root_version, role, target_namespace, target_id, target_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [address.namespace.uuidString.lowercased(), address.identity.id, address.identity.version,
                                      role, target.namespace.uuidString.lowercased(), target.identity.id, target.identity.version])
            }
        }
        try writeRevision(revision, db: db)
    }
}

private func nonempty(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
private func storageIdentifier(_ value: String) -> Bool {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*\z"#, options: .regularExpression) != nil
        && components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
}
private func localReference(_ value: String) -> Bool {
    storageIdentifier(value) && !value.contains(":") && !value.contains("@") && !value.contains("?")
}
