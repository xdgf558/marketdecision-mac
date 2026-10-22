import Foundation
import Observation
import AIInsights
import AIAnalysisNetworkBroker
import Persistence
import SecuritySupport

/// One manually requested response. This type neither persists reports nor owns a key.
public struct AIInsightSession: Sendable {
    public let send: @Sendable (AIInsightRequest, Data) async throws -> AIInsightResult
    public let close: @Sendable () async -> Void
    public init(send: @escaping @Sendable (AIInsightRequest, Data) async throws -> AIInsightResult,
                close: @escaping @Sendable () async -> Void) { self.send = send; self.close = close }
}

@MainActor @Observable public final class AIInsightWorkspaceModel {
    public static let credentialReference = "openai-financial-analysis.v1"
    public let credentials: CredentialSettingsModel
    public let networkAvailable: Bool
    public private(set) var input: AIInsightInput?
    public private(set) var result: AIInsightResult?
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var isBusy = false
    public private(set) var selectedReportID: UUID?
    public private(set) var selectedReportRevision: UUID?
    private let readKey: @Sendable () async throws -> Data?
    private let factory: @Sendable () async throws -> AIInsightSession
    private var generation = UUID()
    private var operation: UUID?
    private var task: Task<Void, Never>?

    public init(credentials: CredentialSettingsModel, networkAvailable: Bool,
                readKey: @escaping @Sendable () async throws -> Data?,
                factory: @escaping @Sendable () async throws -> AIInsightSession) {
        self.credentials = credentials; self.networkAvailable = networkAvailable
        self.readKey = readKey; self.factory = factory
    }

    /// Navigation never reads Keychain, verifies a financial model or starts a connection.
    public func select(reportID: UUID?, revision: UUID? = nil) {
        guard selectedReportID != reportID || selectedReportRevision != revision else { return }
        invalidate(); selectedReportID = reportID; selectedReportRevision = revision
    }

    public func disappear() { invalidate(); selectedReportID = nil; selectedReportRevision = nil }
    public func credentialsChanged() { invalidate() }
    public func cancel() {
        invalidate()
        message = "分析已取消；已发出的请求仍可能产生 API 费用。"
    }

    public func startAnalysis(report: SECFinancialReportDocument, revision: UUID, model: String) {
        guard selectedReportID == report.id, selectedReportRevision == revision else { return }
        start(reportID: report.id, model: model) { try await AIInsightReportAdapter.prepare(report) }
    }

    /// Internal seam exercises the same lifecycle with small synthetic verified summaries.
    @discardableResult func start(reportID: UUID, model: String,
        prepare: @escaping @Sendable () async throws -> AIInsightInput) -> Task<Void, Never>? {
        guard !isBusy, selectedReportID == reportID else { return nil }
        result = nil; input = nil; message = nil; hasError = false
        guard networkAvailable else {
            message = "本构建尚未启用 AI 网络服务；本地财务分析仍可使用。"; return nil
        }
        let token = generation, op = UUID(), credentialRevision = credentials.revision
        operation = op; isBusy = true
        let work = Task { [weak self] in
            guard let self else { return }
            await perform(reportID: reportID, model: model, token: token, operation: op,
                          credentialRevision: credentialRevision, prepare: prepare)
        }
        task = work
        return work
    }

    private func perform(reportID: UUID, model: String, token: UUID, operation op: UUID,
                         credentialRevision: UUID,
                         prepare: @Sendable () async throws -> AIInsightInput) async {
        defer {
            if operation == op { operation = nil; isBusy = false; task = nil }
        }
        do {
            let summary = try await prepare()
            let request = AIInsightRequest(input: summary, model: model)
            try request.validate()
            try check(token, reportID, credentialRevision)
            // The factory verifies the embedded service BEFORE any secret is read.
            let session = try await factory()
            do {
                try check(token, reportID, credentialRevision)
                guard let key = try await readKey(), !key.isEmpty else { throw AIWorkspaceError.missingKey }
                try check(token, reportID, credentialRevision)
                input = summary
                let received = try await withTaskCancellationHandler {
                    try await session.send(request, key)
                } onCancel: { Task { await session.close() } }
                await session.close()
                try check(token, reportID, credentialRevision)
                guard received.inputDigest == (try summary.digest()), received.requestedModel == model else {
                    throw AIWorkspaceError.mismatchedResponse
                }
                result = received
                message = "AI 解读已完成，供财报研究参考；请结合所列依据核对。"
            } catch {
                await session.close()
                throw error
            }
        } catch {
            guard generation == token, selectedReportID == reportID,
                  credentials.revision == credentialRevision else { return }
            result = nil
            if Task.isCancelled {
                message = "分析已取消；已发出的请求仍可能产生 API 费用。"
            } else if error is AIWorkspaceError, case AIWorkspaceError.missingKey = error {
                hasError = true; message = "请先在 AI 设置中保存自己的 OpenAI API Key。"
            } else {
                hasError = true
                message = "未取得可核对的 AI 解读。请检查财报、模型及 API 账户后手动重试；不会自动重发。"
            }
        }
    }

    private func check(_ token: UUID, _ reportID: UUID, _ credentialRevision: UUID) throws {
        try Task.checkCancellation()
        guard token == generation, selectedReportID == reportID,
              credentials.revision == credentialRevision else { throw CancellationError() }
    }

    private func invalidate() {
        generation = UUID(); task?.cancel()
        input = nil; result = nil; message = nil; hasError = false
        // Busy ends only after cleanup, so cancel/reclick cannot overlap paid requests.
    }
}

private enum AIWorkspaceError: Error { case missingKey, mismatchedResponse }

extension AppEnvironment {
    @MainActor public func makeAICredentialSettings() -> CredentialSettingsModel {
        CredentialSettingsModel(store: credentials, log: log, reference: AIInsightWorkspaceModel.credentialReference)
    }
    @MainActor public func makeAIInsightWorkspace(credentials settings: CredentialSettingsModel) -> AIInsightWorkspaceModel {
        let reader = credentials as? any CredentialReadingStorage
        return AIInsightWorkspaceModel(credentials: settings,
            networkAvailable: reader != nil && AIAnalysisServiceAvailability.isAvailable,
            readKey: { try await reader?.read(reference: AIInsightWorkspaceModel.credentialReference) },
            factory: {
                let client = try AIAnalysisXPCClient()
                return AIInsightSession(send: { request, key in try await client.analyze(request, apiKey: key) },
                                        close: { await client.close() })
            })
    }
}
