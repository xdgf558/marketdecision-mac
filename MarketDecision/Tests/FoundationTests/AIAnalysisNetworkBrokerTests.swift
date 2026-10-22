import Foundation
import Testing
import AIInsights
@testable import AIAnalysisNetworkBroker

private func syntheticAIRequest() -> AIInsightRequest {
    AIInsightRequest(input: AIInsightInput(ticker: "DEMO", companyName: "合成公司",
        periodEnd: "2026-09-30", cutoff: "2026-10-22T00:00:00Z",
        metrics: [.init(id: "m-revenue", label: "营收", value: "100", unit: "USD",
                        unavailable: nil, sourceIDs: ["s-1"])],
        sources: [.init(id: "s-1", label: "合成财报")]))
}
private func syntheticAIEnvelope() throws -> AIAnalysisNetworkRequest {
    try AIAnalysisNetworkRequest(request: syntheticAIRequest(), apiKey: Data("synthetic-not-an-api-key".utf8))
}
private func callAIBroker(_ broker: AIAnalysisNetworkBrokerSession, data: Data) async -> (Data?, Int) {
    await withCheckedContinuation { continuation in
        broker.analyze(data) { continuation.resume(returning: ($0, $1)) }
    }
}
private final class AITransportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private actor AISuspendedTransport: AIAnalysisHTTPTransport {
    private let lateReply: AIAnalysisNetworkReply
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<AIAnalysisNetworkReply, Error>?
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    init() throws { lateReply = try AIAnalysisNetworkReply(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8)) }
    func send(_ request: AIAnalysisNetworkRequest) async throws -> AIAnalysisNetworkReply {
        try await withCheckedThrowingContinuation { continuation in
            started = true; pending = continuation
            let waiters = startWaiters; startWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func waitForClose() async {
        if closed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
    func close() {
        closed = true
        let original = pending; pending = nil
        // Ignore cancellation deliberately; the broker must discard this late success.
        original?.resume(returning: lateReply)
        let waiters = closeWaiters; closeWaiters = []
        waiters.forEach { $0.resume() }
    }
}
private actor AIImmediateTransport: AIAnalysisHTTPTransport {
    var closes = 0
    func send(_ request: AIAnalysisNetworkRequest) throws -> AIAnalysisNetworkReply {
        try AIAnalysisNetworkReply(statusCode: 429, mediaType: "application/json", body: Data("{}".utf8))
    }
    func close() { closes += 1 }
}
private final class AILateChannel: AIAnalysisNetworkChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Data, Error>?
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    func exchange(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); waiter = continuation; started = true
            let starts = starts; self.starts = []; lock.unlock()
            starts.forEach { $0.resume() }
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
    func release() {
        lock.lock(); let original = waiter; waiter = nil; lock.unlock()
        original?.resume(returning: Data())
    }
}

/// No actual socket is opened. Tests explicitly release each protocol stage; no timed
/// semaphore silently advances a response before the cancellation control runs.
private final class AIHTTPExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var loader: URLProtocol?
    private var started = false, stopped = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    func start(_ loader: URLProtocol) {
        lock.lock(); self.loader = loader; started = true
        let waiters = startWaiters; startWaiters = []; lock.unlock()
        waiters.forEach { $0.resume() }
    }
    func stop() {
        lock.lock(); stopped = true; loader = nil
        let waiters = stopWaiters; stopWaiters = []; lock.unlock()
        waiters.forEach { $0.resume() }
    }
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started { lock.unlock(); continuation.resume() }
            else { startWaiters.append(continuation); lock.unlock() }
        }
    }
    func waitForStop() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume() }
            else { stopWaiters.append(continuation); lock.unlock() }
        }
    }
    private func current() throws -> URLProtocol { try #require(lock.withLock { loader }) }
    func response(status: Int = 200, length: String? = nil, url: String? = nil) throws {
        let loader = try current()
        var headers = ["Content-Type": "application/json"]
        if let length { headers["Content-Length"] = length }
        let target = try #require(url.flatMap(URL.init(string:)) ?? loader.request.url)
        let response = try #require(HTTPURLResponse(url: target, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func chunk(_ data: Data) throws { let loader = try current(); loader.client?.urlProtocol(loader, didLoad: data) }
    func finish() throws { let loader = try current(); loader.client?.urlProtocolDidFinishLoading(loader) }
}
private final class AIHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var exchange: AIHTTPExchange?
    func install(_ exchange: AIHTTPExchange?) { lock.withLock { self.exchange = exchange } }
    func current() -> AIHTTPExchange? { lock.withLock { exchange } }
}
private final class AISyntheticURLProtocol: URLProtocol {
    static let registry = AIHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.registry.current()?.start(self) }
    override func stopLoading() { Self.registry.current()?.stop() }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AIAnalysisNetworkBrokerTests {
    @Test func descriptorBuildsOnlyFixedPostAndKeepsKeyOutsideBody() throws {
        let original = try syntheticAIEnvelope()
        let decoded = try AIAnalysisNetworkRequest.decode(original.encoded())
        let request = try decoded.makeURLRequest()
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST" && request.timeoutInterval == 60)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData && !request.httpShouldHandleCookies)
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) == ["authorization", "content-type", "accept"])
        #expect(request.httpBody == (try syntheticAIRequest().encodedBody()))
        #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains("synthetic-not-an-api-key"))
    }
    @Test func unknownFieldsCredentialInjectionOversizeAndDeepJSONAreRejected() throws {
        let encoded = try syntheticAIEnvelope().encoded()
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for name in ["url", "headers", "tools", "body"] {
            var changed = root; changed[name] = "forbidden"
            #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(JSONSerialization.data(withJSONObject: changed)) }
        }
        var inner = try #require(root["request"] as? [String: Any]); inner["tools"] = ["web_search"]
        var changed = root; changed["request"] = inner
        #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(JSONSerialization.data(withJSONObject: changed)) }
        for key in ["short", "synthetic\r\nHeader: injected", String(repeating: "x", count: 1_025)] {
            #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest(request: syntheticAIRequest(), apiKey: Data(key.utf8)) }
        }
        #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(Data(repeating: 32, count: 256 * 1_024 + 1)) }
        #expect(throws: (any Error).self) { try AIAnalysisNetworkRequest.decode(Data((String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30)).utf8)) }
    }
    @Test func invalidDescriptorCreatesNoTransportAndMissingHelperFailsClosed() async {
        let count = AITransportCounter()
        let broker = AIAnalysisNetworkBrokerSession(factory: { count.increment(); return AIImmediateTransport() })
        let reply = await callAIBroker(broker, data: Data("{}".utf8))
        #expect(reply.0 == nil && reply.1 == AIAnalysisReplyCode.invalidRequest.rawValue && count.count == 0)
        #expect(!AIAnalysisServiceAvailability.isAvailable)
        #expect(throws: AIAnalysisNetworkError.closed) { try AIAnalysisXPCClient() }
        broker.close()
    }
    @Test func oneExplicitConnectionCannotRetryPaidRequest() async throws {
        let count = AITransportCounter(), transport = AIImmediateTransport()
        let broker = AIAnalysisNetworkBrokerSession(factory: { count.increment(); return transport })
        let bytes = try syntheticAIEnvelope().encoded()
        let first = await callAIBroker(broker, data: bytes)
        #expect(first.1 == 0 && first.0 != nil)
        #expect(try AIAnalysisNetworkReply.decode(#require(first.0)).statusCode == 429)
        #expect(await transport.closes == 1)
        let second = await callAIBroker(broker, data: bytes)
        #expect(second.0 == nil && second.1 == AIAnalysisReplyCode.limitExceeded.rawValue && count.count == 1)
        broker.close()
    }
    @Test func brokerCloseRejectsConcurrentRequestAndLateSuccess() async throws {
        let transport = try AISuspendedTransport()
        let broker = AIAnalysisNetworkBrokerSession(factory: { transport })
        let bytes = try syntheticAIEnvelope().encoded()
        let pending = Task { await callAIBroker(broker, data: bytes) }
        await transport.waitForStart()
        let second = await callAIBroker(broker, data: bytes)
        #expect(second.1 == AIAnalysisReplyCode.busy.rawValue)
        broker.close(); broker.close()
        let result = await pending.value
        #expect(result.0 == nil && result.1 == AIAnalysisReplyCode.closed.rawValue)
        await transport.waitForClose()
    }
    @Test func clientCancellationAndExplicitCloseDropLateResponses() async throws {
        for cancel in [true, false] {
            let channel = AILateChannel()
            let observed = AIAnalysisXPCClient(channel: channel)
            let operation = Task { try await observed.analyze(syntheticAIRequest(), apiKey: Data("synthetic-not-an-api-key".utf8)) }
            await channel.waitForStart()
            if cancel { operation.cancel() } else { await observed.close() }
            #expect(channel.isClosed)
            channel.release()
            await #expect(throws: (any Error).self) { try await operation.value }
            await #expect(throws: AIAnalysisNetworkError.closed) {
                try await observed.analyze(syntheticAIRequest(), apiKey: Data("synthetic-not-an-api-key".utf8))
            }
        }
    }
    @Test func responseStatusAndBytesNeverExposeRemoteErrorsAsSuccess() throws {
        for (status, expected) in [(401, AIAnalysisNetworkError.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .unavailable)] {
            let reply = try AIAnalysisNetworkReply(statusCode: status, mediaType: "application/json", body: Data("remote secret text".utf8))
            #expect(throws: expected) { try reply.checkedBody() }
        }
        #expect(throws: AIAnalysisNetworkError.invalidResponse) {
            try AIAnalysisNetworkReply(statusCode: 302, mediaType: nil, body: Data())
        }
        #expect(throws: AIAnalysisNetworkError.invalidResponse) {
            try AIAnalysisNetworkReply(statusCode: 200, mediaType: "text/html", body: Data()).checkedBody()
        }
        #expect(throws: AIAnalysisNetworkError.invalidResponse) {
            try AIAnalysisNetworkReply(statusCode: 200, mediaType: "application/json", body: Data(repeating: 0, count: AIInsightLimits.responseBytes + 1))
        }
    }
    @Test func transportCloseCancelsInflightAndAliasesShareClosedState() async throws {
        let exchange = AIHTTPExchange(); AISyntheticURLProtocol.registry.install(exchange)
        defer { AISyntheticURLProtocol.registry.install(nil) }
        let transport = try AIAnalysisURLSessionTransport(protocolClasses: [AISyntheticURLProtocol.self])
        let alias = transport, request = try syntheticAIEnvelope()
        let pending = Task { try await transport.send(request) }
        await exchange.waitForStart(); await alias.close()
        await #expect(throws: AIAnalysisNetworkError.closed) { try await pending.value }
        await exchange.waitForStop()
        await #expect(throws: AIAnalysisNetworkError.closed) { try await transport.send(request) }
    }
    @Test func streamedByteLimitRejectsBeforeFullBodyAndRedirectCannotSucceed() async throws {
        for redirect in [false, true] {
            let exchange = AIHTTPExchange(); AISyntheticURLProtocol.registry.install(exchange)
            defer { AISyntheticURLProtocol.registry.install(nil) }
            let transport = try AIAnalysisURLSessionTransport(protocolClasses: [AISyntheticURLProtocol.self], maximumBytes: 12)
            let request = try syntheticAIEnvelope(), pending = Task { try await transport.send(request) }
            await exchange.waitForStart()
            if redirect {
                try exchange.response(status: 302)
                await #expect(throws: AIAnalysisNetworkError.redirectedResponse) { try await pending.value }
            } else {
                try exchange.response(length: "1")
                try exchange.chunk(Data(repeating: 65, count: 8)); try exchange.chunk(Data(repeating: 66, count: 8))
                await #expect(throws: AIAnalysisNetworkError.responseTooLarge) { try await pending.value }
            }
            await exchange.waitForStop(); await transport.close()
        }
    }
    @Test func syntheticPostAtExactLimitReturnsOnlyBodyAndStatus() async throws {
        let exchange = AIHTTPExchange(); AISyntheticURLProtocol.registry.install(exchange)
        defer { AISyntheticURLProtocol.registry.install(nil) }
        let transport = try AIAnalysisURLSessionTransport(protocolClasses: [AISyntheticURLProtocol.self], maximumBytes: 12)
        let request = try syntheticAIEnvelope(), pending = Task { try await transport.send(request) }
        await exchange.waitForStart(); try exchange.response(status: 429)
        try exchange.chunk(Data(repeating: 65, count: 12)); try exchange.finish()
        let result = try await pending.value
        #expect(result.statusCode == 429 && result.body.count == 12 && result.mediaType == "application/json")
        await transport.close()
    }
}
