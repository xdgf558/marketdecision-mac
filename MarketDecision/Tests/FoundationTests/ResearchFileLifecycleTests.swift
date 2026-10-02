import Foundation
import Testing
import DataContracts
@testable import Persistence
@testable import AppComposition

private actor FileOperationGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var started = false
    func pause() async {
        await withCheckedContinuation {
            pending = $0; started = true; waiter?.resume(); waiter = nil
        }
    }
    func waitStarted() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}

/// Each delayed read captures its result before yielding, like a completed SQLite
/// read whose delivery is delayed. This exercises publication independently of I/O.
private actor FileLifecycleStore: ResearchTransferStorage {
    var currentConflicts: [WatchlistConflict] = []
    var conflictGate: FileOperationGate?
    var backupGate: FileOperationGate?
    var cancelGate: FileOperationGate?
    var commitGate: FileOperationGate?
    var failConflict = false
    var failCommit = false
    var plans: [UUID: ResearchTransferPlan] = [:]
    var preparations = 0
    var commits = 0
    var selectedReads = 0
    func seedConflicts() throws {
        currentConflicts = [.init(id: "old-conflict", entry: try WatchlistEntry(symbol: "OLD"))]
    }
    func holdConflicts(_ gate: FileOperationGate, fail: Bool = false) {
        conflictGate = gate; failConflict = fail
    }
    func holdBackup(_ gate: FileOperationGate) { backupGate = gate }
    func holdCancel(_ gate: FileOperationGate) { cancelGate = gate }
    func holdCommit(_ gate: FileOperationGate) { commitGate = gate }
    func rejectCommit() { failCommit = true }
    func selectedBytes() -> Data { selectedReads += 1; return Data("selected".utf8) }
    func exportBackup() async throws -> Data {
        if let gate = backupGate { backupGate = nil; await gate.pause() }
        return Data("frozen-backup".utf8)
    }
    func prepare(_ data: Data, mode: RestoreMode) async throws -> ResearchTransferPlan {
        makePlan(mode == .merge ? .merge : .replace)
    }
    func prepareClear() async throws -> ResearchTransferPlan { makePlan(.clearBusiness) }
    private func makePlan(_ operation: ResearchTransferOperation) -> ResearchTransferPlan {
        preparations += 1
        let plan = ResearchTransferPlan(id: UUID(), digest: UUID().uuidString, operation: operation,
            details: [], researchCount: 0, watchlistCount: 0, conflictCount: 0)
        plans[plan.id] = plan
        return plan
    }
    func commit(_ approval: PlanApproval) async throws {
        if let gate = commitGate { commitGate = nil; await gate.pause() }
        guard let plan = plans[approval.planID], plan.digest == approval.digest else { throw SnapshotError.unknownPlan }
        if failCommit { throw BusinessStoreError.corruptedStorage }
        commits += 1; currentConflicts = []; plans[approval.planID] = nil
    }
    func cancel(_ id: UUID) async {
        if let gate = cancelGate { cancelGate = nil; await gate.pause() }
        plans[id] = nil
    }
    func conflicts() async throws -> [WatchlistConflict] {
        let captured = currentConflicts
        if let gate = conflictGate {
            conflictGate = nil; let fail = failConflict
            await gate.pause()
            if fail { throw BusinessStoreError.corruptedStorage }
        }
        return captured
    }
}

@Suite @MainActor struct ResearchFileLifecycleTests {
    @Test func delayedConflictReadCannotRepublishBeforeCommittedClear() async throws {
        let store = FileLifecycleStore(), gate = FileOperationGate()
        try await store.seedConflicts()
        let model = ResearchTransferModel(store: store)
        await model.prepareClear(); let plan = try #require(model.plan)
        await store.holdConflicts(gate)
        let read = Task { await model.readConflicts() }
        await gate.waitStarted()
        #expect(await model.confirm(id: plan.id, digest: plan.digest))
        #expect(model.conflicts.isEmpty)
        await gate.release(); await read.value
        #expect(model.conflicts.isEmpty)
        #expect(model.message?.contains("操作已提交") == true)
    }
    @Test func slowSelectedFileCannotReplaceNewPlanAfterPageDismissal() async throws {
        let store = FileLifecycleStore(), gate = FileOperationGate()
        let model = ResearchTransferModel(store: store)
        let read = Task {
            await model.prepare(mode: .replace) {
                await gate.pause(); return await store.selectedBytes()
            }
        }
        await gate.waitStarted(); #expect(model.isBusy)
        await model.dismiss().value
        #expect(!model.isBusy); #expect(model.plan == nil)
        await model.prepareClear(); let fresh = try #require(model.plan)
        await gate.release(); await read.value
        #expect(model.plan?.id == fresh.id)
        #expect(await store.preparations == 1)
        #expect(await store.plans[fresh.id]?.id == fresh.id)
        #expect(!model.isBusy)
    }
    @Test func selectedFileReadOwnsBusyBeforeAdditionalPreviewOrClear() async throws {
        let store = FileLifecycleStore(), gate = FileOperationGate()
        let model = ResearchTransferModel(store: store)
        let read = Task {
            await model.prepare(mode: .merge) {
                await gate.pause(); return await store.selectedBytes()
            }
        }
        await gate.waitStarted()
        await model.prepare(mode: .replace) { await store.selectedBytes() }
        await model.prepareClear()
        #expect(await model.backup() == nil)
        #expect(model.isBusy); #expect(model.plan == nil)
        #expect(await store.selectedReads == 0); #expect(await store.preparations == 0)
        await gate.release(); await read.value
        #expect(model.plan?.operation == .merge)
        #expect(await store.selectedReads == 1); #expect(await store.preparations == 1)
    }
    @Test func oldPlanCleanupCannotAdoptSessionCreatedByDismissal() async throws {
        let store = FileLifecycleStore(), gate = FileOperationGate()
        let model = ResearchTransferModel(store: store)
        await model.prepareClear(); let old = try #require(model.plan)
        await store.holdCancel(gate)
        let preview = Task { await model.prepareClear() }
        await gate.waitStarted()
        await model.dismiss().value
        await model.prepareClear(); let fresh = try #require(model.plan)
        await gate.release(); await preview.value
        #expect(model.plan?.id == fresh.id)
        #expect(await store.plans[old.id] == nil)
        #expect(await store.plans[fresh.id]?.id == fresh.id)
        #expect(await store.preparations == 2)
    }
    @Test func dismissedBackupCannotExportOrUnlockNewSelectedFileRead() async throws {
        let store = FileLifecycleStore(), backupGate = FileOperationGate(), readGate = FileOperationGate()
        let model = ResearchTransferModel(store: store)
        await store.holdBackup(backupGate)
        let backup = Task { await model.backup() }
        await backupGate.waitStarted(); await model.dismiss().value
        let read = Task {
            await model.prepare(mode: .merge) {
                await readGate.pause(); return await store.selectedBytes()
            }
        }
        await readGate.waitStarted()
        await backupGate.release(); #expect(await backup.value == nil)
        #expect(model.isBusy); #expect(model.plan == nil)
        await readGate.release(); await read.value
        #expect(model.plan?.operation == .merge); #expect(!model.isBusy)
    }
    @Test func delayedConflictFailureCannotOverwriteFailedCommitOutcome() async throws {
        let store = FileLifecycleStore(), gate = FileOperationGate()
        try await store.seedConflicts()
        let model = ResearchTransferModel(store: store)
        await model.readConflicts(); #expect(model.conflicts.count == 1)
        await model.prepareClear(); let plan = try #require(model.plan)
        await store.holdConflicts(gate, fail: true)
        let read = Task { await model.readConflicts() }
        await gate.waitStarted(); await store.rejectCommit()
        #expect(!(await model.confirm(id: plan.id, digest: plan.digest)))
        let outcome = model.message
        #expect(outcome?.contains("提交未完成") == true)
        await gate.release(); await read.value
        #expect(model.message == outcome)
        #expect(model.conflicts.count == 1); #expect(model.plan?.id == plan.id)
    }
    @Test func newerConflictReadAndPageDismissalRejectOlderDelivery() async throws {
        for dismiss in [false, true] {
            let store = FileLifecycleStore(), gate = FileOperationGate()
            let model = ResearchTransferModel(store: store)
            await store.holdConflicts(gate, fail: true)
            let read = Task { await model.readConflicts() }
            await gate.waitStarted()
            if dismiss { await model.dismiss().value }
            else { try await store.seedConflicts(); await model.readConflicts() }
            await gate.release(); await read.value
            #expect(model.message == nil)
            #expect(model.conflicts.count == (dismiss ? 0 : 1))
        }
    }
    @Test func dismissedCommitStillReportsActualOutcomeAndCleansFailedPlan() async throws {
        for fails in [false, true] {
            let store = FileLifecycleStore(), gate = FileOperationGate()
            let model = ResearchTransferModel(store: store)
            await model.prepareClear(); let plan = try #require(model.plan)
            if fails { await store.rejectCommit() }
            await store.holdCommit(gate)
            let commit = Task { await model.confirm(id: plan.id, digest: plan.digest) }
            await gate.waitStarted(); await model.dismiss().value
            #expect(model.isBusy); #expect(await store.plans[plan.id]?.id == plan.id)
            await gate.release(); #expect(await commit.value == !fails)
            #expect(await store.commits == (fails ? 0 : 1))
            #expect(await store.plans.isEmpty); #expect(!model.isBusy)
            #expect(model.message?.contains(fails ? "请重新预检" : "操作已提交") == true)
            #expect(model.message?.contains("已取消") == false)
        }
    }
    @Test func cancelledAndUnreadableSelectedFilesDoNotPrepareOrMutate() async throws {
        let store = FileLifecycleStore(), model = ResearchTransferModel(store: store)
        await model.prepare(mode: .merge) { throw CancellationError() }
        #expect(model.message?.contains("已取消") == true)
        #expect(model.message?.contains("权限") == false)
        #expect(!model.isBusy); #expect(model.plan == nil)
        await model.prepare(mode: .merge) { throw CocoaError(.fileReadNoPermission) }
        #expect(model.message?.contains("文件读取未完成") == true)
        #expect(!model.isBusy); #expect(model.plan == nil)
        model.fileCancelled()
        #expect(model.message?.contains("已取消") == true)
        #expect(await store.preparations == 0); #expect(await store.commits == 0)
    }
}
