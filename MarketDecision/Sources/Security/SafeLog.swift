import OSLog

/// No arbitrary string, URL, header, Error, credential or account reference enters this API.
public enum SecurityEvent: String, Sendable, CaseIterable {
    case credentialSaved, credentialDeleted, credentialReadFailed, providerRequestFailed
    case credentialCheckSucceeded, credentialSaveFailed, credentialDeleteFailed, credentialInputRejected
    case localPreparationFailed, providerRequestCancelled, localPreparationCancelled
}
/// The only payload is a closed event. Both production output and test sinks use this renderer.
public struct SafeLogRecord: Sendable, Equatable {
    public let event: SecurityEvent
    public init(event: SecurityEvent) { self.event = event }
    public var message: String { event.rawValue }
}
public protocol SecurityEventSink: Sendable {
    func record(_ record: SafeLogRecord)
}
private struct SystemEventSink: SecurityEventSink {
    private let logger = Logger(subsystem: "local.marketdecision", category: "security")
    func record(_ record: SafeLogRecord) { logger.info("\(record.message, privacy: .public)") }
}
public struct SafeLog: Sendable {
    private let sink: any SecurityEventSink
    public init() { sink = SystemEventSink() }
    public init(sink: any SecurityEventSink) { self.sink = sink }
    public static func message(for event: SecurityEvent) -> String { SafeLogRecord(event: event).message }
    public func write(_ event: SecurityEvent) { sink.record(SafeLogRecord(event: event)) }
}
