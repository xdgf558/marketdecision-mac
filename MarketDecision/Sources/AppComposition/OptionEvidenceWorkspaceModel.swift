import Foundation
import Observation
import PortfolioEngine
import OptionsAnalytics
import Persistence

/// A page-local offline document editor. Editing, leaving or replacing the
/// options database invalidates publication; SQLite CAS protects in-flight saves.
@MainActor @Observable public final class OptionEvidenceWorkspaceModel: OptionTransferParticipant {
    public private(set) var report: OptionEvidenceReport?
    public private(set) var savedID: UUID?
    public private(set) var saved: [OptionEvidenceSummary] = []
    public private(set) var revision: UUID?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    private let storage: any OptionEvidenceStorage
    private let calculator: @Sendable (OptionEvidenceInput) async throws -> OptionEvidenceReport
    private let coordinator: OptionTransferCoordinator?
    private var generation = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var transferOperation: UUID?
    private var refreshedGeneration: UUID?
    private var visible = true
    private var pendingReload = false
    public init(storage: any OptionEvidenceStorage, coordinator: OptionTransferCoordinator? = nil,
                calculator: @escaping @Sendable (OptionEvidenceInput) async throws -> OptionEvidenceReport = { input in
                    try await Task.detached { try OptionEvidenceEngine.calculate(input) }.value
                }) {
        self.storage = storage; self.coordinator = coordinator; self.calculator = calculator; coordinator?.register(self)
    }
    public var canEdit: Bool { committing == nil && transferOperation == nil && coordinator?.isTransferring != true }
    public var canSave: Bool { !isBusy && canEdit && report != nil && savedID == nil && revision != nil }
    public var canCancel: Bool { isBusy && canEdit }
    public func load() async {
        visible = true
        guard coordinator?.isTransferring != true else { return }
        if committing != nil { pendingReload = true; return }
        guard !isBusy else { return }
        let token = begin(); clear(); defer { finish(token) }; await readSaved(token)
    }
    public func draftChanged() {
        guard canEdit else { return }
        generation = UUID(); operation = nil; isBusy = false; clear(); message = nil; hasError = false
    }
    public func calculateJSON(_ text: String, kind: OptionEvidenceKind) async {
        guard !isBusy, canEdit else { return }
        let token = begin(); clear(); defer { finish(token) }
        do {
            guard text.utf8.count <= OptionEvidenceStore.maximumInputBytes else { throw OptionLabStoreError.budgetExceeded }
            let input = try JSONDecoder().decode(OptionEvidenceInput.self, from: Data(text.utf8))
            guard input.kind == kind else { throw OptionLabStoreError.incompatibleVersion }
            let baseline = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            let value = try await calculator(input)
            guard owns(token), !Task.isCancelled else { return }
            guard value.input == input else { throw OptionLabStoreError.corruptedStorage }
            report = value; revision = baseline
            message = "已按完整离线证据计算；结果只用于研究，尚未保存。供应商值不会替代本地值，未知历史不会回填。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            fail("输入、来源、时间、单位或冻结模型未通过核对；旧结果已清除，没有生成替代数值。")
        }
    }
    public static func demoJSON(_ kind: OptionEvidenceKind) throws -> String {
        let input: OptionEvidenceInput
        switch kind {
        case .providerComparison: input = .providerComparison(try OptionProviderComparisonDemo.input())
        case .delta25: input = .delta25(try OptionDelta25Demo.input())
        case .tradeAttribution: input = .tradeAttribution(try TradeOptionAttributionDemo.input())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(input), as: UTF8.self)
    }
    @discardableResult public func save() async -> Bool {
        guard canSave, let candidate = report, let baseline = revision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let value = try await storage.save(candidate.input, expectedRevision: baseline)
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return true }
            guard value.id == candidate.id, value.replayMatched, value.report == candidate else { throw OptionLabStoreError.corruptedStorage }
            report = value.report; savedID = value.id; revision = nil
            message = "已冻结完整输入、方法和结果。重新打开时先完整重算；不写入账本，也不读取当前行情。"
            await readSaved(token); await finishSave(token, commit); return true
        } catch {
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return false }
            if (error as? OptionLabStoreError) == .staleRevision {
                clear(); fail("期权库版本已变化，请重新计算；不会让旧保存沿用清空或恢复后的新版本。")
            } else { fail("保存失败，保留原计算和原基线供重试；未记为已保存。") }
            await finishSave(token, commit); return false
        }
    }
    public func open(_ id: UUID) async {
        guard !isBusy, canEdit else { return }
        let token = begin(); clear(); defer { finish(token) }
        do {
            let before = try await storage.revision(), value = try await storage.open(id: id)
            let after = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            guard before == after, value.id == id, value.report.id == id, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            report = value.report; savedID = id
            message = "已按冻结证据重新计算核对。这是历史离线报告，没有读取当前行情或补填历史。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }; fail("快照未通过完整性或重放核对，未显示缓存数值。")
        }
    }
    public func cancel() {
        guard canCancel else { return }; draftChanged(); message = "已取消发布；后台计算可能仍在收尾。"
    }
    public func disappear() {
        visible = false; pendingReload = false; generation = UUID(); operation = nil; clear(); saved = []
        message = nil; hasError = false; isBusy = committing != nil || transferOperation != nil
    }
    var optionTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedGeneration != generation }
    func beginOptionTransfer(_ id: UUID) {
        transferOperation = id; refreshedGeneration = nil; generation = UUID(); operation = nil; clear(); saved = []; message = nil; isBusy = true
    }
    func refreshOptionTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin(); await readSaved(token)
        if owns(token) { refreshedGeneration = generation }; finish(token)
    }
    func endOptionTransfer(_ id: UUID) {
        guard transferOperation == id else { return }; transferOperation = nil; refreshedGeneration = nil; isBusy = committing != nil || operation != nil
    }
    private func begin() -> UUID { let token = UUID(); generation = token; operation = token; isBusy = true; message = nil; hasError = false; return token }
    private func owns(_ token: UUID) -> Bool { visible && generation == token && operation == token }
    private func finish(_ token: UUID) { guard operation == token else { return }; operation = nil; isBusy = committing != nil || transferOperation != nil }
    private func finishSave(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }; committing = nil; finish(token)
        if operation == nil { isBusy = transferOperation != nil }
        if pendingReload && visible { pendingReload = false; await load() }
    }
    private func clear() { report = nil; savedID = nil; revision = nil }
    private func fail(_ text: String) { message = text; hasError = true }
    private func readSaved(_ token: UUID) async {
        do {
            let values = try await storage.summaries()
            guard owns(token), !Task.isCancelled else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            saved = values; listError = nil
        } catch {
            guard owns(token), !Task.isCancelled else { return }; saved = []; listError = "目录读取失败，未保留旧目录。"
        }
    }
}
