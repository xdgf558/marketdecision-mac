import Foundation
import GRDB
import CoreDomain
import PortfolioEngine
import OptionsAnalytics

public enum OptionLabStoreError: Error, Equatable, Sendable {
    case incompatiblePurpose, corruptedStorage, incompatibleVersion, staleRevision
    case conflictingSnapshot, notFound, budgetExceeded, injectedFailure
}

/// Metadata only. Listing a name does not validate or publish cached result values.
public struct OptionLabSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let asOf: Date
    public let strategy: OptionLabStrategy
    public let origin: OptionLabOrigin
    public let underlyingSymbol: String
    public let inputHash: String
    public let reportHash: String
    public init(id: UUID, createdAt: Date, asOf: Date, strategy: OptionLabStrategy, origin: OptionLabOrigin,
                underlyingSymbol: String, inputHash: String, reportHash: String) {
        self.id = id; self.createdAt = createdAt; self.asOf = asOf; self.strategy = strategy; self.origin = origin
        self.underlyingSymbol = underlyingSymbol; self.inputHash = inputHash; self.reportHash = reportHash
    }
}
public struct SavedOptionLab: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let report: OptionLabReport
    public let inputHash: String
    public let reportHash: String
    public let ledgerBasis: OptionLabLedgerBasis?
    /// Set only after full input replay equals the saved report and references.
    public let replayMatched: Bool
    public init(id: UUID, report: OptionLabReport, inputHash: String, reportHash: String,
                ledgerBasis: OptionLabLedgerBasis? = nil, replayMatched: Bool) {
        self.id = id; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash
        self.replayMatched = replayMatched
        self.ledgerBasis = ledgerBasis
    }
}
public protocol OptionLabStorage: Sendable {
    func revision() async throws -> UUID
    func save(id: UUID, input: OptionLabInput, ledgerBasis: OptionLabLedgerBasis?, expectedRevision: UUID) async throws -> SavedOptionLab
    func summaries() async throws -> [OptionLabSummary]
    func open(id: UUID) async throws -> SavedOptionLab
}

/// Append-only offline experiments in a purpose-marked, independent SQLite file.
/// No ledger mutation, real quotes or trading authority. The independent archive
/// preserves these exact bytes and only operates on this purpose-marked database.
public actor OptionLabStore: OptionLabStorage {
    public static let maximumInputBytes = 2 * 1_024 * 1_024
    public static let maximumReportBytes = 4 * 1_024 * 1_024
    public static let maximumSnapshots = 10_000
    private let database: DatabaseStore
    private var failNextSave = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .optionsLab else { throw OptionLabStoreError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .optionsLab) }
    public func revision() throws -> UUID { try database.read(Self.revision) }
    public func makeDailyStore() throws -> OptionDailyStore { try OptionDailyStore(database: database) }
    public func makeChainStore() throws -> OptionChainStore { try OptionChainStore(database: database) }
    public func makePortfolioGreeksStore() throws -> PortfolioGreeksStore { try PortfolioGreeksStore(database: database) }
    public func makeEvidenceStore() throws -> OptionEvidenceStore { try OptionEvidenceStore(database: database) }
    public func makeArchiveStore() throws -> OptionLabArchiveStore { try OptionLabArchiveStore(database: database) }

    /// The caller fixes its baseline before preparing the calculation. Neither a
    /// failed save nor an old page is allowed to silently acquire a fresh revision.
    public func save(id: UUID, input: OptionLabInput, ledgerBasis: OptionLabLedgerBasis? = nil, expectedRevision: UUID) throws -> SavedOptionLab {
        guard id == input.id else { throw OptionLabStoreError.conflictingSnapshot }
        try Task.checkCancellation()
        guard try revision() == expectedRevision else { throw OptionLabStoreError.staleRevision }
        try Self.validateBasis(ledgerBasis, input: input)
        let report = try OptionLabEngine.calculate(input)
        let inputBytes = try Self.encode(input), reportBytes = try Self.encode(report)
        let basisBytes = try ledgerBasis.map(Self.encode)
        guard inputBytes.count <= Self.maximumInputBytes, reportBytes.count <= Self.maximumReportBytes,
              basisBytes.map({ $0.count <= Self.maximumReportBytes }) ?? true else {
            throw OptionLabStoreError.budgetExceeded
        }
        let inputHash = LedgerCSV.hash(inputBytes), reportHash = LedgerCSV.hash(reportBytes)
        let summary = Self.summary(report: report, inputHash: inputHash, reportHash: reportHash)
        let summaryBytes = try Self.encode(summary)
        let modelReference = LedgerCSV.hash(try Self.encode(report.modelReference))
        let parameterReference = LedgerCSV.hash(try Self.encode(report.parameterReference))
        let inject = failNextSave; failNextSave = false
        return try database.transaction { db in
            guard try Self.revision(db) == expectedRevision else { throw OptionLabStoreError.staleRevision }
            if let existing = try Self.load(id: id, db: db) {
                guard existing.report.input == input, existing.inputHash == inputHash, existing.reportHash == reportHash,
                      existing.ledgerBasis == ledgerBasis else {
                    throw OptionLabStoreError.conflictingSnapshot
                }
                return existing
            }
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_lab_catalog") ?? 0) < Self.maximumSnapshots else {
                throw OptionLabStoreError.budgetExceeded
            }
            try Task.checkCancellation()
            try db.execute(sql: """
                INSERT INTO option_lab_catalog(snapshot_id,input_hash,report_hash,model_reference_hash,parameter_reference_hash,numeric_policy_version,summary_hash,summary_json)
                VALUES (?,?,?,?,?,?,?,?)
                """, arguments: [id.uuidString, inputHash, reportHash, modelReference, parameterReference,
                                  Money.numericPolicyVersion, LedgerCSV.hash(summaryBytes), summaryBytes])
            try db.execute(sql: "INSERT INTO option_lab_documents(snapshot_id,input_json,report_json,ledger_basis_json,ledger_basis_hash) VALUES (?,?,?,?,?)",
                arguments: [id.uuidString, inputBytes, reportBytes, basisBytes, basisBytes.map(LedgerCSV.hash)])
            if inject { throw OptionLabStoreError.injectedFailure }
            try Task.checkCancellation()
            try db.execute(sql: "UPDATE option_lab_metadata SET revision = ? WHERE singleton = 1", arguments: [UUID().uuidString])
            return SavedOptionLab(id: id, report: report, inputHash: inputHash, reportHash: reportHash, ledgerBasis: ledgerBasis, replayMatched: true)
        }
    }

    public func summaries() throws -> [OptionLabSummary] {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try Self.revision(db)
            let rows = try Row.fetchAll(db, sql: Self.catalogQuery + " ORDER BY c.snapshot_id")
            guard rows.count <= Self.maximumSnapshots else { throw OptionLabStoreError.budgetExceeded }
            return try rows.map { row in
                try Task.checkCancellation()
                return try Self.decodeSummary(row)
            }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        }
    }
    public func open(id: UUID) throws -> SavedOptionLab {
        try Task.checkCancellation()
        return try database.read { db in
            _ = try Self.revision(db)
            guard let result = try Self.load(id: id, db: db) else { throw OptionLabStoreError.notFound }
            return result
        }
    }
    func injectFailureOnNextSave() { failNextSave = true }

    private static let catalogQuery = """
        SELECT c.*, EXISTS(SELECT 1 FROM option_lab_documents d WHERE d.snapshot_id = c.snapshot_id) AS has_document
        FROM option_lab_catalog c
        """
    private static func summary(report: OptionLabReport, inputHash: String, reportHash: String) -> OptionLabSummary {
        let input = report.input
        // Bound inference work for Swift 6.1 without dropping any nested source.
        let primarySynthetic: Bool = input.underlying.source.origin == .synthetic
            || input.shortLeg.source.origin == .synthetic
        let contractSynthetic: Bool = input.longLeg?.source.origin == .synthetic
            || input.expiry.source.origin == .synthetic || input.capital?.origin == .synthetic
        let pricingSynthetic: Bool = input.pricing?.source.origin == .synthetic
        let riskSynthetic: Bool = input.risk?.containsSyntheticInput == true
        let scenarioSynthetic: Bool = input.scenario?.source.origin == .synthetic
        let synthetic = primarySynthetic || contractSynthetic || pricingSynthetic || riskSynthetic || scenarioSynthetic
        return .init(id: input.id, createdAt: input.createdAt, asOf: input.asOf,
            strategy: input.strategy, origin: synthetic ? .synthetic : .manual,
            underlyingSymbol: report.input.underlying.symbol, inputHash: inputHash, reportHash: reportHash)
    }
    private static func decodeSummary(_ row: Row) throws -> OptionLabSummary {
        do {
            let bytes: Data = row["summary_json"]
            guard bytes.count <= 16_384, LedgerCSV.hash(bytes) == (row["summary_hash"] as String),
                  (row["has_document"] as Bool), (row["numeric_policy_version"] as String) == Money.numericPolicyVersion else {
                throw OptionLabStoreError.corruptedStorage
            }
            let value = try JSONDecoder().decode(OptionLabSummary.self, from: bytes)
            guard value.id.uuidString == (row["snapshot_id"] as String), value.inputHash == (row["input_hash"] as String),
                  value.reportHash == (row["report_hash"] as String), value.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  value.asOf.timeIntervalSinceReferenceDate.isFinite, !value.underlyingSymbol.isEmpty,
                  value.inputHash.count == 64, value.reportHash.count == 64 else { throw OptionLabStoreError.corruptedStorage }
            return value
        } catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func load(id: UUID, db: Database) throws -> SavedOptionLab? {
        guard let row = try Row.fetchOne(db, sql: catalogQuery + " WHERE c.snapshot_id = ?", arguments: [id.uuidString]) else { return nil }
        let metadata = try decodeSummary(row)
        guard let body = try Row.fetchOne(db, sql: "SELECT input_json,report_json,ledger_basis_json,ledger_basis_hash FROM option_lab_documents WHERE snapshot_id = ?", arguments: [id.uuidString]) else {
            throw OptionLabStoreError.corruptedStorage
        }
        do {
            let inputBytes: Data = body["input_json"], reportBytes: Data = body["report_json"]
            guard inputBytes.count <= maximumInputBytes, reportBytes.count <= maximumReportBytes,
                  LedgerCSV.hash(inputBytes) == metadata.inputHash, LedgerCSV.hash(reportBytes) == metadata.reportHash else {
                throw OptionLabStoreError.corruptedStorage
            }
            let input = try JSONDecoder().decode(OptionLabInput.self, from: inputBytes)
            let report = try JSONDecoder().decode(OptionLabReport.self, from: reportBytes)
            let basisBytes: Data? = body["ledger_basis_json"], basisHash: String? = body["ledger_basis_hash"]
            guard (basisBytes == nil) == (basisHash == nil), basisBytes.map({ $0.count <= maximumReportBytes && LedgerCSV.hash($0) == basisHash }) ?? true else {
                throw OptionLabStoreError.corruptedStorage
            }
            let basis = try basisBytes.map { try JSONDecoder().decode(OptionLabLedgerBasis.self, from: $0) }
            try validateBasis(basis, input: input)
            guard input.id == id, report.input == input,
                  LedgerCSV.hash(try encode(report.modelReference)) == (row["model_reference_hash"] as String),
                  LedgerCSV.hash(try encode(report.parameterReference)) == (row["parameter_reference_hash"] as String),
                  summary(report: report, inputHash: metadata.inputHash, reportHash: metadata.reportHash) == metadata else {
                throw OptionLabStoreError.corruptedStorage
            }
            try Task.checkCancellation()
            let replay = try OptionLabEngine.replay(report)
            guard replay == report else { throw OptionLabStoreError.corruptedStorage }
            return SavedOptionLab(id: id, report: replay, inputHash: metadata.inputHash, reportHash: metadata.reportHash, ledgerBasis: basis, replayMatched: true)
        } catch is CancellationError { throw CancellationError() }
        catch { throw OptionLabStoreError.corruptedStorage }
    }
    static func revision(_ db: Database) throws -> UUID {
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_lab_metadata") == 1,
              let raw = try String.fetchOne(db, sql: "SELECT revision FROM option_lab_metadata WHERE singleton = 1"),
              let value = UUID(uuidString: raw), value.uuidString == raw else { throw OptionLabStoreError.corruptedStorage }
        return value
    }
    private static func validateBasis(_ basis: OptionLabLedgerBasis?, input: OptionLabInput) throws {
        if input.capital?.origin == .ledger {
            guard let basis, basis.underlying.symbol == input.underlying.symbol,
                  basis.underlying.kind.rawValue == input.underlying.asset.rawValue,
                  try OptionLabLedgerBridge.replay(basis).capital == input.capital else {
                throw OptionLabStoreError.conflictingSnapshot
            }
        } else if basis != nil { throw OptionLabStoreError.conflictingSnapshot }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

extension DatabaseStore {
    static let optionsLabMigration = DatabaseMigration(identifier: "options-lab.v1") { db in
        try db.execute(sql: """
            CREATE TABLE option_lab_metadata (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), revision TEXT NOT NULL);
            INSERT INTO option_lab_metadata(singleton, revision) VALUES (1, '00000000-0000-0000-0000-000000000000');
            CREATE TABLE option_lab_catalog (
                snapshot_id TEXT PRIMARY KEY NOT NULL,
                input_hash TEXT NOT NULL CHECK(length(input_hash) = 64),
                report_hash TEXT NOT NULL CHECK(length(report_hash) = 64),
                model_reference_hash TEXT NOT NULL CHECK(length(model_reference_hash) = 64),
                parameter_reference_hash TEXT NOT NULL CHECK(length(parameter_reference_hash) = 64),
                numeric_policy_version TEXT NOT NULL,
                summary_hash TEXT NOT NULL CHECK(length(summary_hash) = 64), summary_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE option_lab_documents (
                snapshot_id TEXT PRIMARY KEY NOT NULL, input_json BLOB NOT NULL, report_json BLOB NOT NULL,
                ledger_basis_json BLOB, ledger_basis_hash TEXT CHECK(ledger_basis_hash IS NULL OR length(ledger_basis_hash) = 64),
                CHECK((ledger_basis_json IS NULL) = (ledger_basis_hash IS NULL)),
                FOREIGN KEY(snapshot_id) REFERENCES option_lab_catalog(snapshot_id) ON DELETE RESTRICT
            );
            """)
    }
}
