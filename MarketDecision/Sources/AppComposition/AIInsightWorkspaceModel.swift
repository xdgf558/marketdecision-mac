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
    public private(set) var valuationReference: AIValuationReferenceInput?
    public private(set) var valuationReferenceRevision = UUID()
    /// One in-memory approval opportunity for exactly this published AI proposal.
    /// Re-analysis, report/reference changes, cancellation and departure revoke it.
    public private(set) var valuationProposalID: UUID?
    public private(set) var valuationScenarioCalculation: AIValuationScenarioCalculation?
    public private(set) var valuationScenarioMessage: String?
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
        valuationReference = nil; valuationReferenceRevision = UUID()
    }

    public func disappear() {
        invalidate(); selectedReportID = nil; selectedReportRevision = nil
        valuationReference = nil; valuationReferenceRevision = UUID()
    }
    public func credentialsChanged() { invalidate() }
    public func cancel() {
        invalidate()
        message = "分析已取消；已发出的请求仍可能产生 API 费用。"
    }

    public func startAnalysis(report: SECFinancialReportDocument, revision: UUID, model: String) {
        guard selectedReportID == report.id, selectedReportRevision == revision else { return }
        let reference = valuationReference
        start(reportID: report.id, model: model) {
            try await AIInsightReportAdapter.prepare(report, reference: reference)
        }
    }

    /// A sheet can only apply to the report/revision that opened it. Changing even one
    /// reference input invalidates both AI cards and any pending result; it never sends.
    @discardableResult public func updateValuationReference(_ value: AIValuationReferenceInput?,
        reportID: UUID, reportRevision: UUID) -> Bool {
        guard selectedReportID == reportID, selectedReportRevision == reportRevision else { return false }
        guard valuationReference != value else { return true }
        invalidate(); valuationReference = value; valuationReferenceRevision = UUID()
        return true
    }

    /// Only an explicit confirmation authorizes the local scenario calculation. It does
    /// not read a credential, send another request, save a report or qualify a fair price.
    @discardableResult public func confirmValuationScenarios(proposalID: UUID,
        reportID: UUID, reportRevision: UUID) -> Bool {
        guard !isBusy, selectedReportID == reportID, selectedReportRevision == reportRevision,
              valuationProposalID == proposalID, valuationScenarioCalculation == nil,
              let input, let result, let proposal = result.analysis.valuation.scenarioProposal else { return false }
        do {
            guard result.inputDigest == (try input.digest()),
                  result.promptVersion == AIInsightRequest.promptVersion else { return false }
            try result.analysis.validate(for: input)
            let calculation = try AIValuationScenarioCalculation.calculate(input: input, proposal: proposal)
            valuationScenarioCalculation = calculation
            valuationScenarioMessage = nil
            return true
        } catch {
            // Never display the rejected model output or raw arithmetic error.
            valuationScenarioCalculation = nil
            valuationScenarioMessage = "这些假设暂不能生成有效价格，请核对收入、股数和倍数；不会补零或自动重发。"
            return false
        }
    }

    private func clearValuationProposal() {
        valuationProposalID = nil
        valuationScenarioCalculation = nil
        valuationScenarioMessage = nil
    }

    /// Internal seam exercises the same lifecycle with small synthetic verified summaries.
    @discardableResult func start(reportID: UUID, model: String,
        prepare: @escaping @Sendable () async throws -> AIInsightInput) -> Task<Void, Never>? {
        guard !isBusy, selectedReportID == reportID else { return nil }
        result = nil; input = nil; message = nil; hasError = false
        clearValuationProposal()
        guard networkAvailable else {
            hasError = true; message = AIInsightFailureMessage.serviceUnavailable; return nil
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
        var stage = AIInsightFailureMessage.Stage.preparingReport
        do {
            let summary = try await prepare()
            stage = .validatingRequest
            let request = AIInsightRequest(input: summary, model: model)
            try request.validate()
            try check(token, reportID, credentialRevision)
            // The factory verifies the embedded service BEFORE any secret is read.
            stage = .openingService
            let session = try await factory()
            do {
                try check(token, reportID, credentialRevision)
                stage = .readingCredential
                guard let key = try await readKey(), !key.isEmpty else { throw AIWorkspaceError.missingKey }
                try check(token, reportID, credentialRevision)
                input = summary
                stage = .requestingAnalysis
                let received = try await withTaskCancellationHandler {
                    try await session.send(request, key)
                } onCancel: { Task { await session.close() } }
                await session.close()
                try check(token, reportID, credentialRevision)
                stage = .checkingBinding
                guard received.inputDigest == (try summary.digest()), received.requestedModel == model,
                      received.promptVersion == AIInsightRequest.promptVersion else {
                    throw AIWorkspaceError.mismatchedResponse
                }
                // Both cards publish one checked response. A session implementation cannot
                // bypass financial or valuation citations by supplying only a matching digest.
                try received.analysis.validate(for: summary)
                result = received
                valuationProposalID = received.analysis.valuation.scenarioProposal == nil ? nil : UUID()
                valuationScenarioCalculation = nil
                valuationScenarioMessage = nil
                message = "AI 解读已完成；估值解读已同步到“AI 估值参考”，仅供财报研究参考。"
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
            } else {
                hasError = true
                message = AIInsightFailureMessage.text(for: error, stage: stage)
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
        clearValuationProposal()
        // Busy ends only after cleanup, so cancel/reclick cannot overlap paid requests.
    }
}

enum AIWorkspaceError: Error, Equatable { case missingKey, mismatchedResponse }

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
