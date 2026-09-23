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

public enum HTTPTransportPolicyError: Error, Equatable {
    case invalidConfiguration, forbiddenRequest, responseTooLarge, redirectedResponse
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Explicitly composed HTTPS transport. Exact host allowlisting, an ephemeral no-cookie/no-cache
/// session and denied redirects keep a provider request on its reviewed endpoint. The response
/// size check is a rejection bound, not a streaming memory bound; production use still needs
/// transport and account review. No provider is installed by default.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let allowedHosts: Set<String>
    private let maximumResponseBytes: Int
    private let session: URLSession

    public init(allowedHosts: Set<String>, maximumResponseBytes: Int = 20 * 1_024 * 1_024,
                timeout: TimeInterval = 30) throws {
        let pattern = #"^[a-z0-9][a-z0-9.-]{0,252}$"#
        guard !allowedHosts.isEmpty, allowedHosts.allSatisfy({ host in
            host == host.lowercased() && !host.contains("..") && !host.hasSuffix(".")
                && host.range(of: pattern, options: .regularExpression) != nil
        }), (1...100 * 1_024 * 1_024).contains(maximumResponseBytes),
              timeout.isFinite && (1...120).contains(timeout) else {
            throw HTTPTransportPolicyError.invalidConfiguration
        }
        self.allowedHosts = allowedHosts
        self.maximumResponseBytes = maximumResponseBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> HTTPPayload {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host), url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else {
            throw HTTPTransportPolicyError.forbiddenRequest
        }
        var controlled = request
        controlled.cachePolicy = .reloadIgnoringLocalCacheData
        controlled.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: controlled)
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.malformedResponse }
        guard http.url?.host?.lowercased() == host, http.url?.scheme?.lowercased() == "https",
              !(300...399).contains(http.statusCode) else { throw HTTPTransportPolicyError.redirectedResponse }
        guard data.count <= maximumResponseBytes else { throw HTTPTransportPolicyError.responseTooLarge }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPPayload(statusCode: http.statusCode, mediaType: http.mimeType, headers: headers, body: data)
    }
}
