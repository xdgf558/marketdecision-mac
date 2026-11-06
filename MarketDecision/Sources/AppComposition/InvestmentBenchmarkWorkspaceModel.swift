import Foundation
import Observation
import AIInsights
import AIAnalysisNetworkBroker
import SecuritySupport

/// One explicit benchmark lookup. Neither the session nor its result includes
/// account names, holdings, booked amounts or transaction records.
public struct InvestmentBenchmarkSession: Sendable {
    public let send: @Sendable (AIBenchmarkRequest, Data) async throws -> AIBenchmarkResult
    public let close: @Sendable () async -> Void

    public init(send: @escaping @Sendable (AIBenchmarkRequest, Data) async throws -> AIBenchmarkResult,
                close: @escaping @Sendable () async -> Void) {
        self.send = send; self.close = close
    }
}

/// Cancellation can race the request completion. Both paths await the same
/// cleanup task, so busy cannot end while a second close is still in flight.
private actor InvestmentBenchmarkSessionCleanup {
    private let action: @Sendable () async -> Void
    private var closing: Task<Void, Never>?
    init(_ action: @escaping @Sendable () async -> Void) { self.action = action }
    func close() async {
        if let closing { await closing.value; return }
        let action = action
        let closing = Task { await action() }
        self.closing = closing
        await closing.value
    }
}

@MainActor @Observable public final class InvestmentBenchmarkWorkspaceModel {
    public let credentials: CredentialSettingsModel
    public let networkAvailable: Bool
    public private(set) var result: AIBenchmarkResult?
    public private(set) var message: String?
    public private(set) var isBusy = false
    public private(set) var selectedSnapshotID: UUID?
    private var selectedStart: Date?
    private var selectedEnd: Date?
    private var selectedModel = ""
    private let readKey: @Sendable () async throws -> Data?
    private let factory: @Sendable () async throws -> InvestmentBenchmarkSession
    private var generation = UUID()
    private var operation: UUID?
    private var task: Task<Void, Never>?

    public init(credentials: CredentialSettingsModel, networkAvailable: Bool,
                readKey: @escaping @Sendable () async throws -> Data?,
                factory: @escaping @Sendable () async throws -> InvestmentBenchmarkSession) {
        self.credentials = credentials; self.networkAvailable = networkAvailable
        self.readKey = readKey; self.factory = factory
    }

    /// Selection and navigation never read a key or dispatch a request. Retain
    /// original boundaries; rounding must not change the requested interval.
    public func select(snapshotID: UUID?, start: Date?, end: Date?, model: String) {
        guard selectedSnapshotID != snapshotID || selectedStart != start ||
                selectedEnd != end || selectedModel != model else { return }
        invalidate()
        selectedSnapshotID = snapshotID; selectedStart = start; selectedEnd = end; selectedModel = model
    }

    public func credentialsChanged() { invalidate() }

    public func disappear() {
        invalidate()
        selectedSnapshotID = nil; selectedStart = nil; selectedEnd = nil; selectedModel = ""
    }

    public func cancel() {
        invalidate()
        message = "标普查询已取消；已发出的请求仍可能产生 API 费用。"
    }

    @discardableResult public func startSearch() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        result = nil; message = nil
        guard let snapshotID = selectedSnapshotID, let start = selectedStart, let end = selectedEnd else {
            message = "请先选择有效的收益分享周期。[AI-BENCHMARK-PERIOD]"
            return nil
        }
        guard networkAvailable else {
            message = AIInsightFailureMessage.serviceUnavailable; return nil
        }
        guard !credentials.isBusy else {
            message = "凭据正在更新，请完成后再手动查询。[AI-BENCHMARK-CREDENTIAL-BUSY]"
            return nil
        }
        let request = AIBenchmarkRequest(start: start, end: end, model: selectedModel)
        let token = generation, op = UUID(), credentialRevision = credentials.revision
        operation = op; isBusy = true
        let work = Task { [weak self] in
            guard let self else { return }
            await perform(request: request, snapshotID: snapshotID, token: token,
                          operation: op, credentialRevision: credentialRevision)
        }
        task = work
        return work
    }

    private func perform(request: AIBenchmarkRequest, snapshotID: UUID, token: UUID,
                         operation op: UUID, credentialRevision: UUID) async {
        defer {
            if operation == op { operation = nil; isBusy = false; task = nil }
        }
        var stage = AIInsightFailureMessage.Stage.validatingRequest
        do {
            try request.validate()
            try check(token, snapshotID, credentialRevision)
            // The factory validates the embedded helper before a secret is read.
            stage = .openingService
            let session = try await factory()
            let cleanup = InvestmentBenchmarkSessionCleanup(session.close)
            let received: AIBenchmarkResult
            do {
                try check(token, snapshotID, credentialRevision)
                stage = .readingCredential
                guard let key = try await readKey(), !key.isEmpty else { throw AIWorkspaceError.missingKey }
                try check(token, snapshotID, credentialRevision)
                stage = .requestingAnalysis
                received = try await withTaskCancellationHandler {
                    try await session.send(request, key)
                } onCancel: { Task { await cleanup.close() } }
            } catch {
                await cleanup.close()
                throw error
            }
            await cleanup.close()
            try check(token, snapshotID, credentialRevision)
            stage = .checkingBinding
            try received.validate(for: request)
            result = received
            message = received.reference == nil
                ? Self.unavailableMessage(code: received.unavailableCode)
                : "已取得起止收盘点，本地已计算标普涨跌幅。"
        } catch {
            guard generation == token, selectedSnapshotID == snapshotID,
                  credentials.revision == credentialRevision else { return }
            result = nil
            if Task.isCancelled {
                message = "标普查询已取消；已发出的请求仍可能产生 API 费用。"
            } else if stage == .validatingRequest {
                message = "查询周期或模型无效，未发送请求。请核对模型 ID，并使用支持联网搜索的模型。[AI-BENCHMARK-INPUT]"
            } else if stage == .checkingBinding {
                message = "返回的标普资料与所选周期不符，或来源校验未通过，未展示涨跌幅。[AI-BENCHMARK-EVIDENCE]"
            } else if stage == .requestingAnalysis, let failure = error as? AIBenchmarkError {
                message = Self.benchmarkFailure(failure)
            } else {
                message = AIInsightFailureMessage.text(for: error, stage: stage)
                    + " 标普查询需要模型支持联网搜索；已发出的请求可能计费，不会自动重试。"
            }
        }
    }

    private static let retryNotice = " 未用零或估算值替代；仅可手动重试，已发出的请求及再次查询都可能产生 API 费用。"

    private static func unavailableMessage(code: String?) -> String {
        let detail: String
        switch code {
        case "not_found": detail = "联网搜索未找到所选期间的标普 500 收盘资料。[AI-BENCHMARK-NOT-FOUND]"
        case "insufficient_evidence": detail = "搜索结果缺少可核对的起止收盘值或出处，无法计算同期涨跌幅。[AI-BENCHMARK-INSUFFICIENT]"
        case "ambiguous_series": detail = "搜索资料无法确认是标普 500 价格指数，未混用 ETF 或含股息回报。[AI-BENCHMARK-SERIES]"
        default: detail = "尚未取得可核对的同期标普资料。[AI-BENCHMARK-UNAVAILABLE]"
        }
        return detail + retryNotice
    }

    private static func benchmarkFailure(_ failure: AIBenchmarkError) -> String {
        let detail: String
        switch failure {
        case .missingSearch:
            detail = "本次响应没有已完成的联网搜索证据，未把模型记忆当作行情。请使用支持联网搜索的模型。[AI-BENCHMARK-NO-SEARCH]"
        case .invalidIndex:
            detail = "返回的资料不是所需的标普 500 美元价格指数，或回报口径不一致。[AI-BENCHMARK-INDEX]"
        case .invalidWindow:
            detail = "返回的收盘日期不符合所选期间，可能晚于截止时间或距离边界过远。[AI-BENCHMARK-WINDOW]"
        case .invalidPrice:
            detail = "返回的起止收盘值无效，无法计算标普涨跌幅。[AI-BENCHMARK-PRICE]"
        case .invalidEvidence:
            detail = "本次响应的来源元数据格式无效，无法核对收盘资料。[AI-BENCHMARK-SOURCE-METADATA]"
        case .unsupportedSourceURL:
            detail = "收盘资料引用的地址格式不受支持，需为不含登录信息的公开 HTTPS 网页。[AI-BENCHMARK-SOURCE-URL]"
        case .sourceURLLimit:
            detail = "来源链接的长度或参数数量超出接收限制。[AI-BENCHMARK-SOURCE-LIMIT]"
        case .missingSourceMetadata:
            detail = "本次响应没有可用的来源链接，无法核对起止收盘资料。[AI-BENCHMARK-SOURCE-LIST]"
        case .malformedResponse:
            detail = "标普查询响应的内容结构不符合要求，未取得可核对的数据。[AI-BENCHMARK-FORMAT]"
        case .ambiguousOutput:
            detail = "标普查询返回多个或不明确的最终答案，无法唯一确定结果。[AI-BENCHMARK-AMBIGUOUS]"
        case .incompleteResponse:
            detail = "标普查询尚未返回完整结果，未展示未完成的数据。[AI-BENCHMARK-INCOMPLETE]"
        case .outputLimitReached:
            detail = "本次推理与回答达到 token 上限，标普查询未完成；不会自动加额或展示残缺数据。[AI-BENCHMARK-OUTPUT-LIMIT]"
        case .budgetExceeded:
            detail = "标普查询内容超出本地接收限制，已停止处理。[AI-BENCHMARK-LIMIT]"
        case .invalidModel:
            detail = "标普查询的模型 ID 无效，请在 AI 设置中核对支持联网搜索的模型。[AI-BENCHMARK-MODEL]"
        case .invalidRequest:
            detail = "标普查询请求或返回结果的周期绑定无效，已拒绝展示。[AI-BENCHMARK-REQUEST]"
        }
        return detail + retryNotice
    }

    private func check(_ token: UUID, _ snapshotID: UUID, _ credentialRevision: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, selectedSnapshotID == snapshotID,
              credentials.revision == credentialRevision else { throw CancellationError() }
    }

    private func invalidate() {
        generation = UUID(); task?.cancel()
        result = nil; message = nil
        // Do not clear busy until request and session cleanup actually return.
    }
}

extension AppEnvironment {
    @MainActor public func makeInvestmentBenchmarkWorkspace(credentials settings: CredentialSettingsModel) -> InvestmentBenchmarkWorkspaceModel {
        let reader = credentials as? any CredentialReadingStorage
        return InvestmentBenchmarkWorkspaceModel(credentials: settings,
            networkAvailable: reader != nil && AIAnalysisServiceAvailability.isAvailable,
            readKey: { try await reader?.read(reference: AIInsightWorkspaceModel.credentialReference) },
            factory: {
                let client = try AIAnalysisXPCClient()
                return InvestmentBenchmarkSession(send: { request, key in
                    try await client.searchBenchmark(request, apiKey: key)
                }, close: { await client.close() })
            })
    }
}
