import Foundation
import Darwin
import Security
import SECNetworkBroker

// Synthetic signing/IPC probe only, never linked into the production executable. No SEC
// request, contact, account, file panel, user database or shared credential is used here.
@main struct SECNetworkIsolationProbe {
    static func main() async {
        if CommandLine.arguments.dropFirst() == ["--expect-invalid-broker"] {
            guard !SECNetworkServiceAvailability.isAvailable else { fail("replaced-helper-accepted") }
            print("PASS: main sealed resources reject an independently re-signed replacement helper")
            return
        }
        guard SECNetworkServiceAvailability.isAvailable else { fail("broker-unavailable") }
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
        // Exercise real app-private IPC and the peer signature requirements, with an invalid
        // descriptor that MUST be refused before any URLSession is constructed.
        do {
            try await rejectedDescriptorRoundTrip()
        } catch { fail("ipc-rejection") }
        print("PASS: sandbox denies main sockets; authenticated embedded XPC rejects malformed request; no external request")
    }
    static func rejectedDescriptorRoundTrip() async throws {
        let serviceURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/SECNetworkService.xpc")
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(serviceURL as CFURL, [], &code) == errSecSuccess, let code else { fail("service-code") }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { fail("service-requirement") }
        let connection = NSXPCConnection(serviceName: SECNetworkIdentity.serviceName)
        connection.setCodeSigningRequirement(text as String)
        connection.remoteObjectInterface = NSXPCInterface(with: SECNetworkServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { fail("ipc-timeout") }
        let accepted: Bool = await withCheckedContinuation { continuation in
            let once = ProbeReply(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { failure in
                let systemError = failure as NSError
                print("IPC failure code: " + systemError.domain + "/" + String(systemError.code))
                once.finish(false)
            }
            guard let remote = proxy as? SECNetworkServiceProtocol else { once.finish(false); return }
            remote.fetch(Data("{}".utf8)) { data, status in
                print("IPC reply code: " + String(status))
                once.finish(data == nil && status == SECNetworkReplyCode.invalidRequest.rawValue)
            }
        }
        guard accepted else { fail("ipc-refusal-contract") }
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
