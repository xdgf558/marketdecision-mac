import Foundation
import GRDB
import MarketAnalytics
import PortfolioEngine

public enum MarketStateStorageError: Error, Equatable, Sendable {
    case incompatiblePurpose, corruptedStorage, unsupportedFormat, corruptedArchive
    case budgetExceeded, staleRevision, invalidPlan, identityConflict, notFound, injectedFailure
}
public enum MarketDocumentKind: String, Codable, Equatable, Hashable, Sendable { case marketState, tradeAttribution }
/// Metadata contains no calculated score or PnL. Values are available only after
/// the selected body's hashes and complete deterministic replay have been checked.
public struct MarketStateSummary: Codable, Equatable, Sendable, Identifiable {
    /// Storage identity may differ for a retained conflicting copy. originalID
    /// remains the immutable input/report identity; neither body is rewritten.
    public let id: UUID
    public let originalID: UUID
    public let createdAt: Date
    public let kind: MarketDocumentKind
    public let containsSynthetic: Bool
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, originalID: UUID? = nil, createdAt: Date, kind: MarketDocumentKind, containsSynthetic: Bool, inputHash: String, reportHash: String) {
        self.id = id; self.originalID = originalID ?? id; self.createdAt = createdAt; self.kind = kind; self.containsSynthetic = containsSynthetic
        self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct SavedMarketState: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: MarketStateReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: MarketStateReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public struct SavedMarketAttribution: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: MarketTradeAttributionReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: MarketTradeAttributionReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public protocol MarketStateStorage: Sendable {
    func revision() async throws -> UUID
    func save(_ input: MarketStateInput, expectedRevision: UUID) async throws -> SavedMarketState
    func saveAttribution(_ input: MarketTradeAttributionInput, expectedRevision: UUID) async throws -> SavedMarketAttribution
    func summaries() async throws -> [MarketStateSummary]
    func open(id: UUID) async throws -> SavedMarketState
    func openAttribution(id: UUID) async throws -> SavedMarketAttribution
}

/// Frozen reports own all of their replay input; they never reference this cache.
/// Removing a cached source cannot change or invalidate an existing snapshot.
public struct MarketSourceCacheEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceID: String
    public let feedID: String
    public let evidenceReference: String
    public let retrievedAt: Date
    public let payload: Data
    public init(id: UUID, sourceID: String, feedID: String, evidenceReference: String, retrievedAt: Date, payload: Data) {
        self.id = id; self.sourceID = sourceID; self.feedID = feedID; self.evidenceReference = evidenceReference
        self.retrievedAt = retrievedAt; self.payload = payload
    }
}

/// This purpose-marked database cannot open or migrate research/options/ledger
/// files. Every mutation carries the caller's pre-computation SQLite revision.
public actor MarketStateStore: MarketStateStorage {
    public static let maximumInputBytes = 32 * 1_024 * 1_024
    public static let maximumReportBytes = 64 * 1_024 * 1_024
    public static let maximumReports = 10_000
    public static let maximumCacheEntryBytes = 32 * 1_024 * 1_024
    private let database: DatabaseStore
    private var failNextSave = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .marketState else { throw MarketStateStorageError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .marketState) }
    public func revision() throws -> UUID { try database.read(Self.revision) }
    public func save(_ input: MarketStateInput, expectedRevision: UUID) throws -> SavedMarketState {
        try requireRevision(expectedRevision)
        let inputBytes = try Self.encode(input)
        guard inputBytes.count <= Self.maximumInputBytes else { throw MarketStateStorageError.budgetExceeded }
        let report = try MarketStateEngine.calculate(input)
        let entry = try MarketStoredEntry.make(id: input.id, createdAt: input.createdAt, kind: .marketState,
            synthetic: report.containsSynthetic, input: inputBytes, report: Self.encode(report))
        let stored = try saveEntry(entry, expectedRevision: expectedRevision)
        return .init(id: stored.summary.id, report: report, inputHash: stored.summary.inputHash, reportHash: stored.summary.reportHash, replayMatched: true)
    }
    public func saveAttribution(_ input: MarketTradeAttributionInput, expectedRevision: UUID) throws -> SavedMarketAttribution {
        try requireRevision(expectedRevision)
        let inputBytes = try Self.encode(input)
        guard inputBytes.count <= Self.maximumInputBytes else { throw MarketStateStorageError.budgetExceeded }
        let report = try MarketTradeAttributionEngine.calculate(input)
        let entry = try MarketStoredEntry.make(id: input.id, createdAt: input.createdAt, kind: .tradeAttribution,
            synthetic: report.containsSynthetic, input: inputBytes, report: Self.encode(report))
        let stored = try saveEntry(entry, expectedRevision: expectedRevision)
        return .init(id: stored.summary.id, report: report, inputHash: stored.summary.inputHash, reportHash: stored.summary.reportHash, replayMatched: true)
    }
    public func summaries() throws -> [MarketStateSummary] {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try Self.revision(db)
            guard try Self.count("market_state_catalog", db) <= Self.maximumReports else { throw MarketStateStorageError.budgetExceeded }
            return try Row.fetchAll(db, sql: Self.catalogQuery).map(Self.decodeSummary).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        }
    }
    public func open(id: UUID) throws -> SavedMarketState {
        let entry = try database.read { db in _ = try Self.revision(db); return try Self.load(id, db) }
        guard let entry else { throw MarketStateStorageError.notFound }
        guard case .market(let report) = try entry.replay() else { throw MarketStateStorageError.unsupportedFormat }
        return .init(id: id, report: report, inputHash: entry.summary.inputHash, reportHash: entry.summary.reportHash, replayMatched: true)
    }
    public func openAttribution(id: UUID) throws -> SavedMarketAttribution {
        let entry = try database.read { db in _ = try Self.revision(db); return try Self.load(id, db) }
        guard let entry else { throw MarketStateStorageError.notFound }
        guard case .attribution(let report) = try entry.replay() else { throw MarketStateStorageError.unsupportedFormat }
        return .init(id: id, report: report, inputHash: entry.summary.inputHash, reportHash: entry.summary.reportHash, replayMatched: true)
    }
    public func cache(_ entry: MarketSourceCacheEntry, expectedRevision: UUID) throws {
        try requireRevision(expectedRevision)
        guard !entry.sourceID.isEmpty, !entry.feedID.isEmpty, !entry.evidenceReference.isEmpty,
              entry.retrievedAt.timeIntervalSinceReferenceDate.isFinite, !entry.payload.isEmpty,
              entry.payload.count <= Self.maximumCacheEntryBytes else { throw MarketStateStorageError.unsupportedFormat }
        let bytes = try Self.encode(entry), hash = LedgerCSV.hash(bytes)
        guard bytes.count <= Self.maximumCacheEntryBytes else { throw MarketStateStorageError.budgetExceeded }
        try database.transaction { db in
            try Self.check(expectedRevision, db)
            if let old = try Row.fetchOne(db, sql: "SELECT content_hash,source_json FROM market_state_source_cache WHERE source_id=?", arguments: [entry.id.uuidString]) {
                let oldBytes: Data = old["source_json"]
                guard LedgerCSV.hash(oldBytes) == (old["content_hash"] as String) else { throw MarketStateStorageError.corruptedStorage }
                guard oldBytes == bytes else { throw MarketStateStorageError.identityConflict }; return
            }
            guard try Self.count("market_state_source_cache", db) < Self.maximumReports else { throw MarketStateStorageError.budgetExceeded }
            try Task.checkCancellation()
            try db.execute(sql: "INSERT INTO market_state_source_cache(source_id,content_hash,source_json) VALUES (?,?,?)", arguments: [entry.id.uuidString, hash, bytes])
            try Self.bump(db)
        }
    }
    public func purgeCache(expectedRevision: UUID) throws {
        try requireRevision(expectedRevision)
        try database.transaction { db in
            try Self.check(expectedRevision, db); try Task.checkCancellation()
            try db.execute(sql: "DELETE FROM market_state_source_cache")
            if db.changesCount > 0 { try Self.bump(db) }
        }
    }
    func injectFailureOnNextSave() { failNextSave = true }
    private func requireRevision(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard try revision() == expected else { throw MarketStateStorageError.staleRevision }
    }
    private func saveEntry(_ entry: MarketStoredEntry, expectedRevision: UUID) throws -> MarketStoredEntry {
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            try Self.check(expectedRevision, db)
            // Exact immutable content may already live in a retained conflict
            // directory while the original ID still holds a different version.
            // Reuse that verified copy; never replace the original directory.
            if let raw = try String.fetchOne(db, sql: "SELECT document_id FROM market_state_catalog WHERE original_input_id=? AND kind=? AND input_hash=? AND report_hash=?",
                arguments: [entry.summary.originalID.uuidString, entry.summary.kind.rawValue, entry.summary.inputHash, entry.summary.reportHash]) {
                guard let id = UUID(uuidString: raw), let old = try Self.load(id, db), old.originKey == entry.originKey else { throw MarketStateStorageError.corruptedStorage }
                _ = try old.replay(); return old
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_macro_catalog WHERE document_id=?", arguments: [entry.summary.id.uuidString]) == 0 else { throw MarketStateStorageError.identityConflict }
            if let old = try Self.load(entry.summary.id, db) {
                _ = try old.replay()
                guard old == entry else { throw MarketStateStorageError.identityConflict }; return old
            }
            guard try Self.count("market_state_catalog", db) + Self.count("market_macro_catalog", db) < Self.maximumReports else { throw MarketStateStorageError.budgetExceeded }
            try Task.checkCancellation(); try entry.insert(db)
            if inject { throw MarketStateStorageError.injectedFailure }
            try Task.checkCancellation(); try Self.bump(db)
            return entry
        }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func count(_ table: String, _ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM " + table) ?? 0
    }
    static func revision(_ db: Database) throws -> UUID {
        guard try Int.fetchOne(db, sql: "PRAGMA application_id") == DatabasePurpose.marketState.applicationID else { throw MarketStateStorageError.incompatiblePurpose }
        guard try count("market_state_metadata", db) == 1,
              let raw = try String.fetchOne(db, sql: "SELECT revision FROM market_state_metadata WHERE singleton=1"),
              let revision = UUID(uuidString: raw), revision.uuidString == raw else { throw MarketStateStorageError.corruptedStorage }
        return revision
    }
    static func check(_ expected: UUID, _ db: Database) throws {
        guard try revision(db) == expected else { throw MarketStateStorageError.staleRevision }
    }
    @discardableResult static func bump(_ db: Database) throws -> UUID {
        let revision = UUID()
        try db.execute(sql: "UPDATE market_state_metadata SET revision=? WHERE singleton=1", arguments: [revision.uuidString])
        guard db.changesCount == 1 else { throw MarketStateStorageError.corruptedStorage }; return revision
    }
    static let catalogQuery = "SELECT c.*, EXISTS(SELECT 1 FROM market_state_documents d WHERE d.document_id=c.document_id) AS has_document FROM market_state_catalog c"
    static func decodeSummary(_ row: Row) throws -> MarketStateSummary {
        do {
            try Task.checkCancellation()
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String), row["has_document"] as Bool else { throw MarketStateStorageError.corruptedStorage }
            let summary = try JSONDecoder().decode(MarketStateSummary.self, from: bytes)
            guard summary.id.uuidString == (row["document_id"] as String), summary.originalID.uuidString == (row["original_input_id"] as String), summary.kind.rawValue == (row["kind"] as String),
                  summary.inputHash == (row["input_hash"] as String), summary.reportHash == (row["report_hash"] as String),
                  summary.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  [summary.inputHash, summary.reportHash].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw MarketStateStorageError.corruptedStorage }
            return summary
        } catch is CancellationError { throw CancellationError() }
        catch { throw MarketStateStorageError.corruptedStorage }
    }
    static func load(_ id: UUID, _ db: Database) throws -> MarketStoredEntry? {
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.document_id=?", arguments: [id.uuidString]) else { return nil }
        let summary = try decodeSummary(row)
        guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json FROM market_state_documents WHERE document_id=?", arguments: [id.uuidString]) else { throw MarketStateStorageError.corruptedStorage }
        let entry = MarketStoredEntry(summary: summary, summaryBytes: row["summary_json"], input: body["input_json"], report: body["report_json"])
        try entry.validateBytes(); return entry
    }
}

enum MarketReplayedDocument { case market(MarketStateReport), attribution(MarketTradeAttributionReport) }
struct MarketStoredEntry: Codable, Equatable, Sendable {
    let summary: MarketStateSummary
    let summaryBytes: Data
    let input: Data
    let report: Data
    var originKey: String { [summary.originalID.uuidString, summary.kind.rawValue, summary.inputHash, summary.reportHash].joined(separator: ":") }
    func retainedCopy(id: UUID) throws -> Self {
        let updated = MarketStateSummary(id: id, originalID: summary.originalID, createdAt: summary.createdAt, kind: summary.kind,
            containsSynthetic: summary.containsSynthetic, inputHash: summary.inputHash, reportHash: summary.reportHash)
        return .init(summary: updated, summaryBytes: try MarketStateStore.encode(updated), input: input, report: report)
    }
    func conflictStorageID() throws -> UUID {
        let digest = LedgerCSV.hash(Data(originKey.utf8))
        let characters = Array(digest.prefix(32))
        let value = String(characters[0..<8]) + "-" + String(characters[8..<12]) + "-" + String(characters[12..<16]) + "-" + String(characters[16..<20]) + "-" + String(characters[20..<32])
        guard let id = UUID(uuidString: value) else { throw MarketStateStorageError.corruptedStorage }; return id
    }
    static func make(id: UUID, createdAt: Date, kind: MarketDocumentKind, synthetic: Bool, input: Data, report: Data) throws -> Self {
        let summary = MarketStateSummary(id: id, createdAt: createdAt, kind: kind, containsSynthetic: synthetic,
            inputHash: LedgerCSV.hash(input), reportHash: LedgerCSV.hash(report))
        let entry = Self(summary: summary, summaryBytes: try MarketStateStore.encode(summary), input: input, report: report)
        try entry.validateBytes(); return entry
    }
    func validateBytes() throws {
        try Task.checkCancellation()
        guard input.count <= MarketStateStore.maximumInputBytes, report.count <= MarketStateStore.maximumReportBytes,
              summaryBytes.count <= 16_384 else { throw MarketStateStorageError.budgetExceeded }
        guard try JSONDecoder().decode(MarketStateSummary.self, from: summaryBytes) == summary,
              LedgerCSV.hash(input) == summary.inputHash, LedgerCSV.hash(report) == summary.reportHash,
              summary.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw MarketStateStorageError.corruptedStorage }
        if summary.id != summary.originalID {
            guard try summary.id == conflictStorageID() else { throw MarketStateStorageError.corruptedStorage }
        }
    }
    func replay() throws -> MarketReplayedDocument {
        do {
            try validateBytes()
            switch summary.kind {
            case .marketState:
                let inputValue = try JSONDecoder().decode(MarketStateInput.self, from: input)
                let value = try JSONDecoder().decode(MarketStateReport.self, from: report)
                guard value.input == inputValue, inputValue.id == summary.originalID, inputValue.createdAt == summary.createdAt,
                      value.containsSynthetic == summary.containsSynthetic else { throw MarketStateStorageError.corruptedStorage }
                let replay = try MarketStateEngine.replay(value)
                guard replay == value else { throw MarketStateStorageError.corruptedStorage }; return .market(replay)
            case .tradeAttribution:
                let inputValue = try JSONDecoder().decode(MarketTradeAttributionInput.self, from: input)
                let value = try JSONDecoder().decode(MarketTradeAttributionReport.self, from: report)
                guard value.input == inputValue, inputValue.id == summary.originalID, inputValue.createdAt == summary.createdAt,
                      value.containsSynthetic == summary.containsSynthetic else { throw MarketStateStorageError.corruptedStorage }
                let replay = try MarketTradeAttributionEngine.replay(value)
                guard replay == value else { throw MarketStateStorageError.corruptedStorage }; return .attribution(replay)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw MarketStateStorageError.corruptedStorage }
    }
    func insert(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO market_state_catalog(document_id,original_input_id,kind,input_hash,report_hash,summary_hash,summary_json) VALUES (?,?,?,?,?,?,?)",
            arguments: [summary.id.uuidString, summary.originalID.uuidString, summary.kind.rawValue, summary.inputHash, summary.reportHash, LedgerCSV.hash(summaryBytes), summaryBytes])
        try db.execute(sql: "INSERT INTO market_state_documents(document_id,input_json,report_json) VALUES (?,?,?)", arguments: [summary.id.uuidString, input, report])
    }
}

extension DatabaseStore {
    static let marketStateMigration = DatabaseMigration(identifier: "market-state.v1") { db in
        try db.execute(sql: """
            CREATE TABLE market_state_metadata (singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision TEXT NOT NULL);
            INSERT INTO market_state_metadata(singleton,revision) VALUES (1,'00000000-0000-0000-0000-000000000000');
            CREATE TABLE market_state_catalog (
                document_id TEXT PRIMARY KEY NOT NULL, original_input_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('marketState','tradeAttribution')),
                input_hash TEXT NOT NULL CHECK(length(input_hash)=64), report_hash TEXT NOT NULL CHECK(length(report_hash)=64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE market_state_documents (
                document_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(document_id) REFERENCES market_state_catalog(document_id) ON DELETE RESTRICT
            );
            CREATE UNIQUE INDEX market_state_origin_hash ON market_state_catalog(original_input_id,kind,input_hash,report_hash);
            CREATE TABLE market_state_source_cache (
                source_id TEXT PRIMARY KEY NOT NULL, content_hash TEXT NOT NULL CHECK(length(content_hash)=64), source_json BLOB NOT NULL
            );
            """)
    }
}
