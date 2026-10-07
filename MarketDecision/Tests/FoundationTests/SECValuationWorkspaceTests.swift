import Foundation
import Testing
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private enum ValuationWorkspaceFailure: Error { case injected }
private actor ValuationWorkspaceGate {
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
private actor ValuationWorkspaceFixture {
    static let shared = ValuationWorkspaceFixture()
    private var pending: Task<(SECResearchDocument, SECFinancialReportDocument, SECValuationSupplementDocument), any Error>?
    func value() async throws -> (SECResearchDocument, SECFinancialReportDocument, SECValuationSupplementDocument) {
        if let pending { return try await pending.value }
        let task = Task {
            let (_, _, source, financial, draft) = try await secValuationStorageFixture()
            return (source, financial, draft.document)
        }
        pending = task
        return try await task.value
    }
}
private actor ValuationWorkspaceStorage: SECResearchWorkspaceStorage, SECFinancialReportWorkspaceStorage, SECValuationWorkspaceStorage {
    let source: SECResearchDocument, financial: SECFinancialReportDocument
    var prepared: SECValuationSupplementDocument
    var stored: [SECValuationSupplementDocument]
    var revision = UUID()
    var preparations = 0, opens = 0, commits = 0
    var attemptedRevisions: [UUID] = []
    var receivedEvidence: [SECValuationInputEvidence] = []
    private var sourceListFails = false, financialListFails = false, valuationListFails = false, saveFails = false
    private var prepareGate: ValuationWorkspaceGate?, saveGate: ValuationWorkspaceGate?, openGate: ValuationWorkspaceGate?, listGate: ValuationWorkspaceGate?
    init(source: SECResearchDocument, financial: SECFinancialReportDocument, valuation: SECValuationSupplementDocument, stored: Bool = true) {
        self.source = source; self.financial = financial; prepared = valuation; self.stored = stored ? [valuation] : []
    }
    func configure(sourceListFails: Bool = false, financialListFails: Bool = false, valuationListFails: Bool = false,
                   saveFails: Bool = false, prepareGate: ValuationWorkspaceGate? = nil, saveGate: ValuationWorkspaceGate? = nil,
                   openGate: ValuationWorkspaceGate? = nil, listGate: ValuationWorkspaceGate? = nil) {
        self.sourceListFails = sourceListFails; self.financialListFails = financialListFails
        self.valuationListFails = valuationListFails; self.saveFails = saveFails
        self.prepareGate = prepareGate; self.saveGate = saveGate; self.openGate = openGate; self.listGate = listGate
    }
    func advanceRevision() { revision = UUID() }
    func replacePrepared(_ document: SECValuationSupplementDocument) { prepared = document }
    func savedResearch() throws -> [SECResearchSummary] {
        if sourceListFails { throw ValuationWorkspaceFailure.injected }
        return [.init(document: source)]
    }
    func open(id: UUID) throws -> SECResearchDocument {
        guard id == source.id else { throw SnapshotError.missingReference }; return source
    }
    func prepareFinancialReport(parentID: UUID, executionDate: Date) throws -> SECFinancialReportDraft {
        guard parentID == source.id else { throw SnapshotError.missingReference }
        return .init(document: financial, expectedRevision: revision)
    }
    func saveFinancialReport(_ document: SECFinancialReportDocument, expectedRevision: UUID) throws {
        guard expectedRevision == revision else { throw SnapshotError.stalePlan }; revision = UUID()
    }
    func savedFinancialReports(parentID: UUID?) throws -> [SECFinancialReportSummary] {
        if financialListFails { throw ValuationWorkspaceFailure.injected }
        return [.init(document: financial)]
    }
    func openFinancialReport(id: UUID) throws -> SECFinancialReportDocument {
        guard id == financial.id else { throw SnapshotError.missingReference }; return financial
    }
    func valuationSourceDocument(parentReportID: UUID) throws -> SECResearchDocument {
        guard parentReportID == financial.id else { throw SnapshotError.missingReference }; return source
    }
    func prepareValuationSupplement(parentReportID: UUID, evidence: SECValuationInputEvidence, executionDate: Date) async throws -> SECValuationSupplementDraft {
        preparations += 1; receivedEvidence.append(evidence)
        let baseline = revision, result = prepared, gate = prepareGate; prepareGate = nil
        guard parentReportID == financial.id else { throw SnapshotError.missingReference }
        if let gate { await gate.hold() }
        guard revision == baseline else { throw SnapshotError.stalePlan }
        // This dependency intentionally can return after cancel; the page must reject old publication.
        return .init(document: result, expectedRevision: baseline)
    }
    func saveValuationSupplement(_ document: SECValuationSupplementDocument, expectedRevision: UUID) async throws {
        attemptedRevisions.append(expectedRevision)
        let gate = saveGate, fails = saveFails; saveGate = nil
        if let gate { await gate.hold() }
        try Task.checkCancellation()
        guard revision == expectedRevision else { throw SnapshotError.stalePlan }
        if fails { throw ValuationWorkspaceFailure.injected }
        stored.append(document); commits += 1; revision = UUID()
    }
    func savedValuationSupplements(parentReportID: UUID?) async throws -> [SECValuationSupplementSummary] {
        let rows = stored, fails = valuationListFails, gate = listGate; listGate = nil
        if let gate { await gate.hold() }
        if fails { throw ValuationWorkspaceFailure.injected }
        return rows.filter { parentReportID == nil || $0.parentFinancialReportID == parentReportID }.map(SECValuationSupplementSummary.init(document:))
    }
    func openValuationSupplement(id: UUID) async throws -> SECValuationSupplementDocument {
        opens += 1
        let result = stored.first { $0.id == id }, gate = openGate; openGate = nil
        if let gate { await gate.hold() }
        guard let result else { throw SnapshotError.missingReference }; return result
    }
}
private actor ValuationWorkspaceNetworkProbe {
    var calls = 0
    func importCompany() throws -> SECResearchDocument { calls += 1; throw ValuationWorkspaceFailure.injected }
}
@MainActor private func valuationWorkspace(_ storage: ValuationWorkspaceStorage, now: Date,
    network: ValuationWorkspaceNetworkProbe = .init(),
    replay: (@Sendable (SECValuationSupplementDocument) async throws -> Bool)? = nil) -> SECResearchWorkspaceModel {
    if let replay {
        return .init(storage: storage, networkAvailable: false, importer: { _, _, _ in try await network.importCompany() },
            financialStorage: storage, valuationStorage: storage, now: { now }, valuationReplay: replay)
    }
    return .init(storage: storage, networkAvailable: false, importer: { _, _, _ in try await network.importCompany() },
        financialStorage: storage, valuationStorage: storage, now: { now })
}

@Suite @MainActor struct SECValuationWorkspaceTests {
    @Test func listsAreIndependentAndNeverGenerateOpenOrImportOnLoad() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation), network = ValuationWorkspaceNetworkProbe()
        let model = valuationWorkspace(storage, now: valuation.createdAt, network: network)
        await storage.configure(sourceListFails: true, financialListFails: true)
        await model.load()
        #expect(model.listError != nil && model.financialListError != nil)
        #expect(model.savedValuationSupplements.map(\.id) == [valuation.id] && model.valuationListError == nil)
        await storage.configure(valuationListFails: true)
        await model.load()
        #expect(model.saved.count == 1 && model.savedFinancialReports.count == 1)
        #expect(model.valuationListError != nil && model.savedValuationSupplements.isEmpty)
        #expect(model.valuationSupplement == nil && !model.canDisplayValuationSupplement)
        #expect(await storage.preparations == 0)
        #expect(await storage.opens == 0)
        #expect(await network.calls == 0)
    }

    @Test func unsavedFinancialParentCannotGenerateAndExplicitSavedWorkflowReplaysOffline() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation, stored: false)
        let network = ValuationWorkspaceNetworkProbe(), model = valuationWorkspace(storage, now: valuation.createdAt, network: network)
        await model.open(source.id); await model.generateFinancialReport()
        #expect(!model.canGenerateValuationSupplement)
        await model.generateValuationSupplement(evidence: .init())
        #expect(await storage.preparations == 0)
        await model.saveFinancialReport()
        #expect(model.canGenerateValuationSupplement)
        let baseline = await storage.revision
        await model.generateValuationSupplement(evidence: .init())
        #expect(model.canDisplayValuationSupplement && model.canSaveValuationSupplement && model.valuationState == .generated)
        await model.saveValuationSupplement()
        #expect(model.valuationIsSaved && !model.canSaveValuationSupplement)
        #expect(await storage.attemptedRevisions == [baseline])
        await model.openValuationSupplement(valuation.id)
        #expect(!model.canDisplayValuationSupplement && model.valuationState == .notVerified)
        await model.recomputeValuationSupplement()
        #expect(model.canDisplayValuationSupplement && model.valuationState == .matched)
        #expect(await network.calls == 0)
    }

    @Test func staleDraftNeverRebasesAndRetryPreservesItsOriginalRevision() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation, stored: false)
        let model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await model.generateValuationSupplement(evidence: .init())
        let baseline = await storage.revision
        await storage.configure(saveFails: true); await model.saveValuationSupplement()
        #expect(model.canSaveValuationSupplement && model.valuationHasError)
        await storage.advanceRevision(); await storage.configure(); await model.saveValuationSupplement()
        #expect(await storage.attemptedRevisions == [baseline, baseline])
        #expect(await storage.commits == 0)
        #expect(!model.canSaveValuationSupplement && !model.valuationIsSaved && model.valuationHasError)
        await model.saveValuationSupplement()
        #expect(await storage.attemptedRevisions.count == 2)
    }

    @Test func successfulCommitSurvivesSummaryRefreshFailure() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation, stored: false)
        let model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await model.generateValuationSupplement(evidence: .init())
        await storage.configure(valuationListFails: true); await model.saveValuationSupplement()
        #expect(await storage.commits == 1)
        #expect(model.valuationIsSaved && !model.canSaveValuationSupplement && !model.valuationHasError)
        #expect(model.valuationListError != nil && model.valuationMessage?.contains("已保存") == true)
        #expect(model.financialReport?.id == financial.id)
    }

    @Test func wrongFinancialParentDraftCannotRelabelSelectedReport() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(valuation)) as? [String: Any])
        object["parentFinancialReportID"] = UUID().uuidString
        let wrong = try JSONDecoder().decode(SECValuationSupplementDocument.self, from: JSONSerialization.data(withJSONObject: object))
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: wrong), model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await model.generateValuationSupplement(evidence: .init())
        #expect(model.valuationSupplement == nil && model.valuationHasError && !model.canSaveValuationSupplement)
        #expect(model.financialReport?.id == financial.id)
    }

    @Test func cancelledPreparationCannotPublishOrReleaseNewOpenBusyState() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let oldGate = ValuationWorkspaceGate(), newGate = ValuationWorkspaceGate()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation), model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await storage.configure(prepareGate: oldGate)
        let old = Task { await model.generateValuationSupplement(evidence: .init()) }
        await oldGate.waitUntilEntered(); model.cancel(); await storage.configure(openGate: newGate)
        let current = Task { await model.openValuationSupplement(valuation.id) }
        await newGate.waitUntilEntered(); await oldGate.release(); await old.value
        #expect(model.isBusy && model.valuationSupplement == nil && model.valuationMessage == nil)
        await newGate.release(); await current.value
        #expect(!model.isBusy && model.valuationSupplement?.id == valuation.id && !model.canDisplayValuationSupplement)
    }

    @Test func cancelQueuedSaveCancelsStorageAndPagePublication() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let gate = ValuationWorkspaceGate(), storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation, stored: false)
        let model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await model.generateValuationSupplement(evidence: .init())
        await storage.configure(saveGate: gate)
        let saving = Task { await model.saveValuationSupplement() }
        await gate.waitUntilEntered(); model.disappear(); await gate.release(); await saving.value
        #expect(await storage.commits == 0)
        #expect(!model.isBusy && model.valuationSupplement == nil && !model.valuationIsSaved)
        #expect(model.savedValuationSupplements.isEmpty && model.valuationMessage == nil)
    }

    @Test func replayImmediatelyHidesGeneratedResultsAndMismatchKeepsThemHidden() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let gate = ValuationWorkspaceGate(), storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation)
        let model = valuationWorkspace(storage, now: valuation.createdAt, replay: { _ in await gate.hold(); return false })
        await model.openFinancialReport(financial.id); await model.generateValuationSupplement(evidence: .init())
        #expect(model.canDisplayValuationSupplement)
        let replay = Task { await model.recomputeValuationSupplement() }
        await gate.waitUntilEntered()
        #expect(model.isBusy && !model.canDisplayValuationSupplement && !model.canSaveValuationSupplement)
        await gate.release(); await replay.value
        #expect(model.valuationState == .mismatched && !model.canDisplayValuationSupplement && !model.canSaveValuationSupplement)
    }

    @Test func failedOrLateReplayNeverVerifiesReenteredPage() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation), gate = ValuationWorkspaceGate()
        let failed = valuationWorkspace(storage, now: valuation.createdAt, replay: { _ in throw ValuationWorkspaceFailure.injected })
        await failed.openValuationSupplement(valuation.id); await failed.recomputeValuationSupplement()
        #expect(failed.valuationState == .failed && !failed.canDisplayValuationSupplement)
        let model = valuationWorkspace(storage, now: valuation.createdAt, replay: { _ in await gate.hold(); return true })
        await model.openValuationSupplement(valuation.id)
        let old = Task { await model.recomputeValuationSupplement() }
        await gate.waitUntilEntered(); model.disappear(); await model.load()
        await gate.release(); await old.value
        #expect(model.valuationSupplement == nil && !model.canDisplayValuationSupplement && !model.isBusy)
        #expect(model.valuationMessage == nil && model.savedValuationSupplements.count == 1)
    }

    @Test func oldListFailureCannotEraseNewListOrParentSelection() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let gate = ValuationWorkspaceGate(), storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation)
        let model = valuationWorkspace(storage, now: valuation.createdAt)
        await storage.configure(valuationListFails: true, listGate: gate)
        let old = Task { await model.loadValuationSupplements() }
        await gate.waitUntilEntered(); model.cancel(); await storage.configure()
        await model.load(); await model.openFinancialReport(financial.id)
        await gate.release(); await old.value
        #expect(model.valuationListError == nil && model.savedValuationSupplements.map(\.id) == [valuation.id])
        #expect(model.financialReport?.id == financial.id && !model.isBusy)
    }

    @Test func repeatedIntegerUsesUniqueSourceContextAndAmbiguousContextIsRejected() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation)
        let model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await model.loadValuationSources()
        let raw = try #require(source.sources.first { $0.endpoint == .companyFacts })
        let root = try #require(JSONSerialization.jsonObject(with: raw.bytes) as? [String: Any])
        let facts = try #require(root["facts"] as? [String: Any])
        let gaap = try #require(facts["us-gaap"] as? [String: Any])
        let revenue = try #require(gaap["RevenueFromContractWithCustomerExcludingAssessedTax"] as? [String: Any])
        let units = try #require(revenue["units"] as? [String: Any])
        let values = try #require(units["USD"] as? [[String: Any]])
        let context = try String(decoding: JSONSerialization.data(withJSONObject: values[0], options: [.sortedKeys]), as: UTF8.self)
        var form = SECValuationShareEvidenceDraft()
        form.sourceReference = raw.reference; form.coverDate = "2024-12-31"
        form.accessionNumber = try #require(values[0]["accn"] as? String)
        form.rationale = "Synthetic form citation test, not real capital evidence"
        form.completenessExcerpt = context
        form.classes[0].classID = "common"; form.classes[0].symbol = source.ticker
        form.classes[0].countExcerpt = "100"; form.classes[0].identityExcerpt = context
        await model.generateValuationSupplement(applicability: .unknown, sourceReference: "", excerpt: "", rationale: "", shareEvidence: form)
        #expect(await storage.preparations == 0)
        form.classes[0].countContextExcerpt = context
        await model.generateValuationSupplement(applicability: .unknown, sourceReference: "", excerpt: "", rationale: "", shareEvidence: form)
        #expect(await storage.preparations == 1)
        let reviewed = try #require(await storage.receivedEvidence.last?.shareClasses?.classes.first)
        let contextRange = try #require(raw.bytes.range(of: Data(context.utf8)))
        let numberRange = try #require(Data(context.utf8).range(of: Data("100".utf8)))
        #expect(reviewed.countAnchor.byteOffset == contextRange.lowerBound + numberRange.lowerBound)
        #expect(reviewed.countAnchor.text == "100" && reviewed.outstandingShares.decimalString == "100")
        // A unique outer source fragment still must identify one integer occurrence within it.
        let first = try #require(raw.bytes.range(of: Data("100".utf8)))
        let second = try #require(raw.bytes.range(of: Data("100".utf8), in: first.upperBound..<raw.bytes.endIndex))
        form.classes[0].countContextExcerpt = String(decoding: raw.bytes.subdata(in: max(0, first.lowerBound - 32)..<min(raw.bytes.count, second.upperBound + 32)), as: UTF8.self)
        await model.generateValuationSupplement(applicability: .unknown, sourceReference: "", excerpt: "", rationale: "", shareEvidence: form)
        #expect(await storage.preparations == 1)
        #expect(model.valuationHasError)
    }

    @Test func explicitSourceCitationRejectsWrongOrAmbiguousTextAndParentChangesClearEvidence() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation), model = valuationWorkspace(storage, now: valuation.createdAt)
        await model.openFinancialReport(financial.id); await model.loadValuationSources()
        #expect(model.valuationSourceDocument?.id == source.id)
        let identity = try #require(source.sources.first { $0.endpoint == .companyIdentity })
        await model.generateValuationSupplement(applicability: .generalNonFinancial, sourceReference: identity.reference,
            excerpt: "not-in-source", rationale: "Local review")
        #expect(model.valuationHasError && model.valuationSupplement == nil)
        #expect(await storage.preparations == 0)
        await model.generateValuationSupplement(applicability: .generalNonFinancial, sourceReference: identity.reference,
            excerpt: "\"", rationale: "Local review")
        #expect(await storage.preparations == 0)
        await model.generateValuationSupplement(applicability: .generalNonFinancial, sourceReference: identity.reference,
            excerpt: "Synthetic Report Company", rationale: "Synthetic local applicability review")
        #expect(await storage.preparations == 1)
        let evidence = try #require(await storage.receivedEvidence.last?.industryReview)
        #expect(evidence.applicability == .generalNonFinancial && evidence.anchors.first?.sourceHash == identity.contentHash)
        #expect(evidence.anchors.first?.text == "Synthetic Report Company")
        await model.openFinancialReport(financial.id)
        #expect(model.valuationSourceDocument == nil && model.valuationSupplement == nil && !model.canSaveValuationSupplement)
        model.chooseTicker("NEW")
        #expect(model.financialReport == nil && !model.canGenerateValuationSupplement)
    }
}
