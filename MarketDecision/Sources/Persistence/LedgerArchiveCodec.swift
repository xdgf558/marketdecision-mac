import Foundation
import GRDB
import PortfolioEngine

/// Closed, unencrypted two-entry ZIP profile. Byte/row/depth limits are accepted
/// document budgets, not a promise about process memory or blocking I/O latency.
public enum LedgerArchiveCodec {
    public static let maximumArchiveBytes = 128 * 1_024 * 1_024
    public static let maximumDecodedBytes = 256 * 1_024 * 1_024
    public static let maximumRows = 100_000
    public static let maximumDepth = 8
    static let format = "portfolio-ledger-archive.v1"
    struct Manifest: Codable, Equatable {
        let format: String
        let purpose: String
        let encrypted: Bool
        let stateHash: String
        let stateBytes: Int
    }
    static func encode(_ state:LedgerArchiveState) throws -> Data {
        try Task.checkCancellation()
        let bytes = try canonical(state)
        guard bytes.count < maximumArchiveBytes - 4096 else { throw LedgerArchiveError.budgetExceeded }
        let manifest = Manifest(format:format,purpose:"MDL1",encrypted:false,stateHash:LedgerCSV.hash(bytes),stateBytes:bytes.count)
        return try ResearchZIP.encode(["manifest.json":canonical(manifest),"research-state.json":bytes])
    }
    static func decode(_ data:Data) throws -> LedgerArchiveState {
        try Task.checkCancellation()
        guard data.count <= maximumArchiveBytes else { throw LedgerArchiveError.budgetExceeded }
        let files = try ResearchZIP.decode(data)
        guard let manifestBytes = files["manifest.json"],let stateBytes = files["research-state.json"] else { throw LedgerArchiveError.unsupportedFormat }
        let manifest = try JSONDecoder().decode(Manifest.self,from:manifestBytes)
        guard manifest.format == format,manifest.purpose == "MDL1",!manifest.encrypted else { throw LedgerArchiveError.unsupportedFormat }
        guard try canonical(manifest) == manifestBytes,manifest.stateBytes == stateBytes.count,
              manifest.stateHash == LedgerCSV.hash(stateBytes) else { throw LedgerArchiveError.corruptedArchive }
        let state = try JSONDecoder().decode(LedgerArchiveState.self,from:stateBytes)
        guard try canonical(state) == stateBytes else { throw LedgerArchiveError.corruptedArchive }
        try state.validateShape()
        return state
    }
    static func canonical<T:Encodable>(_ value:T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

enum LedgerArchiveValue: Codable, Equatable, Sendable {
    case text(String), integer(Int64), blob(Data)
    var sqlValue:DatabaseValue {
        switch self { case .text(let v): v.databaseValue; case .integer(let v): v.databaseValue; case .blob(let v): v.databaseValue }
    }
    func text() throws -> String { guard case .text(let value) = self else { throw LedgerArchiveError.corruptedArchive }; return value }
    func blob() throws -> Data { guard case .blob(let value) = self else { throw LedgerArchiveError.corruptedArchive }; return value }
    func integer() throws -> Int64 { guard case .integer(let value) = self else { throw LedgerArchiveError.corruptedArchive }; return value }
}
struct LedgerArchiveTable: Codable, Equatable, Sendable { let name:String; var rows:[[LedgerArchiveValue]] }
struct LedgerArchiveTableDefinition: Sendable {
    let name:String
    let columns:[String]
    let types:[String]
    init(_ name:String,_ columns:String,_ types:String) { self.name = name; self.columns = columns.components(separatedBy:","); self.types = types.map(String.init) }
}
struct LedgerArchiveState: Codable, Equatable, Sendable {
    let format:String
    let ledgerRevision:UUID
    let performanceRevision:UUID
    var tables:[LedgerArchiveTable]
    static let definitions:[LedgerArchiveTableDefinition] = [
        .init("ledger_accounts","account_id,currency,content_hash,account_json","tttb"),
        .init("ledger_sources","source_id,raw_hash,metadata_hash,metadata_json,raw_bytes","tttbb"),
        .init("ledger_batches","batch_id,source_id,content_hash,batch_json","tttb"),
        .init("ledger_events","event_id,account_id,identity_key,audit_sequence,effective_at_json,source_id,source_row,batch_id,content_hash,comparison_hash,event_json","tttibtitttb"),
        .init("performance_inputs","input_hash,ledger_revision,engine_version,parameters_version,numeric_policy_version,input_json,request_hash,request_json","tttttbtb"),
        .init("performance_report_catalog","report_id,account_id,ledger_revision,input_hash,report_hash,summary_hash,summary_json","ttttttb"),
        .init("performance_report_documents","report_id,report_json","tb"),
        .init("ledger_archive_origins","archive_hash,archive_bytes","tb"),
        .init("ledger_archive_batch_links","batch_id,archive_hash,original_batch_id","ttt"),
        .init("ledger_archive_conflicts","conflict_id,archive_hash,summary_hash,summary_json,archive_bytes","tttbb")
    ]
    func rows(_ name:String) throws -> [[LedgerArchiveValue]] {
        guard let table = tables.first(where: { $0.name == name }) else { throw LedgerArchiveError.corruptedArchive }; return table.rows
    }
    var counts:LedgerArchiveCounts {
        func count(_ name:String)->Int { tables.first(where: { $0.name == name })?.rows.count ?? 0 }
        return .init(accounts:count("ledger_accounts"),events:count("ledger_events"),batches:count("ledger_batches"),reports:count("performance_report_catalog"),conflicts:count("ledger_archive_conflicts"))
    }
    func validateShape() throws {
        guard format == "portfolio-ledger-state.v1",tables.map(\.name) == Self.definitions.map(\.name),
              tables.reduce(0, { $0 + $1.rows.count }) <= LedgerArchiveCodec.maximumRows else { throw LedgerArchiveError.unsupportedFormat }
        for (table,definition) in zip(tables,Self.definitions) {
            var keys:Set<String> = []
            for row in table.rows {
                try Task.checkCancellation()
                guard row.count == definition.columns.count else { throw LedgerArchiveError.corruptedArchive }
                guard keys.insert(try row[0].text()).inserted else { throw LedgerArchiveError.corruptedArchive }
                for (value,type) in zip(row,definition.types) {
                    switch (value,type) { case (.text,"t"),(.blob,"b"),(.integer,"i"): break
                    default: throw LedgerArchiveError.corruptedArchive }
                }
            }
            let orderedKeys = try table.rows.map { try $0[0].text() }
            guard orderedKeys == orderedKeys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) else { throw LedgerArchiveError.corruptedArchive }
        }
    }
    static func capture(_ db:Database) throws -> LedgerArchiveState {
        let status = try LedgerArchiveStore.metadata(db)
        let tables = try definitions.map { definition in
            try LedgerArchiveTable(name:definition.name,rows:captureRows(definition,db:db))
        }
        let result = LedgerArchiveState(format:"portfolio-ledger-state.v1",ledgerRevision:status.ledgerRevision,performanceRevision:status.performanceRevision,tables:tables)
        try result.validateShape(); return result
    }
    static func captureRows(_ definition:LedgerArchiveTableDefinition,db:Database,matching:String? = nil) throws -> [[LedgerArchiveValue]] {
        let suffix = matching == nil ? " ORDER BY \(definition.columns[0])":" WHERE \(definition.columns[0]) = ?"
        let arguments = StatementArguments(matching.map { [$0] } ?? [])
        let rows = try Row.fetchAll(db,sql:"SELECT \(definition.columns.joined(separator:",")) FROM \(definition.name)" + suffix,arguments:arguments)
        return try rows.map { row in
            try definition.types.enumerated().map { index,type in
                let value:DatabaseValue = row[index]
                switch (value.storage,type) {
                case (.string(let value),"t"): return .text(value)
                case (.int64(let value),"i"): return .integer(value)
                case (.blob(let value),"b"): return .blob(value)
                default: throw LedgerArchiveError.corruptedStorage
                }
            }
        }
    }
    func insert(_ db:Database) throws {
        try validateShape()
        for (table,definition) in zip(tables,Self.definitions) {
            for row in table.rows { try Self.insert(row,definition:definition,db:db) }
        }
    }
    static func insert(_ row:[LedgerArchiveValue],definition:LedgerArchiveTableDefinition,db:Database) throws {
        try Task.checkCancellation()
        let placeholders = Array(repeating:"?",count:definition.columns.count).joined(separator:",")
        try db.execute(sql:"INSERT INTO \(definition.name)(\(definition.columns.joined(separator:","))) VALUES (\(placeholders))",arguments:StatementArguments(row.map(\.sqlValue)))
    }
    static func clear(_ db:Database) throws {
        for definition in definitions.reversed() { try db.execute(sql:"DELETE FROM \(definition.name)") }
    }
}

/// A validation operation shares a hash cache and cumulative traversal budget.
/// Parent packages remain exact bytes; no archive path is extracted on disk.
final class LedgerArchiveValidation {
    private var states:[String:LedgerArchiveState] = [:]
    private var heights:[String:Int] = [:]
    private var bytes = 0
    func decode(_ data:Data,depth:Int = 0) throws -> LedgerArchiveState {
        guard depth <= LedgerArchiveCodec.maximumDepth else { throw LedgerArchiveError.budgetExceeded }
        let hash = LedgerCSV.hash(data)
        if let state = states[hash] {
            guard let height = heights[hash],height <= LedgerArchiveCodec.maximumDepth - depth else { throw LedgerArchiveError.budgetExceeded }
            return state
        }
        guard data.count <= LedgerArchiveCodec.maximumDecodedBytes - bytes else { throw LedgerArchiveError.budgetExceeded }
        bytes += data.count
        let state = try LedgerArchiveCodec.decode(data)
        let height = try validate(state,depth:depth)
        states[hash] = state; heights[hash] = height; return state
    }
    @discardableResult
    func validate(_ state:LedgerArchiveState,depth:Int = 0) throws -> Int {
        guard depth <= LedgerArchiveCodec.maximumDepth else { throw LedgerArchiveError.budgetExceeded }
        var height = 0
        try state.validateShape()
        let scratch = try DatabaseStore(path:":memory:",purpose:.portfolioLedger)
        try scratch.transaction { db in
            try state.insert(db)
            try db.execute(sql:"UPDATE ledger_metadata SET revision = ?",arguments:[state.ledgerRevision.uuidString])
            try db.execute(sql:"UPDATE performance_metadata SET revision = ?",arguments:[state.performanceRevision.uuidString])
            _ = try LedgerStore.load(db)
            let reports = try state.rows("performance_report_catalog")
            guard reports.count == (try state.rows("performance_inputs")).count,
                  reports.count == (try state.rows("performance_report_documents")).count,
                  try Row.fetchAll(db,sql:"PRAGMA foreign_key_check").isEmpty else { throw LedgerArchiveError.corruptedArchive }
            for row in reports {
                guard let id = UUID(uuidString:try row[0].text()) else { throw LedgerArchiveError.corruptedArchive }
                _ = try PerformanceStore.loadReport(id:id,db)
            }
        }
        var origins:[String:LedgerArchiveState] = [:]
        for row in try state.rows("ledger_archive_origins") {
            let hash = try row[0].text(),raw = try row[1].blob()
            guard LedgerCSV.hash(raw) == hash else { throw LedgerArchiveError.corruptedArchive }
            origins[hash] = try decode(raw,depth:depth+1)
            guard let childHeight = heights[hash] else { throw LedgerArchiveError.corruptedArchive }
            height = max(height,childHeight + 1)
        }
        let localBatches = try Dictionary(uniqueKeysWithValues:state.rows("ledger_batches").map { (try $0[0].text(),$0) })
        let localSources = try Dictionary(uniqueKeysWithValues:state.rows("ledger_sources").map { (try $0[0].text(),$0) })
        let localEvents = try Dictionary(uniqueKeysWithValues:state.rows("ledger_events").map { (try $0[0].text(),$0) })
        for link in try state.rows("ledger_archive_batch_links") {
            guard let origin = origins[try link[1].text()],let local = localBatches[try link[0].text()],
                  let original = try origin.rows("ledger_batches").first(where: { try $0[0].text() == link[2].text() }) else { throw LedgerArchiveError.corruptedArchive }
            let localBatch = try JSONDecoder().decode(LedgerStore.Batch.self,from:local[3].blob())
            let sourceBatch = try JSONDecoder().decode(LedgerStore.Batch.self,from:original[3].blob())
            guard localBatch.sourceID == sourceBatch.sourceID,localBatch.rows.count == sourceBatch.rows.count,
                  let localSource = localSources[localBatch.sourceID],
                  let source = try origin.rows("ledger_sources").first(where: { try $0[0].text() == sourceBatch.sourceID }),localSource == source else { throw LedgerArchiveError.corruptedArchive }
            let originalEvents = try Dictionary(uniqueKeysWithValues:origin.rows("ledger_events").map { (try $0[0].text(),$0) })
            for (a,b) in zip(localBatch.rows,sourceBatch.rows) {
                guard a.rowIndex == b.rowIndex,a.eventID == b.eventID,
                      (a.disposition == "excluded") == (b.disposition == "excluded"),
                      !(b.disposition == "duplicate" && a.disposition == "new") else { throw LedgerArchiveError.corruptedArchive }
                if a.disposition == "new" {
                    guard let id = a.eventID,let localEvent = localEvents[id],let originalEvent = originalEvents[id],
                          localEvent[10] == originalEvent[10],localEvent[4] == originalEvent[4],
                          localEvent[5] == originalEvent[5],localEvent[6] == originalEvent[6],
                          try localEvent[7].text() == localBatch.id else { throw LedgerArchiveError.corruptedArchive }
                }
            }
        }
        for row in try state.rows("ledger_archive_conflicts") {
            _ = try conflict(row,depth:depth)
            guard let childHeight = heights[try row[1].text()] else { throw LedgerArchiveError.corruptedArchive }
            height = max(height,childHeight + 1)
        }
        guard height <= LedgerArchiveCodec.maximumDepth - depth else { throw LedgerArchiveError.budgetExceeded }
        return height
    }
    func conflict(_ row:[LedgerArchiveValue],depth:Int = 0) throws -> LedgerArchiveConflictSummary {
        let raw = try row[4].blob(),summaryBytes = try row[3].blob()
        let summary = try JSONDecoder().decode(LedgerArchiveConflictSummary.self,from:summaryBytes)
        guard summary.id.uuidString == (try row[0].text()),summary.sourceHash == (try row[1].text()),
              LedgerCSV.hash(raw) == summary.sourceHash,LedgerCSV.hash(summaryBytes) == (try row[2].text()),
              !summary.reason.isEmpty,summary.createdAt.timeIntervalSince1970.isFinite else { throw LedgerArchiveError.corruptedArchive }
        let origin = try decode(raw,depth:depth+1)
        guard summary.counts == origin.counts else { throw LedgerArchiveError.corruptedArchive }
        return summary
    }
}
