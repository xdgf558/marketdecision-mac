import Foundation
import Observation
import Persistence

public struct OptionArchiveExportPayload: Sendable {
    public let bytes: Data
    public let filename: String
    public let contentType: String
    public init(bytes: Data, filename: String, contentType: String) {
        self.bytes = bytes; self.filename = filename; self.contentType = contentType
    }
}
/// Approvals stay page-local. The shared coordinator invalidates all visible option
/// pages; the store's fixed revision is the final write boundary across processes.
@MainActor @Observable public final class OptionArchiveTransferModel: OptionTransferParticipant {
    public private(set) var status: OptionLabArchiveStatus?
    public private(set) var plan: OptionLabTransferPlan?
    public private(set) var message: String?
    public private(set) var isBusy = false
    public private(set) var hasError = false
    public private(set) var transferEpoch = UUID()
    private let store: any OptionLabArchiveStorage
    private let coordinator: OptionTransferCoordinator
    private var session = UUID()
    private var visible = false
    private var operation: UUID?
    private var committing: UUID?
    private var pendingCommitID: UUID?
    private var transferOperation: UUID?
    private var refreshedSession: UUID?
    public init(store: any OptionLabArchiveStorage, coordinator: OptionTransferCoordinator? = nil) {
        self.store = store; self.coordinator = coordinator ?? OptionTransferCoordinator()
        self.coordinator.register(self)
    }
    public var canPrepare: Bool { !isBusy && !coordinator.isTransferring && status != nil }
    public var canConfirm: Bool { canPrepare && plan?.canCommit == true }
    public func load() async {
        visible = true
        guard !isBusy, !coordinator.isTransferring else { return }
        let old = takePlan(), token = begin()
        defer { finish(token) }
        if let old { await store.cancel(old) }
        guard owns(token) else { return }
        await readStatus(token)
    }
    public func export() async -> OptionArchiveExportPayload? {
        guard !isBusy, !coordinator.isTransferring else { return nil }
        let token = begin(); defer { finish(token) }
        do {
            let bytes = try await store.exportArchive()
            guard owns(token), !Task.isCancelled else { return nil }
            return .init(bytes: bytes, filename: "MarketDecision-options-backup.zip", contentType: "application/zip")
        } catch {
            guard owns(token) else { return nil }
            hasError = !(error is CancellationError)
            message = error is CancellationError ? "导出已取消，期权库未修改。" : "归档未生成：完整性或重放检查失败。"
            return nil
        }
    }
    public func prepare(_ bytes: Data, mode: OptionLabRestoreMode) async { await prepare(mode: mode, read: { bytes }) }
    public func prepare(mode: OptionLabRestoreMode, read: @Sendable () async throws -> Data) async {
        guard canPrepare, let baseline = status else { return }
        let old = takePlan(), token = begin(); defer { finish(token) }
        do {
            if let old { await store.cancel(old) }
            guard owns(token), !Task.isCancelled else { return }
            let bytes = try await read()
            guard owns(token), !Task.isCancelled else { return }
            let result = try await store.prepareRestore(bytes, mode: mode, expectedRevision: baseline.revision)
            guard owns(token), !Task.isCancelled else { await store.cancel(result.id); return }
            plan = result
        } catch {
            guard owns(token) else { return }
            if (error as? OptionLabArchiveError) == .stalePlan { status = nil }
            hasError = !(error is CancellationError)
            message = error is CancellationError ? "读取或预检已取消，期权库未修改。" : "恢复预检未完成；备份、身份或版本不符，未修改原库。请刷新元数据后重试。"
        }
    }
    public func prepareClear() async {
        guard canPrepare, let baseline = status else { return }
        let old = takePlan(), token = begin(); defer { finish(token) }
        do {
            if let old { await store.cancel(old) }
            guard owns(token), !Task.isCancelled else { return }
            let result = try await store.prepareClear(expectedRevision: baseline.revision)
            guard owns(token), !Task.isCancelled else { await store.cancel(result.id); return }
            plan = result
        } catch {
            guard owns(token) else { return }
            if (error as? OptionLabArchiveError) == .stalePlan { status = nil }
            hasError = true; message = "清空预检失败，未生成清空批准；请刷新元数据。"
        }
    }
    @discardableResult public func confirm(_ approval: OptionLabTransferApproval) async -> Bool {
        guard canConfirm, let current = plan, OptionLabTransferApproval(plan: current) == approval,
              !Task.isCancelled, let boundary = coordinator.begin(excluding: self) else { return false }
        let token = begin(), commit = UUID(); committing = commit; pendingCommitID = approval.planID
        let succeeded: Bool
        do {
            let result = try await store.commit(approval)
            pendingCommitID = nil
            if owns(token) {
                plan = nil; status = .init(revision: result.revision, counts: result.counts)
                message = "期权库操作已提交。研究库、实际账本库、设置、Keychain 和外部文件不变。"
            }
            succeeded = true
        } catch {
            pendingCommitID = nil
            if owns(token) {
                hasError = true
                if (error as? OptionLabArchiveError) == .stalePlan || (error as? OptionLabArchiveError) == .invalidPlan {
                    plan = nil; status = nil; await store.cancel(approval.planID)
                    if owns(token) { message = "期权库版本或计划已失效，请刷新并重新预检。" }
                } else { message = "提交失败，事务未完成；当前页保留原计划，可重试或取消。" }
            } else { await store.cancel(approval.planID) }
            succeeded = false
        }
        await coordinator.finish(boundary)
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
        let old = takePlan(); message = "预检已取消，期权库未修改。"; hasError = false
        if let old { await store.cancel(old) }
    }
    public func dismiss() {
        visible = false; transferEpoch = UUID(); session = UUID(); operation = nil
        let old = plan?.id == pendingCommitID ? nil : takePlan()
        plan = nil; status = nil; message = nil
        isBusy = committing != nil || transferOperation != nil
        if let old { Task { [store] in await store.cancel(old) } }
    }
    public func cancelFileWork() {
        guard committing == nil, transferOperation == nil else { return }
        session = UUID(); operation = nil; isBusy = false
        if let old = takePlan() { Task { [store] in await store.cancel(old) } }
    }
    public func fileCancelled() { hasError = false; message = "文件操作已取消，期权库未修改。" }
    public func fileFailed() { hasError = true; message = "文件操作未完成，请核对所选位置与权限。" }
    public func exported() { hasError = false; message = "文件已写入所选位置。普通 ZIP 未加密，可读 CSV / Markdown 不能用于恢复。" }
    var optionTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedSession != session }
    func beginOptionTransfer(_ id: UUID) {
        transferOperation = id; refreshedSession = nil; transferEpoch = UUID(); session = UUID(); operation = nil; isBusy = true
        let old = takePlan(); status = nil; message = nil
        if let old { Task { [store] in await store.cancel(old) } }
    }
    func refreshOptionTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin(); await readStatus(token)
        if owns(token) { refreshedSession = session }
        finish(token)
    }
    func endOptionTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; refreshedSession = nil; isBusy = committing != nil || operation != nil
    }
    private func begin() -> UUID { let token = UUID(); session = token; operation = token; isBusy = true; message = nil; hasError = false; return token }
    private func owns(_ token: UUID) -> Bool { visible && session == token && operation == token }
    private func finish(_ token: UUID) { guard operation == token else { return }; operation = nil; isBusy = committing != nil || transferOperation != nil }
    private func takePlan() -> UUID? { let old = plan?.id; plan = nil; return old }
    private func readStatus(_ token: UUID) async {
        do {
            let result = try await store.status()
            guard owns(token), !Task.isCancelled else { return }
            status = result
        } catch {
            guard owns(token) else { return }
            status = nil; hasError = true; message = "期权库元数据读取失败，不能生成或确认恢复计划。"
        }
    }
}
