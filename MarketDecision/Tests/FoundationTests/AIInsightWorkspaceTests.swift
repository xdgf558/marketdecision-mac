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

private func aiWorkspaceResult(_ request: AIInsightRequest, encryptedReasoning: Bool = false) throws -> AIInsightResult {
    let analysis: [String: Any] = [
        "summary": ["text": "仅解读当前提供的营收证据。", "evidenceIDs": ["m-revenue"]],
        "strengths": [], "risks": [], "questions": [],
        "limitations": [["text": "合成摘要不足以形成投资判断。", "evidenceIDs": ["s-filing"]]]
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
            (.invalidCutoff, "[AI-LOCAL-CUTOFF]")]
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

    @Test func successfulManualAnalysisKeepsExactInputAndRequestedModelBinding() async throws {
        let probe = AIWorkspaceProbe(), model = workspace(probe: probe), id = UUID()
        model.select(reportID: id)
        await (try start(model, id: id, probe: probe)).value
        let result = try #require(model.result)
        #expect(result.inputDigest == (try aiWorkspaceInput().digest()))
        #expect(result.requestedModel == AIInsightRequest.defaultModel)
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
        // The company page retains this selection while a detail section hides the card.
        model.select(reportID: id, revision: revision)
        #expect(model.result?.inputDigest == digest && model.input != nil)
        #expect(await probe.sends == 1)
        #expect(await probe.keyReads == 1)
        #expect(await probe.factories == 1)
        // Rechecking the same immutable report or leaving the company page invalidates it.
        model.select(reportID: nil, revision: nil)
        #expect(model.result == nil && model.input == nil)
        model.select(reportID: id, revision: UUID())
        #expect(model.result == nil)
        model.disappear()
        #expect(model.selectedReportID == nil)
        #expect(await probe.sends == 1)
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
