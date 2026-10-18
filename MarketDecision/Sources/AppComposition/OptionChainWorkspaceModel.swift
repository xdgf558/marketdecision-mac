import Foundation
import Observation
import CoreDomain
import DataContracts
import MarketDataProviders
import OptionsAnalytics
import Persistence

@MainActor @Observable public final class OptionChainWorkspaceModel: OptionTransferParticipant {
    public private(set) var capture: OptionChainCapture?
    public private(set) var saved: [OptionChainSummary] = []
    public private(set) var savedID: UUID?
    public private(set) var revision: UUID?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    private let storage: any OptionChainStorage
    private let collector: @Sendable () async throws -> OptionChainCapture
    private let coordinator: OptionTransferCoordinator
    private var collectionTask: Task<OptionChainCapture, Error>?
    private var session = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var visible = false
    private var pendingReload = false
    private var transferOperation: UUID?
    private var refreshedSession: UUID?

    public init(storage: any OptionChainStorage, coordinator: OptionTransferCoordinator? = nil,
                collector: @escaping @Sendable () async throws -> OptionChainCapture = {
                    try await OptionChainSyntheticCollection.capture()
                }) {
        self.storage = storage; self.coordinator = coordinator ?? OptionTransferCoordinator(); self.collector = collector
        self.coordinator.register(self)
    }
    public var canSave: Bool { !isBusy && !coordinator.isTransferring && capture != nil && savedID == nil && revision != nil }
    public var canCancel: Bool { isBusy && committing == nil && transferOperation == nil && !coordinator.isTransferring }

    public func load() async {
        visible = true
        guard !coordinator.isTransferring else { return }
        if committing != nil { pendingReload = true; return }
        guard !isBusy else { return }
        let token = begin(); clearCapture(); revision = nil; defer { finish(token) }
        await readRevision(token); await readSummaries(token)
    }
    public func loadSynthetic() async {
        guard !isBusy, !coordinator.isTransferring, visible else { return }
        let token = begin(); clearCapture(); revision = nil; defer { finish(token) }
        // Bind the write baseline before the first asynchronous provider request.
        await readRevision(token)
        guard owns(token), !Task.isCancelled else { return }
        do {
            let collector = collector
            let work = Task { try await collector() }; collectionTask = work
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard owns(token), !Task.isCancelled else { return }
            try value.validate()
            guard value.synthetic else { throw ContractError.invalidIdentity }
            capture = value
            message = "已接受并重放合成原始响应。完整仅指所请求到期范围；不授予实时、PIT或真实供应商资格。"
        } catch {
            guard owns(token) else { return }
            hasError = !Task.isCancelled && !(error is CancellationError)
            message = hasError ? "采集或来源校验失败，未展示旧链或替代报价。" : "采集已取消，迟到响应不会发布。"
        }
        if owns(token) { collectionTask = nil }
    }
    @discardableResult public func saveCapture() async -> Bool {
        guard canSave, let candidate = capture, let baseline = revision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let value = try await storage.save(candidate, expectedRevision: baseline)
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return true }
            guard value.id == candidate.id, value.capture == candidate, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            capture = value.capture; savedID = value.id; message = "已保存原始响应、接受依据与完整链；重开时重新解析核对。"
            await readRevision(token); await readSummaries(token); await finishSave(token, commit); return true
        } catch {
            if owns(token), !Task.isCancelled {
                hasError = true
                if (error as? OptionLabStoreError) == .staleRevision {
                    revision = nil; message = "期权库已变化，原保存基线失效；请重新载入，不自动换用新版本。"
                } else { message = "保存未完成，原输入与基线保留；未把失败记为已保存。" }
            }
            await finishSave(token, commit); return false
        }
    }
    public func open(_ id: UUID) async {
        guard visible, !isBusy, !coordinator.isTransferring else { return }
        let token = begin(); clearCapture(); revision = nil; defer { finish(token) }
        do {
            let before = try await storage.revision()
            let value = try await storage.open(id: id)
            guard owns(token), !Task.isCancelled else { return }
            guard try await storage.revision() == before else { throw OptionLabStoreError.staleRevision }
            guard owns(token), !Task.isCancelled else { return }
            guard value.id == id, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            try value.capture.validate()
            capture = value.capture; savedID = id; revision = before
            message = "已重新解析全部原始页并核对保存的链；这是冻结采集，不是当前市场报价。"
        } catch {
            if owns(token), !Task.isCancelled { hasError = true; message = "采集未通过完整性或版本检查，没有展示缓存报价。" }
        }
    }
    public func makeDraft(strategy: OptionLabStrategy, shortID: String, longID: String?, quantity: Int) throws -> OptionLabInputDraft {
        guard visible, !isBusy, !coordinator.isTransferring, let capture else { throw OptionLabDraftError.missingField }
        return try OptionChainLabBridge.draft(capture, strategy: strategy, shortID: shortID, longID: longID, quantity: quantity)
    }
    public func makeDailyInput(rate: Money, dividendYield: Money, settlements: [String: Date], tick: Money,
                               assumptionReference: String, declaredClose: Bool) throws -> OptionDailyInput {
        guard visible, !isBusy, !coordinator.isTransferring, let capture, savedID == capture.id else { throw OptionLabDraftError.missingField }
        return try OptionChainLabBridge.daily(capture, rate: rate, dividendYield: dividendYield, settlements: settlements,
            tick: tick, assumptionReference: assumptionReference, declaredClose: declaredClose)
    }
    public func cancel() {
        guard committing == nil, transferOperation == nil else { return }
        collectionTask?.cancel(); collectionTask = nil; session = UUID(); operation = nil; isBusy = false
        clearCapture(); revision = nil; message = "采集已取消，迟到响应不会发布。"; hasError = false
    }
    public func disappear() {
        visible = false; pendingReload = false; collectionTask?.cancel(); collectionTask = nil
        session = UUID(); operation = nil; clearCapture(); saved = []; revision = nil; message = nil
        isBusy = committing != nil || transferOperation != nil
    }
    var optionTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedSession != session }
    func beginOptionTransfer(_ id: UUID) {
        collectionTask?.cancel(); collectionTask = nil; transferOperation = id; refreshedSession = nil
        session = UUID(); operation = nil; clearCapture(); saved = []; revision = nil; message = nil; isBusy = true
    }
    func refreshOptionTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin(); await readRevision(token); await readSummaries(token)
        if owns(token) { refreshedSession = session }; finish(token)
    }
    func endOptionTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; refreshedSession = nil; isBusy = operation != nil || committing != nil
    }
    private func begin() -> UUID { let token = UUID(); session = token; operation = token; isBusy = true; message = nil; hasError = false; return token }
    private func owns(_ token: UUID) -> Bool { visible && session == token && operation == token }
    private func finish(_ token: UUID) { guard operation == token else { return }; operation = nil; isBusy = committing != nil || transferOperation != nil }
    private func clearCapture() { capture = nil; savedID = nil }
    private func finishSave(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }; committing = nil; finish(token)
        if operation == nil { isBusy = transferOperation != nil }
        if pendingReload, visible { pendingReload = false; await load() }
    }
    private func readRevision(_ token: UUID) async {
        do { let value = try await storage.revision(); guard owns(token) else { return }; revision = value }
        catch { if owns(token) { revision = nil; hasError = true; message = "期权库版本读取失败；不能保存这次采集。" } }
    }
    private func readSummaries(_ token: UUID) async {
        do {
            let values = try await storage.summaries(); guard owns(token) else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            saved = values; listError = nil
        } catch { if owns(token) { saved = []; listError = "链采集目录读取失败，未沿用旧目录。" } }
    }
}
