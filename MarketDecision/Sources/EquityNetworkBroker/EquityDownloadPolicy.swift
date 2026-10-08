import Foundation
import CoreDomain
import DataContracts
import DataProviders

public enum EquityNetworkIdentity {
    public static let serviceName = "local.marketdecision.equity-network"
    public static let applicationIdentifier = "local.marketdecision.development"
}

public enum EquityNetworkReplyCode: Int, Sendable {
    case success = 0, invalidRequest, closed, busy, limitExceeded, cancelled, transportFailed
}

@objc public protocol EquityNetworkServiceProtocol {
    func fetch(_ request: Data, withReply reply: @escaping @Sendable (Data?, Int) -> Void)
    func close()
}

public enum EquityDownloadPolicyError: Error { case invalidRequest, invalidReply }

/// A closed IEX request description, never a caller-selected origin or arbitrary headers.
/// Credentials exist only in transient request/XPC buffers; this type must never be logged
/// or persisted. Validation is repeated across the process boundary before network creation.
public struct EquityDownloadRequest: Codable, Sendable {
    public enum Route: String, Codable, Sendable { case quote, bars }
    public let route: Route
    public let symbol: String
    private let apiKey: String
    private let secret: String
    public let start: String?
    public let end: String?
    public let pageToken: String?
    public static let maximumEncodedBytes = 8_192
    public static let accept = "application/json"

    public init(_ request: URLRequest) throws {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "data.alpaca.markets", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%"), request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Accept") == Self.accept,
              let apiKey = request.value(forHTTPHeaderField: "APCA-API-KEY-ID"),
              let secret = request.value(forHTTPHeaderField: "APCA-API-SECRET-KEY"),
              Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
                == ["accept", "apca-api-key-id", "apca-api-secret-key"],
              let items = parts.queryItems, items.allSatisfy({ $0.value != nil }),
              Set(items.map(\.name)).count == items.count
        else { throw EquityDownloadPolicyError.invalidRequest }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count >= 5, path[0].isEmpty, path[1] == "v2", path[2] == "stocks" else {
            throw EquityDownloadPolicyError.invalidRequest
        }
        symbol = String(path[3]); self.apiKey = apiKey; self.secret = secret
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard query["feed"] == "iex", query["currency"] == "USD" else {
            throw EquityDownloadPolicyError.invalidRequest
        }
        if path.count == 6, path[4] == "quotes", path[5] == "latest" {
            guard Set(query.keys) == ["feed", "currency"] else { throw EquityDownloadPolicyError.invalidRequest }
            route = .quote; start = nil; end = nil; pageToken = nil
        } else if path.count == 5, path[4] == "bars" {
            let required: Set<String> = ["timeframe", "adjustment", "asof", "sort", "limit", "start", "end", "feed", "currency"]
            guard Set(query.keys) == required || Set(query.keys) == required.union(["page_token"]),
                  query["timeframe"] == "1Day", query["adjustment"] == "raw", query["asof"] == "-",
                  query["sort"] == "asc", query["limit"] == "1000" else { throw EquityDownloadPolicyError.invalidRequest }
            route = .bars; start = query["start"]; end = query["end"]; pageToken = query["page_token"]
        } else { throw EquityDownloadPolicyError.invalidRequest }
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw EquityDownloadPolicyError.invalidRequest }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields.values.allSatisfy({ $0 is String }) else { throw EquityDownloadPolicyError.invalidRequest }
        let required: Set<String> = ["route", "symbol", "apiKey", "secret"]
        let keys = Set(fields.keys)
        switch fields["route"] as? String {
        case "quote": guard keys == required else { throw EquityDownloadPolicyError.invalidRequest }
        case "bars":
            let bars = required.union(["start", "end"])
            guard keys == bars || keys == bars.union(["pageToken"]) else { throw EquityDownloadPolicyError.invalidRequest }
        default: throw EquityDownloadPolicyError.invalidRequest
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public func makeURLRequest() throws -> URLRequest {
        try validate()
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "data.alpaca.markets"
        parts.path = "/v2/stocks/" + symbol + (route == .quote ? "/quotes/latest" : "/bars")
        var query: [URLQueryItem] = []
        if route == .bars {
            query = [.init(name: "timeframe", value: "1Day"), .init(name: "adjustment", value: "raw"),
                     .init(name: "asof", value: "-"), .init(name: "sort", value: "asc"),
                     .init(name: "limit", value: "1000"), .init(name: "start", value: start),
                     .init(name: "end", value: end)]
            if let pageToken { query.append(.init(name: "page_token", value: pageToken)) }
        }
        parts.queryItems = query + [.init(name: "feed", value: "iex"), .init(name: "currency", value: "USD")]
        guard let url = parts.url else { throw EquityDownloadPolicyError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(secret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        return request
    }

    private func validate() throws {
        try EquityRecord.validateSymbol(symbol)
        for value in [apiKey, secret] {
            guard value.range(of: #"^[A-Za-z0-9_-]{4,256}\z"#, options: .regularExpression) != nil else {
                throw EquityDownloadPolicyError.invalidRequest
            }
        }
        switch route {
        case .quote:
            guard start == nil, end == nil, pageToken == nil else { throw EquityDownloadPolicyError.invalidRequest }
        case .bars:
            guard let start, let end else { throw EquityDownloadPolicyError.invalidRequest }
            let lower = try MillisecondInstant(iso8601: start), upper = try MillisecondInstant(iso8601: end)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            guard lower <= upper, upper.milliseconds - lower.milliseconds <= 366 * 86_400_000,
                  upper.date < calendar.startOfDay(for: Date()),
                  pageToken.map({ !$0.isEmpty && $0.utf8.count <= 2_048
                      && $0.unicodeScalars.allSatisfy { (33...126).contains($0.value) } }) ?? true
            else { throw EquityDownloadPolicyError.invalidRequest }
        }
    }
}

/// Only retry metadata crosses alongside the body. Cookies, credentials and arbitrary
/// response headers never cross back. Base64/JSON/XPC buffers mean this is not a RAM cap.
public struct EquityDownloadReply: Codable, Sendable {
    public static let maximumBodyBytes = 4 * 1_024 * 1_024
    public static let maximumEncodedBytes = 6 * 1_024 * 1_024
    public let statusCode: Int
    public let mediaType: String?
    public let body: Data
    public let retryAfter: String?
    public let rateLimitReset: String?

    public init(_ payload: HTTPPayload) throws {
        statusCode = payload.statusCode; mediaType = payload.mediaType; body = payload.body
        retryAfter = payload.header("Retry-After"); rateLimitReset = payload.header("X-RateLimit-Reset")
        try validate()
    }
    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw EquityDownloadPolicyError.invalidReply }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw EquityDownloadPolicyError.invalidReply }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    public func payload() throws -> HTTPPayload {
        try validate()
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        if let rateLimitReset { headers["X-RateLimit-Reset"] = rateLimitReset }
        return HTTPPayload(statusCode: statusCode, mediaType: mediaType, headers: headers, body: body)
    }
    private func validate() throws {
        guard (100...599).contains(statusCode), !(300...399).contains(statusCode),
              body.count <= Self.maximumBodyBytes,
              [mediaType, retryAfter, rateLimitReset].allSatisfy({ value in
                  value.map({ $0.utf8.count <= 128 && $0.unicodeScalars.allSatisfy { (32...126).contains($0.value) } }) ?? true
              }) else { throw EquityDownloadPolicyError.invalidReply }
    }
}
