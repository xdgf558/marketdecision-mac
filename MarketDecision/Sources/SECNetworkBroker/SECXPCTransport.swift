import Foundation
import Security
import DataProviders

/// The application has no socket entitlement. Its sole production download route is this
/// app-private, separately sandboxed service. This is process isolation, not a DNS firewall.
public enum SECNetworkServiceAvailability {
    public static let serviceName = SECNetworkIdentity.serviceName
    public static let applicationIdentifier = SECNetworkIdentity.applicationIdentifier
    public static var isAvailable: Bool { (try? serviceRequirement()) != nil }

    static func serviceRequirement() throws -> String {
        guard Bundle.main.bundleIdentifier == applicationIdentifier else { throw HTTPTransportPolicyError.closed }
        var current: SecCode?
        var staticCurrent: SecStaticCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, [], &staticCurrent) == errSecSuccess, let staticCurrent,
              SecStaticCodeCheckValidity(staticCurrent,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess,
              let mainEntitlements = entitlements(staticCurrent),
              mainEntitlements["com.apple.security.app-sandbox"] as? Bool == true,
              mainEntitlements["com.apple.security.network.client"] == nil,
              mainEntitlements["com.apple.security.network.server"] == nil
        else { throw HTTPTransportPolicyError.closed }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/SECNetworkService.xpc")
        var service: SecStaticCode?
        guard Bundle(url: url)?.bundleIdentifier == serviceName,
              SecStaticCodeCreateWithPath(url as CFURL, [], &service) == errSecSuccess, let service,
              SecStaticCodeCheckValidity(service, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              let keys = entitlements(service),
              keys["com.apple.security.app-sandbox"] as? Bool == true,
              keys["com.apple.security.network.client"] as? Bool == true,
              Set(keys.keys).isSubset(of: ["com.apple.security.app-sandbox", "com.apple.security.network.client",
                  "com.apple.application-identifier", "com.apple.developer.team-identifier"])
        else { throw HTTPTransportPolicyError.closed }
        // Bind to the actual embedded code, including ad-hoc cdhash in local builds. No fixed
        // team identity, shared keychain or global Mach lookup exception is needed.
        var requirement: SecRequirement?
        var string: CFString?
        guard SecCodeCopyDesignatedRequirement(service, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &string) == errSecSuccess, let string
        else { throw HTTPTransportPolicyError.closed }
        return string as String
    }

    private static func entitlements(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }
}

protocol SECNetworkChannel: Sendable {
    func exchange(_ request: Data) async throws -> Data
    func close()
}

/// One connection belongs to one explicit import. Close/cancellation invalidates it and fails
/// its current waiter exactly once. Late replies cannot satisfy a subsequent request.
final class SECXPCChannel: SECNetworkChannel, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var closed = false
    private var pending: (UUID, CheckedContinuation<Data, Error>)?

    init(serviceRequirement: String) {
        connection = NSXPCConnection(serviceName: SECNetworkServiceAvailability.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: SECNetworkServiceProtocol.self)
        connection.setCodeSigningRequirement(serviceRequirement)
        connection.invalidationHandler = { [weak self] in self?.close() }
        connection.interruptionHandler = { [weak self] in self?.close() }
        connection.resume()
    }
    deinit { close() }

    func exchange(_ request: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                lock.lock()
                guard !closed, pending == nil else {
                    lock.unlock(); continuation.resume(throwing: HTTPTransportPolicyError.closed); return
                }
                pending = (id, continuation)
                lock.unlock()
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    self?.finish(id, .failure(HTTPTransportPolicyError.closed))
                }
                guard let remote = proxy as? SECNetworkServiceProtocol else {
                    finish(id, .failure(HTTPTransportPolicyError.closed)); return
                }
                remote.fetch(request) { [weak self] data, code in
                    guard code == 0, let data else {
                        self?.finish(id, .failure(HTTPTransportPolicyError.forbiddenRequest)); return
                    }
                    self?.finish(id, .success(data))
                }
            }
        } onCancel: { self.close() }
    }
    private func finish(_ id: UUID, _ result: Result<Data, Error>) {
        lock.lock()
        guard let pending, pending.0 == id else { lock.unlock(); return }
        self.pending = nil
        lock.unlock()
        pending.1.resume(with: result)
    }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let pending = pending; self.pending = nil
        lock.unlock()
        // Invalidating the connection also tells the service to cancel and close its session;
        // there is no race-prone best-effort close RPC followed immediately by invalidation.
        connection.invalidate()
        pending?.1.resume(throwing: HTTPTransportPolicyError.closed)
    }
}

public actor SECXPCTransport: HTTPTransport {
    private let channel: any SECNetworkChannel
    private var closed = false
    public init() throws {
        channel = SECXPCChannel(serviceRequirement: try SECNetworkServiceAvailability.serviceRequirement())
    }
    init(channel: any SECNetworkChannel) { self.channel = channel }
    deinit { channel.close() }
    public func send(_ request: URLRequest) async throws -> HTTPPayload {
        guard !closed else { throw HTTPTransportPolicyError.closed }
        try Task.checkCancellation()
        let data = try SECDownloadRequest(request).encoded()
        let channel = channel
        let response = try await withTaskCancellationHandler {
            try await channel.exchange(data)
        } onCancel: { channel.close() }
        try Task.checkCancellation()
        guard !closed else { throw HTTPTransportPolicyError.closed }
        return try SECDownloadReply.decode(response).payload()
    }
    public func close() { closed = true; channel.close() }
}
