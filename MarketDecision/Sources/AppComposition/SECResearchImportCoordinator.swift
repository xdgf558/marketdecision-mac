import Foundation
import Persistence

/// All SEC pages made by one application environment share this permit. Refuse a second
/// import before it constructs a transport. Persistent workspaces also share a nonblocking
/// kernel lease across environments/processes and with Equity capture; no waiting queue.
/// Cancellation alone cannot release it: the operation must actually return, including
/// closing its client transport. This covers slow client cancellation, but does not
/// establish an acknowledgement that the helper/URLSession teardown has completed.
actor SECResearchImportCoordinator {
    private var active = false
    private let workspaceLock: WorkspaceImportLock

    init(workspaceLock: WorkspaceImportLock = WorkspaceImportLock()) { self.workspaceLock = workspaceLock }

    func perform<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !active else { throw SECResearchError.importInProgress }
        let lease: WorkspaceImportLease
        do { lease = try workspaceLock.tryAcquire() }
        catch WorkspaceImportLockError.busy { throw SECResearchError.importInProgress }
        defer { lease.release() }
        try Task.checkCancellation()
        active = true
        defer { active = false }
        let value = try await operation()
        try Task.checkCancellation()
        return value
    }
}
