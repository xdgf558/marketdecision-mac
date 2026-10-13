import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
@testable import AppComposition

/// Explicit arrival/release handshake; deliberately ignores cancellation to prove
/// that publication depends on the visible session, not scheduling or elapsed time.
private actor LedgerWorkspaceGate {
    private var arrived = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var worker: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; observers.forEach { $0.resume() }; observers.removeAll()
        if !released { await withCheckedContinuation { worker = $0 } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; worker?.resume(); worker = nil }
}
private enum LedgerWorkspaceFailure: Error { case synthetic }

private actor LedgerWorkspaceStorageFake: LedgerStorage {
    var revision = UUID()
    var accounts = [LedgerAccount(id: "local-a", name: "合成账户")]
    var events: [LedgerEvent] = []
    private var plans: [UUID: (LedgerImportPreview, [LedgerEvent])] = [:]
    private var gates: [String: LedgerWorkspaceGate] = [:]
    private var failures: Set<String> = []
    private(set) var cancellations: [UUID] = []
    private(set) var commits = 0
    private(set) var attemptedCommits = 0
    private(set) var csvExclusions: Set<Int> = []
    private(set) var previewBaselines: [UUID] = []
    func gate(_ key: String, _ gate: LedgerWorkspaceGate) { gates[key] = gate }
    func fail(_ key: String) { failures.insert(key) }
    func advanceRevision() { revision = UUID() }
    func planCount() -> Int { plans.count }
    func pause(_ key: String) async throws {
        let gate = gates.removeValue(forKey: key), failed = failures.remove(key) != nil
        if let gate { await gate.hold() }
        if failed { throw LedgerWorkspaceFailure.synthetic }
    }
    func value() throws -> LedgerSnapshot {
        try .init(revision: revision, accounts: accounts, events: events,
                  state: LedgerEngine.replay(accounts: accounts, events: events),
                  batches: events.isEmpty ? [] : [.init(id: "fixture-batch", sourceHash: String(repeating: "a", count: 64),
                      newEventIDs: events.map(\.id), excludedRowCount: 0, duplicateRowCount: 0)])
    }
    func snapshot() async throws -> LedgerSnapshot {
        let result = try value()
        try await pause("load")
        return result
    }
    func createAccount(_ account: LedgerAccount, expectedRevision: UUID) async throws -> LedgerSnapshot {
        try await pause("account")
        guard expectedRevision == revision else { throw LedgerStoreError.stalePlan }
        accounts.append(account); revision = UUID()
        return try value()
    }
    func previewCSV(data: Data, accountID: String, sourceSystem: String, mapping: LedgerCSVMapping,
                    excludedRows: Set<Int>, expectedRevision: UUID) async throws -> LedgerImportPreview {
        csvExclusions = excludedRows
        let event = try ledgerWorkspaceEvent(id: "csv-event")
        return try await makePreview(events: [event], expectedRevision: expectedRevision, exclusions: excludedRows)
    }
    func previewManual(events: [LedgerEvent], expectedRevision: UUID) async throws -> LedgerImportPreview {
        try await makePreview(events: events, expectedRevision: expectedRevision)
    }
    func previewCorrection(originalEventID: String, replacement: LedgerEvent, reason: String,
                           expectedRevision: UUID) async throws -> LedgerImportPreview {
        try await makePreview(events: [replacement], expectedRevision: expectedRevision)
    }
    func previewBatchReversal(batchID: String, effectiveAt: Date, reason: String,
                              expectedRevision: UUID) async throws -> LedgerImportPreview {
        guard let original = events.first else { throw LedgerStoreError.invalidPlan }
        let event = LedgerEvent(id: "batch-reversal", accountID: original.accountID, effectiveAt: effectiveAt,
            source: .init(sourceSystem: "manual-reversal", externalTransactionID: "batch-reversal", evidence: reason),
            payload: .reversal(.init(originalEventID: original.id, reason: reason)))
        return try await makePreview(events: [event], expectedRevision: expectedRevision)
    }
    private func makePreview(events incoming: [LedgerEvent], expectedRevision: UUID,
                             exclusions: Set<Int> = []) async throws -> LedgerImportPreview {
        previewBaselines.append(expectedRevision)
        guard expectedRevision == revision else { throw LedgerStoreError.stalePlan }
        let rows = incoming.enumerated().map { index, event in
            LedgerImportRow(rowIndex: index + 1, event: event,
                disposition: exclusions.contains(index + 1) ? .excluded : .new, message: "合成模型夹具")
        }
        let accepted = rows.filter { $0.disposition == .new }.compactMap(\.event)
        let plan = try LedgerImportPreview(id: UUID(), targetRevision: revision, sourceHash: String(repeating: "a", count: 64),
            rows: rows, projectedState: LedgerEngine.replay(accounts: accounts, events: events + accepted), validationMessage: nil)
        plans[plan.id] = (plan, accepted)
        try await pause("preview")
        return plan
    }
    func commit(planID: UUID, expectedRevision: UUID) async throws -> LedgerSnapshot {
        attemptedCommits += 1
        guard let (plan, additions) = plans[planID], plan.targetRevision == expectedRevision else { throw LedgerStoreError.invalidPlan }
        try await pause("commit")
        guard expectedRevision == revision else { throw LedgerStoreError.stalePlan }
        events += additions; revision = UUID(); commits += 1; plans.removeValue(forKey: planID)
        return try value()
    }
    func cancel(planID: UUID) async {
        cancellations.append(planID); plans.removeValue(forKey: planID)
        try? await pause("cancel")
    }
}

private func ledgerWorkspaceEvent(id: String = "deposit") throws -> LedgerEvent {
    .init(id: id, accountID: "local-a", effectiveAt: try LedgerCSV.timestamp("2026-01-02T14:30:00Z"),
        source: .init(sourceSystem: "synthetic", externalTransactionID: id, evidence: "合成明确入金"),
        payload: .cash(.init(kind: .deposit, amount: try Money("100"))))
}

@Suite("Ledger workspace session and manual entry")
@MainActor struct LedgerWorkspaceTests {
    @Test func initialLoadAndCashPreviewNeverWriteUntilExactConfirmation() async throws {
        let storage = LedgerWorkspaceStorageFake()
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load()
        #expect(subject.selectedAccountID == "local-a")
        await subject.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(subject.preview)
        #expect(await storage.commits == 0)
        #expect(!(await subject.confirm(id: UUID(), expectedRevision: plan.targetRevision)))
        #expect(!(await subject.confirm(id: plan.id, expectedRevision: UUID())))
        #expect(await storage.attemptedCommits == 0)
        #expect(await subject.confirm(id: plan.id, expectedRevision: plan.targetRevision))
        #expect(subject.snapshot?.state.cashByAccount["local-a"] == (try Money("100")))
        #expect(await storage.commits == 1)
        #expect(subject.preview == nil)
        #expect(!(await subject.confirm(id: plan.id, expectedRevision: plan.targetRevision)))
    }

    @Test func lateLoadCannotPublishAfterPageDisappearsOrClearNewBusyState() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await storage.gate("load", gate)
        let old = Task { await model.load() }
        await gate.wait()
        model.disappear()
        let freshGate = LedgerWorkspaceGate()
        await storage.gate("load", freshGate)
        let fresh = Task { await model.load() }
        await freshGate.wait()
        await gate.release(); await old.value
        #expect(model.snapshot == nil)
        #expect(model.isBusy)
        await freshGate.release(); await fresh.value
        #expect(model.snapshot != nil)
        #expect(!model.isBusy)
    }

    @Test func latePreviewIsReleasedWhenTheDraftChanges() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await storage.gate("preview", gate)
        let task = Task { await model.prepareManual(events: [try ledgerWorkspaceEvent()]) }
        await gate.wait()
        model.draftChanged()
        await gate.release(); try await task.value
        #expect(model.preview == nil)
        #expect(await storage.planCount() == 0)
        #expect(await storage.cancellations.count == 1)
        #expect(await storage.commits == 0)
    }

    @Test func latePreviewFailureCannotReplaceNewSessionMessage() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await storage.gate("preview", gate); await storage.fail("preview")
        let task = Task { await model.prepareManual(events: [try ledgerWorkspaceEvent()]) }
        await gate.wait(); model.disappear()
        await model.load(); await model.cancelPreview()
        let message = model.message
        await gate.release(); try await task.value
        #expect(model.message == message)
        #expect(!model.hasError)
    }

    @Test func ordinaryFailureRetainsTheOriginalPlanForExplicitRetry() async throws {
        let storage = LedgerWorkspaceStorageFake()
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load(); await subject.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(subject.preview)
        await storage.fail("commit")
        #expect(!(await subject.confirm(id: plan.id, expectedRevision: plan.targetRevision)))
        #expect(subject.preview == plan)
        #expect(subject.hasError)
        #expect(await storage.commits == 0)
        #expect(await subject.confirm(id: plan.id, expectedRevision: plan.targetRevision))
        #expect(await storage.commits == 1)
    }

    @Test func staleConfirmationCleansOnlyItsPlanWithoutAdoptingANewRevision() async throws {
        let storage = LedgerWorkspaceStorageFake()
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load(); await subject.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(subject.preview)
        await storage.advanceRevision()
        #expect(!(await subject.confirm(id: plan.id, expectedRevision: plan.targetRevision)))
        #expect(subject.preview == nil)
        #expect(subject.snapshot?.revision == plan.targetRevision)
        #expect(await storage.cancellations == [plan.id])
        #expect(await storage.commits == 0)
    }

    @Test func leavingDuringCommitDoesNotCancelTransactionOrPublishItsResultToAnOldPage() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await model.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(model.preview)
        await storage.gate("commit", gate)
        let task = Task { await model.confirm(id: plan.id, expectedRevision: plan.targetRevision) }
        await gate.wait(); model.disappear()
        #expect(model.isBusy)
        await gate.release(); #expect(await task.value)
        #expect(model.snapshot == nil)
        #expect(model.message == nil)
        #expect(await storage.commits == 1)
        #expect(await storage.cancellations.isEmpty)
        #expect(!model.isBusy)
    }

    @Test func reopeningDuringCommitReadsCommittedSnapshotWithoutOldSuccessMessage() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await model.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(model.preview)
        await storage.gate("commit", gate)
        let task = Task { await model.confirm(id: plan.id, expectedRevision: plan.targetRevision) }
        await gate.wait(); model.disappear(); await model.load()
        #expect(model.isBusy)
        await gate.release(); #expect(await task.value)
        #expect(model.snapshot?.events.count == 1)
        #expect(model.message == nil)
        #expect(!model.isBusy)
    }

    @Test func failureAfterLeavingReleasesOriginalPlanAndDoesNotPublishError() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await model.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(model.preview)
        await storage.gate("commit", gate); await storage.fail("commit")
        let task = Task { await model.confirm(id: plan.id, expectedRevision: plan.targetRevision) }
        await gate.wait(); model.disappear()
        await gate.release(); #expect(!(await task.value))
        #expect(model.message == nil)
        #expect(!model.hasError)
        #expect(await storage.cancellations == [plan.id])
    }

    @Test func staleCleanupCannotPublishAnErrorAfterThePageReopens() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await model.prepareManual(events: [try ledgerWorkspaceEvent()])
        let plan = try #require(model.preview)
        await storage.advanceRevision(); await storage.gate("cancel", gate)
        let task = Task { await model.confirm(id: plan.id, expectedRevision: plan.targetRevision) }
        await gate.wait(); model.disappear(); await model.load()
        await gate.release(); #expect(!(await task.value))
        #expect(model.snapshot != nil)
        #expect(model.message == nil)
        #expect(!model.hasError)
    }

    @Test func accountReloadCompletionCannotPublishToANewerPage() async throws {
        let storage = LedgerWorkspaceStorageFake(), gate = LedgerWorkspaceGate()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load(); await storage.gate("load", gate)
        let task = Task { await model.createAccount(.init(id: "local-b", name: "第二个合成账户")) }
        await gate.wait(); model.disappear(); await model.load()
        #expect(model.snapshot?.accounts.count == 2)
        let message = model.message
        await gate.release(); await task.value
        #expect(model.message == message)
        #expect(!model.isBusy)
    }

    @Test func csvExclusionIsExplicitAndTheDisplayedBaselineIsPreserved() async throws {
        let storage = LedgerWorkspaceStorageFake()
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load()
        let revision = try #require(subject.snapshot?.revision)
        await subject.prepareCSV(Data(LedgerCSVMapping.standardTemplate.utf8), sourceSystem: "synthetic",
            mapping: .standard, excludedRows: [1])
        #expect(await storage.csvExclusions == [1])
        #expect(await storage.previewBaselines == [revision])
        #expect(subject.preview?.rows.first?.disposition == .excluded)
        #expect(!subject.canConfirm)
        await subject.cancelPreview()
        #expect(await storage.commits == 0)
    }

    @Test func changingAccountRejectsStagedEventsCorrectionsAndAnotherAccountsBatch() async throws {
        let storage = LedgerWorkspaceStorageFake(), model = LedgerWorkspaceModel(storage: LedgerWorkspaceStorageFake())
        #expect(model.preview == nil)
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load()
        let original = try ledgerWorkspaceEvent()
        await subject.prepareManual(events: [original])
        let first = try #require(subject.preview)
        #expect(await subject.confirm(id: first.id, expectedRevision: first.targetRevision))
        await subject.createAccount(.init(id: "local-b", name: "另一个合成账户"))
        #expect(subject.selectedAccountID == "local-b")
        let count = await storage.previewBaselines.count
        await subject.prepareManual(events: [try ledgerWorkspaceEvent(id: "old-staged")])
        #expect(subject.preview == nil); #expect(subject.hasError)
        await subject.prepareCorrection(originalEventID: original.id, replacement: try ledgerWorkspaceEvent(id: "replacement"))
        #expect(subject.preview == nil); #expect(subject.hasError)
        await subject.prepareBatchReversal(batchID: "fixture-batch", timestamp: "2026-01-03T14:30:00Z", reason: "错误账户不能代批")
        #expect(subject.preview == nil); #expect(subject.hasError)
        #expect(await storage.previewBaselines.count == count)
        #expect(await storage.commits == 1)
    }

    @Test func batchReversalUsesExplicitReasonAndCreatesAnotherPreview() async throws {
        let storage = LedgerWorkspaceStorageFake(), model = LedgerWorkspaceModel(storage: LedgerWorkspaceStorageFake())
        #expect(model.preview == nil)
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load(); await subject.prepareManual(events: [try ledgerWorkspaceEvent()])
        let first = try #require(subject.preview)
        #expect(await subject.confirm(id: first.id, expectedRevision: first.targetRevision))
        await subject.prepareBatchReversal(batchID: "fixture-batch", timestamp: "2026-01-03T14:30:00Z", reason: "")
        #expect(subject.preview == nil)
        #expect(await storage.commits == 1)
        await subject.prepareBatchReversal(batchID: "fixture-batch", timestamp: "2026-01-03T14:30:00Z", reason: "合成撤销依据")
        let reversal = try #require(subject.preview)
        #expect(reversal.id != first.id)
        #expect(reversal.projectedState?.cashByAccount["local-a"] == (try Money("0")))
        #expect(await storage.commits == 1)
    }

    @Test func selectedCSVReadReturnsExactBytesIncludingUTF8BOMWithoutWriting() async throws {
        let storage = LedgerWorkspaceStorageFake(), model = LedgerWorkspaceModel(storage: LedgerWorkspaceStorageFake())
        #expect(model.snapshot == nil)
        let subject = LedgerWorkspaceModel(storage: storage)
        await subject.load()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-selected-" + UUID().uuidString + ".csv")
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data(LedgerCSVMapping.standardTemplate.utf8)
        try bytes.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(await subject.readSelectedCSV(path) == bytes)
        #expect(await storage.commits == 0)
        #expect(subject.preview == nil)
    }

    @Test func failedReloadDoesNotKeepThePreviousBalanceVisible() async throws {
        let storage = LedgerWorkspaceStorageFake()
        let model = LedgerWorkspaceModel(storage: storage)
        await model.load()
        #expect(model.snapshot != nil)
        await storage.fail("load"); await model.load()
        #expect(model.snapshot == nil)
        #expect(model.hasError)
        #expect(!model.canPrepare)
    }

    @Test func manualFormRequiresExplicitFeeAndCorporateActionEvidence() throws {
        var form = LedgerManualDraft()
        form.kind = .equityTrade; form.timestamp = "2026-01-02T14:30:00Z"
        form.externalID = "fixture-buy"; form.evidence = "合成成交单"
        form.securityID = "US-DEMO-A"; form.symbol = "DEMO"; form.quantity = "2"
        form.unitPrice = "10"; form.openingLotID = "lot-a"
        #expect(throws: MoneyError.self) { try form.event(accountID: "local-a") }
        form.fee = "0"
        let event = try form.event(accountID: "local-a")
        guard case .trade(let trade) = event.payload else { Issue.record("Expected trade"); return }
        #expect(trade.fee == (try Money("0")))
        form.kind = .split; form.ratio = "2"
        #expect(throws: LedgerError.self) { try form.event(accountID: "local-a") }
        form.confirmedBy = "fixture-owner"
        #expect(try form.event(accountID: "local-a").payload.kind == "stockSplit")
        form.fractionQuantities = ["lot-a": "0.5"]
        #expect(throws: MoneyError.self) { try form.event(accountID: "local-a") }
    }

    @Test func manualTransferRequiresHistoricalCostDateAndEventMarketValue() throws {
        var form = LedgerManualDraft()
        form.kind = .transferIn; form.timestamp = "2026-01-02T14:30:00Z"
        form.externalID = "fixture-transfer"; form.evidence = "合成转仓凭据"
        form.securityID = "US-DEMO-A"; form.symbol = "DEMO"; form.quantity = "2"; form.openingLotID = "lot-a"
        form.historicalCost = "15"; form.acquiredAt = "2025-01-02T14:30:00Z"
        #expect(throws: MoneyError.self) { try form.event(accountID: "local-a") }
        form.eventMarketValue = "20"
        let event = try form.event(accountID: "local-a")
        guard case .transferIn(let transfer) = event.payload else { Issue.record("Expected transfer"); return }
        #expect(transfer.historicalCost == (try Money("15")))
        #expect(transfer.eventMarketValue == (try Money("20")))
        #expect(transfer.userReportedTaxBasis == nil)
    }

    @Test func manualOptionDoesNotInferMultiplierOrDeliverableFromOCC() throws {
        var form = LedgerManualDraft()
        form.kind = .optionTrade; form.timestamp = "2026-01-02T14:30:00Z"
        form.externalID = "fixture-option"; form.evidence = "合成合约与成交单"
        form.occSymbol = "DEMO  260116C00020000"; form.contractVersionID = "v1"
        form.effectiveFrom = "2026-01-01T00:00:00Z"; form.tradingEndsAt = "2026-01-16T21:00:00Z"
        form.exerciseDeadline = "2026-01-16T22:00:00Z"; form.settlementAt = "2026-01-20T14:30:00Z"
        form.exerciseConsideration = "2000"; form.deliverableCash = "0"
        form.securityID = "US-DEMO-A"; form.symbol = "DEMO"; form.memoReference = "synthetic-memo"
        form.quantity = "1"; form.unitPrice = "2"; form.fee = "0"; form.openingLotID = "option-lot"
        #expect(throws: MoneyError.self) { try form.event(accountID: "local-a") }
        form.quoteMultiplier = "100"; form.deliverableQuantity = "50"
        form.strategyEnabled = true; form.strategyID = "fixture-strategy"; form.successDefinition = "合成期权管理目的"
        let event = try form.event(accountID: "local-a")
        guard case .trade(let trade) = event.payload, case .option(let option) = trade.instrument else {
            Issue.record("Expected option"); return
        }
        #expect(option.quoteMultiplier == (try Money("100")))
        #expect(option.deliverables[0].quantity == (try Money("50")))
    }
}
