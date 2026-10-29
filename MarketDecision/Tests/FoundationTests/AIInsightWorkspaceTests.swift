import Foundation
import Testing
import AIInsights
import AIAnalysisNetworkBroker
import SecuritySupport
@testable import AppComposition

private enum AIWorkspaceTestFailure: Error { case injected }
private enum AIWorkspaceFailureStage: Sendable { case preparation, service, credential, request }
private final class AIWorkspaceDescriptionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private struct AIWorkspaceSecretFailure: LocalizedError, CustomStringConvertible {
    let descriptions: AIWorkspaceDescriptionCounter
    var errorDescription: String? { descriptions.increment(); return "Bearer SYNTHETIC-PRIVATE-KEY" }
    var description: String { descriptions.increment(); return "https://private.invalid/?secret=SYNTHETIC-PRIVATE-KEY" }
}

/// Explicit entry/release handshake; intentionally ignores task cancellation so
/// late provider completions exercise the production publication boundary.
private actor AIWorkspaceGate {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        let observers = arrivals; arrivals.removeAll()
        for observer in observers { observer.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor AIWorkspaceProbe {
    var prepared = 0
    var factories = 0
    var keyReads = 0
    var sends = 0
    var closes = 0
    func prepare() { prepared += 1 }
    func factory() { factories += 1 }
    func key() { keyReads += 1 }
    func send() { sends += 1 }
    func close() { closes += 1 }
}

private actor AIWorkspaceCredentialStore: CredentialStorage {
    var checks = 0
    func contains(reference: String) -> Bool { checks += 1; return true }
    func save(_ secret: Data, reference: String) {}
    func delete(reference: String) {}
}

private actor AIWorkspaceNamespacedCredentials: CredentialStorage {
    private(set) var values: [String: Data] = [:]
    func contains(reference: String) -> Bool { values[reference] != nil }
    func save(_ secret: Data, reference: String) { values[reference] = secret }
    func delete(reference: String) { values.removeValue(forKey: reference) }
}

private func aiWorkspaceInput(revenue: String = "100") -> AIInsightInput {
    AIInsightInput(ticker: "DEMO", companyName: "合成公司", periodEnd: "2026-09-30",
        cutoff: "2026-10-22T00:00:00.000400Z",
        metrics: [.init(id: "m-revenue", label: "营收", value: revenue, unit: "USD",
                        unavailable: nil, sourceIDs: ["s-filing"])],
        sources: [.init(id: "s-filing", label: "合成财报摘要")])
}

private func aiWorkspaceReference(price: String = "20") throws -> AIValuationReferenceInput {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z"))
    var draft = AIValuationReferenceDraft(now: now)
    draft.price = price; draft.shares = "100"; draft.sharesAsOf = "2026-09-30"
    draft.confirmedSingleClassSameBasis = true; draft.maySendReferenceData = true
    return try draft.validated(now: now)
}

/// The lifecycle seam does not implicitly build valuation inputs; use a validated
/// reference summary so publication exercises the same response scope as production.
private func aiWorkspaceReferenceSummary(_ reference: AIValuationReferenceInput) throws -> AIInsightInput {
    let base = aiWorkspaceInput()
    let source = AIInsightReferenceValuationContext.referenceSourceID
    let marketCap = try reference.price.multiplied(by: reference.shares.decimalString)
    let referenceMetrics: [AIInsightMetric] = [
        .init(id: "reference.price", label: "用户参考价格", value: reference.price.decimalString,
              unit: "USD/share", unavailable: nil, sourceIDs: [source]),
        .init(id: "reference.shares", label: "用户确认普通股总数", value: reference.shares.decimalString,
              unit: "shares", unavailable: nil, sourceIDs: [source]),
        .init(id: "reference.marketCap", label: "参考市值", value: marketCap.decimalString,
              unit: "USD", unavailable: nil, sourceIDs: [source]),
        .init(id: "reference.pe", label: "参考市盈率", value: nil, unit: "multiple",
              unavailable: "合成摘要缺少完整 TTM 净利润", sourceIDs: [source]),
        .init(id: "reference.ps", label: "参考市销率", value: nil, unit: "multiple",
              unavailable: "合成摘要缺少完整 TTM 收入", sourceIDs: [source]),
        .init(id: "reference.pfcf", label: "参考自由现金流倍数", value: nil, unit: "multiple",
              unavailable: "合成摘要缺少完整 TTM 自由现金流", sourceIDs: [source])
    ]
    return AIInsightInput(ticker: base.ticker, companyName: base.companyName,
        periodEnd: base.periodEnd, cutoff: base.cutoff, metrics: base.metrics + referenceMetrics,
        sources: base.sources + [.init(id: source, label: "合成用户参考输入")],
        referenceValuation: .init(referenceAt: try AIInsightReportAdapter.utcCutoff(reference.referenceAt),
                                  sharesAsOf: reference.sharesAsOf.iso8601))
}

private func aiWorkspaceResult(_ request: AIInsightRequest, encryptedReasoning: Bool = false) throws -> AIInsightResult {
    let hasReference = request.input.referenceValuation != nil
    let analysis: [String: Any] = [
        "summary": ["text": "仅解读当前提供的营收证据。", "evidenceIDs": ["m-revenue"]],
        "strengths": [], "risks": [], "questions": [],
        "limitations": [["text": "合成摘要不足以形成投资判断。", "evidenceIDs": ["s-filing"]]],
        "valuation": [
            "scope": hasReference ? "referenceMultiples" : "financialContextOnly",
            "interpretation": [
                "text": hasReference ? "参考价格和股数只用于本地计算参考市值。" : "营收证据只能帮助理解业务规模，不能据此判断股价高低。",
                "evidenceIDs": hasReference ? ["reference.price", "reference.shares", "reference.marketCap"] : ["m-revenue"]],
            "limitations": [[
                "text": hasReference ? "缺少完整 TTM 分母与可比基准，不能据此判断价格高低。" : "摘要没有当前股价、完整股本或获批估值假设，不能给出合理价格。",
                "evidenceIDs": hasReference ? ["reference.pe", "reference.ps", "reference.pfcf"] : ["s-filing"]]]
        ]
    ]
    let encoded = try JSONSerialization.data(withJSONObject: analysis)
    let text = try #require(String(data: encoded, encoding: .utf8))
    var outputs: [[String: Any]] = [["type": "message", "role": "assistant", "status": "completed",
        "content": [["type": "output_text", "text": text, "annotations": []]]]]
    if encryptedReasoning {
        outputs.insert(["type": "reasoning", "summary": [],
            "encrypted_content": "SYNTHETIC-OPAQUE-REASONING"], at: 0)
    }
    let response: [String: Any] = [
        "object": "response", "status": "completed", "model": "gpt-6-luna-2026-10-01",
        "output": outputs
    ]
    return try request.parseResponse(JSONSerialization.data(withJSONObject: response))
}

@Suite("Manual AI analysis lifecycle") @MainActor
struct AIInsightWorkspaceTests {
    private func credentials(_ store: AIWorkspaceCredentialStore = AIWorkspaceCredentialStore()) -> CredentialSettingsModel {
        CredentialSettingsModel(store: store, reference: AIInsightWorkspaceModel.credentialReference)
    }
    private func workspace(probe: AIWorkspaceProbe, credentials: CredentialSettingsModel? = nil,
                           available: Bool = true,
                           readKey: (@Sendable () async throws -> Data?)? = nil,
                           factory: (@Sendable () async throws -> AIInsightSession)? = nil) -> AIInsightWorkspaceModel {
        AIInsightWorkspaceModel(credentials: credentials ?? self.credentials(), networkAvailable: available,
            readKey: readKey ?? {
                await probe.key(); return Data("synthetic-ai-key".utf8)
            }, factory: factory ?? {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send(); return try aiWorkspaceResult(request)
                }, close: { await probe.close() })
            })
    }
    private func start(_ model: AIInsightWorkspaceModel, id: UUID, probe: AIWorkspaceProbe) throws -> Task<Void, Never> {
        try #require(model.start(reportID: id, model: AIInsightRequest.defaultModel) {
            await probe.prepare(); return aiWorkspaceInput()
        })
    }

    @Test func initializationAndNavigationReadNoKeyAndStartNoSession() async {
        let probe = AIWorkspaceProbe(), store = AIWorkspaceCredentialStore()
        let model = workspace(probe: probe, credentials: credentials(store))
        let first = UUID(), second = UUID()
        model.select(reportID: first); model.select(reportID: first)
        model.select(reportID: second); model.disappear()
        model.select(reportID: first); model.credentialsChanged()
        #expect(model.result == nil && model.input == nil && !model.isBusy)
        #expect(model.selectedReportID == first)
        #expect(await store.checks == 0)
        #expect(await probe.keyReads == 0)
        #expect(await probe.factories == 0)
        #expect(await probe.sends == 0)
    }

    @Test func unavailableNetworkAndWrongSelectionDoNotEvenPrepareOrReadKey() async {
        let probe = AIWorkspaceProbe(), model = workspace(probe: probe, available: false), id = UUID()
        model.select(reportID: id)
        let unavailable = model.start(reportID: id, model: AIInsightRequest.defaultModel) {
            await probe.prepare(); return aiWorkspaceInput()
        }
        #expect(unavailable == nil && !model.isBusy && model.result == nil)
        #expect(model.message != nil)
        let wrongSelection = model.start(reportID: UUID(), model: AIInsightRequest.defaultModel) {
            await probe.prepare(); return aiWorkspaceInput()
        }
        #expect(wrongSelection == nil)
        #expect(await probe.prepared == 0)
        #expect(await probe.factories == 0)
        #expect(await probe.keyReads == 0)
        #expect(await probe.sends == 0)
    }

    @Test func serviceFactoryFailureOccursBeforeAnySecretRead() async throws {
        let probe = AIWorkspaceProbe(), id = UUID()
        let model = workspace(probe: probe, factory: {
            await probe.factory(); throw AIWorkspaceTestFailure.injected
        })
        model.select(reportID: id)
        await (try start(model, id: id, probe: probe)).value
        #expect(!model.isBusy && model.result == nil && model.hasError)
        #expect(model.message?.contains("[AI-SERVICE]") == true)
        #expect(await probe.factories == 1)
        #expect(await probe.keyReads == 0)
        #expect(await probe.sends == 0)
        #expect(await probe.closes == 0)
    }

    @Test func encryptedReasoningResponsePublishesOnlyValidatedFinancialAnalysis() async throws {
        let probe = AIWorkspaceProbe(), id = UUID()
        let model = workspace(probe: probe, factory: {
            await probe.factory()
            return AIInsightSession(send: { request, _ in
                await probe.send()
                return try aiWorkspaceResult(request, encryptedReasoning: true)
            }, close: { await probe.close() })
        })
        model.select(reportID: id)
        await (try start(model, id: id, probe: probe)).value
        let result = try #require(model.result)
        #expect(result.analysis.summary.evidenceIDs == ["m-revenue"])
        #expect(result.inputDigest == (try aiWorkspaceInput().digest()))
        #expect(result.requestedModel == AIInsightRequest.defaultModel)
        #expect(!model.hasError && !model.isBusy)
        #expect(model.message?.contains("AI 解读已完成") == true)
        let savedText = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
        #expect(!savedText.contains("SYNTHETIC-OPAQUE-REASONING"))
        #expect(await probe.sends == 1)
        #expect(await probe.closes == 1)
    }

    @Test func missingOrEmptyKeyClosesPreparedSessionWithoutSending() async throws {
        for key: Data? in [nil, Data()] {
            let probe = AIWorkspaceProbe(), id = UUID()
            let model = workspace(probe: probe, readKey: { await probe.key(); return key })
            model.select(reportID: id)
            await (try start(model, id: id, probe: probe)).value
            #expect(!model.isBusy && model.result == nil && model.input == nil && model.hasError)
            #expect(model.message?.contains("[AI-KEY-MISSING]") == true)
            #expect(await probe.factories == 1)
            #expect(await probe.keyReads == 1)
            #expect(await probe.sends == 0)
            #expect(await probe.closes == 1)
        }
    }

    @Test func localPreparationDiagnosticsPrecedeServiceAndCredentialAccess() async throws {
        let cases: [(AIInsightReportAdapterError, String)] = [
            (.replayMismatch, "[AI-LOCAL-REPLAY]"), (.missingMetric, "[AI-LOCAL-METRICS]"),
            (.invalidCutoff, "[AI-LOCAL-CUTOFF]"),
            (.referencePredatesFinancialEvidence, "[AI-REFERENCE-TIME]")]
        for (failure, marker) in cases {
            let probe = AIWorkspaceProbe(), id = UUID(), model = workspace(probe: probe)
            model.select(reportID: id)
            let work = try #require(model.start(reportID: id, model: AIInsightRequest.defaultModel) {
                await probe.prepare(); throw failure
            })
            await work.value
            #expect(model.message?.contains(marker) == true)
            #expect(model.result == nil && model.input == nil && model.hasError && !model.isBusy)
            #expect(await probe.prepared == 1)
            #expect(await probe.factories == 0)
            #expect(await probe.keyReads == 0)
            #expect(await probe.sends == 0)
            #expect(await probe.closes == 0)
        }
    }

    @Test func keychainStatusFailureIsDistinctAndNeverDispatches() async throws {
        let probe = AIWorkspaceProbe(), id = UUID()
        let model = workspace(probe: probe, readKey: {
            await probe.key(); throw CredentialError.status(-34018)
        })
        model.select(reportID: id)
        await (try start(model, id: id, probe: probe)).value
        #expect(model.message?.contains("[AI-KEYCHAIN]") == true)
        #expect(model.message?.contains("OSStatus -34018") == true)
        #expect(model.result == nil && model.input == nil && model.hasError && !model.isBusy)
        #expect(await probe.prepared == 1)
        #expect(await probe.factories == 1)
        #expect(await probe.keyReads == 1)
        #expect(await probe.sends == 0)
        #expect(await probe.closes == 1)
    }

    @Test func manualAPIFailuresPublishSafeDiagnosticsAndNeverRetry() async throws {
        let cases: [(any Error, String)] = [
            (AIAnalysisAPIFailure(statusCode: 401, reason: .authentication), "[AI-HTTP-401-AUTH]"),
            (AIAnalysisAPIFailure(statusCode: 403, reason: .permissionDenied), "[AI-HTTP-403-ACCESS]"),
            (AIAnalysisAPIFailure(statusCode: 404, reason: .modelUnavailable), "[AI-HTTP-404-MODEL]"),
            (AIAnalysisAPIFailure(statusCode: 400, reason: .requestRejected), "[AI-HTTP-400-REQUEST]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .creditsExhausted), "[AI-HTTP-429-CREDITS]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .organizationSpendLimit), "[AI-HTTP-429-ORG-SPEND]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .projectSpendLimit), "[AI-HTTP-429-PROJECT-SPEND]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .organizationUsageLimit), "[AI-HTTP-429-ORG-USAGE]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .quotaExceeded), "[AI-HTTP-429-QUOTA]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .rateLimited), "[AI-HTTP-429-RATE]"),
            (AIAnalysisAPIFailure(statusCode: 429, reason: .rateOrQuota), "[AI-HTTP-429-RATE-OR-QUOTA]"),
            (AIAnalysisAPIFailure(statusCode: 503, reason: .serverFailure), "[AI-HTTP-503-SERVER]"),
            (AIAnalysisNetworkError.timedOut, "[AI-TIMEOUT]"),
            (AIAnalysisNetworkError.connectionFailed, "[AI-CONNECTION]"),
            (AIAnalysisNetworkError.secureConnectionFailed, "[AI-TLS]"),
            (AIInsightError.outputLimitReached, "[AI-OUTPUT-LIMIT]"),
            (AIInsightError.contentFiltered, "[AI-CONTENT-FILTER]"),
            (AIInsightError.responseFailed, "[AI-RESPONSE-FAILED]"),
            (AIInsightError.invalidEvidence, "[AI-EVIDENCE]"),
            (AIInsightError.formatValidation(.responseJSON), "[AI-FORMAT-RESPONSE-JSON]"),
            (AIInsightError.formatValidation(.responseEnvelope), "[AI-FORMAT-RESPONSE-STATE]"),
            (AIInsightError.formatValidation(.responseModel), "[AI-FORMAT-RESPONSE-MODEL]"),
            (AIInsightError.formatValidation(.responseOutput), "[AI-FORMAT-RESPONSE-OUTPUT]"),
            (AIInsightError.formatValidation(.analysisJSON), "[AI-FORMAT-ANSWER-JSON]"),
            (AIInsightError.formatValidation(.analysisFields), "[AI-FORMAT-ANSWER-FIELDS]"),
            (AIInsightError.formatValidation(.valuationFields), "[AI-FORMAT-VALUATION-FIELDS]"),
            (AIInsightError.formatValidation(.scenarioFields), "[AI-FORMAT-SCENARIO-FIELDS]"),
            (AIInsightError.formatValidation(.sectionFields), "[AI-FORMAT-SECTION-FIELDS]"),
            (AIInsightError.formatValidation(.claimFields), "[AI-FORMAT-CLAIM-FIELDS]"),
            (AIInsightError.formatValidation(.analysisDecode), "[AI-FORMAT-ANSWER-TYPE]"),
            (AIInsightError.formatValidation(.usage), "[AI-FORMAT-USAGE]"),
            (AIInsightError.evidenceValidation(.emptyText, section: .summary), "[AI-EVIDENCE-SUMMARY-EMPTY-TEXT]"),
            (AIInsightError.evidenceValidation(.textTooLong, section: .strengths), "[AI-EVIDENCE-STRENGTHS-TEXT-LENGTH]"),
            (AIInsightError.evidenceValidation(.controlCharacter, section: .risks), "[AI-EVIDENCE-RISKS-TEXT-CONTROL]"),
            (AIInsightError.evidenceValidation(.missingReferences, section: .questions), "[AI-EVIDENCE-QUESTIONS-MISSING-REF]"),
            (AIInsightError.evidenceValidation(.tooManyReferences, section: .limitations), "[AI-EVIDENCE-LIMITATIONS-REF-COUNT]"),
            (AIInsightError.evidenceValidation(.duplicateReferences, section: .valuationInterpretation), "[AI-EVIDENCE-VALUATION-DUPLICATE-REF]"),
            (AIInsightError.evidenceValidation(.unknownReference, section: .valuationLimitations), "[AI-EVIDENCE-VALUATION-LIMITATIONS-UNKNOWN-REF]"),
            (AIInsightError.outputStructure(.itemType), "[AI-OUTPUT-ITEM]"),
            (AIInsightError.outputStructure(.reasoningMetadata), "[AI-OUTPUT-REASONING]"),
            (AIInsightError.outputStructure(.messageEnvelope), "[AI-OUTPUT-MESSAGE]"),
            (AIInsightError.outputStructure(.messagePhase), "[AI-OUTPUT-PHASE]"),
            (AIInsightError.outputStructure(.ambiguousMessage), "[AI-OUTPUT-AMBIGUOUS]"),
            (AIInsightError.outputStructure(.contentBlock), "[AI-OUTPUT-CONTENT]"),
            (AIInsightError.outputStructure(.annotations), "[AI-OUTPUT-ANNOTATIONS]"),
            (AIInsightError.outputStructure(.missingText), "[AI-OUTPUT-NO-TEXT]")]
        for (failure, marker) in cases {
            let probe = AIWorkspaceProbe(), id = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { _, _ in
                    await probe.send(); throw failure
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            await (try start(model, id: id, probe: probe)).value
            #expect(model.message?.contains(marker) == true)
            #expect(model.result == nil && model.hasError && !model.isBusy)
            #expect(model.input == aiWorkspaceInput())
            #expect(await probe.prepared == 1)
            #expect(await probe.factories == 1)
            #expect(await probe.keyReads == 1)
            #expect(await probe.sends == 1)
            #expect(await probe.closes == 1)
        }
    }

    @Test func arbitraryFailureDescriptionsAreNeitherReadNorDisplayed() async throws {
        let cases: [(AIWorkspaceFailureStage, String)] = [
            (.preparation, "[AI-LOCAL-REPORT]"), (.service, "[AI-SERVICE]"),
            (.credential, "[AI-KEYCHAIN]"), (.request, "[AI-REQUEST-UNKNOWN]")]
        for (stage, marker) in cases {
            let probe = AIWorkspaceProbe(), descriptions = AIWorkspaceDescriptionCounter(), id = UUID()
            let failure = AIWorkspaceSecretFailure(descriptions: descriptions)
            let model = workspace(probe: probe, readKey: {
                await probe.key()
                if stage == .credential { throw failure }
                return Data("synthetic-ai-key".utf8)
            }, factory: {
                await probe.factory()
                if stage == .service { throw failure }
                return AIInsightSession(send: { _, _ in
                    await probe.send(); throw failure
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            let work = try #require(model.start(reportID: id, model: AIInsightRequest.defaultModel) {
                await probe.prepare()
                if stage == .preparation { throw failure }
                return aiWorkspaceInput()
            })
            await work.value
            let message = try #require(model.message)
            #expect(message.contains(marker))
            #expect(!message.contains("Bearer") && !message.contains("SYNTHETIC-PRIVATE-KEY"))
            #expect(!message.contains("private.invalid"))
            #expect(descriptions.count == 0)
            #expect(model.result == nil && model.hasError && !model.isBusy)
            #expect(await probe.prepared == 1)
            #expect(await probe.factories == (stage == .preparation ? 0 : 1))
            #expect(await probe.keyReads == ((stage == .preparation || stage == .service) ? 0 : 1))
            #expect(await probe.sends == (stage == .request ? 1 : 0))
            #expect(await probe.closes == ((stage == .preparation || stage == .service) ? 0 : 1))
        }
    }

    @Test func evidenceDiagnosticsExposeOnlyClosedReasonsAtRequestAndPublicationBoundaries() async throws {
        for parseInsideSession in [false, true] {
            let probe = AIWorkspaceProbe(), id = UUID()
            let secretMarker = "SYNTHETIC-PRIVATE-EVIDENCE-Bearer-https-private.invalid"
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send()
                    let valid = try aiWorkspaceResult(request)
                    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
                    var analysis = try #require(object["analysis"] as? [String: Any])
                    var valuation = try #require(analysis["valuation"] as? [String: Any])
                    valuation["interpretation"] = ["text": "不得回显：" + secretMarker, "evidenceIDs": [secretMarker]]
                    analysis["valuation"] = valuation; object["analysis"] = analysis
                    if parseInsideSession {
                        let text = String(decoding: try JSONSerialization.data(withJSONObject: analysis), as: UTF8.self)
                        let response: [String: Any] = ["object": "response", "status": "completed", "model": request.model,
                            "output": [["type": "message", "role": "assistant", "status": "completed",
                                "content": [["type": "output_text", "text": text, "annotations": []]]]]]
                        return try request.parseResponse(JSONSerialization.data(withJSONObject: response))
                    }
                    return try JSONDecoder().decode(AIInsightResult.self, from: JSONSerialization.data(withJSONObject: object))
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            await (try start(model, id: id, probe: probe)).value
            let message = try #require(model.message)
            #expect(message.contains("[AI-EVIDENCE-VALUATION-UNKNOWN-REF]"))
            #expect(message.contains("AI 估值参考") && message.contains("不在本次发送资料"))
            #expect(!message.contains(secretMarker) && !message.contains("Bearer") && !message.contains("private.invalid"))
            #expect(model.result == nil && model.hasError && !model.isBusy)
            #expect(await probe.keyReads == 1)
            #expect(await probe.sends == 1)
            #expect(await probe.factories == 1)
            #expect(await probe.closes >= 1)
        }
    }

    @Test func lateEvidenceDiagnosticCannotOverwriteCancellationOrNewReportSession() async throws {
        for cancel in [false, true] {
            let probe = AIWorkspaceProbe(), gate = AIWorkspaceGate(), id = UUID(), nextID = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { _, _ in
                    await probe.send(); await gate.hold()
                    throw AIInsightError.evidenceValidation(.unknownReference, section: .valuationInterpretation)
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            let work = try start(model, id: id, probe: probe)
            await gate.waitUntilEntered()
            if cancel { model.cancel() } else { model.select(reportID: nextID, revision: UUID()) }
            let expectedMessage = model.message
            #expect(model.isBusy && model.result == nil && model.input == nil)
            await gate.release(); await work.value
            #expect(model.message == expectedMessage && !model.hasError && model.result == nil && model.input == nil)
            #expect(model.selectedReportID == (cancel ? id : nextID) && !model.isBusy)
            #expect(await probe.sends == 1)
            #expect(await probe.factories == 1)
            #expect(await probe.keyReads == 1)
        }
    }

    @Test func successfulManualAnalysisKeepsExactInputAndRequestedModelBinding() async throws {
        let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID()
        model.select(reportID: id)
        await (try start(model, id: id, probe: probe)).value
        let result = try #require(model.result)
        #expect(result.inputDigest == (try aiWorkspaceInput().digest()))
        #expect(result.requestedModel == AIInsightRequest.defaultModel)
        #expect(result.promptVersion == AIInsightRequest.promptVersion)
        #expect(result.analysis.summary.evidenceIDs == ["m-revenue"])
        #expect(result.analysis.valuation.scope == .financialContextOnly)
        #expect(result.analysis.valuation.interpretation.evidenceIDs == ["m-revenue"])
        #expect(result.analysis.valuation.limitations.count == 1)
        #expect(result.analysis.valuation.limitations[0].evidenceIDs == ["s-filing"])
        #expect(model.input == aiWorkspaceInput())
        #expect(model.selectedReportID == id && !model.isBusy && !model.hasError)
        #expect(await probe.factories == 1)
        #expect(await probe.keyReads == 1)
        #expect(await probe.sends == 1)
        #expect(await probe.closes == 1)
    }

    @Test func returningToSameVerifiedSummaryKeepsAnswerWithoutAnotherRequest() async throws {
        let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID(), revision = UUID()
        model.select(reportID: id, revision: revision)
        await (try start(model, id: id, probe: probe)).value
        let digest = try #require(model.result?.inputDigest)
        let valuation = try #require(model.result?.analysis.valuation)
        // The company page retains both interpretations while a detail section hides the card.
        model.select(reportID: id, revision: revision)
        #expect(model.result?.inputDigest == digest && model.input != nil)
        #expect(model.result?.analysis.valuation == valuation)
        #expect(await probe.sends == 1)
        #expect(await probe.keyReads == 1)
        #expect(await probe.factories == 1)
        // Rechecking the same immutable ID invalidates both answers without a nil transition.
        model.select(reportID: id, revision: UUID())
        #expect(model.result == nil && model.input == nil)
        // Leaving the company page also clears the selection without sending another request.
        model.select(reportID: nil, revision: nil)
        #expect(model.result == nil && model.input == nil)
        model.select(reportID: id, revision: UUID())
        #expect(model.result == nil)
        model.disappear()
        #expect(model.selectedReportID == nil)
        #expect(await probe.sends == 1)
    }

    @Test func applyingEditingAndClearingReferenceInputsNeverReadsKeyOrSends() async throws {
        let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID(), revision = UUID()
        let original = try aiWorkspaceReference(), edited = try aiWorkspaceReference(price: "21")
        model.select(reportID: id, revision: revision)
        let emptyRevision = model.valuationReferenceRevision
        #expect(model.updateValuationReference(original, reportID: id, reportRevision: revision))
        let appliedRevision = model.valuationReferenceRevision
        #expect(model.valuationReference == original && appliedRevision != emptyRevision)
        #expect(model.updateValuationReference(original, reportID: id, reportRevision: revision))
        #expect(model.valuationReferenceRevision == appliedRevision)
        #expect(model.updateValuationReference(edited, reportID: id, reportRevision: revision))
        let editedRevision = model.valuationReferenceRevision
        #expect(model.valuationReference == edited && editedRevision != appliedRevision)
        #expect(model.updateValuationReference(nil, reportID: id, reportRevision: revision))
        #expect(model.valuationReference == nil && model.valuationReferenceRevision != editedRevision)
        #expect(model.result == nil && model.input == nil && !model.isBusy && !model.hasError)
        #expect(await probe.prepared == 0)
        #expect(await probe.factories == 0)
        #expect(await probe.keyReads == 0)
        #expect(await probe.sends == 0)
    }

    @Test func changingOrClearingReferenceInputsInvalidatesBothPublishedAnswers() async throws {
        for clear in [false, true] {
            let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID(), revision = UUID()
            let original = try aiWorkspaceReference()
            let replacement: AIValuationReferenceInput?
            if clear { replacement = nil } else { replacement = try aiWorkspaceReference(price: "21") }
            let summary = try aiWorkspaceReferenceSummary(original)
            model.select(reportID: id, revision: revision)
            #expect(model.updateValuationReference(original, reportID: id, reportRevision: revision))
            let work = try #require(model.start(reportID: id, model: AIInsightRequest.defaultModel) {
                await probe.prepare(); return summary
            })
            await work.value
            let result = try #require(model.result)
            #expect(result.analysis.summary.evidenceIDs == ["m-revenue"])
            #expect(result.analysis.valuation.scope == .referenceMultiples)
            #expect(result.inputDigest == (try summary.digest()))
            let oldReferenceRevision = model.valuationReferenceRevision
            #expect(model.updateValuationReference(replacement, reportID: id, reportRevision: revision))
            // Financial and valuation cards have one publication owner; neither may keep
            // the old answer when its reference assumptions no longer match the form.
            #expect(model.result == nil && model.input == nil && model.message == nil)
            #expect(model.valuationReference == replacement)
            #expect(model.valuationReferenceRevision != oldReferenceRevision)
            #expect(!model.hasError && !model.isBusy)
            #expect(await probe.prepared == 1)
            #expect(await probe.factories == 1)
            #expect(await probe.keyReads == 1)
            #expect(await probe.sends == 1)
        }
    }

    @Test func changedOrClearedReferenceRejectsLateSuccessAndFailure() async throws {
        for clear in [false, true] {
            for fail in [false, true] {
                let probe = AIWorkspaceProbe(), sent = AIWorkspaceGate(), id = UUID(), revision = UUID()
                let model = workspace(probe: probe, factory: {
                    await probe.factory()
                    return AIInsightSession(send: { request, _ in
                        await probe.send(); await sent.hold()
                        if fail { throw AIAnalysisAPIFailure(statusCode: 429, reason: .quotaExceeded) }
                        return try aiWorkspaceResult(request)
                    }, close: { await probe.close() })
                })
                let original = try aiWorkspaceReference()
                let replacement: AIValuationReferenceInput?
                if clear { replacement = nil } else { replacement = try aiWorkspaceReference(price: "21") }
                let summary = try aiWorkspaceReferenceSummary(original)
                model.select(reportID: id, revision: revision)
                #expect(model.updateValuationReference(original, reportID: id, reportRevision: revision))
                let work = try #require(model.start(reportID: id, model: AIInsightRequest.defaultModel) {
                    await probe.prepare(); return summary
                })
                await sent.waitUntilEntered()
                #expect(model.input == summary && model.isBusy)
                let oldReferenceRevision = model.valuationReferenceRevision
                #expect(model.updateValuationReference(replacement, reportID: id, reportRevision: revision))
                #expect(model.isBusy && model.input == nil && model.result == nil)
                #expect(model.valuationReferenceRevision != oldReferenceRevision)
                #expect(model.start(reportID: id, model: AIInsightRequest.defaultModel,
                                    prepare: { summary }) == nil)
                await sent.release(); await work.value
                #expect(model.valuationReference == replacement)
                #expect(model.selectedReportID == id && model.selectedReportRevision == revision)
                #expect(model.result == nil && model.input == nil && model.message == nil)
                #expect(!model.hasError && !model.isBusy)
                #expect(await probe.factories == 1)
                #expect(await probe.keyReads == 1)
                #expect(await probe.sends == 1)
                #expect(await probe.closes >= 1)
            }
        }
    }

    @Test func reportRevisionAndPageChangesClearManualReferenceInputs() async throws {
        for change in ["report", "revision", "disappear"] {
            let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID(), revision = UUID()
            let reference = try aiWorkspaceReference()
            model.select(reportID: id, revision: revision)
            #expect(model.updateValuationReference(reference, reportID: id, reportRevision: revision))
            let referenceRevision = model.valuationReferenceRevision
            model.select(reportID: id, revision: revision)
            #expect(model.valuationReference == reference && model.valuationReferenceRevision == referenceRevision)
            switch change {
            case "report": model.select(reportID: UUID(), revision: UUID())
            case "revision": model.select(reportID: id, revision: UUID())
            default: model.disappear()
            }
            #expect(model.valuationReference == nil && model.valuationReferenceRevision != referenceRevision)
            #expect(model.input == nil && model.result == nil && !model.isBusy)
            #expect(await probe.prepared == 0)
            #expect(await probe.factories == 0)
            #expect(await probe.keyReads == 0)
            #expect(await probe.sends == 0)
        }
    }

    @Test func oldReferenceSheetCannotApplyOrClearAnotherReportOrRevision() async throws {
        let probe = AIWorkspaceProbe(), model = workspace(probe: probe)
        let oldID = UUID(), oldRevision = UUID(), currentID = UUID(), currentRevision = UUID()
        let original = try aiWorkspaceReference(), current = try aiWorkspaceReference(price: "21")
        model.select(reportID: oldID, revision: oldRevision)
        model.select(reportID: currentID, revision: currentRevision)
        #expect(model.updateValuationReference(current, reportID: currentID, reportRevision: currentRevision))
        let referenceRevision = model.valuationReferenceRevision
        #expect(!model.updateValuationReference(original, reportID: oldID, reportRevision: oldRevision))
        #expect(!model.updateValuationReference(nil, reportID: oldID, reportRevision: oldRevision))
        #expect(!model.updateValuationReference(original, reportID: currentID, reportRevision: oldRevision))
        #expect(!model.updateValuationReference(nil, reportID: currentID, reportRevision: oldRevision))
        #expect(!model.updateValuationReference(original, reportID: oldID, reportRevision: currentRevision))
        #expect(model.valuationReference == current && model.valuationReferenceRevision == referenceRevision)
        model.disappear()
        #expect(!model.updateValuationReference(current, reportID: currentID, reportRevision: currentRevision))
        #expect(model.valuationReference == nil && model.selectedReportID == nil)
        #expect(await probe.prepared == 0)
        #expect(await probe.factories == 0)
        #expect(await probe.keyReads == 0)
        #expect(await probe.sends == 0)
    }

    @Test func switchingReportsRejectsLateSuccessAndFailureFromPreviousReport() async throws {
        for fail in [false, true] {
            let probe = AIWorkspaceProbe(), sent = AIWorkspaceGate(), oldID = UUID(), newID = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send(); await sent.hold()
                    if fail { throw AIAnalysisAPIFailure(statusCode: 401, reason: .authentication) }
                    return try aiWorkspaceResult(request)
                }, close: { await probe.close() })
            })
            model.select(reportID: oldID)
            let work = try start(model, id: oldID, probe: probe)
            await sent.waitUntilEntered()
            model.select(reportID: newID)
            #expect(model.isBusy && model.input == nil && model.result == nil)
            #expect(model.start(reportID: newID, model: AIInsightRequest.defaultModel, prepare: { aiWorkspaceInput() }) == nil)
            await sent.release(); await work.value
            #expect(model.selectedReportID == newID && !model.isBusy)
            #expect(model.result == nil && model.input == nil && model.message == nil && !model.hasError)
            #expect(await probe.sends == 1)
            #expect(await probe.closes >= 1)
        }
    }

    @Test func sameReportIDWithChangedDigestInvalidatesAnInFlightInterpretation() async throws {
        for fail in [false, true] {
            let probe = AIWorkspaceProbe(), sent = AIWorkspaceGate(), id = UUID()
            let oldRevision = UUID(), newRevision = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send(); await sent.hold()
                    if fail { throw AIWorkspaceTestFailure.injected }
                    return try aiWorkspaceResult(request)
                }, close: { await probe.close() })
            })
            model.select(reportID: id, revision: oldRevision)
            let work = try start(model, id: id, probe: probe)
            await sent.waitUntilEntered()
            model.select(reportID: id, revision: oldRevision)
            #expect(model.input == aiWorkspaceInput())
            model.select(reportID: id, revision: newRevision)
            #expect(model.isBusy && model.input == nil && model.result == nil)
            await sent.release(); await work.value
            #expect(model.selectedReportID == id)
            #expect(model.selectedReportRevision == newRevision)
            #expect(model.result == nil && model.input == nil && model.message == nil && !model.hasError)
            #expect(!model.isBusy)
            #expect(await probe.sends == 1)
        }
    }

    @Test func aiCredentialReferenceDoesNotOverwriteOrDeleteReservedServiceCredential() async {
        let store = AIWorkspaceNamespacedCredentials()
        let dataSettings = CredentialSettingsModel(store: store)
        let aiSettings = CredentialSettingsModel(store: store, reference: AIInsightWorkspaceModel.credentialReference)
        #expect(await dataSettings.refresh())
        #expect(await aiSettings.refresh())
        #expect(dataSettings.presence == .absent && aiSettings.presence == .absent)
        #expect(await dataSettings.save("synthetic-data-credential", expectedRevision: dataSettings.revision))
        #expect(await aiSettings.save("synthetic-ai-credential", expectedRevision: aiSettings.revision))
        let stored = await store.values
        #expect(Set(stored.keys) == Set(["reserved-data-service", AIInsightWorkspaceModel.credentialReference]))
        #expect(stored["reserved-data-service"] == Data("synthetic-data-credential".utf8))
        #expect(stored[AIInsightWorkspaceModel.credentialReference] == Data("synthetic-ai-credential".utf8))
        #expect(await aiSettings.delete(expectedRevision: aiSettings.revision))
        #expect(await dataSettings.refresh())
        #expect(await aiSettings.refresh())
        #expect(dataSettings.presence == .saved && aiSettings.presence == .absent)
        #expect(await store.values == ["reserved-data-service": Data("synthetic-data-credential".utf8)])
    }

    @Test func cancelMessageSurvivesLateProviderSuccessAndFailure() async throws {
        for fail in [false, true] {
            let probe = AIWorkspaceProbe(), sent = AIWorkspaceGate(), id = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send(); await sent.hold()
                    if fail { throw AIAnalysisAPIFailure(statusCode: 429, reason: .quotaExceeded) }
                    return try aiWorkspaceResult(request)
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            let work = try start(model, id: id, probe: probe)
            await sent.waitUntilEntered(); model.cancel()
            let cancellationMessage = try #require(model.message)
            #expect(model.isBusy && model.result == nil && model.input == nil)
            await sent.release(); await work.value
            #expect(model.message == cancellationMessage && model.result == nil && !model.hasError)
            #expect(!model.isBusy && model.selectedReportID == id)
            #expect(await probe.sends == 1)
        }
    }

    @Test func leavingPageDoesNotPublishLateResponseOrReopenSelection() async throws {
        let probe = AIWorkspaceProbe(), sent = AIWorkspaceGate(), id = UUID()
        let model = workspace(probe: probe, factory: {
            await probe.factory()
            return AIInsightSession(send: { request, _ in
                await probe.send(); await sent.hold(); return try aiWorkspaceResult(request)
            }, close: { await probe.close() })
        })
        model.select(reportID: id)
        let work = try start(model, id: id, probe: probe)
        await sent.waitUntilEntered(); model.disappear()
        await sent.release(); await work.value
        #expect(model.selectedReportID == nil && model.result == nil && model.input == nil)
        #expect(model.message == nil && !model.hasError && !model.isBusy)
    }

    @Test func busyRemainsUntilCloseFinishesAndCannotOverlapManualRequests() async throws {
        let probe = AIWorkspaceProbe(), closing = AIWorkspaceGate(), id = UUID()
        let model = workspace(probe: probe, factory: {
            await probe.factory()
            return AIInsightSession(send: { request, _ in
                await probe.send(); return try aiWorkspaceResult(request)
            }, close: { await probe.close(); await closing.hold() })
        })
        model.select(reportID: id)
        let work = try start(model, id: id, probe: probe)
        await closing.waitUntilEntered()
        #expect(model.isBusy && model.result == nil)
        #expect(model.start(reportID: id, model: AIInsightRequest.defaultModel, prepare: { aiWorkspaceInput() }) == nil)
        #expect(await probe.factories == 1)
        await closing.release(); await work.value
        #expect(!model.isBusy && model.result != nil)
    }

    @Test func credentialRevisionChangedDuringFactoryBlocksKeyReadAndClosesSession() async throws {
        let probe = AIWorkspaceProbe(), gate = AIWorkspaceGate(), id = UUID(), settings = credentials()
        let model = workspace(probe: probe, credentials: settings, factory: {
            await probe.factory(); await gate.hold()
            return AIInsightSession(send: { request, _ in
                await probe.send(); return try aiWorkspaceResult(request)
            }, close: { await probe.close() })
        })
        model.select(reportID: id)
        let work = try start(model, id: id, probe: probe)
        await gate.waitUntilEntered(); #expect(await settings.refresh())
        await gate.release(); await work.value
        #expect(await probe.keyReads == 0)
        #expect(await probe.sends == 0)
        #expect(await probe.closes == 1)
        #expect(model.result == nil && model.message == nil && !model.hasError && !model.isBusy)
    }

    @Test func credentialRevisionChangedDuringKeyReadPreventsDispatch() async throws {
        let probe = AIWorkspaceProbe(), gate = AIWorkspaceGate(), id = UUID(), settings = credentials()
        let model = workspace(probe: probe, credentials: settings, readKey: {
            await probe.key(); await gate.hold(); return Data("synthetic-stale-key".utf8)
        })
        model.select(reportID: id)
        let work = try start(model, id: id, probe: probe)
        await gate.waitUntilEntered(); #expect(await settings.refresh())
        await gate.release(); await work.value
        #expect(await probe.keyReads == 1)
        #expect(await probe.sends == 0)
        #expect(await probe.closes == 1)
        #expect(model.result == nil && model.input == nil && model.message == nil && !model.isBusy)
    }

    @Test func credentialRevisionChangedInFlightRejectsCompletedResponse() async throws {
        let probe = AIWorkspaceProbe(), gate = AIWorkspaceGate(), id = UUID(), settings = credentials()
        let model = workspace(probe: probe, credentials: settings, factory: {
            await probe.factory()
            return AIInsightSession(send: { request, _ in
                await probe.send(); await gate.hold(); return try aiWorkspaceResult(request)
            }, close: { await probe.close() })
        })
        model.select(reportID: id)
        let work = try start(model, id: id, probe: probe)
        await gate.waitUntilEntered(); #expect(await settings.refresh())
        await gate.release(); await work.value
        #expect(await probe.sends == 1)
        #expect(model.result == nil && model.message == nil && !model.hasError && !model.isBusy)
    }

    @Test func responseFromDifferentInputOrRequestedModelIsRejected() async throws {
        for wrongModel in [false, true] {
            let probe = AIWorkspaceProbe(), id = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send()
                    let different = AIInsightRequest(input: wrongModel ? request.input : aiWorkspaceInput(revenue: "999"),
                        model: wrongModel ? "gpt-6-other" : request.model)
                    return try aiWorkspaceResult(different)
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            await (try start(model, id: id, probe: probe)).value
            #expect(model.result == nil && model.hasError && !model.isBusy)
            #expect(model.message?.contains("[AI-RESULT-BINDING]") == true)
            #expect(await probe.sends == 1)
            #expect(await probe.closes >= 1)
        }
    }

    @Test func oldPromptOrInvalidValuationEvidenceCannotBypassPublicationValidation() async throws {
        for oldPrompt in [false, true] {
            let probe = AIWorkspaceProbe(), id = UUID()
            let model = workspace(probe: probe, factory: {
                await probe.factory()
                return AIInsightSession(send: { request, _ in
                    await probe.send()
                    let valid = try aiWorkspaceResult(request)
                    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
                    if oldPrompt {
                        object["promptVersion"] = "financial-evidence-interpretation.v1"
                    } else {
                        var analysis = try #require(object["analysis"] as? [String: Any])
                        var valuation = try #require(analysis["valuation"] as? [String: Any])
                        var claim = try #require(valuation["interpretation"] as? [String: Any])
                        claim["evidenceIDs"] = ["not-in-request"]
                        valuation["interpretation"] = claim
                        analysis["valuation"] = valuation
                        object["analysis"] = analysis
                    }
                    // Bypass the response parser as a faulty session dependency could do.
                    // The production publication boundary must still reject this result.
                    return try JSONDecoder().decode(AIInsightResult.self,
                        from: JSONSerialization.data(withJSONObject: object))
                }, close: { await probe.close() })
            })
            model.select(reportID: id)
            await (try start(model, id: id, probe: probe)).value
            #expect(model.result == nil && model.hasError && !model.isBusy)
            #expect(model.message?.contains(oldPrompt ? "[AI-RESULT-BINDING]" : "[AI-EVIDENCE-VALUATION-UNKNOWN-REF]") == true)
            #expect(await probe.keyReads == 1)
            #expect(await probe.sends == 1)
            #expect(await probe.closes >= 1)
        }
    }

    @Test func rerunFailureClearsFinancialAndValuationAnswersTogether() async throws {
        let probe = AIWorkspaceProbe(), id = UUID()
        let model = workspace(probe: probe, factory: {
            await probe.factory()
            return AIInsightSession(send: { request, _ in
                await probe.send()
                if await probe.sends == 1 { return try aiWorkspaceResult(request) }
                throw AIAnalysisAPIFailure(statusCode: 503, reason: .serverFailure)
            }, close: { await probe.close() })
        })
        model.select(reportID: id, revision: UUID())
        await (try start(model, id: id, probe: probe)).value
        #expect(model.result?.analysis.valuation.scope == .financialContextOnly)
        let retry = try start(model, id: id, probe: probe)
        #expect(model.result == nil && model.isBusy)
        await retry.value
        #expect(model.result == nil && model.hasError && !model.isBusy)
        #expect(model.message?.contains("[AI-HTTP-503-SERVER]") == true)
        #expect(await probe.sends == 2)
        #expect(await probe.keyReads == 2)
        #expect(await probe.factories == 2)
    }

    @Test func invalidSummaryAndModelFailBeforeCreatingServiceOrReadingKey() async throws {
        for invalidSummary in [false, true] {
            let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID()
            model.select(reportID: id)
            let work = try #require(model.start(reportID: id,
                model: invalidSummary ? AIInsightRequest.defaultModel : "bad model") {
                    await probe.prepare()
                    if invalidSummary { throw AIWorkspaceTestFailure.injected }
                    return aiWorkspaceInput()
                })
            await work.value
            #expect(model.result == nil && model.input == nil && model.hasError && !model.isBusy)
            #expect(model.message?.contains(invalidSummary ? "[AI-LOCAL-REPORT]" : "[AI-MODEL-FORMAT]") == true)
            #expect(await probe.factories == 0)
            #expect(await probe.keyReads == 0)
            #expect(await probe.sends == 0)
        }
    }
}
