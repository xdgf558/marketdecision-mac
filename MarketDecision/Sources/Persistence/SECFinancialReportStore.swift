import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

/// Catalog metadata only. Listing a report does not verify its cached metric values.
public struct SECFinancialReportSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let parentDocumentID: UUID
    public let ticker: String
    public let companyName: String
    public let cutoff: Date
    public let createdAt: Date

    public init(document: SECFinancialReportDocument) {
        id = document.id; parentDocumentID = document.parentDocumentID
        ticker = document.ticker; companyName = document.companyName
        cutoff = document.cutoff; createdAt = document.createdAt
    }

    fileprivate func validate() throws {
        try EquityRecord.validateSymbol(ticker)
        guard !companyName.isEmpty, cutoff.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite, cutoff <= createdAt else { throw BusinessStoreError.corruptedStorage }
    }
}

/// A generated offline candidate and its original business revision. An explicit save
/// must carry this exact baseline; stale drafts are recomputed instead of rebased.
public struct SECFinancialReportDraft: Sendable {
    public let document: SECFinancialReportDocument
    public let expectedRevision: UUID
    public init(document: SECFinancialReportDocument, expectedRevision: UUID) {
        self.document = document; self.expectedRevision = expectedRevision
    }
}

extension SECResearchStore {
    /// The caller captures this baseline before preparing a report. Saving never silently
    /// replaces an old baseline with the current revision after asynchronous computation.
    public func reportWriteRevision() throws -> UUID { try writeRevision() }

    public func prepareFinancialReport(parentID: UUID, executionDate: Date) async throws -> SECFinancialReportDraft {
        try Task.checkCancellation()
        let baseline = try writeRevision()
        let parent = try database.read { db in
            try BusinessDataStore.checkRevision(baseline, db: db)
            return try SECResearchStorage.validatedRecord(id: parentID, db: db)
        }
        let document = try await SECFinancialReportDocument.make(parent: parent.document, parentBytes: parent.bytes,
                                                               executionDate: executionDate)
        try Task.checkCancellation()
        try database.read { db in try BusinessDataStore.checkRevision(baseline, db: db) }
        return SECFinancialReportDraft(document: document, expectedRevision: baseline)
    }

    /// Append one offline report. Parent validation, selected legacy catalog insertion,
    /// report bytes and revision are committed together or entirely rolled back.
    public func saveFinancialReport(_ document: SECFinancialReportDocument, expectedRevision: UUID) async throws {
        try Task.checkCancellation()
        _ = try writeRevision()
        let bytes = try ResearchDocument.encoded(document)
        try database.transaction { db in
            try BusinessDataStore.checkRevision(expectedRevision, db: db)
            try Task.checkCancellation()
            let id = document.id.uuidString.lowercased()
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_financial_report_catalog WHERE report_id = ?", arguments: [id]) == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_financial_report_documents WHERE report_id = ?", arguments: [id]) == 0
            else { throw SnapshotError.duplicateObject }
            let parent = try SECResearchStorage.validatedRecord(id: document.parentDocumentID, db: db)
            try document.validate(parent: parent.document, parentBytes: parent.bytes)
            try Task.checkCancellation()
            try SECResearchStorage.ensureCatalog(document: parent.document, bytes: parent.bytes, db: db)
            try SECFinancialReportStorage.insert(document, bytes: bytes, db: db)
            try Task.checkCancellation()
            try BusinessDataStore.writeRevision(UUID(), db: db)
        }
    }

    /// Read small catalog rows only; selected opening validates report and retained parent.
    /// A parent-specific list does not inspect unrelated report bodies or parent records.
    public func savedFinancialReports(parentID: UUID? = nil) throws -> [SECFinancialReportSummary] {
        _ = try writeRevision()
        return try database.read { db in try SECFinancialReportStorage.summaries(parentID: parentID, db: db) }
    }

    public func openFinancialReport(id: UUID) throws -> SECFinancialReportDocument {
        try Task.checkCancellation()
        _ = try writeRevision()
        return try database.read { db in try SECFinancialReportStorage.open(id: id, db: db) }
    }
}

/// Created only by the complete selected-record reader below for one operation. Preparation
/// may retain it after the read returns; it is never cached or shared across operations and
/// does not grant permission to skip document validation or the final revision check.
struct SECFinancialReportParentChain: Sendable {
    let report: (document: SECFinancialReportDocument, bytes: Data)
    let research: (document: SECResearchDocument, bytes: Data)

    fileprivate init(report: (document: SECFinancialReportDocument, bytes: Data),
                     research: (document: SECResearchDocument, bytes: Data)) {
        self.report = report; self.research = research
    }
}

enum SECFinancialReportStorage {
    private struct Catalog: Codable {
        let summary: SECFinancialReportSummary
        let parentDocumentHash: String
        let reportHash: String
    }

    static func insert(_ document: SECFinancialReportDocument, bytes: Data, db: Database) throws {
        let value = Catalog(summary: .init(document: document), parentDocumentHash: document.parentDocumentHash,
                            reportHash: digest(bytes))
        let summary = try ResearchDocument.encoded(value)
        let id = document.id.uuidString.lowercased()
        try db.execute(sql: """
            INSERT INTO sec_financial_report_catalog
            (report_id, parent_document_id, parent_document_hash, report_hash, summary_hash, summary_json)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, document.parentDocumentID.uuidString.lowercased(), document.parentDocumentHash,
                               value.reportHash, digest(summary), summary])
        try db.execute(sql: "INSERT INTO sec_financial_report_documents(report_id, report_json) VALUES (?, ?)", arguments: [id, bytes])
    }

    // The body table has a rowid and separate narrow primary-key index. The JOIN reads
    // only its ID, never report_json; the parent JOIN likewise reads only its catalog.
    static let catalogQuery = """
        SELECT c.report_id, c.parent_document_id, c.parent_document_hash, c.report_hash,
               c.summary_hash, c.summary_json, d.report_id AS stored_report_id,
               p.document_hash AS retained_parent_hash
        FROM sec_financial_report_catalog c
        LEFT JOIN sec_financial_report_documents d ON d.report_id = c.report_id
        LEFT JOIN sec_research_catalog p ON p.document_id = c.parent_document_id
        """

    static func summaries(parentID: UUID?, db: Database) throws -> [SECFinancialReportSummary] {
        if parentID == nil {
            guard try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sec_financial_report_documents d WHERE NOT EXISTS
                (SELECT 1 FROM sec_financial_report_catalog c WHERE c.report_id = d.report_id)
                """) == 0 else { throw BusinessStoreError.corruptedStorage }
        }
        let query = catalogQuery + (parentID == nil ? "" : " WHERE c.parent_document_id = ?")
        let args: StatementArguments = parentID.map { [$0.uuidString.lowercased()] } ?? []
        let cursor = try Row.fetchCursor(db, sql: query, arguments: args)
        var values: [SECFinancialReportSummary] = []
        while let row = try cursor.next() {
            try Task.checkCancellation()
            values.append(try decodeCatalog(row).summary)
        }
        return values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    static func open(id: UUID, db: Database) throws -> SECFinancialReportDocument {
        try validatedRecord(id: id, db: db).document
    }

    /// Returns the retained report encoding, never a reconstructed JSON encoding. A
    /// valuation supplement binds this exact body and the fully validated SEC parent.
    static func validatedRecord(id: UUID, db: Database) throws -> (document: SECFinancialReportDocument, bytes: Data) {
        try validatedParentChain(id: id, db: db).report
    }

    /// Reuse the already decoded and fully checked parent within this database operation.
    /// Both original encodings remain bound; no catalog-only validation is substituted.
    static func validatedParentChain(id: UUID, db: Database) throws -> SECFinancialReportParentChain {
        let key = id.uuidString.lowercased()
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.report_id = ?", arguments: [key]) else {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_financial_report_documents WHERE report_id = ?", arguments: [key]) == 0
            else { throw BusinessStoreError.corruptedStorage }
            throw SnapshotError.missingReference
        }
        let catalog = try decodeCatalog(row)
        guard let bytes = try Data.fetchOne(db, sql: "SELECT report_json FROM sec_financial_report_documents WHERE report_id = ?", arguments: [key]),
              digest(bytes) == catalog.reportHash else { throw BusinessStoreError.corruptedStorage }
        let document: SECFinancialReportDocument
        do { document = try JSONDecoder().decode(SECFinancialReportDocument.self, from: bytes) }
        catch { throw BusinessStoreError.corruptedStorage }
        guard document.id == id, document.parentDocumentHash == catalog.parentDocumentHash,
              SECFinancialReportSummary(document: document) == catalog.summary else { throw BusinessStoreError.corruptedStorage }
        try Task.checkCancellation()
        let parent = try SECResearchStorage.validatedRecord(id: document.parentDocumentID, db: db)
        do { try document.validate(parent: parent.document, parentBytes: parent.bytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BusinessStoreError.corruptedStorage }
        try Task.checkCancellation()
        return SECFinancialReportParentChain(report: (document, bytes), research: parent)
    }

    private static func decodeCatalog(_ row: Row) throws -> Catalog {
        let bytes: Data = row["summary_json"]
        guard digest(bytes) == row["summary_hash"] else { throw BusinessStoreError.corruptedStorage }
        let catalog: Catalog
        do { catalog = try JSONDecoder().decode(Catalog.self, from: bytes) }
        catch { throw BusinessStoreError.corruptedStorage }
        try catalog.summary.validate()
        let storedID: String? = row["stored_report_id"], retainedHash: String? = row["retained_parent_hash"]
        guard catalog.summary.id.uuidString.lowercased() == row["report_id"], storedID == row["report_id"],
              catalog.summary.parentDocumentID.uuidString.lowercased() == row["parent_document_id"],
              catalog.parentDocumentHash == row["parent_document_hash"], retainedHash == catalog.parentDocumentHash,
              catalog.reportHash == row["report_hash"],
              [catalog.parentDocumentHash, catalog.reportHash].allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
        else { throw BusinessStoreError.corruptedStorage }
        return catalog
    }
}
