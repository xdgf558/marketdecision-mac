import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

private func storageVersion(_ document: SECResearchDocument, id: UUID = UUID()) throws -> SECResearchDocument {
    var json = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(document)) as? [String: Any])
    json["id"] = id.uuidString
    return try JSONDecoder().decode(SECResearchDocument.self, from: JSONSerialization.data(withJSONObject: json))
}

private func legacyBundle(_ document: SECResearchDocument) throws -> SnapshotBundle {
    let bytes = try ResearchDocument.encoded(document)
    let identity = ObjectIdentity(id: document.id.uuidString.lowercased(), version: "sec-research.v1")
    let object = FrozenObject(identity: identity, kind: .result, payload: .string(bytes.base64EncodedString()),
        references: [], capturedAt: try MillisecondInstant(rounding: document.cutoff),
        permission: .init(mayStore: true, mayBackup: false, evidenceReference: "sec-research.local-only.v1"), synthetic: false)
    let root = SnapshotRoot(identity: identity, kind: .analysisRun,
        references: [.init(role: "sec-research", target: identity, contentHash: try object.contentHash())])
    return SnapshotBundle(sourceNamespace: document.id, objects: [object], roots: [root])
}

private func legacyBytes(_ database: DatabaseStore) throws -> [Data] {
    try database.read { db in
        try Data.fetchAll(db, sql: "SELECT object_json FROM p1_snapshot_objects ORDER BY namespace")
        + Data.fetchAll(db, sql: "SELECT content FROM p1_snapshot_objects ORDER BY namespace")
        + Data.fetchAll(db, sql: "SELECT root_json FROM p1_snapshot_roots ORDER BY namespace")
    }
}

@Suite struct SECResearchStorageTests {
    @Test func storesOneExactDocumentBlobAndReopensWithoutFrozenBase64Copies() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .secResearch)
        let store = try SECResearchStore(database: database)
        let original = try await secResearchFixtureDocument()
        let document = try SECResearchDocument(ticker: original.ticker, cutoff: original.cutoff.addingTimeInterval(0.0004),
            identity: original.identity, submissions: original.submissions, facts: original.facts,
            indexes: original.indexes, filingDocuments: original.filingDocuments, sources: original.sources)
        try await store.save(document, expectedRevision: store.writeRevision())
        #expect(try await store.savedResearch() == [.init(document: document)])
        let bytes = try ResearchDocument.encoded(document)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == bytes)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_snapshot_objects") } == 0)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 0)
        let summarySize = try database.read { try Int.fetchOne($0, sql: "SELECT length(summary_json) FROM sec_research_catalog") }
        #expect(try #require(summarySize) < 1_024)
        let reopened = try SECResearchStore(path: path.path)
        let restored = try await reopened.open(id: document.id)
        #expect(try ResearchDocument.encoded(restored) == bytes)
        #expect(restored.cutoff == document.cutoff)
        #expect(restored.sources == document.sources)
        #expect(try restored.recompute() == document.normalization)
        #expect(throws: MigrationError.incompatiblePurpose) { try DatabaseStore(path: path.path) }
        #expect(throws: MigrationError.incompatiblePurpose) { try OfflineIssuerResearchStore(path: path.path) }
    }

    @Test func listAndSelectedOpenAvoidUnrelatedBodiesAndSaveNeverUpdatesExistingVersions() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let store = try SECResearchStore(database: database)
        let original = try await secResearchFixtureDocument()
        var ids: [UUID] = []
        for _ in 0..<24 {
            let document = try storageVersion(original)
            try await store.save(document, expectedRevision: store.writeRevision())
            ids.append(document.id)
        }
        let broken = ids[0], healthy = ids[1]
        try database.transaction { db in
            try db.execute(sql: "UPDATE sec_research_documents SET document_json = ? WHERE document_id = ?",
                           arguments: [Data("damaged-unrelated-body".utf8), broken.uuidString.lowercased()])
            // Any old whole-graph rewrite, update or delete would make the new save fail.
            for table in ["sec_research_documents", "sec_research_catalog", "p1_snapshot_objects", "p1_snapshot_roots"] {
                for operation in ["UPDATE", "DELETE"] {
                    try db.execute(sql: "CREATE TRIGGER no_\(operation)_\(table) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'immutable'); END")
                }
            }
        }
        // A catalog is not a full-database integrity claim. Only opening B rejects B's body.
        #expect(try await store.savedResearch().count == 24)
        #expect(try await store.open(id: healthy).id == healthy)
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.open(id: broken) }
        let added = try storageVersion(original)
        try await store.save(added, expectedRevision: store.writeRevision())
        #expect(try await store.savedResearch().count == 25)
        #expect(try await store.open(id: added.id).id == added.id)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents WHERE document_id = ?",
            arguments: [broken.uuidString.lowercased()]) } == Data("damaged-unrelated-body".utf8))
    }

    @Test func selectedBlobRejectsConflictingOrphanLegacyObjectUnderSameID() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let store = try SECResearchStore(database: database), document = try await secResearchFixtureDocument()
        try await store.save(document, expectedRevision: store.writeRevision())
        let object = try #require(legacyBundle(document).objects.first), id = document.id.uuidString.lowercased()
        try database.transaction { db in
            try db.execute(sql: """
                INSERT INTO p1_snapshot_objects(namespace, object_id, object_version, source_namespace,
                    source_object_id, source_object_version, content_hash, object_json, content)
                VALUES (?, ?, 'sec-research.v1', ?, ?, 'sec-research.v1', ?, ?, ?)
                """, arguments: [id, id, id, id, try object.contentHash(),
                    try ResearchDocument.encoded(object), try object.contentBytes()])
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedResearch() }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.open(id: document.id) }
    }

    @Test func catalogDigestColumnsAndSummaryMustAgreeWithSelectedDocument() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let store = try SECResearchStore(database: database)
        let document = try await secResearchFixtureDocument()
        try await store.save(document, expectedRevision: store.writeRevision())
        let original = try #require(database.read { try Data.fetchOne($0, sql: "SELECT summary_json FROM sec_research_catalog") })
        try database.transaction { db in try db.execute(sql: "UPDATE sec_research_catalog SET summary_hash = ?", arguments: [String(repeating: "a", count: 64)]) }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedResearch() }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.open(id: document.id) }
        try database.transaction { db in try db.execute(sql: "UPDATE sec_research_catalog SET summary_hash = ?", arguments: [digest(original)]) }
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var summary = try #require(json["summary"] as? [String: Any])
        summary["factCount"] = document.facts.count + 1; json["summary"] = summary
        let changed = try JSONSerialization.data(withJSONObject: json)
        try database.transaction { db in try db.execute(sql: "UPDATE sec_research_catalog SET summary_json = ?, summary_hash = ?", arguments: [changed, digest(changed)]) }
        // The list can authenticate only its small envelope. Full binding is checked at open.
        #expect(try await store.savedResearch().first?.factCount == document.facts.count + 1)
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.open(id: document.id) }
        try database.transaction { db in try db.execute(sql: "UPDATE sec_research_catalog SET summary_json = ?, summary_hash = ?, document_hash = ?",
            arguments: [original, digest(original), String(repeating: "b", count: 64)]) }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedResearch() }
    }

    @Test func duplicateIDAndStaleCrossConnectionWritesPreserveImmutableBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let first = try SECResearchStore(path: path.path), second = try SECResearchStore(path: path.path)
        let original = try await secResearchFixtureDocument(), competing = try storageVersion(original)
        let baseline = try await first.writeRevision()
        #expect(try await second.writeRevision() == baseline)
        try await first.save(original, expectedRevision: baseline)
        let committed = try await first.writeRevision()
        await #expect(throws: SnapshotError.stalePlan) { try await second.save(competing, expectedRevision: baseline) }
        await #expect(throws: SnapshotError.duplicateObject) { try await second.save(original, expectedRevision: committed) }
        #expect(try await second.writeRevision() == committed)
        #expect(try await first.savedResearch() == [.init(document: original)])
        #expect(try ResearchDocument.encoded(await second.open(id: original.id)) == ResearchDocument.encoded(original))
    }

    @Test func concurrentActorsSharingOneBaselineAllowOnlyOneImmutableCommit() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let first = try SECResearchStore(database: database), second = try SECResearchStore(database: database)
        let original = try await secResearchFixtureDocument(), competing = try storageVersion(original)
        let baseline = try await first.writeRevision()
        func attempt(_ target: SECResearchStore, _ document: SECResearchDocument) async throws -> Bool {
            do { try await target.save(document, expectedRevision: baseline); return true }
            catch SnapshotError.stalePlan { return false }
        }
        async let a = attempt(first, original)
        async let b = attempt(second, competing)
        let results = try await [a, b]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await first.savedResearch().count == 1)
        #expect(try await second.writeRevision() == first.writeRevision())
    }

    @Test func transactionFailureAfterBlobInsertRollsBackCatalogBlobAndRevisionThenRetries() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let store = try SECResearchStore(database: database)
        let document = try await secResearchFixtureDocument(), before = try await store.writeRevision()
        try database.transaction { db in
            try db.execute(sql: "CREATE TRIGGER reject_revision BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        await #expect(throws: (any Error).self) { try await store.save(document, expectedRevision: before) }
        #expect(try await store.writeRevision() == before)
        #expect(try await store.savedResearch().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_documents") } == 0)
        try database.transaction { db in try db.execute(sql: "DROP TRIGGER reject_revision") }
        try await store.save(document, expectedRevision: before)
        #expect(try await store.savedResearch() == [.init(document: document)])
    }

    @Test func additiveMigrationKeepsPR42BytesAndIndexesLegacyOneAtATimeWithoutRevisionChange() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .secResearch)
        let store = try SECResearchStore(database: database)
        let original = try await secResearchFixtureDocument()
        let older = try storageVersion(original, id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let newer = try storageVersion(original, id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        try await store.business.freeze(legacyBundle(older), expectedRevision: store.writeRevision())
        try await store.business.freeze(legacyBundle(newer), expectedRevision: store.writeRevision())
        let before = try legacyBytes(database), revision = try await store.writeRevision()
        // Produce precisely the old migration history and old graph layout before reopen.
        try database.transaction { db in
            try db.execute(sql: "DROP INDEX sec_research_legacy_object_metadata")
            try db.execute(sql: "DROP TABLE sec_research_documents")
            try db.execute(sql: "DROP TABLE sec_research_catalog")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('sec-research.storage.v1', 'sec-research.storage.v2')")
        }
        let reopened = try SECResearchStore(path: path.path)
        #expect(try await reopened.open(id: older.id).id == older.id)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_catalog") } == 0)
        #expect(try await reopened.savedResearch().map(\.id) == [older.id, newer.id])
        #expect(try await reopened.writeRevision() == revision)
        #expect(try legacyBytes(database) == before)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_documents") } == 0)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_catalog WHERE storage_kind = 'legacy'") } == 2)
        let added = try storageVersion(original)
        try await reopened.save(added, expectedRevision: revision)
        #expect(try legacyBytes(database) == before)
        #expect(try await reopened.savedResearch().count == 3)
        #expect(try await reopened.open(id: newer.id).sources == newer.sources)
    }

    @Test func v2IndexMigrationPreservesV1BodiesAndForcesCoveringMetadataPlans() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .secResearch)
        let store = try SECResearchStore(database: database)
        let document = try await secResearchFixtureDocument(), legacy = try storageVersion(document)
        try await store.save(document, expectedRevision: store.writeRevision())
        try await store.business.freeze(legacyBundle(legacy), expectedRevision: store.writeRevision())
        _ = try await store.savedResearch()
        let oldGraph = try legacyBytes(database), revision = try await store.writeRevision()
        let blob = try #require(database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") })
        let catalog = try database.read { try Data.fetchAll($0, sql: "SELECT summary_json FROM sec_research_catalog ORDER BY document_id") }
        try database.transaction { db in
            // Reproduce an already populated candidate storage.v1 database.
            try db.execute(sql: "DROP INDEX sec_research_document_ids")
            try db.execute(sql: "DROP INDEX sec_research_legacy_object_metadata")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'sec-research.storage.v2'")
            for table in ["sec_research_documents", "sec_research_catalog", "p1_snapshot_objects", "p1_snapshot_roots"] {
                for operation in ["UPDATE", "DELETE"] {
                    try db.execute(sql: "CREATE TRIGGER preserve_\(operation)_\(table) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'do not rewrite'); END")
                }
            }
        }
        let upgraded = try SECResearchStore(path: path.path)
        #expect(try await upgraded.savedResearch().count == 2)
        #expect(try await upgraded.writeRevision() == revision)
        #expect(try legacyBytes(database) == oldGraph)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == blob)
        #expect(try database.read { try Data.fetchAll($0, sql: "SELECT summary_json FROM sec_research_catalog ORDER BY document_id") } == catalog)
        let details = try database.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + SECResearchStorage.catalogShapeQuery).map { row -> String in row["detail"] }
        }
        #expect(details.filter { $0.contains("COVERING INDEX sec_research_document_ids") }.count == 3)
        #expect(details.filter { $0.contains("COVERING INDEX sec_research_legacy_object_metadata") }.count == 2)
        #expect(!details.contains { $0.contains("SEARCH d USING PRIMARY KEY") || $0.contains("SEARCH o USING PRIMARY KEY") })
        #expect(try await upgraded.open(id: document.id).id == document.id)
        #expect(try await upgraded.open(id: legacy.id).id == legacy.id)
    }

    @Test func failedLegacyIndexLeavesInvalidEntryUnindexedAndOriginalBytesUntouched() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch), original = try await secResearchFixtureDocument()
        let store = try SECResearchStore(database: database)
        let good = try storageVersion(original, id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let bad = try storageVersion(original, id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        try await store.business.freeze(legacyBundle(good), expectedRevision: store.writeRevision())
        try await store.business.freeze(legacyBundle(bad), expectedRevision: store.writeRevision())
        let oldContent = try #require(database.read { try Data.fetchOne($0, sql: "SELECT content FROM p1_snapshot_objects WHERE namespace = ?", arguments: [bad.id.uuidString.lowercased()]) })
        try database.transaction { db in try db.execute(sql: "UPDATE p1_snapshot_objects SET content = ? WHERE namespace = ?",
            arguments: [Data("damaged-original".utf8), bad.id.uuidString.lowercased()]) }
        let damagedBytes = try legacyBytes(database), revision = try await store.writeRevision()
        #expect(try await store.open(id: good.id).id == good.id)
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedResearch() }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_catalog") } == 1)
        #expect(try legacyBytes(database) == damagedBytes)
        #expect(try await store.writeRevision() == revision)
        try database.transaction { db in try db.execute(sql: "UPDATE p1_snapshot_objects SET content = ? WHERE namespace = ?",
            arguments: [oldContent, bad.id.uuidString.lowercased()]) }
        #expect(try await store.savedResearch().count == 2)
        #expect(try await store.writeRevision() == revision)
    }

    @Test func cancelledSaveAndCancelledLegacyIndexDoNotPersistPartialRows() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch), original = try await secResearchFixtureDocument()
        let store = try SECResearchStore(database: database), baseline = try await store.writeRevision()
        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(original, expectedRevision: baseline)
        }
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(try await store.writeRevision() == baseline)
        #expect(try await store.savedResearch().isEmpty)
        try await store.business.freeze(legacyBundle(original), expectedRevision: baseline)
        let index = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.savedResearch()
        }
        await #expect(throws: CancellationError.self) { try await index.value }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_catalog") } == 0)
        #expect(try await store.savedResearch().count == 1)
    }
}
