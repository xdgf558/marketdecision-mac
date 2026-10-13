import Foundation
import GRDB
import PortfolioEngine

extension LedgerStore {
    public func makeArchiveStore() throws -> LedgerArchiveStore { try LedgerArchiveStore(database:database) }
}

/// Explicit, process-local approvals. The independent MDL1 database is the only
/// deletion boundary; research, credentials and external files are never opened.
public actor LedgerArchiveStore: LedgerArchiveStorage {
    private let database:DatabaseStore
    private var plans:[UUID:Pending] = [:]
    private var failNextCommit = false
    public init(database:DatabaseStore) throws {
        guard database.purpose == .portfolioLedger else { throw LedgerArchiveError.incompatiblePurpose }
        self.database = database
    }
    public init(path:String) throws { database = try DatabaseStore(path:path,purpose:.portfolioLedger) }
    public func status() throws -> LedgerArchiveStatus { try database.read(Self.metadata) }
    public func exportArchive() throws -> Data {
        let state = try database.read(LedgerArchiveState.capture)
        try LedgerArchiveValidation().validate(state)
        return try LedgerArchiveCodec.encode(state)
    }
    public func prepareRestore(_ data:Data,mode:LedgerRestoreMode,expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) throws -> LedgerTransferPlan {
        try Task.checkCancellation()
        let baseline = try status()
        try Self.check(baseline,expectedLedgerRevision,expectedPerformanceRevision)
        let incoming = try LedgerArchiveValidation().decode(data)
        let operation:LedgerTransferOperation
        let candidate:LedgerArchiveState
        var existingHash:String? = nil
        switch mode {
        case .replace:
            operation = .replace; candidate = incoming
        case .merge,.retainConflict:
            let current = try database.read { db in
                try Self.check(Self.metadata(db),expectedLedgerRevision,expectedPerformanceRevision)
                return try LedgerArchiveState.capture(db)
            }
            try LedgerArchiveValidation().validate(current)
            existingHash = LedgerCSV.hash(try LedgerArchiveCodec.canonical(current))
            operation = mode == .merge ? .merge:.retainConflict
            if mode == .merge {
                do { candidate = try Self.merge(current:current,incoming:incoming,raw:data) }
                catch LedgerArchiveError.identityConflict {
                    return try plan(operation:.merge,baseline:baseline,candidate:current,existingHash:existingHash,
                        details:["账户、交易身份或报告内容发生冲突；活动数据未改动。可明确选择保留完整隔离冲突包，供之后导出处理。"],canCommit:false)
                }
            } else {
                // This is an explicit preservation choice, never partial activation.
                candidate = try Self.retain(current:current,incoming:incoming,raw:data)
            }
        }
        try LedgerArchiveValidation().validate(candidate)
        try database.read { try Self.check(Self.metadata($0),expectedLedgerRevision,expectedPerformanceRevision) }
        return try plan(operation:operation,baseline:baseline,candidate:candidate,existingHash:existingHash,
            details:mode == .retainConflict ? ["完整原包仅保留于隔离冲突区，不进入活动账本或收益报告。ZIP 未加密。"]:
                ["独立账本与收益；原始来源及冻结报告字节保留。恢复后使用新修订号，旧报告仍绑定原账本。ZIP 未加密。"],canCommit:true)
    }
    public func prepareClear(expectedLedgerRevision:UUID,expectedPerformanceRevision:UUID) throws -> LedgerTransferPlan {
        let baseline = try status(); try Self.check(baseline,expectedLedgerRevision,expectedPerformanceRevision)
        let empty = LedgerArchiveState(format:"portfolio-ledger-state.v1",ledgerRevision:expectedLedgerRevision,performanceRevision:expectedPerformanceRevision,
            tables:LedgerArchiveState.definitions.map { LedgerArchiveTable(name:$0.name,rows:[]) })
        return try plan(operation:.clear,baseline:baseline,candidate:empty,existingHash:nil,
            details:["清空本独立账本、原始导入、收益报告、归档来源与隔离冲突包；研究库、Keychain 和外部文件不变。"],canCommit:true)
    }
    public func cancel(_ id:UUID) { plans.removeValue(forKey:id) }
    public func commit(_ approval:LedgerTransferApproval) throws -> LedgerTransferResult {
        guard let pending = plans[approval.planID],pending.plan.canCommit,pending.plan.digest == approval.digest,
              pending.plan.baseLedgerRevision == approval.ledgerRevision,pending.plan.basePerformanceRevision == approval.performanceRevision else { throw LedgerArchiveError.invalidPlan }
        try Task.checkCancellation()
        let injected = failNextCommit; failNextCommit = false
        do {
            let result = try database.transaction { db in
                let current = try Self.metadata(db)
                try Self.check(current,approval.ledgerRevision,approval.performanceRevision)
                guard current.counts == pending.plan.previous else { throw LedgerArchiveError.corruptedStorage }
                if let expected = pending.existingHash {
                    let currentState = try LedgerArchiveState.capture(db)
                    guard LedgerCSV.hash(try LedgerArchiveCodec.canonical(currentState)) == expected else { throw LedgerArchiveError.corruptedStorage }
                }
                // Both baseline tokens were captured before any parsing or replay.
                // No current revision is acquired here to reauthorize an old write.
                try LedgerArchiveState.clear(db)
                try pending.state.insert(db)
                if injected { throw LedgerArchiveError.injectedFailure }
                try Task.checkCancellation()
                let ledgerRevision = pending.plan.operation == .retainConflict ? current.ledgerRevision:UUID()
                let performanceRevision = UUID()
                try db.execute(sql:"UPDATE ledger_metadata SET revision = ? WHERE singleton = 1",arguments:[ledgerRevision.uuidString])
                guard db.changesCount == 1 else { throw LedgerArchiveError.corruptedStorage }
                try db.execute(sql:"UPDATE performance_metadata SET revision = ? WHERE singleton = 1",arguments:[performanceRevision.uuidString])
                guard db.changesCount == 1 else { throw LedgerArchiveError.corruptedStorage }
                // The prepared immutable state was fully replayed. Verify all
                // SQLite constraints and exact persisted bytes before committing.
                let persisted = try LedgerArchiveState.capture(db)
                guard persisted.tables == pending.state.tables,
                      try Row.fetchAll(db,sql:"PRAGMA foreign_key_check").isEmpty else { throw LedgerArchiveError.corruptedStorage }
                return LedgerTransferResult(ledgerRevision:ledgerRevision,performanceRevision:performanceRevision,counts:persisted.counts)
            }
            plans.removeValue(forKey:approval.planID); return result
        } catch LedgerArchiveError.stalePlan {
            plans.removeValue(forKey:approval.planID); throw LedgerArchiveError.stalePlan
        }
    }
    public func conflicts() throws -> [LedgerArchiveConflictSummary] {
        let rows = try conflictRows()
        let validator = LedgerArchiveValidation()
        return try rows.map { try validator.conflict($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func exportConflict(id:UUID) throws -> Data {
        let rows = try conflictRows(id:id)
        guard let row = try rows.first(where: { try $0[0].text() == id.uuidString }) else { throw LedgerArchiveError.notFound }
        _ = try LedgerArchiveValidation().conflict(row)
        return try row[4].blob()
    }
    private func conflictRows(id:UUID? = nil) throws -> [[LedgerArchiveValue]] {
        try database.read { db in
            _ = try Self.metadata(db)
            guard let definition = LedgerArchiveState.definitions.first(where: { $0.name == "ledger_archive_conflicts" }) else { throw LedgerArchiveError.corruptedStorage }
            return try LedgerArchiveState.captureRows(definition,db:db,matching:id?.uuidString)
        }
    }
    func injectFailureOnNextCommit() { failNextCommit = true }
    private struct Pending:Sendable { let plan:LedgerTransferPlan; let state:LedgerArchiveState; let existingHash:String? }
    private func plan(operation:LedgerTransferOperation,baseline:LedgerArchiveStatus,candidate:LedgerArchiveState,
                      existingHash:String?,details:[String],canCommit:Bool) throws -> LedgerTransferPlan {
        guard try LedgerArchiveCodec.canonical(candidate).count < LedgerArchiveCodec.maximumArchiveBytes - 4096 else { throw LedgerArchiveError.budgetExceeded }
        let id = UUID()
        let digestInput = [id.uuidString,operation.rawValue,baseline.ledgerRevision.uuidString,baseline.performanceRevision.uuidString,
                           LedgerCSV.hash(try LedgerArchiveCodec.canonical(candidate)),existingHash ?? "metadata-only"]
        let digest = LedgerCSV.hash(try LedgerArchiveCodec.canonical(digestInput))
        let plan = LedgerTransferPlan(id:id,digest:digest,baseLedgerRevision:baseline.ledgerRevision,basePerformanceRevision:baseline.performanceRevision,
            operation:operation,previous:baseline.counts,result:candidate.counts,details:details,canCommit:canCommit)
        if canCommit {
            guard plans.count < 8 else { throw LedgerArchiveError.invalidPlan }
            plans[id] = Pending(plan:plan,state:candidate,existingHash:existingHash)
        }
        return plan
    }
    static func metadata(_ db:Database) throws -> LedgerArchiveStatus {
        guard try Int.fetchOne(db,sql:"PRAGMA application_id") == DatabasePurpose.portfolioLedger.applicationID else { throw LedgerArchiveError.incompatiblePurpose }
        let names = Set(try String.fetchAll(db,sql:"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*'"))
        let expected = Set(LedgerArchiveState.definitions.map(\.name) + ["ledger_metadata","performance_metadata","grdb_migrations"])
        guard names == expected else { throw LedgerArchiveError.unsupportedFormat }
        func revision(_ table:String)throws->UUID {
            guard try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(table)") == 1,
                  let text = try String.fetchOne(db,sql:"SELECT revision FROM \(table) WHERE singleton = 1"),
                  let value = UUID(uuidString:text),value.uuidString == text else { throw LedgerArchiveError.corruptedStorage }
            return value
        }
        func count(_ table:String)throws->Int { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(table)") ?? 0 }
        return try LedgerArchiveStatus(ledgerRevision:revision("ledger_metadata"),performanceRevision:revision("performance_metadata"),
            counts:.init(accounts:count("ledger_accounts"),events:count("ledger_events"),batches:count("ledger_batches"),reports:count("performance_report_catalog"),conflicts:count("ledger_archive_conflicts")))
    }
    private static func check(_ status:LedgerArchiveStatus,_ ledger:UUID,_ performance:UUID) throws {
        guard status.ledgerRevision == ledger,status.performanceRevision == performance else { throw LedgerArchiveError.stalePlan }
    }
    private static func retain(current:LedgerArchiveState,incoming:LedgerArchiveState,raw:Data) throws -> LedgerArchiveState {
        let scratch = try DatabaseStore(path:":memory:",purpose:.portfolioLedger)
        return try scratch.transaction { db in
            try current.insert(db)
            let hash = LedgerCSV.hash(raw)
            let exists = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ledger_archive_conflicts WHERE archive_hash = ?)",arguments:[hash]) ?? false
            if !exists {
                let summary = LedgerArchiveConflictSummary(id:UUID(),createdAt:Date(),sourceHash:hash,
                    reason:"用户选择保留完整冲突原包；未加入活动账本或收益",counts:incoming.counts)
                let bytes = try LedgerArchiveCodec.canonical(summary)
                try db.execute(sql:"INSERT INTO ledger_archive_conflicts(conflict_id,archive_hash,summary_hash,summary_json,archive_bytes) VALUES (?,?,?,?,?)",
                    arguments:[summary.id.uuidString,hash,LedgerCSV.hash(bytes),bytes,raw])
            }
            try db.execute(sql:"UPDATE ledger_metadata SET revision = ?",arguments:[current.ledgerRevision.uuidString])
            try db.execute(sql:"UPDATE performance_metadata SET revision = ?",arguments:[current.performanceRevision.uuidString])
            return try LedgerArchiveState.capture(db)
        }
    }
}
