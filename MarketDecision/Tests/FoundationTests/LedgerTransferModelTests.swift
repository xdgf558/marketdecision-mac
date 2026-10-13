import Foundation
import Testing
import PortfolioEngine
@testable import Persistence
@testable import AppComposition

private actor LedgerTransferGate {
    private var arrived = false, released = false
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var worker: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; watchers.forEach { $0.resume() }; watchers.removeAll()
        if !released { await withCheckedContinuation { worker = $0 } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { watchers.append($0) } } }
    func release() { released = true; worker?.resume(); worker = nil }
}
private actor TransferArchiveProbe: LedgerArchiveStorage {
    let base: LedgerArchiveStore
    var gates: [String: LedgerTransferGate] = [:]
    var cancelled: [UUID] = [], preparations = 0, commits = 0
    var failCommit = false
    init(_ base: LedgerArchiveStore) { self.base = base }
    func gate(_ key: String, _ gate: LedgerTransferGate) { gates[key] = gate }
    func pause(_ key: String) async { if let gate = gates.removeValue(forKey: key) { await gate.hold() } }
    func failNextCommit() { failCommit = true }
    func status() async throws -> LedgerArchiveStatus { let value = try await base.status(); await pause("status"); return value }
    func exportArchive() async throws -> Data { let value = try await base.exportArchive(); await pause("export"); return value }
    func prepareRestore(_ data: Data, mode: LedgerRestoreMode, expectedLedgerRevision: UUID, expectedPerformanceRevision: UUID) async throws -> LedgerTransferPlan {
        preparations += 1
        let value = try await base.prepareRestore(data, mode: mode, expectedLedgerRevision: expectedLedgerRevision, expectedPerformanceRevision: expectedPerformanceRevision)
        await pause("prepare"); return value
    }
    func prepareClear(expectedLedgerRevision: UUID, expectedPerformanceRevision: UUID) async throws -> LedgerTransferPlan {
        preparations += 1
        let value = try await base.prepareClear(expectedLedgerRevision: expectedLedgerRevision, expectedPerformanceRevision: expectedPerformanceRevision)
        await pause("prepare"); return value
    }
    func commit(_ approval: LedgerTransferApproval) async throws -> LedgerTransferResult {
        commits += 1; await pause("commit")
        if failCommit { failCommit = false; throw LedgerArchiveError.injectedFailure }
        return try await base.commit(approval)
    }
    func cancel(_ id: UUID) async { cancelled.append(id); await base.cancel(id) }
    func conflicts() async throws -> [LedgerArchiveConflictSummary] { try await base.conflicts() }
    func exportConflict(id: UUID) async throws -> Data { try await base.exportConflict(id: id) }
}
private actor TransferLedgerProbe: LedgerStorage {
    let base: LedgerStore
    var gates: [String: LedgerTransferGate] = [:]
    init(_ base: LedgerStore) { self.base = base }
    func gate(_ key: String, _ gate: LedgerTransferGate) { gates[key] = gate }
    func pause(_ key: String) async { if let gate = gates.removeValue(forKey: key) { await gate.hold() } }
    func snapshot() async throws -> LedgerSnapshot { let value = try await base.snapshot(); await pause("snapshot"); return value }
    func createAccount(_ account: LedgerAccount, expectedRevision: UUID) async throws -> LedgerSnapshot { try await base.createAccount(account, expectedRevision: expectedRevision) }
    func previewCSV(data: Data, accountID: String, sourceSystem: String, mapping: LedgerCSVMapping, excludedRows: Set<Int>, expectedRevision: UUID) async throws -> LedgerImportPreview {
        try await base.previewCSV(data: data, accountID: accountID, sourceSystem: sourceSystem, mapping: mapping, excludedRows: excludedRows, expectedRevision: expectedRevision)
    }
    func previewManual(events: [LedgerEvent], expectedRevision: UUID) async throws -> LedgerImportPreview { try await base.previewManual(events: events, expectedRevision: expectedRevision) }
    func previewCorrection(originalEventID: String, replacement: LedgerEvent, reason: String, expectedRevision: UUID) async throws -> LedgerImportPreview {
        try await base.previewCorrection(originalEventID: originalEventID, replacement: replacement, reason: reason, expectedRevision: expectedRevision)
    }
    func previewBatchReversal(batchID: String, effectiveAt: Date, reason: String, expectedRevision: UUID) async throws -> LedgerImportPreview {
        try await base.previewBatchReversal(batchID: batchID, effectiveAt: effectiveAt, reason: reason, expectedRevision: expectedRevision)
    }
    func commit(planID: UUID, expectedRevision: UUID) async throws -> LedgerSnapshot {
        await pause("commit"); return try await base.commit(planID: planID, expectedRevision: expectedRevision)
    }
    func cancel(planID: UUID) async { await base.cancel(planID: planID) }
}
private actor TransferPerformanceProbe: PerformanceStorage {
    let base: PerformanceStore
    var gates: [String: LedgerTransferGate] = [:]
    init(_ base: PerformanceStore) { self.base = base }
    func gate(_ key: String, _ gate: LedgerTransferGate) { gates[key] = gate }
    func pause(_ key: String) async { if let gate = gates.removeValue(forKey: key) { await gate.hold() } }
    func context() async throws -> PerformanceStoreContext { let value = try await base.context(); await pause("context"); return value }
    func prepare(request: PerformanceRequest, rawRequest: Data?, expectedLedgerRevision: UUID, expectedPerformanceRevision: UUID) async throws -> PerformancePreview {
        let value = try await base.prepare(request: request, rawRequest: rawRequest, expectedLedgerRevision: expectedLedgerRevision, expectedPerformanceRevision: expectedPerformanceRevision)
        await pause("prepare"); return value
    }
    func commit(planID: UUID, expectedLedgerRevision: UUID, expectedPerformanceRevision: UUID) async throws -> SavedPerformanceReport {
        await pause("commit"); return try await base.commit(planID: planID, expectedLedgerRevision: expectedLedgerRevision, expectedPerformanceRevision: expectedPerformanceRevision)
    }
    func cancel(planID: UUID) async { await base.cancel(planID: planID) }
    func reports(accountID: String) async throws -> [PerformanceSummary] { try await base.reports(accountID: accountID) }
    func open(id: UUID) async throws -> SavedPerformanceReport { let value = try await base.open(id: id); await pause("open"); return value }
}
@Suite("Ledger transfer page sessions and shared invalidation") @MainActor
struct LedgerTransferModelTests {
    private struct Fixture {
        let ledger: LedgerStore, performance: PerformanceStore, archive: TransferArchiveProbe
        let ledgerProbe: TransferLedgerProbe, performanceProbe: TransferPerformanceProbe
        let transfer: LedgerTransferModel, workspace: LedgerWorkspaceModel, portfolio: PortfolioWorkspaceModel
        let coordinator: LedgerTransferCoordinator
    }
    private func setup() async throws -> Fixture {
        let ledger = try LedgerStore(path: ":memory:"), input = try PortfolioSyntheticExample.input()
        let initial = try await ledger.snapshot()
        let created = try await ledger.createAccount(input.accounts[0], expectedRevision: initial.revision)
        let plan = try await ledger.previewManual(events: input.events, expectedRevision: created.revision)
        _ = try await ledger.commit(planID: plan.id, expectedRevision: created.revision)
        let performance = try await ledger.makePerformanceStore()
        let archiveStore = try await ledger.makeArchiveStore()
        let archive = TransferArchiveProbe(archiveStore)
        let ledgerProbe = TransferLedgerProbe(ledger), performanceProbe = TransferPerformanceProbe(performance), coordinator = LedgerTransferCoordinator()
        let transfer = LedgerTransferModel(store: archive, ledger: ledgerProbe, performance: performanceProbe, coordinator: coordinator)
        let workspace = LedgerWorkspaceModel(storage: ledgerProbe), portfolio = PortfolioWorkspaceModel(storage: performanceProbe)
        workspace.installTransfer(transfer, coordinator: coordinator)
        portfolio.installTransfer(transfer, coordinator: coordinator)
        await workspace.load(); await portfolio.load(); await transfer.load()
        return .init(ledger: ledger, performance: performance, archive: archive, ledgerProbe: ledgerProbe, performanceProbe: performanceProbe,
                     transfer: transfer, workspace: workspace, portfolio: portfolio, coordinator: coordinator)
    }
    private func clear(_ fixture: Fixture) async throws -> LedgerTransferPlan {
        await fixture.transfer.prepareClear(); return try #require(fixture.transfer.plan)
    }
    private func saveReport(_ fixture: Fixture) async throws -> SavedPerformanceReport {
        await fixture.portfolio.prepare(try PortfolioSyntheticExample.input().request)
        let preview = try #require(fixture.portfolio.preview)
        #expect(await fixture.portfolio.save(id: preview.id, ledgerRevision: preview.ledgerRevision, performanceRevision: preview.performanceRevision))
        await fixture.transfer.load()
        return try #require(fixture.portfolio.savedReport)
    }
    @Test func explicitClearApprovalBindsIdentityDigestAndBothRevisions() async throws {
        let f = try await setup(), plan = try await clear(f)
        let wrong = LedgerTransferApproval(planID: plan.id, digest: plan.digest, ledgerRevision: plan.baseLedgerRevision, performanceRevision: UUID())
        #expect(await f.transfer.confirm(wrong) == false)
        #expect(await f.archive.commits == 0)
        await f.transfer.cancel()
        #expect(try await f.ledger.snapshot().accounts.count == 1)
        #expect(await f.transfer.confirm(.init(plan: plan)) == false)
    }
    @Test func delayedSelectedReadCannotPrepareAfterCancellationOrOtherPageClear() async throws {
        let f = try await setup(), bytes = try await f.archive.exportArchive(), gate = LedgerTransferGate()
        let task = Task { await f.transfer.prepare(mode: .merge) { await gate.hold(); return bytes } }
        await gate.wait(); f.transfer.cancelFileWork(); f.transfer.fileCancelled()
        await gate.release(); await task.value
        #expect(f.transfer.plan == nil && f.transfer.message?.contains("已取消") == true)
        #expect(await f.archive.preparations == 0)
        let gate2 = LedgerTransferGate()
        let old = Task { await f.transfer.prepare(mode: .merge) { await gate2.hold(); return bytes } }
        await gate2.wait()
        let second = LedgerTransferModel(store: f.archive, ledger: f.ledgerProbe, performance: f.performanceProbe, coordinator: f.coordinator)
        await second.load(); await second.prepareClear()
        let plan = try #require(second.plan)
        #expect(await second.confirm(.init(plan: plan)))
        await gate2.release(); await old.value
        #expect(f.transfer.plan == nil && f.transfer.status?.counts.accounts == 0)
    }
    @Test func latePreviewAfterDismissalIsCancelledWithoutPublishing() async throws {
        let f = try await setup(), gate = LedgerTransferGate()
        await f.archive.gate("prepare", gate)
        let task = Task { await f.transfer.prepareClear() }
        await gate.wait(); f.transfer.dismiss()
        await gate.release(); await task.value
        #expect(f.transfer.plan == nil && f.transfer.message == nil)
        #expect(await f.archive.cancelled.count == 1)
    }
    @Test func transientCommitFailureRetainsExactPlanAndRefreshesPagesBeforeRetry() async throws {
        let f = try await setup(), plan = try await clear(f)
        await f.archive.failNextCommit()
        #expect(await f.transfer.confirm(.init(plan: plan)) == false)
        #expect(f.transfer.plan?.id == plan.id && f.transfer.canConfirm)
        #expect(f.workspace.snapshot?.accounts.count == 1 && f.portfolio.context?.ledger.accounts.count == 1)
        #expect(await f.transfer.confirm(.init(plan: plan)))
        #expect(f.workspace.snapshot?.accounts.isEmpty == true && f.portfolio.context?.ledger.accounts.isEmpty == true)
        #expect(f.transfer.plan == nil && !f.workspace.isBusy && !f.portfolio.isBusy)
    }
    @Test func staleApprovalCleansPlanWithoutRebasingIt() async throws {
        let f = try await setup(), plan = try await clear(f), before = try await f.ledger.snapshot()
        _ = try await f.ledger.createAccount(.init(id: "second", name: "Second"), expectedRevision: before.revision)
        #expect(await f.transfer.confirm(.init(plan: plan)) == false)
        #expect(f.transfer.plan == nil && f.transfer.status == nil && f.transfer.hasError)
        #expect(await f.archive.cancelled.contains(plan.id))
        #expect(f.workspace.snapshot?.accounts.count == 2)
    }
    @Test func departedCommitCompletesButDoesNotPublishItsMessage() async throws {
        let f = try await setup(), plan = try await clear(f), gate = LedgerTransferGate()
        await f.archive.gate("commit", gate)
        let task = Task { await f.transfer.confirm(.init(plan: plan)) }
        await gate.wait(); f.transfer.dismiss()
        await gate.release(); #expect(await task.value)
        #expect(f.transfer.message == nil && f.transfer.status == nil && !f.transfer.isBusy)
        #expect(f.workspace.snapshot?.accounts.isEmpty == true)
    }
    @Test func oldLedgerReadAndOldPerformanceOpenCannotRepublishAfterClear() async throws {
        let f = try await setup(), report = try await saveReport(f), readGate = LedgerTransferGate(), openGate = LedgerTransferGate()
        await f.ledgerProbe.gate("snapshot", readGate); await f.performanceProbe.gate("open", openGate)
        let oldRead = Task { await f.workspace.load() }, oldOpen = Task { await f.portfolio.open(report.id) }
        await readGate.wait(); await openGate.wait()
        let plan = try await clear(f)
        #expect(await f.transfer.confirm(.init(plan: plan)))
        await readGate.release(); await openGate.release(); await oldRead.value; await oldOpen.value
        #expect(f.workspace.snapshot?.accounts.isEmpty == true && !f.workspace.isBusy)
        #expect(f.portfolio.report == nil && f.portfolio.saved.isEmpty && f.portfolio.context?.ledger.accounts.isEmpty == true)
    }
    @Test func oldPortfolioPreviewAndSaveCannotCrossClearToGainNewBaseline() async throws {
        let f = try await setup(), gate = LedgerTransferGate()
        await f.performanceProbe.gate("prepare", gate)
        let request = try PortfolioSyntheticExample.input().request
        let preparing = Task { await f.portfolio.prepare(request) }
        await gate.wait()
        let plan = try await clear(f)
        #expect(await f.transfer.confirm(.init(plan: plan)))
        await gate.release(); await preparing.value
        #expect(f.portfolio.preview == nil && f.portfolio.report == nil)
        #expect(try await f.performance.reports(accountID: request.accountID).isEmpty)

        let second = try await setup()
        await second.portfolio.prepare(request)
        let preview = try #require(second.portfolio.preview), saveGate = LedgerTransferGate()
        await second.performanceProbe.gate("commit", saveGate)
        let saving = Task { await second.portfolio.save(id: preview.id, ledgerRevision: preview.ledgerRevision, performanceRevision: preview.performanceRevision) }
        await saveGate.wait()
        let clearPlan = try await clear(second)
        #expect(await second.transfer.confirm(.init(plan: clearPlan)))
        #expect(second.portfolio.isBusy) // The old write still owns its own reservation.
        await saveGate.release(); #expect(await saving.value == false)
        #expect(try await second.performance.reports(accountID: request.accountID).isEmpty)
        #expect(second.portfolio.report == nil && !second.portfolio.isBusy)
    }
    @Test func oldLedgerCommitCannotRecreateAccountEventsAfterClear() async throws {
        let f = try await setup()
        let original = try #require(f.workspace.snapshot?.events.first(where: {
            if case .cash = $0.payload { return true }; return false
        }))
        let event = LedgerEvent(id: "late-deposit", accountID: original.accountID,
            effectiveAt: original.effectiveAt.addingTimeInterval(1),
            source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: "late-deposit", evidence: "合成在途存储边界"),
            payload: original.payload)
        await f.workspace.prepareManual(events: [event])
        let preview = try #require(f.workspace.preview), gate = LedgerTransferGate()
        try #require(preview.canCommit)
        await f.ledgerProbe.gate("commit", gate)
        let saving = Task { await f.workspace.confirm(id: preview.id, expectedRevision: preview.targetRevision) }
        await gate.wait()
        let plan = try await clear(f)
        #expect(await f.transfer.confirm(.init(plan: plan)))
        #expect(f.workspace.isBusy)
        await gate.release(); #expect(await saving.value == false)
        let stored = try await f.ledger.snapshot()
        #expect(stored.accounts.isEmpty && stored.events.isEmpty && stored.batches.isEmpty)
        #expect(f.workspace.snapshot?.accounts.isEmpty == true && !f.workspace.isBusy)
    }
    @Test func exportReadsVerifiedSnapshotAndDiscardedSessionCannotReturnBytes() async throws {
        let f = try await setup()
        let csv = try #require(await f.transfer.export(.transactions))
        let text = try #require(String(data: csv.bytes, encoding: .utf8))
        #expect(text.contains(PortfolioExports.purpose) && csv.contentType.contains("csv"))
        let gate = LedgerTransferGate(); await f.archive.gate("export", gate)
        let task = Task { await f.transfer.export(.backup) }
        await gate.wait(); f.transfer.dismiss(); await gate.release()
        #expect(await task.value == nil)
    }
    @Test func cancelledInitiatorStillFinishesGlobalReservationAndNewPageRefresh() async throws {
        let f = try await setup(), plan = try await clear(f), gate = LedgerTransferGate()
        await f.archive.gate("commit", gate)
        let task = Task { await f.transfer.confirm(.init(plan: plan)) }
        await gate.wait()
        let newlyOpened = LedgerWorkspaceModel(storage: f.ledgerProbe)
        newlyOpened.installTransfer(f.transfer, coordinator: f.coordinator)
        await newlyOpened.load()
        #expect(newlyOpened.isBusy && newlyOpened.snapshot == nil)
        task.cancel(); await gate.release(); _ = await task.value
        #expect(!newlyOpened.isBusy && newlyOpened.snapshot != nil)
        #expect(!f.workspace.isBusy && !f.portfolio.isBusy)
        #expect(!f.coordinator.isTransferring)
    }
}
