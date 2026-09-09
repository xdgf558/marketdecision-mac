import Foundation
import Observation

/// Per-settings-page interaction state. Contains no credential bytes.
@MainActor @Observable public final class CredentialInteractionFlow {
    public enum Action: Equatable { case replace, delete }
    public struct Confirmation: Equatable {
        public let id: UUID
        public let action: Action
        public let revision: UUID
    }
    public struct Operation {
        public let revision: UUID
        fileprivate let session: UUID
    }
    public private(set) var confirmation: Confirmation?
    public private(set) var focusRequest: UUID?
    public private(set) var confirmationNotice: String?
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
        confirmationNotice = nil
        confirmation = Confirmation(id: UUID(), action: action, revision: revision)
        focusRequest = nil
    }
    public func cancel(_ id: UUID) {
        guard confirmation?.id == id else { return }
        confirmation = nil
        requestFocus()
    }
    @discardableResult public func invalidate(revision: UUID) -> Bool {
        guard let confirmation, confirmation.revision != revision else { return false }
        self.confirmation = nil
        confirmationNotice = "凭据状态已变化，请重新发起操作并确认。"
        return true
    }
    public func begin(revision: UUID) -> Operation? {
        guard let session else { return nil }
        focusRequest = nil
        return Operation(revision: revision, session: session)
    }
    /// One terminal callback for button activation, cancellation, or system dismissal.
    public func respond(to id: UUID, confirmed: Bool, revision: UUID) -> Operation? {
        guard let confirmation, confirmation.id == id else { return nil }
        guard confirmed else { cancel(id); return nil }
        guard confirmation.revision == revision else {
            invalidate(revision: revision)
            return nil
        }
        self.confirmation = nil
        return begin(revision: revision)
    }
    public func completedCheck(_ operation: Operation, succeeded: Bool) {
        guard succeeded, session == operation.session else { return }
        confirmationNotice = nil
        completed(operation, succeeded: true)
    }
    public func completed(_ operation: Operation, succeeded: Bool) {
        guard succeeded, session == operation.session, confirmation == nil else { return }
        requestFocus()
    }
}
