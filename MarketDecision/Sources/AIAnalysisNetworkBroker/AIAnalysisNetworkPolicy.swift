import Foundation
import AIInsights

public enum AIAnalysisNetworkError: Error, Equatable, Sendable {
    case invalidRequest, invalidResponse, closed, busy, limitExceeded
    case responseTooLarge, redirectedResponse, unauthorized, rateLimited, unavailable
}

public enum AIAnalysisNetworkIdentity {
    public static let serviceName = "local.marketdecision.ai-analysis-network"
    public static let applicationIdentifier = "local.marketdecision.development"
}

@objc public protocol AIAnalysisNetworkServiceProtocol {
    func analyze(_ request: Data, withReply reply: @escaping @Sendable (Data?, Int) -> Void)
    func close()
}

public enum AIAnalysisReplyCode: Int, Sendable { case success, invalidRequest, closed, busy, limitExceeded, failed }

/// Transient IPC envelope. Its key is neither report content nor loggable diagnostic data.
/// The helper rebuilds the URL, headers and body from this closed, revalidated request.
struct AIAnalysisNetworkRequest: Codable, Sendable {
    static let maximumEncodedBytes = 256 * 1_024
    static let endpoint = "https://api.openai.com/v1/responses"
    static let timeout: TimeInterval = 60
    let request: AIInsightRequest
    private let apiKey: String

    init(request: AIInsightRequest, apiKey: Data) throws {
        self.request = request
        guard let text = String(data: apiKey, encoding: .utf8) else { throw AIAnalysisNetworkError.invalidRequest }
        self.apiKey = text
        try validate()
    }
    func validate() throws {
        try request.validate()
        guard (16...1_024).contains(apiKey.utf8.count),
              apiKey.utf8.allSatisfy({ (33...126).contains($0) }),
              !apiKey.contains(":"), !apiKey.contains("\""), !apiKey.contains("\\")
        else { throw AIAnalysisNetworkError.invalidRequest }
        guard try request.encodedBody().count <= AIInsightLimits.requestBodyBytes else {
            throw AIAnalysisNetworkError.invalidRequest
        }
    }
    func encoded() throws -> Data {
        try validate()
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw AIAnalysisNetworkError.invalidRequest }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumEncodedBytes else { throw AIAnalysisNetworkError.invalidRequest }
        try validateDepth(bytes)
        guard
              let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(original.keys) == ["request", "apiKey"] else { throw AIAnalysisNetworkError.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        // Codable alone ignores unknown keys. Compare the decoded schema's re-encoding so
        // hidden tools, headers, origins or request fields cannot ride across the boundary.
        let canonical = try JSONSerialization.jsonObject(with: value.encoded())
        guard NSDictionary(dictionary: original).isEqual(canonical) else { throw AIAnalysisNetworkError.invalidRequest }
        return value
    }
    private static func validateDepth(_ bytes: Data) throws {
        var depth = 0, quoted = false, escaped = false
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 24 else { throw AIAnalysisNetworkError.invalidRequest }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
    }
    func makeURLRequest() throws -> URLRequest {
        try validate()
        guard let url = URL(string: Self.endpoint) else { throw AIAnalysisNetworkError.invalidRequest }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        result.httpMethod = "POST"
        result.httpShouldHandleCookies = false
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        result.httpBody = try request.encodedBody()
        return result
    }
}

/// Only status, MIME type and bounded response bytes return from the helper. Headers,
/// cookies, request credentials and remote error descriptions are never propagated.
struct AIAnalysisNetworkReply: Codable, Sendable {
    static let maximumEncodedBytes = 704 * 1_024
    let statusCode: Int
    let mediaType: String?
    let body: Data
    init(statusCode: Int, mediaType: String?, body: Data) throws {
        self.statusCode = statusCode; self.mediaType = mediaType; self.body = body
        try validate()
    }
    func validate() throws {
        guard (100...599).contains(statusCode), !(300...399).contains(statusCode),
              body.count <= AIInsightLimits.responseBytes,
              mediaType.map({ $0.utf8.count <= 128 && $0.utf8.allSatisfy { (32...126).contains($0) } }) ?? true
        else { throw AIAnalysisNetworkError.invalidResponse }
    }
    func encoded() throws -> Data {
        try validate()
        let value = try JSONEncoder().encode(self)
        guard value.count <= Self.maximumEncodedBytes else { throw AIAnalysisNetworkError.invalidResponse }
        return value
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw AIAnalysisNetworkError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func checkedBody() throws -> Data {
        try validate()
        switch statusCode {
        case 200:
            guard mediaType?.lowercased() == "application/json" else { throw AIAnalysisNetworkError.invalidResponse }
            return body
        case 401, 403: throw AIAnalysisNetworkError.unauthorized
        case 429: throw AIAnalysisNetworkError.rateLimited
        default: throw AIAnalysisNetworkError.unavailable
        }
    }
}
