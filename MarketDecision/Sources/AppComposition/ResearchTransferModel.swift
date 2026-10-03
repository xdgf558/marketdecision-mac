import Foundation
import Observation
import DataContracts
import FundamentalsEngine
import Persistence

@MainActor @Observable public final class ResearchTransferModel {
    public private(set) var plan: ResearchTransferPlan?
    public private(set) var conflicts: [WatchlistConflict] = []
    public private(set) var message: String?
    public private(set) var isBusy = false
    private let store: any ResearchTransferStorage
    private var session = UUID()
    private var conflictRequest = UUID()
    private var commitOperation: UUID?
    private var pendingCommitPlanID: UUID?
    private var committing: Bool { commitOperation != nil }
    var commitWillBegin: (() -> Void)?
    var commitDidFinish: (() async -> Void)?
    public init(store: any ResearchTransferStorage) { self.store = store }
    public func backup() async -> Data? {
        guard !isBusy else { return nil }; isBusy = true; message = nil
        let token = session
        defer { if token == session { isBusy = false } }
        do {
            let bytes = try await store.exportBackup()
            guard token == session else { return nil }
            try Task.checkCancellation(); return bytes
        } catch {
            if token == session {
                message = error is CancellationError ? "文件操作已取消；本地业务数据未修改。":"备份未生成；研究完整性或留存权限检查失败。原库未修改。"
            }
            return nil
        }
    }
    public func prepare(_ bytes: Data, mode: RestoreMode) async {
        await prepare(mode: mode, read: { bytes })
    }
    /// Own the selected-file read as part of the preview. A late read must not
    /// acquire a new session after the page that requested it has disappeared.
    public func prepare(mode: RestoreMode, read: @Sendable () async throws -> Data) async {
        guard !isBusy else { return }
        let (token, old) = beginPreview()
        defer { if token == session { isBusy = false } }
        var reading = true
        do {
            if let old { await store.cancel(old) }
            guard token == session else { return }; try Task.checkCancellation()
            let bytes = try await read()
            guard token == session else { return }; try Task.checkCancellation()
            reading = false
            let prepared = try await store.prepare(bytes,mode:mode)
            guard token == session, !Task.isCancelled else { await store.cancel(prepared.id); return }
            plan = prepared
        } catch {
            if token == session {
                if error is CancellationError { fileCancelled() }
                else { message = reading ? "文件读取未完成；请检查所选文件和读取权限。原库未修改。":"恢复预检失败：包无效、版本不支持或内容校验失败。原库未修改。" }
            }
        }
    }
    public func prepareClear() async {
        guard !isBusy else { return }
        let (token, old) = beginPreview()
        defer { if token == session { isBusy = false } }
        do {
            if let old { await store.cancel(old) }
            guard token == session else { return }; try Task.checkCancellation()
            let prepared = try await store.prepareClear()
            guard token == session, !Task.isCancelled else { await store.cancel(prepared.id); return }
            plan = prepared
        } catch {
            if token == session { message = error is CancellationError ? "预检已取消；原库未修改。":"清空预检失败；原库未修改。" }
        }
    }
    /// Fix identity and busy ownership before the first suspension, including
    /// cleanup of an earlier plan that the storage actor has not processed yet.
    private func beginPreview() -> (UUID, UUID?) {
        let old = plan?.id
        session = UUID(); conflictRequest = UUID(); plan = nil; message = nil; isBusy = true
        return (session, old)
    }
    /// UI must supply the displayed plan identity. A stale sheet cannot approve a newer plan.
    public func confirm(id: UUID, digest: String) async -> Bool {
        guard !isBusy, let current = plan, current.id == id, current.digest == digest else { return false }
        let token = session, operation = UUID()
        isBusy = true; commitOperation = operation; pendingCommitPlanID = id; conflictRequest = UUID()
        // This reservation includes the workspace refresh. Dismissal invalidates
        // publication, but cannot give a newer operation this busy reservation.
        defer {
            if commitOperation == operation { commitOperation = nil; isBusy = false }
        }
        commitWillBegin?()
        let committed: Bool
        do {
            try await store.commit(.init(planID:id,digest:digest))
            pendingCommitPlanID = nil
            if token == session {
                plan = nil; message = "操作已提交。API Key 与外部备份文件未变。"
                conflicts = []
                let request = UUID(); conflictRequest = request
                do {
                    let entries = try await store.conflicts()
                    if token == session, conflictRequest == request { conflicts = entries }
                } catch {
                    if token == session, conflictRequest == request { message = "操作已提交，但冲突列表读取失败。请重新读取；不要重复提交。" }
                }
            }
            committed = true
        } catch SnapshotError.stalePlan {
            pendingCommitPlanID = nil
            if token == session { plan = nil }
            // Storage already removes stale plans. This idempotent cleanup also
            // covers other protocol implementations; it never rolls back a write.
            await store.cancel(id)
            if token == session { message = "数据已变化，旧计划失效。请重新预检并确认。" }
            committed = false
        } catch {
            pendingCommitPlanID = nil
            if token == session, plan?.id == id {
                message = "提交未完成，原库保持不变；可重试当前计划或取消。"
            } else {
                // Commit has returned. Release only its abandoned in-memory
                // approval; do not claim that cancellation undoes the transaction.
                await store.cancel(id)
            }
            committed = false
        }
        await commitDidFinish?()
        return committed
    }
    /// Invalidate synchronously; delayed storage cleanup can only cancel this exact old ID.
    @discardableResult public func dismiss() -> Task<Void,Never> {
        session = UUID(); conflictRequest = UUID()
        // Once confirm has begun, leaving the page cannot revoke an in-flight
        // transaction. After it returns, an abandoned failed plan can be released
        // even while the shared workspace is still refreshing.
        let old = plan?.id == pendingCommitPlanID ? nil : plan?.id; plan = nil
        if !committing { isBusy = false }
        return Task { if let old { await store.cancel(old) } }
    }
    public func cancel() async { await dismiss().value }
    public func readConflicts() async {
        guard !committing else { return }
        let request = UUID(); conflictRequest = request
        do {
            let entries = try await store.conflicts()
            guard request == conflictRequest, !Task.isCancelled else { return }
            conflicts = entries
        } catch {
            guard request == conflictRequest, !Task.isCancelled else { return }
            conflicts = []; message = "冲突列表读取失败，不将损坏记录作为有效结果。"
        }
    }
    public func fileFailed() { message = "文件操作未完成；请检查所选位置和文件权限。" }
    public func fileCancelled() { message = "文件操作已取消；本地业务数据未修改。" }
    public func exported() { message = "文件已导出到你选择的位置；备份不加密，请妥善保管。" }
}
