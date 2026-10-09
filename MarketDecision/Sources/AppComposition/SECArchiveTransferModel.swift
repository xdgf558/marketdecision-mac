import Foundation
import Observation
import DataContracts
import Persistence

/// Explicit local SEC archive actions. The file read is owned by the requesting
/// session; the storage contract owns bytes, validation, approval and atomic writes.
@MainActor @Observable public final class SECArchiveTransferModel {
    public private(set) var plan: SECArchiveRestorePlan?
    public private(set) var message: String?
    public private(set) var isBusy = false
    private let store: any SECArchiveStorage
    private weak var workspace: SECResearchWorkspaceModel?
    private let coordinator: SECArchiveWorkspaceCoordinator
    private var session = UUID()
    private var commitOperation: UUID?
    private var pendingCommitPlanID: UUID?

    public init(store: any SECArchiveStorage, workspace: SECResearchWorkspaceModel,
                coordinator: SECArchiveWorkspaceCoordinator? = nil) {
        self.store = store; self.workspace = workspace
        self.coordinator = coordinator ?? SECArchiveWorkspaceCoordinator()
        self.coordinator.register(workspace)
    }

    /// Consent is required for this action; initialization never supplies it.
    public func export(researchID: UUID, consent: SECLocalArchiveConsent) async -> Data? {
        guard !isBusy, !coordinator.isRestoring else { return nil }
        isBusy = true; message = nil
        let token = session
        defer { if token == session { isBusy = false } }
        do {
            try Task.checkCancellation()
            let bytes = try await store.exportArchive(researchID: researchID, consent: consent)
            guard token == session else { return nil }
            try Task.checkCancellation()
            return bytes
        } catch {
            if token == session {
                message = error is CancellationError ? "归档导出已取消；原研究未修改。"
                    : "归档未生成；研究完整性或本地留存范围未通过检查。原研究未修改。"
            }
            return nil
        }
    }

    public func prepare(_ bytes: Data, mode: RestoreMode, consent: SECLocalArchiveConsent) async {
        await prepare(mode: mode, consent: consent, read: { bytes })
    }

    /// Capture the session before reading a selected file. A read that finishes
    /// after dismissal cannot create a new approval in a newly opened page.
    public func prepare(mode: RestoreMode, consent: SECLocalArchiveConsent,
                        read: @Sendable () async throws -> Data) async {
        guard !isBusy, !coordinator.isRestoring else { return }
        let old = plan?.id
        session = UUID(); plan = nil; message = nil; isBusy = true
        let token = session
        defer { if token == session { isBusy = false } }
        var reading = true
        do {
            if let old { await store.cancelArchiveRestore(old) }
            guard token == session else { return }
            try Task.checkCancellation()
            let bytes = try await read()
            guard token == session else { return }
            try Task.checkCancellation()
            reading = false
            let prepared = try await store.prepareArchiveRestore(bytes, mode: mode, consent: consent)
            guard token == session, !Task.isCancelled else {
                await store.cancelArchiveRestore(prepared.id); return
            }
            plan = prepared
        } catch {
            if token == session {
                if error is CancellationError { fileCancelled() }
                else {
                    message = reading ? "归档文件读取未完成；请检查所选文件和读取权限。原库未修改。"
                        : "SEC 归档预检失败；格式、来源或引用未通过检查。原库未修改。"
                }
            }
        }
    }

    /// The displayed ID and digest authorize only that exact preview. Dismissal
    /// suppresses publication; it does not revoke a transaction already submitted.
    @discardableResult public func confirm(id: UUID, digest: String) async -> Bool {
        guard !isBusy, !Task.isCancelled, let current = plan,
              current.id == id, current.digest == digest,
              workspace != nil, let workspaceOperation = coordinator.begin() else { return false }
        let token = session, operation = UUID()
        isBusy = true; commitOperation = operation; pendingCommitPlanID = id
        defer {
            if commitOperation == operation { commitOperation = nil; isBusy = false }
        }
        let committed: Bool
        do {
            try await store.commitArchiveRestore(.init(planID: id, digest: digest))
            pendingCommitPlanID = nil
            if token == session {
                plan = nil
                message = "SEC 归档恢复已提交；请重新打开记录并显式重算。缓存结果尚未核对。"
            }
            committed = true
        } catch SnapshotError.stalePlan {
            pendingCommitPlanID = nil
            if token == session { plan = nil }
            await store.cancelArchiveRestore(id)
            if token == session { message = "SEC 研究库已变化，旧恢复计划失效。请重新预检并确认。" }
            committed = false
        } catch SnapshotError.unknownPlan {
            pendingCommitPlanID = nil
            if token == session { plan = nil }
            await store.cancelArchiveRestore(id)
            if token == session { message = "恢复计划已失效。请重新预检并确认。" }
            committed = false
        } catch {
            pendingCommitPlanID = nil
            if token == session, plan?.id == id {
                message = "SEC 恢复未提交，原库保持不变；可重试当前计划或取消。"
            } else {
                await store.cancelArchiveRestore(id)
            }
            committed = false
        }
        await coordinator.finish(workspaceOperation)
        return committed
    }

    /// Cleanup always names the abandoned plan. Never cancel an in-flight commit
    /// or allow a dismissed page to release its busy reservation before it returns.
    @discardableResult public func dismiss() -> Task<Void, Never> {
        session = UUID()
        let old = plan?.id == pendingCommitPlanID ? nil : plan?.id
        plan = nil; message = nil
        if commitOperation == nil { isBusy = false }
        return Task { if let old { await store.cancelArchiveRestore(old) } }
    }

    public func cancel() async { await dismiss().value }
    // The native view arbitrates panel callbacks with ResearchFileRequestFlow.
    // These methods do not read files, approve plans or access a provider.
    public func fileFailed() { message = "归档文件操作未完成；请检查所选位置和文件权限。" }
    public func fileCancelled() { message = "归档文件操作已取消；未由此提交恢复。" }
    public func exported() { message = "SEC 归档已导出到所选位置；本地备份未加密，请妥善保管。" }
}
