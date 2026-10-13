import Foundation
import Observation
import PortfolioEngine
import Persistence

public enum LedgerExportKind: String, CaseIterable, Sendable {
    case transactions, positions, realizations, cash, daily, performancePositions, sources, metrics, monthlyCSV, monthlyMarkdown, backup
    public var requiresReport: Bool { [.daily, .performancePositions, .sources, .metrics, .monthlyCSV, .monthlyMarkdown].contains(self) }
}
public struct LedgerExportPayload: Sendable {
    public let bytes: Data
    public let filename: String
    public let contentType: String
}
/// Page-local approval/file state; the shared coordinator owns UI invalidation,
/// while exact SQLite revisions protect all writes across pages and processes.
@MainActor @Observable public final class LedgerTransferModel: LedgerTransferParticipant {
    public private(set) var status: LedgerArchiveStatus?
    public private(set) var plan: LedgerTransferPlan?
    public private(set) var conflicts: [LedgerArchiveConflictSummary] = []
    public private(set) var message: String?
    public private(set) var conflictError: String?
    public private(set) var isBusy = false
    public private(set) var hasError = false
    public private(set) var transferEpoch = UUID()
    private let store: any LedgerArchiveStorage
    private let ledger: any LedgerStorage
    private let performance: any PerformanceStorage
    private let coordinator: LedgerTransferCoordinator
    private var session = UUID()
    private var visible = true
    private var operation: UUID?
    private var committing: UUID?
    private var pendingCommitID: UUID?
    private var transferOperation: UUID?
    private var refreshedSession: UUID?
    public init(store: any LedgerArchiveStorage, ledger: any LedgerStorage, performance: any PerformanceStorage,
                coordinator: LedgerTransferCoordinator? = nil) {
        self.store = store; self.ledger = ledger; self.performance = performance
        self.coordinator = coordinator ?? LedgerTransferCoordinator()
        self.coordinator.register(self)
    }
    public var canPrepare: Bool { !isBusy && !coordinator.isTransferring && status != nil }
    public var canConfirm: Bool { canPrepare && plan?.canCommit == true }
    public func load() async {
        visible = true
        guard !isBusy, !coordinator.isTransferring else { return }
        let previous = takePlan(), token = begin()
        defer { finish(token) }
        if let previous { await store.cancel(previous) }
        guard owns(token) else { return }
        await readStatus(token)
        await readConflicts(token)
    }
    public func export(_ kind: LedgerExportKind, reportID: UUID? = nil) async -> LedgerExportPayload? {
        guard !isBusy, !coordinator.isTransferring else { return nil }
        let token = begin()
        defer { finish(token) }
        do {
            let result: LedgerExportPayload
            if kind == .backup {
                let bytes = try await store.exportArchive()
                result = .init(bytes: bytes, filename: "MarketDecision-ledger-backup.zip", contentType: "application/zip")
            } else if kind.requiresReport {
                guard let reportID else { throw LedgerArchiveError.notFound }
                let frozen = try await performance.open(id: reportID)
                guard owns(token), !Task.isCancelled else { return nil }
                guard frozen.id == reportID, frozen.replayMatched else { throw LedgerArchiveError.corruptedStorage }
                let rendered = try await Task.detached { try PortfolioExports.performance(frozen.report) }.value
                let document: PortfolioExportDocument
                switch kind {
                case .daily: document = rendered.daily
                case .performancePositions: document = rendered.positions
                case .sources: document = rendered.sources
                case .metrics: document = rendered.metrics
                case .monthlyCSV: document = rendered.monthlyCSV
                default: document = rendered.monthlyMarkdown
                }
                result = .init(bytes: document.data, filename: document.suggestedFilename, contentType: document.contentType)
            } else {
                let snapshot = try await ledger.snapshot()
                guard owns(token), !Task.isCancelled else { return nil }
                let rendered = try await Task.detached {
                    try PortfolioExports.ledger(accounts: snapshot.accounts, events: snapshot.events, revision: snapshot.revision)
                }.value
                let document: PortfolioExportDocument
                switch kind {
                case .transactions: document = rendered.transactions
                case .positions: document = rendered.positions
                case .realizations: document = rendered.realizations
                default: document = rendered.cashBalances
                }
                result = .init(bytes: document.data, filename: document.suggestedFilename, contentType: document.contentType)
            }
            guard owns(token), !Task.isCancelled else { return nil }
            return result
        } catch {
            guard owns(token) else { return nil }
            hasError = !(error is CancellationError)
            message = error is CancellationError ? "导出已取消，未修改本地账本。" : "导出未生成；完整性、冻结复算或格式检查失败。不会导出缓存摘要作为金融结果。"
            return nil
        }
    }
    public func exportConflict(_ id: UUID) async -> LedgerExportPayload? {
        guard !isBusy, !coordinator.isTransferring else { return nil }
        let token = begin()
        defer { finish(token) }
        do {
            let bytes = try await store.exportConflict(id: id)
            guard owns(token), !Task.isCancelled else { return nil }
            return .init(bytes: bytes, filename: "ledger-conflict-\(id.uuidString).zip", contentType: "application/zip")
        } catch {
            guard owns(token) else { return nil }
            hasError = true; message = "冲突原包未导出；没有将隔离内容并入活动账本。"; return nil
        }
    }
    public func prepare(_ bytes: Data, mode: LedgerRestoreMode) async { await prepare(mode: mode, read: { bytes }) }
    public func prepare(mode: LedgerRestoreMode, read: @Sendable () async throws -> Data) async {
        guard canPrepare, let baseline = status else { return }
        let previous = takePlan(), token = begin()
        defer { finish(token) }
        var reading = true
        do {
            if let previous { await store.cancel(previous) }
            guard owns(token), !Task.isCancelled else { return }
            let data = try await read()
            guard owns(token), !Task.isCancelled else { return }
            reading = false
            let result = try await store.prepareRestore(data, mode: mode, expectedLedgerRevision: baseline.ledgerRevision,
                                                        expectedPerformanceRevision: baseline.performanceRevision)
            guard owns(token), !Task.isCancelled else { await store.cancel(result.id); return }
            plan = result
            if !result.canCommit { hasError = true; message = "存在身份或内容冲突，本计划不能写入活动账本。可取消后明确选择“隔离保留冲突原包”再预检。" }
        } catch {
            guard owns(token) else { return }
            if (error as? LedgerArchiveError) == .stalePlan { status = nil }
            hasError = !(error is CancellationError)
            message = error is CancellationError ? "读取/预检已取消，账本未修改。"
                : reading ? "备份读取失败；没有生成恢复批准。" : "恢复预检失败；请核对归档与版本，必要时重新载入元数据。原库未修改。"
        }
    }
    public func prepareClear() async {
        guard canPrepare, let baseline = status else { return }
        let previous = takePlan(), token = begin()
        defer { finish(token) }
        do {
            if let previous { await store.cancel(previous) }
            guard owns(token), !Task.isCancelled else { return }
            let result = try await store.prepareClear(expectedLedgerRevision: baseline.ledgerRevision, expectedPerformanceRevision: baseline.performanceRevision)
            guard owns(token), !Task.isCancelled else { await store.cancel(result.id); return }
            plan = result
        } catch {
            guard owns(token) else { return }
            if (error as? LedgerArchiveError) == .stalePlan { status = nil }
            hasError = true; message = "清空预检未完成；原库未修改，需重新载入元数据。"
        }
    }
    @discardableResult public func confirm(_ approval: LedgerTransferApproval) async -> Bool {
        guard canConfirm, let current = plan, LedgerTransferApproval(plan: current) == approval,
              !Task.isCancelled, let boundary = coordinator.begin(excluding: self) else { return false }
        let token = begin(), commit = UUID()
        committing = commit; pendingCommitID = approval.planID
        let succeeded: Bool
        do {
            let result = try await store.commit(approval)
            pendingCommitID = nil
            if owns(token) {
                plan = nil; status = .init(ledgerRevision: result.ledgerRevision, performanceRevision: result.performanceRevision, counts: result.counts)
                message = "账本与收益操作已提交；研究库、设置、Keychain 与外部文件不变。"
            }
            succeeded = true
        } catch {
            pendingCommitID = nil
            if owns(token) {
                hasError = true
                if (error as? LedgerArchiveError) == .stalePlan || (error as? LedgerArchiveError) == .invalidPlan {
                    plan = nil; status = nil; await store.cancel(approval.planID)
                    if owns(token) { message = "账本或收益版本已变化，原计划失效；请重新载入并预检。" }
                } else { message = "提交失败，事务未完成；当前页保留原计划，可重试或取消。" }
            } else { await store.cancel(approval.planID) }
            succeeded = false
        }
        // Finish global invalidation even if this view left or its task cancelled.
        await coordinator.finish(boundary)
        if owns(token) { await readConflicts(token) }
        if committing == commit { committing = nil }
        if operation == token { finish(token) }
        else {
            isBusy = transferOperation != nil
            if visible, !isBusy { await load() }
        }
        return succeeded
    }
    public func cancel() async {
        guard committing == nil, transferOperation == nil else { return }
        session = UUID(); operation = nil; isBusy = false
        let previous = takePlan(); message = "预检已取消，账本与收益记录未修改。"; hasError = false
        if let previous { await store.cancel(previous) }
    }
    public func dismiss() {
        visible = false; transferEpoch = UUID(); session = UUID(); operation = nil
        let old = plan?.id == pendingCommitID ? nil : takePlan()
        plan = nil; status = nil; conflicts = []; message = nil; conflictError = nil
        isBusy = committing != nil || transferOperation != nil
        if let old { Task { [store] in await store.cancel(old) } }
    }
    public func cancelFileWork() {
        guard committing == nil, transferOperation == nil else { return }
        session = UUID(); operation = nil; isBusy = false
        let old = takePlan()
        if let old { Task { [store] in await store.cancel(old) } }
    }
    public func fileCancelled() { hasError = false; message = "文件操作已取消；本地账本未修改。" }
    public func fileFailed() { hasError = true; message = "文件操作未完成，请核对所选位置与权限。" }
    public func exported() { hasError = false; message = "文件已写入你选择的位置。普通 ZIP 未加密，报表 CSV/Markdown 不能用来恢复账本。" }
    var ledgerTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedSession != session }
    func beginLedgerTransfer(_ id: UUID) {
        transferOperation = id; refreshedSession = nil; transferEpoch = UUID(); session = UUID(); operation = nil; isBusy = true
        let old = takePlan(); status = nil; conflicts = []; message = nil
        if let old { Task { [store] in await store.cancel(old) } }
    }
    func refreshLedgerTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin()
        await readStatus(token); await readConflicts(token)
        if owns(token) { refreshedSession = session }
        finish(token)
    }
    func endLedgerTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; refreshedSession = nil; isBusy = committing != nil || operation != nil
    }
    private func begin() -> UUID {
        let token = UUID(); session = token; operation = token; isBusy = true; message = nil; hasError = false; return token
    }
    private func owns(_ token: UUID) -> Bool { visible && session == token && operation == token }
    private func finish(_ token: UUID) {
        guard operation == token else { return }
        operation = nil; isBusy = committing != nil || transferOperation != nil
    }
    private func takePlan() -> UUID? { let value = plan?.id; plan = nil; return value }
    private func readStatus(_ token: UUID) async {
        do {
            let result = try await store.status()
            guard owns(token), !Task.isCancelled else { return }
            status = result
        } catch {
            guard owns(token) else { return }
            status = nil; hasError = true; message = "账本元数据读取失败，不能生成或确认恢复计划。"
        }
    }
    private func readConflicts(_ token: UUID) async {
        do {
            let result = try await store.conflicts()
            guard owns(token), !Task.isCancelled else { return }
            conflicts = result; conflictError = nil
        } catch {
            guard owns(token) else { return }
            conflicts = []; conflictError = "隔离冲突列表读取失败；不能把空列表当作无冲突。"
        }
    }
}
