import Foundation
import Testing
import AIInsights
@testable import AIAnalysisNetworkBroker

private func benchmarkNetworkRequest() -> AIBenchmarkRequest {
    AIBenchmarkRequest(start: Date(timeIntervalSince1970: 1_761_336_000),
                       end: Date(timeIntervalSince1970: 1_792_872_000), model: "synthetic-model")
}

private let benchmarkNetworkKey = Data("synthetic-not-an-api-key".utf8)

private func benchmarkFinancialRequest() -> AIInsightRequest {
    AIInsightRequest(input: AIInsightInput(ticker: "DEMO", companyName: "合成公司",
        periodEnd: "2026-09-30", cutoff: "2026-10-22T00:00:00Z",
        metrics: [.init(id: "m-revenue", label: "营收", value: "100", unit: "USD",
                        unavailable: nil, sourceIDs: ["s-1"])],
        sources: [.init(id: "s-1", label: "合成财报")]))
}

private actor BenchmarkImmediateTransport: AIAnalysisHTTPTransport {
    private(set) var sends = 0
    private(set) var closes = 0
    func send(_ request: AIAnalysisNetworkRequest) throws -> AIAnalysisNetworkReply {
        sends += 1
        return try .init(statusCode: 429, mediaType: "application/json", body: Data("{}".utf8))
    }
    func close() { closes += 1 }
}

private func benchmarkBrokerCall(_ broker: AIAnalysisNetworkBrokerSession, bytes: Data) async -> (Data?, Int) {
    await withCheckedContinuation { continuation in
        broker.analyze(bytes) { continuation.resume(returning: ($0, $1)) }
    }
}

/// A deterministic handshake keeps the first call in flight until the test
/// explicitly cancels/closes and releases it. No network or timeout advances it.
private final class BenchmarkSuspendedChannel: AIAnalysisNetworkChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, Error>?
    private var started = false
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var exchanges = 0
    var isClosed: Bool { lock.withLock { closed } }
    var exchangeCount: Int { lock.withLock { exchanges } }
    func exchange(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending = continuation; started = true; exchanges += 1
            let waiters = starts; starts = []; lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started { lock.unlock(); continuation.resume() }
            else { starts.append(continuation); lock.unlock() }
        }
    }
    func close() { lock.withLock { closed = true } }
    func releaseLateReply() {
        lock.lock(); let continuation = pending; pending = nil; lock.unlock()
        continuation?.resume(returning: Data())
    }
}

private final class BenchmarkImmediateChannel: AIAnalysisNetworkChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: Data
    private var closed = false
    private var exchanges = 0
    var isClosed: Bool { lock.withLock { closed } }
    var exchangeCount: Int { lock.withLock { exchanges } }
    init(reply: Data) { self.reply = reply }
    func exchange(_ request: Data) async throws -> Data {
        lock.withLock { exchanges += 1 }
        return reply
    }
    func close() { lock.withLock { closed = true } }
}

@Suite(.timeLimit(.minutes(1))) struct AIBenchmarkNetworkTests {
    @Test func benchmarkDescriptorKeepsFixedHostToolAndKeyBoundary() throws {
        let request = benchmarkNetworkRequest()
        let bytes = try AIAnalysisNetworkRequest(benchmarkRequest: request, apiKey: benchmarkNetworkKey).encoded()
        let wire = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(wire.keys) == ["benchmarkRequest", "apiKey"])
        let decoded = try AIAnalysisNetworkRequest.decode(bytes)
        #expect(decoded.request == nil && decoded.benchmarkRequest == request)
        let http = try decoded.makeURLRequest()
        #expect(http.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(http.httpMethod == "POST" && http.timeoutInterval == 300)
        #expect(http.cachePolicy == .reloadIgnoringLocalCacheData && !http.httpShouldHandleCookies)
        #expect(Set((http.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) == ["authorization", "content-type", "accept"])
        let body = try #require(http.httpBody)
        #expect(body == (try request.encodedBody()))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["type"] as? String == "web_search")
        #expect(object["store"] as? Bool == false && object["stream"] as? Bool == false)
        #expect(!String(decoding: body, as: UTF8.self).contains(String(decoding: benchmarkNetworkKey, as: UTF8.self)))
    }

    @Test func solBenchmarkDescriptorRebuildsMaxAtTheFixedEndpoint() throws {
        let original = benchmarkNetworkRequest()
        let request = AIBenchmarkRequest(start: original.start, end: original.end,
            model: AIInsightRequest.defaultModel)
        let envelope = try AIAnalysisNetworkRequest(benchmarkRequest: request, apiKey: benchmarkNetworkKey)
        let decoded = try AIAnalysisNetworkRequest.decode(envelope.encoded())
        let http = try decoded.makeURLRequest()
        let bodyData = try #require(http.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(http.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(http.httpMethod == "POST" && http.timeoutInterval == 300)
        #expect(body["model"] as? String == "gpt-6.1-sol")
        #expect(body["reasoning"] as? [String: String] == ["effort": "max"])
        #expect(body["max_output_tokens"] as? Int == 25_000 && body["max_tool_calls"] as? Int == 3)
        #expect((body["tools"] as? [[String: String]]) == [["type": "web_search"]])
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == false)
        #expect(http.httpBody == (try request.encodedBody()))
        #expect(!String(decoding: try #require(http.httpBody), as: UTF8.self)
            .contains(String(decoding: benchmarkNetworkKey, as: UTF8.self)))
    }

    @Test func financialDescriptorRetainsOriginalWireAndToolFreeBody() throws {
        let request = benchmarkFinancialRequest()
        let bytes = try AIAnalysisNetworkRequest(request: request, apiKey: benchmarkNetworkKey).encoded()
        let wire = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(wire.keys) == ["request", "apiKey"])
        let decoded = try AIAnalysisNetworkRequest.decode(bytes)
        #expect(decoded.request == request && decoded.benchmarkRequest == nil)
        let body = try #require(decoded.makeURLRequest().httpBody)
        #expect(body == (try request.encodedBody()))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["tools"] == nil && object["tool_choice"] == nil)
    }

    @Test func mixedMissingNullAndInjectedDescriptorsAreRejected() throws {
        let benchmark = try AIAnalysisNetworkRequest(benchmarkRequest: benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey)
        let original = try #require(JSONSerialization.jsonObject(with: benchmark.encoded()) as? [String: Any])
        let financial = try #require(JSONSerialization.jsonObject(with: AIAnalysisNetworkRequest(
            request: benchmarkFinancialRequest(), apiKey: benchmarkNetworkKey).encoded()) as? [String: Any])
        var mixed = original; mixed["request"] = financial["request"]
        var missing = original; missing.removeValue(forKey: "benchmarkRequest")
        var null = original; null["benchmarkRequest"] = NSNull()
        for invalid in [mixed, missing, null] {
            #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(JSONSerialization.data(withJSONObject: invalid)) }
        }
        for field in ["url", "headers", "body", "tools", "prompt", "instructions"] {
            var invalid = original; invalid[field] = "forbidden"
            #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(JSONSerialization.data(withJSONObject: invalid)) }
            var inner = try #require(original["benchmarkRequest"] as? [String: Any])
            inner[field] = "forbidden"; invalid = original; invalid["benchmarkRequest"] = inner
            #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(JSONSerialization.data(withJSONObject: invalid)) }
        }
    }

    @Test func benchmarkDescriptorRetainsCredentialAndByteLimits() throws {
        for key in ["short", "synthetic\r\nHeader: injected", String(repeating: "x", count: 1_025)] {
            #expect(throws: (any Error).self) {
                try AIAnalysisNetworkRequest(benchmarkRequest: benchmarkNetworkRequest(), apiKey: Data(key.utf8))
            }
        }
        #expect(throws: (any Error).self) {
            try AIAnalysisNetworkRequest.decode(Data(repeating: 32, count: AIAnalysisNetworkRequest.maximumEncodedBytes + 1))
        }
    }

    @Test func brokerCannotSendBenchmarkThenFinancialOnOneConnection() async throws {
        let transport = BenchmarkImmediateTransport()
        let broker = AIAnalysisNetworkBrokerSession(factory: { transport })
        let benchmark = try AIAnalysisNetworkRequest(benchmarkRequest: benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey).encoded()
        let first = await benchmarkBrokerCall(broker, bytes: benchmark)
        #expect(first.1 == AIAnalysisReplyCode.success.rawValue)
        #expect(try AIAnalysisNetworkReply.decode(#require(first.0)).statusCode == 429)
        let financial = try AIAnalysisNetworkRequest(request: benchmarkFinancialRequest(), apiKey: benchmarkNetworkKey).encoded()
        let second = await benchmarkBrokerCall(broker, bytes: financial)
        #expect(second.0 == nil && second.1 == AIAnalysisReplyCode.limitExceeded.rawValue)
        #expect(await transport.sends == 1)
        #expect(await transport.closes == 1)
        broker.close()
    }

    @Test func benchmarkClientCancellationDiscardsLateReplyAndPreventsAnotherPurpose() async throws {
        let channel = BenchmarkSuspendedChannel()
        let client = AIAnalysisXPCClient(channel: channel)
        let work = Task { try await client.searchBenchmark(benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey) }
        await channel.waitForStart()
        await #expect(throws: AIAnalysisNetworkError.limitExceeded) {
            try await client.analyze(benchmarkFinancialRequest(), apiKey: benchmarkNetworkKey)
        }
        work.cancel()
        channel.releaseLateReply()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(channel.isClosed && channel.exchangeCount == 1)
        await #expect(throws: AIAnalysisNetworkError.closed) {
            try await client.searchBenchmark(benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey)
        }
    }

    @Test func benchmarkClientHTTPFailureClosesWithoutRetry() async throws {
        let reply = try AIAnalysisNetworkReply(statusCode: 401, mediaType: "application/json", body: Data("{}".utf8)).encoded()
        let channel = BenchmarkImmediateChannel(reply: reply)
        let client = AIAnalysisXPCClient(channel: channel)
        await #expect(throws: AIAnalysisAPIFailure(statusCode: 401, reason: .authentication)) {
            try await client.searchBenchmark(benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey)
        }
        #expect(channel.isClosed && channel.exchangeCount == 1)
        await #expect(throws: AIAnalysisNetworkError.closed) {
            try await client.searchBenchmark(benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey)
        }
    }

    @Test func benchmarkClientExplicitCloseRejectsPendingAndLaterCalls() async throws {
        let channel = BenchmarkSuspendedChannel()
        let client = AIAnalysisXPCClient(channel: channel)
        let work = Task { try await client.searchBenchmark(benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey) }
        await channel.waitForStart()
        await client.close()
        channel.releaseLateReply()
        await #expect(throws: AIAnalysisNetworkError.closed) { try await work.value }
        await #expect(throws: AIAnalysisNetworkError.closed) {
            try await client.analyze(benchmarkFinancialRequest(), apiKey: benchmarkNetworkKey)
        }
        #expect(channel.isClosed && channel.exchangeCount == 1)
    }

    @Test func benchmarkClientRetainsEncodedReplyBudget() async throws {
        let channel = BenchmarkImmediateChannel(reply: Data(repeating: 32, count: AIAnalysisNetworkReply.maximumEncodedBytes + 1))
        let client = AIAnalysisXPCClient(channel: channel)
        await #expect(throws: AIAnalysisNetworkError.invalidResponse) {
            try await client.searchBenchmark(benchmarkNetworkRequest(), apiKey: benchmarkNetworkKey)
        }
        #expect(channel.isClosed && channel.exchangeCount == 1)
    }
}
