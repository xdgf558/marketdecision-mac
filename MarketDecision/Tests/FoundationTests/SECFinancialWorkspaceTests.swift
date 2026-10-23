import Foundation
import Testing
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private enum FinancialWorkspaceFailure: Error { case injected }

private actor FinancialWorkspaceGate {
    private var entered = false, released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; arrival.forEach { $0.resume() }; arrival = []
        if !released { await withCheckedContinuation { pending = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrival.append($0) } }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}

private actor FinancialWorkspaceFixture {
    static let shared = FinancialWorkspaceFixture()
    private var pending: Task<(SECResearchDocument, SECFinancialReportDocument), any Error>?
    func value() async throws -> (SECResearchDocument, SECFinancialReportDocument) {
        if let pending { return try await pending.value }
        let task = Task {
            let parent = try await secFinancialReportFixtureParent()
            let report = try await SECFinancialReportDocument.make(parent: parent,
                parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
            return (parent, report)
        }
        pending = task
        return try await task.value
    }
}

private actor FinancialWorkspaceStorage: SECResearchWorkspaceStorage, SECFinancialReportWorkspaceStorage {
    let parent: SECResearchDocument
    var prepared: SECFinancialReportDocument
    var stored: [SECFinancialReportDocument]
    var revision = UUID()
    var researchListReads = 0, researchOpenReads = 0, reportListReads = 0, reportOpenReads = 0, preparations = 0, commits = 0
    var attemptedRevisions: [UUID] = []
    private var researchListFails = false, researchOpenFails = false, reportListFails = false, reportOpenFails = false, saveFails = false
    private var preparationError: SECFinancialError?
    private var prepareGate: FinancialWorkspaceGate?, saveGate: FinancialWorkspaceGate?
    private var openGate: FinancialWorkspaceGate?, researchOpenGate: FinancialWorkspaceGate?, listGate: FinancialWorkspaceGate?
    init(parent: SECResearchDocument, report: SECFinancialReportDocument, stored: Bool = true) {
        self.parent = parent; prepared = report; self.stored = stored ? [report] : []
    }
    func configure(researchListFails: Bool = false, researchOpenFails: Bool = false, reportListFails: Bool = false,
                   reportOpenFails: Bool = false, saveFails: Bool = false,
                   preparationError: SECFinancialError? = nil, prepareGate: FinancialWorkspaceGate? = nil,
                   saveGate: FinancialWorkspaceGate? = nil, openGate: FinancialWorkspaceGate? = nil,
                   researchOpenGate: FinancialWorkspaceGate? = nil, listGate: FinancialWorkspaceGate? = nil) {
        self.researchListFails = researchListFails; self.researchOpenFails = researchOpenFails
        self.reportListFails = reportListFails; self.reportOpenFails = reportOpenFails; self.saveFails = saveFails
        self.preparationError = preparationError; self.prepareGate = prepareGate; self.saveGate = saveGate
        self.openGate = openGate; self.researchOpenGate = researchOpenGate; self.listGate = listGate
    }
    func replacePrepared(_ report: SECFinancialReportDocument) { prepared = report }
    func replaceStored(_ reports: [SECFinancialReportDocument]) { stored = reports }
    func advanceRevision() { revision = UUID() }
    func savedResearch() async throws -> [SECResearchSummary] {
        researchListReads += 1
        if researchListFails { throw FinancialWorkspaceFailure.injected }
        return [SECResearchSummary(document: parent)]
    }
    func open(id: UUID) async throws -> SECResearchDocument {
        researchOpenReads += 1
        let gate = researchOpenGate, failing = researchOpenFails
        researchOpenGate = nil
        if let gate { await gate.hold() }
        if failing { throw FinancialWorkspaceFailure.injected }
        guard id == parent.id else { throw SnapshotError.missingReference }
        return parent
    }
    func prepareFinancialReport(parentID: UUID, executionDate: Date) async throws -> SECFinancialReportDraft {
        preparations += 1
        let baseline = revision, document = prepared, error = preparationError, gate = prepareGate
        prepareGate = nil
        guard parentID == parent.id else { throw SnapshotError.missingReference }
        if let gate { await gate.hold() }
        if let error { throw error }
        guard revision == baseline else { throw SnapshotError.stalePlan }
        // Deliberately allow a late result after cancellation: publication still belongs
        // to the page session, independently of this dependency's cooperation.
        return SECFinancialReportDraft(document: document, expectedRevision: baseline)
    }
    func saveFinancialReport(_ document: SECFinancialReportDocument, expectedRevision: UUID) async throws {
        attemptedRevisions.append(expectedRevision)
        let gate = saveGate, failing = saveFails
        saveGate = nil
        if let gate { await gate.hold() }
        try Task.checkCancellation()
        guard revision == expectedRevision else { throw SnapshotError.stalePlan }
        if failing { throw FinancialWorkspaceFailure.injected }
        stored.append(document); commits += 1; revision = UUID()
    }
    func savedFinancialReports(parentID: UUID?) async throws -> [SECFinancialReportSummary] {
        reportListReads += 1
        let rows = stored.filter { parentID == nil || $0.parentDocumentID == parentID }, failing = reportListFails, gate = listGate
        listGate = nil
        if let gate { await gate.hold() }
        if failing { throw FinancialWorkspaceFailure.injected }
        return rows.map(SECFinancialReportSummary.init(document:))
    }
    func openFinancialReport(id: UUID) async throws -> SECFinancialReportDocument {
        reportOpenReads += 1
        let result = stored.first { $0.id == id }, gate = openGate, failing = reportOpenFails
        openGate = nil
        if let gate { await gate.hold() }
        if failing { throw FinancialWorkspaceFailure.injected }
        guard let result else { throw SnapshotError.missingReference }
        return result
    }
}

private actor FinancialWorkspaceNetworkProbe {
    var calls = 0
    private let result: SECResearchDocument?
    private let gate: FinancialWorkspaceGate?
    init(result: SECResearchDocument? = nil, gate: FinancialWorkspaceGate? = nil) {
        self.result = result; self.gate = gate
    }
    func importCompany() async throws -> SECResearchDocument {
        calls += 1
        if let gate { await gate.hold() }
        guard let result else { throw FinancialWorkspaceFailure.injected }
        return result
    }
}

private actor FinancialDailyReplayProbe {
    var calls = 0
    private let result: Bool, fails: Bool
    private let gate: FinancialWorkspaceGate?
    init(result: Bool = true, fails: Bool = false, gate: FinancialWorkspaceGate? = nil) {
        self.result = result; self.fails = fails; self.gate = gate
    }
    func run() async throws -> Bool {
        calls += 1
        if let gate { await gate.hold() }
        if fails { throw FinancialWorkspaceFailure.injected }
        return result
    }
}

private func financialWorkspaceReportCopy(_ report: SECFinancialReportDocument, parentID: UUID? = nil) throws -> SECFinancialReportDocument {
    var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(report)) as? [String: Any])
    object["id"] = UUID().uuidString
    if let parentID { object["parentDocumentID"] = parentID.uuidString }
    return try JSONDecoder().decode(SECFinancialReportDocument.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

@MainActor private func financialWorkspace(_ storage: FinancialWorkspaceStorage,
    network: FinancialWorkspaceNetworkProbe = .init(),
    replay: (@Sendable (SECFinancialReportDocument) async throws -> Bool)? = nil) -> SECResearchWorkspaceModel {
    if let replay {
        return .init(storage: storage, networkAvailable: false, importer: { _, _, _ in try await network.importCompany() },
            financialStorage: storage, financialReplay: replay)
    }
    return .init(storage: storage, networkAvailable: false, importer: { _, _, _ in try await network.importCompany() },
        financialStorage: storage)
}

@Suite @MainActor struct SECFinancialWorkspaceTests {
    @Test func pageListingLoadsIndependentSummariesWithoutGeneratingOpeningOrImporting() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), network = FinancialWorkspaceNetworkProbe()
        let model = financialWorkspace(storage, network: network)
        #expect(await storage.reportListReads == 0)
        await model.load()
        #expect(model.saved.map(\.id) == [parent.id] && model.savedFinancialReports.map(\.id) == [report.id])
        #expect(model.document == nil && model.financialReport == nil && !model.canDisplayFinancialReport)
        #expect(await storage.reportOpenReads == 0)
        #expect(await storage.preparations == 0)
        #expect(await network.calls == 0)
    }

    @Test func eitherListFailureLeavesTheOtherListAndOpenedReportUsable() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), model = financialWorkspace(storage)
        await storage.configure(researchListFails: true)
        await model.load()
        #expect(model.listError != nil && model.saved.isEmpty)
        #expect(model.financialListError == nil && model.savedFinancialReports.count == 1)
        await model.openFinancialReport(report.id)
        #expect(model.financialReport?.id == report.id && !model.canDisplayFinancialReport)
        await storage.configure(reportListFails: true)
        await model.load()
        #expect(model.listError == nil && model.saved.count == 1)
        #expect(model.financialListError != nil && model.savedFinancialReports.isEmpty)
        #expect(model.financialReport?.id == report.id)
        await model.recomputeFinancialReport()
        #expect(model.canDisplayFinancialReport)
    }

    @Test func explicitGenerateAndSaveAreOfflineAndReopeningRequiresReplay() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false)
        let network = FinancialWorkspaceNetworkProbe(), model = financialWorkspace(storage, network: network)
        let original = try ResearchDocument.encoded(parent), baseline = await storage.revision
        await model.open(parent.id)
        #expect(model.canGenerateFinancialReport && !model.canSaveFinancialReport && !model.canDisplayValues)
        await model.generateFinancialReport()
        #expect(model.financialReport?.id == report.id && model.financialReportState == .generated)
        #expect(model.canDisplayFinancialReport && model.canSaveFinancialReport && !model.financialReportIsSaved)
        #expect(await storage.commits == 0)
        await model.saveFinancialReport()
        #expect(model.financialReportIsSaved && !model.canSaveFinancialReport)
        #expect(await storage.attemptedRevisions == [baseline])
        #expect(model.savedFinancialReports.map(\.id) == [report.id])
        let generatedRevision = model.financialReportRevision
        await model.openFinancialReport(report.id)
        #expect(!model.canDisplayFinancialReport && model.financialReportState == .notVerified)
        #expect(model.financialReportRevision != generatedRevision)
        let openedRevision = model.financialReportRevision
        await model.openFinancialReport(report.id)
        #expect(model.financialReport?.id == report.id && model.financialReportRevision != openedRevision)
        await model.recomputeFinancialReport()
        #expect(model.canDisplayFinancialReport && model.financialReportState == .matched)
        #expect(try ResearchDocument.encoded(try #require(model.document)) == original)
        #expect(await network.calls == 0)
    }

    @Test func staleDraftNeverAcquiresANewSaveBaseline() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false), model = financialWorkspace(storage)
        let baseline = await storage.revision
        await model.open(parent.id); await model.generateFinancialReport()
        await storage.advanceRevision()
        await model.saveFinancialReport()
        #expect(await storage.attemptedRevisions == [baseline])
        #expect(await storage.commits == 0)
        #expect(model.financialHasError && !model.canSaveFinancialReport && !model.financialReportIsSaved)
        #expect(model.financialReport?.id == report.id && model.canDisplayFinancialReport)
        await model.saveFinancialReport()
        #expect(await storage.attemptedRevisions.count == 1)
    }

    @Test func recoverableSaveFailureRetriesOriginalDraftAndCommitSurvivesListFailure() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false), model = financialWorkspace(storage)
        let baseline = await storage.revision
        await model.open(parent.id); await model.generateFinancialReport()
        await storage.configure(saveFails: true)
        await model.saveFinancialReport()
        #expect(model.canSaveFinancialReport && model.financialHasError)
        await storage.configure(reportListFails: true)
        await model.saveFinancialReport()
        #expect(await storage.attemptedRevisions == [baseline, baseline])
        #expect(await storage.commits == 1)
        #expect(model.financialReportIsSaved && !model.canSaveFinancialReport && !model.financialHasError)
        #expect(model.financialListError != nil && model.financialMessage?.contains("已保存") == true)
    }

    // String arguments have stable distinct case IDs on the supported Swift Testing 6.1 runtime.
    @Test(arguments: ["insufficientPeriods", "ambiguousPeriods"])
    func unsupportedPeriodsLeaveFrozenSourceAvailableAndDoNotInventReport(error: String) async throws {
        let failure: SECFinancialError = error == "insufficientPeriods" ? .insufficientPeriods : .ambiguousPeriods
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), model = financialWorkspace(storage)
        await model.open(parent.id)
        await storage.configure(preparationError: failure)
        await model.generateFinancialReport()
        #expect(model.document?.id == parent.id && model.financialReport == nil)
        #expect(model.financialHasError && model.financialMessage?.contains("期间") == true)
        #expect(!model.canSaveFinancialReport && !model.canDisplayFinancialReport)
        #expect(await storage.commits == 0)
    }

    @Test func wrongParentDraftIsRejectedWithoutRelabellingSelectedResearch() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let wrong = try financialWorkspaceReportCopy(report, parentID: UUID())
        let storage = FinancialWorkspaceStorage(parent: parent, report: wrong), model = financialWorkspace(storage)
        await model.open(parent.id); await model.generateFinancialReport()
        #expect(model.document?.id == parent.id && model.financialReport == nil && model.financialHasError)
        #expect(!model.canSaveFinancialReport)
    }

    @Test func cancelledPreparationCannotPublishOrReleaseNewOpenBusyState() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let oldGate = FinancialWorkspaceGate(), newGate = FinancialWorkspaceGate()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), model = financialWorkspace(storage)
        await model.open(parent.id)
        await storage.configure(prepareGate: oldGate)
        let old = Task { await model.generateFinancialReport() }
        await oldGate.waitUntilEntered(); model.cancel()
        await storage.configure(openGate: newGate)
        let current = Task { await model.openFinancialReport(report.id) }
        await newGate.waitUntilEntered()
        await oldGate.release(); await old.value
        #expect(model.isBusy && model.financialReport == nil && model.financialMessage == nil)
        await newGate.release(); await current.value
        #expect(!model.isBusy && model.financialReport?.id == report.id && !model.canDisplayFinancialReport)
    }

    @Test func cancellingQueuedSaveCancelsStorageWorkAndCannotPublishCommit() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let gate = FinancialWorkspaceGate()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false), model = financialWorkspace(storage)
        await model.open(parent.id); await model.generateFinancialReport()
        await storage.configure(saveGate: gate)
        let saving = Task { await model.saveFinancialReport() }
        await gate.waitUntilEntered(); model.disappear()
        await gate.release(); await saving.value
        #expect(await storage.commits == 0)
        #expect(model.financialReport == nil && !model.isBusy && !model.financialReportIsSaved)
        #expect(model.financialMessage == nil && model.savedFinancialReports.isEmpty)
    }

    @Test func replayHidesGeneratedNumbersWhilePendingAndOnMismatch() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let gate = FinancialWorkspaceGate(), storage = FinancialWorkspaceStorage(parent: parent, report: report)
        let model = financialWorkspace(storage, replay: { _ in await gate.hold(); return false })
        await model.open(parent.id); await model.generateFinancialReport()
        #expect(model.canDisplayFinancialReport)
        let replay = Task { await model.recomputeFinancialReport() }
        await gate.waitUntilEntered()
        #expect(model.isBusy && !model.canDisplayFinancialReport && !model.canSaveFinancialReport)
        await gate.release(); await replay.value
        #expect(model.financialReportState == .mismatched && !model.canDisplayFinancialReport && !model.canSaveFinancialReport)
        #expect(model.financialReport?.id == report.id)
    }

    @Test func failedAndLateReplayCannotVerifyOrReplaceAReenteredPage() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let gate = FinancialWorkspaceGate(), storage = FinancialWorkspaceStorage(parent: parent, report: report)
        let failed = financialWorkspace(storage, replay: { _ in throw FinancialWorkspaceFailure.injected })
        await failed.openFinancialReport(report.id); await failed.recomputeFinancialReport()
        #expect(failed.financialReportState == .failed && !failed.canDisplayFinancialReport)
        let model = financialWorkspace(storage, replay: { _ in await gate.hold(); return true })
        await model.openFinancialReport(report.id)
        let old = Task { await model.recomputeFinancialReport() }
        await gate.waitUntilEntered(); model.disappear()
        await model.load()
        await gate.release(); await old.value
        #expect(model.financialReport == nil && !model.canDisplayFinancialReport && !model.isBusy)
        #expect(model.financialMessage == nil && model.savedFinancialReports.count == 1)
    }

    @Test func oldReportListFailureCannotEraseNewListOrSourceSelection() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let gate = FinancialWorkspaceGate(), storage = FinancialWorkspaceStorage(parent: parent, report: report)
        let model = financialWorkspace(storage)
        await storage.configure(reportListFails: true, listGate: gate)
        let old = Task { await model.loadFinancialReports() }
        await gate.waitUntilEntered(); model.cancel()
        await storage.configure()
        await model.load(); await model.open(parent.id)
        await gate.release(); await old.value
        #expect(model.financialListError == nil && model.savedFinancialReports.map(\.id) == [report.id])
        #expect(model.document?.id == parent.id && !model.isBusy)
    }

    @Test func changingSourceOrTickerClearsReportVerificationWithoutNetwork() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), network = FinancialWorkspaceNetworkProbe()
        let model = financialWorkspace(storage, network: network)
        await model.open(parent.id); await model.generateFinancialReport()
        await model.open(parent.id)
        #expect(model.financialReport == nil && !model.canDisplayFinancialReport)
        await model.generateFinancialReport(); model.chooseTicker("MSFT")
        #expect(model.document == nil && model.financialReport == nil && !model.canSaveFinancialReport)
        #expect(await network.calls == 0)
    }
}

/// Daily orchestration regressions are source only until explicitly authorized to execute.
/// Import and replay dependencies below are local actors; none installs a network transport.
@Suite @MainActor struct SECStockDailyFlowTests {
    @Test func selectedSourceAnalysisSaveAndReopenUseLocalEvidenceAndHideUncheckedValues() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false)
        let network = FinancialWorkspaceNetworkProbe(), gate = FinancialWorkspaceGate()
        let replay = FinancialDailyReplayProbe(gate: gate)
        let model = financialWorkspace(storage, network: network, replay: { _ in try await replay.run() })
        let sourceBytes = try ResearchDocument.encoded(parent), baseline = await storage.revision
        await model.load(); model.chooseTicker(parent.ticker)
        await model.performDaily(try #require(model.makeDailyRequest(.analyzeResearch(parent.id))))
        #expect(model.document?.id == parent.id && model.financialReport?.id == report.id)
        #expect(model.canDisplayFinancialReport && model.canSaveFinancialReport && !model.financialReportIsSaved)
        #expect(await storage.researchOpenReads == 1)
        #expect(await storage.preparations == 1)
        #expect(await storage.commits == 0)
        await model.performDaily(try #require(model.makeDailyRequest(.saveReport(report.id))))
        #expect(model.financialReportIsSaved && !model.canSaveFinancialReport)
        #expect(await storage.attemptedRevisions == [baseline])
        let request = try #require(model.makeDailyRequest(.openReport(report.id)))
        let previousReportRevision = model.financialReportRevision
        let opening = Task { await model.performDaily(request) }
        await gate.waitUntilEntered()
        #expect(model.isBusy && model.financialReport?.id == report.id)
        #expect(model.financialReportState == .notVerified && !model.canDisplayFinancialReport)
        #expect(model.financialReportRevision != previousReportRevision)
        await gate.release(); await opening.value
        #expect(model.financialReportState == .matched && model.canDisplayFinancialReport)
        #expect(model.financialReportIsSaved && !model.isBusy)
        #expect(await replay.calls == 1)
        #expect(await network.calls == 0)
        #expect(try ResearchDocument.encoded(try #require(model.document)) == sourceBytes)
        let beforeReplay = model.financialReportRevision
        await model.performDaily(try #require(model.makeDailyRequest(.replayReport(report.id))))
        #expect(model.financialReportRevision != beforeReplay && model.canDisplayFinancialReport)
        #expect(await replay.calls == 2)
    }

    @Test(arguments: ["open", "replay", "save"])
    func sameImmutableReportReselectionRejectsPreviouslyCapturedAction(action: String) async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report)
        let replay = FinancialDailyReplayProbe()
        let model = financialWorkspace(storage, replay: { _ in try await replay.run() })
        await model.load(); model.chooseTicker(parent.ticker)
        await model.performDaily(try #require(model.makeDailyRequest(.analyzeResearch(parent.id))))
        let command: SECStockDailyAction = action == "open" ? .openReport(report.id)
            : action == "replay" ? .replayReport(report.id) : .saveReport(report.id)
        let stale = try #require(model.makeDailyRequest(command))
        let originalRevision = model.financialReportRevision
        await model.openFinancialReport(report.id)
        let reopenedRevision = model.financialReportRevision
        #expect(reopenedRevision != originalRevision && model.financialReport?.id == report.id)
        await model.performDaily(stale)
        #expect(await storage.reportOpenReads == 1)
        #expect(await storage.commits == 0)
        #expect(await replay.calls == 0)
        #expect(model.financialReportRevision == reopenedRevision)
        #expect(model.financialReportState == .notVerified && !model.canDisplayFinancialReport)
    }

    @Test(arguments: ["ticker", "leaveAndReturn"])
    func queuedDailyActionsCannotFollowChangedTickerOrPageSession(change: String) async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), network = FinancialWorkspaceNetworkProbe()
        let replay = FinancialDailyReplayProbe()
        let model = financialWorkspace(storage, network: network, replay: { _ in try await replay.run() })
        await model.load(); model.chooseTicker(parent.ticker)
        await model.performDaily(try #require(model.makeDailyRequest(.analyzeResearch(parent.id))))
        let actions: [SECStockDailyAction] = [.analyzeResearch(parent.id), .openReport(report.id),
            .replayReport(report.id), .saveReport(report.id)]
        let queued = try actions.map { try #require(model.makeDailyRequest($0)) }
        if change == "ticker" { model.chooseTicker("MSFT") }
        else {
            model.disappear()
            #expect(model.makeDailyRequest(.openReport(report.id)) == nil)
            await model.load()
        }
        for request in queued { await model.performDaily(request) }
        #expect(await storage.researchOpenReads == 1)
        #expect(await storage.preparations == 1)
        #expect(await storage.reportOpenReads == 0)
        #expect(await storage.commits == 0)
        #expect(await replay.calls == 0)
        #expect(await network.calls == 0)
        #expect(model.document == nil && model.financialReport == nil && !model.isBusy)
    }

    @Test(arguments: ["sourceOpen", "prepare"])
    func leavingDuringDailyAnalysisPreventsLateResultAndFollowOnWork(stage: String) async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), gate = FinancialWorkspaceGate()
        let model = financialWorkspace(storage)
        await model.load(); model.chooseTicker(parent.ticker)
        if stage == "sourceOpen" { await storage.configure(researchOpenGate: gate) }
        else { await storage.configure(prepareGate: gate) }
        let request = try #require(model.makeDailyRequest(.analyzeResearch(parent.id)))
        let old = Task { await model.performDaily(request) }
        await gate.waitUntilEntered(); model.disappear()
        await model.load()
        await gate.release(); await old.value
        #expect(model.document == nil && model.financialReport == nil && !model.isBusy)
        #expect(!model.canDisplayFinancialReport && model.financialMessage == nil)
        #expect(await storage.preparations == (stage == "sourceOpen" ? 0 : 1))
        #expect(await storage.commits == 0)
    }

    @Test func unreadableSelectedSourceStopsBeforeAnalysisWithoutImportFallback() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), network = FinancialWorkspaceNetworkProbe()
        let model = financialWorkspace(storage, network: network)
        await model.load(); model.chooseTicker(parent.ticker)
        await storage.configure(researchOpenFails: true)
        await model.performDaily(try #require(model.makeDailyRequest(.analyzeResearch(parent.id))))
        #expect(model.document == nil && model.financialReport == nil && !model.canDisplayFinancialReport)
        #expect(model.hasError || model.financialHasError)
        #expect(await storage.researchOpenReads == 1)
        #expect(await storage.preparations == 0)
        #expect(await storage.commits == 0)
        #expect(await network.calls == 0)
    }

    @Test(arguments: ["open", "mismatch", "replayFailure"])
    func savedReportFailuresNeverExposeCachedNumbersOrImportAgain(failure: String) async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), network = FinancialWorkspaceNetworkProbe()
        let replay = FinancialDailyReplayProbe(result: failure != "mismatch", fails: failure == "replayFailure")
        let model = financialWorkspace(storage, network: network, replay: { _ in try await replay.run() })
        await model.load(); model.chooseTicker(parent.ticker)
        if failure == "open" { await storage.configure(reportOpenFails: true) }
        await model.performDaily(try #require(model.makeDailyRequest(.openReport(report.id))))
        #expect(!model.canDisplayFinancialReport && !model.canSaveFinancialReport && model.financialHasError)
        if failure == "open" {
            #expect(model.financialReport == nil)
            #expect(await replay.calls == 0)
        } else {
            #expect(model.financialReport?.id == report.id && model.financialReportIsSaved)
            #expect(model.financialReportState == (failure == "mismatch" ? .mismatched : .failed))
            #expect(await replay.calls == 1)
        }
        #expect(await storage.preparations == 0)
        #expect(await storage.commits == 0)
        #expect(await network.calls == 0)
    }

    @Test func explicitUpdateReusesImportedCompanyAndGeneratesOnlyAnUnsavedReport() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false)
        let network = FinancialWorkspaceNetworkProbe(result: parent)
        let model = SECResearchWorkspaceModel(storage: storage, networkAvailable: true,
            importer: { _, _, _ in try await network.importCompany() }, financialStorage: storage)
        await model.load(); model.chooseTicker(parent.ticker)
        #expect(await network.calls == 0)
        let update = try #require(model.startDailyUpdate(email: "researcher@example.invalid"))
        await update.value
        #expect(await network.calls == 1)
        #expect(await storage.preparations == 1)
        #expect(await storage.commits == 0)
        #expect(model.document?.id == parent.id && model.saved.map(\.id) == [parent.id])
        #expect(model.financialReport?.id == report.id && model.financialReportState == .generated)
        #expect(model.canSaveFinancialReport && !model.financialReportIsSaved)
        #expect(model.savedFinancialReports.isEmpty && !model.isBusy)
    }

    @Test(arguments: ["import", "prepare"])
    func updateFailureKeepsOnlyCompletedSourceWorkAndNeverSavesAReport(stage: String) async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false)
        let network = FinancialWorkspaceNetworkProbe(result: stage == "prepare" ? parent : nil)
        let model = SECResearchWorkspaceModel(storage: storage, networkAvailable: true,
            importer: { _, _, _ in try await network.importCompany() }, financialStorage: storage)
        await model.load(); model.chooseTicker(parent.ticker)
        if stage == "prepare" { await storage.configure(preparationError: .insufficientPeriods) }
        let update = try #require(model.startDailyUpdate(email: "researcher@example.invalid"))
        await update.value
        #expect(await network.calls == 1)
        #expect(await storage.preparations == (stage == "prepare" ? 1 : 0))
        #expect(await storage.commits == 0)
        #expect(model.financialReport == nil && !model.canDisplayFinancialReport && !model.isBusy)
        #expect(model.hasError || model.financialHasError)
        if stage == "prepare" { #expect(model.document?.id == parent.id) }
        else { #expect(model.document == nil) }
    }

    @Test func departedUpdateCannotPrepareOrPublishWhenUncooperativeImporterReturns() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false), gate = FinancialWorkspaceGate()
        let network = FinancialWorkspaceNetworkProbe(result: parent, gate: gate)
        let model = SECResearchWorkspaceModel(storage: storage, networkAvailable: true,
            importer: { _, _, _ in try await network.importCompany() }, financialStorage: storage)
        await model.load(); model.chooseTicker(parent.ticker)
        let old = try #require(model.startDailyUpdate(email: "researcher@example.invalid"))
        await gate.waitUntilEntered(); model.disappear()
        await model.load()
        await gate.release(); await old.value
        #expect(await network.calls == 1)
        #expect(await storage.preparations == 0)
        #expect(await storage.commits == 0)
        #expect(model.document == nil && model.financialReport == nil && !model.isBusy)
        #expect(model.financialMessage == nil && model.message == nil)
    }

    @Test(arguments: ["recoverable", "stale"])
    func dailySaveKeepsOriginalRevisionAndNeverRetargetsAnInvalidDraft(failure: String) async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report, stored: false)
        let model = financialWorkspace(storage)
        await model.load(); model.chooseTicker(parent.ticker)
        await model.performDaily(try #require(model.makeDailyRequest(.analyzeResearch(parent.id))))
        let baseline = await storage.revision
        if failure == "stale" { await storage.advanceRevision() }
        else { await storage.configure(saveFails: true) }
        await model.performDaily(try #require(model.makeDailyRequest(.saveReport(report.id))))
        #expect(await storage.attemptedRevisions == [baseline])
        #expect(await storage.commits == 0)
        #expect(model.financialHasError && !model.financialReportIsSaved)
        if failure == "stale" {
            #expect(!model.canSaveFinancialReport && model.makeDailyRequest(.saveReport(report.id)) == nil)
        } else {
            #expect(model.canSaveFinancialReport)
            await storage.configure()
            await model.performDaily(try #require(model.makeDailyRequest(.saveReport(report.id))))
            #expect(await storage.attemptedRevisions == [baseline, baseline])
            #expect(await storage.commits == 1)
            #expect(model.financialReportIsSaved && !model.financialHasError)
        }
    }

    @Test func dailyReloadKeepsListFailuresIndependentAndCannotReviveDepartedPage() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), model = financialWorkspace(storage)
        await model.load(); model.chooseTicker(parent.ticker)
        await storage.configure(researchListFails: true)
        await model.performDaily(try #require(model.makeDailyRequest(.reloadLists)))
        #expect(model.saved.isEmpty && model.listError != nil)
        #expect(model.savedFinancialReports.map(\.id) == [report.id] && model.financialListError == nil)
        await storage.configure(reportListFails: true)
        await model.performDaily(try #require(model.makeDailyRequest(.reloadLists)))
        #expect(model.saved.map(\.id) == [parent.id] && model.listError == nil)
        #expect(model.savedFinancialReports.isEmpty && model.financialListError != nil)
        let queued = try #require(model.makeDailyRequest(.reloadLists))
        let sourceReads = await storage.researchListReads, reportReads = await storage.reportListReads
        model.disappear()
        await model.performDaily(queued)
        #expect(await storage.researchListReads == sourceReads)
        #expect(await storage.reportListReads == reportReads)
        #expect(model.saved.isEmpty && model.savedFinancialReports.isEmpty && !model.isBusy)
        await storage.configure()
        await model.load()
        let gate = FinancialWorkspaceGate()
        await storage.configure(listGate: gate)
        let request = try #require(model.makeDailyRequest(.reloadLists))
        let pending = Task { await model.performDaily(request) }
        await gate.waitUntilEntered(); model.disappear()
        await gate.release(); await pending.value
        #expect(model.saved.isEmpty && model.savedFinancialReports.isEmpty && !model.isBusy)
        #expect(model.listError == nil && model.financialListError == nil)
        #expect(await storage.researchOpenReads == 0)
        #expect(await storage.preparations == 0)
    }

    @Test func openingBoundSourceIsOfflineAndAlsoWorksWithoutFinancialStorage() async throws {
        let (parent, report) = try await FinancialWorkspaceFixture.shared.value()
        let storage = FinancialWorkspaceStorage(parent: parent, report: report), network = FinancialWorkspaceNetworkProbe()
        let model = financialWorkspace(storage, network: network)
        await storage.configure(researchListFails: true)
        await model.load(); model.chooseTicker(parent.ticker)
        await model.openFinancialReport(report.id)
        #expect(model.saved.isEmpty && model.financialReport?.parentDocumentID == parent.id)
        await model.performDaily(try #require(model.makeDailyRequest(.openResearch(parent.id))))
        #expect(model.document?.id == parent.id && model.financialReport == nil && !model.canDisplayValues)
        await storage.configure()
        let sourceOnly = SECResearchWorkspaceModel(storage: storage, networkAvailable: false,
            importer: { _, _, _ in try await network.importCompany() })
        await sourceOnly.load(); sourceOnly.chooseTicker(parent.ticker)
        await sourceOnly.performDaily(try #require(sourceOnly.makeDailyRequest(.openResearch(parent.id))))
        #expect(sourceOnly.document?.id == parent.id && !sourceOnly.canGenerateFinancialReport)
        #expect(!sourceOnly.canDisplayValues && sourceOnly.financialReport == nil)
        let wrongTicker = try #require(sourceOnly.makeDailyRequest(.openResearch(parent.id)))
        sourceOnly.chooseTicker("MSFT")
        await sourceOnly.performDaily(wrongTicker)
        #expect(sourceOnly.document == nil)
        sourceOnly.chooseTicker(parent.ticker)
        let departed = try #require(sourceOnly.makeDailyRequest(.openResearch(parent.id)))
        sourceOnly.disappear(); await sourceOnly.load()
        await sourceOnly.performDaily(departed)
        #expect(sourceOnly.document == nil && !sourceOnly.isBusy)
        #expect(await storage.researchOpenReads == 2)
        #expect(await storage.preparations == 0)
        #expect(await storage.commits == 0)
        #expect(await network.calls == 0)
    }

}
