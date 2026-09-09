import Foundation
import Observation

/// Per-settings-page interaction state. Contains no credential bytes.
@MainActor @Observable public final class CredentialInteractionFlow {
    public enum Action: Equatable { case replace, delete }
    public struct Confirmation: Equatable {
        public let action: Action
        public let revision: UUID
    }
    public struct Operation {
        public let revision: UUID
        fileprivate let session: UUID
    }
    public private(set) var confirmation: Confirmation?
    public private(set) var focusRequest: UUID?
    private var session: UUID?
    public var isVisible: Bool { session != nil }
    public init() {}

    public func appear() { session = UUID(); confirmation = nil; focusRequest = nil }
    public func disappear() { session = nil; confirmation = nil; focusRequest = nil }
    public func requestFocus() {
        guard isVisible else { return }
        focusRequest = UUID()
    }
    public func clearFocusRequest() { focusRequest = nil }
    public func present(_ action: Action, revision: UUID) {
        guard isVisible else { return }
        confirmation = Confirmation(action: action, revision: revision)
        focusRequest = nil
    }
    public func cancel() {
        guard confirmation != nil else { return }
        confirmation = nil
        requestFocus()
    }
    @discardableResult public func invalidate(revision: UUID) -> Bool {
        guard let confirmation, confirmation.revision != revision else { return false }
        self.confirmation = nil
        return true
    }
    public func begin(revision: UUID) -> Operation? {
        guard let session else { return nil }
        focusRequest = nil
        return Operation(revision: revision, session: session)
    }
    public func confirm(_ action: Action, revision: UUID) -> Operation? {
        guard confirmation == Confirmation(action: action, revision: revision) else {
            confirmation = nil
            return nil
        }
        confirmation = nil
        return begin(revision: revision)
    }
    public func completed(_ operation: Operation, succeeded: Bool) {
        guard succeeded, session == operation.session else { return }
        requestFocus()
    }
}
