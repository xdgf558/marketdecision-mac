import Foundation
import Testing
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence
@testable import AppComposition

private actor EvidenceGate {
    private var arrived = false, released = false
    private var worker: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, any Error>?
    func hold() async {
        arrived = true; waiter?.resume(); waiter = nil
        if !released { await withCheckedContinuation { worker = $0 } }
    }
    func wait() async throws {
        guard !arrived else { return }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            timeout()
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    private func timeout() { waiter?.resume(throwing: OptionLabStoreError.notFound); waiter = nil }
    func release() { released = true; worker?.resume(); worker = nil }
}
private actor EvidenceStoreProbe: OptionEvidenceStorage {
    let base: OptionEvidenceStore
    var openGate: EvidenceGate?, saveGate: EvidenceGate?
    var failList = false, failOpen = false, failSave = false, duplicate = false
    init(_ base: OptionEvidenceStore) { self.base = base }
    func gateOpen(_ gate: EvidenceGate) { openGate = gate }
    func gateSave(_ gate: EvidenceGate) { saveGate = gate }
    func failures(list: Bool = false, open: Bool = false, save: Bool = false, duplicate: Bool = false) {
        failList = list; failOpen = open; failSave = save; self.duplicate = duplicate
    }
    func revision() async throws -> UUID { try await base.revision() }
    func summaries() async throws -> [OptionEvidenceSummary] {
        if failList { throw OptionLabStoreError.corruptedStorage }
        let rows = try await base.summaries(); return duplicate ? rows + rows : rows
    }
    func open(id: UUID) async throws -> SavedOptionEvidence {
        let value = try await base.open(id: id), gate = openGate, fail = failOpen; openGate = nil
        if let gate { await gate.hold() }; if fail { throw OptionLabStoreError.corruptedStorage }; return value
    }
    func save(_ input: OptionEvidenceInput, expectedRevision: UUID) async throws -> SavedOptionEvidence {
        let gate = saveGate; saveGate = nil
        if let gate { await gate.hold() }
        if failSave { throw OptionLabStoreError.injectedFailure }
        return try await base.save(input, expectedRevision: expectedRevision)
    }
}
@Suite("Offline option evidence page ownership", .timeLimit(.minutes(1))) @MainActor
struct OptionEvidenceWorkspaceTests {
    private struct Fixture {
        let base: OptionLabStore
        let store: OptionEvidenceStore
        let probe: EvidenceStoreProbe
        let model: OptionEvidenceWorkspaceModel
        let transfer: OptionArchiveTransferModel
    }
    private func setup(gate: EvidenceGate? = nil, fails: Bool = false) async throws -> Fixture {
        let base = try OptionLabStore(path: ":memory:"), store = try await base.makeEvidenceStore()
        let probe = EvidenceStoreProbe(store), coordinator = OptionTransferCoordinator()
        let model = OptionEvidenceWorkspaceModel(storage: probe, coordinator: coordinator, calculator: { input in
            let report = try OptionEvidenceEngine.calculate(input)
            if let gate { await gate.hold() }
            if fails { throw OptionLabStoreError.injectedFailure }
            return report
        })
        let transfer = OptionArchiveTransferModel(store: try await base.makeArchiveStore(), coordinator: coordinator)
        return .init(base: base, store: store, probe: probe, model: model, transfer: transfer)
    }
    private func calculate(_ f: Fixture, kind: OptionEvidenceKind = .providerComparison) async throws {
        let text = try OptionEvidenceWorkspaceModel.demoJSON(kind)
        await f.model.calculateJSON(text, kind: kind)
    }
    private func clear(_ f: Fixture, replace: Bool) async throws {
        await f.transfer.load()
        if replace {
            let empty = try OptionLabStore(path: ":memory:")
            let bytes = try await empty.makeArchiveStore().exportArchive()
            await f.transfer.prepare(bytes, mode: .replace)
        } else { await f.transfer.prepareClear() }
        let plan = try #require(f.transfer.plan)
        #expect(await f.transfer.confirm(.init(plan: plan)))
    }
    @Test(arguments: OptionEvidenceKind.allCases) func completeOfflineFlow(_ kind: OptionEvidenceKind) async throws {
        let f = try await setup(); await f.model.load()
        #expect(f.model.report == nil && !f.model.canSave)
        try await calculate(f, kind: kind)
        let candidate = try #require(f.model.report)
        #expect(candidate.input.kind == kind && candidate.containsSynthetic && f.model.canSave)
        #expect(await f.model.save())
        #expect(f.model.savedID == candidate.id && !f.model.canSave)
        f.model.draftChanged(); #expect(f.model.report == nil)
        await f.model.open(candidate.id)
        #expect(f.model.report == candidate && f.model.savedID == candidate.id)
    }
    @Test func malformedAndWrongKindClearPreviousResult() async throws {
        let f = try await setup(); try await calculate(f)
        await f.model.calculateJSON("not json", kind: .providerComparison)
        #expect(f.model.report == nil && f.model.hasError && !f.model.canSave)
        let text = try OptionEvidenceWorkspaceModel.demoJSON(.providerComparison)
        await f.model.calculateJSON(text, kind: .delta25)
        #expect(f.model.report == nil && f.model.hasError)
    }
    @Test(arguments: [false, true]) func editDropsLateCalculationAndError(_ fails: Bool) async throws {
        let gate = EvidenceGate(), f = try await setup(gate: gate, fails: fails)
        let task = Task { try await calculate(f) }
        do { try await gate.wait() } catch { await gate.release(); _ = try? await task.value; throw error }
        f.model.draftChanged(); await gate.release(); try await task.value
        #expect(f.model.report == nil && !f.model.hasError && !f.model.isBusy && f.model.message == nil)
    }
    @Test func cancelDropsLateCalculation() async throws {
        let gate = EvidenceGate(), f = try await setup(gate: gate)
        let task = Task { try await calculate(f) }
        do { try await gate.wait() } catch { await gate.release(); _ = try? await task.value; throw error }
        f.model.cancel(); let message = f.model.message
        await gate.release(); try await task.value
        #expect(f.model.report == nil && f.model.message == message && !f.model.isBusy)
    }
    @Test(arguments: [false, true]) func transferInvalidatesLateOpen(_ replace: Bool) async throws {
        let f = try await setup(); try await calculate(f); #expect(await f.model.save())
        let id = try #require(f.model.savedID), gate = EvidenceGate()
        await f.probe.gateOpen(gate)
        let task = Task { await f.model.open(id) }
        do { try await gate.wait() } catch { await gate.release(); await task.value; throw error }
        try await clear(f, replace: replace)
        await gate.release(); await task.value
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.saved.isEmpty && !f.model.isBusy)
    }
    @Test(arguments: [false, true]) func transferRejectsQueuedOldSave(_ replace: Bool) async throws {
        let f = try await setup(); try await calculate(f)
        let gate = EvidenceGate(); await f.probe.gateSave(gate)
        let task = Task { await f.model.save() }
        do { try await gate.wait() } catch { await gate.release(); _ = await task.value; throw error }
        try await clear(f, replace: replace)
        await gate.release(); #expect(await task.value == false)
        #expect(try await f.store.summaries().isEmpty)
        #expect(f.model.report == nil && f.model.saved.isEmpty && !f.model.isBusy)
    }
    @Test func leavingDoesNotPublishSuccessfulCommitAndReappearReloads() async throws {
        let f = try await setup(); try await calculate(f)
        let gate = EvidenceGate(); await f.probe.gateSave(gate)
        let task = Task { await f.model.save() }
        do { try await gate.wait() } catch { await gate.release(); _ = await task.value; throw error }
        f.model.disappear(); await f.model.load()
        await gate.release(); #expect(await task.value)
        #expect(f.model.report == nil && f.model.savedID == nil && !f.model.isBusy)
        #expect(f.model.saved.count == 1)
    }
    @Test func failedSaveRetainsOriginalBasisForRetry() async throws {
        let f = try await setup(); try await calculate(f); let baseline = f.model.revision
        await f.probe.failures(save: true); #expect(await f.model.save() == false)
        #expect(f.model.canSave && f.model.revision == baseline && f.model.savedID == nil)
        await f.probe.failures(); #expect(await f.model.save())
    }
    @Test func catalogFailureDoesNotEraseCommittedReport() async throws {
        let f = try await setup(); try await calculate(f)
        await f.probe.failures(list: true); #expect(await f.model.save())
        #expect(f.model.savedID != nil && f.model.report != nil && f.model.listError != nil && f.model.saved.isEmpty)
    }
    @Test func duplicateDirectoryAndFailedOpenNeverDisplayCachedNumbers() async throws {
        let f = try await setup(); try await calculate(f); #expect(await f.model.save())
        let id = try #require(f.model.savedID)
        await f.probe.failures(duplicate: true); await f.model.load()
        #expect(f.model.saved.isEmpty && f.model.listError != nil && f.model.report == nil)
        await f.probe.failures(open: true); await f.model.open(id)
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.hasError)
    }
}
