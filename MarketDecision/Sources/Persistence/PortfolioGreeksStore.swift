import Foundation
import GRDB
import CoreDomain
import PortfolioEngine

/// Directory metadata only. No cached exposure or coverage values are published
/// before the complete frozen ledger and option inputs have been replayed.
public struct PortfolioGreeksSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let asOf: Date
    public let accountID: String
    public let ledgerRevision: UUID
    public let mode: PortfolioGreeksMode
    public let positionCount: Int
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, createdAt: Date, asOf: Date, accountID: String, ledgerRevision: UUID,
                mode: PortfolioGreeksMode, positionCount: Int, inputHash: String, reportHash: String) {
        self.id = id; self.createdAt = createdAt; self.asOf = asOf; self.accountID = accountID
        self.ledgerRevision = ledgerRevision; self.mode = mode; self.positionCount = positionCount
        self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct SavedPortfolioGreeks: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: PortfolioGreeksReport
    public let inputHash: String
    public let reportHash: String
    /// This verifies the frozen historical basis, never its currency against a
    /// separate ledger database that may already have changed.
    public let replayMatched: Bool
    public init(id: UUID, report: PortfolioGreeksReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash
        self.replayMatched = replayMatched
    }
}
public protocol PortfolioGreeksStorage: Sendable {
    func revision() async throws -> UUID
    func save(_ input: PortfolioGreeksInput, expectedRevision: UUID) async throws -> SavedPortfolioGreeks
    func summaries() async throws -> [PortfolioGreeksSummary]
    func open(id: UUID) async throws -> SavedPortfolioGreeks
}

/// Append-only, self-contained reports in the MDQ1 options database. The ledger
/// accounts/events/revision are frozen input bytes; this store cannot mutate or
/// restore portfolio-ledger.sqlite and does not promise a cross-database snapshot.
public actor PortfolioGreeksStore: PortfolioGreeksStorage {
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
    public func save(_ input: PortfolioGreeksInput, expectedRevision: UUID) throws -> SavedPortfolioGreeks {
        try Task.checkCancellation()
        guard try revision() == expectedRevision else { throw OptionLabStoreError.staleRevision }
        let inputBytes = try OptionDailyStore.encode(input)
        guard inputBytes.count <= Self.maximumInputBytes else { throw OptionLabStoreError.budgetExceeded }
        let report = try PortfolioGreeksEngine.calculate(input), reportBytes = try OptionDailyStore.encode(report)
        guard reportBytes.count <= Self.maximumReportBytes else { throw OptionLabStoreError.budgetExceeded }
        let inputHash = LedgerCSV.hash(inputBytes), reportHash = LedgerCSV.hash(reportBytes)
        let summary = Self.summary(report, inputHash: inputHash, reportHash: reportHash)
        let summaryBytes = try OptionDailyStore.encode(summary)
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            // The caller's pre-calculation baseline survives queueing and replay.
            // No old calculation may adopt the revision after clear or restore.
            guard try OptionLabStore.revision(db) == expectedRevision else { throw OptionLabStoreError.staleRevision }
            if let existing = try Self.load(id: input.id, db: db) {
                guard existing.report.input == input, existing.inputHash == inputHash,
                      existing.reportHash == reportHash else { throw OptionLabStoreError.conflictingSnapshot }
                return existing
            }
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM portfolio_greeks_catalog") ?? 0) < Self.maximumReports else {
                throw OptionLabStoreError.budgetExceeded
            }
            try Task.checkCancellation()
            try db.execute(sql: """
                INSERT INTO portfolio_greeks_catalog(report_id,ledger_revision,input_hash,report_hash,model_version,numeric_policy_version,summary_hash,summary_json)
                VALUES (?,?,?,?,?,?,?,?)
                """, arguments: [input.id.uuidString, input.ledgerRevision.uuidString, inputHash, reportHash,
                                   report.schemaVersion, PortfolioGreeksEngine.numericPolicyVersion, LedgerCSV.hash(summaryBytes), summaryBytes])
            try db.execute(sql: "INSERT INTO portfolio_greeks_documents(report_id,input_json,report_json) VALUES (?,?,?)",
                           arguments: [input.id.uuidString, inputBytes, reportBytes])
            if inject { throw OptionLabStoreError.injectedFailure }
            try Task.checkCancellation()
            try db.execute(sql: "UPDATE option_lab_metadata SET revision=? WHERE singleton=1", arguments: [UUID().uuidString])
            guard db.changesCount == 1 else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: input.id, report: report, inputHash: inputHash, reportHash: reportHash, replayMatched: true)
        }
    }
    public func summaries() throws -> [PortfolioGreeksSummary] {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM portfolio_greeks_catalog") ?? 0) <= Self.maximumReports else {
                throw OptionLabStoreError.budgetExceeded
            }
            return try Row.fetchAll(db, sql: Self.catalogQuery).map(Self.decodeSummary).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        }
    }
    public func open(id: UUID) throws -> SavedPortfolioGreeks {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard let value = try Self.load(id: id, db: db) else { throw OptionLabStoreError.notFound }
            return value
        }
    }
    func injectFailureOnNextSave() { failNextSave = true }
    private static let catalogQuery = """
        SELECT c.*, EXISTS(SELECT 1 FROM portfolio_greeks_documents d WHERE d.report_id=c.report_id) AS has_document
        FROM portfolio_greeks_catalog c
        """
    private static func summary(_ report: PortfolioGreeksReport, inputHash: String, reportHash: String) -> PortfolioGreeksSummary {
        let input = report.input
        return .init(id: input.id, createdAt: input.createdAt, asOf: input.asOf, accountID: input.accountID,
                     ledgerRevision: input.ledgerRevision, mode: input.mode, positionCount: report.rows.count,
                     inputHash: inputHash, reportHash: reportHash)
    }
    private static func decodeSummary(_ row: Row) throws -> PortfolioGreeksSummary {
        do {
            try Task.checkCancellation()
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String),
                  (row["has_document"] as Bool), (row["numeric_policy_version"] as String) == PortfolioGreeksEngine.numericPolicyVersion else {
                throw OptionLabStoreError.corruptedStorage
            }
            let value = try JSONDecoder().decode(PortfolioGreeksSummary.self, from: bytes)
            guard value.id.uuidString == (row["report_id"] as String),
                  value.ledgerRevision.uuidString == (row["ledger_revision"] as String),
                  value.inputHash == (row["input_hash"] as String), value.reportHash == (row["report_hash"] as String),
                  value.createdAt.timeIntervalSinceReferenceDate.isFinite, value.asOf.timeIntervalSinceReferenceDate.isFinite,
                  !value.accountID.isEmpty, value.positionCount >= 0,
                  value.inputHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  value.reportHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw OptionLabStoreError.corruptedStorage
            }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func load(id: UUID, db: Database) throws -> SavedPortfolioGreeks? {
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.report_id=?", arguments: [id.uuidString]) else { return nil }
        let metadata = try decodeSummary(row)
        do {
            guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json FROM portfolio_greeks_documents WHERE report_id=?", arguments: [id.uuidString]) else {
                throw OptionLabStoreError.corruptedStorage
            }
            let inputBytes: Data = body["input_json"], reportBytes: Data = body["report_json"]
            guard inputBytes.count <= maximumInputBytes, reportBytes.count <= maximumReportBytes,
                  LedgerCSV.hash(inputBytes) == metadata.inputHash, LedgerCSV.hash(reportBytes) == metadata.reportHash else {
                throw OptionLabStoreError.corruptedStorage
            }
            let input = try JSONDecoder().decode(PortfolioGreeksInput.self, from: inputBytes)
            let report = try JSONDecoder().decode(PortfolioGreeksReport.self, from: reportBytes)
            guard input.id == id, report.input == input, report.schemaVersion == (row["model_version"] as String),
                  summary(report, inputHash: metadata.inputHash, reportHash: metadata.reportHash) == metadata else {
                throw OptionLabStoreError.corruptedStorage
            }
            try Task.checkCancellation()
            let replay = try PortfolioGreeksEngine.replay(report)
            guard replay == report else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: id, report: replay, inputHash: metadata.inputHash, reportHash: metadata.reportHash, replayMatched: true)
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
}

extension DatabaseStore {
    static let portfolioGreeksMigration = DatabaseMigration(identifier: "options-lab.v4") { db in
        // Additive. Existing source, experiment and daily bytes are not re-encoded.
        try db.execute(sql: """
            CREATE TABLE portfolio_greeks_catalog (
                report_id TEXT PRIMARY KEY NOT NULL, ledger_revision TEXT NOT NULL,
                input_hash TEXT NOT NULL CHECK(length(input_hash)=64),
                report_hash TEXT NOT NULL CHECK(length(report_hash)=64),
                model_version TEXT NOT NULL, numeric_policy_version TEXT NOT NULL,
                summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE portfolio_greeks_documents (
                report_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(report_id) REFERENCES portfolio_greeks_catalog(report_id) ON DELETE RESTRICT
            );
            """)
    }
}
