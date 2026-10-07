import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

private func financialStorageParentVersion(_ parent: SECResearchDocument) throws -> SECResearchDocument {
    var json = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(parent)) as? [String: Any])
    json["id"] = UUID().uuidString
    return try JSONDecoder().decode(SECResearchDocument.self, from: JSONSerialization.data(withJSONObject: json))
}

private func financialStorageReportVersion(_ report: SECFinancialReportDocument) throws -> SECFinancialReportDocument {
    var json = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(report)) as? [String: Any])
    json["id"] = UUID().uuidString
    return try JSONDecoder().decode(SECFinancialReportDocument.self, from: JSONSerialization.data(withJSONObject: json))
}

private func financialLegacyBundle(_ parent: SECResearchDocument, bytes: Data) throws -> SnapshotBundle {
    let identity = ObjectIdentity(id: parent.id.uuidString.lowercased(), version: "sec-research.v1")
    let object = FrozenObject(identity: identity, kind: .result, payload: .string(bytes.base64EncodedString()), references: [],
        capturedAt: try MillisecondInstant(rounding: parent.cutoff),
        permission: .init(mayStore: true, mayBackup: false, evidenceReference: "sec-research.local-only.v1"), synthetic: false)
    let root = SnapshotRoot(identity: identity, kind: .analysisRun,
        references: [.init(role: "sec-research", target: identity, contentHash: try object.contentHash())])
    return SnapshotBundle(sourceNamespace: parent.id, objects: [object], roots: [root])
}

private func financialStorageFixture(path: String = ":memory:") async throws
    -> (DatabaseStore, SECResearchStore, SECResearchDocument, SECFinancialReportDocument) {
    let database = try DatabaseStore(path: path, purpose: .secResearch)
    let store = try SECResearchStore(database: database)
    let parent = try await secFinancialReportFixtureParent()
    try await store.save(parent, expectedRevision: store.writeRevision())
    let report = try await SECFinancialReportDocument.make(parent: parent, parentBytes: ResearchDocument.encoded(parent),
        executionDate: parent.cutoff.addingTimeInterval(10))
    return (database, store, parent, report)
}

@Suite struct SECFinancialReportStorageTests {
    @Test func sidecarRoundTripKeepsExactParentOnceAndReopensThroughFullBinding() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let (database, store, parent, report) = try await financialStorageFixture(path: path.path)
        let parentBytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") })
        try await store.saveFinancialReport(report, expectedRevision: store.reportWriteRevision())
        #expect(try await store.savedFinancialReports(parentID: parent.id) == [.init(document: report)])
        #expect(try await store.savedFinancialReports(parentID: UUID()).isEmpty)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == parentBytes)
        let bytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") })
        #expect(bytes == (try ResearchDocument.encoded(report)))
        #expect(report.parentDocumentHash == digest(parentBytes))
        for source in parent.sources where source.bytes.count > 100 {
            #expect(bytes.range(of: Data(source.bytes.base64EncodedString().utf8)) == nil)
        }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_documents") } == 1)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 0)
        let reopened = try SECResearchStore(path: path.path)
        let opened = try await reopened.openFinancialReport(id: report.id)
        #expect(try ResearchDocument.encoded(opened) == bytes)
        try opened.validate(parent: parent, parentBytes: parentBytes)
        let recomputed = try await opened.financials.recompute()
        #expect(try opened.financials.cachedReportsMatch(recomputed))
        #expect(throws: MigrationError.incompatiblePurpose) { try DatabaseStore(path: path.path) }
        #expect(throws: MigrationError.incompatiblePurpose) { try OfflineIssuerResearchStore(path: path.path) }
    }

    @Test func draftRevisionCannotBeRetargetedAfterAnotherWriteAndDuplicateIDCannotOverwrite() async throws {
        let (_, store, parent, report) = try await financialStorageFixture()
        let baseline = try await store.reportWriteRevision()
        let competingParent = try financialStorageParentVersion(parent)
        try await store.save(competingParent, expectedRevision: baseline)
        await #expect(throws: SnapshotError.stalePlan) { try await store.saveFinancialReport(report, expectedRevision: baseline) }
        #expect(try await store.savedFinancialReports().isEmpty)
        let current = try await store.reportWriteRevision()
        try await store.saveFinancialReport(report, expectedRevision: current)
        let committed = try await store.reportWriteRevision()
        await #expect(throws: SnapshotError.duplicateObject) { try await store.saveFinancialReport(report, expectedRevision: committed) }
        #expect(try await store.reportWriteRevision() == committed)
        #expect(try await store.savedFinancialReports().count == 1)
    }

    @Test func catalogListsAndSelectedOpenDoNotReadOtherReportBodies() async throws {
        let (database, store, _, report) = try await financialStorageFixture()
        try await store.saveFinancialReport(report, expectedRevision: store.reportWriteRevision())
        let healthy = try financialStorageReportVersion(report)
        try await store.saveFinancialReport(healthy, expectedRevision: store.reportWriteRevision())
        try database.transaction { db in
            try db.execute(sql: "UPDATE sec_financial_report_documents SET report_json = ? WHERE report_id = ?",
                arguments: [Data("damaged-other-report".utf8), report.id.uuidString.lowercased()])
            for table in ["sec_financial_report_catalog", "sec_financial_report_documents", "sec_research_documents"] {
                for operation in ["UPDATE", "DELETE"] {
                    try db.execute(sql: "CREATE TRIGGER keep_\(operation)_\(table) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'immutable'); END")
                }
            }
        }
        #expect(try await store.savedFinancialReports().count == 2)
        #expect(try await store.openFinancialReport(id: healthy.id).id == healthy.id)
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openFinancialReport(id: report.id) }
        let additional = try financialStorageReportVersion(report)
        try await store.saveFinancialReport(additional, expectedRevision: store.reportWriteRevision())
        #expect(try await store.savedFinancialReports().count == 3)
    }

    @Test func changedParentBytesAreRejectedEvenWhenReportBytesAndMetadataStillMatch() async throws {
        let (database, store, parent, report) = try await financialStorageFixture()
        try await store.saveFinancialReport(report, expectedRevision: store.reportWriteRevision())
        try database.transaction { db in
            try db.execute(sql: "UPDATE sec_research_documents SET document_json = ? WHERE document_id = ?",
                arguments: [Data("damaged-parent".utf8), parent.id.uuidString.lowercased()])
        }
        // Listing proves only catalog integrity; parent body is verified when opened.
        #expect(try await store.savedFinancialReports(parentID: parent.id).count == 1)
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openFinancialReport(id: report.id) }
        let next = try financialStorageReportVersion(report), baseline = try await store.reportWriteRevision()
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.saveFinancialReport(next, expectedRevision: baseline) }
        #expect(try await store.reportWriteRevision() == baseline)
        #expect(try await store.savedFinancialReports().count == 1)
    }

    @Test func catalogHashColumnsAndSelectedBodySummaryMustAgree() async throws {
        let (database, store, _, report) = try await financialStorageFixture()
        try await store.saveFinancialReport(report, expectedRevision: store.reportWriteRevision())
        let original = try #require(database.read { try Data.fetchOne($0, sql: "SELECT summary_json FROM sec_financial_report_catalog") })
        try database.transaction { db in try db.execute(sql: "UPDATE sec_financial_report_catalog SET summary_hash = ?", arguments: [String(repeating: "a", count: 64)]) }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedFinancialReports() }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openFinancialReport(id: report.id) }
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var summary = try #require(object["summary"] as? [String: Any]); summary["companyName"] = "Wrong selected company"
        object["summary"] = summary
        let changed = try JSONSerialization.data(withJSONObject: object)
        try database.transaction { db in try db.execute(sql: "UPDATE sec_financial_report_catalog SET summary_json = ?, summary_hash = ?", arguments: [changed, digest(changed)]) }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openFinancialReport(id: report.id) }
        try database.transaction { db in try db.execute(sql: "UPDATE sec_financial_report_catalog SET summary_json = ?, summary_hash = ?, parent_document_hash = ?",
            arguments: [original, digest(original), String(repeating: "b", count: 64)]) }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedFinancialReports() }
    }

    @Test func failureAfterSidecarInsertRollsBackThenSameApprovedBaselineCanRetry() async throws {
        let (database, store, _, report) = try await financialStorageFixture()
        let before = try await store.reportWriteRevision()
        try database.transaction { db in
            try db.execute(sql: "CREATE TRIGGER fail_report_revision BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        await #expect(throws: (any Error).self) { try await store.saveFinancialReport(report, expectedRevision: before) }
        #expect(try await store.savedFinancialReports().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_financial_report_documents") } == 0)
        #expect(try await store.reportWriteRevision() == before)
        try database.transaction { db in try db.execute(sql: "DROP TRIGGER fail_report_revision") }
        try await store.saveFinancialReport(report, expectedRevision: before)
        #expect(try await store.savedFinancialReports().count == 1)
    }

    @Test func selectedLegacyParentIsIndexedWithoutReencodingOrReadingDamagedOtherVersion() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch), store = try SECResearchStore(database: database)
        let parent = try await secFinancialReportFixtureParent(), other = try financialStorageParentVersion(parent)
        let json = try JSONSerialization.jsonObject(with: ResearchDocument.encoded(parent))
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        #expect(bytes != (try ResearchDocument.encoded(parent)))
        try await store.business.freeze(financialLegacyBundle(parent, bytes: bytes), expectedRevision: store.writeRevision())
        try await store.business.freeze(financialLegacyBundle(other, bytes: ResearchDocument.encoded(other)), expectedRevision: store.writeRevision())
        let savedOriginals = try database.read { try Data.fetchAll($0, sql: "SELECT object_json FROM p1_snapshot_objects ORDER BY namespace") }
        try database.transaction { db in try db.execute(sql: "UPDATE p1_snapshot_objects SET content = ? WHERE namespace = ?",
            arguments: [Data("damaged-unselected-legacy".utf8), other.id.uuidString.lowercased()]) }
        let report = try await SECFinancialReportDocument.make(parent: parent, parentBytes: bytes, executionDate: parent.cutoff.addingTimeInterval(10))
        let baseline = try await store.reportWriteRevision()
        try database.transaction { db in
            try db.execute(sql: "CREATE TRIGGER fail_legacy_report BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT, 'synthetic rollback'); END")
        }
        await #expect(throws: (any Error).self) { try await store.saveFinancialReport(report, expectedRevision: baseline) }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_catalog") } == 0)
        #expect(try await store.savedFinancialReports().isEmpty)
        #expect(try await store.reportWriteRevision() == baseline)
        try database.transaction { db in try db.execute(sql: "DROP TRIGGER fail_legacy_report") }
        try await store.saveFinancialReport(report, expectedRevision: baseline)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_catalog") } == 1)
        #expect(try database.read { try String.fetchOne($0, sql: "SELECT document_hash FROM sec_research_catalog") } == digest(bytes))
        #expect(try database.read { try Data.fetchAll($0, sql: "SELECT object_json FROM p1_snapshot_objects ORDER BY namespace") } == savedOriginals)
        #expect(try await store.openFinancialReport(id: report.id).parentDocumentHash == digest(bytes))
        #expect(try await store.savedFinancialReports().count == 1)
        #expect(throws: (any Error).self) {
            try database.transaction { db in try db.execute(sql: "DELETE FROM sec_research_catalog WHERE document_id = ?", arguments: [parent.id.uuidString.lowercased()]) }
        }
    }

    @Test func v3UpgradePreservesExistingParentBytesAndUsesLightweightBodyIDIndex() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let (database, store, parent, report) = try await financialStorageFixture(path: path.path)
        let before = try await store.reportWriteRevision()
        let bytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") })
        try database.transaction { db in
            try db.execute(sql: "DROP TABLE sec_financial_report_documents")
            try db.execute(sql: "DROP TABLE sec_financial_report_catalog")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'sec-research.storage.v3'")
            for table in ["sec_research_documents", "sec_research_catalog"] {
                for operation in ["UPDATE", "DELETE"] {
                    try db.execute(sql: "CREATE TRIGGER no_\(operation)_\(table) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'preserve'); END")
                }
            }
        }
        let reopened = try SECResearchStore(path: path.path)
        #expect(try await reopened.reportWriteRevision() == before)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == bytes)
        #expect(try await reopened.open(id: parent.id).id == parent.id)
        try await reopened.saveFinancialReport(report, expectedRevision: before)
        let details = try database.read { db in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + SECFinancialReportStorage.catalogQuery).map { row -> String in row["detail"] } }
        #expect(details.contains { $0.contains("COVERING INDEX sqlite_autoindex_sec_financial_report_documents_") })
        #expect(try await reopened.savedFinancialReports().count == 1)
    }

    @Test func cancelledAndConcurrentSidecarSavesRespectStartingRevision() async throws {
        let (database, first, _, report) = try await financialStorageFixture()
        let second = try SECResearchStore(database: database), baseline = try await first.reportWriteRevision()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await first.saveFinancialReport(report, expectedRevision: baseline)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await first.savedFinancialReports().isEmpty)
        let competing = try financialStorageReportVersion(report)
        func attempt(_ target: SECResearchStore, _ value: SECFinancialReportDocument) async throws -> Bool {
            do { try await target.saveFinancialReport(value, expectedRevision: baseline); return true }
            catch SnapshotError.stalePlan { return false }
        }
        async let a = attempt(first, report)
        async let b = attempt(second, competing)
        let results = try await [a, b]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await first.savedFinancialReports().count == 1)
    }
}
