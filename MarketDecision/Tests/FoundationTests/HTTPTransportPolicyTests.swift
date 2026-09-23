import Foundation
import Testing
import DataProviders

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
    }
}
