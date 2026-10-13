import Foundation
import GRDB
import CoreDomain
import PortfolioEngine

public enum PerformanceStoreError: Error, Equatable, Sendable {
    case incompatiblePurpose, corruptedStorage, incompatibleVersion, invalidInput, invalidPlan, stalePlan, notFound, budgetExceeded, injectedFailure
}
public struct PerformanceStoreContext: Sendable, Equatable {
    public let ledger: LedgerSnapshot
    public let revision: UUID
    public init(ledger:LedgerSnapshot,revision:UUID) { self.ledger = ledger; self.revision = revision }
}
public struct PerformancePreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ledgerRevision: UUID
    public let performanceRevision: UUID
    public let inputHash: String
    public let reportHash: String
    public let report: PerformanceReport
    public init(id:UUID,ledgerRevision:UUID,performanceRevision:UUID,inputHash:String,reportHash:String,report:PerformanceReport) {
        self.id = id; self.ledgerRevision = ledgerRevision; self.performanceRevision = performanceRevision
        self.inputHash = inputHash; self.reportHash = reportHash; self.report = report
    }
}
public struct PerformanceSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let accountID: String
    public let createdAt: Date
    public let startDate: String
    public let endDate: String
    public let dayCount: Int
    public let ledgerRevision: UUID
    public let inputHash: String
    public let reportHash: String
    public let engineVersion: String
    /// Only current revision metadata is compared here. Listing is not report replay.
    public let isCurrentLedger: Bool
    public init(id:UUID,accountID:String,createdAt:Date,startDate:String,endDate:String,dayCount:Int,ledgerRevision:UUID,
                inputHash:String,reportHash:String,engineVersion:String,isCurrentLedger:Bool) {
        self.id = id; self.accountID = accountID; self.createdAt = createdAt; self.startDate = startDate; self.endDate = endDate
        self.dayCount = dayCount; self.ledgerRevision = ledgerRevision; self.inputHash = inputHash; self.reportHash = reportHash
        self.engineVersion = engineVersion; self.isCurrentLedger = isCurrentLedger
    }
}
public struct SavedPerformanceReport: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let report: PerformanceReport
    public let inputHash: String
    public let reportHash: String
    public let ledgerRevision: UUID
    public let isCurrentLedger: Bool
    public let replayMatched: Bool
    public init(id:UUID,createdAt:Date,report:PerformanceReport,inputHash:String,reportHash:String,
                ledgerRevision:UUID,isCurrentLedger:Bool,replayMatched:Bool) {
        self.id = id; self.createdAt = createdAt; self.report = report; self.inputHash = inputHash; self.reportHash = reportHash
        self.ledgerRevision = ledgerRevision; self.isCurrentLedger = isCurrentLedger; self.replayMatched = replayMatched
    }
}
public protocol PerformanceStorage: Sendable {
    func context() async throws -> PerformanceStoreContext
    func prepare(request:PerformanceRequest,rawRequest:Data?,expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) async throws -> PerformancePreview
    func commit(planID:UUID,expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) async throws -> SavedPerformanceReport
    func cancel(planID:UUID) async
    func reports(accountID:String) async throws -> [PerformanceSummary]
    func open(id:UUID) async throws -> SavedPerformanceReport
}

extension LedgerStore {
    public func makePerformanceStore() throws -> PerformanceStore { try PerformanceStore(database:database) }
}

/// Independent process-local previews share the ledger queue. Every commit checks
/// both revisions inside SQLite; an old report always replays its frozen ledger.
public actor PerformanceStore: PerformanceStorage {
    // Accepted document sizes, not peak process-memory guarantees.
    public static let maximumRequestBytes = 8 * 1_024 * 1_024
    public static let maximumInputBytes = 32 * 1_024 * 1_024
    public static let maximumReportBytes = 64 * 1_024 * 1_024
    private let database:DatabaseStore
    private let preparationCheckpoint:@Sendable () async -> Void
    private var plans:[UUID:Plan] = [:]
    private var failNextCommit = false
    public init(database:DatabaseStore) throws {
        guard database.purpose == .portfolioLedger else { throw PerformanceStoreError.incompatiblePurpose }
        self.database = database; preparationCheckpoint = {}
    }
    public init(path:String) throws {
        database = try DatabaseStore(path:path,purpose:.portfolioLedger); preparationCheckpoint = {}
    }
    init(database:DatabaseStore,preparationCheckpoint:@escaping @Sendable () async -> Void) throws {
        guard database.purpose == .portfolioLedger else { throw PerformanceStoreError.incompatiblePurpose }
        self.database = database; self.preparationCheckpoint = preparationCheckpoint
    }
    public func context() throws -> PerformanceStoreContext {
        try database.read { db in
            PerformanceStoreContext(ledger:try LedgerStore.load(db),revision:try Self.performanceRevision(db))
        }
    }
    public func prepare(request:PerformanceRequest,rawRequest:Data? = nil,expectedLedgerRevision:UUID,
                        expectedPerformanceRevision:UUID) async throws -> PerformancePreview {
        try Task.checkCancellation()
        // Pin the complete validated ledger before parsing/calculation or suspension.
        let baseline = try context()
        guard baseline.ledger.revision == expectedLedgerRevision,baseline.revision == expectedPerformanceRevision else { throw PerformanceStoreError.stalePlan }
        let raw = try rawRequest ?? Self.encode(request)
        guard raw.count <= Self.maximumRequestBytes else { throw PerformanceStoreError.budgetExceeded }
        guard try JSONDecoder().decode(PerformanceRequest.self,from:raw) == request else { throw PerformanceStoreError.invalidInput }
        let input = PerformanceInput(request:request,ledgerRevision:expectedLedgerRevision,
                                     accounts:baseline.ledger.accounts,events:baseline.ledger.events)
        let envelope = Envelope(input:input,requestHash:LedgerCSV.hash(raw),engineVersion:PerformanceEngine.version,
            ledgerEngineVersion:LedgerEngine.version,parametersVersion:"PARAMETERS_V1",numericPolicyVersion:Money.numericPolicyVersion)
        let inputBytes = try Self.encode(envelope)
        guard inputBytes.count <= Self.maximumInputBytes else { throw PerformanceStoreError.budgetExceeded }
        let report = try PerformanceEngine.calculate(input), reportBytes = try Self.encode(report)
        guard reportBytes.count <= Self.maximumReportBytes else { throw PerformanceStoreError.budgetExceeded }
        try Self.validateVersions(report:report,envelope:envelope)
        await preparationCheckpoint()
        try Task.checkCancellation()
        // A stale calculation must not be offered as a preview on a fresh baseline.
        try database.read { db in try Self.checkRevisions(expectedLedgerRevision,expectedPerformanceRevision,db) }
        guard plans.count < 8 else { throw PerformanceStoreError.invalidPlan }
        let preview = PerformancePreview(id:UUID(),ledgerRevision:expectedLedgerRevision,performanceRevision:expectedPerformanceRevision,
            inputHash:LedgerCSV.hash(inputBytes),reportHash:LedgerCSV.hash(reportBytes),report:report)
        plans[preview.id] = Plan(preview:preview,inputBytes:inputBytes,requestBytes:raw,reportBytes:reportBytes)
        return preview
    }
    public func cancel(planID:UUID) { plans.removeValue(forKey:planID) }
    public func commit(planID:UUID,expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) throws -> SavedPerformanceReport {
        guard let plan = plans[planID],plan.preview.ledgerRevision == expectedLedgerRevision,
              plan.preview.performanceRevision == expectedPerformanceRevision else { throw PerformanceStoreError.invalidPlan }
        try Task.checkCancellation()
        let injected = failNextCommit; failNextCommit = false
        do {
            let saved = try database.transaction { db in
                try Self.checkRevisions(expectedLedgerRevision,expectedPerformanceRevision,db)
                // Verify all current ledger facts, not just its revision token.
                let ledger = try LedgerStore.load(db)
                guard ledger.accounts == plan.preview.report.input.accounts,ledger.events == plan.preview.report.input.events else { throw PerformanceStoreError.corruptedStorage }
                let inputExists = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM performance_inputs WHERE input_hash = ?)",arguments:[plan.preview.inputHash]) ?? false
                if inputExists {
                    let envelope = try Self.loadInput(hash:plan.preview.inputHash,db)
                    guard envelope.input == plan.preview.report.input else { throw PerformanceStoreError.corruptedStorage }
                    let duplicates = try String.fetchAll(db,sql:"SELECT report_id FROM performance_report_catalog WHERE input_hash = ? ORDER BY report_id",arguments:[plan.preview.inputHash])
                    guard duplicates.count == 1 else { throw PerformanceStoreError.corruptedStorage }
                    for id in duplicates {
                        guard let uuid = UUID(uuidString:id) else { throw PerformanceStoreError.corruptedStorage }
                        let existing = try Self.loadReport(id:uuid,db)
                        guard existing.reportHash == plan.preview.reportHash else { throw PerformanceStoreError.corruptedStorage }
                        return existing
                    }
                    // An input without its atomically written report is corruption.
                    throw PerformanceStoreError.corruptedStorage
                }
                let report = plan.preview.report, input = report.input
                try db.execute(sql:"""
                    INSERT INTO performance_inputs(input_hash,ledger_revision,engine_version,parameters_version,numeric_policy_version,input_json,request_hash,request_json)
                    VALUES (?,?,?,?,?,?,?,?)
                    """,arguments:[plan.preview.inputHash,input.ledgerRevision.uuidString,report.engineVersion,report.parametersVersion,
                                   report.numericPolicyVersion,plan.inputBytes,LedgerCSV.hash(plan.requestBytes),plan.requestBytes])
                let summary = try StoredSummary(id:planID,createdAt:Date(),preview:plan.preview)
                let summaryBytes = try Self.encode(summary)
                try db.execute(sql:"""
                    INSERT INTO performance_report_catalog(report_id,account_id,ledger_revision,input_hash,report_hash,summary_hash,summary_json)
                    VALUES (?,?,?,?,?,?,?)
                    """,arguments:[planID.uuidString,input.request.accountID,input.ledgerRevision.uuidString,plan.preview.inputHash,
                                   plan.preview.reportHash,LedgerCSV.hash(summaryBytes),summaryBytes])
                try db.execute(sql:"INSERT INTO performance_report_documents(report_id,report_json) VALUES (?,?)",arguments:[planID.uuidString,plan.reportBytes])
                if injected { throw PerformanceStoreError.injectedFailure }
                try Task.checkCancellation()
                try db.execute(sql:"UPDATE performance_metadata SET revision = ? WHERE singleton = 1",arguments:[UUID().uuidString])
                guard db.changesCount == 1 else { throw PerformanceStoreError.corruptedStorage }
                return try Self.loadReport(id:planID,db)
            }
            plans.removeValue(forKey:planID); return saved
        } catch PerformanceStoreError.stalePlan {
            plans.removeValue(forKey:planID); throw PerformanceStoreError.stalePlan
        }
    }
    public func reports(accountID:String) throws -> [PerformanceSummary] {
        try database.read { db in
            let current = try Self.ledgerRevision(db)
            let rows = try Row.fetchAll(db,sql:Self.catalogQuery + " WHERE c.account_id = ? ORDER BY c.report_id",arguments:[accountID])
            return try rows.map { try Self.loadSummary($0).publicValue(current:current) }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        }
    }
    public func open(id:UUID) throws -> SavedPerformanceReport { try database.read { try Self.loadReport(id:id,$0) } }
    func injectFailureOnNextCommit() { failNextCommit = true }

    private struct Plan:Sendable {
        let preview:PerformancePreview
        let inputBytes:Data
        let requestBytes:Data
        let reportBytes:Data
    }
    private struct Envelope:Codable {
        let input:PerformanceInput
        let requestHash:String
        let engineVersion:String
        let ledgerEngineVersion:String
        let parametersVersion:String
        let numericPolicyVersion:String
    }
    private struct StoredSummary:Codable {
        let id:UUID
        let accountID:String
        let createdAt:Date
        let startDate:String
        let endDate:String
        let dayCount:Int
        let ledgerRevision:UUID
        let inputHash:String
        let reportHash:String
        let engineVersion:String
        init(id:UUID,createdAt:Date,preview:PerformancePreview) throws {
            let days = preview.report.input.request.calendar.tradingDays
            guard let first = days.first,let last = days.last else { throw PerformanceStoreError.invalidInput }
            self.id = id; accountID = preview.report.input.request.accountID; self.createdAt = createdAt
            startDate = first; endDate = last; dayCount = days.count; ledgerRevision = preview.ledgerRevision
            inputHash = preview.inputHash; reportHash = preview.reportHash; engineVersion = preview.report.engineVersion
        }
        func publicValue(current:UUID) -> PerformanceSummary {
            PerformanceSummary(id:id,accountID:accountID,createdAt:createdAt,startDate:startDate,endDate:endDate,dayCount:dayCount,
                ledgerRevision:ledgerRevision,inputHash:inputHash,reportHash:reportHash,engineVersion:engineVersion,isCurrentLedger:current == ledgerRevision)
        }
    }
    private static func encode<T:Encodable>(_ value:T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func ledgerRevision(_ db:Database) throws -> UUID { try revision(table:"ledger_metadata",db) }
    private static func performanceRevision(_ db:Database) throws -> UUID { try revision(table:"performance_metadata",db) }
    private static func revision(table:String,_ db:Database) throws -> UUID {
        guard let value = try String.fetchOne(db,sql:"SELECT revision FROM " + table + " WHERE singleton = 1"),
              let revision = UUID(uuidString:value),revision.uuidString == value else { throw PerformanceStoreError.corruptedStorage }
        return revision
    }
    private static func checkRevisions(_ ledger:UUID,_ performance:UUID,_ db:Database) throws {
        guard try ledgerRevision(db) == ledger,try performanceRevision(db) == performance else { throw PerformanceStoreError.stalePlan }
    }
    private static func validateVersions(report:PerformanceReport,envelope:Envelope) throws {
        guard envelope.engineVersion == PerformanceEngine.version,envelope.ledgerEngineVersion == LedgerEngine.version,
              envelope.parametersVersion == "PARAMETERS_V1",envelope.numericPolicyVersion == Money.numericPolicyVersion,
              report.engineVersion == envelope.engineVersion,report.parametersVersion == envelope.parametersVersion,
              report.numericPolicyVersion == envelope.numericPolicyVersion else { throw PerformanceStoreError.incompatibleVersion }
    }
    private static let catalogQuery = """
        SELECT c.*, i.ledger_revision AS input_ledger_revision, i.engine_version AS input_engine_version,
               EXISTS(SELECT 1 FROM performance_report_documents d WHERE d.report_id = c.report_id) AS has_document
        FROM performance_report_catalog c LEFT JOIN performance_inputs i ON i.input_hash = c.input_hash
        """
    private static func loadSummary(_ row:Row) throws -> StoredSummary {
        do {
            let bytes:Data = row["summary_json"]
            guard LedgerCSV.hash(bytes) == row["summary_hash"] else { throw PerformanceStoreError.corruptedStorage }
            let summary = try JSONDecoder().decode(StoredSummary.self,from:bytes)
            let exists:Bool = row["has_document"]
            guard exists,summary.id.uuidString == row["report_id"],summary.accountID == row["account_id"],
                  summary.ledgerRevision.uuidString == row["ledger_revision"],summary.ledgerRevision.uuidString == row["input_ledger_revision"],
                  summary.inputHash == row["input_hash"],summary.reportHash == row["report_hash"],summary.engineVersion == row["input_engine_version"],
                  summary.createdAt.timeIntervalSinceReferenceDate.isFinite,summary.dayCount > 0,summary.startDate <= summary.endDate,
                  !summary.accountID.isEmpty,summary.inputHash.count == 64,summary.reportHash.count == 64 else { throw PerformanceStoreError.corruptedStorage }
            return summary
        } catch { throw PerformanceStoreError.corruptedStorage }
    }
    private static func loadInput(hash:String,_ db:Database) throws -> Envelope {
        do {
            guard let row = try Row.fetchOne(db,sql:"SELECT * FROM performance_inputs WHERE input_hash = ?",arguments:[hash]) else { throw PerformanceStoreError.corruptedStorage }
            let bytes:Data = row["input_json"],raw:Data = row["request_json"]
            guard bytes.count <= maximumInputBytes,raw.count <= maximumRequestBytes,
                  LedgerCSV.hash(bytes) == hash,LedgerCSV.hash(raw) == row["request_hash"] else { throw PerformanceStoreError.corruptedStorage }
            let envelope = try JSONDecoder().decode(Envelope.self,from:bytes)
            guard envelope.requestHash == row["request_hash"],envelope.input.ledgerRevision.uuidString == row["ledger_revision"],
                  envelope.engineVersion == row["engine_version"],envelope.parametersVersion == row["parameters_version"],
                  envelope.numericPolicyVersion == row["numeric_policy_version"],
                  try JSONDecoder().decode(PerformanceRequest.self,from:raw) == envelope.input.request else { throw PerformanceStoreError.corruptedStorage }
            return envelope
        } catch { throw PerformanceStoreError.corruptedStorage }
    }
    private static func loadReport(id:UUID,_ db:Database) throws -> SavedPerformanceReport {
        try Task.checkCancellation()
        guard let row = try Row.fetchOne(db,sql:catalogQuery + " WHERE c.report_id = ?",arguments:[id.uuidString]) else { throw PerformanceStoreError.notFound }
        let summary = try loadSummary(row), envelope = try loadInput(hash:summary.inputHash,db)
        guard let bytes = try Data.fetchOne(db,sql:"SELECT report_json FROM performance_report_documents WHERE report_id = ?",arguments:[id.uuidString]),
              bytes.count <= maximumReportBytes,LedgerCSV.hash(bytes) == summary.reportHash else { throw PerformanceStoreError.corruptedStorage }
        let report:PerformanceReport
        do { report = try JSONDecoder().decode(PerformanceReport.self,from:bytes) }
        catch { throw PerformanceStoreError.corruptedStorage }
        try validateVersions(report:report,envelope:envelope)
        guard report.input == envelope.input,report.input.request.accountID == summary.accountID,
              report.input.ledgerRevision == summary.ledgerRevision,
              report.input.request.calendar.tradingDays.first == summary.startDate,
              report.input.request.calendar.tradingDays.last == summary.endDate,
              report.input.request.calendar.tradingDays.count == summary.dayCount else { throw PerformanceStoreError.corruptedStorage }
        let computed:PerformanceReport
        do { computed = try PerformanceEngine.recompute(report) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PerformanceStoreError.corruptedStorage }
        guard computed == report else { throw PerformanceStoreError.corruptedStorage }
        return SavedPerformanceReport(id:id,createdAt:summary.createdAt,report:computed,inputHash:summary.inputHash,reportHash:summary.reportHash,
            ledgerRevision:summary.ledgerRevision,isCurrentLedger:try ledgerRevision(db) == summary.ledgerRevision,replayMatched:true)
    }
}
