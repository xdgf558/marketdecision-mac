import Foundation
import Testing
import CoreDomain
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

@MainActor private func persistentValuationWorkspace(_ storage: SECResearchStore, now: Date,
    network: ValuationWorkspaceNetworkProbe) -> SECResearchWorkspaceModel {
    .init(storage: storage, networkAvailable: false, importer: { _, _, _ in try await network.importCompany() },
        financialStorage: storage, valuationStorage: storage, now: { now })
}

private func capturedPriceWorkspaceForm(_ source: SECResearchDocument) throws
    -> (industryReference: String, shares: SECValuationShareEvidenceDraft, split: SECValuationSplitEvidenceDraft) {
    let identity = try #require(source.sources.first { $0.endpoint == .companyIdentity })
    let raw = try #require(source.sources.first { $0.endpoint == .companyFacts })
    let root = try #require(JSONSerialization.jsonObject(with: raw.bytes) as? [String: Any])
    let facts = try #require(root["facts"] as? [String: Any])
    let gaap = try #require(facts["us-gaap"] as? [String: Any])
    let revenue = try #require(gaap["RevenueFromContractWithCustomerExcludingAssessedTax"] as? [String: Any])
    let units = try #require(revenue["units"] as? [String: Any])
    let values = try #require(units["USD"] as? [[String: Any]])
    let context = try String(decoding: JSONSerialization.data(withJSONObject: values[0], options: [.sortedKeys]), as: UTF8.self)
    // Reuse the retained synthetic integer/context fixture to exercise form byte binding.
    // This deliberately artificial interpretation is not issuer capital or split evidence.
    var shares = SECValuationShareEvidenceDraft()
    shares.sourceReference = raw.reference; shares.coverDate = "2024-12-31"
    shares.accessionNumber = try #require(values[0]["accn"] as? String)
    shares.rationale = "Synthetic form binding test only, not real capital evidence"
    shares.completenessExcerpt = context
    shares.classes[0].classID = "common"; shares.classes[0].symbol = source.ticker
    shares.classes[0].countExcerpt = "100"; shares.classes[0].identityExcerpt = context
    shares.classes[0].countContextExcerpt = context
    var split = SECValuationSplitEvidenceDraft()
    split.sourceReference = raw.reference; split.excerpt = context; split.basisDate = "2026-10-03"
    split.rationale = "Synthetic same-basis form test, no conversion or real split qualification"
    return (identity.reference, shares, split)
}

private func capturedPriceWorkspaceQuote(symbol: String, cutoff: Date) throws -> SECValuationPriceEvidence {
    let requestTime = cutoff.addingTimeInterval(4), received = cutoff.addingTimeInterval(5)
    let timestamp = "2026-10-04T00:00:04Z"
    let raw = Data("{\"symbol\":\"\(symbol)\",\"quote\":{\"t\":\"\(timestamp)\",\"bp\":9,\"ap\":10,\"bs\":2,\"as\":3,\"bx\":\"V\",\"ax\":\"V\"}}".utf8)
    let source = try SECValuationSourceMaterial(reference: "synthetic/workspace-quote/" + symbol,
        contentHash: digest(raw), bytes: raw)
    let quote = try EquityQuoteValues(bid: Money("9"), ask: Money("10"), bidSize: Money("2"),
        askSize: Money("3"), bidExchange: "V", askExchange: "V")
    let rights = try SECCapturedPriceRights(entitlementVersion: "synthetic-rights.v1",
        evidenceReference: "synthetic-workspace-scope", licenseReference: "synthetic-only",
        recordedAt: cutoff, validFrom: cutoff, validThrough: cutoff.addingTimeInterval(3_600),
        assertion: "SYNTHETIC rights fixture, no live entitlement",
        evidenceBytes: Data("SYNTHETIC local reference retention test".utf8))
    let request = ProviderRequest(providerID: "alpaca", feedID: "iex", resourceID: symbol,
        capability: .quote, mode: .latest, usage: .replay, configurationVersion: "alpaca-iex-raw-daily.v1",
        entitlementVersion: rights.entitlementVersion, requestedAt: requestTime)
    let provenance = try Provenance(providerID: "alpaca", feedID: "iex", sourceEventAt: EquityRecord.sourceTime(timestamp),
        receivedAt: received, availableAt: nil, evidenceRef: rights.evidenceReference, origin: .provider,
        endpointDescriptor: EndpointDescriptor.quote.rawValue, requestedAt: requestTime, requestID: request.id,
        observationDate: MarketDate(iso8601: "2026-10-03"),
        versionID: EquityRecord.contentVersion(symbol: symbol, timestamp: timestamp, quote: quote, bar: nil),
        versionKind: .localContent, availability: .unknown, rawObjectRef: source.reference, rawHash: source.contentHash,
        normalizationVersion: "equity.raw-iex.v1", licenseRef: rights.licenseReference)
    let record = try EquityRecord(symbol: symbol, sourceTimestamp: timestamp, quote: quote, provenance: provenance)
    return try .init(classID: "common", record: record, request: request, rawSource: source, rights: rights,
        selectedSide: .ask, captureOrigin: .syntheticFixture)
}

@Suite @MainActor struct SECValuationWorkspaceTests {
    @Test func explicitCapturedPriceFormRoundTripsSourceWithoutHistoricalEligibility() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let (_, storage, source, financial, _) = try await secValuationStorageFixture(path: path.path)
        let now = source.cutoff.addingTimeInterval(10), network = ValuationWorkspaceNetworkProbe()
        let model = persistentValuationWorkspace(storage, now: now, network: network)
        let form = try capturedPriceWorkspaceForm(source), price = try capturedPriceWorkspaceQuote(symbol: source.ticker, cutoff: source.cutoff)
        await model.openFinancialReport(financial.id); await model.loadValuationSources()
        await model.generateValuationSupplement(applicability: .generalNonFinancial, sourceReference: form.industryReference,
            excerpt: "Synthetic Report Company", rationale: "Synthetic local applicability review",
            shareEvidence: form.shares, splitEvidence: form.split, capturedPrices: [price])
        let generated = try #require(model.valuationSupplement)
        #expect(model.canDisplayValuationSupplement && model.canSaveValuationSupplement)
        #expect(generated.valuation.results.reference?.metrics["marketCap"]?.value == (try Money("1000")))
        #expect(!source.sources.contains { $0.reference == price.rawSource.reference })
        await model.saveValuationSupplement()
        #expect(model.valuationIsSaved && !model.valuationHasError)
        let reopened = try SECResearchStore(path: path.path)
        let restored = persistentValuationWorkspace(reopened, now: now, network: network)
        await restored.openValuationSupplement(generated.id)
        #expect(!restored.canDisplayValuationSupplement && restored.valuationState == .notVerified)
        let opened = try #require(restored.valuationSupplement)
        #expect(try ResearchDocument.encoded(opened) == ResearchDocument.encoded(generated))
        let retained = try #require(opened.valuation.evidence.prices.first)
        #expect(try ResearchDocument.encoded(retained) == ResearchDocument.encoded(price))
        #expect(retained.rawSource.bytes == price.rawSource.bytes && retained.rawSource.contentHash == digest(price.rawSource.bytes))
        #expect(retained.request.id == price.request.id && retained.rights.evidenceBytes == price.rights.evidenceBytes)
        #expect(retained.rights.evidenceHash == digest(price.rights.evidenceBytes) && retained.selectedSide == .ask)
        await restored.recomputeValuationSupplement()
        #expect(restored.canDisplayValuationSupplement && restored.valuationState == .matched)
        let report = try #require(restored.valuationSupplement?.valuation)
        #expect(report.results.reference?.metrics["marketCap"]?.value == (try Money("1000")))
        #expect(report.results.base.metrics["marketCap"]?.value == nil)
        #expect(report.inputSnapshot.financials.input.classes.isEmpty)
        #expect(report.inputSnapshot.financials.input.normalization.asOf == source.cutoff)
        #expect(retained.record.provenance.availability == .unknown && retained.record.provenance.versionKind == .localContent)
        #expect(report.results.score?.valuation.historyInputs.isEmpty == true)
        #expect(report.results.score?.valuation.metrics.values.allSatisfy { $0.prices.isEmpty && $0.validDays == 0 } == true)
        #expect(report.assessment.referenceScenarioOnly && report.assessment.researchOnly)
        #expect(!report.assessment.historicalPITQualified && !report.assessment.productionEligible)
        #expect(report.assessment.gaps.contains(.syntheticReferenceOnly) && report.assessment.gaps.contains(.historicalValuationUnavailable))
        #expect(try await reopened.savedValuationSupplements(parentReportID: financial.id).count == 1)
        #expect(await network.calls == 0)
    }

    @Test func capturedPriceForDifferentTickerIsRejectedBeforePreparation() async throws {
        let (source, financial, valuation) = try await ValuationWorkspaceFixture.shared.value()
        let storage = ValuationWorkspaceStorage(source: source, financial: financial, valuation: valuation, stored: false)
        let model = valuationWorkspace(storage, now: source.cutoff.addingTimeInterval(10))
        let wrongPrice = try capturedPriceWorkspaceQuote(symbol: "MSFT", cutoff: source.cutoff)
        #expect(wrongPrice.record.symbol != financial.ticker)
        await model.openFinancialReport(financial.id)
        await model.generateValuationSupplement(applicability: .unknown, sourceReference: "", excerpt: "", rationale: "",
            capturedPrices: [wrongPrice])
        #expect(model.valuationHasError && model.valuationSupplement == nil && !model.canSaveValuationSupplement)
        #expect(await storage.preparations == 0)
        #expect(await storage.receivedEvidence.isEmpty)
        await model.saveValuationSupplement()
        #expect(await storage.commits == 0)
        #expect(await storage.stored.isEmpty)
    }

    @Test func omittingCapturedPricesKeepsTheFormPriceGap() async throws {
        let (_, storage, source, financial, _) = try await secValuationStorageFixture()
        let network = ValuationWorkspaceNetworkProbe()
        let model = persistentValuationWorkspace(storage, now: source.cutoff.addingTimeInterval(10), network: network)
        let form = try capturedPriceWorkspaceForm(source)
        await model.openFinancialReport(financial.id); await model.loadValuationSources()
        await model.generateValuationSupplement(applicability: .generalNonFinancial, sourceReference: form.industryReference,
            excerpt: "Synthetic Report Company", rationale: "Synthetic local applicability review",
            shareEvidence: form.shares, splitEvidence: form.split)
        let report = try #require(model.valuationSupplement?.valuation)
        #expect(model.canDisplayValuationSupplement && model.canSaveValuationSupplement)
        #expect(report.evidence.prices.isEmpty && report.results.reference == nil)
        #expect(report.assessment.gaps.contains(.priceSourceMissing) && !report.assessment.currentReferenceCapitalAvailable)
        #expect(report.results.base.metrics["marketCap"]?.value == nil)
        #expect(report.results.score?.valuation.historyInputs.isEmpty == true)
        #expect(await network.calls == 0)
    }

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
