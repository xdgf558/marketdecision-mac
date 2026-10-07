import Foundation
import Observation
import DataContracts
import FundamentalsEngine
import Persistence

public enum SECResearchConfigurationError: Error { case invalidContact, networkDisabled }

/// Contact identity belongs only to this explicit request. It is never part of the saved
/// document, source metadata, error message or diagnostic log.
public struct SECContactIdentity: Sendable {
    public let email: String
    public var userAgent: String { "MarketDecision/0.1 " + email }
    public init(email: String) throws {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 160,
              clean.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}\z"#,
                          options: .regularExpression) != nil,
              !clean.contains("..") else { throw SECResearchConfigurationError.invalidContact }
        self.email = clean
    }
}

public protocol SECResearchWorkspaceStorage: Sendable {
    func savedResearch() async throws -> [SECResearchSummary]
    func open(id: UUID) async throws -> SECResearchDocument
}
extension SECResearchStore: SECResearchWorkspaceStorage {}

public protocol SECFinancialReportWorkspaceStorage: Sendable {
    func prepareFinancialReport(parentID: UUID, executionDate: Date) async throws -> SECFinancialReportDraft
    func saveFinancialReport(_ document: SECFinancialReportDocument, expectedRevision: UUID) async throws
    func savedFinancialReports(parentID: UUID?) async throws -> [SECFinancialReportSummary]
    func openFinancialReport(id: UUID) async throws -> SECFinancialReportDocument
}
extension SECResearchStore: SECFinancialReportWorkspaceStorage {}

public enum SECFinancialReportDisplayState: Sendable, Equatable {
    case notVerified, generated, matched, mismatched, failed
}

public typealias SECResearchImport = @Sendable (String, SECContactIdentity,
    @escaping @Sendable (SECResearchProgress) async -> Void) async throws -> SECResearchDocument

/// A page owns its task, progress and replay status. Opening a page only reads the isolated
/// local store. Neither startup, selection nor replay constructs a network session.
@MainActor @Observable public final class SECResearchWorkspaceModel {
    public private(set) var ticker = "MSFT"
    public let networkAvailable: Bool
    public private(set) var document: SECResearchDocument?
    public private(set) var saved: [SECResearchSummary] = []
    public private(set) var progress: SECResearchProgress?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var listError: String?
    public private(set) var hasError = false
    public private(set) var recomputationState: OfflineIssuerRecomputationState = .notVerified
    public var canDisplayValues: Bool { document != nil && recomputationState == .matched }
    public private(set) var financialReport: SECFinancialReportDocument?
    public private(set) var savedFinancialReports: [SECFinancialReportSummary] = []
    public private(set) var financialReportState: SECFinancialReportDisplayState = .notVerified
    public private(set) var financialReportIsSaved = false
    public private(set) var financialMessage: String?
    public private(set) var financialListError: String?
    public private(set) var financialHasError = false
    public var canGenerateFinancialReport: Bool { !isBusy && document != nil && financialStorage != nil }
    public var canSaveFinancialReport: Bool {
        !isBusy && financialReport != nil && financialDraftRevision != nil && !financialReportIsSaved
            && canDisplayFinancialReport
    }
    public var canDisplayFinancialReport: Bool {
        financialReport != nil && (financialReportState == .generated || financialReportState == .matched)
    }
    private let storage: any SECResearchWorkspaceStorage
    private let financialStorage: (any SECFinancialReportWorkspaceStorage)?
    private let importer: SECResearchImport
    private let replay: @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult
    private let financialReplay: @Sendable (SECFinancialReportDocument) async throws -> Bool
    private let now: @Sendable () -> Date
    private var financialDraftRevision: UUID?
    private var cancelFinancialWork: (@Sendable () -> Void)?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    public init(storage: any SECResearchWorkspaceStorage, networkAvailable: Bool,
                importer: @escaping SECResearchImport,
                replay: @escaping @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult = {
                    try $0.recompute()
                },
                financialStorage: (any SECFinancialReportWorkspaceStorage)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                financialReplay: @escaping @Sendable (SECFinancialReportDocument) async throws -> Bool = { document in
                    let result = try await document.financials.recompute()
                    return try document.financials.cachedReportsMatch(result)
                }) {
        self.storage = storage; self.networkAvailable = networkAvailable
        self.importer = importer; self.replay = replay
        self.financialStorage = financialStorage; self.now = now; self.financialReplay = financialReplay
    }

    public func chooseTicker(_ value: String) {
        guard !isBusy else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ticker != value else { return }
        generation = UUID(); ticker = value; clearDocument(); message = nil; hasError = false
    }

    public func load() async {
        guard !isBusy else { return }
        let token = begin(clear: false)
        defer { finish(token) }
        async let research: Void = reloadList(token)
        async let reports: Void = reloadFinancialList(token)
        _ = await (research, reports)
    }

    /// Called only by the explicit import action. A busy page does not start a second task.
    @discardableResult public func startImport(email: String) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let contact: SECContactIdentity
        do {
            guard networkAvailable else { throw SECResearchConfigurationError.networkDisabled }
            contact = try SECContactIdentity(email: email)
            try EquityRecord.validateSymbol(ticker)
        } catch {
            clearDocument(); hasError = true
            message = networkAvailable ? "请输入有效的股票代码和 SEC 联系邮箱。" : "本构建的 SEC 导入服务不可用，仍可打开本地已保存研究。"
            return nil
        }
        let token = begin(clear: true), symbol = ticker
        task = Task { [weak self, importer] in
            do {
                let result = try await importer(symbol, contact) { [weak self] value in
                    await self?.receive(value, token: token)
                }
                guard let self, self.generation == token else { return }
                try Task.checkCancellation()
                try result.validate()
                guard result.ticker == symbol else { throw ContractError.mismatchedSource }
                self.document = result; self.ticker = result.ticker
                self.message = "导入研究已保存；请显式重算核对后查看标准化数值。缺项与访问范围保留。"
                await self.reloadList(token, committed: true)
                self.finish(token)
            } catch {
                guard let self, self.generation == token else { return }
                self.hasError = !Task.isCancelled
                self.message = Task.isCancelled ? "导入已取消；已接收的源页可能保留，取消不撤销已完成的保存。"
                    : Self.failureMessage(error)
                self.finish(token)
            }
        }
        return task
    }

    public func open(_ id: UUID) async {
        guard !isBusy else { return }
        let token = begin(clear: true)
        defer { finish(token) }
        do {
            let result = try await storage.open(id: id)
            guard generation == token else { return }
            try Task.checkCancellation(); try result.validate()
            guard result.id == id else { throw ContractError.mismatchedSource }
            document = result; ticker = result.ticker
            message = "已打开冻结研究；数值缓存仍待显式重算核对。"
        } catch {
            guard generation == token else { return }
            hasError = true; message = "研究未能打开或未通过完整性检查；未显示旧结果。"
        }
    }

    public func recompute() async {
        guard !isBusy, let document else { return }
        let token = begin(clear: false)
        recomputationState = .notVerified
        defer { finish(token) }
        do {
            let result = try await replay(document)
            guard generation == token else { return }
            try Task.checkCancellation()
            if result == document.normalization {
                recomputationState = .matched; message = "冻结输入重算一致；不授予历史时点或投资分析资格。"
            } else {
                recomputationState = .mismatched; hasError = true
                message = "重算与缓存不一致，数值已隐藏；原记录未修改。"
            }
        } catch {
            guard generation == token else { return }
            recomputationState = .failed; hasError = true
            message = "重算未完成，数值保持隐藏；原记录未修改。"
        }
    }

    /// Preparation captures the original store revision before report generation. Save
    /// uses that exact draft baseline, including after a recoverable storage failure.
    public func generateFinancialReport() async {
        guard canGenerateFinancialReport, let document, let financialStorage else { return }
        let token = beginFinancial(clearReport: true)
        defer { finish(token) }
        do {
            let executionDate = now()
            let draft = try await financialOperation {
                try await financialStorage.prepareFinancialReport(parentID: document.id, executionDate: executionDate)
            }
            guard generation == token else { return }
            try Task.checkCancellation(); try draft.document.validate()
            guard draft.document.parentDocumentID == document.id, draft.document.ticker == document.ticker,
                  draft.document.cutoff == document.cutoff else { throw ContractError.mismatchedSource }
            financialReport = draft.document; financialDraftRevision = draft.expectedRevision
            financialReportState = .generated
            financialMessage = "已从选定冻结研究生成财务报告；尚未保存。期间及分类缺项保持明确。"
        } catch {
            guard generation == token else { return }
            financialHasError = true; financialMessage = Self.financialFailureMessage(error)
        }
    }

    public func saveFinancialReport() async {
        guard canSaveFinancialReport, let financialReport, let financialDraftRevision, let financialStorage else { return }
        let token = beginFinancial()
        defer { finish(token) }
        do {
            try Task.checkCancellation()
            try await financialOperation {
                try await financialStorage.saveFinancialReport(financialReport, expectedRevision: financialDraftRevision)
            }
        } catch {
            guard generation == token else { return }
            financialHasError = true
            if error as? SnapshotError == .stalePlan {
                self.financialDraftRevision = nil
                financialMessage = "研究库已变化，报告未保存。请重新打开源研究并生成；不会自动改用新的保存基线。"
            } else {
                financialMessage = "报告保存未完成；草稿保留，可重试。原有研究和报告未被覆盖。"
            }
            return
        }
        guard generation == token else { return }
        financialReportIsSaved = true; self.financialDraftRevision = nil
        financialMessage = "财务报告已保存，绑定原冻结研究；重开后仍需显式重算核对。"
        await reloadFinancialList(token, committed: true)
    }

    public func openFinancialReport(_ id: UUID) async {
        guard !isBusy, let financialStorage else { return }
        let token = beginFinancial(clearReport: true)
        defer { finish(token) }
        do {
            let result = try await financialOperation { try await financialStorage.openFinancialReport(id: id) }
            guard generation == token else { return }
            try Task.checkCancellation(); try result.validate()
            guard result.id == id else { throw ContractError.mismatchedSource }
            if document?.id != result.parentDocumentID {
                document = nil; recomputationState = .notVerified
            }
            financialReport = result; financialReportIsSaved = true; ticker = result.ticker
            financialMessage = "已打开保存的财务报告；缓存数值在显式重算核对前保持隐藏。"
        } catch {
            guard generation == token else { return }
            financialHasError = true
            financialMessage = "财务报告或绑定源研究未通过检查；未显示旧报告，源研究列表仍可使用。"
        }
    }

    public func recomputeFinancialReport() async {
        guard !isBusy, let financialReport else { return }
        let token = beginFinancial()
        financialReportState = .notVerified
        defer { finish(token) }
        do {
            let replay = financialReplay
            let matches = try await financialOperation { try await replay(financialReport) }
            guard generation == token else { return }
            try Task.checkCancellation()
            financialReportState = matches ? .matched : .mismatched
            financialHasError = !matches
            financialMessage = matches ? "三个财务模型的冻结输入重算一致；不授予估值、评分或历史 PIT 资格。"
                : "重算与报告缓存不一致，数值保持隐藏；原保存内容未修改。"
        } catch {
            guard generation == token else { return }
            financialReportState = .failed; financialHasError = true
            financialMessage = "财务报告重算未完成，数值保持隐藏；原保存内容未修改。"
        }
    }

    public func loadFinancialReports() async {
        guard !isBusy else { return }
        let token = begin(clear: false)
        defer { finish(token) }
        await reloadFinancialList(token)
    }

    public func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        cancelFinancialWork?(); cancelFinancialWork = nil; isBusy = false; progress = nil
        clearDocument(); hasError = false
        message = "操作已取消；已接收的源页或已提交的研究可能保留，可重新载入列表检查。"
    }
    public func disappear() {
        cancel(); message = nil; saved = []; listError = nil
        savedFinancialReports = []; financialListError = nil
    }
    private func receive(_ value: SECResearchProgress, token: UUID) {
        guard generation == token else { return }; progress = value
    }
    private func begin(clear: Bool) -> UUID {
        generation = UUID(); isBusy = true; progress = nil; message = nil; hasError = false
        if clear { clearDocument() }
        return generation
    }
    private func beginFinancial(clearReport: Bool = false) -> UUID {
        let token = begin(clear: false)
        if clearReport { clearFinancialReport() }
        financialMessage = nil; financialHasError = false
        return token
    }
    private func clearDocument() {
        document = nil; recomputationState = .notVerified; clearFinancialReport()
    }
    private func clearFinancialReport() {
        financialReport = nil; financialDraftRevision = nil; financialReportIsSaved = false
        financialReportState = .notVerified; financialMessage = nil; financialHasError = false
    }
    private func finish(_ token: UUID) {
        if generation == token { isBusy = false; task = nil; cancelFinancialWork = nil }
    }
    private func financialOperation<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let pending = Task { try await operation() }
        cancelFinancialWork = { pending.cancel() }
        return try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: { pending.cancel() }
    }
    private func reloadList(_ token: UUID, committed: Bool = false) async {
        do {
            let rows = try await storage.savedResearch()
            guard generation == token else { return }
            try Task.checkCancellation(); saved = rows; listError = nil
        } catch {
            guard generation == token else { return }
            saved = []; listError = "保存列表无法读取，请重新载入。"
            if committed { message = "研究已保存，但列表刷新失败；请重新载入，避免重复导入。" }
        }
    }
    private func reloadFinancialList(_ token: UUID, committed: Bool = false) async {
        guard let financialStorage else { return }
        do {
            let rows = try await financialStorage.savedFinancialReports(parentID: nil)
            guard generation == token else { return }
            try Task.checkCancellation(); savedFinancialReports = rows; financialListError = nil
        } catch {
            guard generation == token else { return }
            savedFinancialReports = []; financialListError = "财务报告列表无法读取，请单独重新载入。源研究列表仍可使用。"
            if committed { financialMessage = "财务报告已保存，但报告列表刷新失败；请重新载入，避免重复保存。" }
        }
    }
    private static func financialFailureMessage(_ error: any Error) -> String {
        switch error {
        case SECFinancialError.insufficientPeriods: "冻结研究缺少足够的连续季度证据，暂不能生成财务报告；不会推测财年或补齐期间。"
        case SECFinancialError.ambiguousPeriods: "冻结研究的财务期间证据有歧义，暂不能生成财务报告；请先核查来源。"
        case SnapshotError.stalePlan: "生成期间研究库已变化，请重新打开源研究后再生成。"
        default: "财务报告未能生成；请检查冻结研究及期间证据。已有研究未修改，也未发起网络请求。"
        }
    }
    private static func failureMessage(_ error: any Error) -> String {
        // Only closed typed categories; never render provider descriptions, request headers or URLs.
        switch error {
        case SECResearchError.importInProgress: "另一个窗口正在导入 SEC 财报；请等待导入完成或取消结束后重试。已保存列表仍可查看。"
        case ProviderFailure.rateLimited: "SEC 暂时限流，导入未完成；请稍后手动重试，已接收的源页可能保留。"
        case ProviderFailure.symbolUnavailable: "未找到所选代码或申报文件；导入未完成。"
        default: "导入未完成；请检查访问配置或稍后重试。已接收的源页可能保留，不代表整次导入成功。"
        }
    }
}
