import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import DataProviders
import SECProvider
import FundamentalsEngine
@testable import Persistence

private let secResearchNow = Date(timeIntervalSince1970: 1_757_592_000)
private let secResearchCIK = "0000320193"

private actor ResearchSECGate: SECRequestGate {
    func wait() async throws { try Task.checkCancellation() }
}

private actor ResearchSECTransport: HTTPTransport {
    private var responses: [HTTPPayload]
    private let pauseAt: Int?
    private var requests = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(_ responses: [HTTPPayload], pauseAt: Int? = nil) { self.responses = responses; self.pauseAt = pauseAt }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        requests += 1
        if requests == pauseAt {
            started = true; startWaiters.forEach { $0.resume() }; startWaiters = []
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        guard !responses.isEmpty else { throw ProviderFailure.offline }
        return responses.removeFirst()
    }
    func waitUntilPaused() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func count() -> Int { requests }
}

private func secResponse(_ text: String, status: Int = 200, media: String = "application/json") -> HTTPPayload {
    HTTPPayload(statusCode: status, mediaType: media, body: Data(text.utf8))
}

private let secIdentityJSON = #"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Synthetic Apple","AAPL","Nasdaq"]]}"#
private let secFactsJSON = #"{"cik":320193,"entityName":"Synthetic Apple","facts":{"us-gaap":{"RevenueFromContractWithCustomerExcludingAssessedTax":{"label":"Revenue","description":"Synthetic","units":{"USD":[{"start":"2024-01-01","end":"2024-12-31","val":100,"accn":"0000320193-25-000001","fy":2024,"fp":"FY","form":"10-K","filed":"2025-02-01"}]}}}}}"#
private let secEmptySubmissions = #"{"cik":"0000320193","filings":{"recent":{"accessionNumber":[],"filingDate":[],"reportDate":[],"acceptanceDateTime":[],"form":[],"primaryDocument":[]},"files":[]}}"#
private let secRecentSubmissions = #"{"cik":"0000320193","filings":{"recent":{"accessionNumber":["0000320193-25-000001"],"filingDate":["2025-02-01"],"reportDate":["2024-12-31"],"acceptanceDateTime":["2025-02-01T21:00:00Z"],"form":["10-K"],"primaryDocument":["annual.htm"]},"files":[{"name":"CIK0000320193-submissions-001.json"}]}}"#
private let secOlderSubmissions = #"{"accessionNumber":["0000320193-24-000002"],"filingDate":["2024-11-01"],"reportDate":["2024-09-30"],"acceptanceDateTime":["2024-11-01T21:00:00Z"],"form":["10-Q"],"primaryDocument":["quarter.htm"]}"#

private func minimalSECResponses() -> [HTTPPayload] {
    [secResponse(secIdentityJSON), secResponse(secEmptySubmissions), secResponse(secFactsJSON)]
}

private func fullSECResponses() -> [HTTPPayload] {
    [secResponse(secIdentityJSON), secResponse(secRecentSubmissions), secResponse(secOlderSubmissions), secResponse(secFactsJSON),
     secResponse(#"{"directory":{"item":[{"name":"annual.htm","type":"text/html","size":23}]}}"#),
     secResponse("<html>annual synthetic</html>", media: "text/html"),
     secResponse(#"{"directory":{"item":[{"name":"quarter.htm","type":"text/html","size":23}]}}"#),
     secResponse("<html>quarter synthetic</html>", media: "text/html")]
}

private func incompatibleFiscalBridgeFacts(overflow: Bool = false) throws -> HTTPPayload {
    func observation(start: String, end: String, period: String, value: String) -> [String: Any] {
        ["start": start, "end": end, "val": value, "accn": "0000320193-25-000001", "fy": 2024,
         "fp": period, "form": period == "FY" ? "10-K" : "10-Q", "filed": "2025-02-01"]
    }
    let maximum = String(repeating: "9", count: 38)
    let revenue = [
        observation(start: overflow ? "2024-01-01" : "2023-01-01",
                    end: overflow ? "2024-09-30" : "2023-09-30", period: "Q3", value: overflow ? "-" + maximum : "60"),
        observation(start: "2024-01-01", end: "2024-12-31", period: "FY", value: overflow ? maximum : "100")
    ]
    let netIncome = [observation(start: "2024-01-01", end: "2024-09-30", period: "Q3", value: "30"),
                     observation(start: "2024-01-01", end: "2024-12-31", period: "FY", value: "50")]
    let envelope: [String: Any] = ["cik": 320193, "entityName": "Synthetic Apple", "facts": ["us-gaap": [
        "RevenueFromContractWithCustomerExcludingAssessedTax": ["label": "Revenue", "description": "Synthetic", "units": ["USD": revenue]],
        "NetIncomeLoss": ["label": "Net income", "description": "Synthetic", "units": ["USD": netIncome]]
    ]]]
    return HTTPPayload(statusCode: 200, mediaType: "application/json", body: try JSONSerialization.data(withJSONObject: envelope))
}

private func classificationFixture(_ original: SECCompanyFactRecord, start: MarketDate, end: MarketDate,
                                   fiscalPeriod: String, form: String) throws -> SECCompanyFactRecord {
    // Decode the boundary fixture directly so the classifier's invalid-date/reversed-range
    // fallback can also be tested. This is not an accepted provider record or persisted data.
    var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(original)) as? [String: Any])
    object["startDate"] = ["year": start.year, "month": start.month, "day": start.day]
    object["endDate"] = ["year": end.year, "month": end.month, "day": end.day]
    object["fiscalPeriod"] = fiscalPeriod; object["form"] = form
    return try JSONDecoder().decode(SECCompanyFactRecord.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

private func researchService(database: DatabaseStore, responses: [HTTPPayload], pauseAt: Int? = nil) throws
    -> (SECResearchService<SECEdgarProvider<ResearchSECTransport, ResearchSECGate>>, SECResearchStore, ResearchSECTransport) {
    let transport = ResearchSECTransport(responses, pauseAt: pauseAt)
    let provider = try SECEdgarProvider(userAgent: "MarketDecisionTests/1.0 synthetic@example.invalid",
        transport: transport, gate: ResearchSECGate(), evidenceRef: "synthetic-sec-evidence", licenseRef: "synthetic-sec-rights", now: { secResearchNow })
    let entitlement = EntitlementSnapshot(providerID: provider.id, feedID: "public-edgar", version: "synthetic.v1",
        evidenceRef: "synthetic-sec-evidence", licenseRef: "synthetic-sec-rights",
        capabilities: provider.capabilitySnapshot.capabilities, usages: [.replay],
        validFrom: secResearchNow.addingTimeInterval(-100), validThrough: secResearchNow.addingTimeInterval(100))
    let store = try SECResearchStore(database: database)
    return (SECResearchService(client: .init(provider: provider, entitlement: entitlement), store: store, now: { secResearchNow }), store, transport)
}

/// Shared synthetic builder for the model suite: no network, no expected-answer resources.
func secResearchFixtureDocument() async throws -> SECResearchDocument {
    let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
    let (service, _, _) = try researchService(database: database, responses: minimalSECResponses())
    return try await service.importCompany(ticker: "AAPL", progress: { _ in })
}

@Suite struct SECResearchServiceTests {
    @Test func periodClassificationPreservesInclusiveThresholdsLeapDaysAndYearCrossings() async throws {
        let document = try await secResearchFixtureDocument()
        let original = try #require(document.facts.first)
        let dictionary = try FinancialFieldDictionary.fundamentalsCompletionV1()
        // Explicit endpoints/expected classes, independently counted with calendar dates.
        let cases: [(String, String, String, String, FinancialPeriodType)] = [
            ("2024-01-01", "2024-03-09", "Q1", "10-Q", .unclassified), // 69 days
            ("2024-01-01", "2024-03-10", "Q1", "10-Q", .quarter),      // 70
            ("2024-01-01", "2024-04-29", "Q1", "10-Q", .quarter),      // 120
            ("2024-01-01", "2024-04-30", "Q1", "10-Q", .unclassified), // 121
            ("2024-01-01", "2024-05-18", "Q2", "10-Q", .unclassified), // 139
            ("2024-01-01", "2024-05-19", "Q2", "10-Q", .yearToDate),   // 140
            ("2024-01-01", "2024-10-26", "Q3", "10-Q", .yearToDate),   // 300
            ("2024-01-01", "2024-10-27", "Q3", "10-Q", .unclassified), // 301
            ("2024-01-01", "2024-10-25", "FY", "10-K", .unclassified), // 299
            ("2024-01-01", "2024-10-26", "FY", "10-K", .annual),       // 300
            ("2024-01-01", "2025-02-03", "FY", "10-K", .annual),       // 400
            ("2024-01-01", "2025-02-04", "FY", "10-K", .unclassified), // 401
            ("2023-11-23", "2024-01-31", "Q1", "10-Q", .quarter),      // 70, year crossing
            ("2023-12-01", "2024-02-29", "Q1", "10-Q", .quarter),      // 91, leap day
            ("2024-02-29", "2024-05-07", "Q2", "10-Q", .unclassified), // 69, leap-day start
            ("2024-02-29", "2024-05-08", "Q2", "10-Q", .quarter)       // 70
        ]
        for (start, end, fp, form, expected) in cases {
            let fact = try classificationFixture(original, start: MarketDate(iso8601: start),
                end: MarketDate(iso8601: end), fiscalPeriod: fp, form: form)
            let result = try FinancialNormalizer.normalize([fact], dictionary: dictionary, asOf: document.cutoff)
            #expect(result.values.count == 1)
            #expect(result.values.first?.periodType == expected)
        }
    }

    @Test func invalidReversedAndOverlongPeriodBoundariesRemainUnclassified() async throws {
        let document = try await secResearchFixtureDocument()
        let original = try #require(document.facts.first)
        let dictionary = try FinancialFieldDictionary.fundamentalsCompletionV1()
        let cases: [(MarketDate, MarketDate)] = [
            (.init(year: 2024, month: 2, day: 30), .init(year: 2024, month: 5, day: 9)),
            (.init(year: 2024, month: 1, day: 1), .init(year: 2024, month: 2, day: 30)),
            (.init(year: 2024, month: 4, day: 1), .init(year: 2024, month: 3, day: 31)),
            (.init(year: 1900, month: 1, day: 1), .init(year: 2173, month: 10, day: 15)), // 100,000 inclusive
            (.init(year: 1900, month: 1, day: 1), .init(year: 2173, month: 10, day: 16))  // previous limit exceeded
        ]
        for (start, end) in cases {
            let fact = try classificationFixture(original, start: start, end: end, fiscalPeriod: "Q1", form: "10-Q")
            let result = try FinancialNormalizer.normalize([fact], dictionary: dictionary, asOf: document.cutoff)
            #expect(result.values.first?.periodType == .unclassified)
        }
    }

    @Test func incompatibleFiscalBridgeIsExplicitResearchGapWhileStrictPolicyStillThrows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .secResearch)
        let (service, _, _) = try researchService(database: database, responses: [secResponse(secIdentityJSON),
            secResponse(secEmptySubmissions), incompatibleFiscalBridgeFacts()])
        let document = try await service.importCompany(ticker: "AAPL", progress: { _ in })
        let dictionary = try FinancialFieldDictionary.fundamentalsCompletionV1()
        #expect(throws: FinancialNormalizationError.incompatiblePeriod) {
            try FinancialNormalizer.normalizeComplete(document.facts, dictionary: dictionary, asOf: document.cutoff)
        }
        let reported = try FinancialNormalizer.normalize(document.facts, dictionary: dictionary, asOf: document.cutoff)
        #expect(throws: FinancialNormalizationError.incompatiblePeriod) {
            try FinancialNormalizer.discreteQuarters(from: reported.values)
        }
        #expect(document.normalizationPolicyVersion == "sec-normalization.research.v1")
        #expect(document.facts.count == 4)
        #expect(document.normalization.values.filter { $0.derivation == .reported } == reported.values)
        #expect(!document.normalization.values.contains { $0.fieldID == "income.revenue" && $0.derivation != .reported })
        let goodBridge = try #require(document.normalization.values.first { $0.fieldID == "income.net-income" && $0.derivation == .annualLessYTD })
        #expect(goodBridge.value == (try Money("20")))
        let issue = try #require(document.normalization.issues.first { $0.code == "incompatible-quarter-bridge" })
        #expect(issue.severity == .high)
        #expect(Set(issue.factIDs) == Set(document.facts.filter { $0.concept == "RevenueFromContractWithCustomerExcludingAssessedTax" }.map(\.factID)))
        let reopened = try SECResearchStore(path: path.path)
        let saved = try await reopened.open(id: document.id)
        #expect(try saved.recompute() == document.normalization)
        #expect(saved.normalizationPolicyVersion == document.normalizationPolicyVersion)
    }

    @Test func researchBridgePolicyDoesNotSwallowNumericPrecisionFailure() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (service, store, _) = try researchService(database: database, responses: [secResponse(secIdentityJSON),
            secResponse(secEmptySubmissions), incompatibleFiscalBridgeFacts(overflow: true)])
        await #expect(throws: MoneyError.precisionExceeded) {
            try await service.importCompany(ticker: "AAPL", progress: { _ in })
        }
        #expect(try await store.savedResearch().isEmpty)
    }

    @Test func repeatedIdenticalAcquisitionKeepsNoOpCacheContractAndCreatesReplayableSnapshot() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (first, store, _) = try researchService(database: database, responses: fullSECResponses())
        let original = try await first.importCompany(ticker: "AAPL", progress: { _ in })
        let initialCount = try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") }
        let (second, _, _) = try researchService(database: database, responses: fullSECResponses())
        let repeated = try await second.importCompany(ticker: "AAPL", progress: { _ in })
        #expect(repeated.id != original.id)
        #expect(repeated.sources.map(\.reference) != original.sources.map(\.reference))
        #expect(repeated.sources.map(\.bytes) == original.sources.map(\.bytes))
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == initialCount)
        #expect(try await store.savedResearch().count == 2)
        #expect(try repeated.recompute() == repeated.normalization)
    }

    @Test func preopenedSecondStoreCanRepeatImportAfterFirstStoreAdvancesRevision() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let firstDatabase = try DatabaseStore(path: path.path, purpose: .secResearch)
        let secondDatabase = try DatabaseStore(path: path.path, purpose: .secResearch)
        // Both BusinessDataStore actors retain the initial revision before either import.
        let (first, firstStore, _) = try researchService(database: firstDatabase, responses: fullSECResponses())
        let (second, secondStore, _) = try researchService(database: secondDatabase, responses: fullSECResponses())
        let original = try await first.importCompany(ticker: "AAPL", progress: { _ in })
        let firstCommittedRevision = try await firstStore.writeRevision()
        let sourceCount = try firstDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") }
        // B must carry its verified operation baseline through each no-op page receipt;
        // replacing that baseline with B's stale actor cache must not abort the next page.
        let repeated = try await second.importCompany(ticker: "AAPL", progress: { _ in })
        #expect(repeated.id != original.id)
        #expect(try await secondStore.writeRevision() != firstCommittedRevision)
        #expect(try await firstStore.savedResearch().count == 2)
        #expect(try await secondStore.savedResearch().count == 2)
        #expect(try secondDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == sourceCount)
        #expect(try repeated.recompute() == repeated.normalization)
    }

    @Test func importsEveryAdvertisedPageAndPrimaryDocumentsThenReopensAndReplays() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .secResearch)
        let (service, store, transport) = try researchService(database: database, responses: fullSECResponses())
        let document = try await service.importCompany(ticker: "AAPL", progress: { _ in })
        #expect(await transport.count() == 8)
        #expect(document.submissions.count == 2)
        #expect(document.sources.count == 8)
        #expect(document.indexes.count == 2)
        #expect(document.filingDocuments.count == 2)
        #expect(document.facts.count == 1)
        #expect(!document.mayRunValuation)
        #expect(try document.recompute() == document.normalization)
        #expect(try await store.savedResearch().map(\.id) == [document.id])
        let reopened = try SECResearchStore(path: path.path)
        let restored = try await reopened.open(id: document.id)
        #expect(restored.sources == document.sources)
        #expect(try restored.recompute() == document.normalization)
        #expect(throws: MigrationError.incompatiblePurpose) { try DatabaseStore(path: path.path) }
        #expect(throws: MigrationError.incompatiblePurpose) { try OfflineIssuerResearchStore(path: path.path) }
    }

    @Test func historicalUnselectedMissingPrimaryDocumentRemainsInInventory() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let olderAnnual = secOlderSubmissions
            .replacingOccurrences(of: #""form":["10-Q"]"#, with: #""form":["10-K"]"#)
            .replacingOccurrences(of: #""primaryDocument":["quarter.htm"]"#, with: #""primaryDocument":[""]"#)
        let responses = [secResponse(secIdentityJSON), secResponse(secRecentSubmissions),
            secResponse(olderAnnual), secResponse(secFactsJSON)] + Array(fullSECResponses().dropFirst(4).prefix(2))
        let (service, store, transport) = try researchService(database: database, responses: responses)
        let document = try await service.importCompany(ticker: "AAPL", progress: { _ in })
        #expect(document.submissions.map(\.accessionNumber) == ["0000320193-25-000001", "0000320193-24-000002"])
        #expect(document.submissions.last?.primaryDocument == "")
        #expect(document.filingDocuments.map(\.fileName) == ["annual.htm"])
        #expect(await transport.count() == 6)
        #expect(try await store.savedResearch().map(\.id) == [document.id])
        #expect(try document.recompute() == document.normalization)
    }

    @Test(arguments: ["10-K", "10-Q"])
    func selectedReportWithoutPrimaryDocumentFailsBeforeIndexDispatch(_ form: String) async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let selected = secRecentSubmissions
            .replacingOccurrences(of: #""form":["10-K"]"#, with: "\"form\":[\"" + form + "\"]")
            .replacingOccurrences(of: #""primaryDocument":["annual.htm"]"#, with: #""primaryDocument":[""]"#)
            .replacingOccurrences(of: #""files":[{"name":"CIK0000320193-submissions-001.json"}]"#, with: #""files":[]"#)
        let (service, store, transport) = try researchService(database: database,
            responses: [secResponse(secIdentityJSON), secResponse(selected), secResponse(secFactsJSON)])
        await #expect(throws: SECResearchError.missingPrimaryDocument) {
            try await service.importCompany(ticker: "AAPL", progress: { _ in })
        }
        #expect(await transport.count() == 3)
        #expect(try await store.savedResearch().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_sec_filing_indexes") } == 0)
    }

    @Test func noReportsOrFactsRemainExplicitGapsWithoutInventedValues() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let emptyFacts = #"{"cik":320193,"entityName":"Synthetic Apple","facts":{}}"#
        let (service, _, transport) = try researchService(database: database,
            responses: [secResponse(secIdentityJSON), secResponse(secEmptySubmissions), secResponse(emptyFacts)])
        let document = try await service.importCompany(ticker: "AAPL", progress: { _ in })
        #expect(document.normalization.values.isEmpty)
        #expect(document.gaps.contains(.missingAnnualFiling))
        #expect(document.gaps.contains(.missingQuarterlyFiling))
        #expect(document.gaps.contains(.missingFacts))
        #expect(await transport.count() == 3)
    }

    @Test func reportedQuarterEvidenceProducesExactTTMWithoutPriceOrClassificationGuessing() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let quarters = [("2024-01-01", "2024-03-31", "Q1", 10), ("2024-04-01", "2024-06-30", "Q2", 20),
                        ("2024-07-01", "2024-09-30", "Q3", 30), ("2024-10-01", "2024-12-31", "Q4", 40)]
        let values: [[String: Any]] = quarters.map { start, end, period, value in
            ["start": start, "end": end, "val": value, "accn": "0000320193-25-000001", "fy": 2024,
             "fp": period, "form": "10-Q", "filed": "2025-02-01"]
        }
        let envelope: [String: Any] = ["cik": 320193, "entityName": "Synthetic Apple", "facts": ["us-gaap": [
            "RevenueFromContractWithCustomerExcludingAssessedTax": ["label": "Revenue", "description": "Synthetic", "units": ["USD": values]]]]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let (service, _, _) = try researchService(database: database, responses: [secResponse(secIdentityJSON),
            secResponse(secEmptySubmissions), HTTPPayload(statusCode: 200, mediaType: "application/json", body: data)])
        let document = try await service.importCompany(ticker: "AAPL", progress: { _ in })
        let ttm = try #require(document.normalization.values.first(where: { $0.periodType == .trailingTwelveMonths }))
        #expect(ttm.value == (try Money("100")))
        #expect(ttm.sourceFactIDs.count == 4)
        #expect(document.gaps.contains(.noQualifiedPricesOrCapital))
        #expect(document.gaps.contains(.financialClassificationNotSupplied))
        #expect(try document.recompute() == document.normalization)
    }

    @Test func crossIssuerContinuationIsRejectedBeforeDispatchOrPagePersistence() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let bad = secRecentSubmissions.replacingOccurrences(of: "CIK0000320193-submissions-001.json", with: "CIK0000789019-submissions-001.json")
        let (service, store, transport) = try researchService(database: database,
            responses: [secResponse(secIdentityJSON), secResponse(bad)])
        await #expect(throws: (any Error).self) {
            try await service.importCompany(ticker: "AAPL", progress: { _ in })
        }
        #expect(await transport.count() == 2)
        #expect(try await store.savedResearch().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 1)
    }

    @Test func repeatedAdvertisedContinuationCannotLoopOrClaimComplete() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        // The latest envelope itself contains duplicate advertised tokens. The acceptance
        // contract rejects it before the service has an opportunity to dispatch either.
        let bad = secRecentSubmissions.replacingOccurrences(of: #"[{"name":"CIK0000320193-submissions-001.json"}]"#,
            with: #"[{"name":"CIK0000320193-submissions-001.json"},{"name":"CIK0000320193-submissions-001.json"}]"#)
        let (service, store, transport) = try researchService(database: database, responses: [secResponse(secIdentityJSON), secResponse(bad)])
        await #expect(throws: (any Error).self) { try await service.importCompany(ticker: "AAPL", progress: { _ in }) }
        #expect(await transport.count() == 2)
        #expect(try await store.savedResearch().isEmpty)
    }

    @Test func throttledLaterPagePreservesAcceptedPagesButNeverPublishesSuccess() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (service, store, transport) = try researchService(database: database,
            responses: [secResponse(secIdentityJSON), secResponse(secRecentSubmissions), secResponse("throttled", status: 429)])
        await #expect(throws: ProviderFailure.rateLimited) { try await service.importCompany(ticker: "AAPL", progress: { _ in }) }
        #expect(await transport.count() == 3)
        #expect(try await store.savedResearch().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 2)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_sec_submissions") } == 1)
        let (retry, _, _) = try researchService(database: database, responses: fullSECResponses())
        let document = try await retry.importCompany(ticker: "AAPL", progress: { _ in })
        #expect(try await store.savedResearch().map(\.id) == [document.id])
    }

    @Test func cancellationAfterDispatchDropsLateResponseAndLeavesNoResearchSnapshot() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (service, store, transport) = try researchService(database: database, responses: minimalSECResponses(), pauseAt: 2)
        let task = Task { try await service.importCompany(ticker: "AAPL", progress: { _ in }) }
        await transport.waitUntilPaused()
        task.cancel(); await transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.savedResearch().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 1)
        #expect(await transport.count() == 2)
    }

    @Test func oldImportCannotAcquireNewBaselineAcrossConcurrentMutation() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (service, store, transport) = try researchService(database: database, responses: minimalSECResponses(), pauseAt: 2)
        let task = Task { try await service.importCompany(ticker: "AAPL", progress: { _ in }) }
        await transport.waitUntilPaused()
        let changedRevision = UUID()
        try database.transaction { db in
            // Represents a committed destructive operation while the second request is away.
            try db.execute(sql: "DELETE FROM p1_sec_identity_listings")
            try db.execute(sql: "DELETE FROM p1_sec_identities")
            try db.execute(sql: "DELETE FROM p1_source_documents")
            try db.execute(sql: "UPDATE p1_store_metadata SET revision = ?", arguments: [changedRevision.uuidString])
        }
        await transport.release()
        await #expect(throws: SnapshotError.stalePlan) { try await task.value }
        #expect(try await store.writeRevision() == changedRevision)
        #expect(try await store.savedResearch().isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 0)
    }

    @Test func sourceCorruptionBeforeFreezeRejectsWholeResearchResult() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (service, store, transport) = try researchService(database: database, responses: minimalSECResponses(), pauseAt: 3)
        let task = Task { try await service.importCompany(ticker: "AAPL", progress: { _ in }) }
        await transport.waitUntilPaused()
        try database.transaction { db in
            try db.execute(sql: "UPDATE p1_source_documents SET payload = ? WHERE endpoint_descriptor = ?",
                arguments: [Data("broken".utf8), EndpointDescriptor.companyIdentity.rawValue])
        }
        await transport.release()
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await task.value }
        #expect(try await store.savedResearch().isEmpty)
    }

    @Test func repeatedIngestRejectsValidButWrongOriginalSourceReference() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (first, store, _) = try researchService(database: database, responses: minimalSECResponses())
        _ = try await first.importCompany(ticker: "AAPL", progress: { _ in })
        try database.transaction { db in
            let storedSource = try String.fetchOne(db, sql: "SELECT source_reference FROM p1_sec_identities LIMIT 1")
            let identitySource = try #require(storedSource)
            try db.execute(sql: "UPDATE p1_sec_facts SET source_reference = ?", arguments: [identitySource])
        }
        let (second, _, _) = try researchService(database: database, responses: minimalSECResponses())
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await second.importCompany(ticker: "AAPL", progress: { _ in })
        }
        #expect(try await store.savedResearch().count == 1)
    }

    @Test func recordHiddenFromAsOfInventoryCannotBypassNoOpSourceValidation() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
        let (first, store, _) = try researchService(database: database, responses: minimalSECResponses())
        _ = try await first.importCompany(ticker: "AAPL", progress: { _ in })
        try database.transaction { db in
            try db.execute(sql: "UPDATE p1_sec_facts SET available_at_ms = ?",
                arguments: [try MillisecondInstant(rounding: secResearchNow.addingTimeInterval(86_400)).milliseconds])
        }
        let (second, _, _) = try researchService(database: database, responses: minimalSECResponses())
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await second.importCompany(ticker: "AAPL", progress: { _ in })
        }
        #expect(try await store.savedResearch().count == 1)
    }

    @Test func explicitReplayUsesFrozenFactsRatherThanCachedNormalization() async throws {
        let original = try await secResearchFixtureDocument()
        let bytes = try ResearchDocument.encoded(original)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var normalization = try #require(object["normalization"] as? [String: Any])
        normalization["values"] = []
        object["normalization"] = normalization
        let changed = try JSONDecoder().decode(SECResearchDocument.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try changed.validate()
        #expect(changed.normalization.values.isEmpty)
        #expect(try changed.recompute() == original.normalization)
        #expect(try changed.recompute() != changed.normalization)
    }

    @Test func frozenSourceHashDamageFailsReopenValidation() async throws {
        let original = try await secResearchFixtureDocument()
        var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(original)) as? [String: Any])
        var sources = try #require(object["sources"] as? [[String: Any]])
        sources[0]["bytes"] = Data("changed".utf8).base64EncodedString()
        object["sources"] = sources
        let corrupted = try JSONDecoder().decode(SECResearchDocument.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        #expect(throws: SECResearchError.invalidDocument) { try corrupted.validate() }
        #expect(throws: SECResearchError.invalidDocument) { try corrupted.recompute() }
    }

    @Test func manyCachedIssuesKeepReferenceValidationAndRejectOneUnknownFact() async throws {
        let original = try await secResearchFixtureDocument()
        let fact = try #require(original.facts.first)
        var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(original)) as? [String: Any])
        var normalization = try #require(object["normalization"] as? [String: Any])
        var issues: [[String: Any]] = (0..<64).map { index in
            ["code": "synthetic-issue-" + String(index), "severity": "high",
             "factIDs": index.isMultiple(of: 2) ? [fact.factID] : [fact.recordID],
             "message": "Synthetic reference-validation fixture"]
        }
        normalization["issues"] = issues; object["normalization"] = normalization
        let valid = try JSONDecoder().decode(SECResearchDocument.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try valid.validate()
        #expect(valid.normalization.issues.count == 64)
        issues[63]["factIDs"] = ["unknown-source-reference"]
        normalization["issues"] = issues; object["normalization"] = normalization
        let invalid = try JSONDecoder().decode(SECResearchDocument.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        #expect(throws: SECResearchError.invalidDocument) { try invalid.validate() }
        #expect(throws: SECResearchError.invalidDocument) { try invalid.recompute() }
    }
}
