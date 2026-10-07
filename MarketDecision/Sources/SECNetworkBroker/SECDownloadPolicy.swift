import Foundation
import DataProviders

public enum SECNetworkIdentity {
    public static let serviceName = "local.marketdecision.sec-network"
    public static let applicationIdentifier = "local.marketdecision.development"
}

public enum SECNetworkReplyCode: Int, Sendable {
    case success = 0, invalidRequest, closed, busy, limitExceeded, cancelled, transportFailed
}

@objc public protocol SECNetworkServiceProtocol {
    func fetch(_ request: Data, withReply reply: @escaping @Sendable (Data?, Int) -> Void)
    func close()
}

public enum SECDownloadPolicyError: Error { case invalidRequest, invalidReply }

/// A narrow wire description, never a caller-selected URL or arbitrary HTTP headers.
/// Codable decoding is untrusted: validation is repeated before constructing any request.
public struct SECDownloadRequest: Codable, Sendable {
    public enum Route: String, Codable, Sendable { case identity, submissions, facts, archive }
    public let route: Route
    public let resource: String
    public let userAgent: String
    public static let maximumEncodedBytes = 4_096
    public static let accept = "application/json, text/html, text/plain;q=0.9, */*;q=0.1"

    public init(_ request: URLRequest) throws {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, !parts.percentEncodedPath.contains("%"),
              request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              let agent = request.value(forHTTPHeaderField: "User-Agent"),
              request.value(forHTTPHeaderField: "Accept") == Self.accept,
              Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) == ["user-agent", "accept"]
        else { throw SECDownloadPolicyError.invalidRequest }
        let path = parts.path
        if parts.host == "www.sec.gov", path == "/files/company_tickers_exchange.json" {
            route = .identity; resource = ""
        } else if parts.host == "data.sec.gov", path.hasPrefix("/submissions/") {
            route = .submissions; resource = String(path.dropFirst("/submissions/".count))
        } else if parts.host == "data.sec.gov", path.hasPrefix("/api/xbrl/companyfacts/") {
            route = .facts; resource = String(path.dropFirst("/api/xbrl/companyfacts/".count))
        } else if parts.host == "www.sec.gov", path.hasPrefix("/Archives/edgar/data/") {
            route = .archive; resource = String(path.dropFirst("/Archives/edgar/data/".count))
        } else { throw SECDownloadPolicyError.invalidRequest }
        userAgent = agent
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw SECDownloadPolicyError.invalidRequest }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw SECDownloadPolicyError.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func makeURLRequest() throws -> URLRequest {
        try validate()
        let host: String, path: String
        switch route {
        case .identity: host = "www.sec.gov"; path = "/files/company_tickers_exchange.json"
        case .submissions: host = "data.sec.gov"; path = "/submissions/" + resource
        case .facts: host = "data.sec.gov"; path = "/api/xbrl/companyfacts/" + resource
        case .archive: host = "www.sec.gov"; path = "/Archives/edgar/data/" + resource
        }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = path
        guard let url = parts.url else { throw SECDownloadPolicyError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        return request
    }

    private func validate() throws {
        let prefix = "MarketDecision/0.1 "
        guard userAgent.hasPrefix(prefix) else { throw SECDownloadPolicyError.invalidRequest }
        let email = String(userAgent.dropFirst(prefix.count))
        guard email.utf8.count <= 160, !email.contains(".."),
              Self.matches(email, #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}\z"#)
        else { throw SECDownloadPolicyError.invalidRequest }
        let valid: Bool
        switch route {
        case .identity: valid = resource.isEmpty
        case .submissions:
            valid = Self.matches(resource, #"^CIK[0-9]{10}(?:-submissions-[0-9]{3})?\.json\z"#)
        case .facts: valid = Self.matches(resource, #"^CIK[0-9]{10}\.json\z"#)
        case .archive:
            // Unpadded issuer number, compact accession, and exactly one safe filename.
            // Zero is retained to match the existing adapter's CIK grammar; issuer identity
            // matching remains a separate provider contract and grants no new endpoint.
            valid = Self.matches(resource, #"^(?:0|[1-9][0-9]{0,9})/[0-9]{18}/[A-Za-z0-9][A-Za-z0-9._\-]{0,255}\z"#)
                && !resource.contains("..")
        }
        guard valid else { throw SECDownloadPolicyError.invalidRequest }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The wire reply excludes cookies, server diagnostics, URLs and arbitrary header fields.
/// The body cap is not a bound on process memory (JSON/XPC and the caller also own buffers).
public struct SECDownloadReply: Codable, Sendable {
    public static let maximumBodyBytes = 20 * 1_024 * 1_024
    public static let maximumEncodedBytes = 29 * 1_024 * 1_024
    public let statusCode: Int
    public let mediaType: String?
    public let body: Data

    public init(_ payload: HTTPPayload) throws {
        statusCode = payload.statusCode; mediaType = payload.mediaType; body = payload.body
        try validate()
    }
    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw SECDownloadPolicyError.invalidReply }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw SECDownloadPolicyError.invalidReply }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    public func payload() throws -> HTTPPayload {
        try validate()
        return HTTPPayload(statusCode: statusCode, mediaType: mediaType, body: body)
    }
    private func validate() throws {
        guard (100...599).contains(statusCode), body.count <= Self.maximumBodyBytes,
              mediaType.map({ $0.utf8.count <= 128 && !$0.contains("\r") && !$0.contains("\n") }) ?? true
        else { throw SECDownloadPolicyError.invalidReply }
    }
}
