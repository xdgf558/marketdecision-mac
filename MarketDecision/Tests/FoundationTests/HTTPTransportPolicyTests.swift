import Foundation
import Testing
@testable import DataProviders

private actor TransportLifecycleProbe {
    private(set) var starts = 0
    private(set) var stops = 0
    func started() { starts += 1 }
    func stopped() { stops += 1 }
}

private final class PausedHTTPSProtocol: URLProtocol {
    static let probe = TransportLifecycleProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await Self.probe.started() } }
    override func stopLoading() { Task { await Self.probe.stopped() } }
}

@Suite struct HTTPTransportPolicyTests {
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
        let transport = try URLSessionHTTPTransport(allowedHosts: ["data.sec.gov"],
            maximumResponseBytes: 1_024, timeout: 30, protocolClasses: [PausedHTTPSProtocol.self])
        let alias = transport
        let request = URLRequest(url: try #require(URL(string: "https://data.sec.gov/test")))
        let startedBefore = await PausedHTTPSProtocol.probe.starts
        let stoppedBefore = await PausedHTTPSProtocol.probe.stops
        let pending = Task { try await transport.send(request) }
        for _ in 0..<200 {
            if await PausedHTTPSProtocol.probe.starts > startedBefore { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await PausedHTTPSProtocol.probe.starts > startedBefore)
        await alias.close()
        await #expect(throws: HTTPTransportPolicyError.closed) { try await pending.value }
        await #expect(throws: HTTPTransportPolicyError.closed) { try await transport.send(request) }
        await transport.close() // idempotent across aliases
        for _ in 0..<200 {
            if await PausedHTTPSProtocol.probe.stops > stoppedBefore { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await PausedHTTPSProtocol.probe.stops > stoppedBefore)
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
