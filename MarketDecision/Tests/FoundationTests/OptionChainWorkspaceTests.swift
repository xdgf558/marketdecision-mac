import Foundation
import Testing
import CoreDomain
import DataContracts
import MarketDataProviders
import OptionsAnalytics
@testable import Persistence
@testable import AppComposition

/// Explicit arrival/release handshake. Cancellation deliberately cannot release
/// this gate: the caller must reject a non-cooperative result after it returns.
private actor ChainWorkspaceGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var worker: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }; arrivalWaiters.removeAll()
        if !released { await withCheckedContinuation { worker = $0 } }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }
    func release() { released = true; worker?.resume(); worker = nil }
}
private enum ChainWorkspaceProbeError: Error { case injected, unexpectedCall }
private actor ChainWorkspaceCollector {
    struct Step: Sendable {
        let capture: OptionChainCapture
        let gate: ChainWorkspaceGate?
        let fails: Bool
        init(_ capture: OptionChainCapture, gate: ChainWorkspaceGate? = nil, fails: Bool = false) {
            self.capture = capture; self.gate = gate; self.fails = fails
        }
    }
    private let steps: [Step]
    private(set) var calls = 0
    init(_ steps: [Step]) { self.steps = steps }
    func collect() async throws -> OptionChainCapture {
        guard calls < steps.count else { throw ChainWorkspaceProbeError.unexpectedCall }
        let step = steps[calls]; calls += 1
        if let gate = step.gate { await gate.hold() }
        if step.fails { throw ChainWorkspaceProbeError.injected }
        return step.capture
    }
}
private actor ChainWorkspaceStoreProbe: OptionChainStorage {
    let base: OptionChainStore
    var beforeSave: ChainWorkspaceGate?
    var afterSave: ChainWorkspaceGate?
    var afterOpen: ChainWorkspaceGate?
    var listFails = false
    var openFails = false
    var duplicateList = false
    private(set) var saveBaselines: [UUID] = []
    init(_ base: OptionChainStore) { self.base = base }
    func gateBeforeSave(_ value: ChainWorkspaceGate) { beforeSave = value }
    func gateAfterSave(_ value: ChainWorkspaceGate) { afterSave = value }
    func gateAfterOpen(_ value: ChainWorkspaceGate) { afterOpen = value }
    func failList(_ value: Bool) { listFails = value }
    func failOpen(_ value: Bool) { openFails = value }
    func duplicateCatalog(_ value: Bool) { duplicateList = value }
    func revision() async throws -> UUID { try await base.revision() }
    func save(_ capture: OptionChainCapture, expectedRevision: UUID) async throws -> SavedOptionChain {
        saveBaselines.append(expectedRevision)
        if let gate = beforeSave { beforeSave = nil; await gate.hold() }
        let result = try await base.save(capture, expectedRevision: expectedRevision)
        if let gate = afterSave { afterSave = nil; await gate.hold() }
        return result
    }
    func summaries() async throws -> [OptionChainSummary] {
        if listFails { throw OptionLabStoreError.corruptedStorage }
        let values = try await base.summaries()
        return duplicateList ? values + values : values
    }
    func open(id: UUID) async throws -> SavedOptionChain {
        if openFails { throw OptionLabStoreError.corruptedStorage }
        let result = try await base.open(id: id)
        if let gate = afterOpen { afterOpen = nil; await gate.hold() }
        return result
    }
}

private actor ChainLabRevisionProbe: OptionLabStorage {
    let base: OptionLabStore
    private var nextRevisionGate: ChainWorkspaceGate?
    init(_ base: OptionLabStore) { self.base = base }
    func holdNextRevision(_ gate: ChainWorkspaceGate) { nextRevisionGate = gate }
    func revision() async throws -> UUID {
        let gate = nextRevisionGate; nextRevisionGate = nil
        let baseline = try await base.revision()
        if let gate { await gate.hold() }
        return baseline
    }
    func save(id: UUID, input: OptionLabInput, ledgerBasis: OptionLabLedgerBasis?, expectedRevision: UUID) async throws -> SavedOptionLab {
        try await base.save(id: id, input: input, ledgerBasis: ledgerBasis, expectedRevision: expectedRevision)
    }
    func summaries() async throws -> [OptionLabSummary] { try await base.summaries() }
    func open(id: UUID) async throws -> SavedOptionLab { try await base.open(id: id) }
}

@Suite("Option chain explicit collection and transfer session boundaries") @MainActor
struct OptionChainWorkspaceTests {
    private struct Fixture {
        let base: OptionLabStore
        let chain: OptionChainStore
        let archive: OptionLabArchiveStore
        let probe: ChainWorkspaceStoreProbe
        let model: OptionChainWorkspaceModel
        let transfer: OptionArchiveTransferModel
        let coordinator: OptionTransferCoordinator
    }
    private func setup(_ collector: ChainWorkspaceCollector) async throws -> Fixture {
        let base = try OptionLabStore(path: ":memory:")
        let chain = try await base.makeChainStore(), archive = try await base.makeArchiveStore()
        let probe = ChainWorkspaceStoreProbe(chain), coordinator = OptionTransferCoordinator()
        let model = OptionChainWorkspaceModel(storage: probe, coordinator: coordinator, collector: { try await collector.collect() })
        let transfer = OptionArchiveTransferModel(store: archive, coordinator: coordinator)
        await model.load(); await transfer.load()
        return .init(base: base, chain: chain, archive: archive, probe: probe, model: model, transfer: transfer, coordinator: coordinator)
    }
    private func clear(_ fixture: Fixture) async throws {
        await fixture.transfer.load(); await fixture.transfer.prepareClear()
        let plan = try #require(fixture.transfer.plan)
        #expect(await fixture.transfer.confirm(.init(plan: plan)))
    }
    private func replaceWithEmptyArchive(_ fixture: Fixture) async throws {
        let empty = try OptionLabStore(path: ":memory:")
        let bytes = try await empty.makeArchiveStore().exportArchive()
        await fixture.transfer.load(); await fixture.transfer.prepare(bytes, mode: .replace)
        let plan = try #require(fixture.transfer.plan)
        #expect(await fixture.transfer.confirm(.init(plan: plan)))
    }

    @Test func initializationAndCatalogLoadNeverCollect() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let collector = ChainWorkspaceCollector([.init(capture)])
        let chain = try OptionChainStore(path: ":memory:")
        let model = OptionChainWorkspaceModel(storage: chain, collector: { try await collector.collect() })
        #expect(await collector.calls == 0)
        #expect(model.capture == nil && model.saved.isEmpty && !model.canSave)
        await model.load(); await model.load()
        #expect(await collector.calls == 0)
        #expect(model.capture == nil && model.revision != nil && !model.isBusy)
    }

    @Test func explicitCollectionSaveAndOpenReplayTheSameSource() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let collector = ChainWorkspaceCollector([.init(capture)]), fixture = try await setup(collector)
        await fixture.model.loadSynthetic()
        #expect(await collector.calls == 1)
        #expect(fixture.model.capture == capture && fixture.model.canSave && fixture.model.savedID == nil)
        let original = try #require(fixture.model.revision)
        #expect(await fixture.model.saveCapture())
        #expect(fixture.model.savedID == capture.id && fixture.model.saved.count == 1 && !fixture.model.canSave)
        #expect(await fixture.probe.saveBaselines == [original])
        fixture.model.disappear(); await fixture.model.load()
        #expect(fixture.model.capture == nil && fixture.model.savedID == nil && fixture.model.saved.count == 1)
        await fixture.model.open(capture.id)
        #expect(fixture.model.capture == capture && fixture.model.savedID == capture.id && !fixture.model.canSave)
        #expect(await collector.calls == 1) // Offline reopen never calls a provider.
    }

    @Test func cancelledNonCooperativeCollectionCannotReleaseOrOverwriteNewOperation() async throws {
        let first = try await OptionChainSyntheticCollection.capture(), next = try await OptionChainSyntheticCollection.capture()
        let oldGate = ChainWorkspaceGate(), newGate = ChainWorkspaceGate()
        let collector = ChainWorkspaceCollector([.init(first, gate: oldGate), .init(next, gate: newGate)])
        let fixture = try await setup(collector)
        let old = Task { await fixture.model.loadSynthetic() }
        await oldGate.waitForArrival(); fixture.model.cancel()
        let current = Task { await fixture.model.loadSynthetic() }
        await newGate.waitForArrival()
        await oldGate.release(); await old.value
        #expect(fixture.model.isBusy && fixture.model.capture == nil && fixture.model.savedID == nil)
        await newGate.release(); await current.value
        #expect(fixture.model.capture == next && !fixture.model.isBusy && !fixture.model.hasError)
        #expect(fixture.model.canSave)
        #expect(await collector.calls == 2)
    }

    @Test func disappearedCollectionLateFailureDoesNotPublishIntoReopenedPage() async throws {
        let first = try await OptionChainSyntheticCollection.capture(), next = try await OptionChainSyntheticCollection.capture()
        let gate = ChainWorkspaceGate()
        let collector = ChainWorkspaceCollector([.init(first, gate: gate, fails: true), .init(next)])
        let fixture = try await setup(collector)
        let old = Task { await fixture.model.loadSynthetic() }
        await gate.waitForArrival(); fixture.model.disappear(); await fixture.model.load(); await fixture.model.loadSynthetic()
        let currentMessage = fixture.model.message
        await gate.release(); await old.value
        #expect(fixture.model.capture == next && fixture.model.message == currentMessage)
        #expect(!fixture.model.isBusy && !fixture.model.hasError && fixture.model.savedID == nil)
    }

    @Test func failedRefreshClearsPriorQuoteButKeepsCatalogMetadata() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let collector = ChainWorkspaceCollector([.init(capture), .init(capture, fails: true)])
        let fixture = try await setup(collector)
        await fixture.model.loadSynthetic(); #expect(await fixture.model.saveCapture())
        await fixture.model.loadSynthetic()
        #expect(fixture.model.hasError && fixture.model.capture == nil && fixture.model.savedID == nil)
        #expect(fixture.model.saved.map(\.id) == [capture.id] && !fixture.model.canSave)
    }

    @Test func clearInvalidatesAlreadyStartedCollection() async throws {
        let capture = try await OptionChainSyntheticCollection.capture(), gate = ChainWorkspaceGate()
        let collector = ChainWorkspaceCollector([.init(capture, gate: gate)])
        let fixture = try await setup(collector), prior = try #require(fixture.model.revision)
        let collecting = Task { await fixture.model.loadSynthetic() }
        await gate.waitForArrival(); try await clear(fixture)
        let current = try #require(fixture.model.revision)
        #expect(prior != current && fixture.model.capture == nil && !fixture.model.isBusy)
        await gate.release(); await collecting.value
        #expect(fixture.model.capture == nil && fixture.model.revision == current && !fixture.model.canSave)
        #expect(await fixture.model.saveCapture() == false)
        #expect(try await fixture.chain.summaries().isEmpty)
    }

    private func assertLateSaveRejected(replace: Bool) async throws {
        let capture = try await OptionChainSyntheticCollection.capture(), gate = ChainWorkspaceGate()
        let collector = ChainWorkspaceCollector([.init(capture)]), fixture = try await setup(collector)
        await fixture.model.loadSynthetic(); let baseline = try #require(fixture.model.revision)
        await fixture.probe.gateBeforeSave(gate)
        let saving = Task { await fixture.model.saveCapture() }
        await gate.waitForArrival()
        if replace { try await replaceWithEmptyArchive(fixture) } else { try await clear(fixture) }
        #expect(try await fixture.chain.summaries().isEmpty)
        await gate.release(); #expect(await saving.value == false)
        #expect(await fixture.probe.saveBaselines == [baseline])
        #expect(try await fixture.chain.summaries().isEmpty)
        #expect(fixture.model.capture == nil && fixture.model.savedID == nil && fixture.model.saved.isEmpty && !fixture.model.isBusy)
        #expect(fixture.model.revision != baseline && !fixture.model.hasError)
    }
    @Test func clearRejectsLateSaveUsingItsOriginalWriteRevision() async throws { try await assertLateSaveRejected(replace: false) }
    @Test func replacementRejectsLateSaveUsingItsOriginalWriteRevision() async throws { try await assertLateSaveRejected(replace: true) }

    @Test func completedOldSaveNeverPublishesCaptureIntoReopenedPage() async throws {
        let capture = try await OptionChainSyntheticCollection.capture(), gate = ChainWorkspaceGate()
        let collector = ChainWorkspaceCollector([.init(capture)]), fixture = try await setup(collector)
        await fixture.model.loadSynthetic(); await fixture.probe.gateAfterSave(gate)
        let saving = Task { await fixture.model.saveCapture() }
        await gate.waitForArrival()
        #expect(try await fixture.chain.summaries().count == 1)
        fixture.model.disappear(); await fixture.model.load()
        #expect(fixture.model.capture == nil && fixture.model.savedID == nil && fixture.model.isBusy)
        await gate.release(); #expect(await saving.value)
        #expect(fixture.model.capture == nil && fixture.model.savedID == nil && fixture.model.message == nil)
        #expect(fixture.model.saved.map(\.id) == [capture.id] && !fixture.model.isBusy)
    }

    @Test func catalogFailureDoesNotEraseSuccessfullySavedCapture() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
        await fixture.model.loadSynthetic(); await fixture.probe.failList(true)
        #expect(await fixture.model.saveCapture())
        #expect(fixture.model.capture == capture && fixture.model.savedID == capture.id)
        #expect(fixture.model.listError != nil && fixture.model.saved.isEmpty && !fixture.model.hasError)
        await fixture.probe.failList(false); await fixture.model.load()
        #expect(fixture.model.listError == nil && fixture.model.saved.map(\.id) == [capture.id])
    }

    @Test func damagedOpenDoesNotEraseHealthyCatalogOrShowOldCapture() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
        await fixture.model.loadSynthetic(); #expect(await fixture.model.saveCapture())
        await fixture.probe.failOpen(true); await fixture.model.open(capture.id)
        #expect(fixture.model.hasError && fixture.model.capture == nil && fixture.model.savedID == nil)
        #expect(fixture.model.listError == nil && fixture.model.saved.map(\.id) == [capture.id])
    }

    @Test func openRequiresUnchangedStorageRevisionBeforePublishing() async throws {
        let capture = try await OptionChainSyntheticCollection.capture(), other = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)])), gate = ChainWorkspaceGate()
        await fixture.model.loadSynthetic(); #expect(await fixture.model.saveCapture())
        await fixture.probe.gateAfterOpen(gate)
        let opening = Task { await fixture.model.open(capture.id) }
        await gate.waitForArrival()
        _ = try await fixture.chain.save(other, expectedRevision: fixture.chain.revision())
        await gate.release(); await opening.value
        #expect(fixture.model.hasError && fixture.model.capture == nil && fixture.model.savedID == nil)
        #expect(!fixture.model.isBusy && !fixture.model.canSave)
    }

    @Test func staleSaveRetainsInputWithoutAdoptingLaterRevision() async throws {
        let capture = try await OptionChainSyntheticCollection.capture(), other = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
        await fixture.model.loadSynthetic(); let before = try #require(fixture.model.revision)
        _ = try await fixture.chain.save(other, expectedRevision: fixture.chain.revision())
        #expect(await fixture.model.saveCapture() == false)
        #expect(fixture.model.capture == capture && fixture.model.revision == nil && !fixture.model.canSave)
        #expect(fixture.model.hasError)
        #expect(await fixture.probe.saveBaselines == [before])
    }

    @Test func duplicateCatalogIdentitiesAreNotPublished() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
        await fixture.model.loadSynthetic(); #expect(await fixture.model.saveCapture())
        await fixture.probe.duplicateCatalog(true); await fixture.model.load()
        #expect(fixture.model.listError != nil && fixture.model.saved.isEmpty && fixture.model.capture == nil)
    }

    private func draft(_ fixture: Fixture, capture: OptionChainCapture) throws -> OptionLabInputDraft {
        let short = try #require(capture.snapshot.contracts.first { $0.right == .put })
        var value = try fixture.model.makeDraft(strategy: .cashSecuredPut, shortID: short.recordID, longID: nil, quantity: 1)
        value.shortLeg.tick = "0.01"; value.settlementAt = short.expiration.iso8601 + "T21:00:00.000Z"
        value.expiryReference = "synthetic-user-selected-settlement"
        value.cashBeforeTrade = "20000"; value.committedCash = "0"
        value.availableShares = "100"; value.committedShares = "0"
        value.capitalReference = "synthetic-user-selected-capital"; value.scenarioPrices = "90\n100\n110"
        return value
    }
    private func settlements(_ capture: OptionChainCapture) throws -> [String: Date] {
        let formatter = ISO8601DateFormatter()
        return try Dictionary(uniqueKeysWithValues: capture.requestedExpirations.map { date in
            (date.iso8601, try #require(formatter.date(from: date.iso8601 + "T21:00:00Z")))
        })
    }
    private func installLab(_ fixture: Fixture, storage: any OptionLabStorage) async throws -> OptionLabWorkspaceModel {
        let dailyStore = try await fixture.base.makeDailyStore()
        let history = OptionHistoryWorkspaceModel(storage: dailyStore, coordinator: fixture.coordinator)
        let lab = OptionLabWorkspaceModel(storage: storage)
        lab.install(history: history, transfer: fixture.transfer, coordinator: fixture.coordinator)
        lab.installChain(fixture.model); await lab.load()
        return lab
    }

    @Test func savedChainStartsNewDraftBaselineThenCalculatesAndSavesRealExperiment() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
        let lab = try await installLab(fixture, storage: fixture.base)
        let original = try #require(lab.revision)
        await fixture.model.loadSynthetic(); #expect(await fixture.model.saveCapture())
        let afterCapture = try await fixture.chain.revision()
        #expect(afterCapture != original && lab.revision == original)
        let value = try draft(fixture, capture: capture)
        try await lab.prepareChainDraft(value)
        #expect(lab.revision == afterCapture && lab.report == nil && !lab.isBusy)
        let input = try value.build(createdAt: capture.createdAt)
        await lab.calculate(input)
        #expect(lab.report?.input.chainEvidence?.capture == capture && lab.canSave)
        #expect(await lab.save())
        let savedID = try #require(lab.savedID), reopened = try await fixture.base.open(id: savedID)
        #expect(reopened.report.input == input && reopened.replayMatched)
        #expect(try await fixture.chain.open(id: capture.id).capture == capture)
    }

    @Test func dailyHandoffRequiresSavedCaptureAndFreshHistoryBaseline() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
        let dailyStore = try await fixture.base.makeDailyStore()
        let history = OptionHistoryWorkspaceModel(storage: dailyStore, coordinator: fixture.coordinator)
        await history.load(); let original = try #require(history.revision)
        await fixture.model.loadSynthetic()
        let dates = try settlements(capture)
        #expect(throws: OptionLabDraftError.missingField) {
            try fixture.model.makeDailyInput(rate: Money("0.05"), dividendYield: Money("0.01"), settlements: dates,
                tick: Money("0.01"), assumptionReference: "synthetic-explicit-daily", declaredClose: true)
        }
        #expect(try await dailyStore.dailySummaries().isEmpty)
        #expect(await fixture.model.saveCapture())
        let afterCapture = try await dailyStore.revision()
        #expect(afterCapture != original && history.revision == original)
        await history.load()
        #expect(history.revision == afterCapture)
        let input = try fixture.model.makeDailyInput(rate: Money("0.05"), dividendYield: Money("0.01"), settlements: dates,
            tick: Money("0.01"), assumptionReference: "synthetic-explicit-daily", declaredClose: true)
        await history.calculateDaily(input)
        #expect(history.canSaveDaily && history.dailyReport?.input.chainEvidence == capture)
        #expect(await history.saveDaily())
        let savedID = try #require(history.savedDailyID), reopened = try await dailyStore.openDaily(id: savedID)
        #expect(reopened.report.input == input && reopened.replayMatched)
    }

    @Test func lateDraftBaselineCannotReviveLeavingPageOrOverridePostClearSession() async throws {
        for clearDuringRead in [false, true] {
            let capture = try await OptionChainSyntheticCollection.capture()
            let fixture = try await setup(ChainWorkspaceCollector([.init(capture)]))
            let probe = ChainLabRevisionProbe(fixture.base), lab = try await installLab(fixture, storage: probe)
            await fixture.model.loadSynthetic(); #expect(await fixture.model.saveCapture())
            let value = try draft(fixture, capture: capture), gate = ChainWorkspaceGate()
            await probe.holdNextRevision(gate)
            let preparing = Task { try await lab.prepareChainDraft(value) }
            await gate.waitForArrival()
            #expect(lab.isBusy && lab.revision == nil)
            if clearDuringRead { try await clear(fixture) }
            else { lab.disappear(); await lab.load() }
            let current = try #require(lab.revision)
            #expect(current == (try await fixture.base.revision()))
            await gate.release()
            await #expect(throws: CancellationError.self) { try await preparing.value }
            #expect(lab.revision == current && lab.report == nil && lab.savedID == nil && !lab.isBusy && !lab.canSave)
            if clearDuringRead {
                #expect(fixture.model.capture == nil)
                #expect(try await fixture.chain.summaries().isEmpty)
            }
        }
    }
}
