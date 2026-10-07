import Foundation
import Testing
import DataProviders
@testable import SECNetworkBroker

private func brokerRequest(_ url: String = "https://www.sec.gov/files/company_tickers_exchange.json") throws -> URLRequest {
    var request = URLRequest(url: try #require(URL(string: url)))
    request.setValue("MarketDecision/0.1 fixture@example.invalid", forHTTPHeaderField: "User-Agent")
    request.setValue(SECDownloadRequest.accept, forHTTPHeaderField: "Accept")
    return request
}

private func brokerFetch(_ broker: SECNetworkBrokerSession, _ data: Data) async -> (Data?, Int) {
    await withCheckedContinuation { continuation in
        broker.fetch(data) { continuation.resume(returning: ($0, $1)) }
    }
}

private final class BrokerCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFactories = 0
    func make() { lock.lock(); storedFactories += 1; lock.unlock() }
    var factories: Int { lock.lock(); defer { lock.unlock() }; return storedFactories }
}

private actor ImmediateBrokerTransport: HTTPTransport {
    var calls = 0
    var closes = 0
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        calls += 1
        return HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8))
    }
    func close() { closes += 1 }
}

private actor SuspendedBrokerTransport: HTTPTransport {
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
        // A synthetic late transport success must never replace the broker's closed result.
        original?.resume(returning: HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8)))
        let waiters = closeWaiters; closeWaiters = []
        waiters.forEach { $0.resume() }
    }
}

@Suite struct SECNetworkBrokerTests {
    @Test func closedDescriptorsRoundTripOnlyExistingSECRoutes() throws {
        let urls = [
            "https://www.sec.gov/files/company_tickers_exchange.json",
            "https://data.sec.gov/submissions/CIK0000789019.json",
            "https://data.sec.gov/submissions/CIK0000789019-submissions-001.json",
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0000789019.json",
            "https://www.sec.gov/Archives/edgar/data/789019/000095017025100235/index.json",
            "https://www.sec.gov/Archives/edgar/data/789019/000095017025100235/msft-20250630.htm"
        ]
        for url in urls {
            let request = try brokerRequest(url)
            let encoded = try SECDownloadRequest(request).encoded()
            let rebuilt = try SECDownloadRequest.decode(encoded).makeURLRequest()
            #expect(rebuilt.url == request.url)
            #expect(rebuilt.httpMethod == "GET")
            #expect(rebuilt.allHTTPHeaderFields == request.allHTTPHeaderFields)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("https"))
        }
    }

    @Test func arbitraryOriginsCredentialsPathsAndHeadersAreRejected() throws {
        let denied = [
            "http://www.sec.gov/files/company_tickers_exchange.json",
            "https://example.invalid/files/company_tickers_exchange.json",
            "https://www.sec.gov.attacker.invalid/files/company_tickers_exchange.json",
            "https://user:password@www.sec.gov/files/company_tickers_exchange.json",
            "https://www.sec.gov:443/files/company_tickers_exchange.json",
            "https://www.sec.gov/files/company_tickers_exchange.json?secret=hidden",
            "https://www.sec.gov/files/company_tickers_exchange.json#fragment",
            "https://www.sec.gov/files/%63ompany_tickers_exchange.json",
            "https://www.sec.gov/arbitrary",
            "https://data.sec.gov/submissions/CIK0000789019-submissions-9999.json",
            "https://www.sec.gov/Archives/edgar/data/789019/000095017025100235/../private",
            "https://www.sec.gov/Archives/edgar/data/789019/000095017025100235/path/file.htm"
        ]
        for value in denied {
            let request = try brokerRequest(value)
            #expect(throws: (any Error).self) { try SECDownloadRequest(request) }
        }
        var withHeader = try brokerRequest()
        withHeader.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        #expect(throws: (any Error).self) { try SECDownloadRequest(withHeader) }
        var post = try brokerRequest(); post.httpMethod = "POST"
        #expect(throws: (any Error).self) { try SECDownloadRequest(post) }
        var body = try brokerRequest(); body.httpBody = Data("synthetic".utf8)
        #expect(throws: (any Error).self) { try SECDownloadRequest(body) }
    }

    @Test func decodedDescriptorCannotBypassRouteOrContactValidation() throws {
        let invalid: [[String: String]] = [
            ["route": "unrestricted", "resource": "https://example.invalid", "userAgent": "MarketDecision/0.1 fixture@example.invalid"],
            ["route": "identity", "resource": "extra", "userAgent": "MarketDecision/0.1 fixture@example.invalid"],
            ["route": "archive", "resource": "789019/000095017025100235/../../other", "userAgent": "MarketDecision/0.1 fixture@example.invalid"],
            ["route": "facts", "resource": "CIK0000789019.json", "userAgent": "MarketDecision/0.1 fixture@example.invalid\r\nAuthorization: secret"],
            ["route": "facts", "resource": "CIK0000789019.json", "userAgent": "OtherApp fixture@example.invalid"]
        ]
        for value in invalid {
            let bytes = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: (any Error).self) { try SECDownloadRequest.decode(bytes) }
        }
        #expect(throws: (any Error).self) {
            try SECDownloadRequest.decode(Data(repeating: 32, count: SECDownloadRequest.maximumEncodedBytes + 1))
        }
    }

    @Test func repliesDiscardHeadersAndEnforceBodyAndMetadataLimits() throws {
        let response = HTTPPayload(statusCode: 200, mediaType: "application/json",
            headers: ["Set-Cookie": "synthetic", "Authorization": "synthetic"], body: Data("{}".utf8))
        let copy = try SECDownloadReply.decode(SECDownloadReply(response).encoded()).payload()
        #expect(copy.body == response.body)
        #expect(copy.headers.isEmpty)
        #expect(throws: (any Error).self) {
            try SECDownloadReply(HTTPPayload(statusCode: 200, mediaType: nil,
                body: Data(repeating: 0, count: SECDownloadReply.maximumBodyBytes + 1)))
        }
        #expect(throws: (any Error).self) {
            try SECDownloadReply(HTTPPayload(statusCode: 200, mediaType: "text/html\ninvalid", body: Data()))
        }
        #expect(throws: (any Error).self) {
            try SECDownloadReply.decode(Data(repeating: 0, count: SECDownloadReply.maximumEncodedBytes + 1))
        }
    }

    @Test func invalidAndClosedCallsCreateNoTransport() async throws {
        let counts = BrokerCounts(), transport = ImmediateBrokerTransport()
        let broker = SECNetworkBrokerSession(factory: { counts.make(); return (transport, { await transport.close() }) })
        let invalid = await brokerFetch(broker, Data("invalid".utf8))
        #expect(invalid.0 == nil)
        #expect(invalid.1 == SECNetworkReplyCode.invalidRequest.rawValue)
        broker.close()
        let closed = await brokerFetch(broker, try SECDownloadRequest(brokerRequest()).encoded())
        #expect(closed.0 == nil)
        #expect(closed.1 == SECNetworkReplyCode.closed.rawValue)
        #expect(counts.factories == 0)
        #expect(await transport.calls == 0)
    }

    @Test func connectionLimitsSequentialPagesAndReusesOnlyItsOwnTransport() async throws {
        let counts = BrokerCounts(), transport = ImmediateBrokerTransport()
        let broker = SECNetworkBrokerSession(factory: { counts.make(); return (transport, { await transport.close() }) })
        let data = try SECDownloadRequest(brokerRequest()).encoded()
        for _ in 0..<40 {
            let result = await brokerFetch(broker, data)
            #expect(result.1 == SECNetworkReplyCode.success.rawValue)
        }
        let rejected = await brokerFetch(broker, data)
        #expect(rejected.0 == nil)
        #expect(rejected.1 == SECNetworkReplyCode.limitExceeded.rawValue)
        #expect(counts.factories == 1)
        #expect(await transport.calls == 40)
        broker.close()
    }

    @Test func busyAndConnectionInvalidationCannotPublishLateTransportSuccess() async throws {
        let transport = SuspendedBrokerTransport()
        let broker = SECNetworkBrokerSession(factory: { (transport, { await transport.close() }) })
        let data = try SECDownloadRequest(brokerRequest()).encoded()
        let running = Task { await brokerFetch(broker, data) }
        await transport.waitForStart()
        let busy = await brokerFetch(broker, data)
        #expect(busy.0 == nil)
        #expect(busy.1 == SECNetworkReplyCode.busy.rawValue)
        broker.close(); broker.close()
        let result = await running.value
        #expect(result.0 == nil)
        #expect(result.1 == SECNetworkReplyCode.closed.rawValue)
        await transport.waitForClose()
        #expect(await transport.calls == 1)
    }
}
