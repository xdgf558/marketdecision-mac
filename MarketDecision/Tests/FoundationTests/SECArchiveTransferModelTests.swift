import Foundation
import Testing
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private enum SECArchiveModelFailure: Error { case injected }

/// Handshake, never a scheduling delay. Deliberately ignores cancellation so that
/// generation guards must reject both late successful values and late failures.
private actor SECArchiveModelGate {
    private var entered = false, released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; arrivals.forEach { $0.resume() }; arrivals = []
        if !released { await withCheckedContinuation { pending = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}

private actor SECArchiveModelFixture {
    static let shared = SECArchiveModelFixture()
    private var pending: Task<(SECResearchDocument, SECFinancialReportDocument, SECValuationSupplementDocument), any Error>?
    func value() async throws -> (SECResearchDocument, SECFinancialReportDocument, SECValuationSupplementDocument) {
        if let pending { return try await pending.value }
        let task = Task {
            let (_, _, parent, report, draft) = try await secValuationStorageFixture()
            return (parent, report, draft.document)
        }
        pending = task
        return try await task.value
    }
}

/// Model contract fake only. Actual transaction/revision protection is tested in
/// SEC archive persistence tests; this fake intentionally allows late read returns.
private actor SECArchiveModelStore: SECArchiveStorage, SECResearchWorkspaceStorage,
    SECFinancialReportWorkspaceStorage, SECValuationWorkspaceStorage {
    let parent: SECResearchDocument
    let report: SECFinancialReportDocument
    let supplement: SECValuationSupplementDocument
    var revision = UUID()
    var present = true
    var restoredPresent = false
    var plans: [UUID: SECArchiveRestorePlan] = [:]
    var cancelled: [UUID] = []
    var commitAttempts = 0, committed = 0, preparations = 0, exports = 0, imports = 0
    var replayCalls = 0, reportReplayCalls = 0, supplementReplayCalls = 0
    var savedWrites = 0
    var receivedConsents: [SECLocalArchiveConsent] = []
    private var gates: [String: SECArchiveModelGate] = [:]
    private var failures: Set<String> = []
    private var commitFailure: String?
    init(_ fixture: (SECResearchDocument, SECFinancialReportDocument, SECValuationSupplementDocument)) {
        (parent, report, supplement) = fixture
    }
    func gate(_ stage: String, _ gate: SECArchiveModelGate) { gates[stage] = gate }
    func fail(_ stage: String) { failures.insert(stage) }
    func failCommit(_ value: String?) { commitFailure = value }
    func retainRestoredRecords() { restoredPresent = true }
    private func pause(_ stage: String) async throws {
        let gate = gates.removeValue(forKey: stage), fails = failures.remove(stage) != nil
        if let gate { await gate.hold() }
        if fails { throw SECArchiveModelFailure.injected }
    }
    func exportArchive(researchID: UUID, consent: SECLocalArchiveConsent) async throws -> Data {
        exports += 1; receivedConsents.append(consent)
        guard researchID == parent.id else { throw SnapshotError.missingReference }
        try await pause("export")
        return Data("synthetic-model-archive".utf8)
    }
    func prepareArchiveRestore(_ bytes: Data, mode: RestoreMode,
                               consent: SECLocalArchiveConsent) async throws -> SECArchiveRestorePlan {
        preparations += 1; receivedConsents.append(consent)
        let result = SECArchiveRestorePlan(id: UUID(), digest: String(repeating: "a", count: 64),
            baseRevision: revision, mode: mode, details: ["合成模型预检"],
            researchCount: 1, reportCount: 1, supplementCount: 1,
            removedResearchCount: mode == .replace ? 1 : 0)
        plans[result.id] = result
        try await pause("prepare")
        return result
    }
    func commitArchiveRestore(_ approval: PlanApproval) async throws {
        commitAttempts += 1
        guard let plan = plans[approval.planID] else { throw SnapshotError.unknownPlan }
        guard plan.digest == approval.digest else { throw SnapshotError.approvalMismatch }
        try await pause("commit")
        if commitFailure == "stale" { throw SnapshotError.stalePlan }
        if commitFailure == "unknown" { throw SnapshotError.unknownPlan }
        if commitFailure != nil { throw SECArchiveModelFailure.injected }
        guard revision == plan.baseRevision else { throw SnapshotError.stalePlan }
        present = restoredPresent; revision = UUID(); committed += 1
        plans.removeValue(forKey: plan.id)
    }
    func cancelArchiveRestore(_ id: UUID) async {
        cancelled.append(id); plans.removeValue(forKey: id)
        try? await pause("cancel")
    }
    func savedResearch() async throws -> [SECResearchSummary] {
        let rows = present ? [SECResearchSummary(document: parent)] : []
        try await pause("list"); return rows
    }
    func open(id: UUID) async throws -> SECResearchDocument {
        guard present, id == parent.id else { throw SnapshotError.missingReference }
        try await pause("open"); return parent
    }
    func prepareFinancialReport(parentID: UUID, executionDate: Date) async throws -> SECFinancialReportDraft {
        let baseline = revision
        try await pause("generateReport")
        return .init(document: report, expectedRevision: baseline)
    }
    func saveFinancialReport(_ document: SECFinancialReportDocument, expectedRevision: UUID) async throws {
        try await pause("saveReport")
        // Intentionally ignore task cancellation: only the original revision may write.
        guard revision == expectedRevision else { throw SnapshotError.stalePlan }
        savedWrites += 1; revision = UUID()
    }
    func savedFinancialReports(parentID: UUID?) async throws -> [SECFinancialReportSummary] {
        let rows = present ? [SECFinancialReportSummary(document: report)] : []
        try await pause("listReports"); return rows
    }
    func openFinancialReport(id: UUID) async throws -> SECFinancialReportDocument {
        guard present, id == report.id else { throw SnapshotError.missingReference }
        try await pause("openReport"); return report
    }
    func valuationSourceDocument(parentReportID: UUID) async throws -> SECValuationSourceDocument {
        let result = try SECValuationSourceDocument(validatedResearch: parent, originalHash: report.parentDocumentHash)
        try await pause("sources"); return result
    }
    func prepareValuationSupplement(parentReportID: UUID, evidence: SECValuationInputEvidence,
                                    executionDate: Date) async throws -> SECValuationSupplementDraft {
        let baseline = revision
        try await pause("generateSupplement")
        return .init(document: supplement, expectedRevision: baseline)
    }
    func saveValuationSupplement(_ document: SECValuationSupplementDocument, expectedRevision: UUID) async throws {
        try await pause("saveSupplement")
        guard revision == expectedRevision else { throw SnapshotError.stalePlan }
        savedWrites += 1; revision = UUID()
    }
    func savedValuationSupplements(parentReportID: UUID?) async throws -> [SECValuationSupplementSummary] {
        let rows = present ? [SECValuationSupplementSummary(document: supplement)] : []
        try await pause("listSupplements"); return rows
    }
    func openValuationSupplement(id: UUID) async throws -> SECValuationSupplementDocument {
        guard present, id == supplement.id else { throw SnapshotError.missingReference }
        try await pause("openSupplement"); return supplement
    }
    func openValuationSupplementWithParent(id: UUID) async throws
        -> (supplement: SECValuationSupplementDocument, parent: SECFinancialReportDocument) {
        guard present, id == supplement.id else { throw SnapshotError.missingReference }
        let pair = (supplement: supplement, parent: report)
        try await pause("openSupplement"); return pair
    }
    func replayResearch() async throws -> FinancialNormalizationResult {
        replayCalls += 1; try await pause("replay"); return parent.normalization
    }
    func replayReport() async throws -> Bool {
        reportReplayCalls += 1; try await pause("replayReport"); return true
    }
    func replaySupplement() async throws -> Bool {
        supplementReplayCalls += 1; try await pause("replaySupplement"); return true
    }
    func importCompany() async throws -> SECResearchDocument {
        imports += 1; try await pause("import"); return parent
    }
}

@MainActor private func secArchiveModels(_ store: SECArchiveModelStore,
    coordinator: SECArchiveWorkspaceCoordinator? = nil)
    -> (SECResearchWorkspaceModel, SECArchiveTransferModel) {
    let workspace = SECResearchWorkspaceModel(storage: store, networkAvailable: true,
        importer: { _, _, _ in try await store.importCompany() },
        replay: { _ in try await store.replayResearch() },
        financialStorage: store, valuationStorage: store,
        valuationReplay: { _ in try await store.replaySupplement() },
        financialReplay: { _ in try await store.replayReport() })
    workspace.configureArchiveTransfer(store: store, coordinator: coordinator)
    return (workspace, workspace.archiveTransfer!)
}

@MainActor private func secArchivePreview(_ transfer: SECArchiveTransferModel) async throws -> SECArchiveRestorePlan {
    await transfer.prepare(Data("synthetic-input".utf8), mode: .replace, consent: .personalLocalBackup)
    return try #require(transfer.plan)
}

@MainActor private func expectSECArchiveHidden(_ workspace: SECResearchWorkspaceModel) {
    #expect(workspace.document == nil && workspace.financialReport == nil && workspace.valuationSupplement == nil)
    #expect(workspace.valuationSourceDocument == nil)
    #expect(!workspace.canDisplayValues && !workspace.canDisplayFinancialReport && !workspace.canDisplayValuationSupplement)
    #expect(!workspace.financialReportIsSaved && !workspace.valuationIsSaved)
    #expect(!workspace.canSaveFinancialReport && !workspace.canSaveValuationSupplement)
}

@Suite @MainActor struct SECArchiveTransferModelTests {
    @Test func initializationAndExportHaveNoImplicitImportReplayOrRestore() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        #expect(await store.exports == 0)
        #expect(await store.preparations == 0)
        #expect(await store.imports == 0)
        let bytes = await transfer.export(researchID: fixture.0.id, consent: .personalLocalBackup)
        #expect(bytes == Data("synthetic-model-archive".utf8))
        #expect(await store.receivedConsents == [.personalLocalBackup])
        #expect(await store.replayCalls == 0)
        #expect(await store.reportReplayCalls == 0)
        #expect(await store.supplementReplayCalls == 0)
        #expect(await store.commitAttempts == 0)
        #expect(await store.imports == 0)
        #expect(transfer.plan == nil && !transfer.isBusy)
        expectSECArchiveHidden(workspace)
    }

    @Test(arguments: ["export", "read", "prepare"])
    func dismissalDiscardsLateFileWorkWithoutTouchingNewPreview(stage: String) async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (_, transfer) = secArchiveModels(store)
        let gate = SECArchiveModelGate()
        if stage != "read" { await store.gate(stage, gate) }
        let pending = Task {
            if stage == "export" { #expect(await transfer.export(researchID: fixture.0.id, consent: .personalLocalBackup) == nil) }
            else {
                await transfer.prepare(mode: .merge, consent: .personalLocalBackup, read: {
                    if stage == "read" { await gate.hold() }
                    return Data("old".utf8)
                })
            }
        }
        await gate.waitUntilEntered()
        await transfer.cancel()
        let next = try await secArchivePreview(transfer)
        await gate.release(); await pending.value
        #expect(transfer.plan?.id == next.id && !transfer.isBusy && transfer.message == nil)
        #expect(await store.plans.keys.sorted { $0.uuidString < $1.uuidString } == [next.id])
        #expect(await store.commitAttempts == 0)
        #expect(await store.preparations == (stage == "prepare" ? 2 : 1))
    }

    @Test func staleSheetAndOrdinaryFailureHaveDifferentRetryRules() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        let old = try await secArchivePreview(transfer)
        let current = try await secArchivePreview(transfer)
        #expect(!(await transfer.confirm(id: old.id, digest: old.digest)))
        #expect(!(await transfer.confirm(id: current.id, digest: "wrong")))
        #expect(await store.commitAttempts == 0)
        await store.failCommit("ordinary")
        #expect(!(await transfer.confirm(id: current.id, digest: current.digest)))
        #expect(transfer.plan?.id == current.id && !transfer.isBusy && !workspace.isBusy)
        #expect(workspace.saved.count == 1)
        expectSECArchiveHidden(workspace)
        await store.failCommit(nil)
        #expect(await transfer.confirm(id: current.id, digest: current.digest))
        #expect(transfer.plan == nil && workspace.saved.isEmpty)
        #expect(await store.committed == 1)
        for failure in ["stale", "unknown"] {
            let plan = try await secArchivePreview(transfer)
            await store.failCommit(failure)
            #expect(!(await transfer.confirm(id: plan.id, digest: plan.digest)))
            #expect(transfer.plan == nil)
            #expect(await store.cancelled.contains(plan.id))
        }
    }

    @Test(arguments: [false, true])
    func dismissingCommitKeepsBusyAndDoesNotRevokeTransaction(fail: Bool) async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        let plan = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate("commit", gate)
        if fail { await store.failCommit("ordinary") }
        let commit = Task { await transfer.confirm(id: plan.id, digest: plan.digest) }
        await gate.waitUntilEntered()
        await transfer.cancel(); workspace.disappear()
        #expect(workspace.isBusy && transfer.isBusy)
        #expect(workspace.startImport(email: "researcher@example.invalid") == nil)
        await transfer.prepare(Data(), mode: .replace, consent: .personalLocalBackup)
        #expect(await store.preparations == 1)
        #expect(await store.imports == 0)
        #expect(!(await store.cancelled.contains(plan.id)))
        await gate.release()
        #expect(await commit.value == !fail)
        #expect(transfer.plan == nil && transfer.message == nil && !transfer.isBusy && !workspace.isBusy)
        #expect(await store.committed == (fail ? 0 : 1))
        #expect(await store.plans.isEmpty)
        if fail { #expect(await store.cancelled.contains(plan.id)) }
        expectSECArchiveHidden(workspace)
    }

    @Test(arguments: ["list", "listReports", "listSupplements", "open", "openReport", "openSupplement", "sources", "openFailure", "listFailure"])
    func restoreRejectsLateReadsAndOldBusyCleanup(scenario: String) async throws {
        let stage = scenario.replacingOccurrences(of: "Failure", with: "")
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        if stage == "sources" { await workspace.openFinancialReport(fixture.1.id) }
        let plan = try await secArchivePreview(transfer), oldGate = SECArchiveModelGate(), commitGate = SECArchiveModelGate()
        await store.gate(stage, oldGate); await store.gate("commit", commitGate)
        if scenario.hasSuffix("Failure") { await store.fail(stage) }
        let old = Task {
            switch stage {
            case "open": await workspace.open(fixture.0.id)
            case "openReport": await workspace.openFinancialReport(fixture.1.id)
            case "openSupplement": await workspace.openValuationSupplement(fixture.2.id)
            case "sources": await workspace.loadValuationSources()
            default: await workspace.load()
            }
        }
        await oldGate.waitUntilEntered()
        let commit = Task { await transfer.confirm(id: plan.id, digest: plan.digest) }
        await commitGate.waitUntilEntered()
        expectSECArchiveHidden(workspace)
        #expect(workspace.saved.isEmpty && workspace.savedFinancialReports.isEmpty && workspace.savedValuationSupplements.isEmpty)
        await oldGate.release(); await old.value
        #expect(workspace.isBusy && transfer.isBusy)
        expectSECArchiveHidden(workspace)
        await commitGate.release(); #expect(await commit.value)
        #expect(!workspace.isBusy && workspace.saved.isEmpty && workspace.savedFinancialReports.isEmpty && workspace.savedValuationSupplements.isEmpty)
        #expect(!workspace.hasError && !workspace.financialHasError && !workspace.valuationHasError)
        expectSECArchiveHidden(workspace)
    }

    @Test(arguments: ["import", "replay", "replayReport", "replaySupplement", "generateReport", "generateSupplement", "saveReport", "saveSupplement"])
    func restoreInvalidatesLateComputationAndPreservesOriginalSaveBaseline(stage: String) async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        switch stage {
        case "replay", "generateReport", "saveReport": await workspace.open(fixture.0.id)
        case "replaySupplement": await workspace.openValuationSupplement(fixture.2.id)
        case "replayReport", "generateSupplement", "saveSupplement": await workspace.openFinancialReport(fixture.1.id)
        default: break
        }
        if stage == "saveReport" { await workspace.generateFinancialReport() }
        if stage == "saveSupplement" { await workspace.generateValuationSupplement(evidence: .init()) }
        let plan = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate(stage, gate)
        let old = Task {
            switch stage {
            case "import":
                if let pending = workspace.startImport(email: "researcher@example.invalid") { await pending.value }
            case "replay": await workspace.recompute()
            case "replayReport": await workspace.recomputeFinancialReport()
            case "replaySupplement": await workspace.recomputeValuationSupplement()
            case "generateReport": await workspace.generateFinancialReport()
            case "generateSupplement": await workspace.generateValuationSupplement(evidence: .init())
            case "saveReport": await workspace.saveFinancialReport()
            default: await workspace.saveValuationSupplement()
            }
        }
        await gate.waitUntilEntered()
        #expect(await transfer.confirm(id: plan.id, digest: plan.digest))
        expectSECArchiveHidden(workspace)
        await gate.release(); await old.value
        expectSECArchiveHidden(workspace)
        #expect(workspace.saved.isEmpty && workspace.savedFinancialReports.isEmpty && workspace.savedValuationSupplements.isEmpty)
        #expect(!workspace.isBusy && !workspace.hasError && !workspace.financialHasError && !workspace.valuationHasError)
        #expect(await store.savedWrites == 0)
    }

    @Test func restoreReloadFailureDoesNotUndoCommittedSuccessOrImplicitlyReplay() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        await store.retainRestoredRecords()
        let plan = try await secArchivePreview(transfer)
        await store.fail("listReports")
        #expect(await transfer.confirm(id: plan.id, digest: plan.digest))
        #expect(transfer.plan == nil && transfer.message?.contains("已提交") == true)
        #expect(workspace.saved.count == 1 && workspace.savedValuationSupplements.count == 1)
        #expect(workspace.savedFinancialReports.isEmpty && workspace.financialListError != nil)
        expectSECArchiveHidden(workspace)
        await workspace.open(fixture.0.id)
        await workspace.openFinancialReport(fixture.1.id)
        await workspace.openValuationSupplement(fixture.2.id)
        #expect(!workspace.canDisplayValues && !workspace.canDisplayFinancialReport && !workspace.canDisplayValuationSupplement)
        #expect(await store.replayCalls == 0)
        #expect(await store.reportReplayCalls == 0)
        #expect(await store.supplementReplayCalls == 0)
        #expect(await store.imports == 0)
    }

    @Test func cancelledTaskCannotApproveOrPublishPreparedPlan() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        let plan = try await secArchivePreview(transfer)
        let confirm = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await transfer.confirm(id: plan.id, digest: plan.digest)
        }
        #expect(!(await confirm.value)); #expect(await store.commitAttempts == 0)
        #expect(!workspace.isBusy)
        #expect(transfer.plan?.id == plan.id)
        let gate = SECArchiveModelGate(); await store.gate("prepare", gate)
        let prepare = Task { await transfer.prepare(Data(), mode: .merge, consent: .personalLocalBackup) }
        await gate.waitUntilEntered(); prepare.cancel(); await gate.release(); await prepare.value
        #expect(transfer.plan == nil && !transfer.isBusy)
        #expect(await store.plans.isEmpty)
    }

    @Test func cancelledCleanupOnlyReleasesItsOldPlan() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (_, transfer) = secArchiveModels(store)
        let old = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate("cancel", gate)
        let cleanup = transfer.dismiss()
        await gate.waitUntilEntered()
        let current = try await secArchivePreview(transfer)
        await gate.release(); await cleanup.value
        #expect(transfer.plan?.id == current.id && !transfer.isBusy)
        #expect(await store.plans[current.id]?.id == current.id)
        #expect(await store.cancelled == [old.id])
    }

    @Test func commitReservationIncludesReloadAndDismissedRefreshCannotPublish() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let (workspace, transfer) = secArchiveModels(store)
        await store.retainRestoredRecords()
        let plan = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate("list", gate)
        let commit = Task { await transfer.confirm(id: plan.id, digest: plan.digest) }
        await gate.waitUntilEntered()
        #expect(await store.committed == 1)
        #expect(workspace.isBusy && transfer.isBusy)
        workspace.disappear(); await transfer.cancel()
        #expect(workspace.isBusy && transfer.isBusy)
        #expect(workspace.startImport(email: "researcher@example.invalid") == nil)
        await transfer.prepare(Data(), mode: .merge, consent: .personalLocalBackup)
        #expect(await store.preparations == 1)
        await gate.release(); #expect(await commit.value)
        #expect(!workspace.isBusy && !transfer.isBusy && transfer.message == nil)
        #expect(workspace.saved.isEmpty && workspace.savedFinancialReports.isEmpty && workspace.savedValuationSupplements.isEmpty)
        expectSECArchiveHidden(workspace)
    }

    @Test(arguments: ["open", "replay", "openReport", "replayReport", "openSupplement", "replaySupplement", "saveReport", "saveSupplement"])
    func sharedCoordinatorInvalidatesOtherPageReadsReplayAndOriginalWrites(stage: String) async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let coordinator = SECArchiveWorkspaceCoordinator()
        let (first, transfer) = secArchiveModels(store, coordinator: coordinator)
        let (second, _) = secArchiveModels(store, coordinator: coordinator)
        first.chooseTicker("AAPL")
        #expect(second.ticker == "MSFT")
        switch stage {
        case "replay", "saveReport": await second.open(fixture.0.id)
        case "replayReport", "saveSupplement": await second.openFinancialReport(fixture.1.id)
        case "replaySupplement": await second.openValuationSupplement(fixture.2.id)
        default: break
        }
        if stage == "saveReport" { await second.generateFinancialReport() }
        if stage == "saveSupplement" { await second.generateValuationSupplement(evidence: .init()) }
        let secondSelectionBeforeRestore = second.ticker
        let plan = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate(stage, gate)
        let old = Task {
            switch stage {
            case "open": await second.open(fixture.0.id)
            case "replay": await second.recompute()
            case "openReport": await second.openFinancialReport(fixture.1.id)
            case "replayReport": await second.recomputeFinancialReport()
            case "openSupplement": await second.openValuationSupplement(fixture.2.id)
            case "replaySupplement": await second.recomputeValuationSupplement()
            case "saveReport": await second.saveFinancialReport()
            default: await second.saveValuationSupplement()
            }
        }
        await gate.waitUntilEntered()
        #expect(await transfer.confirm(id: plan.id, digest: plan.digest))
        expectSECArchiveHidden(first); expectSECArchiveHidden(second)
        await gate.release(); await old.value
        expectSECArchiveHidden(first); expectSECArchiveHidden(second)
        #expect(first.ticker == "AAPL" && second.ticker == secondSelectionBeforeRestore)
        #expect(!first.isBusy && !second.isBusy)
        #expect(first.saved.isEmpty && second.saved.isEmpty)
        #expect(!second.hasError && !second.financialHasError && !second.valuationHasError)
        #expect(await store.savedWrites == 0)
    }

    @Test func pageDismissedBeforeCommitCompletesDoesNotRegainListsDuringRefresh() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let coordinator = SECArchiveWorkspaceCoordinator()
        let (first, transfer) = secArchiveModels(store, coordinator: coordinator)
        let (second, _) = secArchiveModels(store, coordinator: coordinator)
        await store.retainRestoredRecords()
        let plan = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate("commit", gate)
        let commit = Task { await transfer.confirm(id: plan.id, digest: plan.digest) }
        await gate.waitUntilEntered()
        first.disappear(); await transfer.cancel()
        #expect(first.isBusy && second.isBusy && transfer.isBusy)
        await gate.release(); #expect(await commit.value)
        #expect(first.saved.isEmpty && first.savedFinancialReports.isEmpty && first.savedValuationSupplements.isEmpty)
        #expect(second.saved.count == 1 && second.savedFinancialReports.count == 1 && second.savedValuationSupplements.count == 1)
        #expect(transfer.message == nil && !transfer.isBusy && !first.isBusy && !second.isBusy)
        expectSECArchiveHidden(first); expectSECArchiveHidden(second)
    }

    @Test(arguments: ["commit", "refresh"])
    func pagesJoiningRestoreStayReservedUntilEveryPageRefreshFinishes(stage: String) async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let coordinator = SECArchiveWorkspaceCoordinator()
        let (first, transfer) = secArchiveModels(store, coordinator: coordinator)
        await store.retainRestoredRecords()
        let plan = try await secArchivePreview(transfer), gate = SECArchiveModelGate()
        await store.gate(stage == "commit" ? "commit" : "list", gate)
        let commit = Task { await transfer.confirm(id: plan.id, digest: plan.digest) }
        await gate.waitUntilEntered()
        let (second, secondTransfer) = secArchiveModels(store, coordinator: coordinator)
        #expect(first.isBusy && second.isBusy && coordinator.isRestoring)
        await second.load()
        second.chooseTicker("AAPL")
        #expect(second.ticker == "MSFT")
        #expect(second.startImport(email: "researcher@example.invalid") == nil)
        await secondTransfer.prepare(Data(), mode: .merge, consent: .personalLocalBackup)
        #expect(await store.preparations == 1)
        #expect(await store.imports == 0)
        if stage == "commit" {
            await gate.release(); #expect(await commit.value)
            #expect(first.saved.count == 1 && second.saved.count == 1)
        } else {
            // First page is refreshing. Reserve another refresh so that a third
            // page joins after the first page has already completed its reload.
            let secondRefresh = SECArchiveModelGate()
            await store.gate("list", secondRefresh)
            await gate.release(); await secondRefresh.waitUntilEntered()
            #expect(first.isBusy && second.isBusy && transfer.isBusy)
            let (third, _) = secArchiveModels(store, coordinator: coordinator)
            #expect(third.isBusy && coordinator.isRestoring)
            await third.load()
            #expect(third.saved.isEmpty)
            await secondRefresh.release(); #expect(await commit.value)
            #expect(!third.isBusy && third.saved.count == 1)
            expectSECArchiveHidden(third)
        }
        #expect(!first.isBusy && !second.isBusy && !transfer.isBusy && !coordinator.isRestoring)
        #expect(first.saved.count == 1 && second.saved.count == 1)
        expectSECArchiveHidden(first); expectSECArchiveHidden(second)
        #expect(await store.replayCalls == 0)
    }

    @Test func environmentCopiesShareArchiveReservationWithoutSharingPageSelection() async throws {
        let environment = try AppEnvironment.mock(databasePath: ":memory:")
        let copy = environment
        #expect(environment.secArchiveCoordinator === copy.secArchiveCoordinator)
        let first = try await environment.makeSECResearchWorkspace(networkAvailable: false)
        let second = try await copy.makeSECResearchWorkspace(networkAvailable: false)
        #expect(first.archiveTransfer != nil && second.archiveTransfer != nil)
        first.chooseTicker("AAPL")
        #expect(second.ticker == "MSFT")
        let token = try #require(environment.secArchiveCoordinator.begin())
        #expect(first.isBusy && second.isBusy)
        let third = try await copy.makeSECResearchWorkspace(networkAvailable: false)
        #expect(third.isBusy)
        await copy.secArchiveCoordinator.finish(token)
        #expect(!first.isBusy && !second.isBusy && !third.isBusy)
        #expect(first.ticker == "AAPL" && second.ticker == "MSFT" && third.ticker == "MSFT")
        #expect(first.saved.isEmpty && second.saved.isEmpty && third.saved.isEmpty)
        expectSECArchiveHidden(first); expectSECArchiveHidden(second); expectSECArchiveHidden(third)
    }

    @Test func returningPageReloadsAfterItsEarlierRefreshWasAlreadyVisited() async throws {
        let fixture = try await SECArchiveModelFixture.shared.value(), store = SECArchiveModelStore(fixture)
        let coordinator = SECArchiveWorkspaceCoordinator()
        let (first, transfer) = secArchiveModels(store, coordinator: coordinator)
        let (second, _) = secArchiveModels(store, coordinator: coordinator)
        await store.retainRestoredRecords()
        let plan = try await secArchivePreview(transfer), commitGate = SECArchiveModelGate()
        await store.gate("commit", commitGate)
        let commit = Task { await transfer.confirm(id: plan.id, digest: plan.digest) }
        await commitGate.waitUntilEntered()
        first.disappear()
        // The coordinator skips the hidden first page, then blocks refreshing
        // the second. Returning now must make the first page pending again.
        let secondRefresh = SECArchiveModelGate()
        await store.gate("list", secondRefresh)
        await commitGate.release(); await secondRefresh.waitUntilEntered()
        #expect(first.saved.isEmpty && first.isBusy && second.isBusy)
        await first.load()
        #expect(first.isBusy && first.saved.isEmpty)
        await secondRefresh.release(); #expect(await commit.value)
        #expect(first.saved.count == 1 && second.saved.count == 1)
        #expect(first.savedFinancialReports.count == 1 && first.savedValuationSupplements.count == 1)
        #expect(!first.isBusy && !second.isBusy && !transfer.isBusy)
        expectSECArchiveHidden(first); expectSECArchiveHidden(second)
        #expect(await store.replayCalls == 0)
    }

}
