import Foundation
import Testing
import Persistence
@testable import AppComposition

/// Each wait has an explicit arrival/release handshake. Cancellation deliberately does
/// not resume hold(): an import must retain its permit while slow work/close is unwinding.
private actor SECImportPermitGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            held = continuation
            entered = true
            let waiters = entryWaiters; entryWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        let continuation = held; held = nil
        continuation?.resume()
    }
}

private actor SECImportFactoryCounter {
    private(set) var calls = 0
    func invoke() -> Int { calls += 1; return calls }
}

private enum SECImportPermitFixtureError: Error { case failed }

@Suite struct SECResearchImportCoordinatorTests {
    @Test func secondImportIsRejectedBeforeItsTransportFactoryRuns() async throws {
        let coordinator = SECResearchImportCoordinator()
        let gate = SECImportPermitGate(), rejectedFactory = SECImportFactoryCounter()
        let first = Task {
            try await coordinator.perform {
                await gate.hold()
                return 41
            }
        }
        await gate.waitUntilEntered()
        await #expect(throws: SECResearchError.importInProgress) {
            try await coordinator.perform { await rejectedFactory.invoke() }
        }
        #expect(await rejectedFactory.calls == 0)
        await gate.release()
        #expect(try await first.value == 41)
        #expect(try await coordinator.perform { 42 } == 42)
    }

    @Test func cancellationKeepsPermitUntilWorkAndTransportCloseActuallyReturn() async throws {
        let coordinator = SECResearchImportCoordinator()
        let work = SECImportPermitGate(), closing = SECImportPermitGate()
        let rejectedFactory = SECImportFactoryCounter()
        let first = Task {
            try await coordinator.perform {
                await work.hold()
                // Models the awaited transport.close() at the end of the real importer.
                await closing.hold()
                return 10
            }
        }
        await work.waitUntilEntered()
        first.cancel()
        await #expect(throws: SECResearchError.importInProgress) {
            try await coordinator.perform { await rejectedFactory.invoke() }
        }
        await work.release()
        await closing.waitUntilEntered()
        await #expect(throws: SECResearchError.importInProgress) {
            try await coordinator.perform { await rejectedFactory.invoke() }
        }
        #expect(await rejectedFactory.calls == 0)
        await closing.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await coordinator.perform { 11 } == 11)
    }

    @Test func operationFailureReleasesPermitForTheNextImport() async throws {
        let coordinator = SECResearchImportCoordinator()
        let gate = SECImportPermitGate()
        let failing = Task {
            try await coordinator.perform { () async throws -> Int in
                await gate.hold()
                throw SECImportPermitFixtureError.failed
            }
        }
        await gate.waitUntilEntered()
        await #expect(throws: SECResearchError.importInProgress) {
            try await coordinator.perform { 1 }
        }
        await gate.release()
        await #expect(throws: SECImportPermitFixtureError.self) { try await failing.value }
        #expect(try await coordinator.perform { 2 } == 2)
    }

    @Test func alreadyCancelledCallerNeverInvokesTheOperationOrClaimsPermit() async throws {
        let coordinator = SECResearchImportCoordinator(), factory = SECImportFactoryCounter()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.perform { await factory.invoke() }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await factory.calls == 0)
        #expect(try await coordinator.perform { 3 } == 3)
    }

    @Test func copiedApplicationEnvironmentsShareTheSameImportPermit() async throws {
        let original = try AppEnvironment.mock(databasePath: ":memory:")
        let copied = original
        #expect(original.secImportCoordinator === copied.secImportCoordinator)
        let gate = SECImportPermitGate(), rejectedFactory = SECImportFactoryCounter()
        let running = Task {
            try await original.secImportCoordinator.perform {
                await gate.hold()
                return 5
            }
        }
        await gate.waitUntilEntered()
        await #expect(throws: SECResearchError.importInProgress) {
            try await copied.secImportCoordinator.perform { await rejectedFactory.invoke() }
        }
        #expect(await rejectedFactory.calls == 0)
        await gate.release()
        #expect(try await running.value == 5)
        #expect(try await copied.secImportCoordinator.perform { 6 } == 6)
    }

    @Test func separatelyOpenedEnvironmentsRejectBeforeFactoryAndDoNotLockAtStartup() async throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let path = directory.url.appendingPathComponent("foundation.sqlite").path
        let first = try AppEnvironment.mock(databasePath: path), second = try AppEnvironment.mock(databasePath: path)
        #expect(!FileManager.default.fileExists(atPath: directory.lockURL.path))
        let gate = SECImportPermitGate(), factory = SECImportFactoryCounter()
        let running = Task { try await first.secImportCoordinator.perform { await gate.hold(); return 1 } }
        await gate.waitUntilEntered()
        await #expect(throws: SECResearchError.importInProgress) {
            try await second.secImportCoordinator.perform { await factory.invoke() }
        }
        #expect(await factory.calls == 0)
        await gate.release()
        #expect(try await running.value == 1)
        do { #expect(try await second.secImportCoordinator.perform { 2 } == 2) }
        catch { Issue.record("Successor import stayed blocked after the original operation returned"); throw error }
    }

    @Test func crossEnvironmentPermitSurvivesCancellationUntilCloseReturns() async throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let first = SECResearchImportCoordinator(workspaceLock: WorkspaceImportLock(directory: directory.url))
        let second = SECResearchImportCoordinator(workspaceLock: WorkspaceImportLock(directory: directory.url))
        let work = SECImportPermitGate(), closing = SECImportPermitGate(), factory = SECImportFactoryCounter()
        let running = Task { try await first.perform { await work.hold(); await closing.hold(); return 1 } }
        await work.waitUntilEntered()
        running.cancel()
        await #expect(throws: SECResearchError.importInProgress) { try await second.perform { await factory.invoke() } }
        await work.release(); await closing.waitUntilEntered()
        await #expect(throws: SECResearchError.importInProgress) { try await second.perform { await factory.invoke() } }
        let child = try ImportLockChild(directory, mode: "try")
        try child.expect("BUSY"); try child.waitForExit()
        #expect(await factory.calls == 0)
        await closing.release()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await second.perform { 2 } == 2)
    }

    @Test func subprocessCompetitionAndUnavailableWorkspaceNeverInvokeSECFactory() async throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let child = try ImportLockChild(directory)
        try child.expect("READY")
        let coordinator = SECResearchImportCoordinator(workspaceLock: WorkspaceImportLock(directory: directory.url))
        let factory = SECImportFactoryCounter()
        await #expect(throws: SECResearchError.importInProgress) { try await coordinator.perform { await factory.invoke() } }
        let missing = SECResearchImportCoordinator(workspaceLock: WorkspaceImportLock(directory: directory.url.appendingPathComponent("missing")))
        await #expect(throws: WorkspaceImportLockError.unavailable) { try await missing.perform { await factory.invoke() } }
        #expect(await factory.calls == 0)
        try child.release()
        #expect(try await coordinator.perform { 3 } == 3)
    }

    @Test func preCancelledFileImportDoesNotCreateLockAndThrownOperationReleasesIt() async throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let coordinator = SECResearchImportCoordinator(workspaceLock: WorkspaceImportLock(directory: directory.url))
        let factory = SECImportFactoryCounter()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.perform { await factory.invoke() }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await factory.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.lockURL.path))
        await #expect(throws: SECImportPermitFixtureError.self) {
            try await coordinator.perform { () async throws -> Int in throw SECImportPermitFixtureError.failed }
        }
        let child = try ImportLockChild(directory, mode: "try")
        try child.expect("ACQUIRED"); try child.waitForExit()
    }
}
