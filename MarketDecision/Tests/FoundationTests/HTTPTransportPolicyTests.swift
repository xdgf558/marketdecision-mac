import Foundation
import Testing
@testable import DataProviders

/// URLProtocol emits only when the test releases each stage. No timeout silently advances
/// the response, so slow CI scheduling cannot turn a cancellation check into a full download.
private final class ScriptedHTTPExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var loader: URLProtocol?
    private var started = false
    private var stopped = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var chunks = 0

    func didStart(_ loader: URLProtocol) {
        lock.lock()
        self.loader = loader
        started = true
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func didStop() {
        lock.lock()
        stopped = true
        loader = nil
        let waiters = stopWaiters
        stopWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
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

    private func currentLoader() -> URLProtocol? {
        lock.lock(); defer { lock.unlock() }
        return loader
    }

    func response(status: Int = 200, headers: [String: String] = [:]) throws {
        let loader = try #require(currentLoader())
        let url = try #require(loader.request.url)
        // These synthetic SEC-style responses declare their MIME type. Without it CFNetwork
        // can hold a tiny unfinished response for MIME sniffing before notifying the delegate;
        // that would test sniffing/timeout behavior rather than the streaming rejection path.
        var fields = ["Content-Type": "application/json"]
        fields.merge(headers) { _, supplied in supplied }
        let response = try #require(HTTPURLResponse(url: url,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields))
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func chunk(_ data: Data) throws {
        let loader = try #require(currentLoader())
        lock.lock(); chunks += 1; lock.unlock()
        loader.client?.urlProtocol(loader, didLoad: data)
    }

    func finish() throws {
        let loader = try #require(currentLoader())
        loader.client?.urlProtocolDidFinishLoading(loader)
    }

    func emittedChunks() -> Int {
        lock.lock(); defer { lock.unlock() }
        return chunks
    }
}

private final class HTTPExchangeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [String: ScriptedHTTPExchange] = [:]
    func insert(_ exchange: ScriptedHTTPExchange, key: String) {
        lock.lock(); defer { lock.unlock() }
        exchanges[key] = exchange
    }
    func find(_ key: String?) -> ScriptedHTTPExchange? {
        lock.lock(); defer { lock.unlock() }
        return key.flatMap { exchanges[$0] }
    }
    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        exchanges.removeValue(forKey: key)
    }
}

private final class ScriptedHTTPSProtocol: URLProtocol {
    static let registry = HTTPExchangeRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registry.find(request.url?.lastPathComponent)?.didStart(self)
    }
    override func stopLoading() {
        Self.registry.find(request.url?.lastPathComponent)?.didStop()
    }
}

@Suite(.timeLimit(.minutes(1))) struct HTTPTransportPolicyTests {
    @Test func configurationRejectsWildcardHostsAndUnboundedResponses() throws {
        #expect(throws: HTTPTransportPolicyError.invalidConfiguration) {
            try URLSessionHTTPTransport(allowedHosts: [])
        }
        #expect(throws: HTTPTransportPolicyError.invalidConfiguration) {
            try URLSessionHTTPTransport(allowedHosts: ["*.sec.gov"])
        }
        #expect(throws: HTTPTransportPolicyError.invalidConfiguration) {
            try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"], maximumResponseBytes: 0)
        }
        #expect(throws: HTTPTransportPolicyError.invalidConfiguration) {
            try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"], timeout: .infinity)
        }
    }

    @Test func unsafeRequestsFailBeforeAnyNetworkCall() async throws {
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"])
        let urls = ["http://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json",
                    "https://other.example/api",
                    "https://user:password@data.sec.gov/api",
                    "https://data.sec.gov:8443/api",
                    "https://data.sec.gov/api#fragment"]
        for text in urls {
            let request = URLRequest(url: try #require(URL(string: text)))
            await #expect(throws: HTTPTransportPolicyError.forbiddenRequest) {
                try await transport.send(request)
            }
        }
        var post = URLRequest(url: try #require(URL(string: "https://data.sec.gov/api")))
        post.httpMethod = "POST"
        await #expect(throws: HTTPTransportPolicyError.forbiddenRequest) {
            try await transport.send(post)
        }
        await transport.close()
    }

    @Test func aliasesShareExplicitCloseAndInFlightRequestIsCancelled() async throws {
        let exchange = ScriptedHTTPExchange()
        let key = UUID().uuidString
        ScriptedHTTPSProtocol.registry.insert(exchange, key: key)
        defer { ScriptedHTTPSProtocol.registry.remove(key) }
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"],
            maximumResponseBytes: 1_024, timeout: 30, protocolClasses: [ScriptedHTTPSProtocol.self])
        let alias = transport
        let request = URLRequest(url: try #require(URL(string: "https://data.sec.gov/\(key)")))
        let pending = Task { try await transport.send(request) }
        await exchange.waitForStart()
        await alias.close()
        await #expect(throws: HTTPTransportPolicyError.closed) { try await pending.value }
        await #expect(throws: HTTPTransportPolicyError.closed) { try await transport.send(request) }
        await transport.close()
        await exchange.waitForStop()
    }

    @Test func actualChunksStopAtBoundEvenWithFalseContentLength() async throws {
        let exchange = ScriptedHTTPExchange()
        let key = UUID().uuidString
        ScriptedHTTPSProtocol.registry.insert(exchange, key: key)
        defer { ScriptedHTTPSProtocol.registry.remove(key) }
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"],
            maximumResponseBytes: 12, timeout: 30, protocolClasses: [ScriptedHTTPSProtocol.self])
        let request = URLRequest(url: try #require(URL(string: "https://data.sec.gov/\(key)")))
        let pending = Task { try await transport.send(request) }
        await exchange.waitForStart()
        try exchange.response(headers: ["Content-Length": "1"])
        try exchange.chunk(Data(repeating: 65, count: 8))
        try exchange.chunk(Data(repeating: 66, count: 8))
        // The server has not finished or delivered its remaining chunks. The transport must
        // reject and stop this exchange now, rather than checking a completed response body.
        await #expect(throws: HTTPTransportPolicyError.responseTooLarge) { try await pending.value }
        await exchange.waitForStop()
        #expect(exchange.emittedChunks() == 2)
        await transport.close()
    }

    @Test func advertisedOversizeIsRejectedBeforeBody() async throws {
        let exchange = ScriptedHTTPExchange()
        let key = UUID().uuidString
        ScriptedHTTPSProtocol.registry.insert(exchange, key: key)
        defer { ScriptedHTTPSProtocol.registry.remove(key) }
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"],
            maximumResponseBytes: 12, timeout: 30, protocolClasses: [ScriptedHTTPSProtocol.self])
        let request = URLRequest(url: try #require(URL(string: "https://data.sec.gov/\(key)")))
        let pending = Task { try await transport.send(request) }
        await exchange.waitForStart()
        try exchange.response(headers: ["Content-Length": "13"])
        await #expect(throws: HTTPTransportPolicyError.responseTooLarge) { try await pending.value }
        await exchange.waitForStop()
        #expect(exchange.emittedChunks() == 0)
        await transport.close()
    }

    @Test func callerCancellationStopsPartialBodyAndSessionRemainsReusable() async throws {
        let exchange = ScriptedHTTPExchange()
        let key = UUID().uuidString
        ScriptedHTTPSProtocol.registry.insert(exchange, key: key)
        defer { ScriptedHTTPSProtocol.registry.remove(key) }
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"],
            maximumResponseBytes: 12, timeout: 30, protocolClasses: [ScriptedHTTPSProtocol.self])
        let request = URLRequest(url: try #require(URL(string: "https://data.sec.gov/\(key)")))
        let pending = Task { try await transport.send(request) }
        await exchange.waitForStart()
        try exchange.response()
        try exchange.chunk(Data([1, 2]))
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await exchange.waitForStop()
        #expect(exchange.emittedChunks() == 1)

        let retry = ScriptedHTTPExchange()
        let retryKey = UUID().uuidString
        ScriptedHTTPSProtocol.registry.insert(retry, key: retryKey)
        defer { ScriptedHTTPSProtocol.registry.remove(retryKey) }
        let retryRequest = URLRequest(url: try #require(URL(string: "https://data.sec.gov/\(retryKey)")))
        let retryTask = Task { try await transport.send(retryRequest) }
        await retry.waitForStart()
        try retry.response(status: 503, headers: ["Retry-After": "30"])
        try retry.chunk(Data("retry".utf8))
        try retry.finish()
        let payload = try await retryTask.value
        #expect(payload.statusCode == 503)
        #expect(payload.header("retry-after") == "30")
        #expect(payload.body == Data("retry".utf8))
        await transport.close()
    }

    @Test func unknownLengthAtExactLimitAndNonSuccessStatusReachProvider() async throws {
        let exchange = ScriptedHTTPExchange()
        let key = UUID().uuidString
        ScriptedHTTPSProtocol.registry.insert(exchange, key: key)
        defer { ScriptedHTTPSProtocol.registry.remove(key) }
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"],
            maximumResponseBytes: 12, timeout: 30, protocolClasses: [ScriptedHTTPSProtocol.self])
        let request = URLRequest(url: try #require(URL(string: "https://data.sec.gov/\(key)")))
        let pending = Task { try await transport.send(request) }
        await exchange.waitForStart()
        try exchange.response(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "5"])
        try exchange.chunk(Data(repeating: 65, count: 5))
        try exchange.chunk(Data(repeating: 66, count: 7))
        try exchange.finish()
        let payload = try await pending.value
        #expect(payload.statusCode == 429)
        #expect(payload.mediaType == "application/json")
        #expect(payload.body == Data(repeating: 65, count: 5) + Data(repeating: 66, count: 7))
        #expect(payload.header("retry-after") == "5")
        await transport.close()
    }

    @Test func droppingAliasesReleasesRepeatedSessionOwners() async throws {
        for _ in 0..<5 {
            weak var released: URLSessionHTTPTransport?
            do {
                let owner = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"])
                let alias = owner
                released = owner
                #expect(alias === owner)
            }
            #expect(released == nil)
        }
    }
}
