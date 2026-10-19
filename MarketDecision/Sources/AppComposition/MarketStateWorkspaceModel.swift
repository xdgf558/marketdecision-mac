import Foundation
import Observation
import MarketAnalytics
import PortfolioEngine
import Persistence

/// Page-local publication and same-environment destructive-transfer coordination.
/// Every save retains the revision captured before calculation; invalidation is
/// not a rollback and cannot rebase an old write onto a post-restore database.
@MainActor @Observable public final class MarketStateWorkspaceModel: MarketStateTransferParticipant {
    public private(set) var report: MarketStateReport?
    public private(set) var attribution: MarketTradeAttributionReport?
    public private(set) var savedID: UUID?
    public private(set) var saved: [MarketStateSummary] = []
    public private(set) var revision: UUID?
    public private(set) var status: MarketStateArchiveStatus?
    public private(set) var plan: MarketStateTransferPlan?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    public private(set) var transferEpoch = UUID()
    private let storage: any MarketStateStorage
    private let archive: any MarketStateArchiveStorage
    private let coordinator: MarketStateTransferCoordinator
    private let calculateMarket: @Sendable (MarketStateInput) async throws -> MarketStateReport
    private let calculateAttribution: @Sendable (MarketTradeAttributionInput) async throws -> MarketTradeAttributionReport
    private var generation = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var transfer: UUID?
    private var refreshed: UUID?
    private var visible = true
    private var pendingReload = false
    public init(storage: any MarketStateStorage, archive: any MarketStateArchiveStorage,
                coordinator: MarketStateTransferCoordinator = MarketStateTransferCoordinator(),
                calculateMarket: @escaping @Sendable (MarketStateInput) async throws -> MarketStateReport = { input in
                    try await Task.detached { try MarketStateEngine.calculate(input) }.value
                }, calculateAttribution: @escaping @Sendable (MarketTradeAttributionInput) async throws -> MarketTradeAttributionReport = { input in
                    try await Task.detached { try MarketTradeAttributionEngine.calculate(input) }.value
                }) {
        self.storage = storage; self.archive = archive; self.coordinator = coordinator
        self.calculateMarket = calculateMarket; self.calculateAttribution = calculateAttribution
        coordinator.register(self)
    }
    public var canEdit: Bool { committing == nil && transfer == nil && !coordinator.isTransferring && plan == nil }
    public var canSave: Bool { !isBusy && canEdit && savedID == nil && revision != nil && (report != nil || attribution != nil) }
    public var canPrepare: Bool { !isBusy && canEdit }
    public var canConfirm: Bool { !isBusy && committing == nil && !coordinator.isTransferring && plan?.canCommit == true }
    public func load() async {
        visible = true
        // The initiating page is deliberately excluded from coordinator refresh.
        // A reappearance during its own commit must therefore remember a reload
        // before the shared reservation can short-circuit this entry point.
        if committing != nil { pendingReload = true; return }
        guard !coordinator.isTransferring else { return }
        guard !isBusy else { return }
        let token = begin(); defer { finish(token) }; await readSaved(token)
    }
    public func draftChanged() {
        guard canEdit else { return }
        generation = UUID(); operation = nil; isBusy = false; clear(); message = nil; hasError = false
    }
    public nonisolated static func demoJSON(_ kind: MarketDocumentKind) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data: Data
        switch kind {
        case .marketState: data = try encoder.encode(MarketStateDemo.input())
        case .tradeAttribution: data = try encoder.encode(MarketTradeAttributionDemo.input())
        }
        return String(decoding: data, as: UTF8.self)
    }
    public func calculateJSON(_ text: String, kind: MarketDocumentKind) async {
        guard !isBusy, canEdit else { return }
        let token = begin(); clear(); defer { finish(token) }
        do {
            guard text.utf8.count <= MarketStateStore.maximumInputBytes else { throw MarketStateStorageError.budgetExceeded }
            let baseline = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            switch kind {
            case .marketState:
                let input = try JSONDecoder().decode(MarketStateInput.self, from: Data(text.utf8))
                let value = try await calculateMarket(input)
                guard owns(token), !Task.isCancelled else { return }
                guard value.input == input else { throw MarketStateStorageError.corruptedStorage }; report = value
            case .tradeAttribution:
                let input = try JSONDecoder().decode(MarketTradeAttributionInput.self, from: Data(text.utf8))
                let value = try await calculateAttribution(input)
                guard owns(token), !Task.isCancelled else { return }
                guard value.input == input else { throw MarketStateStorageError.corruptedStorage }; attribution = value
            }
            revision = baseline; message = "完整离线输入已核对，尚未保存。缺失证据不以当前值回填；结果仅供研究。"
        } catch { if owns(token), !Task.isCancelled { fail("输入、版本或时点证据未通过核对；未显示旧结果或替代分数。") } }
    }
    @discardableResult public func save() async -> Bool {
        guard canSave, let baseline = revision else { return false }
        let market = report, trades = attribution, token = begin(), commit = UUID(); committing = commit
        do {
            let id: UUID
            if let market {
                let value = try await storage.save(market.input, expectedRevision: baseline)
                guard value.replayMatched, value.report == market else { throw MarketStateStorageError.corruptedStorage }; id = value.id
            } else if let trades {
                let value = try await storage.saveAttribution(trades.input, expectedRevision: baseline)
                guard value.replayMatched, value.report == trades else { throw MarketStateStorageError.corruptedStorage }; id = value.id
            } else { throw MarketStateStorageError.invalidPlan }
            if owns(token), !Task.isCancelled { savedID = id; revision = nil; message = "已冻结完整输入、版本和结果。重开时先重算核对，不请求当前行情。"; await readSaved(token) }
            await finishCommit(token, commit); return true
        } catch {
            if owns(token), !Task.isCancelled {
                if (error as? MarketStateStorageError) == .staleRevision { clear(); fail("市场库版本已变化，请重新计算；旧保存不会取得新的写入基线。") }
                else { fail("保存未完成，保留原输入与原基线供重试，未标为已保存。") }
            }
            await finishCommit(token, commit); return false
        }
    }
    public func open(_ item: MarketStateSummary) async {
        guard !isBusy, canEdit else { return }
        let token = begin(); clear(); defer { finish(token) }
        do {
            let before = try await storage.revision()
            var market: MarketStateReport?, trades: MarketTradeAttributionReport?
            switch item.kind {
            case .marketState:
                let value = try await storage.open(id: item.id)
                guard value.id == item.id, value.report.input.id == item.originalID, value.inputHash == item.inputHash,
                      value.reportHash == item.reportHash, value.replayMatched else { throw MarketStateStorageError.corruptedStorage }; market = value.report
            case .tradeAttribution:
                let value = try await storage.openAttribution(id: item.id)
                guard value.id == item.id, value.report.id == item.originalID, value.inputHash == item.inputHash,
                      value.reportHash == item.reportHash, value.replayMatched else { throw MarketStateStorageError.corruptedStorage }; trades = value.report
            }
            let after = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            guard before == after else { throw MarketStateStorageError.staleRevision }
            report = market; attribution = trades; savedID = item.id; message = "已完整重放并核对历史冻结证据；没有联网或补填历史。"
        } catch { if owns(token), !Task.isCancelled { fail("所选快照未通过完整性、版本或重放核对，未显示缓存数值。") } }
    }
    public func exportArchive() async -> Data? {
        guard canPrepare else { return nil }; let token = begin(); defer { finish(token) }
        do { let bytes = try await archive.exportArchive(); guard owns(token), !Task.isCancelled else { return nil }; return bytes }
        catch { if owns(token), !Task.isCancelled { fail("归档生成失败，未导出不完整数据。") }; return nil }
    }
    public func prepareRestore(mode: MarketStateRestoreMode, read: @escaping @Sendable () async throws -> Data) async {
        await prepare { archive, baseline in try await archive.prepareRestore(read(), mode: mode, expectedRevision: baseline) }
    }
    public func prepareClear() async { await prepare { try await $0.prepareClear(expectedRevision: $1) } }
    public func prepareDelete(_ id: UUID) async { await prepare { try await $0.prepareDelete(ids: [id], expectedRevision: $1) } }
    private func prepare(_ action: @escaping @Sendable (any MarketStateArchiveStorage, UUID) async throws -> MarketStateTransferPlan) async {
        guard canPrepare else { return }; let token = begin(); defer { finish(token) }
        do {
            let baseline = try await archive.status(); guard owns(token), !Task.isCancelled else { return }
            let candidate = try await action(archive, baseline.revision)
            guard owns(token), !Task.isCancelled else { await archive.cancel(candidate.id); return }
            status = baseline; plan = candidate; message = "预检完成，尚未变更数据库。请核对范围后明确确认。"
        } catch { if owns(token), !Task.isCancelled { fail("归档或目标元数据未通过预检，没有变更数据库。") } }
    }
    public func cancelPlan(expectedID: UUID? = nil) async {
        guard committing == nil, let old = plan, expectedID == nil || old.id == expectedID else { return }; plan = nil
        let token = UUID(); generation = token; operation = nil; isBusy = transfer != nil
        await archive.cancel(old.id)
        guard visible, generation == token else { return }; message = "已取消预检计划，数据库未变更。"; hasError = false
    }
    @discardableResult public func confirm(_ approval: MarketStateTransferApproval) async -> Bool {
        guard canConfirm, let candidate = plan, candidate.id == approval.planID,
              candidate.digest == approval.digest, candidate.baseRevision == approval.revision,
              let shared = coordinator.begin(excluding: self) else { return false }
        let token = begin(), commit = UUID(); committing = commit; clear(); saved = []; transferEpoch = UUID()
        var succeeded = false
        do {
            let result = try await archive.commit(approval); succeeded = true
            if owns(token) { plan = nil; status = .init(revision: result.revision, counts: result.counts); message = "已提交独立市场库计划。其他业务库和 Keychain 不变。" }
        } catch {
            let stale = (error as? MarketStateStorageError) == .staleRevision
            if stale || !owns(token) { await archive.cancel(candidate.id) }
            if owns(token) {
                if stale { plan = nil; fail("计划版本已过期，请重新预检；未应用旧批准。") }
                else { fail("事务未完成，原计划与基线保留，可重试。取消只释放批准，不表示回滚事务。") }
            }
        }
        if owns(token) { await readSaved(token) }
        await coordinator.finish(shared); await finishCommit(token, commit); return succeeded
    }
    public func cancelWork() {
        guard committing == nil, transfer == nil else { return }
        generation = UUID(); operation = nil; isBusy = false; clear(); message = "已取消发布，后台计算或文件读取可能仍在收尾。"; hasError = false
    }
    public func fileOutcome(_ outcome: ResearchFileRequestFlow.Outcome) {
        switch outcome { case .succeeded: message = "归档文件已保存。"; hasError = false
        case .cancelled: message = "已取消文件操作。"; hasError = false
        case .failed: fail("文件操作未完成，请检查所选文件或保存位置。") }
    }
    public func disappear() {
        visible = false; pendingReload = false; generation = UUID(); operation = nil; clear(); saved = []; message = nil
        if committing == nil, let old = plan { plan = nil; Task { await archive.cancel(old.id) } }
        else { plan = nil }
        isBusy = committing != nil || transfer != nil
    }
    var marketStateTransferRefreshNeeded: Bool { transfer != nil && visible && refreshed != generation }
    func beginMarketStateTransfer(_ id: UUID) {
        transfer = id; refreshed = nil; generation = UUID(); operation = nil; clear(); saved = []; message = nil; isBusy = true; transferEpoch = UUID()
        if let old = plan { plan = nil; Task { await archive.cancel(old.id) } }
    }
    func refreshMarketStateTransfer(_ id: UUID) async {
        guard transfer == id, visible else { return }; let token = begin(); await readSaved(token)
        if owns(token) { refreshed = generation }; finish(token)
    }
    func endMarketStateTransfer(_ id: UUID) { guard transfer == id else { return }; transfer = nil; refreshed = nil; isBusy = operation != nil || committing != nil }
    private func begin() -> UUID { let token = UUID(); generation = token; operation = token; isBusy = true; message = nil; hasError = false; return token }
    private func owns(_ token: UUID) -> Bool { visible && generation == token && operation == token }
    private func finish(_ token: UUID) { guard operation == token else { return }; operation = nil; isBusy = committing != nil || transfer != nil }
    private func finishCommit(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }; committing = nil; finish(token)
        if operation == nil { isBusy = transfer != nil }
        if pendingReload && visible { pendingReload = false; await load() }
    }
    private func clear() { report = nil; attribution = nil; savedID = nil; revision = nil }
    private func fail(_ text: String) { message = text; hasError = true }
    private func readSaved(_ token: UUID) async {
        do {
            let values = try await storage.summaries(), metadata = try await archive.status()
            guard owns(token), !Task.isCancelled else { return }
            guard Set(values.map(\.id)).count == values.count else { throw MarketStateStorageError.corruptedStorage }
            saved = values; status = metadata; listError = nil
        } catch { if owns(token), !Task.isCancelled { saved = []; status = nil; listError = "目录或元数据读取失败，未沿用旧目录。" } }
    }
}
