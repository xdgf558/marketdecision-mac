import Foundation
import GRDB
import PortfolioEngine

/// Versioned unencrypted, stored-entry ZIP. Only an MDQ1 options state is valid;
/// CSV/Markdown and archives for research/ledger databases are never restorable.
/// Limits constrain accepted documents, not process RSS or blocking I/O duration.
public enum OptionLabArchiveCodec {
    public static let maximumArchiveBytes = 128 * 1_024 * 1_024
    public static let maximumRows = 100_000
    static let format = "options-lab-archive.v3"
    static let chainFormat = "options-lab-archive.v2"
    static let legacyFormat = "options-lab-archive.v1"
    struct Manifest: Codable, Equatable {
        let format: String
        let purpose: String
        let encrypted: Bool
        let stateHash: String
        let stateBytes: Int
        let embeddedLedgerBases: Int
        let ledgerBasisScope: String
    }
    static let ledgerBasisScope = "Embedded historical account and event evidence only; does not restore portfolio-ledger.sqlite or credentials."
    static func encode(_ state: OptionLabArchiveState) throws -> Data {
        try Task.checkCancellation()
        guard state.format == OptionLabArchiveState.format else { throw OptionLabArchiveError.unsupportedFormat }
        try state.validateShape()
        let bytes = try canonical(state)
        guard bytes.count < maximumArchiveBytes - 4096 else { throw OptionLabArchiveError.budgetExceeded }
        let manifest = Manifest(format: format, purpose: "MDQ1", encrypted: false, stateHash: LedgerCSV.hash(bytes),
            stateBytes: bytes.count, embeddedLedgerBases: state.counts.embeddedLedgerBases, ledgerBasisScope: ledgerBasisScope)
        return try ResearchZIP.encode(["manifest.json": canonical(manifest), "research-state.json": bytes])
    }
    static func decode(_ data: Data) throws -> OptionLabArchiveState {
        try Task.checkCancellation()
        guard data.count <= maximumArchiveBytes else { throw OptionLabArchiveError.budgetExceeded }
        do {
            let files = try ResearchZIP.decode(data)
            guard let manifestBytes = files["manifest.json"], let stateBytes = files["research-state.json"] else { throw OptionLabArchiveError.unsupportedFormat }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
            guard [format, chainFormat, legacyFormat].contains(manifest.format), manifest.purpose == "MDQ1", !manifest.encrypted,
                  manifest.ledgerBasisScope == ledgerBasisScope else { throw OptionLabArchiveError.unsupportedFormat }
            guard try canonical(manifest) == manifestBytes, manifest.stateBytes == stateBytes.count,
                  manifest.stateHash == LedgerCSV.hash(stateBytes) else { throw OptionLabArchiveError.corruptedArchive }
            let state = try JSONDecoder().decode(OptionLabArchiveState.self, from: stateBytes)
            guard try canonical(state) == stateBytes, manifest.embeddedLedgerBases == state.counts.embeddedLedgerBases else { throw OptionLabArchiveError.corruptedArchive }
            guard (manifest.format == format && state.format == OptionLabArchiveState.format)
                || (manifest.format == chainFormat && state.format == OptionLabArchiveState.chainFormat)
                || (manifest.format == legacyFormat && state.format == OptionLabArchiveState.legacyFormat) else { throw OptionLabArchiveError.unsupportedFormat }
            // Verify the original v1/v2 bytes and exact versioned table catalog before
            // an in-memory upgrade. Existing frozen body bytes stay intact.
            try state.validateShape(); return try state.upgraded()
        } catch is CancellationError { throw CancellationError() }
        catch let error as OptionLabArchiveError { throw error }
        catch { throw OptionLabArchiveError.corruptedArchive }
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data { try OptionDailyStore.encode(value) }
}

enum OptionLabArchiveValue: Codable, Equatable, Sendable {
    case text(String), blob(Data), null
    var sqlValue: DatabaseValue {
        switch self { case .text(let value): value.databaseValue; case .blob(let value): value.databaseValue; case .null: .null }
    }
    func text() throws -> String { guard case .text(let value) = self else { throw OptionLabArchiveError.corruptedArchive }; return value }
}
struct OptionLabArchiveTable: Codable, Equatable, Sendable { let name: String; var rows: [[OptionLabArchiveValue]] }
struct OptionLabArchiveDefinition: Sendable {
    let name: String
    let columns: [String]
    let types: [String]
    let keyCount: Int
    init(_ name: String, _ columns: String, _ types: String, keys: Int = 1) {
        self.name = name; self.columns = columns.components(separatedBy: ","); self.types = types.map(String.init); self.keyCount = keys
    }
    func key(_ row: [OptionLabArchiveValue]) throws -> String {
        let parts = try row.prefix(keyCount).map { try $0.text() }
        return try String(decoding: OptionLabArchiveCodec.canonical(parts), as: UTF8.self)
    }
}
struct OptionLabArchiveState: Codable, Equatable, Sendable {
    static let format = "options-lab-state.v3"
    static let chainFormat = "options-lab-state.v2"
    static let legacyFormat = "options-lab-state.v1"
    let format: String
    let revision: UUID
    var tables: [OptionLabArchiveTable]
    // Upper-case types permit NULL, solely for the pre-existing optional basis.
    static let legacyDefinitions: [OptionLabArchiveDefinition] = [
        .init("option_lab_catalog", "snapshot_id,input_hash,report_hash,model_reference_hash,parameter_reference_hash,numeric_policy_version,summary_hash,summary_json", "tttttttb"),
        .init("option_lab_documents", "snapshot_id,input_json,report_json,ledger_basis_json,ledger_basis_hash", "tbbBT"),
        .init("option_daily_catalog", "snapshot_id,symbol,session,input_hash,report_hash,summary_hash,summary_json", "ttttttb"),
        .init("option_daily_documents", "snapshot_id,input_json,report_json", "tbb"),
        .init("option_daily_chains", "snapshot_id,summary_hash,summary_json", "ttb"),
        .init("option_daily_contracts", "snapshot_id,contract_id,summary_hash,summary_json", "tttb", keys: 2),
        .init("option_history_catalog", "report_id,symbol,session,input_hash,report_hash,summary_hash,summary_json", "ttttttb"),
        .init("option_history_documents", "report_id,input_json,report_json", "tbb")
    ]
    static let chainDefinitions: [OptionLabArchiveDefinition] = [
        .init("option_chain_catalog", "capture_id,symbol,provider_id,feed_id,content_hash,summary_hash,summary_json", "ttttttb"),
        .init("option_chain_documents", "capture_id,capture_json", "tb")
    ]
    static let portfolioDefinitions: [OptionLabArchiveDefinition] = [
        .init("portfolio_greeks_catalog", "report_id,ledger_revision,input_hash,report_hash,model_version,numeric_policy_version,summary_hash,summary_json", "tttttttb"),
        .init("portfolio_greeks_documents", "report_id,input_json,report_json", "tbb")
    ]
    static let definitions = legacyDefinitions + chainDefinitions + portfolioDefinitions
    private var acceptedDefinitions: [OptionLabArchiveDefinition] {
        switch format {
        case Self.legacyFormat: Self.legacyDefinitions
        case Self.chainFormat: Self.legacyDefinitions + Self.chainDefinitions
        default: Self.definitions
        }
    }
    func rows(_ name: String) throws -> [[OptionLabArchiveValue]] {
        guard let table = tables.first(where: { $0.name == name }) else { throw OptionLabArchiveError.corruptedArchive }; return table.rows
    }
    var counts: OptionLabArchiveCounts {
        func rows(_ name: String) -> [[OptionLabArchiveValue]] { tables.first(where: { $0.name == name })?.rows ?? [] }
        let bases = rows("option_lab_documents").filter { $0.count == 5 && $0[3] != .null }.count
        return .init(experiments: rows("option_lab_catalog").count, dailySummaries: rows("option_daily_catalog").count,
            historyReports: rows("option_history_catalog").count, contractSummaries: rows("option_daily_contracts").count,
            embeddedLedgerBases: bases + rows("portfolio_greeks_catalog").count, chainCaptures: rows("option_chain_catalog").count,
            portfolioReports: rows("portfolio_greeks_catalog").count)
    }
    static func empty(revision: UUID) -> Self {
        .init(format: Self.format, revision: revision, tables: definitions.map { .init(name: $0.name, rows: []) })
    }
    func upgraded() throws -> Self {
        try validateShape()
        guard format != Self.format else { return self }
        let missing = format == Self.legacyFormat ? Self.chainDefinitions + Self.portfolioDefinitions : Self.portfolioDefinitions
        return .init(format: Self.format, revision: revision,
                     tables: tables + missing.map { .init(name: $0.name, rows: []) })
    }
    func validateShape() throws {
        guard [Self.format, Self.chainFormat, Self.legacyFormat].contains(format), tables.map(\.name) == acceptedDefinitions.map(\.name),
              tables.reduce(0, { $0 + $1.rows.count }) <= OptionLabArchiveCodec.maximumRows,
              counts.experiments <= OptionLabStore.maximumSnapshots, counts.dailySummaries <= OptionDailyStore.maximumRecords,
              counts.historyReports <= OptionDailyStore.maximumRecords,
              counts.chainCaptures <= OptionChainStore.maximumCaptures,
              counts.portfolioReports <= PortfolioGreeksStore.maximumReports else { throw OptionLabArchiveError.budgetExceeded }
        var totalBytes = 0
        for (table, definition) in zip(tables, acceptedDefinitions) {
            var keys: Set<String> = [], orderedKeys: [String] = []
            for row in table.rows {
                try Task.checkCancellation()
                guard row.count == definition.columns.count else { throw OptionLabArchiveError.corruptedArchive }
                for (value, type) in zip(row, definition.types) {
                    switch (value, type) {
                    case (.text(let text), "t"), (.text(let text), "T"): totalBytes += text.utf8.count
                    case (.blob(let data), "b"), (.blob(let data), "B"): totalBytes += data.count
                    case (.null, "T"), (.null, "B"): break
                    default: throw OptionLabArchiveError.corruptedArchive
                    }
                    guard totalBytes <= OptionLabArchiveCodec.maximumArchiveBytes else { throw OptionLabArchiveError.budgetExceeded }
                }
                let key = try definition.key(row)
                guard keys.insert(key).inserted else { throw OptionLabArchiveError.corruptedArchive }
                orderedKeys.append(key)
            }
            guard orderedKeys == orderedKeys.sorted(by: Self.byteOrder) else { throw OptionLabArchiveError.corruptedArchive }
        }
    }
    static func byteOrder(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    static func capture(_ db: Database) throws -> Self {
        let status = try OptionLabArchiveStore.metadata(db)
        var rowsBudget = OptionLabArchiveCodec.maximumRows, byteBudget = OptionLabArchiveCodec.maximumArchiveBytes
        let tables = try definitions.map { definition in
            let cursor = try Row.fetchCursor(db, sql: "SELECT " + definition.columns.joined(separator: ",") + " FROM " + definition.name)
            var result: [(String, [OptionLabArchiveValue])] = []
            while let row = try cursor.next() {
                try Task.checkCancellation(); rowsBudget -= 1
                guard rowsBudget >= 0 else { throw OptionLabArchiveError.budgetExceeded }
                let values: [OptionLabArchiveValue] = try definition.types.enumerated().map { index, type in
                    let value: DatabaseValue = row[index]
                    switch (value.storage, type) {
                    case (.string(let text), "t"), (.string(let text), "T"):
                        byteBudget -= text.utf8.count; return .text(text)
                    case (.blob(let bytes), "b"), (.blob(let bytes), "B"):
                        byteBudget -= bytes.count; return .blob(bytes)
                    case (.null, "T"), (.null, "B"): return .null
                    default: throw OptionLabArchiveError.corruptedStorage
                    }
                }
                guard byteBudget >= 0 else { throw OptionLabArchiveError.budgetExceeded }
                result.append((try definition.key(values), values))
            }
            return OptionLabArchiveTable(name: definition.name, rows: result.sorted { byteOrder($0.0, $1.0) }.map(\.1))
        }
        let result = Self(format: Self.format, revision: status.revision, tables: tables)
        try result.validateShape(); return result
    }
    func insert(_ db: Database) throws {
        try validateShape()
        guard format == Self.format else { throw OptionLabArchiveError.unsupportedFormat }
        for (table, definition) in zip(tables, Self.definitions) {
            let placeholders = Array(repeating: "?", count: definition.columns.count).joined(separator: ",")
            for row in table.rows {
                try Task.checkCancellation()
                try db.execute(sql: "INSERT INTO " + definition.name + "(" + definition.columns.joined(separator: ",") + ") VALUES (" + placeholders + ")",
                    arguments: StatementArguments(row.map(\.sqlValue)))
            }
        }
    }
    static func clear(_ db: Database) throws {
        // The MDQ1 marker and exact table catalog are checked before this closed list.
        // Neither other database files nor arbitrary table names are accepted.
        for definition in definitions.reversed() { try db.execute(sql: "DELETE FROM " + definition.name) }
    }
    func validateReplay() throws {
        try validateShape()
        let scratch = try DatabaseStore(path: ":memory:", purpose: .optionsLab)
        do {
            try scratch.transaction { db in
                try insert(db)
                guard counts.experiments == (try rows("option_lab_documents")).count,
                      counts.dailySummaries == (try rows("option_daily_documents")).count,
                      counts.dailySummaries == (try rows("option_daily_chains")).count,
                      counts.historyReports == (try rows("option_history_documents")).count,
                      counts.chainCaptures == (try rows("option_chain_documents")).count,
                      counts.portfolioReports == (try rows("portfolio_greeks_documents")).count,
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw OptionLabArchiveError.corruptedArchive }
                for row in try rows("option_lab_catalog") {
                    guard let id = UUID(uuidString: try row[0].text()), try OptionLabStore.load(id: id, db: db) != nil else { throw OptionLabArchiveError.corruptedArchive }
                }
                for row in try rows("option_daily_catalog") {
                    guard let id = UUID(uuidString: try row[0].text()), try OptionDailyStore.loadDaily(id: id, db: db) != nil else { throw OptionLabArchiveError.corruptedArchive }
                }
                for row in try rows("option_history_catalog") {
                    guard let id = UUID(uuidString: try row[0].text()), try OptionDailyStore.loadHistory(id: id, db: db) != nil else { throw OptionLabArchiveError.corruptedArchive }
                }
                for row in try rows("option_chain_catalog") {
                    guard let id = UUID(uuidString: try row[0].text()), try OptionChainStore.load(id: id, db: db) != nil else { throw OptionLabArchiveError.corruptedArchive }
                }
                for row in try rows("portfolio_greeks_catalog") {
                    guard let id = UUID(uuidString: try row[0].text()), try PortfolioGreeksStore.load(id: id, db: db) != nil else { throw OptionLabArchiveError.corruptedArchive }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabArchiveError.corruptedArchive }
    }
    static func merge(current: Self, incoming: Self) throws -> Self {
        try current.validateShape(); try incoming.validateShape()
        guard current.format == Self.format, incoming.format == Self.format else { throw OptionLabArchiveError.unsupportedFormat }
        var merged: [OptionLabArchiveTable] = []
        for (index, definition) in definitions.enumerated() {
            var entries: [String: [OptionLabArchiveValue]] = [:]
            for row in current.tables[index].rows { entries[try definition.key(row)] = row }
            for row in incoming.tables[index].rows {
                let key = try definition.key(row)
                if let existing = entries[key], existing != row { throw OptionLabArchiveError.identityConflict }
                entries[key] = row
            }
            merged.append(.init(name: definition.name, rows: entries.keys.sorted(by: byteOrder).compactMap { entries[$0] }))
        }
        return .init(format: Self.format, revision: current.revision, tables: merged)
    }
}
