import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence
@testable import AppComposition

private enum PortfolioGreeksGateError: Error { case arrivalTimedOut }
private actor PortfolioGreeksGate {
    private var arrived = false, released = false
    private var arrivals: [CheckedContinuation<Void, any Error>] = []
    private var worker: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { worker = $0 } }
    }
    /// A missing arrival is a test failure, never permission to release the worker.
    func wait() async throws {
        guard !arrived else { return }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            failArrival()
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { arrivals.append($0) }
    }
    private func failArrival() {
        guard !arrived else { return }
        arrivals.forEach { $0.resume(throwing: PortfolioGreeksGateError.arrivalTimedOut) }; arrivals.removeAll()
    }
    func release() { released = true; worker?.resume(); worker = nil }
}
private actor PortfolioGreeksLedgerProbe {
    var snapshot: LedgerSnapshot
    var calls = 0
    private var nextGate: PortfolioGreeksGate?
    private var failNext = false
    init(_ snapshot: LedgerSnapshot) { self.snapshot = snapshot }
    func gate(_ value: PortfolioGreeksGate) { nextGate = value }
    func fail() { failNext = true }
    func advance() { snapshot = .init(revision: UUID(), accounts: snapshot.accounts, events: snapshot.events, state: snapshot.state) }
    func read() async throws -> LedgerSnapshot {
        calls += 1
        let result = snapshot, gate = nextGate, fails = failNext
        nextGate = nil; failNext = false
        if let gate { await gate.hold() }
        if fails { throw OptionLabStoreError.injectedFailure }
        return result
    }
}
private actor PortfolioGreeksStoreProbe: PortfolioGreeksStorage {
    let base: PortfolioGreeksStore
    var baselines: [UUID] = []
    private var beforeSave: PortfolioGreeksGate?, afterSave: PortfolioGreeksGate?, afterOpen: PortfolioGreeksGate?
    private var failSave = false, failOpen = false, failList = false, duplicate = false
    init(_ base: PortfolioGreeksStore) { self.base = base }
    func gateBeforeSave(_ value: PortfolioGreeksGate) { beforeSave = value }
    func gateAfterSave(_ value: PortfolioGreeksGate) { afterSave = value }
    func gateAfterOpen(_ value: PortfolioGreeksGate) { afterOpen = value }
    func failSaveOnce() { failSave = true }
    func failOpenOnce() { failOpen = true }
    func failListOnce() { failList = true }
    func duplicateList() { duplicate = true }
    func revision() async throws -> UUID { try await base.revision() }
    func save(_ input: PortfolioGreeksInput, expectedRevision: UUID) async throws -> SavedPortfolioGreeks {
        baselines.append(expectedRevision)
        let before = beforeSave, after = afterSave, fails = failSave
        beforeSave = nil; afterSave = nil; failSave = false
        if let before { await before.hold() }
        if fails { throw OptionLabStoreError.injectedFailure }
        let result = try await base.save(input, expectedRevision: expectedRevision)
        if let after { await after.hold() }
        return result
    }
    func summaries() async throws -> [PortfolioGreeksSummary] {
        if failList { failList = false; throw OptionLabStoreError.corruptedStorage }
        let values = try await base.summaries()
        return duplicate ? values + values : values
    }
    func open(id: UUID) async throws -> SavedPortfolioGreeks {
        if failOpen { failOpen = false; throw OptionLabStoreError.corruptedStorage }
        let result = try await base.open(id: id), gate = afterOpen
        afterOpen = nil; if let gate { await gate.hold() }; return result
    }
}
private actor PortfolioGreeksSourcesProbe: OptionLabStorage {
    let base: OptionLabStore
    private var failList = false, failOpen = false
    private var openGate: PortfolioGreeksGate?
    init(_ base: OptionLabStore) { self.base = base }
    func failListOnce() { failList = true }
    func failOpenOnce() { failOpen = true }
    func gate(_ value: PortfolioGreeksGate) { openGate = value }
    func revision() async throws -> UUID { try await base.revision() }
    func save(id: UUID, input: OptionLabInput, ledgerBasis: OptionLabLedgerBasis?, expectedRevision: UUID) async throws -> SavedOptionLab {
        try await base.save(id: id, input: input, ledgerBasis: ledgerBasis, expectedRevision: expectedRevision)
    }
    func summaries() async throws -> [OptionLabSummary] {
        if failList { failList = false; throw OptionLabStoreError.corruptedStorage }; return try await base.summaries()
    }
    func open(id: UUID) async throws -> SavedOptionLab {
        let fails = failOpen, gate = openGate; failOpen = false; openGate = nil
        let result = try await base.open(id: id)
        if let gate { await gate.hold() }; if fails { throw OptionLabStoreError.corruptedStorage }; return result
    }
}
private actor PortfolioGreeksCalculatorProbe {
    var calls = 0
    private var gate: PortfolioGreeksGate?
    private var fails = false
    func holdNext(_ value: PortfolioGreeksGate, fails: Bool = false) { gate = value; self.fails = fails }
    func calculate(_ input: PortfolioGreeksInput) async throws -> PortfolioGreeksReport {
        calls += 1; let gate = gate, fails = fails; self.gate = nil; self.fails = false
        let result = try PortfolioGreeksEngine.calculate(input)
        if let gate { await gate.hold() }; if fails { throw OptionLabStoreError.injectedFailure }; return result
    }
}

@Suite("Portfolio Greeks explicit evidence and lifecycle boundaries", .timeLimit(.minutes(1))) @MainActor
struct PortfolioGreeksWorkspaceTests {
    private struct Fixture {
        let base: OptionLabStore
        let store: PortfolioGreeksStore
        let probe: PortfolioGreeksStoreProbe
        let sources: PortfolioGreeksSourcesProbe
        let ledger: PortfolioGreeksLedgerProbe
        let calculator: PortfolioGreeksCalculatorProbe
        let model: PortfolioGreeksWorkspaceModel
        let transfer: OptionArchiveTransferModel
        let input: PortfolioGreeksInput
    }
    private func setup() async throws -> Fixture {
        let input = try PortfolioGreeksDemo.input(), base = try OptionLabStore(path: ":memory:")
        let store = try await base.makePortfolioGreeksStore(), probe = PortfolioGreeksStoreProbe(store)
        let sources = PortfolioGreeksSourcesProbe(base), calculator = PortfolioGreeksCalculatorProbe()
        let state = try LedgerEngine.replay(accounts: input.accounts, events: input.events)
        let ledger = PortfolioGreeksLedgerProbe(.init(revision: input.ledgerRevision, accounts: input.accounts, events: input.events, state: state))
        let coordinator = OptionTransferCoordinator()
        let model = PortfolioGreeksWorkspaceModel(storage: probe, experiments: sources,
            ledgerReader: { try await ledger.read() }, coordinator: coordinator,
            calculator: { try await calculator.calculate($0) })
        let archive = try await base.makeArchiveStore(), transfer = OptionArchiveTransferModel(store: archive, coordinator: coordinator)
        return .init(base: base, store: store, probe: probe, sources: sources, ledger: ledger, calculator: calculator,
                     model: model, transfer: transfer, input: input)
    }
    private func prepareLedger(_ f: Fixture) async {
        await f.model.readLedger(); await f.model.configure(accountID: f.input.accountID, asOf: f.input.asOf)
    }
    private func seedSource(_ f: Fixture) async throws -> SavedOptionLab {
        let input = try #require(f.input.reports.first).input
        return try await f.base.save(id: input.id, input: input, expectedRevision: f.base.revision())
    }
    private func clear(_ f: Fixture, replace: Bool = false) async throws {
        await f.transfer.load()
        if replace {
            let empty = try OptionLabStore(path: ":memory:")
            let bytes = try await empty.makeArchiveStore().exportArchive()
            await f.transfer.prepare(bytes, mode: .replace)
        } else { await f.transfer.prepareClear() }
        let plan = try #require(f.transfer.plan)
        #expect(await f.transfer.confirm(.init(plan: plan)))
    }
    @Test func initializationAndCatalogLoadDoNotReadLedgerOrCalculate() async throws {
        let f = try await setup()
        #expect(await f.ledger.calls == 0); #expect(await f.calculator.calls == 0)
        #expect(f.model.report == nil && f.model.saved.isEmpty && !f.model.canSave)
        await f.model.load()
        #expect(await f.ledger.calls == 0); #expect(await f.calculator.calls == 0)
        #expect(f.model.report == nil && f.model.ledgerSnapshot == nil)
    }
    @Test func completeAndMissingSyntheticExamplesKeepCoverageAndNeverReadLedger() async throws {
        let f = try await setup(); await f.model.load(); await f.model.calculateSynthetic(includeMissing: false)
        let complete = try #require(f.model.report)
        #expect(complete.input.mode == .synthetic && complete.coverage.isComplete && complete.completeTotals != nil)
        await f.model.calculateSynthetic(includeMissing: true)
        let missing = try #require(f.model.report)
        #expect(missing.id != complete.id && !missing.coverage.isComplete && missing.completeTotals == nil)
        #expect(missing.coverage.missingPositions == 1 && missing.coveredTotals != nil)
        #expect(await f.ledger.calls == 0 && f.model.ledgerSnapshot == nil)
    }
    @Test func syntheticSaveAndOfflineReopenReplayFrozenInputsWithoutLedgerRead() async throws {
        let f = try await setup(); await f.model.load(); await f.model.calculateSynthetic(includeMissing: true)
        let original = try #require(f.model.report), baseline = try #require(f.model.revision)
        #expect(await f.model.save()); #expect(await f.probe.baselines == [baseline])
        #expect(f.model.savedID == original.id && !f.model.canSave)
        f.model.disappear(); await f.model.load()
        #expect(f.model.report == nil && f.model.saved.count == 1)
        await f.model.open(original.id)
        #expect(f.model.report == original && f.model.savedID == original.id && !f.model.canSave)
        #expect(await f.ledger.calls == 0)
    }
    @Test func completeAndMissingExamplesCanBothFreezeWithoutIdentityConflict() async throws {
        let f = try await setup(); await f.model.calculateSynthetic(includeMissing: false)
        let complete = try #require(f.model.report); #expect(await f.model.save())
        await f.model.calculateSynthetic(includeMissing: true)
        let missing = try #require(f.model.report); #expect(await f.model.save())
        #expect(complete.id != missing.id && f.model.saved.count == 2)
        #expect(try await f.store.open(id: complete.id).report.coverage.isComplete)
        #expect(try await f.store.open(id: missing.id).report.coverage.missingPositions == 1)
    }
    @Test func selectedAccountFreezesOnlyItsOwnLedgerEvidence() async throws {
        let f = try await setup()
        let unrelated = LedgerAccount(id: "unrelated", name: "Not selected")
        let accounts = f.input.accounts + [unrelated]
        let event = LedgerEvent(id: "unrelated-deposit", accountID: unrelated.id, effectiveAt: f.input.asOf,
            source: .init(sourceSystem: "fixture", externalTransactionID: "unrelated-deposit", evidence: "not selected"),
            payload: .cash(.init(kind: .deposit, amount: try Money("12345"))))
        let events = f.input.events + [event]
        let state = try LedgerEngine.replay(accounts: accounts, events: events)
        let ledger = PortfolioGreeksLedgerProbe(.init(revision: UUID(), accounts: accounts, events: events, state: state))
        let model = PortfolioGreeksWorkspaceModel(storage: f.probe, experiments: f.sources, ledgerReader: { try await ledger.read() })
        await model.readLedger(); await model.configure(accountID: f.input.accountID, asOf: f.input.asOf); await model.calculate()
        let input = try #require(model.report).input
        #expect(input.accounts == f.input.accounts && input.events == f.input.events)
        #expect(input.accounts.allSatisfy { $0.id != unrelated.id } && input.events.allSatisfy { $0.accountID != unrelated.id })
    }
    @Test func explicitLedgerReadFailureClearsPriorPositionsAndReport() async throws {
        let f = try await setup(); await prepareLedger(f); await f.model.calculate()
        #expect(f.model.report?.input.mode == .ledger && f.model.report?.coverage.coveredPositions == 0)
        await f.ledger.fail(); await f.model.readLedger()
        #expect(f.model.ledgerSnapshot == nil && f.model.report == nil && f.model.positions.isEmpty && f.model.bindings.isEmpty)
        #expect(f.model.hasError && !f.model.canSave)
    }
    @Test func accountOrTimeEditInvalidatesAcceptedContext() async throws {
        let f = try await setup(); await prepareLedger(f); await f.model.calculate()
        #expect(f.model.canSave && !f.model.positions.isEmpty)
        f.model.draftChanged()
        #expect(f.model.report == nil && f.model.positions.isEmpty && f.model.accountID == nil && f.model.asOf == nil)
        #expect(!f.model.canCalculateLedger && !f.model.canSave && f.model.ledgerSnapshot != nil)
    }
    @Test func evidenceSelectionEditInvalidatesCalculationWithoutInventingBinding() async throws {
        let f = try await setup(); await prepareLedger(f); await f.model.calculate()
        #expect(f.model.canSave && f.model.report != nil)
        let positions = f.model.positions
        f.model.evidenceSelectionChanged()
        #expect(f.model.report == nil && f.model.revision == nil && !f.model.canSave)
        #expect(f.model.positions == positions && f.model.bindings.isEmpty && f.model.canCalculateLedger)
    }
    @Test func metadataSelectionCannotBindUntilFullSourceOpen() async throws {
        let f = try await setup(), source = try await seedSource(f)
        await f.model.load(); await prepareLedger(f)
        let identity = try #require(f.model.positions.first).instrument.identity
        f.model.bind(instrumentIdentity: identity, reportID: source.id, contractID: nil)
        #expect(f.model.bindings.isEmpty && f.model.verifiedSources.isEmpty && f.model.sources.count == 1)
        await f.model.openSource(source.id)
        f.model.bind(instrumentIdentity: identity, reportID: source.id, contractID: nil)
        #expect(f.model.bindings.count == 1 && f.model.verifiedSources.count == 1)
    }
    @Test func failedSourceReopenRemovesItsOldEvidenceAndBindings() async throws {
        let f = try await setup(), source = try await seedSource(f)
        await prepareLedger(f); await f.model.openSource(source.id)
        let identity = try #require(f.model.positions.first).instrument.identity
        f.model.bind(instrumentIdentity: identity, reportID: source.id, contractID: nil)
        await f.sources.failOpenOnce(); await f.model.openSource(source.id)
        #expect(f.model.verifiedSources.isEmpty && f.model.bindings.isEmpty && f.model.sourceError != nil)
        #expect(f.model.report == nil && !f.model.canSave)
    }
    @Test func syntheticSourceCannotFillAnOrdinaryLedgerGap() async throws {
        let f = try await setup(), source = try await seedSource(f)
        await prepareLedger(f); await f.model.openSource(source.id)
        let binding = try #require(f.input.bindings.first)
        f.model.bind(instrumentIdentity: binding.instrumentIdentity, reportID: source.id, contractID: binding.contractID)
        await f.model.calculate()
        #expect(f.model.report == nil && f.model.hasError && !f.model.canSave)
        #expect(f.model.message == PortfolioGreeksError.syntheticEvidence.errorDescription)
    }
    @Test func lateCalculationAfterLeaveDoesNotOverwriteNewPageOrBusy() async throws {
        let f = try await setup(), oldGate = PortfolioGreeksGate(), nextGate = PortfolioGreeksGate()
        await f.calculator.holdNext(oldGate, fails: true)
        let old = Task { await f.model.calculateSynthetic(includeMissing: false) }
        try await oldGate.wait(); f.model.disappear(); await f.model.load()
        await f.calculator.holdNext(nextGate)
        let next = Task { await f.model.calculateSynthetic(includeMissing: true) }
        try await nextGate.wait(); await oldGate.release(); await old.value
        #expect(f.model.isBusy && f.model.report == nil && !f.model.hasError)
        await nextGate.release(); await next.value
        #expect(f.model.report?.coverage.missingPositions == 1 && !f.model.isBusy && !f.model.hasError)
    }
    @Test func cancelledNonCooperativeReadCannotRestoreLedgerSelection() async throws {
        let f = try await setup(), gate = PortfolioGreeksGate()
        await f.ledger.gate(gate)
        let read = Task { await f.model.readLedger() }
        try await gate.wait(); f.model.cancel(); await f.model.calculateSynthetic(includeMissing: false)
        let report = f.model.report
        await gate.release(); await read.value
        #expect(f.model.report == report && f.model.ledgerSnapshot == nil && !f.model.isBusy)
    }
    @Test func ledgerChangeDuringCalculationPreventsPublishingOldPortfolio() async throws {
        let f = try await setup(), gate = PortfolioGreeksGate(); await prepareLedger(f)
        await f.calculator.holdNext(gate)
        let calculating = Task { await f.model.calculate() }
        try await gate.wait(); await f.ledger.advance(); await gate.release(); await calculating.value
        #expect(f.model.report == nil && f.model.positions.isEmpty && !f.model.canSave && f.model.hasError)
    }
    @Test func ledgerChangeBeforeSaveRejectsWithoutCallingOptionStorage() async throws {
        let f = try await setup(); await prepareLedger(f); await f.model.calculate()
        #expect(f.model.canSave); await f.ledger.advance()
        #expect(await f.model.save() == false)
        #expect(await f.probe.baselines.isEmpty && f.model.report == nil && f.model.revision == nil)
        #expect(try await f.store.summaries().isEmpty)
    }
    @Test func savedHistoricalReportKeepsOldBasisWhenExplicitLedgerCheckFindsChange() async throws {
        let f = try await setup(); await prepareLedger(f); await f.model.calculate(); #expect(await f.model.save())
        let original = try #require(f.model.report)
        await f.ledger.advance(); await f.model.checkLedgerRevision()
        #expect(f.model.report == original && f.model.savedID == original.id)
        #expect(f.model.currentLedgerRevision != original.input.ledgerRevision && !f.model.canSave)
        #expect(f.model.message?.contains("历史报告") == true)
    }
    @Test func ordinaryFailureRetainsOriginalOptionWriteBasisForRetry() async throws {
        let f = try await setup(); await f.model.calculateSynthetic(includeMissing: true)
        let baseline = try #require(f.model.revision), report = try #require(f.model.report)
        await f.probe.failSaveOnce(); #expect(await f.model.save() == false)
        #expect(f.model.report == report && f.model.revision == baseline && f.model.canSave && f.model.savedID == nil)
        #expect(await f.model.save()); #expect(await f.probe.baselines == [baseline, baseline])
    }
    private func lateSaveRejected(replace: Bool) async throws {
        let f = try await setup(), gate = PortfolioGreeksGate(); await f.model.load(); await f.model.calculateSynthetic(includeMissing: true)
        let baseline = try #require(f.model.revision)
        await f.probe.gateBeforeSave(gate)
        let saving = Task { await f.model.save() }; try await gate.wait()
        #expect(!f.model.canCancel)
        try await clear(f, replace: replace); await gate.release(); #expect(await saving.value == false)
        #expect(await f.probe.baselines == [baseline]); #expect(try await f.store.summaries().isEmpty)
        #expect(f.model.report == nil && f.model.savedID == nil && !f.model.isBusy && !f.model.hasError)
    }
    @Test func clearRejectsQueuedSaveWithOriginalCAS() async throws { try await lateSaveRejected(replace: false) }
    @Test func replacementRejectsQueuedSaveWithOriginalCAS() async throws { try await lateSaveRejected(replace: true) }
    @Test func completedSaveAfterPageLeaveCannotPublishButStillExists() async throws {
        let f = try await setup(), gate = PortfolioGreeksGate(); await f.model.calculateSynthetic(includeMissing: false)
        let id = try #require(f.model.report).id
        await f.probe.gateAfterSave(gate)
        let saving = Task { await f.model.save() }; try await gate.wait()
        f.model.disappear(); await f.model.load(); #expect(f.model.isBusy && f.model.report == nil)
        await gate.release(); #expect(await saving.value)
        #expect(f.model.report == nil && f.model.savedID == nil && !f.model.isBusy)
        #expect(f.model.saved.map(\.id) == [id]); #expect(try await f.store.open(id: id).replayMatched)
    }
    @Test func clearRejectsLateOpenAndSourceOpenResults() async throws {
        let f = try await setup(); await f.model.calculateSynthetic(includeMissing: false); #expect(await f.model.save())
        let id = try #require(f.model.savedID), gate = PortfolioGreeksGate()
        await f.probe.gateAfterOpen(gate)
        let opening = Task { await f.model.open(id) }; try await gate.wait(); try await clear(f)
        await gate.release(); await opening.value
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.saved.isEmpty && !f.model.isBusy)
        let source = try await seedSource(f), sourceGate = PortfolioGreeksGate()
        await f.sources.gate(sourceGate)
        let sourceOpen = Task { await f.model.openSource(source.id) }; try await sourceGate.wait(); try await clear(f)
        await sourceGate.release(); await sourceOpen.value
        #expect(f.model.verifiedSources.isEmpty && f.model.sources.isEmpty && f.model.bindings.isEmpty)
    }
    @Test func failedOrDuplicateCatalogDoesNotRetainOldRows() async throws {
        let f = try await setup(); await f.model.calculateSynthetic(includeMissing: false); #expect(await f.model.save())
        await f.probe.failListOnce(); await f.model.load()
        #expect(f.model.saved.isEmpty && f.model.listError != nil && f.model.report == nil)
        await f.probe.duplicateList(); await f.model.load()
        #expect(f.model.saved.isEmpty && f.model.listError != nil && !f.model.canSave)
    }
    @Test func sourceCatalogFailureIsIndependentOfHealthySavedPortfolioCatalog() async throws {
        let f = try await setup(); await f.model.calculateSynthetic(includeMissing: false); #expect(await f.model.save())
        _ = try await seedSource(f); await f.sources.failListOnce(); await f.model.load()
        #expect(f.model.saved.count == 1 && f.model.listError == nil && f.model.sourceError != nil)
        #expect(f.model.sources.isEmpty && f.model.verifiedSources.isEmpty && f.model.report == nil)
    }
    @Test func invalidSnapshotOpenDoesNotRetainPreviouslyVisibleNumbers() async throws {
        let f = try await setup(); await f.model.calculateSynthetic(includeMissing: true); #expect(await f.model.save())
        let id = try #require(f.model.savedID); await f.probe.failOpenOnce(); await f.model.open(id)
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.hasError)
    }
}
