import Foundation
import DataProviders
import DataContracts

/// Injected for deterministic cancellation/backoff tests. Production uses a monotonic clock.
public protocol EquityRequestClock: Sendable {
    func now() -> Date
    func uptime() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}
public struct SystemEquityRequestClock: EquityRequestClock {
    public init() {}
    public func now() -> Date { Date() }
    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// One shared scheduler per adapter instance (including copies). At most 3 GET attempts,
/// 30 seconds total scheduling/retry budget, at least 350ms between dispatches. These are local
/// operational ceilings, not a promise about account quotas or a substitute for server limits.
actor EquityHTTPExecutor {
    let transport: any HTTPTransport
    let clock: any EquityRequestClock
    private var nextDispatch: TimeInterval = 0
    init(transport: any HTTPTransport, clock: any EquityRequestClock) { self.transport = transport; self.clock = clock }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        let deadline = clock.uptime() + 30
        for attempt in 0..<3 {
            while true {
                try Task.checkCancellation()
                let now = clock.uptime(), wait = max(0, nextDispatch - now)
                guard now + wait <= deadline else { throw ProviderFailure.rateLimited }
                if wait == 0 { nextDispatch = now + 0.35; break }
                try await clock.sleep(seconds: wait)
            }
            let response: HTTPPayload
            do { response = try await transport.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); throw ProviderFailure.offline }
            try Task.checkCancellation()
            guard clock.uptime() <= deadline else { throw ProviderFailure.offline }
            if response.statusCode == 200 { return response }
            if response.statusCode == 401 { throw ProviderFailure.authInvalid }
            if response.statusCode == 403 { throw ProviderFailure.notEntitled }
            if response.statusCode == 404 { throw ProviderFailure.symbolUnavailable }
            let throttled = response.statusCode == 429
            guard throttled || [500, 502, 503, 504].contains(response.statusCode) else { throw ProviderFailure.malformedResponse }
            let failure: ProviderFailure = throttled ? .rateLimited : .offline
            let delay = try retryDelay(response, fallback: pow(2, Double(attempt)))
            // Apply the shared cooldown even when this caller has exhausted its own retries.
            nextDispatch = max(nextDispatch, clock.uptime() + delay)
            guard attempt < 2, nextDispatch <= deadline else { throw failure }
        }
        throw ProviderFailure.offline
    }
    private func retryDelay(_ response: HTTPPayload, fallback: TimeInterval) throws -> TimeInterval {
        var delay = fallback
        if let header = response.header("Retry-After") {
            if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 { delay = max(delay, seconds) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                guard let date = formatter.date(from: header) else { throw ProviderFailure.rateLimited }
                delay = max(delay, date.timeIntervalSince(clock.now()))
            }
        }
        if let header = response.header("X-RateLimit-Reset") {
            guard let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 else { throw ProviderFailure.rateLimited }
            delay = max(delay, seconds - clock.now().timeIntervalSince1970)
        }
        return delay
    }
}
