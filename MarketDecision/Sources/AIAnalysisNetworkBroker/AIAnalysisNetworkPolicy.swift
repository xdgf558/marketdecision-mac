import Foundation
import AIInsights

public enum AIAnalysisNetworkError: Error, Equatable, Sendable {
    case invalidRequest, invalidResponse, closed, busy, limitExceeded
    case responseTooLarge, redirectedResponse, unauthorized, rateLimited, unavailable
    case timedOut, connectionFailed, secureConnectionFailed
}

/// A closed diagnostic, never the remote error message, headers, request ID or credentials.
/// The HTTP status remains useful even when a body is malformed or its code is unknown.
public struct AIAnalysisAPIFailure: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case authentication, permissionDenied, modelUnavailable, requestRejected, notFound
        case creditsExhausted, organizationSpendLimit, projectSpendLimit, organizationUsageLimit
        case quotaExceeded, rateLimited, rateOrQuota, serverFailure, unexpectedStatus
    }
    public let statusCode: Int
    public let reason: Reason

    public init(statusCode: Int, reason: Reason) {
        self.statusCode = statusCode
        self.reason = reason
    }

    init(statusCode: Int, body: Data) {
        let reason: Reason
        switch statusCode {
        case 401: reason = .authentication
        case 403: reason = .permissionDenied
        case 400, 404:
            reason = Self.knownCodes(in: body).contains("model_not_found")
                ? .modelUnavailable : (statusCode == 400 ? .requestRejected : .notFound)
        case 429:
            let codes = Self.knownCodes(in: body)
            var reasons = Set(codes.compactMap(Self.quotaReason).map(\.rawValue))
            // insufficient_quota can accompany a more specific billing/usage code.
            // It is a parent category, not a contradictory second diagnosis.
            if reasons.count > 1, !reasons.contains(Reason.rateLimited.rawValue) {
                reasons.remove(Reason.quotaExceeded.rawValue)
            }
            // Genuinely conflicting quota/rate or multiple specific categories remain unknown.
            if reasons.count == 1, let value = reasons.first, let category = Reason(rawValue: value) {
                reason = category
            } else {
                reason = .rateOrQuota
            }
        case 500...599: reason = .serverFailure
        default: reason = .unexpectedStatus
        }
        self.init(statusCode: statusCode, reason: reason)
    }

    private static func quotaReason(_ code: String) -> Reason? {
        switch code {
        case "credit_balance_exhausted": return .creditsExhausted
        case "organization_spend_limit_exceeded": return .organizationSpendLimit
        case "project_spend_limit_exceeded": return .projectSpendLimit
        case "organization_usage_limit_exceeded": return .organizationUsageLimit
        case "insufficient_quota": return .quotaExceeded
        case "rate_limit_exceeded", "slow_down", "rate_limit_error": return .rateLimited
        default: return nil
        }
    }

    private static func knownCodes(in body: Data) -> Set<String> {
        // Diagnostic parsing has its own smaller byte/depth budget. Exceeding it only
        // removes the optional category; it never turns an HTTP failure into success.
        guard body.count <= 16 * 1_024 else { return [] }
        var depth = 0, quoted = false, escaped = false
        for byte in body {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 8 else { return [] }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else { return [] }
            }
        }
        guard depth == 0, !quoted,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let failure = object["error"] as? [String: Any] else { return [] }
        let allowed: Set<String> = ["model_not_found", "credit_balance_exhausted",
            "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
            "organization_usage_limit_exceeded", "insufficient_quota",
            "rate_limit_exceeded", "slow_down", "rate_limit_error"]
        return Set(["code", "type"].compactMap { field -> String? in
            guard let value = failure[field] as? String, value.utf8.count <= 64,
                  allowed.contains(value) else { return nil }
            return value
        })
    }
}

public enum AIAnalysisNetworkIdentity {
    public static let serviceName = "local.marketdecision.ai-analysis-network"
    public static let applicationIdentifier = "local.marketdecision.development"
}

@objc public protocol AIAnalysisNetworkServiceProtocol {
    func analyze(_ request: Data, withReply reply: @escaping @Sendable (Data?, Int) -> Void)
    func close()
}

public enum AIAnalysisReplyCode: Int, Sendable {
    // Keep the original wire values stable for existing helpers and clients.
    case success, invalidRequest, closed, busy, limitExceeded, failed
    case timedOut, connectionFailed, secureConnectionFailed, responseTooLarge, redirectedResponse, invalidResponse

    static func transportFailure(_ error: any Error) -> Self {
        if let error = error as? AIAnalysisNetworkError {
            switch error {
            case .invalidRequest: return .invalidRequest
            case .invalidResponse: return .invalidResponse
            case .closed: return .closed
            case .busy: return .busy
            case .limitExceeded: return .limitExceeded
            case .timedOut: return .timedOut
            case .connectionFailed: return .connectionFailed
            case .secureConnectionFailed: return .secureConnectionFailed
            case .responseTooLarge: return .responseTooLarge
            case .redirectedResponse: return .redirectedResponse
            default: return .failed
            }
        }
        if error is CancellationError { return .closed }
        guard let error = error as? URLError else { return .failed }
        switch error.code {
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return .connectionFailed
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .secureConnectionFailed
        case .cancelled: return .closed
        default: return .failed
        }
    }

    var networkError: AIAnalysisNetworkError {
        switch self {
        case .invalidRequest: return .invalidRequest
        case .closed: return .closed
        case .busy: return .busy
        case .limitExceeded: return .limitExceeded
        case .timedOut: return .timedOut
        case .connectionFailed: return .connectionFailed
        case .secureConnectionFailed: return .secureConnectionFailed
        case .responseTooLarge: return .responseTooLarge
        case .redirectedResponse: return .redirectedResponse
        case .invalidResponse: return .invalidResponse
        case .success, .failed: return .unavailable
        }
    }
}

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
/// cookies and request credentials are never propagated. An HTTP failure becomes a
/// closed category in checkedBody(); remote error descriptions never become diagnostics.
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
        default: throw AIAnalysisAPIFailure(statusCode: statusCode, body: body)
        }
    }
}
