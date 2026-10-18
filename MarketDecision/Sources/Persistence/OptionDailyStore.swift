import Foundation
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine
import OptionsAnalytics

/// Catalog metadata deliberately excludes calculated values. Opening a record
/// always checks every stored byte and repeats the original calculation.
public struct OptionDailySummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let session: MarketDate
    public let symbol: String
    public let origin: OptionLabOrigin
    public let contractCount: Int
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, createdAt: Date, session: MarketDate, symbol: String, origin: OptionLabOrigin, contractCount: Int, inputHash: String, reportHash: String) {
        self.id = id; self.createdAt = createdAt; self.session = session; self.symbol = symbol; self.origin = origin
        self.contractCount = contractCount; self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct OptionVolatilityHistorySummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let session: MarketDate
    public let symbol: String
    public let origin: OptionLabOrigin
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, createdAt: Date, session: MarketDate, symbol: String, origin: OptionLabOrigin, inputHash: String, reportHash: String) {
        self.id = id; self.createdAt = createdAt; self.session = session; self.symbol = symbol; self.origin = origin
        self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct SavedOptionDaily: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: OptionDailyReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: OptionDailyReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public struct SavedOptionVolatilityHistory: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: OptionVolatilityHistoryReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: OptionVolatilityHistoryReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public protocol OptionDailyStorage: Sendable {
    func revision() async throws -> UUID
    func saveDaily(_ input: OptionDailyInput, expectedRevision: UUID) async throws -> SavedOptionDaily
    func dailySummaries() async throws -> [OptionDailySummary]
    func openDaily(id: UUID) async throws -> SavedOptionDaily
    func saveHistory(_ input: OptionVolatilityHistoryInput, expectedRevision: UUID) async throws -> SavedOptionVolatilityHistory
    func historySummaries() async throws -> [OptionVolatilityHistorySummary]
    func openHistory(id: UUID) async throws -> SavedOptionVolatilityHistory
}

/// Shares the options database revision with experiments and archive replacement.
/// The original baseline crosses calculation and the transaction; an old writer
/// cannot acquire the post-clear revision. No live provider or cache is involved.
public actor OptionDailyStore: OptionDailyStorage {
    public static let maximumDailyInputBytes = 4 * 1_024 * 1_024
    public static let maximumDailyReportBytes = 8 * 1_024 * 1_024
    public static let maximumHistoryBytes = 64 * 1_024 * 1_024
    public static let maximumRecords = 10_000
    private let database: DatabaseStore
    private var failNextSave = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .optionsLab else { throw OptionLabStoreError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .optionsLab) }
    public func revision() throws -> UUID { try database.read(OptionLabStore.revision) }
    public func saveDaily(_ input: OptionDailyInput, expectedRevision: UUID) throws -> SavedOptionDaily {
        try Task.checkCancellation(); try check(expectedRevision)
        let report = try OptionDailyEngine.calculate(input)
        let inputBytes = try Self.encode(input), reportBytes = try Self.encode(report)
        guard inputBytes.count <= Self.maximumDailyInputBytes, reportBytes.count <= Self.maximumDailyReportBytes else { throw OptionLabStoreError.budgetExceeded }
        let inputHash = LedgerCSV.hash(inputBytes), reportHash = LedgerCSV.hash(reportBytes)
        let metadata = Self.summary(report, inputHash, reportHash), summaryBytes = try Self.encode(metadata)
        let chainBytes = try Self.encode(report.chainSummary)
        let contracts = try report.contractSummaries.map { ($0.contractID, try Self.encode($0)) }
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            try Self.check(expectedRevision, db)
            if let existing = try Self.loadDaily(id: input.id, db: db) {
                guard existing.inputHash == inputHash, existing.reportHash == reportHash,
                      existing.report.input == input else { throw OptionLabStoreError.conflictingSnapshot }
                return existing
            }
            try Self.checkCount("option_daily_catalog", db)
            try db.execute(sql: "INSERT INTO option_daily_catalog(snapshot_id,symbol,session,input_hash,report_hash,summary_hash,summary_json) VALUES (?,?,?,?,?,?,?)",
                arguments: [input.id.uuidString, input.symbol, input.session.iso8601, inputHash, reportHash, LedgerCSV.hash(summaryBytes), summaryBytes])
            try db.execute(sql: "INSERT INTO option_daily_documents(snapshot_id,input_json,report_json) VALUES (?,?,?)", arguments: [input.id.uuidString, inputBytes, reportBytes])
            try db.execute(sql: "INSERT INTO option_daily_chains(snapshot_id,summary_hash,summary_json) VALUES (?,?,?)", arguments: [input.id.uuidString, LedgerCSV.hash(chainBytes), chainBytes])
            for (id, bytes) in contracts {
                try Task.checkCancellation()
                try db.execute(sql: "INSERT INTO option_daily_contracts(snapshot_id,contract_id,summary_hash,summary_json) VALUES (?,?,?,?)", arguments: [input.id.uuidString, id, LedgerCSV.hash(bytes), bytes])
            }
            if inject { throw OptionLabStoreError.injectedFailure }
            try Self.advance(db)
            return SavedOptionDaily(id: input.id, report: report, inputHash: inputHash, reportHash: reportHash, replayMatched: true)
        }
    }
    public func dailySummaries() throws -> [OptionDailySummary] {
        try database.read { db in
            _ = try OptionLabStore.revision(db)
            let rows = try Row.fetchAll(db, sql: Self.dailyCatalogQuery + " ORDER BY c.snapshot_id")
            guard rows.count <= Self.maximumRecords else { throw OptionLabStoreError.budgetExceeded }
            return try rows.map(Self.decodeDailySummary).sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        }
    }
    public func openDaily(id: UUID) throws -> SavedOptionDaily {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard let value = try Self.loadDaily(id: id, db: db) else { throw OptionLabStoreError.notFound }; return value
        }
    }
    public func saveHistory(_ input: OptionVolatilityHistoryInput, expectedRevision: UUID) throws -> SavedOptionVolatilityHistory {
        try Task.checkCancellation(); try check(expectedRevision)
        let report = try OptionVolatilityHistoryEngine.calculate(input)
        let inputBytes = try Self.encode(input), reportBytes = try Self.encode(report)
        guard inputBytes.count <= Self.maximumHistoryBytes, reportBytes.count <= Self.maximumHistoryBytes else { throw OptionLabStoreError.budgetExceeded }
        let inputHash = LedgerCSV.hash(inputBytes), reportHash = LedgerCSV.hash(reportBytes)
        let metadata = Self.summary(report, inputHash, reportHash), summaryBytes = try Self.encode(metadata)
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            try Self.check(expectedRevision, db)
            if let existing = try Self.loadHistory(id: input.id, db: db) {
                guard existing.inputHash == inputHash, existing.reportHash == reportHash,
                      existing.report.input == input else { throw OptionLabStoreError.conflictingSnapshot }
                return existing
            }
            try Self.checkCount("option_history_catalog", db)
            try db.execute(sql: "INSERT INTO option_history_catalog(report_id,symbol,session,input_hash,report_hash,summary_hash,summary_json) VALUES (?,?,?,?,?,?,?)",
                arguments: [input.id.uuidString, metadata.symbol, metadata.session.iso8601, inputHash, reportHash, LedgerCSV.hash(summaryBytes), summaryBytes])
            try db.execute(sql: "INSERT INTO option_history_documents(report_id,input_json,report_json) VALUES (?,?,?)", arguments: [input.id.uuidString, inputBytes, reportBytes])
            if inject { throw OptionLabStoreError.injectedFailure }
            try Self.advance(db)
            return SavedOptionVolatilityHistory(id: input.id, report: report, inputHash: inputHash, reportHash: reportHash, replayMatched: true)
        }
    }
    public func historySummaries() throws -> [OptionVolatilityHistorySummary] {
        try database.read { db in
            _ = try OptionLabStore.revision(db)
            let rows = try Row.fetchAll(db, sql: Self.historyCatalogQuery + " ORDER BY c.report_id")
            guard rows.count <= Self.maximumRecords else { throw OptionLabStoreError.budgetExceeded }
            return try rows.map(Self.decodeHistorySummary).sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        }
    }
    public func openHistory(id: UUID) throws -> SavedOptionVolatilityHistory {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard let value = try Self.loadHistory(id: id, db: db) else { throw OptionLabStoreError.notFound }; return value
        }
    }
    func injectFailureOnNextSave() { failNextSave = true }
    private func check(_ expected: UUID) throws { guard try revision() == expected else { throw OptionLabStoreError.staleRevision } }
    private static func check(_ expected: UUID, _ db: Database) throws {
        guard try OptionLabStore.revision(db) == expected else { throw OptionLabStoreError.staleRevision }
        try Task.checkCancellation()
    }
    private static func checkCount(_ table: String, _ db: Database) throws {
        guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM " + table) ?? 0) < maximumRecords else { throw OptionLabStoreError.budgetExceeded }
    }
    private static func advance(_ db: Database) throws {
        try Task.checkCancellation()
        try db.execute(sql: "UPDATE option_lab_metadata SET revision = ? WHERE singleton = 1", arguments: [UUID().uuidString])
        guard db.changesCount == 1 else { throw OptionLabStoreError.corruptedStorage }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    private static func summary(_ report: OptionDailyReport, _ inputHash: String, _ reportHash: String) -> OptionDailySummary {
        .init(id: report.input.id, createdAt: report.input.createdAt, session: report.input.session, symbol: report.input.symbol,
            origin: report.containsSynthetic ? .synthetic : .manual, contractCount: report.contractSummaries.count, inputHash: inputHash, reportHash: reportHash)
    }
    private static func summary(_ report: OptionVolatilityHistoryReport, _ inputHash: String, _ reportHash: String) -> OptionVolatilityHistorySummary {
        return .init(id: report.input.id, createdAt: report.input.createdAt, session: report.input.current.input.session,
            symbol: report.input.current.input.symbol, origin: report.containsSynthetic ? .synthetic : .manual, inputHash: inputHash, reportHash: reportHash)
    }
    private static let dailyCatalogQuery = """
        SELECT c.*, EXISTS(SELECT 1 FROM option_daily_documents d WHERE d.snapshot_id=c.snapshot_id) AS has_document,
        EXISTS(SELECT 1 FROM option_daily_chains s WHERE s.snapshot_id=c.snapshot_id) AS has_chain,
        (SELECT COUNT(*) FROM option_daily_contracts k WHERE k.snapshot_id=c.snapshot_id) AS contract_count
        FROM option_daily_catalog c
        """
    private static let historyCatalogQuery = """
        SELECT c.*, EXISTS(SELECT 1 FROM option_history_documents d WHERE d.report_id=c.report_id) AS has_document
        FROM option_history_catalog c
        """
    private static func decodeDailySummary(_ row: Row) throws -> OptionDailySummary {
        do {
            try Task.checkCancellation()
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String) else { throw OptionLabStoreError.corruptedStorage }
            let value = try JSONDecoder().decode(OptionDailySummary.self, from: bytes)
            guard value.id.uuidString == (row["snapshot_id"] as String), value.symbol == (row["symbol"] as String), value.session.iso8601 == (row["session"] as String),
                  value.inputHash == (row["input_hash"] as String), value.reportHash == (row["report_hash"] as String),
                  value.inputHash.count == 64, value.reportHash.count == 64, !value.symbol.isEmpty, value.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  (row["has_document"] as Bool), (row["has_chain"] as Bool), value.contractCount == (row["contract_count"] as Int) else { throw OptionLabStoreError.corruptedStorage }
            return value
        } catch is CancellationError { throw CancellationError() } catch { throw OptionLabStoreError.corruptedStorage }
    }
    private static func decodeHistorySummary(_ row: Row) throws -> OptionVolatilityHistorySummary {
        do {
            try Task.checkCancellation()
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String) else { throw OptionLabStoreError.corruptedStorage }
            let value = try JSONDecoder().decode(OptionVolatilityHistorySummary.self, from: bytes)
            guard value.id.uuidString == (row["report_id"] as String), value.symbol == (row["symbol"] as String), value.session.iso8601 == (row["session"] as String),
                  value.inputHash == (row["input_hash"] as String), value.reportHash == (row["report_hash"] as String),
                  value.inputHash.count == 64, value.reportHash.count == 64, !value.symbol.isEmpty, value.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  (row["has_document"] as Bool) else { throw OptionLabStoreError.corruptedStorage }
            return value
        } catch is CancellationError { throw CancellationError() } catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func loadDaily(id: UUID, db: Database) throws -> SavedOptionDaily? {
        guard let row = try Row.fetchOne(db, sql: dailyCatalogQuery + " WHERE c.snapshot_id=?", arguments: [id.uuidString]) else { return nil }
        let metadata = try decodeDailySummary(row)
        do {
            guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json FROM option_daily_documents WHERE snapshot_id=?", arguments: [id.uuidString]),
                  let chain = try Row.fetchOne(db, sql: "SELECT summary_hash,summary_json FROM option_daily_chains WHERE snapshot_id=?", arguments: [id.uuidString]) else { throw OptionLabStoreError.corruptedStorage }
            let inputBytes: Data = body["input_json"], reportBytes: Data = body["report_json"], chainBytes: Data = chain["summary_json"]
            guard inputBytes.count <= maximumDailyInputBytes, reportBytes.count <= maximumDailyReportBytes,
                  LedgerCSV.hash(inputBytes) == metadata.inputHash, LedgerCSV.hash(reportBytes) == metadata.reportHash,
                  LedgerCSV.hash(chainBytes) == (chain["summary_hash"] as String) else { throw OptionLabStoreError.corruptedStorage }
            let input = try JSONDecoder().decode(OptionDailyInput.self, from: inputBytes)
            let report = try JSONDecoder().decode(OptionDailyReport.self, from: reportBytes)
            guard input.id == id, report.input == input, summary(report, metadata.inputHash, metadata.reportHash) == metadata,
                  try encode(report.chainSummary) == chainBytes else { throw OptionLabStoreError.corruptedStorage }
            let contracts = try Row.fetchAll(db, sql: "SELECT contract_id,summary_hash,summary_json FROM option_daily_contracts WHERE snapshot_id=? ORDER BY contract_id", arguments: [id.uuidString])
            let expected = report.contractSummaries.sorted { $0.contractID.utf8.lexicographicallyPrecedes($1.contractID.utf8) }
            guard contracts.count == expected.count else { throw OptionLabStoreError.corruptedStorage }
            for (stored, value) in zip(contracts, expected) {
                try Task.checkCancellation()
                let bytes: Data = stored["summary_json"]
                guard value.contractID == (stored["contract_id"] as String), LedgerCSV.hash(bytes) == (stored["summary_hash"] as String),
                      try encode(value) == bytes else { throw OptionLabStoreError.corruptedStorage }
            }
            let replay = try OptionDailyEngine.replay(report)
            guard replay == report else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: id, report: replay, inputHash: metadata.inputHash, reportHash: metadata.reportHash, replayMatched: true)
        } catch is CancellationError { throw CancellationError() } catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func loadHistory(id: UUID, db: Database) throws -> SavedOptionVolatilityHistory? {
        guard let row = try Row.fetchOne(db, sql: historyCatalogQuery + " WHERE c.report_id=?", arguments: [id.uuidString]) else { return nil }
        let metadata = try decodeHistorySummary(row)
        do {
            guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json FROM option_history_documents WHERE report_id=?", arguments: [id.uuidString]) else { throw OptionLabStoreError.corruptedStorage }
            let inputBytes: Data = body["input_json"], reportBytes: Data = body["report_json"]
            guard inputBytes.count <= maximumHistoryBytes, reportBytes.count <= maximumHistoryBytes,
                  LedgerCSV.hash(inputBytes) == metadata.inputHash, LedgerCSV.hash(reportBytes) == metadata.reportHash else { throw OptionLabStoreError.corruptedStorage }
            let input = try JSONDecoder().decode(OptionVolatilityHistoryInput.self, from: inputBytes)
            let report = try JSONDecoder().decode(OptionVolatilityHistoryReport.self, from: reportBytes)
            guard input.id == id, report.input == input, summary(report, metadata.inputHash, metadata.reportHash) == metadata else { throw OptionLabStoreError.corruptedStorage }
            let replay = try OptionVolatilityHistoryEngine.replay(report)
            guard replay == report else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: id, report: replay, inputHash: metadata.inputHash, reportHash: metadata.reportHash, replayMatched: true)
        } catch is CancellationError { throw CancellationError() } catch { throw OptionLabStoreError.corruptedStorage }
    }
}

extension DatabaseStore {
    static let optionDailyMigration = DatabaseMigration(identifier: "options-lab.v2") { db in
        // Additive: experiment v1/v2/v3 bytes and the shared revision are untouched.
        try db.execute(sql: """
            CREATE TABLE option_daily_catalog (
                snapshot_id TEXT PRIMARY KEY NOT NULL, symbol TEXT NOT NULL, session TEXT NOT NULL,
                input_hash TEXT NOT NULL CHECK(length(input_hash)=64), report_hash TEXT NOT NULL CHECK(length(report_hash)=64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX option_daily_by_session ON option_daily_catalog(symbol,session,snapshot_id);
            CREATE TABLE option_daily_documents (
                snapshot_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES option_daily_catalog(snapshot_id) ON DELETE RESTRICT
            );
            CREATE TABLE option_daily_chains (
                snapshot_id TEXT PRIMARY KEY NOT NULL, summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES option_daily_catalog(snapshot_id) ON DELETE RESTRICT
            );
            CREATE TABLE option_daily_contracts (
                snapshot_id TEXT NOT NULL, contract_id TEXT NOT NULL, summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL,
                PRIMARY KEY(snapshot_id,contract_id), FOREIGN KEY(snapshot_id) REFERENCES option_daily_catalog(snapshot_id) ON DELETE RESTRICT
            );
            CREATE TABLE option_history_catalog (
                report_id TEXT PRIMARY KEY NOT NULL, symbol TEXT NOT NULL, session TEXT NOT NULL,
                input_hash TEXT NOT NULL CHECK(length(input_hash)=64), report_hash TEXT NOT NULL CHECK(length(report_hash)=64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX option_history_by_session ON option_history_catalog(symbol,session,report_id);
            CREATE TABLE option_history_documents (
                report_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(report_id) REFERENCES option_history_catalog(report_id) ON DELETE RESTRICT
            );
            """)
    }
}
