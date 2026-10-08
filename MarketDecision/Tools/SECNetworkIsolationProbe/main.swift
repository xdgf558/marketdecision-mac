import Foundation
import Darwin
import Security
import SECNetworkBroker
import EquityNetworkBroker

// Synthetic signing/IPC probe only, never linked into the production executable. No valid
// SEC/equity request, contact, account, file panel, user database or credential is used here.
@main struct SECNetworkIsolationProbe {
    private enum Broker: CaseIterable, Sendable {
        case sec, equity
        var name: String { self == .sec ? "SECNetworkService" : "EquityNetworkService" }
        var identity: String { self == .sec ? SECNetworkIdentity.serviceName : EquityNetworkIdentity.serviceName }
        var invalidCode: Int { self == .sec ? SECNetworkReplyCode.invalidRequest.rawValue : EquityNetworkReplyCode.invalidRequest.rawValue }
    }

    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--expect-invalid-broker"] {
            guard !SECNetworkServiceAvailability.isAvailable, !EquityNetworkServiceAvailability.isAvailable else {
                fail("replaced-helper-accepted")
            }
            print("PASS: main sealed resources reject an independently re-signed replacement helper for both brokers")
            return
        }
        guard SECNetworkServiceAvailability.isAvailable, EquityNetworkServiceAvailability.isAvailable else { fail("broker-unavailable") }
        // No listener is needed: EPERM is an OS denial, unlike ECONNREFUSED/timeout.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { fail("socket-create") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let failure = errno
        Darwin.close(descriptor)
        guard result == -1, failure == EPERM || failure == EACCES else { fail("main-network-not-denied") }
        // Exercise each actual app-private listener with a malformed descriptor that MUST
        // be refused before any URLSession is constructed. There are no credentials here.
        for broker in Broker.allCases {
            do { try await rejectedDescriptorRoundTrip(broker) }
            catch { fail("ipc-rejection") }
        }
        print("PASS: sandbox denies main sockets; authenticated SEC/Equity XPC reject malformed requests; zero external requests")
    }
    private static func rejectedDescriptorRoundTrip(_ broker: Broker) async throws {
        let serviceURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/" + broker.name + ".xpc")
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(serviceURL as CFURL, [], &code) == errSecSuccess, let code else { fail("service-code") }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { fail("service-requirement") }
        let connection = NSXPCConnection(serviceName: broker.identity)
        connection.setCodeSigningRequirement(text as String)
        switch broker {
        case .sec: connection.remoteObjectInterface = NSXPCInterface(with: SECNetworkServiceProtocol.self)
        case .equity: connection.remoteObjectInterface = NSXPCInterface(with: EquityNetworkServiceProtocol.self)
        }
        connection.resume()
        defer { connection.invalidate() }
        let timeout = Task { try await Task.sleep(for: .seconds(15)); fail("ipc-timeout") }
        defer { timeout.cancel() }
        let accepted: Bool = await withCheckedContinuation { continuation in
            let once = ProbeReply(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.finish(false) }
            let reply: @Sendable (Data?, Int) -> Void = { data, status in
                once.finish(data == nil && status == broker.invalidCode)
            }
            switch broker {
            case .sec:
                guard let remote = proxy as? SECNetworkServiceProtocol else { once.finish(false); return }
                remote.fetch(Data("{}".utf8), withReply: reply)
            case .equity:
                guard let remote = proxy as? EquityNetworkServiceProtocol else { once.finish(false); return }
                remote.fetch(Data("{}".utf8), withReply: reply)
            }
        }
        guard accepted else { fail("ipc-refusal-contract") }
        print("PASS: " + broker.name + " rejects malformed descriptor")
    }
    static func fail(_ code: String) -> Never { print("FAIL: " + code); exit(1) }
}

private final class ProbeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ result: Bool) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: result)
    }
}
