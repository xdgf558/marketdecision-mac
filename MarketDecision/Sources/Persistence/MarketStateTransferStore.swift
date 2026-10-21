import Foundation
import GRDB
import PortfolioEngine

/// Plans are bounded, process-local approvals. Transaction failures retain a
/// plan for retry; stale approvals are consumed. Cancel never reverses a commit.
public actor MarketStateArchiveStore: MarketStateArchiveStorage {
    private let database: DatabaseStore
    private var plans: [UUID: Pending] = [:]
    private var failNextCommit = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .marketState else { throw MarketStateStorageError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path: path, purpose: .marketState) }
    public func status() throws -> MarketStateArchiveStatus { try database.read(Self.metadata) }
    public func exportArchive() throws -> Data {
        try Task.checkCancellation()
        let state = try database.read { db in _ = try Self.metadata(db); return try MarketArchiveState.capture(db) }
        return try MarketStateArchiveCodec.encode(state)
    }
    public func prepareRestore(_ data: Data, mode: MarketStateRestoreMode, expectedRevision: UUID) throws -> MarketStateTransferPlan {
        try Task.checkCancellation()
        let baseline = try status(); try Self.check(baseline, expectedRevision)
        let incoming = try MarketStateArchiveCodec.decode(data)
        let candidate: MarketArchiveState, existingHash: String?
        switch mode {
        case .replace:
            // Valid incoming bodies may repair corrupt old bodies. Metadata and
            // counts remain mandatory; cache rows are not read or replaced.
            candidate = incoming; existingHash = nil
        case .merge:
            let current = try capture(expectedRevision)
            try current.validate()
            candidate = try MarketArchiveState.merge(current, incoming)
            existingHash = LedgerCSV.hash(try MarketStateStore.encode(current))
        }
        try Self.check(status(), expectedRevision)
        return try prepare(operation: mode == .merge ? .merge : .replace, baseline: baseline, candidate: candidate, existingHash: existingHash)
    }
    public func prepareClear(expectedRevision: UUID) throws -> MarketStateTransferPlan {
        try Task.checkCancellation()
        let baseline = try status(); try Self.check(baseline, expectedRevision)
        return try prepare(operation: .clear, baseline: baseline, candidate: .empty, existingHash: nil)
    }
    public func prepareDelete(ids: Set<UUID>, expectedRevision: UUID) throws -> MarketStateTransferPlan {
        try Task.checkCancellation()
        guard !ids.isEmpty else { throw MarketStateStorageError.invalidPlan }
        let baseline = try status(); try Self.check(baseline, expectedRevision)
        let current = try capture(expectedRevision)
        try current.validate()
        guard ids.isSubset(of: Set(current.entries.map { $0.summary.id } + current.macroEntries.map { $0.summary.id })) else { throw MarketStateStorageError.notFound }
        let candidate = MarketArchiveState(format: MarketArchiveState.format, entries: current.entries.filter { !ids.contains($0.summary.id) }, macroEntries: current.macroEntries.filter { !ids.contains($0.summary.id) })
        return try prepare(operation: .delete, baseline: baseline, candidate: candidate,
            existingHash: LedgerCSV.hash(try MarketStateStore.encode(current)))
    }
    public func cancel(_ id: UUID) { plans.removeValue(forKey: id) }
    public func commit(_ approval: MarketStateTransferApproval) throws -> MarketStateTransferResult {
        guard let pending = plans[approval.planID], pending.plan.canCommit, pending.plan.digest == approval.digest,
              pending.plan.baseRevision == approval.revision else { throw MarketStateStorageError.invalidPlan }
        try Task.checkCancellation()
        let inject = failNextCommit; failNextCommit = false
        do {
            let result = try database.transaction { db in
                let before = try Self.metadata(db)
                try Self.check(before, approval.revision)
                guard before.counts == pending.plan.previous else { throw MarketStateStorageError.corruptedStorage }
                if let hash = pending.existingHash {
                    let current = try MarketArchiveState.capture(db)
                    guard LedgerCSV.hash(try MarketStateStore.encode(current)) == hash else { throw MarketStateStorageError.corruptedStorage }
                    if pending.plan.operation == .merge, current == pending.state {
                        return MarketStateTransferResult(revision: before.revision, counts: before.counts)
                    }
                }
                try Task.checkCancellation()
                try MarketArchiveState.clearFrozen(db)
                try pending.state.insert(db)
                if pending.plan.operation == .clear { try db.execute(sql: "DELETE FROM market_state_source_cache") }
                if inject { throw MarketStateStorageError.injectedFailure }
                try Task.checkCancellation()
                let revision = try MarketStateStore.bump(db)
                let after = try Self.metadata(db)
                guard after.counts == pending.plan.result,
                      try MarketArchiveState.capture(db) == pending.state,
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw MarketStateStorageError.corruptedStorage }
                return MarketStateTransferResult(revision: revision, counts: after.counts)
            }
            plans.removeValue(forKey: approval.planID); return result
        } catch MarketStateStorageError.staleRevision {
            plans.removeValue(forKey: approval.planID); throw MarketStateStorageError.staleRevision
        }
    }
    func injectFailureOnNextCommit() { failNextCommit = true }
    private struct Pending: Sendable {
        let plan: MarketStateTransferPlan
        let state: MarketArchiveState
        let existingHash: String?
        let bytes: Int
    }
    private func prepare(operation: MarketStateTransferOperation, baseline: MarketStateArchiveStatus,
                         candidate: MarketArchiveState, existingHash: String?) throws -> MarketStateTransferPlan {
        let bytes = try MarketStateStore.encode(candidate)
        guard bytes.count < MarketStateArchiveCodec.maximumArchiveBytes - 4096, plans.count < 8,
              plans.values.reduce(0, { $0 + $1.bytes }) <= MarketStateArchiveCodec.maximumArchiveBytes - bytes.count else { throw MarketStateStorageError.budgetExceeded }
        let id = UUID(), result = candidate.counts(cache: operation == .clear ? 0 : baseline.counts.cachedSources)
        let fields = [id.uuidString, operation.rawValue, baseline.revision.uuidString,
            LedgerCSV.hash(try MarketStateStore.encode(baseline.counts)), LedgerCSV.hash(try MarketStateStore.encode(result)),
            LedgerCSV.hash(bytes), existingHash ?? "replaceable-bodies"]
        let digest = LedgerCSV.hash(try MarketStateStore.encode(fields))
        let details = [
            operation == .clear ? "清空独立市场库的历史快照、交易归因、冻结宏观来源/桥接报告与可清理源缓存。" : "只变更独立市场库的冻结快照、交易归因、宏观来源和桥接报告，保留目标库源缓存。",
            "研究、期权、portfolio-ledger.sqlite 和 Keychain 不变；嵌入交易证据不会恢复到账本。",
            "ZIP 不加密，归档不含可清理源缓存；宏观原文件/发布证据独立冻结，快照包含重放所需的完整输入。打开前完整重算，目录不显示缓存分数。",
            "相同原始身份不同内容保留两份，结果含 \(result.conflictCopies) 份冲突副本；只重映射目录身份，不改冻结输入、报告或嵌入账本证据。重复导入按原始身份与内容哈希去重。",
            "批准只在本进程有效；字节预算不是进程内存上限。"
        ]
        let plan = MarketStateTransferPlan(id: id, digest: digest, baseRevision: baseline.revision, operation: operation,
            previous: baseline.counts, result: result, details: details, canCommit: true)
        plans[id] = Pending(plan: plan, state: candidate, existingHash: existingHash, bytes: bytes.count)
        return plan
    }
    private static func check(_ status: MarketStateArchiveStatus, _ expected: UUID) throws {
        guard status.revision == expected else { throw MarketStateStorageError.staleRevision }
    }
    private func capture(_ expected: UUID) throws -> MarketArchiveState {
        try database.read { db in try Self.check(Self.metadata(db), expected); return try MarketArchiveState.capture(db) }
    }
    static func metadata(_ db: Database) throws -> MarketStateArchiveStatus {
        let revision = try MarketStateStore.revision(db)
        let names = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*'"))
        guard names == Set(["grdb_migrations", "market_state_metadata", "market_state_catalog", "market_state_documents", "market_state_source_cache", "market_macro_catalog", "market_macro_documents", "market_macro_sources", "market_macro_observations"]) else { throw MarketStateStorageError.unsupportedFormat }
        let bodyCount = try MarketStateStore.count("market_state_documents", db) + MarketStateStore.count("market_macro_documents", db)
        let catalogCount = try MarketStateStore.count("market_state_catalog", db) + MarketStateStore.count("market_macro_catalog", db)
        // Independent counts deliberately permit repair of missing/orphaned old
        // bodies. Merge/export still demand a complete, verified graph.
        guard bodyCount <= MarketStateStore.maximumReports, catalogCount <= MarketStateStore.maximumReports else { throw MarketStateStorageError.corruptedStorage }
        let market = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_state_catalog WHERE kind='marketState'") ?? 0
        let trades = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_state_catalog WHERE kind='tradeAttribution'") ?? 0
        let macro = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_macro_catalog WHERE kind='source'") ?? 0
        let bridges = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM market_macro_catalog WHERE kind='marketBridge'") ?? 0
        guard market + trades + macro + bridges == catalogCount else { throw MarketStateStorageError.corruptedStorage }
        let conflicts = try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM market_state_catalog WHERE document_id != original_input_id) + (SELECT COUNT(*) FROM market_macro_catalog WHERE document_id != original_input_id)") ?? 0
        return .init(revision: revision, counts: .init(marketReports: market, attributionReports: trades, macroReports: macro, bridgeReports: bridges,
            frozenSources: try MarketStateStore.count("market_macro_sources", db), sourceObservations: try MarketStateStore.count("market_macro_observations", db), documentBodies: bodyCount, conflictCopies: conflicts,
            cachedSources: try MarketStateStore.count("market_state_source_cache", db)))
    }
}
