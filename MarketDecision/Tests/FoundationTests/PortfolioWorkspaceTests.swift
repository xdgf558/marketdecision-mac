import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
@testable import AppComposition

private actor PortfolioWorkspaceGate {
    private var arrived = false, released = false
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; watchers.forEach { $0.resume() }; watchers.removeAll()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { watchers.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor PortfolioWorkspaceFake: PerformanceStorage {
    var performanceRevision = UUID(), ledgerRevision = UUID()
    var reads = 0, prepares = 0, commits = 0
    var opened: [UUID] = [], ordinaryEvents: [LedgerEvent] = []
    var openVariant: String?
    var lastRaw: Data?, baselines: [(UUID, UUID)] = []
    var plans: [UUID: PerformancePreview] = [:], records: [UUID: SavedPerformanceReport] = [:]
    var cancelled: [UUID] = []
    var failures: [String: PerformanceStoreError] = [:], gates: [String: PortfolioWorkspaceGate] = [:]
    func gate(_ key: String, _ gate: PortfolioWorkspaceGate) { gates[key] = gate }
    func fail(_ key: String, error: PerformanceStoreError = .corruptedStorage) { failures[key] = error }
    func pause(_ key: String) async throws {
        let gate = gates.removeValue(forKey: key), error = failures.removeValue(forKey: key)
        if let gate { await gate.hold() }
        if let error { throw error }
    }
    func context() async throws -> PerformanceStoreContext {
        reads += 1
        let read = reads
        // Indexed gates let a test pause either side of one immutable read;
        // the existing unindexed gate keeps its snapshot-before-pause behavior.
        try await pause("context:\(read):before")
        let input = try PortfolioSyntheticExample.input()
        let accounts = input.accounts + [.init(id: "ordinary-b", name: "独立空账户")]
        let events = input.events + ordinaryEvents
        let ledger = try LedgerSnapshot(revision: ledgerRevision, accounts: accounts, events: events,
            state: LedgerEngine.replay(accounts: accounts, events: events))
        let result = PerformanceStoreContext(ledger: ledger, revision: performanceRevision)
        try await pause("context:\(read)")
        try await pause("context")
        return result
    }
    func prepare(request: PerformanceRequest, rawRequest: Data?, expectedLedgerRevision: UUID,
                 expectedPerformanceRevision: UUID) async throws -> PerformancePreview {
        prepares += 1; baselines.append((expectedLedgerRevision, expectedPerformanceRevision)); lastRaw = rawRequest
        guard expectedLedgerRevision == ledgerRevision, expectedPerformanceRevision == performanceRevision else { throw PerformanceStoreError.stalePlan }
        let original = try PortfolioSyntheticExample.input()
        let input = PerformanceInput(request: request, ledgerRevision: ledgerRevision, accounts: original.accounts, events: original.events)
        let report = try PerformanceEngine.calculate(input)
        let value = PerformancePreview(id: UUID(), ledgerRevision: ledgerRevision, performanceRevision: performanceRevision,
            inputHash: String(repeating: "a", count: 64), reportHash: String(repeating: "b", count: 64), report: report)
        plans[value.id] = value
        try await pause("prepare")
        return value
    }
    func commit(planID: UUID, expectedLedgerRevision: UUID, expectedPerformanceRevision: UUID) async throws -> SavedPerformanceReport {
        commits += 1
        try await pause("commit")
        guard let plan = plans[planID], expectedLedgerRevision == ledgerRevision,
              expectedPerformanceRevision == performanceRevision else { throw PerformanceStoreError.stalePlan }
        let record = SavedPerformanceReport(id: planID, createdAt: Date(), report: plan.report,
            inputHash: plan.inputHash, reportHash: plan.reportHash, ledgerRevision: ledgerRevision, isCurrentLedger: true, replayMatched: true)
        records[planID] = record; plans[planID] = nil; performanceRevision = UUID()
        if let gate = gates.removeValue(forKey: "committed") { await gate.hold() }
        return record
    }
    func cancel(planID: UUID) { plans[planID] = nil; cancelled.append(planID) }
    func reports(accountID: String) async throws -> [PerformanceSummary] {
        try await pause("reports")
        return records.values.filter { $0.report.input.request.accountID == accountID }.map { record in
            .init(id: record.id, accountID: accountID, createdAt: record.createdAt,
                startDate: record.report.input.request.calendar.tradingDays.first ?? "",
                endDate: record.report.input.request.calendar.tradingDays.last ?? "",
                dayCount: record.report.input.request.calendar.tradingDays.count,
                ledgerRevision: record.ledgerRevision, inputHash: record.inputHash, reportHash: record.reportHash,
                engineVersion: record.report.engineVersion, isCurrentLedger: record.ledgerRevision == ledgerRevision)
        }
    }
    func open(id: UUID) async throws -> SavedPerformanceReport {
        opened.append(id)
        guard let original = records[id] else { throw PerformanceStoreError.notFound }
        let result = SavedPerformanceReport(id: openVariant == "identity" ? UUID() : original.id,
            createdAt: original.createdAt, report: original.report,
            inputHash: openVariant == "hash" ? String(repeating: "e", count: 64) : original.inputHash,
            reportHash: original.reportHash, ledgerRevision: original.ledgerRevision,
            isCurrentLedger: openVariant != "stale" && original.isCurrentLedger,
            replayMatched: openVariant != "unreplayed" && original.replayMatched)
        try await pause("open")
        return result
    }
    func advanceLedger() { ledgerRevision = UUID() }
    func advancePerformance() { performanceRevision = UUID() }
    func setOpenVariant(_ value: String) { openVariant = value }

    /// Offline invented ledger values; the evidence exercises the ordinary
    /// local-document branch, not a claim of real account/provider validation.
    func seedReturnRecord() throws -> UUID {
        func cash(_ id: String, at time: String, kind: LedgerCashKind, amount: String) throws -> LedgerEvent {
            try .init(id: id, accountID: "ordinary-b", effectiveAt: LedgerCSV.timestamp(time),
                      source: .init(sourceSystem: "fixture-local-ledger", externalTransactionID: id,
                                    evidence: "fixture-local-document"),
                      payload: .cash(.init(kind: kind, amount: Money(amount))))
        }
        ordinaryEvents = try [cash("return-deposit", at: "2025-12-01T15:00:00Z", kind: .deposit, amount: "1000"),
                              cash("return-interest", at: "2026-01-07T15:00:00Z", kind: .interest, amount: "100")]
        let original = try PortfolioSyntheticExample.input()
        let account = LedgerAccount(id: "ordinary-b", name: "独立空账户")
        let source = try PerformanceEvidence(id: "return-source", source: "fixture-local-document", kind: .localDocument,
            availableAt: LedgerCSV.timestamp("2025-12-01T14:00:00Z"), reference: "offline-cash-calendar", rawDocument: Data("invented offline ledger fixture".utf8))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt; formatter.dateFormat = "yyyy-MM-dd"
        var day = try LedgerCSV.timestamp("2025-12-05T21:00:00Z"), days: [PerformanceDayInput] = []
        let last = try LedgerCSV.timestamp("2026-01-07T21:00:00Z")
        while day <= last {
            if (2...6).contains(calendar.component(.weekday, from: day)) {
                days.append(.init(day: formatter.string(from: day), valuationAt: day, sessions: [], prices: []))
            }
            day = day.addingTimeInterval(86_400)
        }
        let request = try PerformanceRequest(accountID: account.id, calculatedAt: LedgerCSV.timestamp("2026-01-07T22:00:00Z"),
            calendar: .init(tradingDays: days.map(\.day), evidence: source), days: days,
            externalFlowsComplete: true, flowCompletenessEvidence: source)
        let input = PerformanceInput(request: request, ledgerRevision: ledgerRevision,
            accounts: original.accounts + [account], events: original.events + ordinaryEvents)
        let report = try PerformanceEngine.calculate(input), id = UUID()
        records[id] = SavedPerformanceReport(id: id, createdAt: request.calculatedAt, report: report,
            inputHash: String(repeating: "c", count: 64), reportHash: String(repeating: "d", count: 64),
            ledgerRevision: ledgerRevision, isCurrentLedger: true, replayMatched: true)
        return id
    }
}
@Suite("Portfolio workspace publication and local evidence") @MainActor
struct PortfolioWorkspaceTests {
    private func setup() async -> (PortfolioWorkspaceModel, PortfolioWorkspaceFake) {
        let storage = PortfolioWorkspaceFake()
        let injected = PortfolioWorkspaceModel(storage: storage)
        await injected.load()
        return (injected, storage)
    }
    private func prepare(_ model: PortfolioWorkspaceModel) async throws -> PerformancePreview {
        await model.prepare(try PortfolioSyntheticExample.input().request)
        return try #require(model.preview)
    }
    private func save(_ model: PortfolioWorkspaceModel, _ plan: PerformancePreview) async -> Bool {
        await model.save(id: plan.id, ledgerRevision: plan.ledgerRevision, performanceRevision: plan.performanceRevision)
    }
    private func generateQuickReports(_ model: PortfolioWorkspaceModel,
                                      at timestamp: String = "2026-01-07T22:00:00Z") async throws -> [InvestmentPeriodReport] {
        let account = try #require(model.selectedAccountID), baseline = try #require(model.preparationBaseline)
        await model.generatePeriodReports(accountID: account, baseline: baseline, at: try LedgerCSV.timestamp(timestamp))
        #expect(model.periodReports.count == 3 && !model.hasError)
        return model.periodReports
    }
    private func returnShareSetup() async throws -> (PortfolioWorkspaceModel, PortfolioWorkspaceFake, UUID, InvestmentPeriodReport) {
        let storage = PortfolioWorkspaceFake(), id = try await storage.seedReturnRecord()
        let model = PortfolioWorkspaceModel(storage: storage)
        await model.load(); await model.chooseAccount("ordinary-b")
        let reports = try await generateQuickReports(model)
        return (model, storage, id, try #require(reports.first { $0.period == .month }))
    }
    @Test func initializationDoesNotReadStorageOrSynthesizeAnAccount() async {
        let storage = PortfolioWorkspaceFake()
        let injected = PortfolioWorkspaceModel(storage: storage)
        #expect(injected.context == nil && injected.report == nil && injected.selectedAccountID == nil)
        #expect(injected.preparationBaseline == nil)
        #expect(await storage.reads == 0)
    }
    @Test func preparePinsBothRevisionsAndPreservesExactJSONBytes() async throws {
        let (model, storage) = await setup(), baseline = try #require(model.context)
        let request = try PortfolioSyntheticExample.input().request
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        let raw = try encoder.encode(request)
        await model.prepare(request, rawRequest: raw)
        let plan = try #require(model.preview)
        #expect(plan.ledgerRevision == baseline.ledger.revision && plan.performanceRevision == baseline.revision)
        #expect(await storage.lastRaw == raw)
        #expect(model.origin == .preview && model.savedReport == nil)
    }
    @Test func boundDraftRejectsEachChangedRevisionBeforeCallingStorage() async throws {
        for ledgerChanged in [true, false] {
            let (model, storage) = await setup(), original = try #require(model.preparationBaseline)
            if ledgerChanged { await storage.advanceLedger() } else { await storage.advancePerformance() }
            await model.load()
            let current = try #require(model.preparationBaseline)
            // Preserve the current session to isolate the revision precondition.
            let oldRevision = PortfolioPreparationBaseline(ledgerRevision: original.ledgerRevision,
                performanceRevision: original.performanceRevision, inputEpoch: current.inputEpoch)
            await model.prepare(try PortfolioSyntheticExample.input().request, baseline: oldRevision)
            #expect(model.hasError && model.preview == nil && model.report == nil)
            #expect(model.preparationBaseline == current && model.canPrepare)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func boundDraftCannotRegainApprovalAfterReloadReentryAccountRoundTripOrTransfer() async throws {
        for transition in ["reload", "reentry", "account", "transfer"] {
            let (model, storage) = await setup(), original = try #require(model.preparationBaseline)
            let request = try PortfolioSyntheticExample.input().request
            switch transition {
            case "reload": await model.load()
            case "reentry": model.disappear(); await model.load()
            case "account":
                await model.chooseAccount("ordinary-b")
                await model.chooseAccount(request.accountID)
            default:
                let operation = UUID()
                model.beginLedgerTransfer(operation)
                await model.refreshLedgerTransfer(operation)
                model.endLedgerTransfer(operation)
            }
            let current = try #require(model.preparationBaseline)
            #expect(current.ledgerRevision == original.ledgerRevision && current.performanceRevision == original.performanceRevision)
            #expect(current.inputEpoch != original.inputEpoch)
            await model.prepare(request, baseline: original)
            #expect(model.hasError && model.preview == nil && model.report == nil)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func ordinaryEditingKeepsDraftBaselineAndBoundPreparationPreservesExactBytes() async throws {
        let (model, storage) = await setup(), original = try #require(model.preparationBaseline)
        let request = try PortfolioSyntheticExample.input().request
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        let raw = try encoder.encode(request)
        model.draftChanged()
        #expect(model.preparationBaseline == original)
        await model.prepare(request, rawRequest: raw, baseline: original)
        let plan = try #require(model.preview)
        #expect(plan.ledgerRevision == original.ledgerRevision && plan.performanceRevision == original.performanceRevision)
        #expect(model.displayedRequest == request && model.origin == .preview)
        #expect(await storage.lastRaw == raw)
    }
    @Test func outdatedBoundDraftCancelsPreviousPreviewInsteadOfLeavingItSaveable() async throws {
        let (model, storage) = await setup(), current = try #require(model.preparationBaseline)
        let plan = try await prepare(model)
        let stale = PortfolioPreparationBaseline(ledgerRevision: current.ledgerRevision,
            performanceRevision: current.performanceRevision, inputEpoch: UUID())
        await model.prepare(try PortfolioSyntheticExample.input().request, baseline: stale)
        #expect(model.preview == nil && model.report == nil && !model.canSave && model.hasError)
        #expect(await save(model, plan) == false)
        #expect(await storage.prepares == 1)
        #expect(await storage.commits == 0)
    }
    @Test func lateBoundPreparationCannotPopulateAReopenedDifferentAccount() async throws {
        let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
        let gate = PortfolioWorkspaceGate(), request = try PortfolioSyntheticExample.input().request
        await storage.gate("prepare", gate)
        let old = Task { await model.prepare(request, baseline: baseline) }
        await gate.wait()
        model.disappear(); await model.load(); await model.chooseAccount("ordinary-b")
        let current = try #require(model.preparationBaseline)
        await gate.release(); await old.value
        #expect(model.selectedAccountID == "ordinary-b" && model.preparationBaseline == current)
        #expect(!model.isBusy && !model.hasError && model.preview == nil && model.report == nil && model.displayedRequest == nil)
        #expect(await storage.cancelled.count == 1)
        #expect(await storage.commits == 0)
    }
    @Test func successfulSaveRetainsVerifiedInputWhenListRefreshFailsButNotOldDraftApproval() async throws {
        let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
        let request = try PortfolioSyntheticExample.input().request
        await model.prepare(request, baseline: baseline)
        let plan = try #require(model.preview)
        await storage.fail("reports")
        #expect(await save(model, plan))
        #expect(model.origin == .frozen && model.savedReport?.replayMatched == true)
        #expect(model.report == plan.report && model.displayedRequest == request && model.listError != nil)
        #expect(model.inputEpoch == baseline.inputEpoch)
        #expect(model.preparationBaseline?.performanceRevision != baseline.performanceRevision)
        await model.prepare(request, baseline: baseline)
        #expect(model.hasError && !model.canSave && model.preview == nil)
        #expect(await storage.prepares == 1)
        #expect(await storage.commits == 1)
    }
    @Test func wrongAccountIsRejectedBeforeStorageAndSelectionClearsPreviousApproval() async throws {
        let (model, storage) = await setup()
        let old = try await prepare(model)
        await model.chooseAccount("ordinary-b")
        #expect(model.preview == nil && model.report == nil)
        #expect(await storage.cancelled.contains(old.id))
        await model.prepare(try PortfolioSyntheticExample.input().request)
        #expect(model.hasError && model.preview == nil)
        #expect(await storage.prepares == 1)
        #expect(await save(model, old) == false)
        #expect(await storage.commits == 0)
    }
    @Test func latePreviewCannotPublishOrReleaseANewerBusyOperation() async throws {
        let (model, storage) = await setup(), firstGate = PortfolioWorkspaceGate(), newGate = PortfolioWorkspaceGate()
        await storage.gate("prepare", firstGate)
        let request = try PortfolioSyntheticExample.input().request
        let first = Task { await model.prepare(request) }
        await firstGate.wait()
        model.disappear()
        await storage.gate("context", newGate)
        let newer = Task { await model.load() }
        await newGate.wait()
        await firstGate.release(); await first.value
        #expect(model.isBusy && model.preview == nil && model.report == nil)
        #expect(await storage.cancelled.count == 1)
        await newGate.release(); await newer.value
        #expect(!model.isBusy && model.context != nil)
    }
    @Test func alteredApprovalIsRejectedWithoutCommit() async throws {
        let (model, storage) = await setup(), plan = try await prepare(model)
        #expect(await model.save(id: UUID(), ledgerRevision: plan.ledgerRevision, performanceRevision: plan.performanceRevision) == false)
        #expect(await model.save(id: plan.id, ledgerRevision: UUID(), performanceRevision: plan.performanceRevision) == false)
        #expect(await storage.commits == 0)
    }
    @Test func transientFailureKeepsExactPlanForRetryAndSuccessRefreshesPerformanceBaseline() async throws {
        let (model, storage) = await setup(), plan = try await prepare(model)
        await storage.fail("commit", error: .injectedFailure)
        #expect(await save(model, plan) == false)
        #expect(model.preview?.id == plan.id && model.canSave && model.hasError)
        #expect(await save(model, plan))
        #expect(model.preview == nil && model.origin == .frozen && model.saved.count == 1)
        #expect(model.context?.revision != plan.performanceRevision)
        let next = try await prepare(model)
        #expect(next.performanceRevision == model.context?.revision)
    }
    @Test func knownLedgerChangesRefreshFrozenLabelWithoutReplacingInputOrNumbers() async throws {
        // The commit records its original ledger metadata, then another page
        // advances the ledger before the model receives that successful result.
        let (model, storage) = await setup(), plan = try await prepare(model), committed = PortfolioWorkspaceGate()
        await storage.gate("committed", committed)
        await storage.fail("reports") // Prove that context refresh alone updates the label.
        let saving = Task { await save(model, plan) }
        await committed.wait(); await storage.advanceLedger(); await committed.release()
        #expect(await saving.value)
        let frozen = try #require(model.savedReport)
        #expect(!frozen.isCurrentLedger && model.listError != nil)
        #expect(model.context?.ledger.revision != frozen.ledgerRevision)
        #expect(frozen.report == plan.report && model.report == plan.report)
        #expect(frozen.ledgerRevision == plan.ledgerRevision && frozen.replayMatched)

        // A later explicit list-only refresh must also update an already open
        // report, without depending on a successful context refresh.
        let (other, secondStore) = await setup(), second = try await prepare(other)
        #expect(await save(other, second))
        #expect(other.savedReport?.isCurrentLedger == true)
        let summaryGate = PortfolioWorkspaceGate()
        await secondStore.advanceLedger(); await secondStore.gate("reports", summaryGate)
        let refreshing = Task { await other.reloadSaved() }
        await summaryGate.wait()
        #expect(other.savedReport?.isCurrentLedger == true) // No unread revision is guessed.
        await summaryGate.release(); await refreshing.value
        #expect(other.savedReport?.isCurrentLedger == false)
        #expect(other.savedReport?.report == second.report && other.report == second.report)
        #expect(other.savedReport?.ledgerRevision == second.ledgerRevision)
    }
    @Test func staleCommitCleansOriginalPlanAndNeverRebasesApproval() async throws {
        let (model, storage) = await setup(), plan = try await prepare(model)
        await storage.advanceLedger()
        #expect(await save(model, plan) == false)
        #expect(model.preview == nil && model.report == nil && model.context == nil && !model.canSave && model.hasError)
        #expect(await storage.cancelled.contains(plan.id))
    }
    @Test func departedCommitCompletesStorageWithoutPublishingOldPageResult() async throws {
        let (model, storage) = await setup(), plan = try await prepare(model), gate = PortfolioWorkspaceGate()
        await storage.gate("commit", gate)
        let task = Task { await save(model, plan) }
        await gate.wait(); model.disappear()
        await gate.release(); #expect(await task.value)
        #expect(model.report == nil && model.savedReport == nil && model.message == nil && !model.isBusy)
        #expect(await storage.records.count == 1)
        #expect(await storage.cancelled.isEmpty)
        await model.load()
        #expect(model.saved.count == 1 && model.report == nil)
    }
    @Test func departedCommitFailureDoesNotOverwriteReopenedPage() async throws {
        let (model, storage) = await setup(), plan = try await prepare(model), gate = PortfolioWorkspaceGate()
        await storage.gate("commit", gate); await storage.fail("commit", error: .injectedFailure)
        let task = Task { await save(model, plan) }
        await gate.wait(); model.disappear(); await model.load()
        #expect(model.isBusy)
        await gate.release(); #expect(await task.value == false)
        #expect(model.context != nil && !model.isBusy && model.message == nil && !model.hasError)
        #expect(await storage.cancelled.contains(plan.id))
    }
    @Test func openFailureDoesNotExposePreviousReportCachedNumbers() async throws {
        let (model, storage) = await setup(), plan = try await prepare(model)
        #expect(await save(model, plan))
        await storage.fail("open")
        await model.open(plan.id)
        #expect(model.report == nil && model.savedReport == nil && model.origin == .none && model.hasError)
    }
    @Test func foreignAccountReportCannotPopulateSelectedAccount() async throws {
        let (model, _) = await setup(), plan = try await prepare(model)
        #expect(await save(model, plan))
        await model.chooseAccount("ordinary-b")
        await model.open(plan.id)
        #expect(model.report == nil && model.savedReport == nil && model.hasError)
        #expect(model.selectedAccountID == "ordinary-b")
    }
    @Test func reportListFailureDoesNotDisableHealthyLedgerOrEvidencePreparation() async throws {
        let (model, storage) = await setup()
        await storage.fail("reports"); await model.reloadSaved()
        #expect(model.listError != nil && model.context != nil && model.canPrepare)
        #expect(try await prepare(model).report.daily.count == 4)
    }
    @Test func explicitSyntheticExampleNeverCallsPreparationOrChangesOrdinaryContext() async throws {
        let (model, storage) = await setup(), context = model.context
        await model.chooseAccount("ordinary-b")
        await model.showSyntheticExample()
        let report = try #require(model.report)
        #expect(model.origin == .synthetic && model.preview == nil && !model.canSave)
        #expect(model.selectedAccountID == "ordinary-b" && model.context == context)
        #expect(report.input.request.accountID == "SYNTHETIC-PERFORMANCE")
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
        #expect(report.daily.last?.nav == (try Money("1004")))
        #expect(report.risk.sharpe.value == nil)
    }
    @Test func quickPeriodReportsPublishThreeWindowsFromOneBaselineWithoutPreparingOrCommitting() async throws {
        let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
        let account = try #require(model.selectedAccountID), reads = await storage.reads
        let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
        await model.generatePeriodReports(accountID: account, baseline: baseline, at: cutoff)
        #expect(model.periodReports.map(\.period) == [.year, .quarter, .month])
        #expect(model.periodReports.allSatisfy {
            $0.accountID == account && $0.ledgerRevision == baseline.ledgerRevision && $0.generatedAt == cutoff
        })
        #expect(model.periodReports.allSatisfy { $0.containsSyntheticRecords })
        #expect(model.preparationBaseline == baseline && !model.isBusy && !model.hasError)
        #expect(model.preview == nil && model.report == nil && model.savedReport == nil && !model.canSave)
        #expect(await storage.reads == reads + 2)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
        #expect(await storage.records.isEmpty)
    }
    @Test func quickPeriodReportsForOrdinaryEmptyAccountContainRealZeroWithoutSyntheticContamination() async throws {
        let (model, storage) = await setup()
        await model.chooseAccount("ordinary-b")
        let baseline = try #require(model.preparationBaseline), zero = try Money("0")
        await model.generatePeriodReports(accountID: "ordinary-b", baseline: baseline,
                                          at: try LedgerCSV.timestamp("2026-01-07T22:00:00Z"))
        #expect(model.periodReports.count == 3 && !model.hasError)
        for report in model.periodReports {
            #expect(report.accountID == "ordinary-b" && !report.containsSyntheticRecords)
            #expect(report.bookedPnL == zero && report.realizedPnL == zero && report.realizedEventCount == 0)
            #expect(report.openingCash == zero && report.closingCash == zero)
            #expect(report.timeline.isEmpty && report.contributions.isEmpty)
        }
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
    }
    @Test func queuedQuickPeriodRequestRejectsChangedAccountOrInputEpochBeforeReadingStorage() async throws {
        for transition in ["account", "epoch"] {
            let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
            let account = try #require(model.selectedAccountID)
            if transition == "account" { await model.chooseAccount("ordinary-b") }
            else { await model.load() }
            let current = try #require(model.preparationBaseline), reads = await storage.reads
            await model.generatePeriodReports(accountID: account, baseline: baseline,
                                              at: try LedgerCSV.timestamp("2026-01-07T22:00:00Z"))
            #expect(model.periodReports.isEmpty && !model.isBusy)
            #expect(model.preparationBaseline == current)
            #expect(await storage.reads == reads)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func quickPeriodInitialReadRejectsEitherChangedRevision() async throws {
        for ledgerChanged in [true, false] {
            let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
            let account = try #require(model.selectedAccountID), reads = await storage.reads
            if ledgerChanged { await storage.advanceLedger() } else { await storage.advancePerformance() }
            await model.generatePeriodReports(accountID: account, baseline: baseline,
                                              at: try LedgerCSV.timestamp("2026-01-07T22:00:00Z"))
            #expect(model.periodReports.isEmpty && model.hasError && !model.isBusy)
            #expect(await storage.reads == reads + 1)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func quickPeriodRecheckRejectsEitherRevisionChangedAfterInitialSnapshotOrDuringRecheck() async throws {
        for phase in ["after-initial", "before-recheck"] {
            for ledgerChanged in [true, false] {
                let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
                let account = try #require(model.selectedAccountID), reads = await storage.reads
                let gate = PortfolioWorkspaceGate()
                let key = phase == "after-initial" ? "context:\(reads + 1)" : "context:\(reads + 2):before"
                await storage.gate(key, gate)
                let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
                let task = Task { await model.generatePeriodReports(accountID: account, baseline: baseline, at: cutoff) }
                await gate.wait()
                #expect(model.isBusy && model.periodReports.isEmpty)
                if ledgerChanged { await storage.advanceLedger() } else { await storage.advancePerformance() }
                await gate.release(); await task.value
                #expect(model.periodReports.isEmpty && model.hasError && !model.isBusy)
                #expect(await storage.reads == reads + 2)
                #expect(await storage.prepares == 0)
                #expect(await storage.commits == 0)
            }
        }
    }
    @Test func departedQuickPeriodSuccessOrFailureCannotPublishIntoANewAccountOrReleaseItsBusyOperation() async throws {
        for fails in [false, true] {
            let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
            let account = try #require(model.selectedAccountID), read = await storage.reads + 1
            let oldGate = PortfolioWorkspaceGate(), newGate = PortfolioWorkspaceGate()
            let key = "context:\(read)"
            await storage.gate(key, oldGate)
            if fails { await storage.fail(key) }
            let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
            let old = Task { await model.generatePeriodReports(accountID: account, baseline: baseline, at: cutoff) }
            await oldGate.wait()
            model.disappear(); await model.load(); await model.chooseAccount("ordinary-b")
            let current = try #require(model.preparationBaseline), newRead = await storage.reads + 1
            await storage.gate("context:\(newRead)", newGate)
            let newer = Task { await model.generatePeriodReports(accountID: "ordinary-b", baseline: current, at: cutoff) }
            await newGate.wait()
            let currentMessage = model.message
            await oldGate.release(); await old.value
            #expect(model.selectedAccountID == "ordinary-b" && model.preparationBaseline == current)
            #expect(model.isBusy && model.periodReports.isEmpty && !model.hasError && model.message == currentMessage)
            await newGate.release(); await newer.value
            #expect(!model.isBusy && !model.hasError && model.periodReports.count == 3)
            #expect(model.periodReports.allSatisfy { $0.accountID == "ordinary-b" && !$0.containsSyntheticRecords })
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func cancellingQuickPeriodRequestSuppressesLatePublicationAndAllowsANewRequest() async throws {
        let (model, storage) = await setup(), baseline = try #require(model.preparationBaseline)
        let account = try #require(model.selectedAccountID), read = await storage.reads + 1
        let gate = PortfolioWorkspaceGate(), cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
        await storage.gate("context:\(read)", gate)
        let old = Task { await model.generatePeriodReports(accountID: account, baseline: baseline, at: cutoff) }
        await gate.wait(); model.cancelPeriodReports()
        #expect(!model.isBusy && model.periodReports.isEmpty && !model.hasError)
        await model.chooseAccount("ordinary-b")
        let current = try #require(model.preparationBaseline)
        await model.generatePeriodReports(accountID: "ordinary-b", baseline: current, at: cutoff)
        let expected = model.periodReports, message = model.message
        #expect(expected.count == 3)
        await gate.release(); await old.value
        #expect(model.periodReports == expected && model.message == message && !model.isBusy && !model.hasError)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
    }
    @Test func quickPeriodCancellationDoesNotCancelAnUnrelatedPreparation() async throws {
        let (model, storage) = await setup(), gate = PortfolioWorkspaceGate()
        let request = try PortfolioSyntheticExample.input().request
        await storage.gate("prepare", gate)
        let task = Task { await model.prepare(request) }
        await gate.wait(); model.cancelPeriodReports()
        #expect(model.isBusy && model.periodReports.isEmpty)
        #expect(await storage.cancelled.isEmpty)
        await gate.release(); await task.value
        #expect(model.preview != nil && model.canSave && !model.hasError)
        #expect(await storage.prepares == 1)
        #expect(await storage.commits == 0)
    }
    @Test func quickPeriodResultsClearWithAccountChangeDepartureTransferAndDraftReset() async throws {
        for transition in ["account", "departure", "transfer", "draft"] {
            let (model, _) = await setup(), baseline = try #require(model.preparationBaseline)
            let account = try #require(model.selectedAccountID)
            await model.generatePeriodReports(accountID: account, baseline: baseline,
                                              at: try LedgerCSV.timestamp("2026-01-07T22:00:00Z"))
            #expect(model.periodReports.count == 3)
            switch transition {
            case "account": await model.chooseAccount("ordinary-b")
            case "departure": model.disappear()
            case "transfer":
                let transfer = UUID()
                model.beginLedgerTransfer(transfer)
                #expect(model.periodReports.isEmpty && model.isBusy)
                await model.refreshLedgerTransfer(transfer); model.endLedgerTransfer(transfer)
            default: model.draftChanged()
            }
            #expect(model.periodReports.isEmpty)
        }
    }
    @Test func directPeriodShareReturnsMonthlyVerifiedZeroWithoutObservingBusyTransitions() async throws {
        let (model, storage) = await setup()
        await model.chooseAccount("ordinary-b")
        let baseline = try #require(model.preparationBaseline), reads = await storage.reads
        let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
        // One awaited call must return the card even without a UI observer or
        // a suspension inserted between generation and sharing.
        let result = await model.generatePeriodShare(accountID: "ordinary-b", baseline: baseline, at: cutoff)
        let snapshot = try #require(result)
        var options = InvestmentShareOptions(); options.showAmounts = true
        #expect(snapshot.periodSelection == .month && snapshot.card(options: options).amount == "0.00 USD")
        #expect(model.periodReports.count == 3 && model.preparationBaseline == baseline)
        #expect(!model.isBusy && !model.hasError && model.report == nil && model.savedReport == nil)
        #expect(await storage.reads == reads + 4)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
        #expect(await storage.records.isEmpty)
    }
    @Test func directPeriodShareStopsWhenEitherGenerationReadFailsWithoutCheckingAnOldReport() async throws {
        for failingRead in [1, 2] {
            let (model, storage) = await setup()
            _ = try await generateQuickReports(model)
            let account = try #require(model.selectedAccountID), baseline = try #require(model.preparationBaseline)
            let reads = await storage.reads, gate = PortfolioWorkspaceGate()
            let key = "context:\(reads + failingRead)"
            await storage.gate(key, gate); await storage.fail(key)
            let cutoff = try LedgerCSV.timestamp("2026-01-08T22:00:00Z")
            let request = Task { await model.generatePeriodShare(accountID: account, baseline: baseline, at: cutoff) }
            await gate.wait()
            #expect(model.isBusy && model.periodReports.isEmpty)
            await gate.release()
            #expect(await request.value == nil)
            #expect(model.hasError && !model.isBusy && model.periodReports.isEmpty)
            #expect(await storage.reads == reads + failingRead)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func directPeriodShareRecheckFailureEndsRequestAndAllowsExplicitRetry() async throws {
        let (model, storage) = await setup()
        await model.chooseAccount("ordinary-b")
        let baseline = try #require(model.preparationBaseline), reads = await storage.reads
        let gate = PortfolioWorkspaceGate(), key = "context:\(reads + 3)"
        await storage.gate(key, gate); await storage.fail(key)
        let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
        let request = Task { await model.generatePeriodShare(accountID: "ordinary-b", baseline: baseline, at: cutoff) }
        await gate.wait()
        #expect(model.isBusy && model.periodReports.count == 3)
        await gate.release()
        #expect(await request.value == nil)
        #expect(model.hasError && !model.isBusy && model.periodReports.count == 3)
        #expect(await storage.reads == reads + 3)
        // Failure returns to the caller; only a new explicit request retries.
        let retry = await model.generatePeriodShare(accountID: "ordinary-b", baseline: baseline, at: cutoff)
        #expect(retry?.periodSelection == .month && !model.hasError && !model.isBusy)
        #expect(await storage.reads == reads + 7)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
    }
    @Test func directPeriodShareCancellationOrDepartureCannotPublishIntoANewerRequest() async throws {
        for pausedRead in [1, 3] {
            for departed in [false, true] {
                let (model, storage) = await setup()
                let account = try #require(model.selectedAccountID), baseline = try #require(model.preparationBaseline)
                let reads = await storage.reads, oldGate = PortfolioWorkspaceGate(), newGate = PortfolioWorkspaceGate()
                await storage.gate("context:\(reads + pausedRead)", oldGate)
                let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
                let old = Task { await model.generatePeriodShare(accountID: account, baseline: baseline, at: cutoff) }
                await oldGate.wait()
                if departed { model.disappear(); await model.load() }
                else { old.cancel(); model.cancelPeriodReports() }
                await model.chooseAccount("ordinary-b")
                let current = try #require(model.preparationBaseline), newRead = await storage.reads + 1
                await storage.gate("context:\(newRead)", newGate)
                let newer = Task { await model.generatePeriodShare(accountID: "ordinary-b", baseline: current, at: cutoff) }
                await newGate.wait()
                let message = model.message
                await oldGate.release()
                #expect(await old.value == nil)
                #expect(model.isBusy && !model.hasError && model.message == message && model.periodReports.isEmpty)
                #expect(model.preparationBaseline == current && model.selectedAccountID == "ordinary-b")
                await newGate.release()
                let result = await newer.value
                #expect(result?.periodSelection == .month && !model.isBusy && !model.hasError)
                #expect(model.periodReports.allSatisfy { $0.accountID == "ordinary-b" && !$0.containsSyntheticRecords })
                #expect(await storage.prepares == 0)
                #expect(await storage.commits == 0)
            }
        }
    }
    @Test func quickPeriodShareSupportsVerifiedZeroWithoutPreparingOrSavingAValuationReport() async throws {
        let (model, storage) = await setup()
        await model.chooseAccount("ordinary-b")
        let reports = try await generateQuickReports(model), baseline = try #require(model.preparationBaseline)
        let initialReads = await storage.reads
        var options = InvestmentShareOptions(); options.showAmounts = true
        for report in reports {
            let result = await model.preparePeriodShare(report)
            let snapshot = try #require(result), card = snapshot.card(options: options)
            #expect(card.amount == "0.00 USD" && card.profitLabel == "已入账收益")
            #expect(!snapshot.supportsReturn && !snapshot.supportsHoldingNames)
        }
        #expect(model.periodReports == reports && model.preparationBaseline == baseline)
        #expect(model.report == nil && model.savedReport == nil && model.preview == nil && !model.canSave)
        #expect(!model.isBusy && !model.hasError)
        #expect(await storage.reads == initialReads + 6)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
        #expect(await storage.records.isEmpty)
        #expect(await storage.plans.isEmpty)
        #expect(await storage.cancelled.isEmpty)
    }
    @Test func quickPeriodShareRejectsOtherAccountOrReplacedReportBeforeReadingStorage() async throws {
        for transition in ["account", "regenerated", "cancelled", "reloaded"] {
            let (model, storage) = await setup()
            let reports = try await generateQuickReports(model), report = try #require(reports.first)
            switch transition {
            case "account": await model.chooseAccount("ordinary-b")
            case "regenerated": _ = try await generateQuickReports(model, at: "2026-01-08T22:00:00Z")
            case "cancelled": model.cancelPeriodReports()
            default: await model.load()
            }
            let expected = model.periodReports, expectedMessage = model.message, reads = await storage.reads
            #expect(await model.preparePeriodShare(report) == nil)
            #expect(model.periodReports == expected && model.message == expectedMessage && !model.isBusy && !model.hasError)
            #expect(await storage.reads == reads)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func quickPeriodShareRejectsEitherRevisionChangedBeforeOrDuringItsRecheck() async throws {
        for duringRead in [false, true] {
            for ledgerChanged in [true, false] {
                let (model, storage) = await setup()
                let reports = try await generateQuickReports(model), report = try #require(reports.first)
                let reads = await storage.reads
                let snapshot: InvestmentShareSnapshot?
                if duringRead {
                    let gate = PortfolioWorkspaceGate()
                    await storage.gate("context:\(reads + 1):before", gate)
                    let sharing = Task { await model.preparePeriodShare(report) }
                    await gate.wait()
                    #expect(model.isBusy)
                    if ledgerChanged { await storage.advanceLedger() } else { await storage.advancePerformance() }
                    await gate.release(); snapshot = await sharing.value
                } else {
                    if ledgerChanged { await storage.advanceLedger() } else { await storage.advancePerformance() }
                    snapshot = await model.preparePeriodShare(report)
                }
                #expect(snapshot == nil && model.periodReports.isEmpty && model.context == nil)
                #expect(model.hasError && !model.isBusy && model.report == nil && model.savedReport == nil)
                #expect(await storage.reads == reads + 1)
                #expect(await storage.prepares == 0)
                #expect(await storage.commits == 0)
            }
        }
    }
    @Test func cancelledOrDepartedPeriodShareCannotPublishIntoANewerAccountOrReleaseItsBusyState() async throws {
        for departed in [false, true] {
            for fails in [false, true] {
                let (model, storage) = await setup()
                let reports = try await generateQuickReports(model), report = try #require(reports.first)
                let read = await storage.reads + 1, key = "context:\(read)"
                let oldGate = PortfolioWorkspaceGate(), newGate = PortfolioWorkspaceGate()
                await storage.gate(key, oldGate)
                if fails { await storage.fail(key) }
                let sharing = Task { await model.preparePeriodShare(report) }
                await oldGate.wait()
                if departed { model.disappear(); await model.load() }
                else { model.cancelPeriodReports() }
                #expect(!model.isBusy && model.periodReports.isEmpty)
                await model.chooseAccount("ordinary-b")
                let baseline = try #require(model.preparationBaseline), nextRead = await storage.reads + 1
                await storage.gate("context:\(nextRead)", newGate)
                let cutoff = try LedgerCSV.timestamp("2026-01-07T22:00:00Z")
                let newer = Task { await model.generatePeriodReports(accountID: "ordinary-b", baseline: baseline, at: cutoff) }
                await newGate.wait()
                let currentMessage = model.message
                await oldGate.release()
                #expect(await sharing.value == nil)
                #expect(model.isBusy && model.periodReports.isEmpty && !model.hasError && model.message == currentMessage)
                #expect(model.selectedAccountID == "ordinary-b" && model.preparationBaseline == baseline)
                await newGate.release(); await newer.value
                #expect(!model.isBusy && !model.hasError && model.periodReports.count == 3)
                #expect(model.periodReports.allSatisfy { $0.accountID == "ordinary-b" })
                #expect(await storage.prepares == 0)
                #expect(await storage.commits == 0)
            }
        }
    }
    @Test func taskCancelledPeriodShareSuppressesLateSuccessAndFailureAndCanBeRetried() async throws {
        for fails in [false, true] {
            let (model, storage) = await setup()
            let reports = try await generateQuickReports(model), report = try #require(reports.first)
            let read = await storage.reads + 1, key = "context:\(read)", gate = PortfolioWorkspaceGate()
            await storage.gate(key, gate)
            if fails { await storage.fail(key) }
            let sharing = Task { await model.preparePeriodShare(report) }
            await gate.wait(); sharing.cancel(); await gate.release()
            #expect(await sharing.value == nil)
            #expect(model.periodReports == reports && !model.isBusy && !model.hasError && model.message == nil)
            #expect(await model.preparePeriodShare(report) != nil)
            #expect(!model.isBusy && !model.hasError)
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func periodShareReadFailureDoesNotPublishButKeepsTheSameReportAvailableForRetry() async throws {
        let (model, storage) = await setup()
        let reports = try await generateQuickReports(model), report = try #require(reports.first)
        await storage.fail("context")
        #expect(await model.preparePeriodShare(report) == nil)
        #expect(model.periodReports == reports && model.hasError && !model.isBusy)
        #expect(model.report == nil && model.savedReport == nil)
        #expect(await model.preparePeriodShare(report) != nil)
        #expect(model.periodReports == reports && !model.hasError && !model.isBusy)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
        #expect(await storage.cancelled.isEmpty)
    }
    @Test func periodShareReopensCurrentAccountNAVWithoutCreatingOrSavingAnotherReport() async throws {
        let (model, storage, id, report) = try await returnShareSetup()
        let baseline = try #require(model.preparationBaseline), reads = await storage.reads
        let result = await model.preparePeriodShare(report), snapshot = try #require(result)
        var options = InvestmentShareOptions(); options.showAmounts = true
        #expect(snapshot.supportsReturn && snapshot.periodSelection == .month)
        #expect(snapshot.card(options: options).amount == "+100.00 USD")
        #expect(await storage.opened == [id])
        #expect(await storage.reads == reads + 2)
        #expect(await storage.prepares == 0)
        #expect(await storage.commits == 0)
        #expect(await storage.cancelled.isEmpty)
        #expect(model.preparationBaseline == baseline && model.report == nil && model.preview == nil)
        #expect(!model.hasError && !model.isBusy)
    }
    @Test func periodShareNeverReusesCurrentNAVForAnotherAccountOrUncoveredPeriod() async throws {
        let (model, storage, _, _) = try await returnShareSetup()
        let yearly = try #require(model.periodReports.first { $0.period == .year })
        let annualShare = await model.preparePeriodShare(yearly)
        #expect(annualShare != nil && annualShare?.supportsReturn == false)
        #expect(await storage.opened.isEmpty)
        let other = try #require(model.context?.ledger.accounts.first { $0.id != "ordinary-b" }?.id)
        await model.chooseAccount(other)
        let reports = try await generateQuickReports(model), monthly = try #require(reports.first { $0.period == .month })
        let otherShare = await model.preparePeriodShare(monthly)
        #expect(otherShare != nil && otherShare?.supportsReturn == false)
        #expect(await storage.opened.isEmpty)
    }
    @Test func periodShareKeepsBookedFactsButNeverFallbackReturnAfterNAVReadOrReplayFailure() async throws {
        for failure in ["reports", "open", "identity", "hash", "unreplayed"] {
            let (model, storage, _, report) = try await returnShareSetup()
            if ["reports", "open"].contains(failure) { await storage.fail(failure) }
            else { await storage.setOpenVariant(failure) }
            let result = await model.preparePeriodShare(report), snapshot = try #require(result)
            var options = InvestmentShareOptions(); options.showAmounts = true
            #expect(!snapshot.supportsReturn && snapshot.card(options: options).amount == "+100.00 USD")
            #expect(!model.hasError && !model.isBusy && model.periodReports.contains(report))
            #expect(await storage.prepares == 0)
            #expect(await storage.commits == 0)
        }
    }
    @Test func periodShareRejectsStaleOpenedNAVAndEitherRevisionChangingDuringEvidenceRead() async throws {
        let (staleModel, staleStorage, _, staleReport) = try await returnShareSetup()
        await staleStorage.setOpenVariant("stale")
        #expect(await staleModel.preparePeriodShare(staleReport) == nil)
        #expect(staleModel.hasError && staleModel.context == nil && staleModel.periodReports.isEmpty)
        for stage in ["reports", "open", "final-context"] {
            for ledgerChanged in [true, false] {
                let (model, storage, _, report) = try await returnShareSetup()
                let gate = PortfolioWorkspaceGate(), reads = await storage.reads
                await storage.gate(stage == "final-context" ? "context:\(reads + 2):before" : stage, gate)
                let sharing = Task { await model.preparePeriodShare(report) }
                await gate.wait()
                if ledgerChanged { await storage.advanceLedger() } else { await storage.advancePerformance() }
                await gate.release()
                #expect(await sharing.value == nil)
                #expect(model.hasError && !model.isBusy && model.context == nil && model.periodReports.isEmpty)
                #expect(await storage.prepares == 0)
                #expect(await storage.commits == 0)
            }
        }
    }
    @Test func lateNAVSuccessOrFailureCannotPublishAfterDepartureOrClearNewAccountBusyState() async throws {
        for stage in ["reports", "open"] {
            for fails in [false, true] {
                let (model, storage, _, report) = try await returnShareSetup()
                let oldGate = PortfolioWorkspaceGate(), newGate = PortfolioWorkspaceGate()
                await storage.gate(stage, oldGate)
                if fails { await storage.fail(stage) }
                let old = Task { await model.preparePeriodShare(report) }
                await oldGate.wait()
                model.disappear(); await model.load()
                let other = try #require(model.context?.ledger.accounts.first { $0.id != "ordinary-b" }?.id)
                await model.chooseAccount(other)
                let baseline = try #require(model.preparationBaseline), read = await storage.reads + 1
                await storage.gate("context:\(read)", newGate)
                let newer = Task { await model.generatePeriodReports(accountID: other, baseline: baseline,
                    at: try LedgerCSV.timestamp("2026-01-07T22:00:00Z")) }
                await newGate.wait()
                let message = model.message
                await oldGate.release()
                #expect(await old.value == nil)
                #expect(model.isBusy && !model.hasError && model.message == message && model.periodReports.isEmpty)
                #expect(model.preparationBaseline == baseline && model.selectedAccountID == other)
                await newGate.release()
                #expect(try await newer.value)
                #expect(!model.isBusy && !model.hasError)
            }
        }
    }
    @Test func cancelledNAVReopenReturnsNoSnapshotAndAllowsExplicitRetry() async throws {
        let (model, storage, _, report) = try await returnShareSetup()
        let gate = PortfolioWorkspaceGate()
        await storage.gate("open", gate)
        let task = Task { await model.preparePeriodShare(report) }
        await gate.wait(); task.cancel(); await gate.release()
        #expect(await task.value == nil)
        #expect(!model.hasError && !model.isBusy && model.periodReports.contains(report))
        let retry = await model.preparePeriodShare(report)
        #expect(retry?.supportsReturn == true && !model.isBusy)
    }
    @Test func localFormNeverInventsCalendarEvidenceOrTimezone() throws {
        let draft = PortfolioInputDraft()
        #expect(throws: (any Error).self) { try draft.build(accountID: "ordinary", calculatedAt: Date()) }
        var proof = PortfolioEvidenceDraft(); proof.source = "Local"; proof.reference = "v1"; proof.text = "source"
        proof.availableAt = "2026-01-01T12:00:00"
        #expect(throws: (any Error).self) { try proof.build() }
        proof.availableAt = "2026-01-01T12:00:00.0004Z"
        let value = try proof.build()
        #expect(value.availableAt == (try LedgerCSV.timestamp(proof.availableAt)))
        #expect(value.rawDocument == Data("source".utf8) && value.kind == .userConfirmed)
        proof.kind = .synthetic
        #expect(throws: PortfolioDraftError.missingField) { try proof.build() }
    }
    @Test func localFormKeepsBlankPricesDistinctFromZeroAndRejectsMalformedRateRows() throws {
        var quote = PortfolioQuoteDraft()
        quote.instrumentID = "equity:X"; quote.opensAt = "2026-01-02T14:30:00Z"; quote.closesAt = "2026-01-02T21:00:00Z"
        quote.quoteAt = quote.closesAt; quote.bid = "0"; quote.ask = ""
        var proof = PortfolioEvidenceDraft(); proof.source = "Local"; proof.reference = "v1"; proof.text = "explicit source"; proof.availableAt = quote.quoteAt
        quote.priceEvidence = proof; proof.id = UUID().uuidString; quote.sessionEvidence = proof
        let result = try quote.build().1
        #expect(result.bid == (try Money("0")) && result.ask == nil && result.last == nil)
        #expect(result.basis == .raw && result.timeliness == .endOfDay)
        var rate = PortfolioRateDraft(); rate.points = "0.25,4.25,extra"
        #expect(throws: PortfolioDraftError.invalidRows) { try rate.build() }
    }
    @Test func advancedInputPreservesSourceBytesAndSubmillisecondDates() throws {
        let input = try PortfolioSyntheticExample.input()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(input.request), text = try #require(String(data: bytes, encoding: .utf8))
        let (request, raw) = try PortfolioInputDraft.decodeJSON(text)
        #expect(request == input.request && raw == bytes)
        #expect(throws: (any Error).self) { try PortfolioInputDraft.decodeJSON("{\"accountID\":\"only\"}") }
    }
    @Test func publishedRatePastePreservesReplayEnvelopeAndDoesNotInventReleaseTimes() throws {
        var local = PortfolioPublishedRateDraft()
        local.document.source = "FRED local document"
        local.document.reference = "explicit-vintage"
        local.document.availableAt = "2026-01-06T12:00:00Z"
        local.document.text = #"{"units":"lin","count":2,"offset":0,"observations":[{"date":"2026-01-02","realtime_start":"2026-01-02","realtime_end":"9999-12-31","value":"4.25"},{"date":"2026-01-05","realtime_start":"2026-01-05","realtime_end":"9999-12-31","value":"."}]}"#
        let missing = try local.parse()
        #expect(missing.curves.isEmpty && missing.missingValueDays == ["2026-01-05"] && missing.unverifiedReleaseDays == ["2026-01-02"])
        let release = PublishedRateRelease(observationDay: "2026-01-02", realtimeStart: "2026-01-02", realtimeEnd: "9999-12-31",
            availability: .instant(try LedgerCSV.timestamp("2026-01-02T21:00:00Z"), evidence: "explicit release evidence"))
        local.releaseJSON = try #require(String(data: JSONEncoder().encode([release]), encoding: .utf8))
        let imported = try local.parse(), curve = try #require(imported.curves.first)
        #expect(imported.curves.count == 1 && curve.sourceVersion == FREDPublishedRateImport.version && curve.sourceInput != nil)
        #expect(curve.evidence.rawDocument == Data(local.document.text.utf8))
        var form = PortfolioInputDraft()
        form.tradingDays = "2026-01-02"; form.calendarEvidence = local.document
        form.calendarEvidence.id = "calendar-proof"; form.calendarEvidence.text = "Explicit calendar"
        form.importedRateCurves = imported.curves
        let request = try form.build(accountID: "ordinary", calculatedAt: LedgerCSV.timestamp("2026-01-07T12:00:00Z"))
        #expect(request.rateCurves == imported.curves)
        try FREDPublishedRateImport.validateFrozenCurve(request.rateCurves[0])
    }

}
