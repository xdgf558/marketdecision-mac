import Foundation
import Testing
import AIInsights
import SecuritySupport
@testable import AppComposition

private actor BenchmarkWorkspaceGate {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        let pending = arrivals; arrivals.removeAll()
        for continuation in pending { continuation.resume() }
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
        for continuation in pending { continuation.resume() }
    }
}

private actor BenchmarkWorkspaceProbe {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor BenchmarkWorkspaceCredentials: CredentialStorage {
    private(set) var checks = 0
    func contains(reference: String) -> Bool { checks += 1; return true }
    func save(_ secret: Data, reference: String) {}
    func delete(reference: String) {}
}

private enum BenchmarkWorkspaceFailure: Error { case injected }
private final class BenchmarkWorkspaceDescriptionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private struct BenchmarkWorkspaceSecretFailure: LocalizedError, CustomStringConvertible {
    let counter: BenchmarkWorkspaceDescriptionCounter
    var errorDescription: String? { counter.increment(); return "Bearer SYNTHETIC-PRIVATE-KEY" }
    var description: String { counter.increment(); return "https://private.invalid/?secret=SYNTHETIC-PRIVATE-KEY" }
}

private func benchmarkWorkspaceResponse(_ request: AIBenchmarkRequest, available: Bool = false,
                                        unavailableReason: String = "insufficient_evidence",
                                        incompleteReason: String? = nil) throws -> AIBenchmarkResult {
    let source = "https://fred.stlouisfed.org/series/SP500"
    let body: [String: Any] = [
        "status": available ? "available" : "unavailable", "index": "S&P500",
        "returnType": "PRICE_RETURN", "currency": "USD",
        "start": available ? ["day": "2025-10-24", "close": "6000"] : NSNull(),
        "end": available ? ["day": "2026-10-23", "close": "6600"] : NSNull(),
        "unavailableReason": available ? NSNull() : unavailableReason
    ]
    let outputText = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    let sources: [[String: String]] = available ? [["type": "url", "url": source, "title": "S&P 500 — synthetic test"]] : []
    let details: Any
    if let incompleteReason { details = ["reason": incompleteReason] }
    else { details = NSNull() }
    let response: [String: Any] = [
        "object": "response", "status": incompleteReason == nil ? "completed" : "incomplete", "model": "synthetic-model",
        "error": NSNull(), "incomplete_details": details,
        "output": [
            ["type": "web_search_call", "id": "ws_synthetic", "status": "completed",
             "action": ["type": "search", "query": "S&P 500 synthetic fixture", "sources": sources]],
            ["type": "message", "role": "assistant", "status": "completed",
             "content": [["type": "output_text", "text": outputText, "annotations": []]]]
        ]
    ]
    return try request.parseResponse(JSONSerialization.data(withJSONObject: response))
}

@Suite("Explicit share benchmark request lifecycle") @MainActor
struct InvestmentBenchmarkWorkspaceTests {
    private var start: Date { Date(timeIntervalSince1970: 1_761_337_800) } // 2025-10-24 20:30 UTC
    private var end: Date { Date(timeIntervalSince1970: 1_792_787_400) } // 2026-10-23 20:30 UTC
    private func credentials(_ store: BenchmarkWorkspaceCredentials = .init()) -> CredentialSettingsModel {
        .init(store: store, reference: AIInsightWorkspaceModel.credentialReference)
    }
    private func workspace(_ probe: BenchmarkWorkspaceProbe, credentials: CredentialSettingsModel? = nil,
                           available: Bool = true,
                           readKey: (@Sendable () async throws -> Data?)? = nil,
                           factory: (@Sendable () async throws -> InvestmentBenchmarkSession)? = nil) -> InvestmentBenchmarkWorkspaceModel {
        // Preserve Sendable before nil-coalescing; Swift 6.1 does not infer it
        // for an inline default closure in the optional expression.
        let defaultReadKey: @Sendable () async throws -> Data? = {
            await probe.record("key"); return Data("synthetic-benchmark-key".utf8)
        }
        let defaultFactory: @Sendable () async throws -> InvestmentBenchmarkSession = {
            await probe.record("factory")
            return InvestmentBenchmarkSession(send: { request, _ in
                await probe.record("send"); return try benchmarkWorkspaceResponse(request)
            }, close: { await probe.record("close") })
        }
        return .init(credentials: credentials ?? self.credentials(), networkAvailable: available,
                     readKey: readKey ?? defaultReadKey, factory: factory ?? defaultFactory)
    }
    private func select(_ model: InvestmentBenchmarkWorkspaceModel, id: UUID = UUID()) {
        model.select(snapshotID: id, start: start, end: end, model: "synthetic-model")
    }

    @Test func selectingPeriodsAndLeavingReadsNoCredentialAndCreatesNoSession() async {
        let probe = BenchmarkWorkspaceProbe(), store = BenchmarkWorkspaceCredentials()
        let model = workspace(probe, credentials: credentials(store)), id = UUID()
        select(model, id: id); select(model, id: id)
        model.select(snapshotID: id, start: start.addingTimeInterval(0.0004), end: end, model: "synthetic-model")
        model.credentialsChanged(); model.disappear()
        #expect(model.selectedSnapshotID == nil && model.result == nil && !model.isBusy)
        #expect(await probe.events.isEmpty)
        #expect(await store.checks == 0)
    }

    @Test func missingSelectionUnavailableServiceAndInvalidPeriodNeverReadKey() async throws {
        let probe = BenchmarkWorkspaceProbe(), model = workspace(probe)
        #expect(model.startSearch() == nil)
        let unavailable = workspace(probe, available: false)
        select(unavailable)
        #expect(unavailable.startSearch() == nil)
        #expect(unavailable.message?.contains("[AI-SERVICE]") == true)
        model.select(snapshotID: UUID(), start: end, end: start, model: "synthetic-model")
        await (try #require(model.startSearch())).value
        #expect(model.message?.contains("[AI-BENCHMARK-INPUT]") == true)
        #expect(!model.isBusy && model.result == nil)
        #expect(await probe.events.isEmpty)
    }

    @Test func serviceValidationFailurePrecedesEveryCredentialRead() async throws {
        let probe = BenchmarkWorkspaceProbe()
        let model = workspace(probe, factory: {
            await probe.record("factory"); throw BenchmarkWorkspaceFailure.injected
        })
        select(model)
        await (try #require(model.startSearch())).value
        #expect(await probe.events == ["factory"])
        #expect(model.message?.contains("[AI-SERVICE]") == true)
        #expect(!model.isBusy && model.result == nil)
    }

    @Test func absentOrEmptyCredentialClosesSessionAndNeverSends() async throws {
        for key: Data? in [nil, Data()] {
            let probe = BenchmarkWorkspaceProbe()
            let model = workspace(probe, readKey: { await probe.record("key"); return key })
            select(model)
            await (try #require(model.startSearch())).value
            #expect(await probe.events == ["factory", "key", "close"])
            #expect(model.message?.contains("[AI-KEY-MISSING]") == true)
            #expect(!model.isBusy && model.result == nil)
        }
    }

    @Test func oneExplicitSearchPublishesCheckedReferenceAfterSessionCloses() async throws {
        let probe = BenchmarkWorkspaceProbe()
        let model = workspace(probe, factory: {
            await probe.record("factory")
            return InvestmentBenchmarkSession(send: { request, _ in
                await probe.record("send"); return try benchmarkWorkspaceResponse(request, available: true)
            }, close: { await probe.record("close") })
        })
        select(model)
        await (try #require(model.startSearch())).value
        let result = try #require(model.result), reference = try #require(result.reference)
        try result.validate(for: AIBenchmarkRequest(start: start, end: end, model: "synthetic-model"))
        #expect(reference.changePercent.decimalString == "10")
        #expect(await probe.events == ["factory", "key", "send", "close"])
        #expect(!model.isBusy)
    }

    @Test func unavailableEvidencePublishesMissingStatusWithoutFabricatingZero() async throws {
        let reasons = [
            ("not_found", "[AI-BENCHMARK-NOT-FOUND]"),
            ("insufficient_evidence", "[AI-BENCHMARK-INSUFFICIENT]"),
            ("ambiguous_series", "[AI-BENCHMARK-SERIES]")
        ]
        for (reason, marker) in reasons {
            let probe = BenchmarkWorkspaceProbe()
            let model = workspace(probe, factory: {
                await probe.record("factory")
                return InvestmentBenchmarkSession(send: { request, _ in
                    await probe.record("send")
                    return try benchmarkWorkspaceResponse(request, unavailableReason: reason)
                }, close: { await probe.record("close") })
            })
            select(model)
            await (try #require(model.startSearch())).value
            #expect(try #require(model.result).reference == nil)
            #expect(model.message?.contains(marker) == true)
            #expect(model.message?.contains("未用零") == true)
            #expect(model.message?.contains("手动重试") == true)
            #expect(await probe.events == ["factory", "key", "send", "close"])
        }
    }

    @Test func cancellationWaitsForSendAndSharedCleanupBeforeAnotherPaidRequest() async throws {
        let probe = BenchmarkWorkspaceProbe(), sendGate = BenchmarkWorkspaceGate(), closeGate = BenchmarkWorkspaceGate()
        let model = workspace(probe, factory: {
            await probe.record("factory")
            return InvestmentBenchmarkSession(send: { request, _ in
                await probe.record("send"); await sendGate.hold()
                return try benchmarkWorkspaceResponse(request)
            }, close: { await probe.record("close"); await closeGate.hold() })
        })
        select(model)
        let work = try #require(model.startSearch())
        await sendGate.waitUntilEntered()
        #expect(model.startSearch() == nil)
        model.cancel()
        await closeGate.waitUntilEntered()
        #expect(model.isBusy && model.startSearch() == nil && model.result == nil)
        await sendGate.release()
        #expect(model.isBusy)
        await closeGate.release(); await work.value
        #expect(!model.isBusy && model.result == nil)
        #expect(model.message?.contains("已取消") == true)
        #expect(await probe.events == ["factory", "key", "send", "close"])
    }

    @Test func changedSnapshotPeriodOrModelRejectsLateResponseFromPriorSelection() async throws {
        for change in ["snapshot", "period", "model"] {
            let probe = BenchmarkWorkspaceProbe(), gate = BenchmarkWorkspaceGate(), id = UUID()
            let model = workspace(probe, factory: {
                await probe.record("factory")
                return InvestmentBenchmarkSession(send: { request, _ in
                    await probe.record("send"); await gate.hold()
                    return try benchmarkWorkspaceResponse(request)
                }, close: { await probe.record("close") })
            })
            select(model, id: id)
            let work = try #require(model.startSearch())
            await gate.waitUntilEntered()
            model.select(snapshotID: change == "snapshot" ? UUID() : id,
                start: change == "period" ? start.addingTimeInterval(0.0004) : start,
                end: end, model: change == "model" ? "synthetic-other" : "synthetic-model")
            #expect(model.isBusy && model.result == nil && model.message == nil)
            await gate.release(); await work.value
            #expect(!model.isBusy && model.result == nil && model.message == nil)
            #expect(await probe.events == ["factory", "key", "send", "close"])
        }
    }

    @Test func credentialRevisionChangeDuringReadRejectsKeyBeforeDispatch() async throws {
        let probe = BenchmarkWorkspaceProbe(), gate = BenchmarkWorkspaceGate(), settings = credentials()
        let model = workspace(probe, credentials: settings, readKey: {
            await probe.record("key"); await gate.hold(); return Data("synthetic-obsolete-key".utf8)
        })
        select(model)
        let work = try #require(model.startSearch())
        await gate.waitUntilEntered()
        #expect(await settings.refresh())
        // The revision check protects the request even if the UI observation
        // has not yet called credentialsChanged().
        await gate.release(); await work.value
        #expect(await probe.events == ["factory", "key", "close"])
        #expect(!model.isBusy && model.result == nil && model.message == nil)
    }

    @Test func departureDuringFactoryClosesLateSessionWithoutReadingKey() async throws {
        let probe = BenchmarkWorkspaceProbe(), gate = BenchmarkWorkspaceGate(), id = UUID()
        let model = workspace(probe, factory: {
            await probe.record("factory"); await gate.hold()
            return InvestmentBenchmarkSession(send: { request, _ in
                await probe.record("send"); return try benchmarkWorkspaceResponse(request)
            }, close: { await probe.record("close") })
        })
        select(model, id: id)
        let work = try #require(model.startSearch())
        await gate.waitUntilEntered()
        model.disappear(); select(model, id: id)
        #expect(model.startSearch() == nil)
        await gate.release(); await work.value
        #expect(await probe.events == ["factory", "close"])
        #expect(model.result == nil && model.message == nil && !model.isBusy)
    }

    @Test func mismatchedResultIsRejectedEvenWhenSessionBypassesResponseParserBinding() async throws {
        let probe = BenchmarkWorkspaceProbe()
        let other = AIBenchmarkRequest(start: start.addingTimeInterval(-86_400), end: end, model: "synthetic-model")
        let model = workspace(probe, factory: {
            await probe.record("factory")
            return InvestmentBenchmarkSession(send: { _, _ in
                await probe.record("send"); return try benchmarkWorkspaceResponse(other)
            }, close: { await probe.record("close") })
        })
        select(model)
        await (try #require(model.startSearch())).value
        #expect(model.result == nil && !model.isBusy)
        #expect(model.message?.contains("[AI-BENCHMARK-EVIDENCE]") == true)
        #expect(await probe.events == ["factory", "key", "send", "close"])
    }

    @Test func arbitraryRequestFailureDoesNotReadDescriptionsOrAutomaticallyRetry() async throws {
        let probe = BenchmarkWorkspaceProbe(), counter = BenchmarkWorkspaceDescriptionCounter()
        let model = workspace(probe, factory: {
            await probe.record("factory")
            return InvestmentBenchmarkSession(send: { _, _ in
                await probe.record("send"); throw BenchmarkWorkspaceSecretFailure(counter: counter)
            }, close: { await probe.record("close") })
        })
        select(model)
        await (try #require(model.startSearch())).value
        let message = try #require(model.message)
        #expect(!message.contains("Bearer") && !message.contains("private.invalid"))
        #expect(counter.count == 0 && model.result == nil && !model.isBusy)
        #expect(await probe.events == ["factory", "key", "send", "close"])
    }

    @Test func outputLimitDiscardsPartialBenchmarkAndRequiresAnExplicitRetry() async throws {
        let probe = BenchmarkWorkspaceProbe()
        let model = workspace(probe, factory: {
            await probe.record("factory")
            return InvestmentBenchmarkSession(send: { request, _ in
                await probe.record("send")
                let data = try request.encodedBody()
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["max_output_tokens"] as? Int == 25_000)
                #expect(body["reasoning"] as? [String: String] == ["effort": "max"])
                return try benchmarkWorkspaceResponse(request, available: true,
                                                      incompleteReason: "max_output_tokens")
            }, close: { await probe.record("close") })
        })
        model.select(snapshotID: UUID(), start: start, end: end, model: "gpt-6.1-sol")
        await (try #require(model.startSearch())).value
        #expect(model.result == nil && !model.isBusy)
        #expect(model.message?.contains("[AI-BENCHMARK-OUTPUT-LIMIT]") == true)
        #expect(await probe.events == ["factory", "key", "send", "close"])

        // Only a second explicit action may send again, with the same finite budget.
        await (try #require(model.startSearch())).value
        #expect(model.result == nil && !model.isBusy)
        #expect(await probe.events == ["factory", "key", "send", "close", "factory", "key", "send", "close"])
    }

    @Test func benchmarkResponseFailuresUseClosedSpecificDiagnosticsWithoutRetrying() async throws {
        let cases: [(AIBenchmarkError, String)] = [
            (.missingSearch, "NO-SEARCH"), (.invalidIndex, "INDEX"), (.invalidWindow, "WINDOW"),
            (.invalidPrice, "PRICE"), (.invalidEvidence, "SOURCE-METADATA"), (.malformedResponse, "FORMAT"),
            (.unsupportedSourceURL, "SOURCE-URL"),
            (.sourceURLLimit, "SOURCE-LIMIT"), (.missingSourceMetadata, "SOURCE-LIST"),
            (.ambiguousOutput, "AMBIGUOUS"), (.incompleteResponse, "INCOMPLETE"), (.outputLimitReached, "OUTPUT-LIMIT"),
            (.budgetExceeded, "LIMIT"), (.invalidModel, "MODEL"), (.invalidRequest, "REQUEST")
        ]
        for (failure, code) in cases {
            let probe = BenchmarkWorkspaceProbe()
            let model = workspace(probe, factory: {
                await probe.record("factory")
                return InvestmentBenchmarkSession(send: { _, _ in
                    await probe.record("send"); throw failure
                }, close: { await probe.record("close") })
            })
            select(model)
            await (try #require(model.startSearch())).value
            let message = try #require(model.message)
            #expect(message.contains("[AI-BENCHMARK-" + code + "]"))
            #expect(message.contains("手动重试") && message.contains("API 费用"))
            #expect(!message.contains("AI-REQUEST-UNKNOWN"))
            #expect(model.result == nil && !model.isBusy)
            #expect(await probe.events == ["factory", "key", "send", "close"])
        }
    }
}
