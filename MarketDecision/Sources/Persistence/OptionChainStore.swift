import Foundation
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine

/// Metadata only: catalog values never substitute for source validation on open.
public struct OptionChainSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let symbol: String
    public let providerID: String
    public let feedID: String
    public let synthetic: Bool
    public let status: OptionChainCaptureStatus
    public let contractCount: Int
    public let pageCount: Int
    public let contentHash: String
    public init(id: UUID, createdAt: Date, symbol: String, providerID: String, feedID: String, synthetic: Bool, status: OptionChainCaptureStatus,
                contractCount: Int, pageCount: Int, contentHash: String) {
        self.id = id; self.createdAt = createdAt; self.symbol = symbol
        self.providerID = providerID; self.feedID = feedID
        self.synthetic = synthetic; self.status = status
        self.contractCount = contractCount; self.pageCount = pageCount; self.contentHash = contentHash
    }
}

public struct SavedOptionChain: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let capture: OptionChainCapture
    public let contentHash: String
    public let replayMatched: Bool
    public init(id: UUID, capture: OptionChainCapture, contentHash: String, replayMatched: Bool) {
        self.id = id; self.capture = capture; self.contentHash = contentHash; self.replayMatched = replayMatched
    }
}

public protocol OptionChainStorage: Sendable {
    func revision() async throws -> UUID
    func save(_ capture: OptionChainCapture, expectedRevision: UUID) async throws -> SavedOptionChain
    func summaries() async throws -> [OptionChainSummary]
    func open(id: UUID) async throws -> SavedOptionChain
}

/// The immutable capture contains the original response bytes as well as their
/// normalized projection. Both are validated by replay before writing or opening.
/// Uses the same revision as experiments, daily studies and archive replacement:
/// a request started before clear/restore cannot adopt the later write baseline.
public actor OptionChainStore: OptionChainStorage {
    public static let maximumCaptureBytes = 32 * 1_024 * 1_024
    public static let maximumCaptures = 10_000
    private let database: DatabaseStore
    private var failNextSave = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .optionsLab else { throw OptionLabStoreError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .optionsLab) }
    public func revision() throws -> UUID { try database.read(OptionLabStore.revision) }
    public func save(_ capture: OptionChainCapture, expectedRevision: UUID) throws -> SavedOptionChain {
        try Task.checkCancellation()
        guard try revision() == expectedRevision else { throw OptionLabStoreError.staleRevision }
        try capture.validate()
        let bytes = try OptionDailyStore.encode(capture)
        guard bytes.count <= Self.maximumCaptureBytes else { throw OptionLabStoreError.budgetExceeded }
        let hash = LedgerCSV.hash(bytes), summary = Self.summary(capture, hash)
        let summaryBytes = try OptionDailyStore.encode(summary)
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            // Do not replace expectedRevision after validation or queueing.
            guard try OptionLabStore.revision(db) == expectedRevision else { throw OptionLabStoreError.staleRevision }
            if let existing = try Self.load(id: capture.id, db: db) {
                guard existing.capture == capture, existing.contentHash == hash else { throw OptionLabStoreError.conflictingSnapshot }
                return existing
            }
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_chain_catalog") ?? 0) < Self.maximumCaptures else {
                throw OptionLabStoreError.budgetExceeded
            }
            try Task.checkCancellation()
            try db.execute(sql: """
                INSERT INTO option_chain_catalog(capture_id,symbol,provider_id,feed_id,content_hash,summary_hash,summary_json)
                VALUES (?,?,?,?,?,?,?)
                """, arguments: [capture.id.uuidString, capture.symbol, capture.providerID, capture.feedID,
                                   hash, LedgerCSV.hash(summaryBytes), summaryBytes])
            try db.execute(sql: "INSERT INTO option_chain_documents(capture_id,capture_json) VALUES (?,?)",
                           arguments: [capture.id.uuidString, bytes])
            if inject { throw OptionLabStoreError.injectedFailure }
            try Task.checkCancellation()
            try db.execute(sql: "UPDATE option_lab_metadata SET revision=? WHERE singleton=1", arguments: [UUID().uuidString])
            guard db.changesCount == 1 else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: capture.id, capture: capture, contentHash: hash, replayMatched: true)
        }
    }
    public func summaries() throws -> [OptionChainSummary] {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_chain_catalog") ?? 0) <= Self.maximumCaptures else {
                throw OptionLabStoreError.budgetExceeded
            }
            return try Row.fetchAll(db, sql: Self.catalogQuery).map(Self.decodeSummary).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        }
    }
    public func open(id: UUID) throws -> SavedOptionChain {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try OptionLabStore.revision(db)
            guard let result = try Self.load(id: id, db: db) else { throw OptionLabStoreError.notFound }
            return result
        }
    }
    func injectFailureOnNextSave() { failNextSave = true }
    private static let catalogQuery = """
        SELECT c.*, EXISTS(SELECT 1 FROM option_chain_documents d WHERE d.capture_id=c.capture_id) AS has_document
        FROM option_chain_catalog c
        """
    private static func summary(_ capture: OptionChainCapture, _ hash: String) -> OptionChainSummary {
        .init(id: capture.id, createdAt: capture.createdAt, symbol: capture.symbol, providerID: capture.providerID,
              feedID: capture.feedID, synthetic: capture.synthetic, status: capture.snapshot.status,
              contractCount: capture.snapshot.contracts.count, pageCount: capture.pages.count, contentHash: hash)
    }
    private static func decodeSummary(_ row: Row) throws -> OptionChainSummary {
        do {
            try Task.checkCancellation()
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String),
                  (row["has_document"] as Bool) else { throw OptionLabStoreError.corruptedStorage }
            let value = try JSONDecoder().decode(OptionChainSummary.self, from: bytes)
            guard value.id.uuidString == (row["capture_id"] as String), value.symbol == (row["symbol"] as String),
                  value.providerID == (row["provider_id"] as String), value.feedID == (row["feed_id"] as String),
                  value.contentHash == (row["content_hash"] as String), value.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  value.contractCount >= 0, value.pageCount > 0, value.contentHash.count == 64,
                  !value.symbol.isEmpty, !value.providerID.isEmpty, !value.feedID.isEmpty else { throw OptionLabStoreError.corruptedStorage }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func load(id: UUID, db: Database) throws -> SavedOptionChain? {
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.capture_id=?", arguments: [id.uuidString]) else { return nil }
        let metadata = try decodeSummary(row)
        do {
            guard let bytes = try Data.fetchOne(db, sql: "SELECT capture_json FROM option_chain_documents WHERE capture_id=?", arguments: [id.uuidString]),
                  bytes.count <= maximumCaptureBytes, LedgerCSV.hash(bytes) == metadata.contentHash else { throw OptionLabStoreError.corruptedStorage }
            let capture = try JSONDecoder().decode(OptionChainCapture.self, from: bytes)
            try capture.validate()
            guard capture.id == id, summary(capture, metadata.contentHash) == metadata else { throw OptionLabStoreError.corruptedStorage }
            return .init(id: id, capture: capture, contentHash: metadata.contentHash, replayMatched: true)
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
}

extension DatabaseStore {
    static let optionChainMigration = DatabaseMigration(identifier: "options-lab.v3") { db in
        // Additive: all earlier experiment/daily/history bytes and revision survive.
        try db.execute(sql: """
            CREATE TABLE option_chain_catalog (
                capture_id TEXT PRIMARY KEY NOT NULL, symbol TEXT NOT NULL, provider_id TEXT NOT NULL, feed_id TEXT NOT NULL,
                content_hash TEXT NOT NULL CHECK(length(content_hash)=64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX option_chain_by_symbol ON option_chain_catalog(symbol,capture_id);
            CREATE TABLE option_chain_documents (
                capture_id TEXT PRIMARY KEY NOT NULL, capture_json BLOB NOT NULL,
                FOREIGN KEY(capture_id) REFERENCES option_chain_catalog(capture_id) ON DELETE RESTRICT
            );
            """)
    }
}
