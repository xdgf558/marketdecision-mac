import Foundation
import Security
import AIInsights

/// The application has no socket entitlement. Its AI analysis route is this
/// app-private, separately sandboxed service. This is process isolation, not a DNS firewall.
public enum AIAnalysisServiceAvailability {
    public static let serviceName = AIAnalysisNetworkIdentity.serviceName
    public static let applicationIdentifier = AIAnalysisNetworkIdentity.applicationIdentifier
    public static var isAvailable: Bool { (try? serviceRequirement()) != nil }

    static func serviceRequirement() throws -> String {
        guard Bundle.main.bundleIdentifier == applicationIdentifier else { throw AIAnalysisNetworkError.closed }
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
        else { throw AIAnalysisNetworkError.closed }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/AIAnalysisNetworkService.xpc")
        var service: SecStaticCode?
        guard Bundle(url: url)?.bundleIdentifier == serviceName,
              SecStaticCodeCreateWithPath(url as CFURL, [], &service) == errSecSuccess, let service,
              SecStaticCodeCheckValidity(service, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              let keys = entitlements(service),
              keys["com.apple.security.app-sandbox"] as? Bool == true,
              keys["com.apple.security.network.client"] as? Bool == true,
              Set(keys.keys).isSubset(of: ["com.apple.security.app-sandbox", "com.apple.security.network.client",
                  "com.apple.application-identifier", "com.apple.developer.team-identifier"])
        else { throw AIAnalysisNetworkError.closed }
        // Bind to the actual embedded code, including ad-hoc cdhash in local builds. No fixed
        // team identity, shared keychain or global Mach lookup exception is needed.
        var requirement: SecRequirement?
        var string: CFString?
        guard SecCodeCopyDesignatedRequirement(service, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &string) == errSecSuccess, let string
        else { throw AIAnalysisNetworkError.closed }
        return string as String
    }

    private static func entitlements(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }
}

protocol AIAnalysisNetworkChannel: Sendable {
    func exchange(_ request: Data) async throws -> Data
    func close()
}

/// One connection belongs to one explicit AI analysis. Close/cancellation invalidates it and fails
/// its current waiter exactly once. Late replies cannot satisfy a subsequent request.
final class AIAnalysisXPCChannel: AIAnalysisNetworkChannel, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var closed = false
    private var pending: (UUID, CheckedContinuation<Data, Error>)?

    init(serviceRequirement: String) {
        connection = NSXPCConnection(serviceName: AIAnalysisServiceAvailability.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: AIAnalysisNetworkServiceProtocol.self)
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
                    lock.unlock(); continuation.resume(throwing: AIAnalysisNetworkError.closed); return
                }
                pending = (id, continuation)
                lock.unlock()
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    self?.finish(id, .failure(AIAnalysisNetworkError.closed))
                }
                guard let remote = proxy as? AIAnalysisNetworkServiceProtocol else {
                    finish(id, .failure(AIAnalysisNetworkError.closed)); return
                }
                remote.analyze(request) { [weak self] data, code in
                    guard code == 0, let data else {
                        let error: AIAnalysisNetworkError
                        switch AIAnalysisReplyCode(rawValue: code) {
                        case .invalidRequest: error = .invalidRequest
                        case .closed: error = .closed
                        case .busy: error = .busy
                        case .limitExceeded: error = .limitExceeded
                        default: error = .unavailable
                        }
                        self?.finish(id, .failure(error)); return
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
        pending?.1.resume(throwing: AIAnalysisNetworkError.closed)
    }
}

/// Construct only for an explicit analysis after the user has accepted its data/cost scope.
/// Initialization checks the shipped helper before callers read Keychain bytes.
public actor AIAnalysisXPCClient {
    private let channel: any AIAnalysisNetworkChannel
    private var closed = false
    private var consumed = false
    public init() throws {
        channel = AIAnalysisXPCChannel(serviceRequirement: try AIAnalysisServiceAvailability.serviceRequirement())
    }
    init(channel: any AIAnalysisNetworkChannel) { self.channel = channel }
    deinit { channel.close() }
    public func analyze(_ request: AIInsightRequest, apiKey: Data) async throws -> AIInsightResult {
        guard !closed else { throw AIAnalysisNetworkError.closed }
        guard !consumed else { throw AIAnalysisNetworkError.limitExceeded }
        try Task.checkCancellation()
        let bytes = try AIAnalysisNetworkRequest(request: request, apiKey: apiKey).encoded()
        consumed = true
        let channel = channel
        do {
            let data = try await withTaskCancellationHandler {
                try await channel.exchange(bytes)
            } onCancel: { channel.close() }
            try Task.checkCancellation()
            guard !closed else { throw AIAnalysisNetworkError.closed }
            let body = try AIAnalysisNetworkReply.decode(data).checkedBody()
            let result = try request.parseResponse(body)
            close()
            return result
        } catch {
            close()
            throw error
        }
    }
    public func close() { closed = true; channel.close() }
}
