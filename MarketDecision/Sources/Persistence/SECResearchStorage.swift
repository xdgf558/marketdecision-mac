import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

/// Lightweight list metadata, never a claim that a document was opened or replayed.
public struct SECResearchSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let ticker: String
    public let companyName: String
    public let cutoff: Date
    public let sourceCount: Int
    public let factCount: Int

    public init(document: SECResearchDocument) {
        id = document.id; ticker = document.ticker; companyName = document.identity.name
        cutoff = document.cutoff; sourceCount = document.sources.count; factCount = document.facts.count
    }

    fileprivate func validate() throws {
        try EquityRecord.validateSymbol(ticker)
        guard cutoff.timeIntervalSinceReferenceDate.isFinite, sourceCount >= 1, sourceCount <= 40,
              factCount >= 0 else { throw BusinessStoreError.corruptedStorage }
    }
}

/// New records have one document JSON BLOB, not duplicate base64 FrozenObject encodings.
/// Legacy graph bytes remain immutable; only a small derived catalog is added on first list.
/// A list validates catalog integrity, while opening a version validates its complete body.
/// Neither operation promises that unrelated bodies or the mutable source cache are healthy.
enum SECResearchStorage {
    private struct Catalog: Codable {
        let summary: SECResearchSummary
        let storageKind: String
        let documentHash: String
    }

    static func insert(_ document: SECResearchDocument, bytes: Data, db: Database) throws {
        let id = document.id.uuidString.lowercased()
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_research_catalog WHERE document_id = ?", arguments: [id]) == 0,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_roots WHERE namespace = ?", arguments: [id]) == 0,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_objects INDEXED BY sec_research_legacy_object_metadata WHERE namespace = ?", arguments: [id]) == 0
        else { throw SnapshotError.duplicateObject }
        try insertCatalog(document, hash: digest(bytes), kind: "blob", db: db)
        try db.execute(sql: "INSERT INTO sec_research_documents(document_id, document_json) VALUES (?, ?)", arguments: [id, bytes])
    }

    private static func insertCatalog(_ document: SECResearchDocument, hash: String, kind: String, db: Database) throws {
        let catalog = Catalog(summary: .init(document: document), storageKind: kind, documentHash: hash)
        let bytes = try ResearchDocument.encoded(catalog)
        try db.execute(sql: """
            INSERT INTO sec_research_catalog(document_id, storage_kind, document_hash, summary_hash, summary_json)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [document.id.uuidString.lowercased(), kind, hash, digest(bytes), bytes])
    }

    /// Index each unindexed legacy record in its own transaction. Cancellation/corruption
    /// rolls back that entry; already verified summaries may remain. Business revision is
    /// unchanged because the source record and every original byte remain unchanged.
    static func indexLegacyDocuments(_ database: DatabaseStore) throws {
        let pending = try database.read { db in
            try validateCatalogShape(db)
            return try String.fetchAll(db, sql: """
                SELECT r.namespace FROM p1_snapshot_roots r
                LEFT JOIN sec_research_catalog c ON c.document_id = r.namespace
                WHERE c.document_id IS NULL ORDER BY r.namespace
                """)
        }
        for text in pending {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
            try database.transaction { db in
                // Another connection may have indexed this version since the inventory read.
                if let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE document_id = ?", arguments: [text]) {
                    _ = try decodeCatalog(row); return
                }
                let (document, bytes) = try legacyDocument(id: id, db: db)
                try Task.checkCancellation()
                try insertCatalog(document, hash: digest(bytes), kind: "legacy", db: db)
            }
        }
    }

    private static let catalogQuery = "SELECT document_id, storage_kind, document_hash, summary_hash, summary_json FROM sec_research_catalog"

    static func summaries(_ db: Database) throws -> [SECResearchSummary] {
        try validateCatalogShape(db)
        var result: [SECResearchSummary] = []
        let rows = try Row.fetchCursor(db, sql: catalogQuery)
        while let row = try rows.next() {
            try Task.checkCancellation()
            result.append(try decodeCatalog(row).summary)
        }
        return result.sorted { $0.cutoff == $1.cutoff ? $0.id.uuidString < $1.id.uuidString : $0.cutoff > $1.cutoff }
    }

    static func open(id: UUID, db: Database) throws -> SECResearchDocument {
        try validatedRecord(id: id, db: db).document
    }

    /// Returns the exact retained encoding as well as the validated document. A financial
    /// report binds these original bytes, never a potentially different re-encoding.
    static func validatedRecord(id: UUID, db: Database) throws -> (document: SECResearchDocument, bytes: Data) {
        let text = id.uuidString.lowercased()
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE document_id = ?", arguments: [text]) else {
            // Opening one pre-catalog record does not force unrelated legacy migration.
            return try legacyDocument(id: id, db: db)
        }
        let catalog = try decodeCatalog(row)
        let document: SECResearchDocument, bytes: Data
        switch catalog.storageKind {
        case "blob":
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_roots WHERE namespace = ?", arguments: [text]) == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_objects INDEXED BY sec_research_legacy_object_metadata WHERE namespace = ?", arguments: [text]) == 0,
                  let stored = try Data.fetchOne(db, sql: "SELECT document_json FROM sec_research_documents WHERE document_id = ?", arguments: [text])
            else { throw BusinessStoreError.corruptedStorage }
            bytes = stored
            guard digest(bytes) == catalog.documentHash else { throw BusinessStoreError.corruptedStorage }
            document = try decodeDocument(bytes)
        case "legacy":
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_research_documents INDEXED BY sec_research_document_ids WHERE document_id = ?", arguments: [text]) == 0
            else { throw BusinessStoreError.corruptedStorage }
            (document, bytes) = try legacyDocument(id: id, db: db)
        default: throw BusinessStoreError.corruptedStorage
        }
        try Task.checkCancellation()
        guard document.id == id, digest(bytes) == catalog.documentHash,
              SECResearchSummary(document: document) == catalog.summary else { throw BusinessStoreError.corruptedStorage }
        return (document, bytes)
    }

    /// Index only the selected legacy parent, inside the caller's transaction. Frozen
    /// document bytes and business revision are unchanged by this derived metadata.
    static func ensureCatalog(document: SECResearchDocument, bytes: Data, db: Database) throws {
        let text = document.id.uuidString.lowercased()
        if let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE document_id = ?", arguments: [text]) {
            let catalog = try decodeCatalog(row)
            guard catalog.documentHash == digest(bytes), catalog.summary == SECResearchSummary(document: document)
            else { throw BusinessStoreError.corruptedStorage }
        } else {
            let original = try legacyDocument(id: document.id, db: db)
            guard original.1 == bytes else { throw BusinessStoreError.corruptedStorage }
            try insertCatalog(document, hash: digest(bytes), kind: "legacy", db: db)
        }
    }

    private static func decodeCatalog(_ row: Row) throws -> Catalog {
        let bytes: Data = row["summary_json"]
        guard digest(bytes) == row["summary_hash"] else { throw BusinessStoreError.corruptedStorage }
        let result: Catalog
        do { result = try JSONDecoder().decode(Catalog.self, from: bytes) }
        catch { throw BusinessStoreError.corruptedStorage }
        try result.summary.validate()
        guard result.summary.id.uuidString.lowercased() == row["document_id"],
              result.storageKind == row["storage_kind"], ["legacy", "blob"].contains(result.storageKind),
              result.documentHash == row["document_hash"],
              result.documentHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw BusinessStoreError.corruptedStorage }
        return result
    }

    private static func decodeDocument(_ bytes: Data) throws -> SECResearchDocument {
        do {
            let result = try JSONDecoder().decode(SECResearchDocument.self, from: bytes)
            try result.validate()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw BusinessStoreError.corruptedStorage }
    }

    /// Metadata-only shape checks prevent missing/orphan index entries from silently
    /// disappearing. No document_json/object_json/content column is read by this path.
    private static func validateCatalogShape(_ db: Database) throws {
        let invalid = try Int.fetchOne(db, sql: catalogShapeQuery)
        guard invalid == 0 else { throw BusinessStoreError.corruptedStorage }
    }

    // INDEXED BY is intentional: SQLite otherwise prefers a WITHOUT ROWID primary
    // key lookup, which may copy a complete large BLOB merely to compare its key.
    // Keep this query available to the storage-plan regression, not to app callers.
    static let catalogShapeQuery = """
            SELECT
            (SELECT COUNT(*) FROM sec_research_catalog c WHERE
                (c.storage_kind = 'blob' AND (NOT EXISTS (SELECT 1 FROM sec_research_documents d INDEXED BY sec_research_document_ids WHERE d.document_id = c.document_id)
                    OR EXISTS (SELECT 1 FROM p1_snapshot_roots r WHERE r.namespace = c.document_id)))
                OR (c.storage_kind = 'legacy' AND (NOT EXISTS (SELECT 1 FROM p1_snapshot_roots r WHERE r.namespace = c.document_id)
                    OR EXISTS (SELECT 1 FROM sec_research_documents d INDEXED BY sec_research_document_ids WHERE d.document_id = c.document_id))))
            + (SELECT COUNT(*) FROM sec_research_documents d INDEXED BY sec_research_document_ids WHERE NOT EXISTS
                (SELECT 1 FROM sec_research_catalog c WHERE c.document_id = d.document_id AND c.storage_kind = 'blob'))
            + (SELECT COUNT(*) FROM p1_snapshot_object_edges)
            + (SELECT COUNT(*) FROM p1_snapshot_roots r WHERE
                r.root_id != r.namespace OR r.root_version != 'sec-research.v1' OR r.source_namespace != r.namespace
                OR r.source_root_id != r.root_id OR r.source_root_version != r.root_version
                OR NOT EXISTS (SELECT 1 FROM p1_snapshot_objects o INDEXED BY sec_research_legacy_object_metadata WHERE o.namespace = r.namespace AND o.object_id = r.root_id
                    AND o.object_version = r.root_version AND o.source_namespace = o.namespace
                    AND o.source_object_id = o.object_id AND o.source_object_version = o.object_version))
            + (SELECT COUNT(*) FROM p1_snapshot_objects o INDEXED BY sec_research_legacy_object_metadata WHERE NOT EXISTS
                (SELECT 1 FROM p1_snapshot_roots r WHERE r.namespace = o.namespace AND r.root_id = o.object_id AND r.root_version = o.object_version))
            + (SELECT COUNT(*) FROM p1_snapshot_root_edges e WHERE e.role != 'sec-research' OR e.target_namespace != e.namespace
                OR e.target_id != e.root_id OR e.target_version != e.root_version)
            + ABS((SELECT COUNT(*) FROM p1_snapshot_roots) - (SELECT COUNT(*) FROM p1_snapshot_root_edges))
            """

    private static func legacyDocument(id: UUID, db: Database) throws -> (SECResearchDocument, Data) {
        let text = id.uuidString.lowercased()
        let roots = try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_roots WHERE namespace = ?", arguments: [text])
        guard !roots.isEmpty else { throw SnapshotError.missingReference }
        let objects = try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_objects WHERE namespace = ?", arguments: [text])
        let edges = try Row.fetchAll(db, sql: "SELECT * FROM p1_snapshot_root_edges WHERE namespace = ?", arguments: [text])
        guard roots.count == 1, objects.count == 1, edges.count == 1,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_snapshot_object_edges WHERE namespace = ?", arguments: [text]) == 0
        else { throw BusinessStoreError.corruptedStorage }
        let rootRow = roots[0], objectRow = objects[0], edge = edges[0]
        let object: FrozenObject, root: SnapshotRoot
        do {
            object = try JSONDecoder().decode(FrozenObject.self, from: objectRow["object_json"])
            root = try JSONDecoder().decode(SnapshotRoot.self, from: rootRow["root_json"])
        } catch { throw BusinessStoreError.corruptedStorage }
        let identity = ObjectIdentity(id: text, version: "sec-research.v1")
        let content: Data = objectRow["content"]
        guard object.identity == identity, root.identity == identity,
              objectRow["object_id"] == text, objectRow["object_version"] == identity.version,
              objectRow["source_namespace"] == text, objectRow["source_object_id"] == text, objectRow["source_object_version"] == identity.version,
              rootRow["root_id"] == text, rootRow["root_version"] == identity.version,
              rootRow["source_namespace"] == text, rootRow["source_root_id"] == text, rootRow["source_root_version"] == identity.version,
              edge["root_id"] == text, edge["root_version"] == identity.version, edge["role"] == "sec-research",
              edge["target_namespace"] == text, edge["target_id"] == text, edge["target_version"] == identity.version,
              try object.contentBytes() == content, digest(content) == objectRow["content_hash"],
              try root.contentHash() == rootRow["content_hash"], root.kind == .analysisRun, root.references.count == 1,
              root.references[0].role == "sec-research", root.references[0].target == identity,
              root.references[0].contentHash == digest(content), object.kind == .result, object.references.isEmpty,
              !object.synthetic, object.permission.mayStore, !object.permission.mayBackup,
              object.permission.evidenceReference == "sec-research.local-only.v1",
              case let .string(encoded) = object.payload, let bytes = Data(base64Encoded: encoded)
        else { throw BusinessStoreError.corruptedStorage }
        let document = try decodeDocument(bytes)
        guard document.id == id, object.capturedAt == (try MillisecondInstant(rounding: document.cutoff)) else {
            throw BusinessStoreError.corruptedStorage
        }
        try Task.checkCancellation()
        return (document, bytes)
    }
}
