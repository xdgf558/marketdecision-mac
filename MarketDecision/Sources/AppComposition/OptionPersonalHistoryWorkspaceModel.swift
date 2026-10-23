import Foundation
import Observation
import PortfolioEngine
import Persistence

public struct OptionPersonalHistorySelection: Sendable, Equatable {
    public let reportID: UUID
    public let accountID: String
    public let accountName: String
    public let startDay: String
    public let endDay: String
    public let ledgerRevision: UUID
    public let isCurrentLedger: Bool
    public let history: OptionPersonalHistory
    public var statistics: PerformanceTradeStatistics { history.statistics }
    public var rounds: [PerformanceRound] { history.rounds }
    public var excludedRoundCount: Int { history.excludedRoundCount }
    public var asOf: Date { history.asOf }
    public var statisticsScope: String { OptionPersonalHistory.statisticsScope }
}

private struct Revision: Sendable, Equatable {
    let ledger: UUID
    let performance: UUID
    init(_ context: PerformanceStoreContext) { ledger = context.ledger.revision; performance = context.revision }
}

/// Explicitly invoked, read-only personal history. Its lazy factory is never
/// called by initialization, appearance, a calculation, or an option save.
@MainActor @Observable public final class OptionPersonalHistoryWorkspaceModel: LedgerTransferParticipant {
    public private(set) var accounts: [LedgerAccount] = []
    public private(set) var selectedAccountID: String?
    public private(set) var summaries: [PerformanceSummary] = []
    public private(set) var selectedReportID: UUID?
    public private(set) var result: OptionPersonalHistorySelection?
    public private(set) var hasLoadedAccounts = false
    public private(set) var hasLoadedReports = false
    public private(set) var isBusy = false
    public private(set) var hasError = false
    public private(set) var message: String?
    private let factory: @Sendable () async throws -> any PerformanceStorage
    private let coordinator: LedgerTransferCoordinator
    private var baseline: Revision?
    private var session = UUID()
    private var operation: UUID?
    private var cancelWork: (@Sendable () -> Void)?
    private var visible = false
    private var transferOperation: UUID?

    public init(storageFactory: @escaping @Sendable () async throws -> any PerformanceStorage,
                coordinator: LedgerTransferCoordinator? = nil) {
        factory = storageFactory; self.coordinator = coordinator ?? LedgerTransferCoordinator()
        self.coordinator.register(self)
    }

    public func appear() { visible = true }

    public func loadAccounts() async {
        guard visible, !Task.isCancelled, !coordinator.isTransferring else { return }
        let token = begin(); clearSelection(); accounts = []; baseline = nil
        hasLoadedAccounts = false
        defer { finish(token) }
        let factory = factory
        let work = Task.detached {
            try Task.checkCancellation()
            let storage = try await factory()
            try Task.checkCancellation()
            return try await storage.context()
        }
        cancelWork = { work.cancel() }
        do {
            let context = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard owns(token), !Task.isCancelled else { return }
            guard Set(context.ledger.accounts.map(\.id)).count == context.ledger.accounts.count else {
                throw PerformanceStoreError.corruptedStorage
            }
            accounts = context.ledger.accounts; baseline = Revision(context)
            hasLoadedAccounts = true
            message = accounts.isEmpty ? "还没有个人账户；可先在‘我的投资’记账并保存收益报告。" : "请选择一个账户和一份已保存收益报告；不会合并多份报告的重复回合。"
        } catch { fail(error, token: token) }
    }

    public func selectAccount(_ id: String) async {
        guard visible, !Task.isCancelled, !coordinator.isTransferring, accounts.contains(where: { $0.id == id }),
              let expected = baseline else { return }
        let token = begin(); clearSelection(); selectedAccountID = id
        defer { finish(token) }
        let factory = factory
        let work = Task.detached {
            let storage = try await factory()
            try Task.checkCancellation()
            let before = try await storage.context()
            guard Revision(before) == expected else { throw PerformanceStoreError.stalePlan }
            let values = try await storage.reports(accountID: id)
            try Task.checkCancellation()
            let after = try await storage.context()
            guard Revision(after) == expected else { throw PerformanceStoreError.stalePlan }
            guard Set(values.map(\.id)).count == values.count, values.allSatisfy({ $0.accountID == id }) else {
                throw PerformanceStoreError.corruptedStorage
            }
            return values
        }
        cancelWork = { work.cancel() }
        do {
            let values = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard owns(token), selectedAccountID == id, baseline == expected, !Task.isCancelled else { return }
            summaries = values; hasLoadedReports = true
            message = values.isEmpty ? "这个账户还没有已保存的收益报告；先在‘我的投资’核算并保存。" : "选择一份报告后才核对完整输入并整理个人历史；列表不代表重放已经通过。"
        } catch { fail(error, token: token) }
    }

    public func openSelected(_ id: UUID) async {
        guard visible, !Task.isCancelled, !coordinator.isTransferring, let accountID = selectedAccountID,
              let expected = baseline, let summary = summaries.first(where: { $0.id == id && $0.accountID == accountID }) else { return }
        let token = begin(); result = nil; selectedReportID = id
        defer { finish(token) }
        let factory = factory
        let work = Task.detached {
            let storage = try await factory()
            try Task.checkCancellation()
            let before = try await storage.context()
            guard Revision(before) == expected else { throw PerformanceStoreError.stalePlan }
            let saved = try await storage.open(id: id)
            try Task.checkCancellation()
            guard saved.id == id, saved.replayMatched, saved.report.input.request.accountID == accountID,
                  saved.inputHash == summary.inputHash, saved.reportHash == summary.reportHash,
                  saved.createdAt == summary.createdAt, saved.report.engineVersion == summary.engineVersion,
                  saved.ledgerRevision == summary.ledgerRevision, saved.ledgerRevision == saved.report.input.ledgerRevision,
                  saved.report.input.request.calendar.tradingDays.first == summary.startDate,
                  saved.report.input.request.calendar.tradingDays.last == summary.endDate,
                  saved.report.input.request.calendar.tradingDays.count == summary.dayCount,
                  summary.isCurrentLedger == (saved.ledgerRevision == expected.ledger),
                  saved.isCurrentLedger == (saved.ledgerRevision == expected.ledger),
                  let account = saved.report.input.accounts.first(where: { $0.id == accountID }) else {
                throw PerformanceStoreError.corruptedStorage
            }
            guard !InvestmentSummary(report: saved.report).containsSyntheticEvidence else {
                throw OptionPersonalHistoryError.syntheticEvidence
            }
            let history = try OptionPersonalHistory(report: saved.report)
            try Task.checkCancellation()
            let after = try await storage.context()
            guard Revision(after) == expected else { throw PerformanceStoreError.stalePlan }
            return OptionPersonalHistorySelection(reportID: id, accountID: accountID, accountName: account.name,
                startDay: summary.startDate, endDay: summary.endDate, ledgerRevision: saved.ledgerRevision,
                isCurrentLedger: saved.isCurrentLedger, history: history)
        }
        cancelWork = { work.cancel() }
        do {
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard owns(token), selectedAccountID == accountID, selectedReportID == id,
                  baseline == expected, !Task.isCancelled else { return }
            result = value
            message = value.statistics.displayN == 0 ? "所选冻结报告没有卖出开仓的期权经济回合；未把股票或买入期权纳入。"
                : "已重放所选报告。历史频率和策略目的成功率分别计算；不足 30 个合格样本保留计数，不显示频率。"
        } catch { fail(error, token: token) }
    }

    public func disappear() {
        visible = false; invalidate(); clearSelection(); accounts = []; baseline = nil
        hasLoadedAccounts = false; message = nil; hasError = false
    }

    private func begin() -> UUID {
        invalidate(); let token = UUID(); session = token; operation = token
        isBusy = true; hasError = false; message = nil; return token
    }
    private func owns(_ token: UUID) -> Bool { visible && session == token && operation == token }
    private func finish(_ token: UUID) {
        guard owns(token) else { return }
        operation = nil; cancelWork = nil; isBusy = transferOperation != nil
    }
    private func invalidate() {
        cancelWork?(); cancelWork = nil; session = UUID(); operation = nil
        isBusy = transferOperation != nil
    }
    private func clearSelection() {
        selectedAccountID = nil; selectedReportID = nil; summaries = []; result = nil; hasLoadedReports = false
    }
    private func fail(_ error: Error, token: UUID) {
        guard owns(token), !Task.isCancelled else { return }
        result = nil; hasError = true
        if (error as? OptionPersonalHistoryError) == .syntheticEvidence {
            message = "此报告含合成来源或示例标记，不能作为个人交易历史。期权试算结果不受影响。"
        } else if (error as? PerformanceStoreError) == .stalePlan {
            baseline = nil; selectedReportID = nil; summaries = []; hasLoadedReports = false
            message = "账本或收益报告版本已变化；请重新载入账户并明确选择报告，未发布旧统计。"
        } else if error is CancellationError {
            message = "个人历史读取已取消；未发布旧统计。"
        } else {
            message = "个人历史未通过读取、完整性或重放检查；没有用旧统计或零值替代。期权试算结果不受影响。"
        }
    }

    // A restore invalidates this view, without silently reopening the ledger or
    // choosing another saved report. The next read remains an explicit action.
    var ledgerTransferRefreshNeeded: Bool { false }
    func beginLedgerTransfer(_ id: UUID) {
        transferOperation = id; invalidate(); clearSelection(); accounts = []; baseline = nil
        hasLoadedAccounts = false; message = "账本正在恢复，原个人历史已失效。"; hasError = false
    }
    func refreshLedgerTransfer(_ id: UUID) async {}
    func endLedgerTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; isBusy = false
        if visible { message = "账本恢复流程已结束，请重新载入账户并选择报告。" }
    }
}
