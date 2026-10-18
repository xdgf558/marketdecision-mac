import Foundation
import Observation
import CoreDomain
import DataContracts
import OptionsAnalytics
import Persistence

@MainActor @Observable public final class OptionHistoryWorkspaceModel: OptionTransferParticipant {
    public private(set) var dailyReport: OptionDailyReport?
    public private(set) var historyReport: OptionVolatilityHistoryReport?
    public private(set) var savedDailyID: UUID?
    public private(set) var savedHistoryID: UUID?
    public private(set) var dailySummaries: [OptionDailySummary] = []
    public private(set) var historySummaries: [OptionVolatilityHistorySummary] = []
    public private(set) var revision: UUID?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var excludedHistoryCount = 0
    public private(set) var dailyListError: String?
    public private(set) var historyListError: String?
    private let storage: any OptionDailyStorage
    private let coordinator: OptionTransferCoordinator
    private let dailyCalculator: @Sendable (OptionDailyInput) async throws -> OptionDailyReport
    private let historyCalculator: @Sendable (OptionVolatilityHistoryInput) async throws -> OptionVolatilityHistoryReport
    private var session = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var visible = false
    private var transferOperation: UUID?
    private var refreshedSession: UUID?
    private var pendingReload = false
    public init(storage: any OptionDailyStorage, coordinator: OptionTransferCoordinator? = nil,
                dailyCalculator: @escaping @Sendable (OptionDailyInput) async throws -> OptionDailyReport = { input in
                    let work = Task.detached { try OptionDailyEngine.calculate(input) }
                    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }, historyCalculator: @escaping @Sendable (OptionVolatilityHistoryInput) async throws -> OptionVolatilityHistoryReport = { input in
                    let work = Task.detached { try OptionVolatilityHistoryEngine.calculate(input) }
                    return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }) {
        self.storage = storage; self.coordinator = coordinator ?? OptionTransferCoordinator()
        self.dailyCalculator = dailyCalculator; self.historyCalculator = historyCalculator
        self.coordinator.register(self)
    }
    public var canSaveDaily: Bool { !isBusy && !coordinator.isTransferring && dailyReport != nil && savedDailyID == nil && revision != nil }
    public var canSaveHistory: Bool { !isBusy && !coordinator.isTransferring && historyReport != nil && savedHistoryID == nil && revision != nil }
    public func load() async {
        visible = true
        guard !coordinator.isTransferring else { return }
        if committing != nil { pendingReload = true; return }
        guard !isBusy else { return }
        let token = begin(); clearResults(); revision = nil
        defer { finish(token) }
        await readRevision(token); await readSummaries(token)
    }
    public func calculateDaily(_ input: OptionDailyInput) async {
        guard !isBusy, !coordinator.isTransferring else { return }
        let token = begin(); clearResults(); defer { finish(token) }
        do {
            let value = try await dailyCalculator(input)
            guard owns(token), !Task.isCancelled else { return }
            guard value.input == input else { throw OptionLabStoreError.corruptedStorage }
            dailyReport = value; message = "已按完整离线输入计算日摘要；历史或报价缺口仍会保留，不授予市场数据资格。"
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            hasError = true; message = "日摘要输入未通过校验；没有使用手工 sigma 或其他来源填补本地 IV。"
        }
    }
    public func calculateHistory(_ input: OptionVolatilityHistoryInput) async {
        guard !isBusy, !coordinator.isTransferring else { return }
        let token = begin(); historyReport = nil; savedHistoryID = nil; defer { finish(token) }
        do { try await calculateHistory(input, token: token) }
        catch {
            guard owns(token), !Task.isCancelled else { return }
            hasError = true; message = "历史分析未通过完整输入与日历检查；未显示缓存历史数值。"
        }
    }
    public func syntheticHistory() async {
        guard !isBusy, !coordinator.isTransferring else { return }
        let token = begin(); clearResults(); defer { finish(token) }
        do {
            let work = Task.detached { try OptionVolatilityHistoryDemo.input() }
            let input = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard owns(token), !Task.isCancelled else { return }
            try await calculateHistory(input, token: token)
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            hasError = true; message = "合成历史示例未能完成；未填入替代结果。"
        }
    }
    /// The caller explicitly supplies a declared calendar. Stored dates are not
    /// inferred to be an official exchange schedule, nor filled with synthetic rows.
    public func calculateSavedHistory(sessions: [MarketDate], reference: String) async {
        guard !isBusy, !coordinator.isTransferring, let current = dailyReport,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = begin(); historyReport = nil; savedHistoryID = nil; defer { finish(token) }
        do {
            let before = try await storage.revision()
            let summaries = try await storage.dailySummaries()
            var reports: [OptionDailyReport] = [], excluded = 0
            let declaredSessions = Set(sessions)
            for summary in summaries where summary.symbol == current.input.symbol && summary.session < current.input.session {
                guard declaredSessions.contains(summary.session) else { excluded += 1; continue }
                guard owns(token), !Task.isCancelled else { return }
                let value = try await storage.openDaily(id: summary.id)
                guard value.replayMatched, value.id == summary.id else { throw OptionLabStoreError.corruptedStorage }
                let candidate = value.report
                if candidate.input.feedID == current.input.feedID,
                   candidate.input.declaredScope == current.input.declaredScope,
                   candidate.input.sessionTimeZoneID == current.input.sessionTimeZoneID,
                   candidate.input.source.origin == current.input.source.origin,
                   candidate.containsSynthetic == current.containsSynthetic,
                   candidate.modelReference == current.modelReference {
                    reports.append(candidate)
                } else { excluded += 1 }
            }
            guard try await storage.revision() == before else { throw OptionLabStoreError.staleRevision }
            guard owns(token), !Task.isCancelled else { return }
            let declaredAt = max(Date(), ([current.input.createdAt] + reports.map { $0.input.createdAt }).max() ?? Date())
            let calendar = OptionDailyCalendar(id: UUID().uuidString, version: "manual-declaration.v1", sessions: sessions,
                source: .init(origin: current.input.source.origin, reference: reference, enteredAt: declaredAt))
            let input = OptionVolatilityHistoryInput(createdAt: declaredAt, current: current, history: reports, calendar: calendar)
            try await calculateHistory(input, token: token)
            if owns(token) { excludedHistoryCount = excluded }
        } catch {
            guard owns(token), !Task.isCancelled else { return }
            hasError = true; message = "历史读取、版本或日历校验失败；请检查重复会话与来源，未使用旧历史结果。"
        }
    }
    @discardableResult public func saveDaily() async -> Bool {
        guard canSaveDaily, let report = dailyReport, let baseline = revision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let result = try await storage.saveDaily(report.input, expectedRevision: baseline)
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return true }
            guard result.replayMatched, result.report == report else { throw OptionLabStoreError.corruptedStorage }
            dailyReport = result.report; savedDailyID = result.id; message = "日摘要已保存；重开时必须完整重算核对。"
            await readRevision(token); await readSummaries(token); await finishSave(token, commit); return true
        } catch {
            if owns(token), !Task.isCancelled {
                hasError = true
                if (error as? OptionLabStoreError) == .staleRevision {
                    revision = nil; message = "期权库已变化，原基线失效。请重新载入并计算；不会自动改用新版本重试。"
                } else { message = "保存未完成；原基线保留，不自动改用新版本重试。" }
            }
            await finishSave(token, commit); return false
        }
    }
    @discardableResult public func saveHistory() async -> Bool {
        guard canSaveHistory, let report = historyReport, let baseline = revision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let result = try await storage.saveHistory(report.input, expectedRevision: baseline)
            guard owns(token), !Task.isCancelled else { await finishSave(token, commit); return true }
            guard result.replayMatched, result.report == report else { throw OptionLabStoreError.corruptedStorage }
            historyReport = result.report; savedHistoryID = result.id; message = "历史分析已保存完整输入；不会把今后的日摘要混入此冻结版本。"
            await readRevision(token); await readSummaries(token); await finishSave(token, commit); return true
        } catch {
            if owns(token), !Task.isCancelled {
                hasError = true
                if (error as? OptionLabStoreError) == .staleRevision {
                    revision = nil; message = "期权库已变化，原基线失效。请重新载入并计算；不会自动改用新版本重试。"
                } else { message = "保存未完成；原基线保留，不自动改用新版本重试。" }
            }
            await finishSave(token, commit); return false
        }
    }
    public func openDaily(_ id: UUID) async {
        guard !isBusy, !coordinator.isTransferring else { return }
        let token = begin(); clearResults(); defer { finish(token) }
        do {
            let value = try await storage.openDaily(id: id)
            guard owns(token), !Task.isCancelled else { return }
            guard value.id == id, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            dailyReport = value.report; savedDailyID = id; message = "已用完整输入重算并核对日摘要。"
        } catch { if owns(token), !Task.isCancelled { hasError = true; message = "日摘要未通过完整性或重算检查，未展示缓存数值。" } }
    }
    public func openHistory(_ id: UUID) async {
        guard !isBusy, !coordinator.isTransferring else { return }
        let token = begin(); clearResults(); defer { finish(token) }
        do {
            let value = try await storage.openHistory(id: id)
            guard owns(token), !Task.isCancelled else { return }
            guard value.id == id, value.replayMatched else { throw OptionLabStoreError.corruptedStorage }
            historyReport = value.report; savedHistoryID = id; dailyReport = value.report.input.current
            message = "已重算并核对原始日摘要、日历与历史窗口。"
        } catch { if owns(token), !Task.isCancelled { hasError = true; message = "历史分析未通过完整性或重算检查，未展示缓存数值。" } }
    }
    public func draftChanged() {
        guard committing == nil, transferOperation == nil else { return }
        session = UUID(); operation = nil; isBusy = false; clearResults(); message = nil; hasError = false
    }
    public func historyDraftChanged() {
        guard committing == nil, transferOperation == nil else { return }
        session = UUID(); operation = nil; isBusy = false; historyReport = nil; savedHistoryID = nil
        excludedHistoryCount = 0; message = nil; hasError = false
    }
    public func disappear() {
        visible = false; pendingReload = false; session = UUID(); operation = nil; clearResults()
        revision = nil; dailySummaries = []; historySummaries = []; message = nil
        isBusy = committing != nil || transferOperation != nil
    }
    var optionTransferRefreshNeeded: Bool { transferOperation != nil && visible && refreshedSession != session }
    func beginOptionTransfer(_ id: UUID) {
        transferOperation = id; refreshedSession = nil; session = UUID(); operation = nil; clearResults()
        revision = nil; dailySummaries = []; historySummaries = []; message = nil; isBusy = true
    }
    func refreshOptionTransfer(_ id: UUID) async {
        guard transferOperation == id, visible else { return }
        let token = begin(); await readRevision(token); await readSummaries(token)
        if owns(token) { refreshedSession = session }; finish(token)
    }
    func endOptionTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; refreshedSession = nil; isBusy = committing != nil || operation != nil
    }
    private func calculateHistory(_ input: OptionVolatilityHistoryInput, token: UUID) async throws {
        let result = try await historyCalculator(input)
        guard owns(token), !Task.isCancelled else { return }
        guard result.input == input else { throw OptionLabStoreError.corruptedStorage }
        historyReport = result; dailyReport = input.current
        message = "已核对历史输入。IV Rank / Percentile 仅在固定历史门槛成立时输出，不代表真实世界概率。"
    }
    private func clearResults() { excludedHistoryCount = 0; dailyReport = nil; historyReport = nil; savedDailyID = nil; savedHistoryID = nil }
    private func begin() -> UUID { let token = UUID(); session = token; operation = token; isBusy = true; message = nil; hasError = false; return token }
    private func owns(_ token: UUID) -> Bool { visible && session == token && operation == token }
    private func finish(_ token: UUID) { guard operation == token else { return }; operation = nil; isBusy = committing != nil || transferOperation != nil }
    private func finishSave(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }; committing = nil; finish(token)
        if operation == nil { isBusy = transferOperation != nil }
        if pendingReload, visible { pendingReload = false; await load() }
    }
    private func readRevision(_ token: UUID) async {
        do { let value = try await storage.revision(); guard owns(token) else { return }; revision = value }
        catch { if owns(token) { revision = nil; hasError = true; message = "期权库版本读取失败；可离线计算，但不能保存。" } }
    }
    private func readSummaries(_ token: UUID) async {
        do {
            let values = try await storage.dailySummaries(); guard owns(token) else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            dailySummaries = values; dailyListError = nil
        } catch { if owns(token) { dailySummaries = []; dailyListError = "日摘要目录读取失败，未沿用旧目录。" } }
        guard owns(token) else { return }
        do {
            let values = try await storage.historySummaries(); guard owns(token) else { return }
            guard Set(values.map(\.id)).count == values.count else { throw OptionLabStoreError.corruptedStorage }
            historySummaries = values; historyListError = nil
        } catch { if owns(token) { historySummaries = []; historyListError = "历史报告目录读取失败，未沿用旧目录。" } }
    }
}
