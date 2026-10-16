import Foundation
import Testing
import CoreDomain
import OptionsAnalytics
import PortfolioEngine
import Persistence
@testable import AppComposition

private actor OptionWorkspaceGate {
    private var arrived = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor OptionWorkspaceStore: OptionLabStorage {
    var version = UUID(), reads = 0, saves = 0
    var baselines: [UUID] = [], inputs: [OptionLabInput] = []
    var records: [UUID: SavedOptionLab] = [:]
    var failures: [String: OptionLabStoreError] = [:]
    var gates: [String: OptionWorkspaceGate] = [:]
    var duplicateSummary = false, rejectReplay = false
    func gate(_ key: String, _ value: OptionWorkspaceGate) { gates[key] = value }
    func fail(_ key: String, _ error: OptionLabStoreError = .injectedFailure) { failures[key] = error }
    func advance() { version = UUID() }
    func duplicate() { duplicateSummary = true }
    func unverified() { rejectReplay = true }
    func pause(_ key: String) async throws {
        let gate = gates.removeValue(forKey: key), error = failures.removeValue(forKey: key)
        if let gate { await gate.hold() }
        if let error { throw error }
    }
    func revision() async throws -> UUID { reads += 1; let result = version; try await pause("revision"); return result }
    func save(id: UUID, input: OptionLabInput, ledgerBasis: OptionLabLedgerBasis?, expectedRevision: UUID) async throws -> SavedOptionLab {
        saves += 1; baselines.append(expectedRevision); inputs.append(input)
        try await pause("save")
        guard expectedRevision == version else { throw OptionLabStoreError.staleRevision }
        let report = try OptionLabEngine.calculate(input)
        let result = SavedOptionLab(id: id, report: report, inputHash: String(repeating: "a", count: 64),
            reportHash: String(repeating: "b", count: 64), ledgerBasis: ledgerBasis, replayMatched: true)
        records[id] = result; version = UUID(); return result
    }
    func summaries() async throws -> [OptionLabSummary] {
        var result = records.values.map { value in
            OptionLabSummary(id: value.id, createdAt: value.report.input.createdAt, asOf: value.report.input.asOf,
                strategy: value.report.input.strategy, origin: value.report.input.underlying.source.origin,
                underlyingSymbol: value.report.input.underlying.symbol, inputHash: value.inputHash, reportHash: value.reportHash)
        }
        if duplicateSummary, let first = result.first { result.append(first) }
        try await pause("summaries"); return result
    }
    func open(id: UUID) async throws -> SavedOptionLab {
        guard let value = records[id] else { throw OptionLabStoreError.notFound }
        let result = SavedOptionLab(id: value.id, report: value.report, inputHash: value.inputHash, reportHash: value.reportHash,
            ledgerBasis: value.ledgerBasis, replayMatched: !rejectReplay)
        try await pause("open"); return result
    }
}

@Suite("Offline options workspace lifecycle") @MainActor
struct OptionLabWorkspaceTests {
    private func setup() async -> (OptionLabWorkspaceModel, OptionWorkspaceStore) {
        let store = OptionWorkspaceStore(), model = OptionLabWorkspaceModel(storage: store)
        await model.load(); return (model, store)
    }
    @Test func constructionDoesNotReadLedgerStorageOrCreateFinancialInputs() async {
        let store = OptionWorkspaceStore(), model = OptionLabWorkspaceModel(storage: store)
        #expect(model.report == nil && model.saved.isEmpty && model.ledgerSnapshot == nil && model.revision == nil)
        #expect(await store.reads == 0)
        #expect(!model.canSave)
    }
    @Test func blankManualDraftDoesNotInventZeroCashQuotesOrSourceEvidence() throws {
        let draft = OptionLabInputDraft()
        #expect(draft.origin == .manual && draft.cashBeforeTrade.isEmpty && draft.committedCash.isEmpty)
        #expect(draft.shortLeg.bid.isEmpty && draft.shortLeg.tick.isEmpty && draft.sourceReference.isEmpty)
        #expect(throws: (any Error).self) { try draft.build() }
    }
    @Test func syntheticEditsKeepOriginAndNewCalculationsGetDistinctSnapshotIDs() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .putCreditSpread)
        draft.shortLeg.bid = "2.1"; draft.cashBeforeTrade = "30000"
        let first = try draft.build(), second = try draft.build()
        #expect(first.id != second.id)
        #expect(first.underlying.source.origin == .synthetic && first.shortLeg.source.origin == .synthetic)
        #expect(first.capital.origin == .synthetic && first.expiry.source.origin == .synthetic)
        #expect(try OptionLabEngine.calculate(first).researchOnly)
        #expect(OptionLabInputDraft().origin == .manual)
    }
    @Test func draftRejectsFractionalSizesAndMissingCapitalRatherThanRoundingOrFillingZero() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        draft.shortLeg.bidSize = "1.5"
        #expect(throws: OptionLabDraftError.invalidNumber) { try draft.build() }
        draft.shortLeg.bidSize = "10"; draft.cashBeforeTrade = ""
        #expect(throws: MoneyError.invalidDecimal) { try draft.build() }
    }
    @Test func copyingAnInputPreservesExactSubmillisecondTimesUntilEdited() throws {
        let instant = Date(timeIntervalSince1970: 1_760_000_000.0004)
        let original = try OptionLabDemo.input(at: instant)
        let draft = OptionLabInputDraft(input: original)
        let copied = try draft.build(createdAt: instant.addingTimeInterval(1))
        #expect(copied.id != original.id)
        #expect(copied.asOf == original.asOf && copied.expiry.settlementAt == original.expiry.settlementAt)
        #expect(copied.shortLeg.quotedAt == original.shortLeg.quotedAt && copied.shortLeg.receivedAt == original.shortLeg.receivedAt)
        #expect(copied.underlying.quotedAt == original.underlying.quotedAt && copied.underlying.receivedAt == original.underlying.receivedAt)
    }
    @Test func copyingMixedOriginsCannotRelabelSyntheticLegsAsManual() throws {
        let original = try OptionLabDemo.input()
        let mixed = OptionLabInput(createdAt: original.createdAt, asOf: original.asOf, strategy: original.strategy,
            shortLeg: original.shortLeg, longLeg: original.longLeg,
            underlying: .init(symbol: original.underlying.symbol, bid: original.underlying.bid, ask: original.underlying.ask,
                quotedAt: original.asOf, receivedAt: original.asOf,
                source: .init(origin: .manual, reference: "manual assumption", enteredAt: original.asOf)),
            capital: original.capital, policy: original.policy, expiry: original.expiry, scenarioPrices: original.scenarioPrices)
        let draft = OptionLabInputDraft(input: mixed)
        #expect(draft.origin == .synthetic)
        #expect(try draft.build(createdAt: original.createdAt).underlying.source.origin == .synthetic)
    }
    @Test func calculatedResultIsBoundToFullImmutableInputAndDraftEditClearsIt() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input()
        await model.calculate(input)
        #expect(model.report?.input == input && model.canSave && model.savedID == nil)
        model.draftChanged()
        #expect(model.report == nil && !model.canSave)
        #expect(await store.saves == 0)
    }
    @Test func knownInputFailureUsesFixedActionableMessageAndNoOldResult() async throws {
        let store = OptionWorkspaceStore()
        let model = OptionLabWorkspaceModel(storage: store, calculator: { _ in throw OptionLabError.missingTick })
        await model.load(); await model.calculate(try OptionLabDemo.input())
        #expect(model.hasError && model.report == nil && !model.canSave)
        #expect(model.message == OptionLabError.missingTick.errorDescription)
    }
    @Test func calculatorCannotPublishAReportForADifferentInput() async throws {
        let other = try OptionLabDemo.input(strategy: .coveredCall), store = OptionWorkspaceStore()
        let model = OptionLabWorkspaceModel(storage: store, calculator: { _ in try OptionLabEngine.calculate(other) })
        await model.load(); await model.calculate(try OptionLabDemo.input())
        #expect(model.hasError && model.report == nil && !model.canSave)
    }
    @Test func lateCalculationCannotPublishAfterEditOrReleaseNewerBusyRead() async throws {
        let calculationGate = OptionWorkspaceGate(), readGate = OptionWorkspaceGate(), store = OptionWorkspaceStore()
        let model = OptionLabWorkspaceModel(storage: store, calculator: { input in
            await calculationGate.hold(); return try OptionLabEngine.calculate(input)
        })
        await model.load(); let input = try OptionLabDemo.input()
        let old = Task { await model.calculate(input) }; await calculationGate.wait()
        model.draftChanged(); await store.gate("summaries", readGate)
        let newer = Task { await model.reloadSaved() }; await readGate.wait()
        await calculationGate.release(); await old.value
        #expect(model.report == nil && model.isBusy)
        await readGate.release(); await newer.value
        #expect(!model.isBusy && model.report == nil)
    }
    @Test func saveFailureKeepsOriginalIDInputAndRevisionForRetry() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input(), baseline = try #require(model.revision)
        await model.calculate(input); await store.fail("save")
        #expect(await model.save() == false)
        #expect(model.canSave && model.savedID == nil && model.report?.input == input)
        #expect(await model.save())
        #expect(model.savedID == input.id && model.saved.count == 1 && !model.canSave)
        #expect(await store.baselines == [baseline, baseline])
        #expect(await store.inputs == [input, input])
    }
    @Test func staleSaveDoesNotAcquireNewWritingBaseline() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input()
        await model.calculate(input); await store.advance()
        #expect(await model.save() == false)
        #expect(model.revision == nil && !model.canSave && model.savedID == nil && model.report?.input == input)
        #expect(await model.save() == false)
        #expect(await store.saves == 1)
    }
    @Test func explicitReloadRecoversStaleBaselineOnlyAfterDiscardingOldCalculation() async throws {
        let (model, store) = await setup(), old = try OptionLabDemo.input()
        await model.calculate(old); await store.advance()
        #expect(await model.save() == false)
        #expect(model.revision == nil && model.report?.input == old)
        await model.load()
        #expect(model.report == nil && model.revision != nil && !model.canSave)
        let new = try OptionLabDemo.input()
        await model.calculate(new); #expect(await model.save())
        #expect(model.savedID == new.id && new.id != old.id)
        #expect(await store.inputs.map(\.id) == [old.id, new.id])
    }
    @Test func leavingDuringSaveDoesNotPublishAndReentryLoadsFreshStateAfterCompletion() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input(), gate = OptionWorkspaceGate()
        await model.calculate(input); await store.gate("save", gate)
        let saving = Task { await model.save() }; await gate.wait()
        model.disappear(); await model.load()
        #expect(model.isBusy && model.report == nil)
        await gate.release(); #expect(await saving.value)
        #expect(!model.isBusy && model.report == nil && model.savedID == nil)
        #expect(model.saved.map(\.id) == [input.id] && model.revision != nil)
    }
    @Test func leavingDuringFailedSaveDoesNotPublishOldErrorIntoReenteredSession() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input(), gate = OptionWorkspaceGate()
        await model.calculate(input); await store.gate("save", gate); await store.fail("save")
        let saving = Task { await model.save() }; await gate.wait()
        model.disappear(); await model.load(); await gate.release()
        #expect(await saving.value == false)
        #expect(!model.hasError && model.message == nil && model.report == nil && !model.isBusy)
    }
    @Test func delayedOpenCannotRestoreValuesAfterPageDisappears() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input(), gate = OptionWorkspaceGate()
        await model.calculate(input); #expect(await model.save()); await store.gate("open", gate)
        let opening = Task { await model.open(input.id) }; await gate.wait()
        #expect(model.report == nil)
        model.disappear(); await gate.release(); await opening.value
        #expect(model.report == nil && model.savedID == nil && !model.isBusy)
    }
    @Test func unverifiedOpenNeverDisplaysCachedValues() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input()
        await model.calculate(input); #expect(await model.save()); await store.unverified()
        await model.open(input.id)
        #expect(model.hasError && model.report == nil && model.savedID == nil)
    }
    @Test func directoryFailureDoesNotEraseIndependentlyVerifiedCurrentReport() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input()
        await model.calculate(input); #expect(await model.save()); await store.fail("summaries")
        await model.reloadSaved()
        #expect(model.report?.input == input && model.savedID == input.id)
        #expect(model.saved.isEmpty && model.listError != nil)
    }
    @Test func duplicateDirectoryIDsFailClosedWithoutPublishingAmbiguousRows() async throws {
        let (model, store) = await setup(), input = try OptionLabDemo.input()
        await model.calculate(input); #expect(await model.save()); await store.duplicate(); await model.reloadSaved()
        #expect(model.saved.isEmpty && model.listError != nil && model.report?.input == input)
    }
    @Test func ledgerReadFailureIsIndependentOfManualAndSyntheticComputation() async throws {
        let store = OptionWorkspaceStore(), model = OptionLabWorkspaceModel(storage: store, ledgerReader: { throw LedgerStoreError.corruptedStorage })
        await model.load(); let input = try OptionLabDemo.input(); await model.calculate(input)
        await model.readLedger()
        #expect(model.ledgerSnapshot == nil && model.ledgerError != nil)
        #expect(model.report?.input == input && model.canSave)
    }
    @Test func persistenceRevisionFailureDoesNotPreventOfflineComputation() async throws {
        let store = OptionWorkspaceStore(); await store.fail("revision")
        let model = OptionLabWorkspaceModel(storage: store); await model.load()
        await model.calculate(try OptionLabDemo.input())
        #expect(model.report != nil && model.revision == nil && !model.canSave)
    }
    @Test func forgedLedgerBasisCannotPublishEvenWhenItsClaimedCapitalMatches() async throws {
        let fixture = try PortfolioSyntheticExample.input(), base = try OptionLabDemo.input()
        let snapshot = LedgerSnapshot(revision: fixture.ledgerRevision, accounts: fixture.accounts, events: fixture.events,
            state: try LedgerEngine.replay(accounts: fixture.accounts, events: fixture.events))
        let basis = try OptionLabLedgerBridge.inspect(snapshot: snapshot, accountID: fixture.request.accountID,
            underlying: .init(id: "DEMO", symbol: "DEMO"), asOf: base.asOf, completenessEvidence: "Synthetic complete ledger and obligations")
        let encoded = try JSONEncoder().encode(basis)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["cashBeforeTrade"] = "999999"
        let forged = try JSONDecoder().decode(OptionLabLedgerBasis.self, from: JSONSerialization.data(withJSONObject: object))
        let capital = try #require(forged.capital)
        let input = OptionLabInput(createdAt: base.createdAt, asOf: base.asOf, strategy: base.strategy,
            shortLeg: base.shortLeg, longLeg: base.longLeg, underlying: base.underlying,
            capital: capital, policy: base.policy, expiry: base.expiry, scenarioPrices: base.scenarioPrices)
        let (model, store) = await setup()
        await model.calculate(input, ledgerBasis: forged)
        #expect(model.report == nil && model.hasError && !model.canSave)
        #expect(await store.saves == 0)
    }

}
