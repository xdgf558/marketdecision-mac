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
    case invalidConfiguration, forbiddenRequest, responseTooLarge, redirectedResponse, closed
}

/// A request owns only the bytes admitted by its bound. Delegate callbacks and Swift task
/// cancellation can race, so completion and buffer access share one lock. A cancelled request
/// never resumes its continuation twice, even when URLSession later reports its own error.
private final class BoundedHTTPTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let expectedHost: String
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPPayload, Error>?
    private var cancelledBeforeStart = false
    private var finished = false
    private var response: HTTPURLResponse?
    private var body = Data()

    init(maximumBytes: Int, expectedHost: String) {
        self.maximumBytes = maximumBytes
        self.expectedHost = expectedHost
    }

    // The delegate registers the task before this call. Always resume, including after an early
    // cancel, so URLSession delivers completion and the delegate releases the registration.
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<HTTPPayload, Error>) {
        lock.lock()
        let cancelled = cancelledBeforeStart
        if !cancelled {
            self.task = task
            self.continuation = continuation
        }
        lock.unlock()
        if cancelled {
            continuation.resume(throwing: CancellationError())
            task.cancel()
        }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelledBeforeStart = true
        lock.unlock()
        finish(.failure(CancellationError()), cancelTask: true)
    }

    func receive(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(ProviderFailure.malformedResponse), cancelTask: true)
            return false
        }
        guard http.url?.host?.lowercased() == expectedHost,
              http.url?.scheme?.lowercased() == "https",
              !(300...399).contains(http.statusCode) else {
            finish(.failure(HTTPTransportPolicyError.redirectedResponse), cancelTask: true)
            return false
        }
        // This hint can reject early, but a missing, false or compressed Content-Length never
        // relaxes the actual decoded-byte limit enforced in receive(_: Data).
        guard http.expectedContentLength <= Int64(maximumBytes) else {
            finish(.failure(HTTPTransportPolicyError.responseTooLarge), cancelTask: true)
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        self.response = http
        return true
    }

    func receive(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock()
            finish(.failure(HTTPTransportPolicyError.responseTooLarge), cancelTask: true)
            return
        }
        body.append(data)
        lock.unlock()
    }

    func complete(error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let response else {
            lock.unlock()
            finish(.failure(ProviderFailure.malformedResponse))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let result = HTTPPayload(statusCode: response.statusCode, mediaType: response.mimeType,
                                 headers: headers, body: body)
        lock.unlock()
        finish(.success(result))
    }

    private func finish(_ result: Result<HTTPPayload, Error>, cancelTask: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        response = nil
        body = Data()
        lock.unlock()
        if cancelTask { task?.cancel() }
        continuation?.resume(with: result)
    }
}

private final class BoundedHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: BoundedHTTPTransfer] = [:]

    func register(_ transfer: BoundedHTTPTransfer, for task: URLSessionDataTask) {
        lock.lock(); defer { lock.unlock() }
        transfers[task.taskIdentifier] = transfer
    }

    private func transfer(for task: URLSessionTask, remove: Bool = false) -> BoundedHTTPTransfer? {
        lock.lock(); defer { lock.unlock() }
        if remove { return transfers.removeValue(forKey: task.taskIdentifier) }
        return transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(for: dataTask)?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(for: task, remove: true)?.complete(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Explicitly composed HTTPS transport. Exact host allowlisting, an ephemeral no-cookie/no-cache
/// session and denied redirects keep a provider request on its reviewed endpoint. The response
/// body is accumulated incrementally and the task is cancelled before an over-limit chunk is
/// appended. URLSession still owns its transient callback/network buffers; this is not a bound
/// on total process memory. Production use needs account review. No provider is installed by default.
/// A reference owner for one delegate-bearing session. Aliases share the same lifetime;
/// closing one explicitly cancels their in-flight requests, while merely dropping an alias
/// does not. The final owner invalidates the session even if close was omitted.
public actor URLSessionHTTPTransport: HTTPTransport {
    private let allowedHosts: Set<String>
    private let maximumResponseBytes: Int
    private let session: URLSession
    private let delegate: BoundedHTTPDelegate
    private var closed = false

    public init(allowedHosts: Set<String>, maximumResponseBytes: Int = 20 * 1_024 * 1_024,
                timeout: TimeInterval = 30) throws {
        let delegate = BoundedHTTPDelegate()
        self.delegate = delegate
        session = try Self.makeSession(delegate: delegate, allowedHosts: allowedHosts, maximumResponseBytes: maximumResponseBytes,
                                       timeout: timeout, protocolClasses: nil)
        self.allowedHosts = allowedHosts
        self.maximumResponseBytes = maximumResponseBytes
    }

    // Session protocol injection is module-internal and used only by synthetic lifecycle tests.
    init(allowedHosts: Set<String>, maximumResponseBytes: Int, timeout: TimeInterval,
         protocolClasses: [AnyClass]) throws {
        let delegate = BoundedHTTPDelegate()
        self.delegate = delegate
        session = try Self.makeSession(delegate: delegate, allowedHosts: allowedHosts, maximumResponseBytes: maximumResponseBytes,
                                       timeout: timeout, protocolClasses: protocolClasses)
        self.allowedHosts = allowedHosts
        self.maximumResponseBytes = maximumResponseBytes
    }

    private static func makeSession(delegate: BoundedHTTPDelegate, allowedHosts: Set<String>, maximumResponseBytes: Int,
                                    timeout: TimeInterval, protocolClasses: [AnyClass]?) throws -> URLSession {
        let pattern = #"^[a-z0-9][a-z0-9.-]{0,252}$"#
        guard !allowedHosts.isEmpty, allowedHosts.allSatisfy({ host in
            host == host.lowercased() && !host.contains("..") && !host.hasSuffix(".")
                && host.range(of: pattern, options: .regularExpression) != nil
        }), (1...100 * 1_024 * 1_024).contains(maximumResponseBytes),
              timeout.isFinite && (1...120).contains(timeout) else {
            throw HTTPTransportPolicyError.invalidConfiguration
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        session.invalidateAndCancel()
    }

    deinit {
        session.invalidateAndCancel()
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
        guard !closed else { throw HTTPTransportPolicyError.closed }
        let transfer = BoundedHTTPTransfer(maximumBytes: maximumResponseBytes, expectedHost: host)
        let payload: HTTPPayload
        do {
            payload = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let task = session.dataTask(with: controlled)
                    delegate.register(transfer, for: task)
                    transfer.start(task, continuation: continuation)
                }
            } onCancel: {
                transfer.cancel()
            }
        } catch {
            if closed { throw HTTPTransportPolicyError.closed }
            throw error
        }
        guard !closed else { throw HTTPTransportPolicyError.closed }
        try Task.checkCancellation()
        return payload
    }
}
