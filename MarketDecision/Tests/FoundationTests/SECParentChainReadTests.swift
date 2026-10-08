import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

/// Counts body reads only. No expanded statement, bound argument or source byte is retained.
private final class ParentBodyReads: @unchecked Sendable {
    struct Counts: Equatable { var research = 0, legacy = 0, report = 0 }
    private let lock = NSLock()
    private var counts = Counts()
    func observe(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        let sql = sql.lowercased()
        if sql.hasPrefix("select document_json from sec_research_documents") { counts.research += 1 }
        if sql.hasPrefix("select * from p1_snapshot_objects where namespace") { counts.legacy += 1 }
        if sql.hasPrefix("select report_json from sec_financial_report_documents") { counts.report += 1 }
    }
    func reset() { lock.lock(); defer { lock.unlock() }; counts = Counts() }
    func snapshot() -> Counts { lock.lock(); defer { lock.unlock() }; return counts }
    func install(on database: DatabaseStore) throws {
        try database.read { db in
            db.trace { event in
                guard case let .statement(statement) = event else { return }
                self.observe(statement.sql)
            }
        }
    }
}

private func chainSupplementCopy(_ value: SECValuationSupplementDocument) throws -> SECValuationSupplementDocument {
    var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(value)) as? [String: Any])
    object["id"] = UUID().uuidString
    return try JSONDecoder().decode(SECValuationSupplementDocument.self, from: JSONSerialization.data(withJSONObject: object))
}

private func chainLegacyBundle(_ document: SECResearchDocument, bytes: Data) throws -> SnapshotBundle {
    let identity = ObjectIdentity(id: document.id.uuidString.lowercased(), version: "sec-research.v1")
    let object = FrozenObject(identity: identity, kind: .result, payload: .string(bytes.base64EncodedString()), references: [],
        capturedAt: try MillisecondInstant(rounding: document.cutoff),
        permission: .init(mayStore: true, mayBackup: false, evidenceReference: "sec-research.local-only.v1"), synthetic: false)
    let root = SnapshotRoot(identity: identity, kind: .analysisRun,
        references: [.init(role: "sec-research", target: identity, contentHash: try object.contentHash())])
    return SnapshotBundle(sourceNamespace: document.id, objects: [object], roots: [root])
}

@Suite struct SECParentChainReadTests {
    @Test func everySupplementOperationReadsEachSelectedParentBodyOnce() async throws {
        let (database, store, research, report, _) = try await secValuationStorageFixture()
        let reads = ParentBodyReads(); try reads.install(on: database)
        defer { try? database.read { $0.trace(nil) } }
        let expected = ParentBodyReads.Counts(research: 1, legacy: 0, report: 1)

        let source = try await store.valuationSourceDocument(parentReportID: report.id)
        #expect(source.id == research.id && source.sources == research.sources)
        #expect(reads.snapshot() == expected)

        reads.reset()
        let draft = try await store.prepareValuationSupplement(parentReportID: report.id, evidence: .init(),
            executionDate: research.cutoff.addingTimeInterval(3))
        #expect(reads.snapshot() == expected)
        reads.reset()
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        #expect(reads.snapshot() == expected)
        reads.reset()
        let opened = try await store.openValuationSupplement(id: draft.document.id)
        #expect(reads.snapshot() == expected)
        #expect(try ResearchDocument.encoded(opened) == ResearchDocument.encoded(draft.document))
        let replay = try await opened.valuation.recompute()
        #expect(try opened.valuation.cachedReportMatches(replay))
        #expect(reads.snapshot() == expected) // Explicit frozen replay is independent of SQLite.
    }

    @Test(arguments: ["sec_research_documents", "sec_financial_report_documents"])
    func eachNewOperationRevalidatesBothParentsAfterPriorSuccess(_ table: String) async throws {
        let (database, store, research, report, draft) = try await secValuationStorageFixture()
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        _ = try await store.openValuationSupplement(id: draft.document.id)
        _ = try await store.valuationSourceDocument(parentReportID: report.id)
        let revision = try await store.reportWriteRevision()
        let another = try chainSupplementCopy(draft.document)
        try database.transaction { db in
            let column = table == "sec_research_documents" ? "document_json" : "report_json"
            try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [Data("synthetic-damaged-parent".utf8)])
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await store.valuationSourceDocument(parentReportID: report.id)
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await store.prepareValuationSupplement(parentReportID: report.id, evidence: .init(),
                executionDate: research.cutoff.addingTimeInterval(3))
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await store.saveValuationSupplement(another, expectedRevision: revision)
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await store.openValuationSupplement(id: draft.document.id)
        }
        #expect(try await store.reportWriteRevision() == revision)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_documents") } == 1)
    }

    @Test func legacyParentIsReadOnceWithoutReencodingAndSupplementReplaysAfterReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("synthetic-legacy.sqlite").path
        let database = try DatabaseStore(path: path, purpose: .secResearch), store = try SECResearchStore(database: database)
        let research = try await secFinancialReportFixtureParent()
        let canonical = try ResearchDocument.encoded(research)
        let original = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: canonical),
            options: [.prettyPrinted, .sortedKeys])
        #expect(original != canonical)
        try await store.business.freeze(chainLegacyBundle(research, bytes: original), expectedRevision: store.writeRevision())
        let report = try await store.prepareFinancialReport(parentID: research.id, executionDate: research.cutoff.addingTimeInterval(1))
        try await store.saveFinancialReport(report.document, expectedRevision: report.expectedRevision)
        let oldObject = try #require(database.read { try Data.fetchOne($0, sql: "SELECT object_json FROM p1_snapshot_objects") })
        let oldContent = try #require(database.read { try Data.fetchOne($0, sql: "SELECT content FROM p1_snapshot_objects") })
        let reportBytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") })
        let reads = ParentBodyReads(); try reads.install(on: database)
        defer { try? database.read { $0.trace(nil) } }
        let expected = ParentBodyReads.Counts(research: 0, legacy: 1, report: 1)
        let source = try await store.valuationSourceDocument(parentReportID: report.document.id)
        #expect(source.id == research.id && source.sources == research.sources)
        #expect(reads.snapshot() == expected)
        reads.reset()
        let draft = try await store.prepareValuationSupplement(parentReportID: report.document.id, evidence: .init(),
            executionDate: research.cutoff.addingTimeInterval(2))
        #expect(reads.snapshot() == expected)
        reads.reset()
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        #expect(reads.snapshot() == expected)
        reads.reset()
        let opened = try await store.openValuationSupplement(id: draft.document.id)
        #expect(reads.snapshot() == expected)
        #expect(opened.parentResearchHash == digest(original))
        #expect(opened.parentFinancialReportHash == digest(reportBytes))
        try database.read { $0.trace(nil) }
        let reopenedStore = try SECResearchStore(path: path)
        let reopened = try await reopenedStore.openValuationSupplement(id: draft.document.id)
        #expect(try ResearchDocument.encoded(reopened) == ResearchDocument.encoded(opened))
        let replay = try await reopened.valuation.recompute()
        #expect(try reopened.valuation.cachedReportMatches(replay))
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT object_json FROM p1_snapshot_objects") } == oldObject)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT content FROM p1_snapshot_objects") } == oldContent)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") } == reportBytes)
    }

    @Test func iterativeValidationStillChecksResourceIdentityAndCompleteCachedFacts() async throws {
        let research = try await secFinancialReportFixtureParent()
        let original = try ResearchDocument.encoded(research)
        var changed = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var sources = try #require(changed["sources"] as? [[String: Any]])
        let identityReference = try #require(research.sources.first(where: { $0.endpoint == .companyIdentity })?.reference)
        let sourceIndex = try #require(sources.firstIndex(where: { $0["reference"] as? String == identityReference }))
        var request = try #require(sources[sourceIndex]["request"] as? [String: Any])
        request["resourceID"] = "MSFT"
        sources[sourceIndex]["request"] = request; changed["sources"] = sources
        let wrongResource = try JSONDecoder().decode(SECResearchDocument.self, from: JSONSerialization.data(withJSONObject: changed))
        #expect(throws: SECResearchError.invalidDocument) { try wrongResource.validate() }

        changed = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var normalization = try #require(changed["normalization"] as? [String: Any])
        var selected = try #require(normalization["selectedSourceFacts"] as? [[String: Any]])
        try #require(!selected.isEmpty)
        selected[0]["sourceValue"] = "999999"
        normalization["selectedSourceFacts"] = selected; changed["normalization"] = normalization
        let wrongFact = try JSONDecoder().decode(SECResearchDocument.self, from: JSONSerialization.data(withJSONObject: changed))
        #expect(throws: SECResearchError.invalidDocument) { try wrongFact.validate() }
        try research.validate()
        #expect(try research.recompute() == research.normalization)
        #expect(try ResearchDocument.encoded(research) == original)
    }
}
