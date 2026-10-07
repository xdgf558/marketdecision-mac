import Foundation
import DataProviders

/// One XPC connection is one explicit import. No transport is constructed at listener
/// startup, and a connection accepts only one in-flight request and forty total pages.
public final class SECNetworkBrokerSession: NSObject, SECNetworkServiceProtocol, @unchecked Sendable {
    private typealias Reply = @Sendable (Data?, Int) -> Void
    private let lock = NSLock()
    private let factory: @Sendable () throws -> (any HTTPTransport, @Sendable () async -> Void)
    private var transport: (any HTTPTransport)?
    private var closeTransport: (@Sendable () async -> Void)?
    private var closed = false
    private var requestCount = 0
    private var pending: (id: UUID, task: Task<Void, Never>, reply: Reply)?

    public override init() {
        factory = {
            let transport = try URLSessionHTTPTransport(allowedHosts: ["www.sec.gov", "data.sec.gov"],
                maximumResponseBytes: SECDownloadReply.maximumBodyBytes)
            return (transport, { await transport.close() })
        }
        super.init()
    }

    // Synthetic dependency only: the XPC listener uses the no-argument production initializer.
    init(factory: @escaping @Sendable () throws -> (any HTTPTransport, @Sendable () async -> Void)) {
        self.factory = factory
        super.init()
    }

    public func fetch(_ encoded: Data, withReply reply: @escaping @Sendable (Data?, Int) -> Void) {
        let request: URLRequest
        do { request = try SECDownloadRequest.decode(encoded).makeURLRequest() }
        catch { reply(nil, SECNetworkReplyCode.invalidRequest.rawValue); return }
        lock.lock()
        guard !closed else { lock.unlock(); reply(nil, SECNetworkReplyCode.closed.rawValue); return }
        guard pending == nil else { lock.unlock(); reply(nil, SECNetworkReplyCode.busy.rawValue); return }
        guard requestCount < 40 else { lock.unlock(); reply(nil, SECNetworkReplyCode.limitExceeded.rawValue); return }
        do {
            if transport == nil {
                let owned = try factory(); transport = owned.0; closeTransport = owned.1
            }
        } catch { lock.unlock(); reply(nil, SECNetworkReplyCode.transportFailed.rawValue); return }
        guard let transport else { lock.unlock(); reply(nil, SECNetworkReplyCode.transportFailed.rawValue); return }
        requestCount += 1
        let id = UUID()
        let task = Task { [self] in
            do {
                try Task.checkCancellation()
                let payload = try await transport.send(request)
                try Task.checkCancellation()
                let data = try SECDownloadReply(payload).encoded()
                complete(id: id, data: data, code: .success)
            } catch is CancellationError { complete(id: id, data: nil, code: .cancelled) }
            catch { complete(id: id, data: nil, code: .transportFailed) }
        }
        pending = (id, task, reply)
        lock.unlock()
    }

    private func complete(id: UUID, data: Data?, code: SECNetworkReplyCode) {
        lock.lock()
        guard let current = pending, current.id == id, !closed else { lock.unlock(); return }
        pending = nil
        lock.unlock()
        current.reply(data, code.rawValue)
    }

    /// Connection invalidation and explicit close share one idempotent path. It closes the
    /// caller immediately even if a transport misbehaves; a late result cannot reply again.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let current = pending; pending = nil
        let finish = closeTransport; closeTransport = nil; transport = nil
        lock.unlock()
        current?.task.cancel()
        current?.reply(nil, SECNetworkReplyCode.closed.rawValue)
        if let finish { Task { await finish() } }
    }

    deinit {
        pending?.task.cancel()
        if let finish = closeTransport { Task { await finish() } }
    }
}
