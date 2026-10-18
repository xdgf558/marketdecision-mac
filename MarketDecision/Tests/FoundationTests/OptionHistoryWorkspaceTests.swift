import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import Persistence
@testable import AppComposition

private actor OptionHistoryGate {
    private var arrived = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var worker: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        if !released { await withCheckedContinuation { worker = $0 } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; worker?.resume(); worker = nil }
}
private actor OptionHistoryStorageProbe: OptionDailyStorage {
    let base: OptionDailyStore
    var openGate: OptionHistoryGate?, saveGate: OptionHistoryGate?
    var failDailyList = false
    init(_ base: OptionDailyStore) { self.base = base }
    func setOpen(_ gate: OptionHistoryGate) { openGate = gate }
    func setSave(_ gate: OptionHistoryGate) { saveGate = gate }
    func failList() { failDailyList = true }
    func revision() async throws -> UUID { try await base.revision() }
    func saveDaily(_ input: OptionDailyInput, expectedRevision: UUID) async throws -> SavedOptionDaily {
        if let gate = saveGate { saveGate = nil; await gate.hold() }
        return try await base.saveDaily(input, expectedRevision: expectedRevision)
    }
    func saveHistory(_ input: OptionVolatilityHistoryInput, expectedRevision: UUID) async throws -> SavedOptionVolatilityHistory { try await base.saveHistory(input, expectedRevision: expectedRevision) }
    func dailySummaries() async throws -> [OptionDailySummary] {
        if failDailyList { throw OptionLabStoreError.corruptedStorage }
        return try await base.dailySummaries()
    }
    func historySummaries() async throws -> [OptionVolatilityHistorySummary] { try await base.historySummaries() }
    func openDaily(id: UUID) async throws -> SavedOptionDaily {
        let value = try await base.openDaily(id: id)
        if let gate = openGate { openGate = nil; await gate.hold() }
        return value
    }
    func openHistory(id: UUID) async throws -> SavedOptionVolatilityHistory { try await base.openHistory(id: id) }
}
private actor OptionArchiveProbe: OptionLabArchiveStorage {
    let base: OptionLabArchiveStore
    var gate: OptionHistoryGate?
    var fail = false
    var cancels: [UUID] = []
    init(_ base: OptionLabArchiveStore) { self.base = base }
    func holdCommit(_ gate: OptionHistoryGate, fail: Bool) { self.gate = gate; self.fail = fail }
    func status() async throws -> OptionLabArchiveStatus { try await base.status() }
    func exportArchive() async throws -> Data { try await base.exportArchive() }
    func prepareRestore(_ data: Data, mode: OptionLabRestoreMode, expectedRevision: UUID) async throws -> OptionLabTransferPlan { try await base.prepareRestore(data, mode: mode, expectedRevision: expectedRevision) }
    func prepareClear(expectedRevision: UUID) async throws -> OptionLabTransferPlan { try await base.prepareClear(expectedRevision: expectedRevision) }
    func commit(_ approval: OptionLabTransferApproval) async throws -> OptionLabTransferResult {
        if let gate { self.gate = nil; await gate.hold() }
        if fail { fail = false; throw OptionLabArchiveError.injectedFailure }
        return try await base.commit(approval)
    }
    func cancel(_ id: UUID) async { cancels.append(id); await base.cancel(id) }
}
@Suite("Option daily/history page sessions and archive invalidation") @MainActor
struct OptionHistoryWorkspaceTests {
    private struct Fixture {
        let base: OptionLabStore, daily: OptionDailyStore, probe: OptionHistoryStorageProbe, archive: OptionArchiveProbe
        let model: OptionHistoryWorkspaceModel, transfer: OptionArchiveTransferModel, coordinator: OptionTransferCoordinator
    }
    private func setup() async throws -> Fixture {
        let base = try OptionLabStore(path: ":memory:")
        let daily = try await base.makeDailyStore(), archive = OptionArchiveProbe(try await base.makeArchiveStore())
        let probe = OptionHistoryStorageProbe(daily), coordinator = OptionTransferCoordinator()
        let model = OptionHistoryWorkspaceModel(storage: probe, coordinator: coordinator)
        let transfer = OptionArchiveTransferModel(store: archive, coordinator: coordinator)
        await model.load(); await transfer.load()
        return .init(base: base, daily: daily, probe: probe, archive: archive, model: model, transfer: transfer, coordinator: coordinator)
    }
    private func saved(_ f: Fixture) async throws -> UUID {
        let input = try OptionDailyDemo.input()
        await f.model.calculateDaily(input)
        #expect(await f.model.saveDaily())
        return try #require(f.model.savedDailyID)
    }
    @Test func dailyDraftKeepsSyntheticAndDoesNotBackdateNewDeclaration() throws {
        var draft = try OptionDailyInputDraft.synthetic()
        draft.symbol = "CHANGED"
        let before = Date(), input = try draft.build()
        #expect(input.source.origin == .synthetic && input.underlying.source.origin == .synthetic)
        #expect(input.contracts.allSatisfy { $0.source.origin == .synthetic && $0.activity.source.origin == .synthetic })
        #expect(input.createdAt >= before && input.source.enteredAt == input.createdAt)
        #expect(input.asOf == OptionDailyDemo.defaultDate)
        #expect(input.contracts.allSatisfy { $0.activity.openInterest == nil && $0.activity.volume == nil })
        draft.declaredClose = false
        #expect(try OptionDailyEngine.calculate(draft.build()).iv30 == nil)
    }
    @Test func calculationCompletedAfterDraftEditCannotPublish() async throws {
        let daily = try OptionDailyStore(path: ":memory:"), gate = OptionHistoryGate()
        let model = OptionHistoryWorkspaceModel(storage: daily, dailyCalculator: { input in
            let result = try OptionDailyEngine.calculate(input); await gate.hold(); return result
        })
        await model.load(); let input = try OptionDailyDemo.input()
        let work = Task { await model.calculateDaily(input) }
        await gate.wait(); model.draftChanged(); await gate.release(); await work.value
        #expect(model.dailyReport == nil && model.savedDailyID == nil && !model.isBusy)
    }
    @Test func clearRejectsLateOldSaveAtOriginalRevision() async throws {
        let f = try await setup(), gate = OptionHistoryGate(), input = try OptionDailyDemo.input()
        await f.model.calculateDaily(input)
        await f.probe.setSave(gate)
        let save = Task { await f.model.saveDaily() }
        await gate.wait(); await f.transfer.prepareClear()
        let plan = try #require(f.transfer.plan)
        #expect(await f.transfer.confirm(.init(plan: plan)))
        await gate.release(); #expect(await save.value == false)
        #expect(try await f.daily.dailySummaries().isEmpty)
        #expect(f.model.dailyReport == nil && f.model.savedDailyID == nil)
        await f.model.load(); #expect(f.model.dailySummaries.isEmpty && !f.model.isBusy)
    }
    @Test func clearDiscardsAnAlreadyReadDailyResult() async throws {
        let f = try await setup(), id = try await saved(f), gate = OptionHistoryGate()
        await f.probe.setOpen(gate)
        let opening = Task { await f.model.openDaily(id) }
        await gate.wait(); await f.transfer.load(); await f.transfer.prepareClear()
        let plan = try #require(f.transfer.plan)
        #expect(await f.transfer.confirm(.init(plan: plan)))
        await gate.release(); await opening.value
        #expect(f.model.dailyReport == nil && f.model.dailySummaries.isEmpty && !f.model.isBusy)
    }
    @Test func independentCatalogFailureDoesNotEraseHealthyHistoryCatalog() async throws {
        let f = try await setup(), input = try OptionVolatilityHistoryDemo.input(priorSessions: 0)
        _ = try await f.daily.saveHistory(input, expectedRevision: f.daily.revision())
        await f.probe.failList(); await f.model.load()
        #expect(f.model.dailyListError != nil && f.model.dailySummaries.isEmpty)
        #expect(f.model.historyListError == nil && f.model.historySummaries.count == 1)
        #expect(f.model.historyReport == nil)
    }
    @Test func savedHistoryUsesNewDeclarationTimeAndExcludesOtherSeries() async throws {
        let f = try await setup()
        let currentInput = try OptionDailyDemo.input()
        let earlier = try OptionDailyDemo.input(at: currentInput.asOf.addingTimeInterval(-86_400))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(earlier)) as? [String: Any])
        func changed(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                for (key, child) in dict { dict[key] = key == "feedID" ? "other-offline-series" : changed(child) }
                return dict
            }
            if let array = value as? [Any] { return array.map(changed) }
            return value
        }
        object = try #require(changed(object) as? [String: Any])
        let other = try JSONDecoder().decode(OptionDailyInput.self, from: JSONSerialization.data(withJSONObject: object))
        _ = try await f.daily.saveDaily(other, expectedRevision: f.daily.revision())
        var currentObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(currentInput)) as? [String: Any])
        currentObject["createdAt"] = currentInput.createdAt.addingTimeInterval(10).timeIntervalSinceReferenceDate
        let delayed = try JSONDecoder().decode(OptionDailyInput.self, from: JSONSerialization.data(withJSONObject: currentObject))
        await f.model.load(); await f.model.calculateDaily(delayed)
        let before = Date()
        await f.model.calculateSavedHistory(sessions: [earlier.session, delayed.session], reference: "explicit local calendar declared now")
        let report = try #require(f.model.historyReport)
        #expect(report.input.createdAt >= before && report.input.createdAt >= delayed.createdAt)
        #expect(report.input.calendar.source.enteredAt == report.input.createdAt)
        #expect(report.input.current.input.asOf == delayed.asOf)
        #expect(f.model.excludedHistoryCount == 1 && report.input.history.isEmpty)
        #expect(report.ivRank == nil && report.ivPercentile == nil)
    }
    @Test func staleSaveRemovesKnownInvalidWriteBaseline() async throws {
        let f = try await setup()
        await f.model.calculateDaily(try OptionDailyDemo.input())
        _ = try await f.daily.saveDaily(OptionDailyDemo.input(), expectedRevision: f.daily.revision())
        #expect(await f.model.saveDaily() == false)
        #expect(f.model.revision == nil && !f.model.canSaveDaily && f.model.dailyReport != nil)
    }
    @Test func archiveDismissedCommitCannotPublishIntoNewSession() async throws {
        let f = try await setup(), gate = OptionHistoryGate()
        _ = try await saved(f); await f.transfer.load(); await f.transfer.prepareClear()
        let plan = try #require(f.transfer.plan)
        await f.archive.holdCommit(gate, fail: false)
        let commit = Task { await f.transfer.confirm(.init(plan: plan)) }
        await gate.wait(); f.transfer.dismiss(); await gate.release()
        #expect(await commit.value)
        #expect(f.transfer.plan == nil && f.transfer.message == nil && !f.transfer.isBusy)
        #expect(try await f.daily.dailySummaries().isEmpty)
    }
    @Test func archiveDismissedFailureCleansOnlyItsOldPlan() async throws {
        let f = try await setup(), gate = OptionHistoryGate()
        await f.transfer.prepareClear(); let plan = try #require(f.transfer.plan)
        await f.archive.holdCommit(gate, fail: true)
        let commit = Task { await f.transfer.confirm(.init(plan: plan)) }
        await gate.wait(); f.transfer.dismiss(); await gate.release()
        #expect(await commit.value == false)
        #expect(f.transfer.message == nil && f.transfer.plan == nil && !f.transfer.isBusy)
        #expect(await f.archive.cancels == [plan.id])
    }
}
