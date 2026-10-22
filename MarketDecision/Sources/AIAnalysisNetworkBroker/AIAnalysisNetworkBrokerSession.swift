import Foundation

/// One explicit analysis per app-private connection. Invalid descriptors never create a
/// transport, and no retry is automatic: a retried API call may incur another charge.
public final class AIAnalysisNetworkBrokerSession: NSObject, AIAnalysisNetworkServiceProtocol, @unchecked Sendable {
    private typealias Reply = @Sendable (Data?, Int) -> Void
    private let lock = NSLock()
    private let factory: @Sendable () throws -> any AIAnalysisHTTPTransport
    private var transport: (any AIAnalysisHTTPTransport)?
    private var closed = false
    private var consumed = false
    private var pending: (id: UUID, task: Task<Void, Never>, reply: Reply)?

    public override init() { factory = { AIAnalysisURLSessionTransport() }; super.init() }
    init(factory: @escaping @Sendable () throws -> any AIAnalysisHTTPTransport) {
        self.factory = factory; super.init()
    }
    public func analyze(_ bytes: Data, withReply reply: @escaping @Sendable (Data?, Int) -> Void) {
        let request: AIAnalysisNetworkRequest
        do { request = try AIAnalysisNetworkRequest.decode(bytes) }
        catch { reply(nil, AIAnalysisReplyCode.invalidRequest.rawValue); return }
        lock.lock()
        guard !closed else { lock.unlock(); reply(nil, AIAnalysisReplyCode.closed.rawValue); return }
        guard pending == nil else { lock.unlock(); reply(nil, AIAnalysisReplyCode.busy.rawValue); return }
        guard !consumed else { lock.unlock(); reply(nil, AIAnalysisReplyCode.limitExceeded.rawValue); return }
        let transport: any AIAnalysisHTTPTransport
        do { transport = try factory() }
        catch { lock.unlock(); reply(nil, AIAnalysisReplyCode.failed.rawValue); return }
        self.transport = transport
        consumed = true
        let id = UUID()
        let task = Task { [self] in
            do {
                try Task.checkCancellation()
                let response = try await transport.send(request)
                try Task.checkCancellation()
                let data = try response.encoded()
                await transport.close()
                complete(id: id, data: data, code: .success)
            } catch {
                await transport.close()
                complete(id: id, data: nil, code: .failed)
            }
        }
        pending = (id, task, reply)
        lock.unlock()
    }
    private func complete(id: UUID, data: Data?, code: AIAnalysisReplyCode) {
        lock.lock()
        guard let current = pending, current.id == id, !closed else { lock.unlock(); return }
        pending = nil; transport = nil
        lock.unlock()
        current.reply(data, code.rawValue)
    }
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let current = pending; pending = nil
        let transport = transport; self.transport = nil
        lock.unlock()
        current?.task.cancel()
        current?.reply(nil, AIAnalysisReplyCode.closed.rawValue)
        if let transport { Task { await transport.close() } }
    }
    deinit {
        pending?.task.cancel()
        if let transport { Task { await transport.close() } }
    }
}
