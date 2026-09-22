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
    var commitWillBegin: (() -> Void)?
    var commitDidFinish: (() async -> Void)?
    public init(store: any ResearchTransferStorage) { self.store = store }
    public func backup() async -> Data? {
        guard !isBusy else { return nil }; isBusy = true; message = nil
        defer { isBusy = false }
        do { let bytes = try await store.exportBackup(); try Task.checkCancellation(); return bytes }
        catch { message = "备份未生成；研究完整性或留存权限检查失败。原库未修改。"; return nil }
    }
    public func prepare(_ bytes: Data, mode: RestoreMode) async {
        guard !isBusy else { return }; isBusy = true
        await cancel(); message = nil; let token = session
        defer { isBusy = false }
        do {
            let prepared = try await store.prepare(bytes,mode:mode)
            guard token == session, !Task.isCancelled else { await store.cancel(prepared.id); return }
            plan = prepared
        } catch { if token == session { message = "恢复预检失败：包无效、版本不支持或内容校验失败。原库未修改。" } }
    }
    public func prepareClear() async {
        guard !isBusy else { return }; isBusy = true
        await cancel(); message = nil; let token = session
        defer { isBusy = false }
        do {
            let prepared = try await store.prepareClear()
            guard token == session, !Task.isCancelled else { await store.cancel(prepared.id); return }
            plan = prepared
        } catch { if token == session { message = "清空预检失败；原库未修改。" } }
    }
    /// UI must supply the displayed plan identity. A stale sheet cannot approve a newer plan.
    public func confirm(id: UUID, digest: String) async -> Bool {
        guard !isBusy, let current = plan, current.id == id, current.digest == digest else { return false }
        isBusy = true; defer { isBusy = false }
        commitWillBegin?()
        let committed: Bool
        do {
            try await store.commit(.init(planID:id,digest:digest))
            plan = nil; message = "操作已提交。API Key 与外部备份文件未变。"
            do { conflicts = try await store.conflicts() }
            catch { conflicts = []; message = "操作已提交，但冲突列表读取失败。请重新读取；不要重复提交。" }
            committed = true
        } catch SnapshotError.stalePlan {
            plan = nil; message = "数据已变化，旧计划失效。请重新预检并确认。"; committed = false
        } catch {
            message = "提交未完成，原库保持不变；可重试当前计划或取消。"; committed = false
        }
        await commitDidFinish?()
        return committed
    }
    /// Invalidate synchronously; delayed storage cleanup can only cancel this exact old ID.
    @discardableResult public func dismiss() -> Task<Void,Never> {
        session = UUID()
        let old = plan?.id; plan = nil
        return Task { if let old { await store.cancel(old) } }
    }
    public func cancel() async { await dismiss().value }
    public func readConflicts() async {
        do { conflicts = try await store.conflicts() }
        catch { conflicts = []; message = "冲突列表读取失败，不将损坏记录作为有效结果。" }
    }
    public func fileFailed() { message = "文件操作未完成；请检查所选位置和文件权限。" }
    public func exported() { message = "文件已导出到你选择的位置；备份不加密，请妥善保管。" }
}
