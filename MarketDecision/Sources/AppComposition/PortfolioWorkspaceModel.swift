import Foundation
import Observation
import PortfolioEngine
import Persistence

public enum PortfolioDisplayOrigin: String, Sendable { case none, preview, frozen, synthetic }

/// Page-local state. Every preview captures both revisions before suspension;
/// only storage can freeze the result against the same ledger and evidence history.
@MainActor @Observable public final class PortfolioWorkspaceModel {
    public private(set) var context: PerformanceStoreContext?
    public private(set) var selectedAccountID: String?
    public private(set) var preview: PerformancePreview?
    public private(set) var report: PerformanceReport?
    public private(set) var displayedRequest: PerformanceRequest?
    public private(set) var savedReport: SavedPerformanceReport?
    public private(set) var saved: [PerformanceSummary] = []
    public private(set) var origin: PortfolioDisplayOrigin = .none
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    private let storage: any PerformanceStorage
    private var generation = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var visible = true

    public init(storage: any PerformanceStorage) { self.storage = storage }
    public var canPrepare: Bool { !isBusy && context != nil && selectedAccountID != nil }
    public var canSave: Bool { !isBusy && preview != nil && origin == .preview }

    public func load() async {
        visible = true
        guard !isBusy else { return }
        let previous = takePreview(), token = begin()
        clearReport(); context = nil
        defer { finish(token) }
        if let previous { await storage.cancel(planID: previous.id) }
        guard owns(token) else { return }
        await reloadContext(token)
        guard owns(token) else { return }
        await reloadReports(token)
    }

    public func chooseAccount(_ accountID: String) async {
        guard !isBusy, context?.ledger.accounts.contains(where: { $0.id == accountID }) == true else { return }
        let previous = takePreview(), token = begin()
        selectedAccountID = accountID; saved = []; clearReport()
        defer { finish(token) }
        if let previous { await storage.cancel(planID: previous.id) }
        guard owns(token) else { return }
        await reloadReports(token)
    }

    public func prepare(_ request: PerformanceRequest, rawRequest: Data? = nil) async {
        guard canPrepare, let baseline = context, let accountID = selectedAccountID else { return }
        guard request.accountID == accountID else {
            draftChanged(); hasError = true; message = "证据中的账户与当前选择不一致，未计算或保存。"; return
        }
        let previous = takePreview(), token = begin()
        clearReport()
        defer { finish(token) }
        if let previous { await storage.cancel(planID: previous.id) }
        guard owns(token), !Task.isCancelled else { return }
        do {
            let value = try await storage.prepare(request: request, rawRequest: rawRequest,
                expectedLedgerRevision: baseline.ledger.revision, expectedPerformanceRevision: baseline.revision)
            guard owns(token), !Task.isCancelled else { await storage.cancel(planID: value.id); return }
            preview = value; report = value.report; displayedRequest = request; origin = .preview
            message = "已按当前账本与显式证据计算，尚未冻结。请核对估值缺口、会话和收益分段；缺失数据不当作零。"
        } catch {
            guard owns(token) else { return }
            if (error as? PerformanceStoreError) == .stalePlan { context = nil }
            hasError = true; message = "计算未完成。请核对账户版本、官方会话、输入时间与来源证据；不会用当前报价补历史。"
        }
    }

    @discardableResult public func save(id: UUID, ledgerRevision: UUID, performanceRevision: UUID) async -> Bool {
        guard canSave, let candidate = preview, candidate.id == id,
              candidate.ledgerRevision == ledgerRevision, candidate.performanceRevision == performanceRevision else { return false }
        let token = begin(), commit = UUID()
        committing = commit
        do {
            let result = try await storage.commit(planID: id, expectedLedgerRevision: ledgerRevision,
                                                 expectedPerformanceRevision: performanceRevision)
            if owns(token) {
                preview = nil; savedReport = result; report = result.report; origin = .frozen
                message = "本地估值与收益报告已冻结。重开时会用原账本与原证据复算，不会悄悄改用当前数据。"
                await reloadContext(token)
                guard owns(token) else { await finishCommit(token: token, commit: commit); return true }
                await reloadReports(token, afterSave: true)
            }
            await finishCommit(token: token, commit: commit)
            return true
        } catch {
            if owns(token) {
                hasError = true
                if (error as? PerformanceStoreError) == .stalePlan || (error as? PerformanceStoreError) == .invalidPlan {
                    preview = nil; clearReport(); context = nil
                    await storage.cancel(planID: id)
                    if owns(token) { message = "账本或估值记录已变化，原计划失效。请重新载入并计算；未替换批准基线。" }
                } else {
                    message = "冻结未完成，原预览与版本保留，可以重试；不代表已经保存。"
                }
            } else { await storage.cancel(planID: id) }
            await finishCommit(token: token, commit: commit)
            return false
        }
    }

    public func open(_ id: UUID) async {
        guard !isBusy else { return }
        let previous = takePreview(), token = begin()
        clearReport()
        defer { finish(token) }
        if let previous { await storage.cancel(planID: previous.id) }
        guard owns(token), !Task.isCancelled else { return }
        do {
            let result = try await storage.open(id: id)
            guard owns(token), !Task.isCancelled else { return }
            guard result.id == id, result.replayMatched, result.report.input.request.accountID == selectedAccountID else { throw PerformanceStoreError.corruptedStorage }
            savedReport = result; report = result.report; displayedRequest = result.report.input.request; origin = .frozen
            message = result.isCurrentLedger ? "已按原冻结输入重算核对；报告对应当前账本版本。"
                : "已按原冻结输入重算核对；当前账本已经变化，这份报告保留为历史版本，不代表当前组合。"
        } catch {
            guard owns(token) else { return }
            hasError = true; message = "冻结报告未能通过来源、引用或复算检查；未显示缓存数值。"
        }
    }

    public func showSyntheticExample() async {
        guard !isBusy else { return }
        let previous = takePreview(), token = begin()
        clearReport()
        defer { finish(token) }
        if let previous { await storage.cancel(planID: previous.id) }
        guard owns(token), !Task.isCancelled else { return }
        do {
            let value = try await Task.detached {
                try PerformanceEngine.calculate(PortfolioSyntheticExample.input())
            }.value
            guard owns(token), !Task.isCancelled else { return }
            report = value; displayedRequest = value.input.request; origin = .synthetic
            message = "独立合成教学示例，仅在内存中；不会改动当前账户，也不能冻结为普通账户历史。"
        } catch {
            guard owns(token) else { return }
            hasError = true; message = "合成示例未能计算；没有生成或保存替代值。"
        }
    }

    public func reloadSaved() async {
        guard !isBusy else { return }
        let token = begin()
        defer { finish(token) }
        await reloadReports(token)
    }

    public func cancelPreview() async {
        guard committing == nil else { return }
        generation = UUID(); operation = nil; isBusy = false
        let previous = takePreview(); clearReport()
        message = "估值预览已取消，未冻结报告。"; hasError = false
        if let previous { await storage.cancel(planID: previous.id) }
    }

    public func draftChanged() {
        guard committing == nil else { return }
        generation = UUID(); operation = nil; isBusy = false
        let previous = takePreview(); clearReport(); message = nil; hasError = false
        if let previous { Task { [storage] in await storage.cancel(planID: previous.id) } }
    }

    public func disappear() {
        visible = false; generation = UUID(); operation = nil
        let previous = takePreview(); context = nil; saved = []; clearReport(); message = nil; hasError = false
        if committing == nil {
            isBusy = false
            if let previous { Task { [storage] in await storage.cancel(planID: previous.id) } }
        }
    }

    private func begin() -> UUID {
        let token = UUID(); generation = token; operation = token; isBusy = true; hasError = false; message = nil
        return token
    }
    private func owns(_ token: UUID) -> Bool { visible && generation == token && operation == token }
    private func finish(_ token: UUID) {
        guard operation == token else { return }
        operation = nil; isBusy = committing != nil
    }
    private func finishCommit(token: UUID, commit: UUID) async {
        guard committing == commit else { return }
        committing = nil
        if operation == token { finish(token) }
        else { isBusy = false; if visible { await load() } }
    }
    private func takePreview() -> PerformancePreview? { let old = preview; preview = nil; return old }
    private func clearReport() { report = nil; displayedRequest = nil; savedReport = nil; origin = .none }
    /// Refresh only the known ledger-status label. The original input and
    /// validated report remain immutable; failed or absent reads supply no guess.
    private func updateCurrentLedgerLabel(_ isCurrent: Bool) {
        guard let frozen = savedReport, frozen.isCurrentLedger != isCurrent else { return }
        savedReport = SavedPerformanceReport(id: frozen.id, createdAt: frozen.createdAt, report: frozen.report,
            inputHash: frozen.inputHash, reportHash: frozen.reportHash, ledgerRevision: frozen.ledgerRevision,
            isCurrentLedger: isCurrent, replayMatched: frozen.replayMatched)
    }
    private func reloadContext(_ token: UUID) async {
        do {
            let value = try await storage.context()
            guard owns(token), !Task.isCancelled else { return }
            context = value
            if let frozen = savedReport { updateCurrentLedgerLabel(frozen.ledgerRevision == value.ledger.revision) }
            if !value.ledger.accounts.contains(where: { $0.id == selectedAccountID }) { selectedAccountID = value.ledger.accounts.first?.id }
        } catch {
            guard owns(token) else { return }
            context = nil; hasError = true; message = "账本读取或校验失败，未显示旧组合余额；冻结报告列表可单独重试。"
        }
    }
    private func reloadReports(_ token: UUID, afterSave: Bool = false) async {
        guard let account = selectedAccountID else { saved = []; listError = nil; return }
        do {
            let value = try await storage.reports(accountID: account)
            guard owns(token), !Task.isCancelled else { return }
            saved = value; listError = nil
            if let frozen = savedReport, let summary = value.first(where: { $0.id == frozen.id && $0.ledgerRevision == frozen.ledgerRevision }) {
                updateCurrentLedgerLabel(summary.isCurrentLedger)
            }
        } catch {
            guard owns(token) else { return }
            saved = []; listError = "报告列表无法读取，可单独重试；当前账本与证据输入仍可使用。"
            if afterSave { message = "报告已冻结，但列表刷新失败。请重新载入列表，避免重复保存。" }
        }
    }
}
