import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

/// Catalog metadata only. Opening and explicit replay remain separate operations.
public struct SECValuationSupplementSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let parentFinancialReportID: UUID
    public let parentResearchID: UUID
    public let ticker: String
    public let companyName: String
    public let cutoff: Date
    public let createdAt: Date

    public init(document: SECValuationSupplementDocument) {
        id = document.id; parentFinancialReportID = document.parentFinancialReportID
        parentResearchID = document.parentResearchID; ticker = document.ticker
        companyName = document.companyName; cutoff = document.cutoff; createdAt = document.createdAt
    }
    fileprivate func validate() throws {
        try EquityRecord.validateSymbol(ticker)
        guard !companyName.isEmpty, cutoff.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite, cutoff <= createdAt
        else { throw BusinessStoreError.corruptedStorage }
    }
}

/// The original revision is captured before preparation and is never silently rebased.
public struct SECValuationSupplementDraft: Sendable {
    public let document: SECValuationSupplementDocument
    public let expectedRevision: UUID
    public init(document: SECValuationSupplementDocument, expectedRevision: UUID) {
        self.document = document; self.expectedRevision = expectedRevision
    }
}

extension SECResearchStore {
    /// Open source evidence through the selected retained accounting report. One read
    /// validates both original encodings and their binding before returning any source.
    /// Re-encoding a decoded research document is never used as proof of its saved hash.
    public func valuationSourceDocument(parentReportID: UUID) throws -> SECValuationSourceDocument {
        try Task.checkCancellation()
        _ = try writeRevision()
        return try database.read { db in
            let chain = try SECFinancialReportStorage.validatedParentChain(id: parentReportID, db: db)
            try Task.checkCancellation()
            return try SECValuationSourceDocument(validatedResearch: chain.research.document,
                originalHash: chain.report.document.parentDocumentHash)
        }
    }

    public func prepareValuationSupplement(parentReportID: UUID, evidence: SECValuationInputEvidence,
                                            executionDate: Date) async throws -> SECValuationSupplementDraft {
        try Task.checkCancellation()
        let baseline = try writeRevision()
        let parents = try database.read { db in
            try BusinessDataStore.checkRevision(baseline, db: db)
            return try SECFinancialReportStorage.validatedParentChain(id: parentReportID, db: db)
        }
        let document = try await SECValuationSupplementDocument.make(parent: parents.report.document, parentBytes: parents.report.bytes,
            research: parents.research.document, researchBytes: parents.research.bytes, evidence: evidence, executionDate: executionDate)
        try Task.checkCancellation()
        try database.read { db in try BusinessDataStore.checkRevision(baseline, db: db) }
        return .init(document: document, expectedRevision: baseline)
    }

    /// Append the independent supplement and advance the business revision atomically.
    /// Cached parent results are never used as authorization for valuation calculations.
    public func saveValuationSupplement(_ document: SECValuationSupplementDocument, expectedRevision: UUID) async throws {
        try Task.checkCancellation()
        _ = try writeRevision()
        let bytes = try ResearchDocument.encoded(document)
        try database.transaction { db in
            try BusinessDataStore.checkRevision(expectedRevision, db: db)
            try Task.checkCancellation()
            let id = document.id.uuidString.lowercased()
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_catalog WHERE supplement_id = ?", arguments: [id]) == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [id]) == 0
            else { throw SnapshotError.duplicateObject }
            let chain = try SECFinancialReportStorage.validatedParentChain(id: document.parentFinancialReportID, db: db)
            try document.validate(parent: chain.report.document, parentBytes: chain.report.bytes,
                                  research: chain.research.document, researchBytes: chain.research.bytes)
            try Task.checkCancellation()
            try SECValuationSupplementStorage.insert(document, bytes: bytes, db: db)
            try Task.checkCancellation()
            try BusinessDataStore.writeRevision(UUID(), db: db)
        }
    }

    /// Listing touches no supplement, accounting report or SEC research body.
    public func savedValuationSupplements(parentReportID: UUID? = nil) throws -> [SECValuationSupplementSummary] {
        _ = try writeRevision()
        return try database.read { db in try SECValuationSupplementStorage.summaries(parentReportID: parentReportID, db: db) }
    }

    public func openValuationSupplement(id: UUID) throws -> SECValuationSupplementDocument {
        try Task.checkCancellation()
        _ = try writeRevision()
        return try database.read { db in try SECValuationSupplementStorage.open(id: id, db: db) }
    }
}

enum SECValuationSupplementStorage {
    private struct Catalog: Codable {
        let summary: SECValuationSupplementSummary
        let parentFinancialReportHash: String
        let parentResearchHash: String
        let supplementHash: String
    }

    static func insert(_ document: SECValuationSupplementDocument, bytes: Data, db: Database) throws {
        let catalog = Catalog(summary: .init(document: document), parentFinancialReportHash: document.parentFinancialReportHash,
            parentResearchHash: document.parentResearchHash, supplementHash: digest(bytes))
        let summary = try ResearchDocument.encoded(catalog), id = document.id.uuidString.lowercased()
        try db.execute(sql: """
            INSERT INTO sec_valuation_supplement_catalog
            (supplement_id, parent_report_id, parent_report_hash, parent_research_id, parent_research_hash,
             supplement_hash, summary_hash, summary_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, document.parentFinancialReportID.uuidString.lowercased(), document.parentFinancialReportHash,
                document.parentResearchID.uuidString.lowercased(), document.parentResearchHash,
                catalog.supplementHash, digest(summary), summary])
        try db.execute(sql: "INSERT INTO sec_valuation_supplement_documents(supplement_id, supplement_json) VALUES (?, ?)",
            arguments: [id, bytes])
    }

    static let catalogQuery = """
        SELECT c.supplement_id, c.parent_report_id, c.parent_report_hash, c.parent_research_id,
               c.parent_research_hash, c.supplement_hash, c.summary_hash, c.summary_json,
               d.supplement_id AS stored_supplement_id, f.report_hash AS retained_report_hash,
               f.parent_document_id AS retained_research_id, f.parent_document_hash AS report_research_hash,
               r.document_hash AS retained_research_hash
        FROM sec_valuation_supplement_catalog c
        LEFT JOIN sec_valuation_supplement_documents d ON d.supplement_id = c.supplement_id
        LEFT JOIN sec_financial_report_catalog f ON f.report_id = c.parent_report_id
        LEFT JOIN sec_research_catalog r ON r.document_id = c.parent_research_id
        """

    static func summaries(parentReportID: UUID?, db: Database) throws -> [SECValuationSupplementSummary] {
        if parentReportID == nil {
            guard try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sec_valuation_supplement_documents d WHERE NOT EXISTS
                (SELECT 1 FROM sec_valuation_supplement_catalog c WHERE c.supplement_id = d.supplement_id)
                """) == 0 else { throw BusinessStoreError.corruptedStorage }
        }
        let query = catalogQuery + (parentReportID == nil ? "" : " WHERE c.parent_report_id = ?")
        let args: StatementArguments = parentReportID.map { [$0.uuidString.lowercased()] } ?? []
        let cursor = try Row.fetchCursor(db, sql: query, arguments: args)
        var values: [SECValuationSupplementSummary] = []
        while let row = try cursor.next() {
            try Task.checkCancellation(); values.append(try decodeCatalog(row).summary)
        }
        return values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    static func open(id: UUID, db: Database) throws -> SECValuationSupplementDocument {
        let key = id.uuidString.lowercased()
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.supplement_id = ?", arguments: [key]) else {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [key]) == 0
            else { throw BusinessStoreError.corruptedStorage }
            throw SnapshotError.missingReference
        }
        let catalog = try decodeCatalog(row)
        guard let bytes = try Data.fetchOne(db, sql: "SELECT supplement_json FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [key]),
              digest(bytes) == catalog.supplementHash else { throw BusinessStoreError.corruptedStorage }
        let document: SECValuationSupplementDocument
        do { document = try JSONDecoder().decode(SECValuationSupplementDocument.self, from: bytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BusinessStoreError.corruptedStorage }
        guard document.id == id, document.parentFinancialReportHash == catalog.parentFinancialReportHash,
              document.parentResearchHash == catalog.parentResearchHash,
              SECValuationSupplementSummary(document: document) == catalog.summary else { throw BusinessStoreError.corruptedStorage }
        try Task.checkCancellation()
        let chain = try SECFinancialReportStorage.validatedParentChain(id: document.parentFinancialReportID, db: db)
        do {
            try document.validate(parent: chain.report.document, parentBytes: chain.report.bytes,
                                  research: chain.research.document, researchBytes: chain.research.bytes)
        } catch is CancellationError { throw CancellationError() }
        catch { throw BusinessStoreError.corruptedStorage }
        try Task.checkCancellation()
        return document
    }

    private static func decodeCatalog(_ row: Row) throws -> Catalog {
        let bytes: Data = row["summary_json"]
        guard digest(bytes) == row["summary_hash"] else { throw BusinessStoreError.corruptedStorage }
        let value: Catalog
        do { value = try JSONDecoder().decode(Catalog.self, from: bytes) }
        catch { throw BusinessStoreError.corruptedStorage }
        try value.summary.validate()
        let stored: String? = row["stored_supplement_id"], reportHash: String? = row["retained_report_hash"]
        let researchID: String? = row["retained_research_id"], reportResearchHash: String? = row["report_research_hash"]
        let researchHash: String? = row["retained_research_hash"]
        guard value.summary.id.uuidString.lowercased() == row["supplement_id"], stored == row["supplement_id"],
              value.summary.parentFinancialReportID.uuidString.lowercased() == row["parent_report_id"],
              value.summary.parentResearchID.uuidString.lowercased() == row["parent_research_id"],
              researchID == row["parent_research_id"],
              value.parentFinancialReportHash == row["parent_report_hash"], reportHash == value.parentFinancialReportHash,
              value.parentResearchHash == row["parent_research_hash"], researchHash == value.parentResearchHash,
              reportResearchHash == value.parentResearchHash, value.supplementHash == row["supplement_hash"],
              [value.parentFinancialReportHash, value.parentResearchHash, value.supplementHash].allSatisfy({
                  $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
              }) else { throw BusinessStoreError.corruptedStorage }
        return value
    }
}
