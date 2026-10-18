import Foundation
import Observation
import OptionsAnalytics
import PortfolioEngine
import Persistence

/// A page-local calculation captures one immutable input. Editing, leaving, or
/// opening another snapshot invalidates publication; a save keeps its original CAS.
@MainActor @Observable public final class OptionLabWorkspaceModel: OptionTransferParticipant {
    public private(set) var portfolioGreeks: PortfolioGreeksWorkspaceModel?
    public private(set) var chain: OptionChainWorkspaceModel?
    public private(set) var history: OptionHistoryWorkspaceModel?
    public private(set) var transfer: OptionArchiveTransferModel?
    private var coordinator: OptionTransferCoordinator?
    private var transferOperation: UUID?
    private var refreshedGeneration: UUID?
    public private(set) var report: OptionLabReport?
    public private(set) var savedID: UUID?
    public private(set) var reportLedgerBasis: OptionLabLedgerBasis?
    public private(set) var saved: [OptionLabSummary] = []
    public private(set) var revision: UUID?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    public private(set) var ledgerSnapshot: LedgerSnapshot?
    public private(set) var ledgerError: String?
    private let storage: any OptionLabStorage
    private let ledgerReader: (@Sendable () async throws -> LedgerSnapshot)?
    private let calculator: @Sendable (OptionLabInput) async throws -> OptionLabReport
    private var generation = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var visible = true
    private var pendingReload = false

    public init(storage: any OptionLabStorage,
                ledgerReader: (@Sendable () async throws -> LedgerSnapshot)? = nil,
                calculator: @escaping @Sendable (OptionLabInput) async throws -> OptionLabReport = { input in
                    try await Task.detached { try OptionLabEngine.calculate(input) }.value
                }) {
        self.storage = storage; self.ledgerReader = ledgerReader; self.calculator = calculator
    }
    public var canSave: Bool { !isBusy && coordinator?.isTransferring != true && report != nil && savedID == nil && revision != nil }
    public var canReadLedger: Bool { ledgerReader != nil && !isBusy && coordinator?.isTransferring != true }

    /// Explicit handoff starts a NEW draft baseline after a chain save. It never
    /// rebases an old report, queued save or operation invalidated by clear/restore.
    public func prepareChainDraft(_ draft: OptionLabInputDraft) async throws {
        guard visible, !isBusy, coordinator?.isTransferring != true,
              let evidence = draft.chainEvidence, chain?.capture == evidence.capture else { throw OptionLabStoreError.staleRevision }
        try OptionChainEvidence.validateForLab(evidence.capture)
        let token = begin(); clearReport(); revision = nil
        defer { finish(token) }
        let baseline = try await storage.revision()
        guard owns(token), !Task.isCancelled, chain?.capture == evidence.capture else { throw CancellationError() }
        revision = baseline
    }

    public func load() async {
        visible = true
        if coordinator?.isTransferring == true { return }
        if committing != nil { pendingReload = true; return }
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); clearReport(); revision = nil; saved = []; listError = nil
        defer { finish(token) }
        do {
            let value = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            revision = value
        } catch {
            guard owns(token) else { return }
            hasError = true; message = "本地期权快照版本未能读取。仍可离线计算，但不能保存。"
        }
        guard owns(token), !Task.isCancelled else { return }
        await readSummaries(token)
    }

    public func calculate(_ input: OptionLabInput, ledgerBasis: OptionLabLedgerBasis? = nil) async {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); clearReport()
        defer { finish(token) }
        do {
            guard (input.capital.origin == .ledger && ledgerBasis?.capital == input.capital)
                    || (input.capital.origin != .ledger && ledgerBasis == nil) else { throw OptionLabError.invalidCapital }
            if let ledgerBasis {
                let verified = try await Task.detached { try OptionLabLedgerBridge.replay(ledgerBasis) }.value
                guard owns(token), !Task.isCancelled else { return }
                guard verified.capital == input.capital else { throw OptionLabError.invalidCapital }
            }
            let result = try await calculator(input)
            guard owns(token), !Task.isCancelled else { return }
            guard result.input == input else { throw OptionLabStoreError.corruptedStorage }
            report = result; reportLedgerBasis = ledgerBasis
            message = "已按这一份完整输入计算，尚未保存。研究损益不代表成交、适当性或可下单额度。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            hasError = true
            message = (error as? OptionLabError)?.errorDescription ?? "输入未通过校验。请检查报价、到期证据、策略腿、费用和资金；没有生成替代数值。"
        }
    }

    @discardableResult public func save() async -> Bool {
        guard canSave, let candidate = report, let baseline = revision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let value = try await storage.save(id: candidate.input.id, input: candidate.input, ledgerBasis: reportLedgerBasis, expectedRevision: baseline)
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return true }
            guard value.id == candidate.input.id, value.replayMatched, value.report == candidate else {
                throw OptionLabStoreError.corruptedStorage
            }
            report = value.report; savedID = value.id
            message = "已保存完整输入与结果。重开时重新计算核对；不会改用当前账本或当前报价。"
            do {
                let newRevision = try await storage.revision()
                guard owns(token) else { await finishSave(token, commit); return true }
                revision = newRevision
            } catch {
                guard owns(token) else { await finishSave(token, commit); return true }
                revision = nil; message = "快照已保存，但新版本未能读取；请重新载入后再保存其他计算。"
            }
            guard owns(token) else { await finishSave(token, commit); return true }
            await readSummaries(token)
            await finishSave(token, commit)
            return true
        } catch {
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return false }
            hasError = true
            if (error as? OptionLabStoreError) == .staleRevision {
                revision = nil
                message = "快照库已变化，原保存基线失效。请重新载入并计算；不会自动改用新版本重试。"
            } else {
                message = "保存未完成，原输入与保存基线保留，可以重试；未把失败记为已保存。"
            }
            await finishSave(token, commit)
            return false
        }
    }

    public func open(_ id: UUID) async {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); clearReport()
        defer { finish(token) }
        do {
            let value = try await storage.open(id: id)
            guard owns(token), !Task.isCancelled else { return }
            guard value.id == id, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            report = value.report; savedID = id; reportLedgerBasis = value.ledgerBasis
            message = "已用原始完整输入重新计算核对。这是历史研究快照，资金依据不会自动更新。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            hasError = true; message = "快照未通过完整性或重算检查，未显示缓存金融数值。"
        }
    }

    public func reloadSaved() async {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); defer { finish(token) }
        await readSummaries(token)
    }

    /// Reading the ledger is explicit and read-only; failure does not erase an
    /// independently calculated manual/synthetic option report.
    public func readLedger() async {
        guard canReadLedger, let ledgerReader else { return }
        let token = begin(); ledgerSnapshot = nil; ledgerError = nil
        defer { finish(token) }
        do {
            let value = try await ledgerReader()
            guard owns(token), !Task.isCancelled else { return }
            ledgerSnapshot = value
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            ledgerError = "账本读取失败，未沿用旧余额或持仓。手工假设和合成计算仍可使用。"
        }
    }

    public func draftChanged() {
        guard committing == nil, transferOperation == nil else { return }
        generation = UUID(); operation = nil; isBusy = false; clearReport(); message = nil; hasError = false
    }
    public func disappear() {
        visible = false; pendingReload = false; generation = UUID(); operation = nil
        clearReport(); revision = nil; saved = []; ledgerSnapshot = nil
        message = nil; hasError = false; listError = nil; ledgerError = nil
        isBusy = committing != nil || transferOperation != nil
    }
    public func installPortfolioGreeks(_ model: PortfolioGreeksWorkspaceModel) { portfolioGreeks = model }
    public func installChain(_ model: OptionChainWorkspaceModel) { chain = model }
    public func install(history: OptionHistoryWorkspaceModel, transfer: OptionArchiveTransferModel,
                        coordinator: OptionTransferCoordinator) {
        self.history = history; self.transfer = transfer; self.coordinator = coordinator
        coordinator.register(self)
    }
    var optionTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedGeneration != generation }
    func beginOptionTransfer(_ id: UUID) {
        transferOperation = id; refreshedGeneration = nil; generation = UUID(); operation = nil
        clearReport(); revision = nil; saved = []; message = nil; listError = nil; isBusy = true
    }
    func refreshOptionTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin()
        do {
            let value = try await storage.revision()
            guard owns(token) else { return }
            revision = value
        } catch {
            guard owns(token) else { return }
            revision = nil; hasError = true; message = "期权库版本未能读取，请重新载入。"
        }
        await readSummaries(token)
        if owns(token) { refreshedGeneration = generation }
        finish(token)
    }
    func endOptionTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; refreshedGeneration = nil; isBusy = committing != nil || operation != nil
    }
    private func begin() -> UUID {
        let token = UUID(); generation = token; operation = token; isBusy = true; hasError = false; message = nil
        return token
    }
    private func owns(_ token: UUID) -> Bool { visible && generation == token && operation == token }
    private func finish(_ token: UUID) {
        guard operation == token else { return }
        operation = nil; isBusy = committing != nil || transferOperation != nil
    }
    private func clearReport() { report = nil; savedID = nil; reportLedgerBasis = nil }
    private func finishSave(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }
        committing = nil; finish(token)
        if operation == nil { isBusy = transferOperation != nil }
        if pendingReload && visible { pendingReload = false; await load() }
    }
    private func readSummaries(_ token: UUID) async {
        do {
            let values = try await storage.summaries()
            guard owns(token), !Task.isCancelled else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            saved = values; listError = nil
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            saved = []; listError = "快照目录读取失败；不会显示旧目录，也不影响已单独核对的当前结果。"
        }
    }
}
