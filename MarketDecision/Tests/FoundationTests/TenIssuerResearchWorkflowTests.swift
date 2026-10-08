import Foundation
import Testing
import CoreDomain
import DataContracts
import FundamentalsEngine
import Persistence
import AppComposition

private let workflowIssuers = ["AAPL", "MSFT", "META", "AMZN", "NVDA", "COST", "WMT", "KO", "JPM", "BRK.B"]
private let workflowDate = Date(timeIntervalSince1970: 1_800_000_000)

private struct WorkflowOracle: Decodable {
    struct Fact: Decodable { let fieldID, end, periodType, sourceHash: String; let fiscalYear: Int }
    struct Window: Decodable { let start, end: String }
    let ticker, cik: String
    let financialCompany: Bool
    let facts: [Fact]
    let quarters: [Window]
    let knownMissing: [String]
    let expectedMetrics: [String: String]
}
private struct WorkflowSaved {
    let rowID: String
    let documentID: UUID
    let bytes: Data
}
private actor WorkflowReplayCount {
    var calls = 0
    func run(_ document: OfflineIssuerResearchDocument) async throws -> OfflineIssuerResearchRecomputation {
        calls += 1
        return try await document.recompute()
    }
}

// This is a production local-excerpt workflow check against real SQLite, not SEC API
// acquisition evidence. Original issuer statements and prior independent oracles are reused;
// there is no fabricated quote, changed model threshold or implied G1/data admission.
@Suite(.serialized) @MainActor struct TenIssuerResearchWorkflowTests {
    @Test(arguments: workflowIssuers)
    func reviewedExcerptTraversesRealWorkspaceStoreAndExplicitReplay(ticker: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ten-issuer-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("offline-issuer.sqlite").path
        let oracle = try JSONDecoder().decode(WorkflowOracle.self, from: offlineIssuerExcerpt(ticker))
        let saved = try await generateVerifyAndSave(ticker: ticker, path: path, oracle: oracle)

        // New store and page model: persisted bytes are the only carried result, not the
        // original calculation object or a model whose verification flag survived navigation.
        let replay = WorkflowReplayCount()
        let store = try OfflineIssuerResearchStore(path: path)
        let reopened = try OfflineIssuerWorkspaceModel(storage: store, catalog: .bundled(), now: { workflowDate },
            replay: { try await replay.run($0) })
        await reopened.load()
        #expect(reopened.saved.count == 1 && reopened.document == nil)
        #expect(await replay.calls == 0)
        await reopened.open(saved.rowID)
        let persisted = try #require(reopened.document)
        #expect(persisted.id == saved.documentID && reopened.isSaved && !reopened.hasError)
        #expect(reopened.selectedTicker == ticker && reopened.selectionTicker == ticker)
        #expect(reopened.recomputationState == .notVerified && !reopened.canDisplayReports)
        #expect(await replay.calls == 0)
        #expect(try ResearchDocument.encoded(persisted) == saved.bytes)
        await reopened.recompute()
        #expect(reopened.recomputationState == .matched && reopened.canDisplayReports && !reopened.hasError)
        #expect(await replay.calls == 1)
        #expect(try ResearchDocument.encoded(reopened.document) == ResearchDocument.encoded(Optional(persisted)))
        try verifyResearchBoundaries(persisted, oracle: oracle)
        reopened.disappear()
        #expect(reopened.document == nil && !reopened.canDisplayReports)
    }

    private func generateVerifyAndSave(ticker: String, path: String, oracle: WorkflowOracle) async throws -> WorkflowSaved {
        let store = try OfflineIssuerResearchStore(path: path)
        // The runtime catalogue intentionally has no expected-answer fields. The separate
        // test oracle is never passed to the production generator.
        let catalog = try OfflineIssuerCatalog.bundled()
        let page = OfflineIssuerWorkspaceModel(storage: store, catalog: catalog, now: { workflowDate })
        await page.select(ticker)
        let document = try #require(page.document)
        #expect(page.context?.ticker == ticker && page.selectedTicker == ticker && !page.hasError)
        #expect(page.recomputationState == .notVerified && !page.canDisplayReports && page.canSave)
        let original = try ResearchDocument.encoded(document)
        await page.recompute()
        #expect(page.recomputationState == .matched && page.canDisplayReports && !page.hasError)
        try verifyResearchBoundaries(document, oracle: oracle)
        await page.save()
        #expect(page.isSaved && !page.hasError && page.savedReadError == nil)
        let id = try #require(page.savedID)
        #expect(page.saved.count == 1 && page.saved.first?.document.id == document.id)
        page.disappear()
        return WorkflowSaved(rowID: id, documentID: document.id, bytes: original)
    }

    private func verifyResearchBoundaries(_ document: OfflineIssuerResearchDocument, oracle: WorkflowOracle) throws {
        #expect(document.ticker == oracle.ticker && document.cik == oracle.cik)
        let context = try document.context(), input = document.inputSnapshot.financials.input
        #expect(context.knownMissing == oracle.knownMissing)
        #expect(input.financialCompany == oracle.financialCompany)
        #expect(input.quarters.map { $0.start.iso8601 + "/" + $0.end.iso8601 }
            == oracle.quarters.map { $0.start + "/" + $0.end })
        let hashes = Set(oracle.facts.map(\.sourceHash))
        #expect(Set(context.facts.map(\.sourceHash)) == hashes)
        #expect(Set(document.baseReport.sourceVersions) == hashes)
        #expect(input.normalization.selectedSourceFacts.isEmpty && input.normalization.unmappedSourceFacts.isEmpty)
        #expect(input.normalization.values.allSatisfy { $0.accessionNumbers.isEmpty })
        #expect(!document.providerAdmitted && !document.historicalPITQualified && !document.capitalInputsAllowed)
        #expect(document.researchOnly && !document.synthetic)
        #expect(document.retention.mayStore && !document.retention.mayBackup)
        #expect(document.cacheState == "requires-explicit-recompute")
        for key in ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceSales", "priceFCF", "fcfYield"] {
            let metric = try #require(document.baseReport.metrics[key])
            #expect(metric.value == nil && metric.unavailable != nil, "\(oracle.ticker) missing market data: \(key)")
        }
        if oracle.financialCompany {
            #expect(document.baseReport.metrics["roic"]?.unavailable == .notApplicable)
            #expect(document.baseReport.metrics["netDebtEBITDA"]?.unavailable == .notApplicable)
        }
        // Representative independent accounting answers survive the integrated page/storage
        // journey. Detailed formula vectors remain in the existing golden-model suites.
        let end = try #require(oracle.quarters.last).end
        let year = try #require(oracle.facts.first { $0.end == end && $0.periodType == "annual" }).fiscalYear
        for key in ["revenue", "netIncome", "fcf"] {
            if let expected = oracle.expectedMetrics["\(year)/" + key] {
                #expect(try document.baseReport.metrics[key]?.value == Money(expected), "\(oracle.ticker) \(key)")
            }
        }
    }
}
