import Foundation
import Testing
import MacroProviders
import MarketAnalytics
@testable import Persistence
@testable import AppComposition

private actor MacroPageGate {
    private var arrived = false, released = false
    private var worker: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, any Error>?
    func hold() async { arrived = true; waiter?.resume(); waiter = nil; if !released { await withCheckedContinuation { worker = $0 } } }
    func wait() async throws {
        guard !arrived else { return }
        let deadline = Task { do { try await Task.sleep(for: .seconds(20)) } catch { return }; timeout() }
        defer { deadline.cancel() }; try await withCheckedThrowingContinuation { waiter = $0 }
    }
    private func timeout() { waiter?.resume(throwing: MarketStateStorageError.notFound); waiter = nil }
    func release() { released = true; worker?.resume(); worker = nil }
}
private actor MacroPageStoreProbe: MacroSourceStorage {
    let base: MacroSourceStore
    var openGate: MacroPageGate?, saveGate: MacroPageGate?
    var failedList = false, failedOpen = false, failedSave = false, duplicate = false
    init(_ base: MacroSourceStore) { self.base = base }
    func gate(open: MacroPageGate? = nil, save: MacroPageGate? = nil) { openGate = open; saveGate = save }
    func failures(list: Bool = false, open: Bool = false, save: Bool = false, duplicate: Bool = false) {
        failedList = list; failedOpen = open; failedSave = save; self.duplicate = duplicate
    }
    func revision() async throws -> UUID { try await base.revision() }
    func summaries() async throws -> [MacroSourceSummary] {
        if failedList { throw MarketStateStorageError.corruptedStorage }
        let values = try await base.summaries(); return duplicate ? values + values : values
    }
    func save(_ input: MacroImportInput, expectedRevision: UUID) async throws -> SavedMacroSource {
        let held = saveGate; saveGate = nil; if let held { await held.hold() }
        if failedSave { throw MarketStateStorageError.injectedFailure }
        return try await base.save(input, expectedRevision: expectedRevision)
    }
    func open(id: UUID) async throws -> SavedMacroSource {
        let value = try await base.open(id: id), held = openGate, fails = failedOpen; openGate = nil
        if let held { await held.hold() }; if fails { throw MarketStateStorageError.corruptedStorage }; return value
    }
    func saveBridge(_ input: MacroMarketBridgeInput, expectedRevision: UUID) async throws -> SavedMacroMarketBridge {
        let held = saveGate; saveGate = nil; if let held { await held.hold() }
        if failedSave { throw MarketStateStorageError.injectedFailure }
        return try await base.saveBridge(input, expectedRevision: expectedRevision)
    }
    func openBridge(id: UUID) async throws -> SavedMacroMarketBridge { try await base.openBridge(id: id) }
}

@Suite("Offline source page ownership", .timeLimit(.minutes(1))) @MainActor
struct MacroSourceWorkspaceTests {
    private struct Fixture {
        let store: MacroSourceStore
        let probe: MacroPageStoreProbe
        let model: MacroSourceWorkspaceModel
        let market: MarketStateWorkspaceModel
    }
    private func setup(gate: MacroPageGate? = nil, calculationFails: Bool = false) throws -> Fixture {
        let db = try DatabaseStore(path: ":memory:", purpose: .marketState)
        let store = try MacroSourceStore(database: db), probe = MacroPageStoreProbe(store), coordinator = MarketStateTransferCoordinator()
        let model = MacroSourceWorkspaceModel(storage: probe, coordinator: coordinator, evaluate: { input in
            let value = try MacroSourceEngine.evaluate(input)
            if let gate { await gate.hold() }; if calculationFails { throw MacroSourceError.malformedSource }; return value
        })
        let market = MarketStateWorkspaceModel(storage: try MarketStateStore(database: db), archive: try MarketStateArchiveStore(database: db), coordinator: coordinator)
        return .init(store: store, probe: probe, model: model, market: market)
    }
    private func prepare(_ model: MacroSourceWorkspaceModel, format: MacroSourceFormat = .fredObservationsJSON) async throws {
        let input = try MacroSourceDemo.input(format: format), text = try MacroSourceManifest(input).json()
        await model.prepare(manifestJSON: text) { input.rawData }
    }
    private func save(_ model: MacroSourceWorkspaceModel) async throws {
        let preview = try #require(model.preview)
        #expect(await model.confirm(id: preview.id, expectedRevision: preview.revision))
    }
    private func clear(_ f: Fixture, replace: Bool = false) async throws {
        if replace {
            let bytes = try await MarketStateArchiveStore(path: ":memory:").exportArchive()
            await f.market.prepareRestore(mode: .replace) { bytes }
        } else { await f.market.prepareClear() }
        let plan = try #require(f.market.plan); #expect(await f.market.confirm(.init(plan: plan)))
    }
    @Test(arguments: MacroSourceFormat.allCases) func explicitPreviewConfirmAndReopen(_ format: MacroSourceFormat) async throws {
        let f = try setup(); await f.model.load(); try await prepare(f.model, format: format)
        let candidate = try #require(f.model.preview)
        #expect(try await f.store.summaries().isEmpty)
        #expect(candidate.report.input.descriptor.format == format && candidate.report.containsSynthetic)
        try await save(f.model); let row = try #require(f.model.saved.first)
        #expect(f.model.preview == nil && f.model.savedID == row.id)
        f.model.draftChanged(); await f.model.open(row)
        #expect(f.model.report == candidate.report && f.model.savedID == row.id)
    }
    @Test func previewIdentityAndRevisionMustBothMatch() async throws {
        let f = try setup(); try await prepare(f.model); let p = try #require(f.model.preview)
        #expect(await f.model.confirm(id: UUID(), expectedRevision: p.revision) == false)
        #expect(await f.model.confirm(id: p.id, expectedRevision: UUID()) == false)
        #expect(try await f.store.summaries().isEmpty)
        f.model.draftChanged(); #expect(await f.model.confirm(id: p.id, expectedRevision: p.revision) == false)
    }
    @Test func changedIdentityImportReusesExactEvidenceWithoutFalseFailure() async throws {
        let f = try setup(); try await prepare(f.model); try await save(f.model)
        let first = try #require(f.model.report), id = f.model.savedID, revision = try await f.store.revision()
        try await prepare(f.model); #expect(f.model.preview?.report.id != first.id); try await save(f.model)
        #expect(f.model.report == first && f.model.savedID == id && !f.model.hasError)
        #expect(try await f.store.revision() == revision)
    }
    @Test(arguments: [false, true]) func latePreviewAndErrorCannotOverrideEditedForm(_ fails: Bool) async throws {
        let gate = MacroPageGate(), f = try setup(gate: gate, calculationFails: fails)
        let task = Task { try await prepare(f.model) }
        do { try await gate.wait() } catch { await gate.release(); _ = try? await task.value; throw error }
        f.model.draftChanged(); await gate.release(); try await task.value
        #expect(f.model.preview == nil && f.model.report == nil && f.model.message == nil && !f.model.isBusy && !f.model.hasError)
    }
    @Test func cancelledFileReadCannotCreateAPreview() async throws {
        let f = try setup(), input = try MacroSourceDemo.input(), text = try MacroSourceManifest(input).json(), gate = MacroPageGate()
        let task = Task { await f.model.prepare(manifestJSON: text) { await gate.hold(); return input.rawData } }
        do { try await gate.wait() } catch { await gate.release(); await task.value; throw error }
        f.model.cancel(); let message = f.model.message; await gate.release(); await task.value
        #expect(f.model.preview == nil && f.model.report == nil && f.model.message == message && !f.model.isBusy)
    }
    @Test func malformedManifestClearsPreviouslyCheckedValues() async throws {
        let f = try setup(); try await prepare(f.model)
        await f.model.prepare(manifestJSON: "wrong") { Data() }
        #expect(f.model.report == nil && f.model.preview == nil && f.model.hasError && !f.model.canConfirm)
    }
    @Test(arguments: [false, true]) func transferInvalidatesLateRead(_ replace: Bool) async throws {
        let f = try setup(); try await prepare(f.model); try await save(f.model)
        let row = try #require(f.model.saved.first), gate = MacroPageGate(); await f.probe.gate(open: gate)
        let task = Task { await f.model.open(row) }
        do { try await gate.wait() } catch { await gate.release(); await task.value; throw error }
        try await clear(f, replace: replace); await gate.release(); await task.value
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.saved.isEmpty && !f.model.isBusy)
    }
    @Test(arguments: [false, true]) func transferRejectsQueuedOldImport(_ replace: Bool) async throws {
        let f = try setup(); try await prepare(f.model); let preview = try #require(f.model.preview), gate = MacroPageGate()
        await f.probe.gate(save: gate); let task = Task { await f.model.confirm(id: preview.id, expectedRevision: preview.revision) }
        do { try await gate.wait() } catch { await gate.release(); _ = await task.value; throw error }
        try await clear(f, replace: replace); await gate.release(); #expect(await task.value == false)
        #expect(try await f.store.summaries().isEmpty); #expect(f.model.report == nil && !f.model.isBusy)
    }
    @Test func leavingDuringSaveNeverPublishesAndReentryReloads() async throws {
        let f = try setup(); try await prepare(f.model); let preview = try #require(f.model.preview), gate = MacroPageGate()
        await f.probe.gate(save: gate); let task = Task { await f.model.confirm(id: preview.id, expectedRevision: preview.revision) }
        do { try await gate.wait() } catch { await gate.release(); _ = await task.value; throw error }
        f.model.disappear(); await f.model.load(); await gate.release(); #expect(await task.value)
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.saved.count == 1 && !f.model.isBusy && f.model.message == nil)
    }
    @Test func failedSaveRetainsExactPreviewAndCanRetry() async throws {
        let f = try setup(); try await prepare(f.model); let preview = try #require(f.model.preview)
        await f.probe.failures(save: true); #expect(await f.model.confirm(id: preview.id, expectedRevision: preview.revision) == false)
        #expect(f.model.preview?.id == preview.id && f.model.preview?.revision == preview.revision && f.model.canConfirm)
        await f.probe.failures(); try await save(f.model)
    }
    @Test func corruptDirectoryOrOpenNeverShowsUnverifiedValues() async throws {
        let f = try setup(); try await prepare(f.model); try await save(f.model); let row = try #require(f.model.saved.first)
        await f.probe.failures(duplicate: true); await f.model.load()
        #expect(f.model.saved.isEmpty && f.model.listError != nil)
        await f.probe.failures(open: true); await f.model.open(row)
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.hasError)
    }
    @Test func selectedSourceBridgeFreezesOriginalBytesAndReplays() async throws {
        let f = try setup(); try await prepare(f.model, format: .cboeIndexHistoryCSV); try await save(f.model)
        let source = try #require(f.model.report); f.model.selectCurrentSource()
        let base = try MarketStateDemo.input(sessionCount: 5)
        await f.model.buildMarket(base: base)
        let bridge = try #require(f.model.bridge)
        #expect(bridge.input.base == base && bridge.input.sources == [source] && f.model.canSaveBridge)
        #expect(await f.model.saveBridge())
        let row = try #require(f.model.saved.first { $0.kind == .marketBridge })
        f.model.draftChanged(); await f.model.open(row)
        #expect(f.model.bridge == bridge && f.model.savedID == row.id && f.model.report == nil)
    }
    @Test func unconfirmedOrReleaseCycleSourceCannotSilentlyEnterMarketCalculation() async throws {
        let f = try setup(); try await prepare(f.model); f.model.selectCurrentSource()
        #expect(f.model.selectedSources.isEmpty)
        try await save(f.model); f.model.selectCurrentSource()
        #expect(f.model.selectedSources.count == 1)
        await f.model.buildMarket(base: try MarketStateDemo.input(sessionCount: 5))
        #expect(f.model.bridge == nil && f.model.hasError && !f.model.canSaveBridge)
    }
    @Test func restoreAlsoInvalidatesSourceBasketAndUnpersistedBridge() async throws {
        let f = try setup(); try await prepare(f.model, format: .cboeIndexHistoryCSV); try await save(f.model); f.model.selectCurrentSource()
        await f.model.buildMarket(base: try MarketStateDemo.input(sessionCount: 5)); #expect(f.model.bridge != nil)
        try await clear(f)
        #expect(f.model.bridge == nil && f.model.selectedSources.isEmpty && f.model.saved.isEmpty && !f.model.canSaveBridge)
    }
}
