import Foundation
import Testing
import DataContracts
import DataProviders
import MarketDataProviders
@testable import EquityNetworkBroker

private func equityBrokerRequest(_ url: String = "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD") throws -> URLRequest {
    var request = URLRequest(url: try #require(URL(string: url)))
    request.httpMethod = "GET"
    request.setValue("synthetic_key", forHTTPHeaderField: "APCA-API-KEY-ID")
    request.setValue("synthetic_secret", forHTTPHeaderField: "APCA-API-SECRET-KEY")
    request.setValue(EquityDownloadRequest.accept, forHTTPHeaderField: "Accept")
    return request
}

private func equityBarsRequest(token: String? = nil) throws -> URLRequest {
    var parts = URLComponents()
    parts.scheme = "https"; parts.host = "data.alpaca.markets"; parts.path = "/v2/stocks/BRK.B/bars"
    parts.queryItems = [.init(name: "timeframe", value: "1Day"), .init(name: "adjustment", value: "raw"),
                       .init(name: "asof", value: "-"), .init(name: "sort", value: "asc"),
                       .init(name: "limit", value: "1000"), .init(name: "start", value: "2025-01-01T00:00:00.000Z"),
                       .init(name: "end", value: "2025-02-01T00:00:00.000Z")]
    if let token { parts.queryItems?.append(.init(name: "page_token", value: token)) }
    parts.queryItems? += [.init(name: "feed", value: "iex"), .init(name: "currency", value: "USD")]
    return try equityBrokerRequest(#require(parts.url).absoluteString)
}

private func equityBrokerFetch(_ broker: EquityNetworkBrokerSession, _ data: Data) async -> (Data?, Int) {
    await withCheckedContinuation { continuation in
        broker.fetch(data) { continuation.resume(returning: ($0, $1)) }
    }
}

private final class EquityBrokerCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFactories = 0
    func make() { lock.lock(); storedFactories += 1; lock.unlock() }
    var factories: Int { lock.lock(); defer { lock.unlock() }; return storedFactories }
}

private actor ImmediateEquityBrokerTransport: HTTPTransport {
    var calls = 0
    var closes = 0
    var received: URLRequest?
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        calls += 1; received = request
        return HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8))
    }
    func close() { closes += 1 }
}

private actor SuspendedEquityBrokerTransport: HTTPTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<HTTPPayload, Error>?
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    var calls = 0
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            response = continuation; started = true
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
        let original = response; response = nil
        // This transport ignores cancellation and returns a late success when closed.
        original?.resume(returning: HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8)))
        let waiters = closeWaiters; closeWaiters = []
        waiters.forEach { $0.resume() }
    }
}

private final class EquityTestChannel: EquityNetworkChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var storedCalls = 0
    private var closed = false
    private let response: Data
    init() throws {
        response = try EquityDownloadReply(HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8))).encoded()
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return storedCalls }
    func exchange(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: HTTPTransportPolicyError.closed); return }
            storedCalls += 1; pending = continuation
            let waiters = startWaiters; startWaiters = []
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if storedCalls > 0 { lock.unlock(); continuation.resume(); return }
            startWaiters.append(continuation); lock.unlock()
        }
    }
    func close() {
        lock.lock()
        closed = true
        let original = pending; pending = nil
        lock.unlock()
        original?.resume(returning: response)
    }
}

private actor EquityProviderPolicyLoopback: HTTPTransport {
    var captured: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        let rebuilt = try EquityDownloadRequest.decode(EquityDownloadRequest(request).encoded()).makeURLRequest()
        captured.append(rebuilt)
        let json = rebuilt.url?.path.hasSuffix("/bars") == true
            ? #"{"symbol":"MSFT","bars":null,"next_page_token":null}"#
            : #"{"symbol":"MSFT","quote":null}"#
        return HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data(json.utf8))
    }
}

@Suite struct EquityNetworkBrokerTests {
    @Test func existingProviderRequestsCrossClosedPolicyWithoutCredentialsInReturnedSource() async throws {
        let loopback = EquityProviderPolicyLoopback()
        for capability in [ProviderCapability.quote, .bars] {
            let provider = try AlpacaIEXProvider(apiKey: Data("synthetic_key".utf8), secret: Data("synthetic_secret".utf8),
                evidenceRef: "synthetic-evidence", licenseRef: "synthetic-license", transport: loopback)
            let range = DateRange(start: Date(timeIntervalSince1970: 1_735_689_600), end: Date(timeIntervalSince1970: 1_738_368_000))
            let request = ProviderRequest(providerID: "alpaca", feedID: "iex", resourceID: "MSFT", capability: capability,
                mode: .latest, range: capability == .bars ? .sourceEvents(range) : nil, usage: .liveAnalysis,
                configurationVersion: AlpacaIEXProvider.configurationVersion, entitlementVersion: "synthetic-rights.v1",
                requestedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                pageToken: capability == .bars ? "next+/=" : nil)
            let response = try await (capability == .quote ? provider.quote(request: request) : provider.dailyBars(request: request))
            #expect(!response.rawPayload.bytes.contains(Data("synthetic_secret".utf8)))
        }
        #expect(await loopback.captured.count == 2)
    }

    @Test func closedDescriptorsRoundTripOnlyIEXQuoteAndRawDailyBars() throws {
        for request in [try equityBrokerRequest(), try equityBarsRequest(), try equityBarsRequest(token: "opaque+/=?&percent%token")] {
            let encoded = try EquityDownloadRequest(request).encoded()
            let rebuilt = try EquityDownloadRequest.decode(encoded).makeURLRequest()
            #expect(rebuilt.url == request.url)
            #expect(rebuilt.httpMethod == "GET")
            #expect(rebuilt.allHTTPHeaderFields == request.allHTTPHeaderFields)
            #expect(rebuilt.timeoutInterval == 10)
            #expect(rebuilt.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(!rebuilt.httpShouldHandleCookies)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("https"))
        }
    }

    @Test func arbitraryOriginTradingSIPQueryAndHeadersAreRejected() throws {
        let denied = [
            "http://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD",
            "https://data.alpaca.markets.attacker.invalid/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD",
            "https://paper-api.alpaca.markets/v2/orders?feed=iex&currency=USD",
            "https://data.alpaca.markets:443/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD",
            "https://user:password@data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD#fragment",
            "https://data.alpaca.markets/v2/stocks/%4DSFT/quotes/latest?feed=iex&currency=USD",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=sip&currency=USD",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&feed=sip&currency=USD",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&currency=EUR",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex&currency=USD&token=extra",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest?feed=iex",
            "https://data.alpaca.markets/v2/stocks/MSFT/quotes/latest/?feed=iex&currency=USD",
            "https://data.alpaca.markets/v2/stocks/MSFT/trades/latest?feed=iex&currency=USD",
            "https://data.alpaca.markets/v2/stocks/../quotes/latest?feed=iex&currency=USD",
            "https://data.alpaca.markets/v2/stocks/msft/quotes/latest?feed=iex&currency=USD"
        ]
        for value in denied {
            let request = try equityBrokerRequest(value)
            #expect(throws: (any Error).self) { try EquityDownloadRequest(request) }
        }
        for header in ["Cookie", "Authorization", "Proxy-Authorization", "Host", "User-Agent"] {
            var request = try equityBrokerRequest(); request.setValue("synthetic", forHTTPHeaderField: header)
            #expect(throws: (any Error).self) { try EquityDownloadRequest(request) }
        }
        var post = try equityBrokerRequest(); post.httpMethod = "POST"
        #expect(throws: (any Error).self) { try EquityDownloadRequest(post) }
        var body = try equityBrokerRequest(); body.httpBody = Data("synthetic".utf8)
        #expect(throws: (any Error).self) { try EquityDownloadRequest(body) }
    }

    @Test func dailyRangeAdjustmentTokensAndCredentialGrammarAreBounded() throws {
        let request = try equityBarsRequest()
        for (name, value) in [("timeframe", "1Min"), ("adjustment", "all"), ("asof", "2025-01-01"),
                              ("sort", "desc"), ("limit", "10000"), ("start", "2023-01-01T00:00:00.000Z"),
                              ("start", "2025-02-02T00:00:00.000Z"), ("end", "2099-01-01T00:00:00.000Z"),
                              ("start", "2025-01-01T00:00:00Z")] {
            let originalURL = try #require(request.url)
            var components = try #require(URLComponents(url: originalURL, resolvingAgainstBaseURL: false))
            components.queryItems = components.queryItems?.map { $0.name == name ? .init(name: name, value: value) : $0 }
            let invalid = try equityBrokerRequest(#require(components.url).absoluteString)
            #expect(throws: (any Error).self) { try EquityDownloadRequest(invalid) }
        }
        for token in ["", "contains space", "line\nbreak", String(repeating: "x", count: 2_049)] {
            let invalid = try equityBarsRequest(token: token)
            #expect(throws: (any Error).self) { try EquityDownloadRequest(invalid) }
        }
        for value in ["abc", "contains space", "非ASCII", String(repeating: "a", count: 257)] {
            for header in ["APCA-API-KEY-ID", "APCA-API-SECRET-KEY"] {
                var invalid = try equityBrokerRequest(); invalid.setValue(value, forHTTPHeaderField: header)
                #expect(throws: (any Error).self) { try EquityDownloadRequest(invalid) }
            }
        }
    }

    @Test func decodedDescriptorCannotSupplyURLHeadersOrIrrelevantFields() throws {
        let original = try EquityDownloadRequest(equityBrokerRequest()).encoded()
        let fields = try #require(JSONSerialization.jsonObject(with: original) as? [String: String])
        for (key, value) in [("route", "orders"), ("symbol", "../orders"), ("secret", "bad\r\nHeader: x"),
                             ("url", "https://example.invalid"), ("headers", "arbitrary"), ("start", "2025-01-01T00:00:00.000Z")] {
            var invalid = fields; invalid[key] = value
            let bytes = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: (any Error).self) { try EquityDownloadRequest.decode(bytes) }
        }
        #expect(throws: (any Error).self) {
            try EquityDownloadRequest.decode(Data(repeating: 32, count: EquityDownloadRequest.maximumEncodedBytes + 1))
        }
    }

    @Test func repliesRetainOnlyBoundedRetryMetadataAndEnforceBodyLimit() throws {
        let response = HTTPPayload(statusCode: 429, mediaType: "application/json",
            headers: ["Set-Cookie": "synthetic", "Authorization": "synthetic", "Retry-After": "3", "X-RateLimit-Reset": "1740000000"],
            body: Data("{}".utf8))
        let copy = try EquityDownloadReply.decode(EquityDownloadReply(response).encoded()).payload()
        #expect(copy.body == response.body)
        #expect(copy.headers == ["Retry-After": "3", "X-RateLimit-Reset": "1740000000"])
        #expect(throws: (any Error).self) {
            try EquityDownloadReply(HTTPPayload(statusCode: 200, mediaType: nil,
                body: Data(repeating: 0, count: EquityDownloadReply.maximumBodyBytes + 1)))
        }
        for headers in [["Retry-After": "3\nheader"], ["X-RateLimit-Reset": String(repeating: "1", count: 129)]] {
            #expect(throws: (any Error).self) {
                try EquityDownloadReply(HTTPPayload(statusCode: 429, mediaType: nil, headers: headers, body: Data()))
            }
        }
        #expect(throws: (any Error).self) {
            try EquityDownloadReply(HTTPPayload(statusCode: 302, mediaType: nil, body: Data()))
        }
        #expect(throws: (any Error).self) {
            try EquityDownloadReply(HTTPPayload(statusCode: 200, mediaType: "application/json\r\ninvalid", body: Data()))
        }
        #expect(throws: (any Error).self) {
            try EquityDownloadReply.decode(Data(repeating: 0, count: EquityDownloadReply.maximumEncodedBytes + 1))
        }
    }

    @Test func invalidAndClosedCallsCreateNoTransport() async throws {
        let counts = EquityBrokerCounts(), transport = ImmediateEquityBrokerTransport()
        let broker = EquityNetworkBrokerSession(factory: { counts.make(); return (transport, { await transport.close() }) })
        let invalid = await equityBrokerFetch(broker, Data("invalid".utf8))
        #expect(invalid.0 == nil)
        #expect(invalid.1 == EquityNetworkReplyCode.invalidRequest.rawValue)
        broker.close()
        let closed = await equityBrokerFetch(broker, try EquityDownloadRequest(equityBrokerRequest()).encoded())
        #expect(closed.0 == nil)
        #expect(closed.1 == EquityNetworkReplyCode.closed.rawValue)
        #expect(counts.factories == 0)
        #expect(await transport.calls == 0)
    }

    @Test func connectionLimitsSequentialRequestsAndReconstructsSafeRequest() async throws {
        let counts = EquityBrokerCounts(), transport = ImmediateEquityBrokerTransport()
        let broker = EquityNetworkBrokerSession(factory: { counts.make(); return (transport, { await transport.close() }) })
        let data = try EquityDownloadRequest(equityBarsRequest()).encoded()
        for _ in 0..<40 {
            let result = await equityBrokerFetch(broker, data)
            #expect(result.1 == EquityNetworkReplyCode.success.rawValue)
        }
        let rejected = await equityBrokerFetch(broker, data)
        #expect(rejected.0 == nil)
        #expect(rejected.1 == EquityNetworkReplyCode.limitExceeded.rawValue)
        #expect(counts.factories == 1)
        #expect(await transport.calls == 40)
        let received = try #require(await transport.received)
        #expect(received.url?.host == "data.alpaca.markets")
        #expect(!received.httpShouldHandleCookies)
        broker.close()
    }

    @Test func busyAndConnectionInvalidationCannotPublishLateTransportSuccess() async throws {
        let transport = SuspendedEquityBrokerTransport()
        let broker = EquityNetworkBrokerSession(factory: { (transport, { await transport.close() }) })
        let data = try EquityDownloadRequest(equityBrokerRequest()).encoded()
        let running = Task { await equityBrokerFetch(broker, data) }
        await transport.waitForStart()
        let busy = await equityBrokerFetch(broker, data)
        #expect(busy.0 == nil)
        #expect(busy.1 == EquityNetworkReplyCode.busy.rawValue)
        broker.close(); broker.close()
        let result = await running.value
        #expect(result.0 == nil)
        #expect(result.1 == EquityNetworkReplyCode.closed.rawValue)
        await transport.waitForClose()
        #expect(await transport.calls == 1)
    }

    @Test func clientRejectsInvalidRequestsBeforeCrossingChannelAndClosedTransportCannotSend() async throws {
        let channel = try EquityTestChannel(), transport = EquityXPCTransport(channel: channel)
        var request = try equityBrokerRequest(); request.setValue("synthetic", forHTTPHeaderField: "Cookie")
        await #expect(throws: (any Error).self) { try await transport.send(request) }
        #expect(channel.calls == 0)
        await transport.close()
        await #expect(throws: HTTPTransportPolicyError.closed) { try await transport.send(equityBrokerRequest()) }
        #expect(channel.calls == 0)
        #expect(!EquityNetworkServiceAvailability.isAvailable)
    }

    @Test func clientCancellationClosesChannelAndRejectsLateSuccess() async throws {
        let channel = try EquityTestChannel(), transport = EquityXPCTransport(channel: channel)
        let request = try equityBrokerRequest()
        let running = Task { try await transport.send(request) }
        await channel.waitForStart()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(channel.calls == 1)
        await transport.close()
    }
}
