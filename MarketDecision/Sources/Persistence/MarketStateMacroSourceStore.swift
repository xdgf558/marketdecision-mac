import Foundation
import GRDB
import MacroProviders
import MarketAnalytics
import PortfolioEngine

public enum MacroDocumentKind: String, Codable, Equatable, Sendable { case source, marketBridge }
/// Directory data deliberately excludes observation values and calculated market scores.
public struct MacroSourceSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let originalID: UUID
    public let createdAt: Date
    public let kind: MacroDocumentKind
    public let format: MacroSourceFormat?
    public let series: [MacroSeriesID]
    public let sourceID: String?
    public let feedID: String?
    public let revisionID: String?
    public let sourceCount: Int
    public let observationCount: Int
    public let containsSynthetic: Bool
    public let contentKey: String
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, originalID: UUID, createdAt: Date, kind: MacroDocumentKind,
                format: MacroSourceFormat?, series: [MacroSeriesID], sourceID: String?, feedID: String?, revisionID: String?,
                sourceCount: Int, observationCount: Int, containsSynthetic: Bool, contentKey: String, inputHash: String, reportHash: String) {
        self.id = id; self.originalID = originalID; self.createdAt = createdAt; self.kind = kind; self.format = format; self.series = series
        self.sourceID = sourceID; self.feedID = feedID; self.revisionID = revisionID; self.sourceCount = sourceCount; self.observationCount = observationCount
        self.containsSynthetic = containsSynthetic; self.contentKey = contentKey; self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct SavedMacroSource: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: MacroSourceReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: MacroSourceReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public struct SavedMacroMarketBridge: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: MacroMarketBridgeReport
    public let inputHash: String
    public let reportHash: String
    public let replayMatched: Bool
    public init(id: UUID, report: MacroMarketBridgeReport, inputHash: String, reportHash: String, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash; self.replayMatched = replayMatched
    }
}
public protocol MacroSourceStorage: Sendable {
    func revision() async throws -> UUID
    func summaries() async throws -> [MacroSourceSummary]
    func save(_ input: MacroImportInput, expectedRevision: UUID) async throws -> SavedMacroSource
    func open(id: UUID) async throws -> SavedMacroSource
    func saveBridge(_ input: MacroMarketBridgeInput, expectedRevision: UUID) async throws -> SavedMacroMarketBridge
    func openBridge(id: UUID) async throws -> SavedMacroMarketBridge
}
/// Only the newly generated directory identity and generation timestamp are excluded.
/// Retrieval, cutoff, declared origin, raw bytes, releases and all descriptor fields remain bound.
public enum MacroSourceContentIdentity {
    public static func hash(_ input: MacroImportInput) throws -> String {
        try hashEncoded(input)
    }
    public static func hash(_ input: MacroMarketBridgeInput) throws -> String {
        try hashEncoded(input)
    }
    private static func hashEncoded<T: Encodable>(_ input: T) throws -> String {
        let data = try MarketStateStore.encode(input)
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MarketStateStorageError.corruptedStorage }
        fields.removeValue(forKey: "id"); fields.removeValue(forKey: "createdAt")
        return LedgerCSV.hash(try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
}

/// Frozen source bytes and typed vintages belong to reports, never to the purgeable source cache.
/// No transport, credential access or supplier qualification is installed by this store.
public actor MacroSourceStore: MacroSourceStorage {
    private let database: DatabaseStore
    private var failNextSave = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .marketState else { throw MarketStateStorageError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .marketState) }
    public func revision() throws -> UUID { try database.read(MarketStateStore.revision) }
    public func summaries() throws -> [MacroSourceSummary] {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try MarketStateStore.revision(db)
            guard try MarketStateStore.count("market_macro_catalog", db) <= MarketStateStore.maximumReports else { throw MarketStateStorageError.budgetExceeded }
            return try Row.fetchAll(db, sql: Self.catalogQuery).map(Self.decodeSummary).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        }
    }
    public func save(_ input: MacroImportInput, expectedRevision: UUID) throws -> SavedMacroSource {
        try requireRevision(expectedRevision)
        let inputBytes = try MarketStateStore.encode(input)
        guard inputBytes.count <= MarketStateStore.maximumInputBytes else { throw MarketStateStorageError.budgetExceeded }
        let report = try MacroSourceEngine.evaluate(input)
        let entry = try MacroStoredEntry.make(input: input, report: report)
        let saved = try saveEntry(entry, expectedRevision: expectedRevision)
        guard case .source(let replayed) = try saved.replay() else { throw MarketStateStorageError.corruptedStorage }
        return .init(id: saved.summary.id, report: replayed, inputHash: saved.summary.inputHash, reportHash: saved.summary.reportHash, replayMatched: true)
    }
    public func saveBridge(_ input: MacroMarketBridgeInput, expectedRevision: UUID) throws -> SavedMacroMarketBridge {
        try requireRevision(expectedRevision)
        guard try MarketStateStore.encode(input).count <= MarketStateStore.maximumInputBytes else { throw MarketStateStorageError.budgetExceeded }
        let report = try MacroMarketBridgeEngine.evaluate(input)
        let entry = try MacroStoredEntry.make(input: input, report: report)
        let saved = try saveEntry(entry, expectedRevision: expectedRevision)
        guard case .bridge(let replayed) = try saved.replay() else { throw MarketStateStorageError.corruptedStorage }
        return .init(id: saved.summary.id, report: replayed, inputHash: saved.summary.inputHash, reportHash: saved.summary.reportHash, replayMatched: true)
    }
    public func open(id: UUID) throws -> SavedMacroSource {
        let entry = try database.read { db in _ = try MarketStateStore.revision(db); return try Self.load(id, db) }
        guard let entry else { throw MarketStateStorageError.notFound }
        guard case .source(let report) = try entry.replay() else { throw MarketStateStorageError.unsupportedFormat }
        return .init(id: id, report: report, inputHash: entry.summary.inputHash, reportHash: entry.summary.reportHash, replayMatched: true)
    }
    public func openBridge(id: UUID) throws -> SavedMacroMarketBridge {
        let entry = try database.read { db in _ = try MarketStateStore.revision(db); return try Self.load(id, db) }
        guard let entry else { throw MarketStateStorageError.notFound }
        guard case .bridge(let report) = try entry.replay() else { throw MarketStateStorageError.unsupportedFormat }
        return .init(id: id, report: report, inputHash: entry.summary.inputHash, reportHash: entry.summary.reportHash, replayMatched: true)
    }
    func injectFailureOnNextSave() { failNextSave = true }
    private func requireRevision(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard try revision() == expected else { throw MarketStateStorageError.staleRevision }
    }
    private func saveEntry(_ entry: MacroStoredEntry, expectedRevision: UUID) throws -> MacroStoredEntry {
        _ = try entry.replay()
        try MacroStoredEntry.validateVersions([entry])
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            try MarketStateStore.check(expectedRevision, db)
            if let raw = try String.fetchOne(db, sql: "SELECT document_id FROM market_macro_catalog WHERE kind=? AND content_key=?", arguments: [entry.summary.kind.rawValue, entry.summary.contentKey]) {
                guard let id = UUID(uuidString: raw), let old = try Self.load(id, db), old.summary.contentKey == entry.summary.contentKey,
                      old.summary.kind == entry.summary.kind else { throw MarketStateStorageError.corruptedStorage }
                _ = try old.replay(); return old
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_state_catalog WHERE document_id=?", arguments: [entry.summary.id.uuidString]) == 0 else { throw MarketStateStorageError.identityConflict }
            if let old = try Self.load(entry.summary.id, db) {
                _ = try old.replay()
                guard old == entry else { throw MarketStateStorageError.identityConflict }; return old
            }
            guard try MarketStateStore.count("market_macro_catalog", db) + MarketStateStore.count("market_state_catalog", db) < MarketStateStore.maximumReports else { throw MarketStateStorageError.budgetExceeded }
            // Only overlapping source vintages are loaded; a directory listing never reads bodies.
            for otherID in try Self.overlappingDocuments(entry, db) {
                guard let other = try Self.load(otherID, db) else { throw MarketStateStorageError.corruptedStorage }
                try MacroStoredEntry.validateVersions([other, entry])
            }
            try Task.checkCancellation(); try entry.insert(db)
            if inject { throw MarketStateStorageError.injectedFailure }
            try Task.checkCancellation(); try MarketStateStore.bump(db)
            return entry
        }
    }
    static let catalogQuery = "SELECT c.*, EXISTS(SELECT 1 FROM market_macro_documents d WHERE d.document_id=c.document_id) AS has_document FROM market_macro_catalog c"
    static func decodeSummary(_ row: Row) throws -> MacroSourceSummary {
        do {
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String), row["has_document"] as Bool else { throw MarketStateStorageError.corruptedStorage }
            let value = try JSONDecoder().decode(MacroSourceSummary.self, from: bytes)
            guard value.id.uuidString == (row["document_id"] as String), value.originalID.uuidString == (row["original_input_id"] as String),
                  value.kind.rawValue == (row["kind"] as String), value.contentKey == (row["content_key"] as String),
                  value.inputHash == (row["input_hash"] as String), value.reportHash == (row["report_hash"] as String),
                  value.createdAt.timeIntervalSinceReferenceDate.isFinite, value.sourceCount >= 1, value.observationCount >= 0,
                  [value.inputHash, value.reportHash, value.contentKey].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw MarketStateStorageError.corruptedStorage }
            return value
        } catch { throw MarketStateStorageError.corruptedStorage }
    }
    static func load(_ id: UUID, _ db: Database) throws -> MacroStoredEntry? {
        do { return try loadValidated(id, db) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MarketStateStorageError.corruptedStorage }
    }
    private static func loadValidated(_ id: UUID, _ db: Database) throws -> MacroStoredEntry? {
        try Task.checkCancellation()
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.document_id=?", arguments: [id.uuidString]) else { return nil }
        let summary = try decodeSummary(row)
        guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json FROM market_macro_documents WHERE document_id=?", arguments: [id.uuidString]) else { throw MarketStateStorageError.corruptedStorage }
        let entry = MacroStoredEntry(summary: summary, summaryBytes: row["summary_json"], input: body["input_json"], report: body["report_json"])
        _ = try entry.replay()
        let expected = try entry.sourceReports()
        let sources = try Row.fetchAll(db, sql: "SELECT * FROM market_macro_sources WHERE document_id=? ORDER BY source_key", arguments: [id.uuidString])
        guard sources.count == expected.count else { throw MarketStateStorageError.corruptedStorage }
        for (row, report) in zip(sources, expected) {
            let input = report.input, descriptor = input.descriptor, payload: Data = row["payload"]
            guard row["source_key"] as String == input.id.uuidString, row["source_id"] as String == descriptor.sourceID,
                  row["feed_id"] as String == descriptor.feedID, row["source_format"] as String == descriptor.format.rawValue,
                  row["revision_id"] as String == descriptor.revisionID, row["content_hash"] as String == report.contentSHA256,
                  LedgerCSV.hash(payload) == report.contentSHA256, payload == input.rawData else { throw MarketStateStorageError.corruptedStorage }
            let records = try Row.fetchAll(db, sql: "SELECT * FROM market_macro_observations WHERE document_id=? AND source_key=? ORDER BY series,observation_id,vintage_id", arguments: [id.uuidString, input.id.uuidString])
            let observations = Self.sorted(report.observations)
            guard records.count == observations.count else { throw MarketStateStorageError.corruptedStorage }
            for (record, observation) in zip(records, observations) {
                let bytes: Data = record["record_json"]
                guard record["series"] as String == observation.series.rawValue, record["observation_id"] as String == observation.observationID,
                      record["vintage_id"] as String == observation.vintageID, record["observation_date"] as String == observation.observationDate,
                      record["version_key"] as String == (try versionKey(input, observation)),
                      record["record_hash"] as String == LedgerCSV.hash(bytes),
                      try JSONDecoder().decode(MacroSourceObservation.self, from: bytes) == observation,
                      try MarketStateStore.encode(observation) == bytes else { throw MarketStateStorageError.corruptedStorage }
            }
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_macro_observations WHERE document_id=?", arguments: [id.uuidString]) == expected.reduce(0, { $0 + $1.observations.count }) else { throw MarketStateStorageError.corruptedStorage }
        return entry
    }
    static func sorted(_ observations: [MacroSourceObservation]) -> [MacroSourceObservation] {
        observations.sorted { [$0.series.rawValue, $0.observationID, $0.vintageID].lexicographicallyPrecedes([$1.series.rawValue, $1.observationID, $1.vintageID]) }
    }
    static func versionKey(_ input: MacroImportInput, _ observation: MacroSourceObservation) throws -> String {
        let d = input.descriptor
        return LedgerCSV.hash(try MarketStateStore.encode([d.sourceID, d.feedID, d.basisVersion, d.population ?? "", d.cftcContractCode ?? "", d.cftcScope?.rawValue ?? "", observation.series.rawValue, observation.observationID, observation.vintageID]))
    }
    private static func overlappingDocuments(_ entry: MacroStoredEntry, _ db: Database) throws -> Set<UUID> {
        var result = Set<UUID>()
        for source in try entry.sourceReports() {
            for observation in source.observations {
                let key = try versionKey(source.input, observation)
                for raw in try String.fetchAll(db, sql: "SELECT DISTINCT document_id FROM market_macro_observations WHERE version_key=?", arguments: [key]) {
                    guard let id = UUID(uuidString: raw) else { throw MarketStateStorageError.corruptedStorage }; result.insert(id)
                }
            }
        }
        return result
    }
}

enum MacroReplayedDocument { case source(MacroSourceReport), bridge(MacroMarketBridgeReport) }
struct MacroStoredEntry: Codable, Equatable, Sendable {
    let summary: MacroSourceSummary
    let summaryBytes: Data
    let input: Data
    let report: Data
    var originKey: String { [summary.originalID.uuidString, summary.kind.rawValue, summary.inputHash, summary.reportHash].joined(separator: ":") }
    var contentKey: String { summary.kind.rawValue + ":" + summary.contentKey }
    static func make(input: MacroImportInput, report: MacroSourceReport) throws -> Self {
        let bytes = try MarketStateStore.encode(input), reportBytes = try MarketStateStore.encode(report), d = input.descriptor
        let summary = MacroSourceSummary(id: input.id, originalID: input.id, createdAt: input.createdAt, kind: .source, format: d.format,
            series: d.series, sourceID: d.sourceID, feedID: d.feedID, revisionID: d.revisionID, sourceCount: 1,
            observationCount: report.observations.count, containsSynthetic: report.containsSynthetic, contentKey: try MacroSourceContentIdentity.hash(input),
            inputHash: LedgerCSV.hash(bytes), reportHash: LedgerCSV.hash(reportBytes))
        return .init(summary: summary, summaryBytes: try MarketStateStore.encode(summary), input: bytes, report: reportBytes)
    }
    static func make(input: MacroMarketBridgeInput, report: MacroMarketBridgeReport) throws -> Self {
        let bytes = try MarketStateStore.encode(input), reportBytes = try MarketStateStore.encode(report)
        let summary = MacroSourceSummary(id: input.id, originalID: input.id, createdAt: input.createdAt, kind: .marketBridge, format: nil,
            series: Array(Set(input.sources.flatMap { $0.input.descriptor.series })).sorted { $0.rawValue < $1.rawValue }, sourceID: nil, feedID: nil,
            revisionID: nil, sourceCount: input.sources.count, observationCount: input.sources.reduce(0) { $0 + $1.observations.count },
            containsSynthetic: report.containsSynthetic, contentKey: try MacroSourceContentIdentity.hash(input), inputHash: LedgerCSV.hash(bytes), reportHash: LedgerCSV.hash(reportBytes))
        return .init(summary: summary, summaryBytes: try MarketStateStore.encode(summary), input: bytes, report: reportBytes)
    }
    func retainedCopy(id: UUID) throws -> Self {
        let s = summary
        let copy = MacroSourceSummary(id: id, originalID: s.originalID, createdAt: s.createdAt, kind: s.kind, format: s.format, series: s.series,
            sourceID: s.sourceID, feedID: s.feedID, revisionID: s.revisionID, sourceCount: s.sourceCount, observationCount: s.observationCount,
            containsSynthetic: s.containsSynthetic, contentKey: s.contentKey, inputHash: s.inputHash, reportHash: s.reportHash)
        return .init(summary: copy, summaryBytes: try MarketStateStore.encode(copy), input: input, report: report)
    }
    func conflictStorageID() throws -> UUID {
        let digest = Array(LedgerCSV.hash(Data(originKey.utf8)).prefix(32))
        let raw = String(digest[0..<8]) + "-" + String(digest[8..<12]) + "-" + String(digest[12..<16]) + "-" + String(digest[16..<20]) + "-" + String(digest[20..<32])
        guard let id = UUID(uuidString: raw) else { throw MarketStateStorageError.corruptedStorage }; return id
    }
    func replay() throws -> MacroReplayedDocument {
        do {
            try Task.checkCancellation()
            guard input.count <= MarketStateStore.maximumInputBytes, report.count <= MarketStateStore.maximumReportBytes, summaryBytes.count <= 16_384,
                  LedgerCSV.hash(input) == summary.inputHash, LedgerCSV.hash(report) == summary.reportHash,
                  try MarketStateStore.encode(summary) == summaryBytes else { throw MarketStateStorageError.corruptedStorage }
            let result: MacroReplayedDocument, expected: MacroStoredEntry
            switch summary.kind {
            case .source:
                let value = try JSONDecoder().decode(MacroSourceReport.self, from: report), original = try JSONDecoder().decode(MacroImportInput.self, from: input)
                guard value.input == original else { throw MarketStateStorageError.corruptedStorage }
                result = .source(try MacroSourceEngine.replay(value)); expected = try .make(input: original, report: value)
            case .marketBridge:
                let value = try JSONDecoder().decode(MacroMarketBridgeReport.self, from: report), original = try JSONDecoder().decode(MacroMarketBridgeInput.self, from: input)
                guard value.input == original else { throw MarketStateStorageError.corruptedStorage }
                result = .bridge(try MacroMarketBridgeEngine.replay(value)); expected = try .make(input: original, report: value)
            }
            let adjusted = summary.id == summary.originalID ? expected : try expected.retainedCopy(id: conflictStorageID())
            guard adjusted == self else { throw MarketStateStorageError.corruptedStorage }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw MarketStateStorageError.corruptedStorage }
    }
    func sourceReports() throws -> [MacroSourceReport] {
        let sources: [MacroSourceReport]
        switch summary.kind {
        case .source: sources = [try JSONDecoder().decode(MacroSourceReport.self, from: report)]
        case .marketBridge: sources = try JSONDecoder().decode(MacroMarketBridgeReport.self, from: report).input.sources
        }
        guard Set(sources.map(\.input.id)).count == sources.count else { throw MarketStateStorageError.corruptedStorage }
        return sources.sorted { $0.input.id.uuidString < $1.input.id.uuidString }
    }
    static func validateVersions(_ entries: [Self]) throws {
        var versions: [String: MacroSourceObservation] = [:]
        for entry in entries {
            for source in try entry.sourceReports() {
                for value in source.observations {
                    let key = try MacroSourceStore.versionKey(source.input, value)
                    if let old = versions[key] {
                        guard old.series == value.series, old.observationID == value.observationID, old.observationDate == value.observationDate,
                              old.vintageID == value.vintageID, old.vintageStart == value.vintageStart, old.vintageEnd == value.vintageEnd,
                              old.unit == value.unit, old.value == value.value, old.rawFields == value.rawFields, old.transformation == value.transformation, old.missingReason == value.missingReason
                        else { throw MarketStateStorageError.identityConflict }
                        if let oldRelease = old.release, let release = value.release, oldRelease != release { throw MarketStateStorageError.identityConflict }
                        if old.release == nil, value.release != nil { versions[key] = value }
                    } else { versions[key] = value }
                }
            }
        }
    }
    func insert(_ db: Database) throws {
        _ = try replay()
        try db.execute(sql: "INSERT INTO market_macro_catalog(document_id,original_input_id,kind,content_key,input_hash,report_hash,summary_hash,summary_json) VALUES (?,?,?,?,?,?,?,?)",
            arguments: [summary.id.uuidString, summary.originalID.uuidString, summary.kind.rawValue, summary.contentKey, summary.inputHash, summary.reportHash, LedgerCSV.hash(summaryBytes), summaryBytes])
        try db.execute(sql: "INSERT INTO market_macro_documents(document_id,input_json,report_json) VALUES (?,?,?)", arguments: [summary.id.uuidString, input, report])
        for source in try sourceReports() {
            try Task.checkCancellation()
            let i = source.input, d = i.descriptor
            try db.execute(sql: "INSERT INTO market_macro_sources(document_id,source_key,source_id,feed_id,source_format,revision_id,content_hash,payload) VALUES (?,?,?,?,?,?,?,?)",
                arguments: [summary.id.uuidString, i.id.uuidString, d.sourceID, d.feedID, d.format.rawValue, d.revisionID, source.contentSHA256, i.rawData])
            for observation in source.observations {
                let bytes = try MarketStateStore.encode(observation)
                try db.execute(sql: "INSERT INTO market_macro_observations(document_id,source_key,series,observation_id,vintage_id,observation_date,version_key,record_hash,record_json) VALUES (?,?,?,?,?,?,?,?,?)",
                    arguments: [summary.id.uuidString, i.id.uuidString, observation.series.rawValue, observation.observationID, observation.vintageID, observation.observationDate,
                        try MacroSourceStore.versionKey(i, observation), LedgerCSV.hash(bytes), bytes])
            }
        }
    }
}

extension DatabaseStore {
    static let marketMacroSourceMigration = DatabaseMigration(identifier: "market-state.v2") { db in
        try db.execute(sql: """
            CREATE TABLE market_macro_catalog (
                document_id TEXT PRIMARY KEY NOT NULL, original_input_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('source','marketBridge')),
                content_key TEXT NOT NULL CHECK(length(content_key)=64), input_hash TEXT NOT NULL CHECK(length(input_hash)=64),
                report_hash TEXT NOT NULL CHECK(length(report_hash)=64), summary_hash TEXT NOT NULL CHECK(length(summary_hash)=64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE UNIQUE INDEX market_macro_content ON market_macro_catalog(kind,content_key);
            CREATE TABLE market_macro_documents (
                document_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(document_id) REFERENCES market_macro_catalog(document_id) ON DELETE RESTRICT
            );
            CREATE TABLE market_macro_sources (
                document_id TEXT NOT NULL, source_key TEXT NOT NULL, source_id TEXT NOT NULL, feed_id TEXT NOT NULL,
                source_format TEXT NOT NULL, revision_id TEXT NOT NULL, content_hash TEXT NOT NULL CHECK(length(content_hash)=64), payload BLOB NOT NULL,
                PRIMARY KEY(document_id,source_key), FOREIGN KEY(document_id) REFERENCES market_macro_catalog(document_id) ON DELETE RESTRICT
            );
            CREATE TABLE market_macro_observations (
                document_id TEXT NOT NULL, source_key TEXT NOT NULL, series TEXT NOT NULL, observation_id TEXT NOT NULL, vintage_id TEXT NOT NULL,
                observation_date TEXT NOT NULL, version_key TEXT NOT NULL CHECK(length(version_key)=64), record_hash TEXT NOT NULL CHECK(length(record_hash)=64), record_json BLOB NOT NULL,
                PRIMARY KEY(document_id,source_key,series,observation_id,vintage_id),
                FOREIGN KEY(document_id,source_key) REFERENCES market_macro_sources(document_id,source_key) ON DELETE RESTRICT
            );
            CREATE INDEX market_macro_versions ON market_macro_observations(version_key,document_id);
            """)
    }
}
