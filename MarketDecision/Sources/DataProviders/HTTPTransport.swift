import Foundation
import DataContracts

public struct HTTPPayload: Sendable {
    public let statusCode: Int
    public let mediaType: String?
    public let headers: [String: String]
    public let body: Data
    public init(statusCode: Int, mediaType: String?, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode; self.mediaType = mediaType; self.headers = headers; self.body = body
    }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPPayload }

/// Available for explicitly composed adapters. No production provider is installed by default.
public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> HTTPPayload {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.malformedResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPPayload(statusCode: http.statusCode, mediaType: http.mimeType, headers: headers, body: data)
    }
}
