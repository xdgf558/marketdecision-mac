import Foundation
import AIInsights

protocol AIAnalysisHTTPTransport: Sendable {
    func send(_ request: AIAnalysisNetworkRequest) async throws -> AIAnalysisNetworkReply
    func close() async
}

private final class AIAnalysisBoundedTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let expectedHost: String
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<AIAnalysisNetworkReply, Error>?
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
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<AIAnalysisNetworkReply, Error>) {
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
            finish(.failure(AIAnalysisNetworkError.invalidResponse), cancelTask: true)
            return false
        }
        guard http.url?.absoluteString == AIAnalysisNetworkRequest.endpoint,
              http.url?.host?.lowercased() == expectedHost,
              !(300...399).contains(http.statusCode) else {
            finish(.failure(AIAnalysisNetworkError.redirectedResponse), cancelTask: true)
            return false
        }
        // This hint can reject early, but a missing, false or compressed Content-Length never
        // relaxes the actual decoded-byte limit enforced in receive(_: Data).
        guard http.expectedContentLength <= Int64(maximumBytes) else {
            finish(.failure(AIAnalysisNetworkError.responseTooLarge), cancelTask: true)
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
            finish(.failure(AIAnalysisNetworkError.responseTooLarge), cancelTask: true)
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
            finish(.failure(AIAnalysisNetworkError.invalidResponse))
            return
        }
        let result: AIAnalysisNetworkReply
        do { result = try AIAnalysisNetworkReply(statusCode: response.statusCode, mediaType: response.mimeType, body: body) }
        catch { lock.unlock(); finish(.failure(AIAnalysisNetworkError.invalidResponse)); return }
        lock.unlock()
        finish(.success(result))
    }

    private func finish(_ result: Result<AIAnalysisNetworkReply, Error>, cancelTask: Bool = false) {
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

private final class AIAnalysisBoundedDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: AIAnalysisBoundedTransfer] = [:]

    func register(_ transfer: AIAnalysisBoundedTransfer, for task: URLSessionDataTask) {
        lock.lock(); defer { lock.unlock() }
        transfers[task.taskIdentifier] = transfer
    }

    private func transfer(for task: URLSessionTask, remove: Bool = false) -> AIAnalysisBoundedTransfer? {
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

/// Dedicated one-purpose POST session. Existing SEC/Equity GET policy remains unchanged.
/// Byte bounds stop over-limit accumulation, not URLSession/XPC/JSON total process memory.
/// Aliases share this reference owner; close and final release invalidate the delegate session.
actor AIAnalysisURLSessionTransport: AIAnalysisHTTPTransport {
    private let maximumBytes: Int
    private let session: URLSession
    private let delegate: AIAnalysisBoundedDelegate
    private var closed = false

    init() {
        maximumBytes = AIInsightLimits.responseBytes
        let delegate = AIAnalysisBoundedDelegate()
        self.delegate = delegate
        session = Self.makeSession(delegate: delegate, protocolClasses: nil)
    }
    // Synthetic URLProtocol injection and smaller response bounds are test-only.
    init(protocolClasses: [AnyClass], maximumBytes: Int = AIInsightLimits.responseBytes) throws {
        guard (1...AIInsightLimits.responseBytes).contains(maximumBytes) else {
            throw AIAnalysisNetworkError.invalidRequest
        }
        self.maximumBytes = maximumBytes
        let delegate = AIAnalysisBoundedDelegate()
        self.delegate = delegate
        session = Self.makeSession(delegate: delegate, protocolClasses: protocolClasses)
    }
    private static func makeSession(delegate: AIAnalysisBoundedDelegate, protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = AIAnalysisNetworkRequest.timeout
        configuration.timeoutIntervalForResource = AIAnalysisNetworkRequest.timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    func close() {
        guard !closed else { return }
        closed = true
        session.invalidateAndCancel()
    }
    deinit { session.invalidateAndCancel() }

    func send(_ request: AIAnalysisNetworkRequest) async throws -> AIAnalysisNetworkReply {
        guard !closed else { throw AIAnalysisNetworkError.closed }
        let controlled = try request.makeURLRequest()
        let transfer = AIAnalysisBoundedTransfer(maximumBytes: maximumBytes, expectedHost: "api.openai.com")
        let reply: AIAnalysisNetworkReply
        do {
            reply = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let task = session.dataTask(with: controlled)
                    delegate.register(transfer, for: task)
                    transfer.start(task, continuation: continuation)
                }
            } onCancel: { transfer.cancel() }
        } catch {
            if closed { throw AIAnalysisNetworkError.closed }
            throw error
        }
        guard !closed else { throw AIAnalysisNetworkError.closed }
        try Task.checkCancellation()
        return reply
    }
}
