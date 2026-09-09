import OSLog

/// No arbitrary string, URL, header, Error, or credential can enter this log API.
public enum SecurityEvent: String, Sendable { case credentialSaved, credentialDeleted, credentialReadFailed, providerRequestFailed }
public struct SafeLog: Sendable {
    private let logger = Logger(subsystem: "local.marketdecision", category: "security")
    public init() {}
    public static func message(for event: SecurityEvent) -> String { event.rawValue }
    public func write(_ event: SecurityEvent) { logger.info("\(event.rawValue, privacy: .public)") }
}
