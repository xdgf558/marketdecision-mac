import Foundation
import Testing
import DataProviders
@testable import SECNetworkBroker

private final class BrokerChannelProbe: SECNetworkChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var closed = false
    var count: Int { lock.withLock { requests.count } }
    var isClosed: Bool { lock.withLock { closed } }
    func arrived() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requests.isEmpty { arrival = continuation; lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
    }
    func exchange(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !closed else { lock.unlock(); continuation.resume(throwing: HTTPTransportPolicyError.closed); return }
            requests.append(request); waiter = continuation
            let arrival = arrival; self.arrival = nil
            lock.unlock(); arrival?.resume()
        }
    }
    // Deliberately ignore cancellation until released, like a late IPC callback.
    func close() { lock.withLock { closed = true } }
    func release(_ data: Data) {
        lock.lock(); let waiter = waiter; self.waiter = nil; lock.unlock()
        waiter?.resume(returning: data)
    }
    func request() -> Data? { lock.withLock { requests.first } }
}

@Suite struct SECXPCTransportTests {
    private func request(_ address: String = "https://www.sec.gov/files/company_tickers_exchange.json") -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("MarketDecision/0.1 researcher@example.invalid", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/html, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        return request
    }
    private func reply() throws -> Data {
        try SECDownloadReply(HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8))).encoded()
    }
    @Test func forbiddenDestinationNeverReachesConnection() async throws {
        let channel = BrokerChannelProbe()
        let checked = SECXPCTransport(channel: channel)
        await #expect(throws: (any Error).self) { _ = try await checked.send(request("https://example.invalid/data")) }
        #expect(channel.count == 0)
        await checked.close()
    }
    @Test func closedDescriptorAndResponseCrossTheChannel() async throws {
        let channel = BrokerChannelProbe()
        let checked = SECXPCTransport(channel: channel)
        let operation = Task { try await checked.send(request()) }
        await channel.arrived()
        let decoded = try SECDownloadRequest.decode(#require(channel.request()))
        #expect(try decoded.makeURLRequest().url == request().url)
        channel.release(try reply())
        let response = try await operation.value
        #expect(response.statusCode == 200 && response.body == Data("{}".utf8))
        await checked.close(); #expect(channel.isClosed)
    }
    @Test func cancellationClosesConnectionAndRejectsLateReply() async throws {
        let channel = BrokerChannelProbe()
        let transport = SECXPCTransport(channel: channel)
        let operation = Task { try await transport.send(request()) }
        await channel.arrived()
        operation.cancel()
        #expect(channel.isClosed)
        channel.release(try reply())
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        await transport.close()
    }
    @Test func explicitClosePreventsNewRequestsAndLatePublication() async throws {
        let channel = BrokerChannelProbe()
        let transport = SECXPCTransport(channel: channel)
        let operation = Task { try await transport.send(request()) }
        await channel.arrived()
        await transport.close()
        channel.release(try reply())
        await #expect(throws: HTTPTransportPolicyError.closed) { _ = try await operation.value }
        await #expect(throws: HTTPTransportPolicyError.closed) { _ = try await transport.send(request()) }
        #expect(channel.count == 1 && channel.isClosed)
    }
    @Test func testRunnerCannotEnableProductionBroker() {
        #expect(!SECNetworkServiceAvailability.isAvailable)
        #expect(throws: HTTPTransportPolicyError.closed) { _ = try SECXPCTransport() }
    }
}
