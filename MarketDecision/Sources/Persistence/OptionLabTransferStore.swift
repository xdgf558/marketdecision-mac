import Foundation
import GRDB
import PortfolioEngine

/// Plans are process-local, bounded, exact approvals. Restart requires preparing
/// again. A failed transaction retains its approval for an explicit retry; stale
/// plans are consumed. Cancel only releases a plan, never reverses a committed write.
public actor OptionLabArchiveStore: OptionLabArchiveStorage {
    private let database: DatabaseStore
    private var plans: [UUID: Pending] = [:]
    private var failNextCommit = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .optionsLab else { throw OptionLabArchiveError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .optionsLab) }
    public func status() throws -> OptionLabArchiveStatus { try database.read(Self.metadata) }
    public func exportArchive() throws -> Data {
        try Task.checkCancellation()
        let state = try database.read(OptionLabArchiveState.capture)
        try state.validateReplay()
        return try OptionLabArchiveCodec.encode(state)
    }
    public func prepareRestore(_ data: Data, mode: OptionLabRestoreMode, expectedRevision: UUID) throws -> OptionLabTransferPlan {
        try Task.checkCancellation()
        let baseline = try status(); try Self.check(baseline, expectedRevision)
        let incoming = try OptionLabArchiveCodec.decode(data)
        try incoming.validateReplay()
        let candidate: OptionLabArchiveState
        let existingHash: String?
        switch mode {
        case .replace:
            // The incoming archive is fully validated. Old bodies may be corrupt:
            // only identity, revision and counts are required to preview repair.
            candidate = incoming; existingHash = nil
        case .merge:
            let current = try database.read { db in
                try Self.check(Self.metadata(db), expectedRevision)
                return try OptionLabArchiveState.capture(db)
            }
            try current.validateReplay()
            existingHash = LedgerCSV.hash(try OptionLabArchiveCodec.canonical(current))
            candidate = try OptionLabArchiveState.merge(current: current, incoming: incoming)
            try candidate.validateReplay()
        }
        try database.read { try Self.check(Self.metadata($0), expectedRevision) }
        return try plan(operation: mode == .merge ? .merge : .replace, baseline: baseline, candidate: candidate, existingHash: existingHash)
    }
    public func prepareClear(expectedRevision: UUID) throws -> OptionLabTransferPlan {
        try Task.checkCancellation()
        let baseline = try status(); try Self.check(baseline, expectedRevision)
        return try plan(operation: .clear, baseline: baseline, candidate: .empty(revision: expectedRevision), existingHash: nil)
    }
    public func cancel(_ id: UUID) { plans.removeValue(forKey: id) }
    public func commit(_ approval: OptionLabTransferApproval) throws -> OptionLabTransferResult {
        guard let pending = plans[approval.planID], pending.plan.canCommit, pending.plan.digest == approval.digest,
              pending.plan.baseRevision == approval.revision else { throw OptionLabArchiveError.invalidPlan }
        try Task.checkCancellation()
        let injected = failNextCommit; failNextCommit = false
        do {
            let result = try database.transaction { db in
                let current = try Self.metadata(db)
                try Self.check(current, approval.revision)
                guard current.counts == pending.plan.previous else { throw OptionLabArchiveError.corruptedStorage }
                if let expected = pending.existingHash {
                    let state = try OptionLabArchiveState.capture(db)
                    guard LedgerCSV.hash(try OptionLabArchiveCodec.canonical(state)) == expected else { throw OptionLabArchiveError.corruptedStorage }
                }
                try Task.checkCancellation()
                try OptionLabArchiveState.clear(db)
                try pending.state.insert(db)
                if injected { throw OptionLabArchiveError.injectedFailure }
                try Task.checkCancellation()
                let revision = UUID()
                try db.execute(sql: "UPDATE option_lab_metadata SET revision=? WHERE singleton=1", arguments: [revision.uuidString])
                guard db.changesCount == 1 else { throw OptionLabArchiveError.corruptedStorage }
                let persisted = try OptionLabArchiveState.capture(db)
                guard persisted.tables == pending.state.tables,
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw OptionLabArchiveError.corruptedStorage }
                return OptionLabTransferResult(revision: revision, counts: persisted.counts)
            }
            plans.removeValue(forKey: approval.planID); return result
        } catch OptionLabArchiveError.stalePlan {
            plans.removeValue(forKey: approval.planID); throw OptionLabArchiveError.stalePlan
        }
    }
    func injectFailureOnNextCommit() { failNextCommit = true }
    private struct Pending: Sendable {
        let plan: OptionLabTransferPlan
        let state: OptionLabArchiveState
        let existingHash: String?
        let bytes: Int
    }
    private func plan(operation: OptionLabTransferOperation, baseline: OptionLabArchiveStatus, candidate: OptionLabArchiveState, existingHash: String?) throws -> OptionLabTransferPlan {
        let bytes = try OptionLabArchiveCodec.canonical(candidate)
        guard bytes.count < OptionLabArchiveCodec.maximumArchiveBytes - 4096,
              plans.count < 8,
              plans.values.reduce(0, { $0 + $1.bytes }) <= OptionLabArchiveCodec.maximumArchiveBytes - bytes.count else { throw OptionLabArchiveError.budgetExceeded }
        let id = UUID()
        let digestFields = [id.uuidString, operation.rawValue, baseline.revision.uuidString,
            LedgerCSV.hash(try OptionLabArchiveCodec.canonical(baseline.counts)), LedgerCSV.hash(bytes), existingHash ?? "replaceable-bodies"]
        let digest = LedgerCSV.hash(try OptionLabArchiveCodec.canonical(digestFields))
        let details = [
            operation == .clear ? "清空独立期权库的实验、日链与合约摘要、历史报告、期权链来源和组合 Greeks；研究库、账本库和 Keychain 不变。" : "恢复独立期权库；保留输入、报告、期权链来源、组合 Greeks 和嵌入证明的原字节，打开前仍须完整重算核对。",
            "ZIP 未加密。可能包含实验引用的只读账户和历史事件证明（本次结果 \(candidate.counts.embeddedLedgerBases) 份），不备份或恢复 portfolio-ledger.sqlite。",
            "相同身份不同内容明确拒绝合并，不覆盖、不改名。确认只在本进程有效；输入预算不是进程内存上限。"
        ]
        let plan = OptionLabTransferPlan(id: id, digest: digest, baseRevision: baseline.revision, operation: operation,
            previous: baseline.counts, result: candidate.counts, details: details, canCommit: true)
        plans[id] = Pending(plan: plan, state: candidate, existingHash: existingHash, bytes: bytes.count)
        return plan
    }
    private static func check(_ status: OptionLabArchiveStatus, _ expected: UUID) throws {
        guard status.revision == expected else { throw OptionLabArchiveError.stalePlan }
    }
    static func metadata(_ db: Database) throws -> OptionLabArchiveStatus {
        guard try Int.fetchOne(db, sql: "PRAGMA application_id") == DatabasePurpose.optionsLab.applicationID else { throw OptionLabArchiveError.incompatiblePurpose }
        let names = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*'"))
        let expected = Set(OptionLabArchiveState.definitions.map(\.name) + ["option_lab_metadata", "grdb_migrations"])
        guard names == expected else { throw OptionLabArchiveError.unsupportedFormat }
        let revision: UUID
        do { revision = try OptionLabStore.revision(db) } catch { throw OptionLabArchiveError.corruptedStorage }
        func count(_ table: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM " + table) ?? 0 }
        let bases = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM option_lab_documents WHERE ledger_basis_json IS NOT NULL") ?? 0
        return try .init(revision: revision, counts: .init(experiments: count("option_lab_catalog"), dailySummaries: count("option_daily_catalog"),
            historyReports: count("option_history_catalog"), contractSummaries: count("option_daily_contracts"), embeddedLedgerBases: bases + count("portfolio_greeks_catalog"),
            chainCaptures: count("option_chain_catalog"), portfolioReports: count("portfolio_greeks_catalog")))
    }
}
