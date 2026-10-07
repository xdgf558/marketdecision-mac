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
    var researchListReads = 0, reportListReads = 0, reportOpenReads = 0, preparations = 0, commits = 0
    var attemptedRevisions: [UUID] = []
    private var researchListFails = false, reportListFails = false, saveFails = false
    private var preparationError: SECFinancialError?
    private var prepareGate: FinancialWorkspaceGate?, saveGate: FinancialWorkspaceGate?
    private var openGate: FinancialWorkspaceGate?, listGate: FinancialWorkspaceGate?
    init(parent: SECResearchDocument, report: SECFinancialReportDocument, stored: Bool = true) {
        self.parent = parent; prepared = report; self.stored = stored ? [report] : []
    }
    func configure(researchListFails: Bool = false, reportListFails: Bool = false, saveFails: Bool = false,
                   preparationError: SECFinancialError? = nil, prepareGate: FinancialWorkspaceGate? = nil,
                   saveGate: FinancialWorkspaceGate? = nil, openGate: FinancialWorkspaceGate? = nil,
                   listGate: FinancialWorkspaceGate? = nil) {
        self.researchListFails = researchListFails; self.reportListFails = reportListFails; self.saveFails = saveFails
        self.preparationError = preparationError; self.prepareGate = prepareGate; self.saveGate = saveGate
        self.openGate = openGate; self.listGate = listGate
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
        let result = stored.first { $0.id == id }, gate = openGate
        openGate = nil
        if let gate { await gate.hold() }
        guard let result else { throw SnapshotError.missingReference }
        return result
    }
}

private actor FinancialWorkspaceNetworkProbe {
    var calls = 0
    func importCompany() throws -> SECResearchDocument { calls += 1; throw FinancialWorkspaceFailure.injected }
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
        await model.openFinancialReport(report.id)
        #expect(!model.canDisplayFinancialReport && model.financialReportState == .notVerified)
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
