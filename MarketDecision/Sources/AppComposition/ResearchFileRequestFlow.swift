import Foundation

/// Arbitration for one visible native panel request. A cancellation callback wins
/// over a failure callback for the same request, in either delivery order. Keeping
/// the completed identity until the next request prevents duplicate callbacks from
/// being mistaken for a new file operation. No file bytes or storage authorization.
public struct ResearchFileRequestFlow {
    public enum Outcome { case succeeded, failed, cancelled }
    private enum State { case pending, reading, succeeded, failed, cancelled, finished }
    public private(set) var id: UUID?
    private var state = State.finished
    public init() {}
    public var isBusy: Bool { state == .pending || state == .reading }
    public var isReading: Bool { state == .reading }
    public func isPending(_ request: UUID?) -> Bool { request != nil && id == request && state == .pending }
    public func owns(_ request: UUID?) -> Bool { request != nil && id == request }
    public mutating func begin() -> UUID? {
        guard !isBusy else { return nil }
        let request = UUID(); id = request; state = .pending
        return request
    }
    /// True means the caller may publish this outcome exactly once.
    public mutating func receive(_ outcome: Outcome, for request: UUID?) -> Bool {
        guard owns(request) else { return false }
        switch outcome {
        case .cancelled:
            guard state == .pending || state == .reading || state == .failed else { return false }
            state = .cancelled
        case .failed:
            guard state == .pending else { return false }
            state = .failed
        case .succeeded:
            guard state == .pending else { return false }
            state = .succeeded
        }
        return true
    }
    public mutating func selectFile(for request: UUID?) -> Bool {
        guard isPending(request) else { return false }
        state = .reading; return true
    }
    public mutating func finish(for request: UUID?) {
        guard owns(request), isBusy else { return }
        state = .finished
    }
    public mutating func dismiss() { id = nil; state = .finished }
}
