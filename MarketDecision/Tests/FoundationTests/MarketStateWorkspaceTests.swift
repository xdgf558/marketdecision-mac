import Foundation
import Testing
import MarketAnalytics
import PortfolioEngine
import CoreDomain
import DataContracts
import DataProviders
import SecuritySupport
@testable import Persistence
@testable import AppComposition

private actor MarketPageCredentialProbe: CredentialStorage {
    private(set) var calls = 0
    func contains(reference: String) -> Bool { calls += 1; return false }
    func save(_ secret: Data, reference: String) { calls += 1 }
    func delete(reference: String) { calls += 1 }
}
private actor MarketPageQuoteProbe: QuoteProvider {
    nonisolated let id = "SYNTHETIC-market-composition-probe"
    private(set) var calls = 0
    func quote(for symbol: String) throws -> Quote { calls += 1; throw MarketStateStorageError.notFound }
}

private actor MarketPageGate {
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
private actor MarketPageStoreProbe: MarketStateStorage {
    let base: MarketStateStore
    var openGate: MarketPageGate?, saveGate: MarketPageGate?
    var failedList = false, failedOpen = false, failedSave = false, duplicate = false
    init(_ base: MarketStateStore) { self.base = base }
    func gate(open: MarketPageGate? = nil, save: MarketPageGate? = nil) { openGate = open; saveGate = save }
    func failures(list: Bool = false, open: Bool = false, save: Bool = false, duplicate: Bool = false) {
        failedList = list; failedOpen = open; failedSave = save; self.duplicate = duplicate
    }
    func revision() async throws -> UUID { try await base.revision() }
    func summaries() async throws -> [MarketStateSummary] {
        if failedList { throw MarketStateStorageError.corruptedStorage }
        let values = try await base.summaries(); return duplicate ? values + values : values
    }
    func save(_ input: MarketStateInput, expectedRevision: UUID) async throws -> SavedMarketState {
        let held = saveGate; saveGate = nil; if let held { await held.hold() }
        if failedSave { throw MarketStateStorageError.injectedFailure }
        return try await base.save(input, expectedRevision: expectedRevision)
    }
    func saveAttribution(_ input: MarketTradeAttributionInput, expectedRevision: UUID) async throws -> SavedMarketAttribution {
        try await base.saveAttribution(input, expectedRevision: expectedRevision)
    }
    func open(id: UUID) async throws -> SavedMarketState {
        let value = try await base.open(id: id), held = openGate, fails = failedOpen; openGate = nil
        if let held { await held.hold() }; if fails { throw MarketStateStorageError.corruptedStorage }; return value
    }
    func openAttribution(id: UUID) async throws -> SavedMarketAttribution { try await base.openAttribution(id: id) }
}
private actor MarketPageArchiveProbe: MarketStateArchiveStorage {
    let base: MarketStateArchiveStore
    var commitGate: MarketPageGate?, cancelGate: MarketPageGate?
    var failCommit = false
    init(_ base: MarketStateArchiveStore) { self.base = base }
    func gate(commit: MarketPageGate? = nil, cancel: MarketPageGate? = nil, failure: Bool = false) { commitGate = commit; cancelGate = cancel; failCommit = failure }
    func status() async throws -> MarketStateArchiveStatus { try await base.status() }
    func exportArchive() async throws -> Data { try await base.exportArchive() }
    func prepareRestore(_ data: Data, mode: MarketStateRestoreMode, expectedRevision: UUID) async throws -> MarketStateTransferPlan { try await base.prepareRestore(data, mode: mode, expectedRevision: expectedRevision) }
    func prepareClear(expectedRevision: UUID) async throws -> MarketStateTransferPlan { try await base.prepareClear(expectedRevision: expectedRevision) }
    func prepareDelete(ids: Set<UUID>, expectedRevision: UUID) async throws -> MarketStateTransferPlan { try await base.prepareDelete(ids: ids, expectedRevision: expectedRevision) }
    func commit(_ approval: MarketStateTransferApproval) async throws -> MarketStateTransferResult {
        let held = commitGate, fail = failCommit; commitGate = nil
        if let held { await held.hold() }; if fail { throw MarketStateStorageError.injectedFailure }; return try await base.commit(approval)
    }
    func cancel(_ id: UUID) async { let held = cancelGate; cancelGate = nil; if let held { await held.hold() }; await base.cancel(id) }
}

@Suite("Offline market page ownership", .timeLimit(.minutes(1))) @MainActor
struct MarketStateWorkspaceTests {
    private struct Fixture {
        let store: MarketStateStore
        let probe: MarketPageStoreProbe
        let archive: MarketPageArchiveProbe
        let model: MarketStateWorkspaceModel
        let other: MarketStateWorkspaceModel
    }
    private func setup(gate: MarketPageGate? = nil, calculationFails: Bool = false) throws -> Fixture {
        let db = try DatabaseStore(path: ":memory:", purpose: .marketState)
        let store = try MarketStateStore(database: db), probe = MarketPageStoreProbe(store)
        let archive = MarketPageArchiveProbe(try MarketStateArchiveStore(database: db)), coordinator = MarketStateTransferCoordinator()
        let model = MarketStateWorkspaceModel(storage: probe, archive: archive, coordinator: coordinator, calculateMarket: { input in
            let value = try MarketStateEngine.calculate(input)
            if let gate { await gate.hold() }; if calculationFails { throw MarketStateStorageError.injectedFailure }; return value
        })
        return .init(store: store, probe: probe, archive: archive, model: model,
            other: MarketStateWorkspaceModel(storage: store, archive: archive, coordinator: coordinator))
    }
    private func json(_ kind: MarketDocumentKind = .marketState) throws -> String {
        let input = try MarketStateDemo.input(sessionCount: 5), encoder = JSONEncoder()
        let data = try kind == .marketState ? encoder.encode(input) : encoder.encode(MarketTradeAttributionDemo.input(snapshot: MarketStateEngine.calculate(input)))
        return String(decoding: data, as: UTF8.self)
    }
    private func calculate(_ model: MarketStateWorkspaceModel, kind: MarketDocumentKind = .marketState) async throws { await model.calculateJSON(try json(kind), kind: kind) }
    private func transfer(_ f: Fixture, replace: Bool) async throws {
        if replace {
            let empty = try MarketStateArchiveStore(path: ":memory:"), bytes = try await empty.exportArchive()
            await f.other.prepareRestore(mode: .replace) { bytes }
        } else { await f.other.prepareClear() }
        let plan = try #require(f.other.plan); #expect(await f.other.confirm(.init(plan: plan)))
    }
    @Test func environmentLazilySharesOnlyMarketDatabaseWithoutProviderOrCredentials() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unrelatedNames = ["offline-issuer.sqlite", "sec-research.sqlite", "portfolio-ledger.sqlite", "options-lab.sqlite"]
        let sentinel = Data("SYNTHETIC unrelated workspace; not a database".utf8)
        for name in unrelatedNames { try sentinel.write(to: folder.appendingPathComponent(name)) }
        let path = folder.appendingPathComponent("market-state.sqlite").path
        let credentials = MarketPageCredentialProbe(), provider = MarketPageQuoteProbe()
        let environment = try AppEnvironment(quotes: provider, database: DatabaseStore(path: ":memory:"), credentials: credentials,
            offlineResearchDatabasePath: folder.appendingPathComponent("offline-issuer.sqlite").path)
        #expect(!FileManager.default.fileExists(atPath: path))
        let credentialCallsBefore = await credentials.calls, providerCallsBefore = await provider.calls
        #expect(credentialCallsBefore == 0 && providerCallsBefore == 0)
        let first = try await environment.makeMarketStateWorkspaceModel()
        let second = try await environment.makeMarketStateWorkspaceModel()
        #expect(first !== second)
        await first.load(); await second.load()
        #expect(first.status?.revision == second.status?.revision && first.status != nil)
        #expect(first.report == nil && second.report == nil && first.saved.isEmpty && second.saved.isEmpty)
        try await calculate(first); #expect(await first.save())
        await second.load(); let item = try #require(second.saved.first)
        #expect(second.report == nil && second.savedID == nil)
        await second.open(item)
        #expect(second.report == first.report && second.savedID == first.savedID)
        #expect(try DatabaseStore(path: path, purpose: .marketState).migrationVersions() == ["foundation.v1", "market-state.v1", "market-state.v2"])
        #expect(throws: MigrationError.incompatiblePurpose) { try DatabaseStore(path: path, purpose: .portfolioLedger) }
        for name in unrelatedNames { #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == sentinel) }
        let credentialCallsAfter = await credentials.calls, providerCallsAfter = await provider.calls
        #expect(credentialCallsAfter == 0 && providerCallsAfter == 0)
        // Probe evidence covers the injected credential and quote boundaries;
        // it is not a network-monitor, real Keychain or whole-process proof.
    }
    @Test(arguments: [MarketDocumentKind.marketState, .tradeAttribution]) func frozenFlow(_ kind: MarketDocumentKind) async throws {
        let f = try setup(); await f.model.load(); try await calculate(f.model, kind: kind)
        #expect(f.model.canSave); #expect(await f.model.save())
        let row = try #require(f.model.saved.first)
        #expect(row.kind == kind && row.containsSynthetic); f.model.draftChanged()
        await f.model.open(row); #expect(f.model.savedID == row.id)
        #expect(kind == .marketState ? f.model.report != nil : f.model.attribution != nil)
    }
    @Test func malformedInputClearsPreviousReport() async throws {
        let f = try setup(); try await calculate(f.model)
        await f.model.calculateJSON("not-json", kind: .marketState)
        #expect(f.model.hasError && f.model.report == nil && !f.model.canSave)
    }
    @Test(arguments: [false, true]) func editingDropsLateCalculationAndError(_ failure: Bool) async throws {
        let gate = MarketPageGate(), f = try setup(gate: gate, calculationFails: failure)
        let task = Task { try await calculate(f.model) }
        do { try await gate.wait() } catch { await gate.release(); _ = try? await task.value; throw error }
        f.model.draftChanged(); await gate.release(); try await task.value
        #expect(f.model.report == nil && !f.model.isBusy && !f.model.hasError && f.model.message == nil)
    }
    @Test(arguments: [false, true]) func transferInvalidatesLateRead(_ replace: Bool) async throws {
        let f = try setup(); try await calculate(f.model); #expect(await f.model.save())
        let row = try #require(f.model.saved.first), gate = MarketPageGate(); await f.probe.gate(open: gate)
        let task = Task { await f.model.open(row) }
        do { try await gate.wait() } catch { await gate.release(); await task.value; throw error }
        try await transfer(f, replace: replace); await gate.release(); await task.value
        #expect(f.model.saved.isEmpty && f.model.report == nil && f.model.savedID == nil && !f.model.isBusy)
    }
    @Test(arguments: [false, true]) func transferRejectsQueuedOldSave(_ replace: Bool) async throws {
        let f = try setup(); try await calculate(f.model)
        let gate = MarketPageGate(); await f.probe.gate(save: gate); let task = Task { await f.model.save() }
        do { try await gate.wait() } catch { await gate.release(); _ = await task.value; throw error }
        try await transfer(f, replace: replace); await gate.release(); #expect(await task.value == false)
        #expect(try await f.store.summaries().isEmpty); #expect(f.model.report == nil && !f.model.isBusy)
    }
    @Test func saveFailurePreservesOriginalRevisionForRetry() async throws {
        let f = try setup(); try await calculate(f.model); let baseline = f.model.revision
        await f.probe.failures(save: true); #expect(await f.model.save() == false)
        #expect(f.model.canSave && f.model.revision == baseline)
        await f.probe.failures(); #expect(await f.model.save())
    }
    @Test func badCatalogDoesNotExposeCachedScoresOrRemoveSavedReport() async throws {
        let f = try setup(); try await calculate(f.model); #expect(await f.model.save())
        let row = try #require(f.model.saved.first)
        await f.probe.failures(duplicate: true); await f.model.load()
        #expect(f.model.saved.isEmpty && f.model.listError != nil && f.model.report != nil)
        await f.probe.failures(open: true); await f.model.open(row)
        #expect(f.model.report == nil && f.model.savedID == nil && f.model.hasError)
    }
    @Test func previewAndCancelNeverMutateDatabase() async throws {
        let f = try setup(); try await calculate(f.model); #expect(await f.model.save())
        let before = try await f.store.revision(); await f.model.prepareClear()
        #expect(f.model.plan != nil && f.model.canConfirm && !f.model.canSave)
        await f.model.cancelPlan(); #expect(f.model.plan == nil)
        #expect(try await f.store.revision() == before); #expect(try await f.store.summaries().count == 1)
    }
    @Test func lateCancelCannotOverwriteNewCalculation() async throws {
        let f = try setup(); await f.model.prepareClear(); let gate = MarketPageGate(); await f.archive.gate(cancel: gate)
        let task = Task { await f.model.cancelPlan() }
        do { try await gate.wait() } catch { await gate.release(); await task.value; throw error }
        try await calculate(f.model); let message = f.model.message
        await gate.release(); await task.value
        #expect(f.model.report != nil && f.model.message == message && !f.model.hasError)
    }
    @Test(arguments: [false, true]) func leavingDropsCommitResultAndReloads(_ fails: Bool) async throws {
        let f = try setup(); try await calculate(f.model); #expect(await f.model.save()); await f.model.prepareClear()
        let plan = try #require(f.model.plan), gate = MarketPageGate(); await f.archive.gate(commit: gate, failure: fails)
        let task = Task { await f.model.confirm(.init(plan: plan)) }
        do { try await gate.wait() } catch { await gate.release(); _ = await task.value; throw error }
        f.model.disappear(); await f.model.load(); await gate.release(); #expect(await task.value == !fails)
        #expect(f.model.message == nil && !f.model.hasError && !f.model.isBusy && f.model.plan == nil)
        #expect(f.model.saved.count == (fails ? 1 : 0))
        let actual = try await f.archive.status()
        #expect(f.model.status == actual)
        #expect(f.model.status?.counts.marketReports == (fails ? 1 : 0))
    }
    @Test func oldSheetDismissalCannotCancelNewPlan() async throws {
        let f = try setup(); await f.model.prepareClear(); let old = try #require(f.model.plan)
        await f.model.cancelPlan(expectedID: old.id)
        await f.model.prepareClear(); let current = try #require(f.model.plan)
        #expect(current.id != old.id)
        await f.model.cancelPlan(expectedID: old.id)
        #expect(f.model.plan == current && f.model.canConfirm)
        await f.model.cancelPlan(expectedID: current.id)
    }
    @Test func cancelledImportDiscardsLatePreparedPlan() async throws {
        let f = try setup(), bytes = try await f.archive.exportArchive(), gate = MarketPageGate()
        let task = Task { await f.model.prepareRestore(mode: .merge) { await gate.hold(); return bytes } }
        do { try await gate.wait() } catch { await gate.release(); await task.value; throw error }
        f.model.cancelWork(); let message = f.model.message; await gate.release(); await task.value
        #expect(f.model.plan == nil && f.model.message == message && !f.model.isBusy)
    }
}
