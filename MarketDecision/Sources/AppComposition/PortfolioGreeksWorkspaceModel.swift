import Foundation
import Observation
import PortfolioEngine
import OptionsAnalytics
import Persistence

/// Explicit, read-only ledger selection plus verified frozen option reports.
/// The option-store CAS is a write boundary. Ledger comparisons are observations,
/// not a cross-database transaction or a claim that the saved report stays current.
@MainActor @Observable public final class PortfolioGreeksWorkspaceModel: OptionTransferParticipant {
    public private(set) var report: PortfolioGreeksReport?
    public private(set) var savedID: UUID?
    public private(set) var saved: [PortfolioGreeksSummary] = []
    public private(set) var sources: [OptionLabSummary] = []
    public private(set) var verifiedSources: [SavedOptionLab] = []
    public private(set) var ledgerSnapshot: LedgerSnapshot?
    public private(set) var currentLedgerRevision: UUID?
    public private(set) var accountID: String?
    public private(set) var asOf: Date?
    public private(set) var positions: [LedgerLot] = []
    public private(set) var bindings: [PortfolioGreeksBinding] = []
    public private(set) var revision: UUID?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    public private(set) var sourceError: String?
    private let storage: any PortfolioGreeksStorage
    private let experiments: any OptionLabStorage
    private let ledgerReader: (@Sendable () async throws -> LedgerSnapshot)?
    private let calculator: @Sendable (PortfolioGreeksInput) async throws -> PortfolioGreeksReport
    private let coordinator: OptionTransferCoordinator?
    private var generation = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var transferOperation: UUID?
    private var refreshedGeneration: UUID?
    private var visible = true
    private var pendingReload = false

    public init(storage: any PortfolioGreeksStorage, experiments: any OptionLabStorage,
                ledgerReader: (@Sendable () async throws -> LedgerSnapshot)? = nil,
                coordinator: OptionTransferCoordinator? = nil,
                calculator: @escaping @Sendable (PortfolioGreeksInput) async throws -> PortfolioGreeksReport = { input in
                    try await Task.detached { try PortfolioGreeksEngine.calculate(input) }.value
                }) {
        self.storage = storage; self.experiments = experiments; self.ledgerReader = ledgerReader
        self.coordinator = coordinator; self.calculator = calculator; coordinator?.register(self)
    }
    public var canSave: Bool { !isBusy && coordinator?.isTransferring != true && report != nil && savedID == nil && revision != nil }
    public var canCancel: Bool { isBusy && committing == nil && transferOperation == nil }
    public var canReadLedger: Bool { !isBusy && coordinator?.isTransferring != true && ledgerReader != nil }
    public var canCalculateLedger: Bool { !isBusy && coordinator?.isTransferring != true && accountID != nil && asOf != nil && ledgerSnapshot != nil }

    /// Opens metadata only. It never reads a ledger, credential or transport.
    public func load() async {
        visible = true
        guard coordinator?.isTransferring != true else { return }
        if committing != nil { pendingReload = true; return }
        guard !isBusy else { return }
        let token = begin(); clearAll(); defer { finish(token) }
        await readCatalogs(token)
    }
    public func readLedger() async {
        guard canReadLedger, let ledgerReader else { return }
        let token = begin(); clearDraft(); ledgerSnapshot = nil; currentLedgerRevision = nil
        defer { finish(token) }
        do {
            let value = try await ledgerReader()
            guard owns(token), !Task.isCancelled else { return }
            ledgerSnapshot = value; currentLedgerRevision = value.revision
            message = "已只读载入账本。选择账户与评估时刻，再逐项绑定已核对的本地报告；未自动选择报价。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            fail("账本读取失败，旧持仓和旧组合结果已失效；没有沿用缓存持仓。")
        }
    }
    public func configure(accountID selected: String, asOf cutoff: Date) async {
        guard !isBusy, coordinator?.isTransferring != true, let snapshot = ledgerSnapshot else { return }
        let token = begin(); clearDraft(); defer { finish(token) }
        do {
            guard cutoff.timeIntervalSinceReferenceDate.isFinite,
                  snapshot.accounts.contains(where: { $0.id == selected }) else { throw PortfolioGreeksError.invalidInput }
            let lots = try await Task.detached {
                try LedgerEngine.replay(accounts: snapshot.accounts, events: snapshot.events.filter { $0.effectiveAt <= cutoff })
                    .lots.filter { $0.accountID == selected && !$0.isClosed }
            }.value
            guard owns(token), !Task.isCancelled, ledgerSnapshot?.revision == snapshot.revision else { return }
            accountID = selected; asOf = cutoff; positions = lots
            message = "已确定 \(lots.count) 个未平仓批次。缺少绑定、报价或 IV 的项目会明确列为缺口，不计作零风险。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            fail("账户与所选时刻的账本不能完整重放，未生成持仓列表。")
        }
    }
    /// A source is usable only after full open/replay, never by choosing a catalog row.
    public func openSource(_ id: UUID) async {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); clearReport(); revision = nil
        verifiedSources.removeAll { $0.id == id }; bindings.removeAll { $0.reportID == id }
        defer { finish(token) }
        do {
            let before = try await storage.revision()
            let value = try await experiments.open(id: id)
            let after = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            guard before == after, value.id == id, value.replayMatched,
                  value.report.input.id == id else { throw OptionLabStoreError.corruptedStorage }
            verifiedSources.append(value); sourceError = nil
            message = "已按完整输入核对选中报告。尚未绑定持仓；普通账本不能使用合成证据。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            sourceError = "选中来源未通过重放或读取期间版本已变化；未保留它的旧绑定或数值。"
        }
    }
    public func bind(instrumentIdentity: String, reportID: UUID, contractID: String?) {
        guard !isBusy, coordinator?.isTransferring != true,
              positions.contains(where: { $0.instrument.identity == instrumentIdentity }),
              verifiedSources.contains(where: { $0.id == reportID }) else { return }
        invalidateCalculation()
        bindings.removeAll { $0.instrumentIdentity == instrumentIdentity }
        bindings.append(.init(instrumentIdentity: instrumentIdentity, reportID: reportID, contractID: contractID))
    }
    public func removeBinding(_ instrumentIdentity: String) {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        invalidateCalculation(); bindings.removeAll { $0.instrumentIdentity == instrumentIdentity }
    }
    /// Editing account/time cannot retain the previously accepted selection or report.
    public func evidenceSelectionChanged() {
        guard committing == nil, transferOperation == nil else { return }
        generation = UUID(); operation = nil; isBusy = false; invalidateCalculation()
    }
    public func draftChanged() {
        guard committing == nil, transferOperation == nil else { return }
        generation = UUID(); operation = nil; isBusy = false; clearDraft(); message = nil; hasError = false
    }
    public func calculate() async {
        guard canCalculateLedger, let snapshot = ledgerSnapshot, let accountID, let asOf, let ledgerReader else { return }
        let sourceIDs = Set(bindings.map(\.reportID))
        let input = PortfolioGreeksInput(createdAt: Date(), asOf: asOf, mode: .ledger, accountID: accountID,
            ledgerRevision: snapshot.revision, accounts: snapshot.accounts.filter { $0.id == accountID }, events: snapshot.events.filter { $0.accountID == accountID },
            reports: verifiedSources.filter { sourceIDs.contains($0.id) }.map(\.report), bindings: bindings)
        let token = begin(); clearReport(); revision = nil; defer { finish(token) }
        do {
            let baseline = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            let before = try await ledgerReader()
            guard owns(token), !Task.isCancelled else { return }
            currentLedgerRevision = before.revision
            guard before.revision == input.ledgerRevision else { throw OptionLabStoreError.staleRevision }
            let value = try await calculator(input)
            guard owns(token), !Task.isCancelled else { return }
            let after = try await ledgerReader()
            guard owns(token), !Task.isCancelled else { return }
            currentLedgerRevision = after.revision
            guard after.revision == input.ledgerRevision else { throw OptionLabStoreError.staleRevision }
            guard value.input == input else { throw OptionLabStoreError.corruptedStorage }
            report = value; revision = baseline
            message = "已按冻结账本和选定证据计算。版本核对不是跨库锁；保存后始终是历史研究快照。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            if (error as? OptionLabStoreError) == .staleRevision {
                positions = []; accountIDReset(); fail("计算期间账本已变化，请重新读取账本并选择证据；未发布旧组合结果。")
            } else { fail((error as? PortfolioGreeksError)?.errorDescription ?? "组合输入或来源未通过核对，没有生成替代风险数值。") }
        }
    }
    public func calculateSynthetic(includeMissing: Bool) async {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); clearDraft(); ledgerSnapshot = nil; currentLedgerRevision = nil
        defer { finish(token) }
        do {
            let baseline = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            let example = try PortfolioGreeksDemo.input(includeMissing: includeMissing)
            let input = PortfolioGreeksInput(id: UUID(), createdAt: example.createdAt, asOf: example.asOf,
                mode: .synthetic, accountID: example.accountID, ledgerRevision: example.ledgerRevision,
                accounts: example.accounts, events: example.events, reports: example.reports, bindings: example.bindings)
            let value = try await calculator(input)
            guard owns(token), !Task.isCancelled else { return }
            guard value.input == input, value.input.mode == .synthetic else { throw OptionLabStoreError.corruptedStorage }
            report = value; revision = baseline
            message = "SYNTHETIC · 独立合成组合示例，不是当前账户；不会填补普通账本的证据缺口。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }; fail("合成示例未能完整核对，没有生成替代结果。")
        }
    }
    @discardableResult public func save() async -> Bool {
        guard canSave, let candidate = report, let baseline = revision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            if candidate.input.mode == .ledger {
                guard let ledgerReader else { throw OptionLabStoreError.staleRevision }
                let current = try await ledgerReader()
                guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return false }
                currentLedgerRevision = current.revision
                guard current.revision == candidate.input.ledgerRevision else { throw OptionLabStoreError.staleRevision }
            }
            let value = try await storage.save(candidate.input, expectedRevision: baseline)
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return true }
            guard value.id == candidate.id, value.replayMatched, value.report == candidate else { throw OptionLabStoreError.corruptedStorage }
            report = value.report; savedID = value.id
            message = "已保存历史研究快照。冻结原账本版本与来源；不表示此刻的持仓仍然相同，也不改写账本。"
            revision = nil
            await readSaved(token)
            await finishSave(token, commit); return true
        } catch {
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return false }
            if (error as? OptionLabStoreError) == .staleRevision {
                clearReport(); revision = nil
                fail("原账本或期权库保存基线已失效。请重新读取并计算，不会自动改用新版本重试。")
            } else { fail("保存失败，原计算与原保存基线保留供重试；未记为已保存。") }
            await finishSave(token, commit); return false
        }
    }
    public func open(_ id: UUID) async {
        guard !isBusy, coordinator?.isTransferring != true else { return }
        let token = begin(); clearDraft(); defer { finish(token) }
        do {
            let before = try await storage.revision(), value = try await storage.open(id: id)
            let after = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            guard before == after, value.id == id, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            report = value.report; savedID = id
            message = "已用冻结账本和来源重新计算核对。没有读取当前账本、行情或凭据；这是历史报告。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }; fail("快照未通过完整性或重放核对，未显示缓存风险数值。")
        }
    }
    public func checkLedgerRevision() async {
        guard canReadLedger, let ledgerReader, let candidate = report, candidate.input.mode == .ledger else { return }
        let token = begin(); currentLedgerRevision = nil; defer { finish(token) }
        do {
            let current = try await ledgerReader()
            guard owns(token), !Task.isCancelled, report?.id == candidate.id else { return }
            currentLedgerRevision = current.revision
            if current.revision != candidate.input.ledgerRevision && savedID == nil {
                clearReport(); revision = nil; fail("当前账本已变化，未保存结果已失效；请重新读取并计算。")
            } else {
                message = current.revision == candidate.input.ledgerRevision
                    ? "本次读取的账本版本与冻结版本相同；这次观察不保证随后仍相同。"
                    : "本次读取的账本版本已不同；保留的是已核对历史报告，未更新其输入或数值。"
            }
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            fail("当前账本版本未能核对；历史报告不代表当前组合。")
        }
    }
    /// Cancellation invalidates publication. Detached replay may finish its CPU
    /// work; this is not a resource-completion receipt or cancellation deadline.
    public func cancel() {
        guard canCancel else { return }
        generation = UUID(); operation = nil; isBusy = false; clearDraft(); message = "读取或计算已取消；迟到结果不再发布。"; hasError = false
    }
    public func disappear() {
        visible = false; pendingReload = false; generation = UUID(); operation = nil; clearAll()
        message = nil; hasError = false; isBusy = committing != nil || transferOperation != nil
    }
    var optionTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedGeneration != generation }
    func beginOptionTransfer(_ id: UUID) {
        transferOperation = id; refreshedGeneration = nil; generation = UUID(); operation = nil
        clearAll(); message = nil; isBusy = true
    }
    func refreshOptionTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin(); await readCatalogs(token)
        if owns(token) { refreshedGeneration = generation }; finish(token)
    }
    func endOptionTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; refreshedGeneration = nil; isBusy = committing != nil || operation != nil
    }
    private func begin() -> UUID {
        let token = UUID(); generation = token; operation = token; isBusy = true; hasError = false; message = nil; return token
    }
    private func owns(_ token: UUID) -> Bool { visible && generation == token && operation == token }
    private func finish(_ token: UUID) {
        guard operation == token else { return }; operation = nil; isBusy = committing != nil || transferOperation != nil
    }
    private func finishSave(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }; committing = nil; finish(token)
        if operation == nil { isBusy = transferOperation != nil }
        if pendingReload && visible { pendingReload = false; await load() }
    }
    private func clearReport() { report = nil; savedID = nil }
    private func accountIDReset() { accountID = nil; asOf = nil; bindings = [] }
    private func clearDraft() { clearReport(); accountIDReset(); positions = []; revision = nil }
    private func clearAll() {
        clearDraft(); ledgerSnapshot = nil; currentLedgerRevision = nil; saved = []; sources = []; verifiedSources = []
        listError = nil; sourceError = nil
    }
    private func invalidateCalculation() { clearReport(); revision = nil; message = nil; hasError = false }
    private func fail(_ text: String) { hasError = true; message = text }
    private func readSaved(_ token: UUID) async {
        do {
            let values = try await storage.summaries()
            guard owns(token), !Task.isCancelled else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            saved = values; listError = nil
        } catch {
            guard owns(token), !Task.isCancelled else { return }; saved = []; listError = "组合报告目录未能核对，没有保留旧目录。"
        }
    }
    private func readCatalogs(_ token: UUID) async {
        await readSaved(token)
        guard owns(token), !Task.isCancelled else { return }
        do {
            let values = try await experiments.summaries()
            guard owns(token), !Task.isCancelled else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            sources = values; sourceError = nil
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            sources = []; verifiedSources = []; bindings = []; sourceError = "来源报告目录未能核对，没有沿用旧来源或绑定。"
        }
    }
}
