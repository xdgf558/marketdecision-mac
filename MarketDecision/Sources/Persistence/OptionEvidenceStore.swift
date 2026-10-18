import Foundation
import GRDB
import CoreDomain
import PortfolioEngine

public struct OptionEvidenceSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let kind: OptionEvidenceKind
    public let containsSynthetic: Bool
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, createdAt: Date, kind: OptionEvidenceKind, containsSynthetic: Bool, inputHash: String, reportHash: String) {
        self.id = id; self.createdAt = createdAt; self.kind = kind; self.containsSynthetic = containsSynthetic
        self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct SavedOptionEvidence: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: OptionEvidenceReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: OptionEvidenceReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public protocol OptionEvidenceStorage: Sendable {
    func revision() async throws -> UUID
    func save(_ input: OptionEvidenceInput, expectedRevision: UUID) async throws -> SavedOptionEvidence
    func summaries() async throws -> [OptionEvidenceSummary]
    func open(id: UUID) async throws -> SavedOptionEvidence
}

/// Independent immutable documents in the options database. Embedded ledger
/// evidence never grants write access to the ledger database. Catalogs have no
/// computed numbers; opening and archive validation always perform full replay.
public actor OptionEvidenceStore: OptionEvidenceStorage {
    public static let maximumInputBytes = 16 * 1_024 * 1_024
    public static let maximumReportBytes = 32 * 1_024 * 1_024
    public static let maximumReports = 10_000
    private let database: DatabaseStore
    private var failNextSave = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .optionsLab else { throw OptionLabStoreError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .optionsLab) }
    public func revision() throws -> UUID { try database.read(OptionLabStore.revision) }
    public func save(_ input: OptionEvidenceInput, expectedRevision: UUID) throws -> SavedOptionEvidence {
        try Task.checkCancellation()
        guard try revision() == expectedRevision else { throw OptionLabStoreError.staleRevision }
        let inputBytes = try OptionDailyStore.encode(input)
        guard inputBytes.count <= Self.maximumInputBytes else { throw OptionLabStoreError.budgetExceeded }
        let report = try OptionEvidenceEngine.calculate(input), reportBytes = try OptionDailyStore.encode(report)
        guard reportBytes.count <= Self.maximumReportBytes else { throw OptionLabStoreError.budgetExceeded }
        let inputHash = LedgerCSV.hash(inputBytes), reportHash = LedgerCSV.hash(reportBytes)
        let summary = Self.summary(report, inputHash: inputHash, reportHash: reportHash)
        let summaryBytes = try OptionDailyStore.encode(summary)
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            guard try OptionLabStore.revision(db) == expectedRevision else { throw OptionLabStoreError.staleRevision }
            if let existing = try Self.load(id: input.id, db: db) {
                guard existing.report.input == input, existing.inputHash == inputHash, existing.reportHash == reportHash else { throw OptionLabStoreError.conflictingSnapshot }
                return existing
            }
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_evidence_catalog") ?? 0) < Self.maximumReports else { throw OptionLabStoreError.budgetExceeded }
            try Task.checkCancellation()
            try db.execute(sql: "INSERT INTO option_evidence_catalog(report_id,kind,input_hash,report_hash,summary_hash,summary_json) VALUES (?,?,?,?,?,?)",
                arguments: [input.id.uuidString, input.kind.rawValue, inputHash, reportHash, LedgerCSV.hash(summaryBytes), summaryBytes])
            try db.execute(sql: "INSERT INTO option_evidence_documents(report_id,input_json,report_json) VALUES (?,?,?)", arguments: [input.id.uuidString, inputBytes, reportBytes])
            if inject { throw OptionLabStoreError.injectedFailure }
            try Task.checkCancellation()
            try db.execute(sql: "UPDATE option_lab_metadata SET revision=? WHERE singleton=1", arguments: [UUID().uuidString])
            guard db.changesCount == 1 else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: input.id, report: report, inputHash: inputHash, reportHash: reportHash, replayMatched: true)
        }
    }
    public func summaries() throws -> [OptionEvidenceSummary] {
        try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_evidence_catalog") ?? 0) <= Self.maximumReports else { throw OptionLabStoreError.budgetExceeded }
            return try Row.fetchAll(db, sql: Self.catalogQuery).map(Self.decodeSummary).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        }
    }
    public func open(id: UUID) throws -> SavedOptionEvidence {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard let value = try Self.load(id: id, db: db) else { throw OptionLabStoreError.notFound }; return value
        }
    }
    func injectFailureOnNextSave() { failNextSave = true }
    private static let catalogQuery = "SELECT c.*, EXISTS(SELECT 1 FROM option_evidence_documents d WHERE d.report_id=c.report_id) AS has_document FROM option_evidence_catalog c"
    private static func summary(_ report: OptionEvidenceReport, inputHash: String, reportHash: String) -> OptionEvidenceSummary {
        .init(id: report.id, createdAt: report.input.createdAt, kind: report.input.kind, containsSynthetic: report.containsSynthetic, inputHash: inputHash, reportHash: reportHash)
    }
    private static func decodeSummary(_ row: Row) throws -> OptionEvidenceSummary {
        do {
            try Task.checkCancellation()
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String), (row["has_document"] as Bool) else { throw OptionLabStoreError.corruptedStorage }
            let value = try JSONDecoder().decode(OptionEvidenceSummary.self, from: bytes)
            guard value.id.uuidString == (row["report_id"] as String), value.kind.rawValue == (row["kind"] as String),
                value.inputHash == (row["input_hash"] as String), value.reportHash == (row["report_hash"] as String), value.createdAt.timeIntervalSinceReferenceDate.isFinite,
                value.inputHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                value.reportHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw OptionLabStoreError.corruptedStorage }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func load(id: UUID, db: Database) throws -> SavedOptionEvidence? {
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.report_id=?", arguments: [id.uuidString]) else { return nil }
        let metadata = try decodeSummary(row)
        do {
            guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json FROM option_evidence_documents WHERE report_id=?", arguments: [id.uuidString]) else { throw OptionLabStoreError.corruptedStorage }
            let inputBytes: Data = body["input_json"], reportBytes: Data = body["report_json"]
            guard inputBytes.count <= maximumInputBytes, reportBytes.count <= maximumReportBytes,
                LedgerCSV.hash(inputBytes) == metadata.inputHash, LedgerCSV.hash(reportBytes) == metadata.reportHash else { throw OptionLabStoreError.corruptedStorage }
            let input = try JSONDecoder().decode(OptionEvidenceInput.self, from: inputBytes)
            let report = try JSONDecoder().decode(OptionEvidenceReport.self, from: reportBytes)
            guard input.id == id, report.input == input, summary(report, inputHash: metadata.inputHash, reportHash: metadata.reportHash) == metadata else { throw OptionLabStoreError.corruptedStorage }
            let replay = try OptionEvidenceEngine.replay(report)
            guard replay == report else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: id, report: replay, inputHash: metadata.inputHash, reportHash: metadata.reportHash, replayMatched: true)
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
}
extension DatabaseStore {
    static let optionEvidenceMigration = DatabaseMigration(identifier: "options-lab.v5") { db in
        try db.execute(sql: """
            CREATE TABLE option_evidence_catalog (
                report_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL,
                input_hash TEXT NOT NULL CHECK(length(input_hash)=64), report_hash TEXT NOT NULL CHECK(length(report_hash)=64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE option_evidence_documents (
                report_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(report_id) REFERENCES option_evidence_catalog(report_id) ON DELETE RESTRICT
            );
            """)
    }
}
