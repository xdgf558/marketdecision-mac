import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import DataProviders
import SECProvider
import FundamentalsEngine
@testable import Persistence

private actor SECFixtureGate: SECRequestGate {
    private(set) var waits = 0
    func wait() async throws { waits += 1; try Task.checkCancellation() }
    func count() -> Int { waits }
}

private actor SECFixtureTransport: HTTPTransport {
    private var payloads: [HTTPPayload]
    private var requests: [URLRequest] = []
    init(_ payloads: [HTTPPayload]) { self.payloads = payloads }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        requests.append(request)
        guard !payloads.isEmpty else { throw ProviderFailure.offline }
        return payloads.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}

private actor PausedSECTransport: HTTPTransport {
    private let payload: HTTPPayload
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<HTTPPayload, Never>?
    init(_ payload: HTTPPayload) { self.payload = payload }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        started = true; startedWaiter?.resume(); startedWaiter = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { startedWaiter = $0 } }
    }
    func release() { pending?.resume(returning: payload); pending = nil }
}

@Suite struct PhaseOneSECProviderTests {
    let now = Date(timeIntervalSince1970: 1_757_592_000) // 2025-09-11T12:00:00Z

    private func provider(_ bodies: [Data], status: Int = 200, mediaType: String = "application/json") throws
        -> (SECEdgarProvider<SECFixtureTransport, SECFixtureGate>, SECFixtureTransport, SECFixtureGate) {
        let transport = SECFixtureTransport(bodies.map { HTTPPayload(statusCode: status, mediaType: mediaType, body: $0) })
        let gate = SECFixtureGate()
        return (try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com", transport: transport,
                                    gate: gate, evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1",
                                    now: { now }), transport, gate)
    }

    func entitlement(_ capabilities: Set<ProviderCapability>) -> EntitlementSnapshot {
        EntitlementSnapshot(providerID: "sec-edgar", feedID: "public-edgar", version: "sec-rights.v1",
            evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", capabilities: capabilities,
            usages: [.pitResearch], validFrom: now.addingTimeInterval(-100), validThrough: now.addingTimeInterval(100))
    }

    func request(_ capability: ProviderCapability, resource: String, page: String? = nil,
                 range: DataWindow? = nil) -> ProviderRequest {
        ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: resource,
            capability: capability, mode: .latest, range: range, usage: .pitResearch,
            configurationVersion: "sec-edgar.v1", entitlementVersion: "sec-rights.v1",
            requestedAt: now, pageToken: page)
    }

    @Test func identityPadsCIKAndSendsDeclaredUserAgentThroughAcceptedPipeline() async throws {
        let bytes = Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Apple Inc.","AAPL","Nasdaq"],[789019,"Microsoft Corp.","MSFT","Nasdaq"]]}"#.utf8)
        let (provider, transport, gate) = try provider([bytes])
        let client = FundamentalsDataClient(provider: provider, entitlement: entitlement([.companyIdentity]))
        let accepted = try await client.companyIdentity(request(.companyIdentity, resource: "AAPL"))
        #expect(accepted.exchange.result.items.count == 1)
        #expect(accepted.exchange.result.items[0].cik == "0000320193")
        #expect(accepted.rawPayload.bytes == bytes)
        #expect(await gate.count() == 1)
        let sent = try #require(await transport.captured().first)
        #expect(sent.url?.absoluteString == "https://www.sec.gov/files/company_tickers_exchange.json")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "MarketDecision/1.0 research@example.com")
    }

    @Test func invalidUserAgentAndRateAboveOfficialCeilingFailClosed() throws {
        let transport = SECFixtureTransport([]), gate = SECFixtureGate()
        #expect(throws: SECAdapterError.invalidConfiguration) {
            try SECEdgarProvider(userAgent: "anonymous", transport: transport, gate: gate,
                                evidenceRef: "e", licenseRef: "l")
        }
        #expect(throws: SECAdapterError.invalidConfiguration) { try SECRateLimiter(requestsPerSecond: 11) }
        #expect(throws: SECAdapterError.invalidConfiguration) { try SECRateLimiter(requestsPerSecond: 0) }
    }

    @Test func submissionsKeepAcceptanceEvidenceAmendmentsAndExplicitPageToken() async throws {
        let current = Data(#"{"cik":"0000320193","filings":{"recent":{"accessionNumber":["0000320193-25-000079"],"filingDate":["2025-08-01"],"reportDate":["2025-06-28"],"acceptanceDateTime":["2025-08-01T20:01:02.000Z"],"form":["10-Q/A"],"primaryDocument":["aapl-20250628.htm"]},"files":[{"name":"CIK0000320193-submissions-001.json"}]}}"#.utf8)
        let older = Data(#"{"accessionNumber":["0000320193-24-000069"],"filingDate":["2024-08-02"],"reportDate":["2024-06-29"],"acceptanceDateTime":[""],"form":["10-Q"],"primaryDocument":["aapl-20240629.htm"]}"#.utf8)
        let (provider, transport, _) = try provider([current, older])
        let client = FundamentalsDataClient(provider: provider, entitlement: entitlement([.submissions]))
        let first = try await client.submissions(request(.submissions, resource: "0000320193"))
        #expect(first.exchange.result.status == .partial)
        #expect(first.exchange.result.nextPageToken == "CIK0000320193-submissions-001.json")
        #expect(first.continuationTokens == ["CIK0000320193-submissions-001.json"])
        #expect(first.exchange.result.items[0].isAmendment)
        #expect(first.exchange.result.items[0].acceptedAt != nil)
        let second = try await client.submissions(request(.submissions, resource: "0000320193",
            page: "CIK0000320193-submissions-001.json"))
        #expect(second.exchange.result.status == .complete)
        #expect(second.exchange.result.items[0].acceptedAt == nil)
        let availabilityUpper = try second.exchange.result.items[0].provenance.availability.upperBound()
        let filingDayStart = try MarketDate(iso8601: "2024-08-02").start(in: TimeZone(identifier: "America/New_York")!)
        #expect(availabilityUpper > filingDayStart)
        let urls = await transport.captured().compactMap(\.url?.absoluteString)
        #expect(urls == ["https://data.sec.gov/submissions/CIK0000320193.json",
                         "https://data.sec.gov/submissions/CIK0000320193-submissions-001.json"])
    }

    @Test func companyFactsPreserveRevisionsUnitsZeroAndUnknownConcepts() async throws {
        let bytes = companyFactsFixture()
        let (provider, _, _) = try provider([bytes])
        let client = FundamentalsDataClient(provider: provider, entitlement: entitlement([.companyFacts]))
        let accepted = try await client.companyFacts(request(.companyFacts, resource: "0000320193"))
        let facts = accepted.exchange.result.items
        #expect(facts.count == 4)
        #expect(facts.filter { $0.concept == "RevenueFromContractWithCustomerExcludingAssessedTax" }.count == 3)
        #expect(facts.contains { $0.concept == "CustomMetric" && $0.value == (try? Money("0")) })
        #expect(Set(facts.map(\.unit)) == ["USD"])
        #expect(Set(facts.map(\.recordID)).count == facts.count)
        #expect(Set(facts.filter { $0.concept != "CustomMetric" }.map(\.factID)).count == 2)
    }

    @Test func archiveIndexAndDocumentUseClosedPathsAndKeepExactBytes() async throws {
        let index = Data(#"{"directory":{"item":[{"name":"aapl-20250628.htm","type":"text/html","size":123},{"name":"Financial_Report.xlsx","type":"application/vnd.ms-excel","size":45}]}}"#.utf8)
        let document = Data("<html>synthetic filing</html>".utf8)
        let transport = SECFixtureTransport([HTTPPayload(statusCode: 200, mediaType: "application/json", body: index),
                                             HTTPPayload(statusCode: 200, mediaType: "text/html", body: document)])
        let gate = SECFixtureGate()
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com", transport: transport,
            gate: gate, evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", now: { now })
        let rights = entitlement([.filingIndex, .filingDocument])
        let client = FundamentalsDataClient(provider: provider, entitlement: rights)
        let root = "0000320193/0000320193-25-000079"
        let acceptedIndex = try await client.filingIndex(request(.filingIndex, resource: root))
        #expect(acceptedIndex.exchange.result.items[0].files.count == 2)
        let acceptedDocument = try await client.filingDocument(request(.filingDocument, resource: root + "/aapl-20250628.htm"))
        #expect(acceptedDocument.rawPayload.bytes == document)
        let urls = await transport.captured().compactMap(\.url?.absoluteString)
        #expect(urls == ["https://www.sec.gov/Archives/edgar/data/320193/000032019325000079/index.json",
                         "https://www.sec.gov/Archives/edgar/data/320193/000032019325000079/aapl-20250628.htm"])
        await #expect(throws: SECAdapterError.invalidResource) {
            try await client.filingDocument(request(.filingDocument, resource: root + "/../secret"))
        }
    }

    @Test func throttleIsAnErrorAndNeverAnEmptyAcceptedPage() async throws {
        let (provider, _, _) = try provider([Data("{}".utf8)], status: 429)
        let client = FundamentalsDataClient(provider: provider, entitlement: entitlement([.companyIdentity]))
        await #expect(throws: ProviderFailure.rateLimited) {
            try await client.companyIdentity(request(.companyIdentity, resource: "AAPL"))
        }
    }

    @Test func acquisitionPipelineAcceptsStoresAndAuditsOfflineWithoutGrantingValuation() async throws {
        let identity = Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Apple Inc.","AAPL","Nasdaq"]]}"#.utf8)
        let (provider, transport, _) = try provider([identity, companyFactsFixture()])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-pipeline-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try DatabaseStore(path: path)
        let store = try BusinessDataStore(database: database)
        let client = FundamentalsDataClient(provider: provider, entitlement: entitlement([.companyIdentity, .companyFacts]))
        let pipeline = SECAcquisitionPipeline(client: client, store: store)
        let first = try await pipeline.ingest(request(.companyIdentity, resource: "AAPL"))
        #expect(first.status == .complete && first.insertedDocuments == 1 && first.insertedRecords == 1)
        let second = try await pipeline.ingest(request(.companyFacts, resource: "0000320193"))
        #expect(second.status == .complete && second.insertedDocuments == 1 && second.insertedRecords > 0)
        let audit = try await OfflineResearchEvidenceReader(store: store).inspect(symbol: "AAPL",
            cutoff: now.addingTimeInterval(1), barWindow: .init(start: now.addingTimeInterval(-86_400), end: now),
            dictionary: .foundationV1())
        #expect(audit.identity?.cik == "0000320193")
        #expect(audit.normalization?.values.isEmpty == false)
        #expect(audit.sourceHashes.count == 2)
        #expect(audit.gaps.contains(.missingDailyBar))
        #expect(audit.gaps.contains(.supplierAndLicenseNotQualified))
        #expect(!audit.mayRunValuation)
        let replay = try await OfflineResearchEvidenceReader(store: BusinessDataStore(path: path)).inspect(symbol: "AAPL",
            cutoff: now.addingTimeInterval(1), barWindow: .init(start: now.addingTimeInterval(-86_400), end: now),
            dictionary: .foundationV1())
        #expect(try ResearchDocument.encoded(audit) == ResearchDocument.encoded(replay))

        let invalid = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: "0000320193",
            capability: .companyFacts, mode: .latest, usage: .pitResearch,
            configurationVersion: "wrong-version", entitlementVersion: "sec-rights.v1", requestedAt: now)
        await #expect(throws: ContractError.mismatchedRequest) { try await pipeline.ingest(invalid) }
        #expect(await transport.captured().count == 2)

        try database.transaction { db in
            try db.execute(sql: "UPDATE p1_source_documents SET payload = X'41' WHERE endpoint_descriptor = ?",
                           arguments: [EndpointDescriptor.companyFacts.rawValue])
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await OfflineResearchEvidenceReader(store: store).inspect(symbol: "AAPL",
                cutoff: now.addingTimeInterval(1), barWindow: .init(start: now.addingTimeInterval(-86_400), end: now),
                dictionary: .foundationV1())
        }
    }

    @Test func acquisitionDoesNotRebaseAnInFlightPageAfterAnotherStoreWrite() async throws {
        let raw = Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Apple Inc.","AAPL","Nasdaq"]]}"#.utf8)
        let transport = PausedSECTransport(HTTPPayload(statusCode: 200, mediaType: "application/json", body: raw))
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com",
            transport: transport, gate: SECFixtureGate(), evidenceRef: "sec-official-api",
            licenseRef: "sec-public-access.v1", now: { now })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-race-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BusinessDataStore(path: path)
        let pipeline = SECAcquisitionPipeline(client: FundamentalsDataClient(provider: provider,
            entitlement: entitlement([.companyIdentity])), store: store)
        let task = Task { try await pipeline.ingest(request(.companyIdentity, resource: "AAPL")) }
        await transport.waitForStart()
        let stamp = try MillisecondInstant(rounding: now)
        let document = try SourceDocument(reference: "fixture/concurrent", providerID: "fixture", feedID: "fixture",
            endpoint: .companyFacts, receivedAt: stamp, availableAt: stamp,
            mediaType: "application/json", evidenceRef: "fixture", licenseRef: "fixture", payload: Data("{}".utf8))
        _ = try await store.ingest(document: document, observations: [], expectedRevision: store.revision())
        await transport.release()
        await #expect(throws: SnapshotError.stalePlan) { try await task.value }
        #expect(try await store.counts().sourceDocuments == 1)
        await #expect(throws: SnapshotError.missingReference) {
            try await store.secIdentity(ticker: "AAPL", asOf: now.addingTimeInterval(1))
        }
    }

    @Test func offlineEvidenceKeepsSubmillisecondCutoffAndExcludesTheNextMillisecond() async throws {
        let future = now.addingTimeInterval(0.001)
        let transport = SECFixtureTransport([HTTPPayload(statusCode: 200, mediaType: "application/json",
            body: Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Apple Inc.","AAPL","Nasdaq"]]}"#.utf8))])
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com",
            transport: transport, gate: SECFixtureGate(), evidenceRef: "sec-official-api",
            licenseRef: "sec-public-access.v1", now: { future })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-cutoff-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BusinessDataStore(path: path)
        let request = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: "AAPL",
            capability: .companyIdentity, mode: .latest, usage: .pitResearch,
            configurationVersion: "sec-edgar.v1", entitlementVersion: "sec-rights.v1", requestedAt: future)
        _ = try await SECAcquisitionPipeline(client: FundamentalsDataClient(provider: provider,
            entitlement: entitlement([.companyIdentity])), store: store).ingest(request)
        let reader = OfflineResearchEvidenceReader(store: store)
        let start = now.addingTimeInterval(-1)
        let early = now.addingTimeInterval(0.0004)
        let earlyAudit = try await reader.inspect(symbol: "AAPL", cutoff: early,
            barWindow: .init(start: start, end: early), dictionary: .foundationV1())
        #expect(earlyAudit.identity == nil)
        #expect(earlyAudit.cutoff == early)
        let replay = try JSONDecoder().decode(OfflineResearchEvidence.self, from: ResearchDocument.encoded(earlyAudit))
        #expect(replay.cutoff == early)
        let beforeFuture = now.addingTimeInterval(0.0006)
        let beforeAudit = try await reader.inspect(symbol: "AAPL", cutoff: beforeFuture,
            barWindow: .init(start: start, end: beforeFuture), dictionary: .foundationV1())
        #expect(beforeAudit.identity == nil)
        let atFuture = try await reader.inspect(symbol: "AAPL", cutoff: future,
            barWindow: .init(start: start, end: future), dictionary: .foundationV1())
        #expect(atFuture.identity?.cik == "0000320193")
    }

    @Test func acquisitionKeepsPartialCoverageAndRejectsThrottleWithoutWriting() async throws {
        let partial = Data(#"{"cik":"0000320193","filings":{"recent":{"accessionNumber":["0000320193-25-000079"],"filingDate":["2025-08-01"],"reportDate":["2025-06-28"],"acceptanceDateTime":["2025-08-01T20:01:02.000Z"],"form":["10-Q"],"primaryDocument":["aapl-20250628.htm"]},"files":[{"name":"CIK0000320193-submissions-001.json"}]}}"#.utf8)
        let (firstProvider, _, _) = try provider([partial])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-partial-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BusinessDataStore(path: path)
        let pipeline = SECAcquisitionPipeline(client: FundamentalsDataClient(provider: firstProvider,
            entitlement: entitlement([.submissions])), store: store)
        let receipt = try await pipeline.ingest(request(.submissions, resource: "0000320193"))
        #expect(receipt.status == .partial)
        #expect(receipt.nextPageToken == "CIK0000320193-submissions-001.json")
        #expect(receipt.insertedRecords == 1)
        let before = await store.revision()
        let (throttled, _, _) = try provider([Data("{}".utf8)], status: 429)
        let failed = SECAcquisitionPipeline(client: FundamentalsDataClient(provider: throttled,
            entitlement: entitlement([.submissions])), store: store)
        await #expect(throws: ProviderFailure.rateLimited) {
            try await failed.ingest(request(.submissions, resource: "0000320193",
                page: "CIK0000320193-submissions-001.json"))
        }
        #expect(await store.revision() == before)
    }

    private func companyFactsFixture() -> Data {
        Data(#"{"cik":320193,"entityName":"Apple Inc.","facts":{"us-gaap":{"RevenueFromContractWithCustomerExcludingAssessedTax":{"label":"Revenue","description":"Revenue","units":{"USD":[{"val":10,"accn":"0000320193-24-000001","fy":2024,"fp":"Q1","form":"10-Q","filed":"2024-02-01","start":"2024-01-01","end":"2024-03-31","frame":"CY2024Q1"},{"val":25,"accn":"0000320193-24-000002","fy":2024,"fp":"Q2","form":"10-Q","filed":"2024-05-01","start":"2024-01-01","end":"2024-06-30","frame":"CY2024Q2"},{"val":26,"accn":"0000320193-24-000003","fy":2024,"fp":"Q2","form":"10-Q/A","filed":"2024-05-15","start":"2024-01-01","end":"2024-06-30","frame":"CY2024Q2"}]}},"CustomMetric":{"label":"Custom","description":"Issuer extension-like fixture","units":{"USD":[{"val":0,"accn":"0000320193-24-000002","fy":2024,"fp":"Q2","form":"10-Q","filed":"2024-05-01","start":"2024-01-01","end":"2024-06-30"}]}}}}}"#.utf8)
    }
}

@Suite struct PhaseOneFinancialNormalizationTests {
    let cutoff = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01
    let hash = String(repeating: "a", count: 64)

    func day(_ value: String) throws -> MarketDate { try MarketDate(iso8601: value) }
    func fact(id: String, value: String, start: String?, end: String, filed: String,
              fp: String, form: String = "10-Q", concept: String = "RevenueFromContractWithCustomerExcludingAssessedTax",
              factID: String? = nil, dimensions: [String: String] = [:], availability: Date? = nil) throws -> SECCompanyFactRecord {
        let version = "v-" + id
        let endDate = try day(end), filedDate = try day(filed)
        let defaultAvailability = try filedDate.start(in: TimeZone(secondsFromGMT: 0)!).addingTimeInterval(86_400)
        let available = availability ?? defaultAvailability
        let provenance = Provenance(providerID: "sec-edgar", feedID: "public-edgar", sourceEventAt: nil,
            receivedAt: cutoff, availableAt: nil, evidenceRef: "sec-official-api", origin: .filing,
            endpointDescriptor: EndpointDescriptor.companyFacts.rawValue, requestedAt: cutoff.addingTimeInterval(-1),
            requestID: UUID(), observationDate: endDate, versionID: version, versionKind: .sourceVersion,
            availability: .instant(available, evidence: "synthetic accepted evidence"),
            rawObjectRef: "provider/sec/" + id, rawHash: hash, normalizationVersion: "sec-edgar.decode.v1",
            licenseRef: "sec-public-access.v1")
        return try SECCompanyFactRecord(recordID: "record-" + id, factID: factID ?? "fact-" + id,
            cik: "0000320193", taxonomy: "us-gaap", concept: concept, label: concept, description: "fixture",
            unit: "USD", sourceValue: value, value: Money(value), startDate: try start.map(day), endDate: endDate,
            periodKind: start == nil ? .instant : .duration, accessionNumber: "0000320193-24-" + String(format: "%06d", Int(id.filter(\.isNumber)) ?? 1),
            form: form, filedDate: filedDate, fiscalYear: 2024, fiscalPeriod: fp, frame: nil,
            dimensions: dimensions, provenance: provenance)
    }

    @Test func revisionSelectionUsesAvailabilityAndUnknownTagsStayVisible() throws {
        let dictionary = try FinancialFieldDictionary.foundationV1()
        let old = try fact(id: "101", value: "25", start: "2024-01-01", end: "2024-06-30", filed: "2024-05-01",
                           fp: "Q2", factID: "same-context", availability: Date(timeIntervalSince1970: 100))
        let new = try fact(id: "102", value: "26", start: "2024-01-01", end: "2024-06-30", filed: "2024-05-15",
                           fp: "Q2", form: "10-Q/A", factID: "same-context", availability: Date(timeIntervalSince1970: 300))
        let unknown = try fact(id: "103", value: "0", start: "2024-01-01", end: "2024-06-30", filed: "2024-05-01",
                               fp: "Q2", concept: "IssuerCustomMetric", availability: Date(timeIntervalSince1970: 100))
        let segmented = try fact(id: "104", value: "25", start: "2024-01-01", end: "2024-06-30", filed: "2024-05-01",
                                 fp: "Q2", dimensions: ["StatementClassOfStockAxis": "ClassAMember"],
                                 availability: Date(timeIntervalSince1970: 100))
        let early = try FinancialNormalizer.normalize([old, new, unknown, segmented], dictionary: dictionary,
                                                       asOf: Date(timeIntervalSince1970: 200))
        #expect(early.values.count == 1)
        #expect(early.values[0].value == (try Money("25")))
        #expect(Set(early.unmappedSourceFacts.map(\.recordID)) == Set([unknown.recordID, segmented.recordID]))
        let late = try FinancialNormalizer.normalize([old, new], dictionary: dictionary,
                                                      asOf: Date(timeIntervalSince1970: 400))
        #expect(late.values[0].value == (try Money("26")))
        #expect(late.values[0].accessionNumbers == [new.accessionNumber])
    }

    @Test func q1YTDSubtractsToDiscreteQuartersAndFourQuartersMakeTTM() throws {
        let facts = [
            try fact(id: "201", value: "10", start: "2024-01-01", end: "2024-03-31", filed: "2024-04-20", fp: "Q1"),
            try fact(id: "202", value: "25", start: "2024-01-01", end: "2024-06-30", filed: "2024-07-20", fp: "Q2"),
            try fact(id: "203", value: "45", start: "2024-01-01", end: "2024-09-30", filed: "2024-10-20", fp: "Q3"),
            try fact(id: "204", value: "70", start: "2024-01-01", end: "2024-12-31", filed: "2024-12-31", fp: "FY", form: "10-K")
        ]
        let normalized = try FinancialNormalizer.normalize(facts, dictionary: .foundationV1(), asOf: cutoff)
        let quarters = try FinancialNormalizer.discreteQuarters(from: normalized.values)
        #expect(quarters.issues.isEmpty)
        #expect(quarters.values.map(\.value) == [try Money("10"), try Money("15"), try Money("20"), try Money("25")])
        #expect(quarters.values.map(\.fiscalPeriod) == ["Q1", "Q2", "Q3", "Q4"])
        let ttm = try FinancialNormalizer.trailingTwelveMonths(from: quarters.values)
        #expect(ttm.issues.isEmpty)
        #expect(ttm.values.count == 1)
        #expect(ttm.values[0].value == (try Money("70")))
        #expect(ttm.values[0].sourceFactIDs.count == 4)
        let complete = try FinancialNormalizer.normalizeComplete(facts, dictionary: .foundationV1(), asOf: cutoff)
        #expect(complete.values.contains { $0.periodType == .trailingTwelveMonths && $0.value == (try? Money("70")) })
        let reordered = try FinancialNormalizer.normalizeComplete(Array(facts.reversed()), dictionary: .foundationV1(), asOf: cutoff)
        #expect(reordered == complete)
    }

    @Test func missingBridgeAndConflictingAliasesNeverBecomeSilentValues() throws {
        let ytd = try fact(id: "301", value: "25", start: "2024-01-01", end: "2024-06-30", filed: "2024-07-20", fp: "Q2")
        let alias = try fact(id: "302", value: "24", start: "2024-01-01", end: "2024-06-30", filed: "2024-07-20",
                             fp: "Q2", concept: "Revenues")
        let normalized = try FinancialNormalizer.normalize([ytd, alias], dictionary: .foundationV1(), asOf: cutoff)
        #expect(normalized.issues.contains { $0.code == "mapping-conflict" && $0.severity == .blocker })
        #expect(normalized.values.isEmpty)
        let ytdOnly = try FinancialNormalizer.normalize([ytd], dictionary: .foundationV1(), asOf: cutoff)
        let quarters = try FinancialNormalizer.discreteQuarters(from: ytdOnly.values)
        #expect(quarters.values.isEmpty)
        #expect(quarters.issues.contains { $0.code == "missing-ytd-bridge" })
        let ttm = try FinancialNormalizer.trailingTwelveMonths(from: [])
        #expect(ttm.values.isEmpty)
    }

    @Test func equivalentAliasDeduplicatesAndReportedQuarterWinsOverBridge() throws {
        let preferred = try fact(id: "401", value: "15", start: "2024-04-01", end: "2024-06-30",
                                 filed: "2024-07-20", fp: "Q2")
        let alias = try fact(id: "402", value: "15", start: "2024-04-01", end: "2024-06-30",
                             filed: "2024-07-20", fp: "Q2", concept: "Revenues")
        let q1 = try fact(id: "403", value: "10", start: "2024-01-01", end: "2024-03-31",
                          filed: "2024-04-20", fp: "Q1")
        let ytd = try fact(id: "404", value: "25", start: "2024-01-01", end: "2024-06-30",
                           filed: "2024-07-20", fp: "Q2")
        let normalized = try FinancialNormalizer.normalize([preferred, alias, q1, ytd],
                                                            dictionary: .foundationV1(), asOf: cutoff)
        #expect(normalized.issues.contains { $0.code == "equivalent-mapping-deduplicated" })
        #expect(normalized.values.filter { $0.periodType == .quarter && $0.fiscalPeriod == "Q2" }.count == 1)
        let quarters = try FinancialNormalizer.discreteQuarters(from: normalized.values)
        let q2 = try #require(quarters.values.filter { $0.fiscalPeriod == "Q2" }.only)
        #expect(q2.derivation == .reported)
        #expect(q2.value == (try Money("15")))
        #expect(throws: FinancialNormalizationError.invalidDictionary) {
            try FinancialFieldDictionary(version: "invalid.v1", rules: [
                FinancialMappingRule(taxonomy: "us-gaap", concept: "Revenues", sourceUnit: "USD",
                    fieldID: "income.revenue", statement: .incomeStatement, nature: .additiveFlow),
                FinancialMappingRule(taxonomy: "us-gaap", concept: "SalesRevenueNet", sourceUnit: "USD",
                    fieldID: "income.revenue", statement: .incomeStatement, nature: .additiveFlow)
            ])
        }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

@Suite struct PhaseOneSECPersistenceTests {
    let now = Date(timeIntervalSince1970: 1_757_592_000)

    @Test func acceptedFactsPersistExactRawBytesSelectPITAndNormalizationReopens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("sec.sqlite").path
        let raw = Data(#"{"cik":320193,"entityName":"Apple Inc.","facts":{"us-gaap":{"RevenueFromContractWithCustomerExcludingAssessedTax":{"label":"Revenue","description":"Revenue","units":{"USD":[{"val":10,"accn":"0000320193-24-000001","fy":2024,"fp":"Q1","form":"10-Q","filed":"2024-02-01","start":"2024-01-01","end":"2024-03-31","frame":"CY2024Q1"},{"val":11,"accn":"0000320193-24-000002","fy":2024,"fp":"Q1","form":"10-Q/A","filed":"2024-02-15","start":"2024-01-01","end":"2024-03-31","frame":"CY2024Q1"}]}}}}}"#.utf8)
        let expandedRaw = Data(#"{"cik":320193,"entityName":"Apple Inc.","facts":{"us-gaap":{"RevenueFromContractWithCustomerExcludingAssessedTax":{"label":"Revenue","description":"Revenue","units":{"USD":[{"val":10,"accn":"0000320193-24-000001","fy":2024,"fp":"Q1","form":"10-Q","filed":"2024-02-01","start":"2024-01-01","end":"2024-03-31","frame":"CY2024Q1"},{"val":11,"accn":"0000320193-24-000002","fy":2024,"fp":"Q1","form":"10-Q/A","filed":"2024-02-15","start":"2024-01-01","end":"2024-03-31","frame":"CY2024Q1"}]}},"IssuerCustomMetric":{"label":"Custom","description":"Unmapped source fact","units":{"USD":[{"val":0,"accn":"0000320193-24-000002","fy":2024,"fp":"Q1","form":"10-Q/A","filed":"2024-02-15","start":"2024-01-01","end":"2024-03-31"}]}}}}}"#.utf8)
        let transport = SECFixtureTransport([
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: raw),
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: raw),
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: expandedRaw)
        ])
        let gate = SECFixtureGate()
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com", transport: transport,
            gate: gate, evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", now: { now })
        let rights = EntitlementSnapshot(providerID: "sec-edgar", feedID: "public-edgar", version: "sec-rights.v1",
            evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", capabilities: [.companyFacts],
            usages: [.pitResearch], validFrom: now.addingTimeInterval(-1), validThrough: now.addingTimeInterval(1))
        let request = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: "0000320193",
            capability: .companyFacts, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
            entitlementVersion: "sec-rights.v1", requestedAt: now)
        let accepted = try await FundamentalsDataClient(provider: provider, entitlement: rights).companyFacts(request)
        let store = try BusinessDataStore(path: path)
        let receipt = try await store.ingestSECCompanyFacts(accepted, expectedRevision: store.revision())
        #expect(receipt.insertedDocuments == 1)
        #expect(receipt.insertedRecords == 2)
        let duplicate = try await store.ingestSECCompanyFacts(accepted, expectedRevision: store.revision())
        #expect(duplicate.insertedDocuments == 0 && duplicate.insertedRecords == 0)
        #expect(duplicate.revision == receipt.revision)
        let repeatedRequest = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: "0000320193",
            capability: .companyFacts, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
            entitlementVersion: "sec-rights.v1", requestedAt: now)
        let repeated = try await FundamentalsDataClient(provider: provider, entitlement: rights).companyFacts(repeatedRequest)
        #expect(repeated.rawPayload.reference != accepted.rawPayload.reference)
        let repeatedReceipt = try await store.ingestSECCompanyFacts(repeated, expectedRevision: store.revision())
        #expect(repeatedReceipt.insertedDocuments == 0 && repeatedReceipt.insertedRecords == 0)
        #expect(repeatedReceipt.revision == receipt.revision)
        await #expect(throws: SnapshotError.missingReference) {
            try await store.sourceDocument(reference: repeated.rawPayload.reference)
        }
        let expandedRequest = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: "0000320193",
            capability: .companyFacts, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
            entitlementVersion: "sec-rights.v1", requestedAt: now)
        let expanded = try await FundamentalsDataClient(provider: provider, entitlement: rights).companyFacts(expandedRequest)
        let expandedReceipt = try await store.ingestSECCompanyFacts(expanded, expectedRevision: store.revision())
        #expect(expandedReceipt.insertedDocuments == 1 && expandedReceipt.insertedRecords == 1)
        #expect(try await store.sourceDocument(reference: expanded.rawPayload.reference).payload == expandedRaw)
        #expect(try await store.sourceDocument(reference: accepted.rawPayload.reference).payload == raw)
        let purge = try await store.purgeCache(seriesIDs: ["synthetic-unused-series"],
                                               expectedRevision: store.revision())
        #expect(purge.removedDocuments == 0 && purge.removedObservations == 0)
        #expect(try await store.sourceDocument(reference: accepted.rawPayload.reference).payload == raw)
        #expect(try await store.sourceDocument(reference: expanded.rawPayload.reference).payload == expandedRaw)
        let earlyCutoff = try MarketDate(iso8601: "2024-02-10").start(in: TimeZone(identifier: "America/New_York")!)
        let earlyFacts = try await store.secFactVersions(cik: "0000320193", asOf: earlyCutoff)
        let early = try FinancialNormalizer.normalize(earlyFacts, dictionary: .foundationV1(), asOf: earlyCutoff)
        #expect(early.values.count == 1)
        #expect(early.values[0].value == (try Money("10")))
        #expect(early.values[0].confidence == .medium)
        let lateCutoff = try MarketDate(iso8601: "2024-03-01").start(in: TimeZone(identifier: "America/New_York")!)
        let lateFacts = try await store.secFactVersions(cik: "0000320193", asOf: lateCutoff)
        let late = try FinancialNormalizer.normalizeComplete(lateFacts, dictionary: .foundationV1(), asOf: lateCutoff)
        #expect(late.values.count == 1)
        #expect(late.values[0].value == (try Money("11")))
        let persisted = try await store.persistNormalization(late, dictionary: .foundationV1(),
                                                             expectedRevision: store.revision())
        #expect(persisted.insertedDictionary)
        #expect(persisted.insertedValues == 1)
        let reopened = try BusinessDataStore(path: path)
        let loaded = try await reopened.normalization(runID: persisted.runID)
        #expect(loaded.values == late.values)
        let loadedDictionary = try await reopened.financialDictionary(version: late.dictionaryVersion)
        let expectedDictionary = try FinancialFieldDictionary.foundationV1()
        #expect(loadedDictionary.rules == expectedDictionary.rules)
        #expect(try await reopened.sourceDocument(reference: accepted.rawPayload.reference).payload == raw)
    }

    @Test func filingDocumentMetadataAndExactBytesCommitTogetherAndReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("filing.sqlite").path
        let bytes = Data("<html>synthetic immutable filing</html>".utf8)
        let transport = SECFixtureTransport([HTTPPayload(statusCode: 200, mediaType: "text/html", body: bytes)])
        let gate = SECFixtureGate()
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com", transport: transport,
            gate: gate, evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", now: { now })
        let rights = EntitlementSnapshot(providerID: "sec-edgar", feedID: "public-edgar", version: "sec-rights.v1",
            evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", capabilities: [.filingDocument],
            usages: [.pitResearch], validFrom: now.addingTimeInterval(-1), validThrough: now.addingTimeInterval(1))
        let resource = "0000320193/0000320193-25-000079/aapl-20250628.htm"
        let request = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: resource,
            capability: .filingDocument, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
            entitlementVersion: "sec-rights.v1", requestedAt: now)
        let accepted = try await FundamentalsDataClient(provider: provider, entitlement: rights).filingDocument(request)
        let store = try BusinessDataStore(path: path)
        let receipt = try await store.ingestSECFilingDocument(accepted, expectedRevision: store.revision())
        #expect(receipt.insertedDocuments == 1 && receipt.insertedRecords == 1)
        let reopened = try BusinessDataStore(path: path)
        let record = try await reopened.secFilingDocument(cik: "0000320193", accessionNumber: "0000320193-25-000079",
                                                          fileName: "aapl-20250628.htm", asOf: now)
        #expect(record.provenance.rawHash == digest(bytes))
        #expect(try await reopened.sourceDocument(reference: record.provenance.rawObjectRef!).payload == bytes)
    }

    @Test func tickerIdentityAndFilingIndexRemainQueryableAfterReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("sec-index.sqlite").path
        let identityBytes = Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Apple Inc.","AAPL","Nasdaq"]]}"#.utf8)
        let indexBytes = Data(#"{"directory":{"item":[{"name":"aapl-20250628.htm","type":"text/html","size":123}]}}"#.utf8)
        let transport = SECFixtureTransport([
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: identityBytes),
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: indexBytes)
        ])
        let gate = SECFixtureGate()
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com", transport: transport,
            gate: gate, evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", now: { now })
        let rights = EntitlementSnapshot(providerID: "sec-edgar", feedID: "public-edgar", version: "sec-rights.v1",
            evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1",
            capabilities: [.companyIdentity, .filingIndex], usages: [.pitResearch],
            validFrom: now.addingTimeInterval(-1), validThrough: now.addingTimeInterval(1))
        let client = FundamentalsDataClient(provider: provider, entitlement: rights)
        let identityRequest = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: "AAPL",
            capability: .companyIdentity, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
            entitlementVersion: "sec-rights.v1", requestedAt: now)
        let indexRequest = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar",
            resourceID: "0000320193/0000320193-25-000079", capability: .filingIndex, mode: .latest,
            usage: .pitResearch, configurationVersion: "sec-edgar.v1", entitlementVersion: "sec-rights.v1",
            requestedAt: now)
        let store = try BusinessDataStore(path: path)
        try await store.ingestSECIdentities(client.companyIdentity(identityRequest), expectedRevision: store.revision())
        try await store.ingestSECFilingIndex(client.filingIndex(indexRequest), expectedRevision: store.revision())
        let reopened = try BusinessDataStore(path: path)
        #expect(try await reopened.secIdentity(ticker: "AAPL", asOf: now).cik == "0000320193")
        let index = try await reopened.secFilingIndex(cik: "0000320193",
            accessionNumber: "0000320193-25-000079", asOf: now)
        #expect(index.files.map(\.name) == ["aapl-20250628.htm"])
        #expect(try await reopened.sourceDocument(reference: index.provenance.rawObjectRef!).payload == indexBytes)
    }
}

@Suite struct SECAvailabilityPrecisionTests {
    let now = Date(timeIntervalSince1970: 1_757_592_000)
    let identityBytes = Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[320193,"Apple Inc.","AAPL","Nasdaq"]]}"#.utf8)
    let submissionBytes = Data(#"{"cik":"0000320193","filings":{"recent":{"accessionNumber":["0000320193-25-000079"],"filingDate":["2025-09-11"],"reportDate":["2025-06-28"],"acceptanceDateTime":["2025-09-11T12:00:00.000Z"],"form":["10-Q"],"primaryDocument":["aapl-20250628.htm"]},"files":[]}}"#.utf8)
    let factBytes = Data(#"{"cik":320193,"entityName":"Apple Inc.","facts":{"us-gaap":{"RevenueFromContractWithCustomerExcludingAssessedTax":{"label":"Revenue","description":"Revenue","units":{"USD":[{"val":10,"accn":"0000320193-25-000079","fy":2025,"fp":"Q2","form":"10-Q","filed":"2025-09-11","start":"2025-04-01","end":"2025-06-30"}]}}}}}"#.utf8)

    private func client(_ payloads: [HTTPPayload], at received: Date, capabilities: Set<ProviderCapability>) throws
        -> FundamentalsDataClient<SECEdgarProvider<SECFixtureTransport, SECFixtureGate>> {
        let provider = try SECEdgarProvider(userAgent: "MarketDecision/1.0 research@example.com",
            transport: SECFixtureTransport(payloads), gate: SECFixtureGate(), evidenceRef: "sec-official-api",
            licenseRef: "sec-public-access.v1", now: { received })
        let rights = EntitlementSnapshot(providerID: "sec-edgar", feedID: "public-edgar", version: "sec-rights.v1",
            evidenceRef: "sec-official-api", licenseRef: "sec-public-access.v1", capabilities: capabilities,
            usages: [.pitResearch], validFrom: now.addingTimeInterval(-1), validThrough: now.addingTimeInterval(1))
        return FundamentalsDataClient(provider: provider, entitlement: rights)
    }

    private func request(_ capability: ProviderCapability, resource: String, at date: Date) -> ProviderRequest {
        ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: resource,
            capability: capability, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
            entitlementVersion: "sec-rights.v1", requestedAt: date)
    }

    private func legacyBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(MillisecondInstant(rounding: date).iso8601)
        }
        return try encoder.encode(value)
    }

    /// Synthetic storage fixture with a valid content hash and a matching coarse index.
    /// This does not claim the SEC Company Facts adapter supplies instant-level availability.
    private func replaceRecord(_ database: DatabaseStore, table: String, bytes: Data, indexedAt date: Date) throws {
        try database.transaction { db in
            try db.execute(sql: "UPDATE " + table + " SET record_json = ?, record_hash = ?, available_at_ms = ?",
                           arguments: [bytes, digest(bytes), try MillisecondInstant(flooring: date).milliseconds])
        }
    }

    @Test func sameMillisecondAcquisitionRetainsExactAvailabilityAfterReopen() async throws {
        let acquired = now.addingTimeInterval(0.0004), early = now.addingTimeInterval(0.0002)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("precise.sqlite").path
        let database = try DatabaseStore(path: path), store = try BusinessDataStore(database: database)
        let client = try client([
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: identityBytes),
            HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data(#"{"directory":{"item":[{"name":"aapl-20250628.htm","type":"text/html","size":123}]}}"#.utf8)),
            HTTPPayload(statusCode: 200, mediaType: "text/html", body: Data("<html>synthetic</html>".utf8))
        ], at: acquired, capabilities: [.companyIdentity, .filingIndex, .filingDocument])
        let pipeline = SECAcquisitionPipeline(client: client, store: store)
        let root = "0000320193/0000320193-25-000079"
        _ = try await pipeline.ingest(request(.companyIdentity, resource: "AAPL", at: acquired))
        _ = try await pipeline.ingest(request(.filingIndex, resource: root, at: acquired))
        _ = try await pipeline.ingest(request(.filingDocument, resource: root + "/aapl-20250628.htm", at: acquired))
        let reopened = try BusinessDataStore(path: path)
        for reader in [store, reopened] {
            await #expect(throws: SnapshotError.missingReference) { try await reader.secIdentity(ticker: "AAPL", asOf: early) }
            await #expect(throws: SnapshotError.missingReference) {
                try await reader.secFilingIndex(cik: "0000320193", accessionNumber: "0000320193-25-000079", asOf: early)
            }
            await #expect(throws: SnapshotError.missingReference) {
                try await reader.secFilingDocument(cik: "0000320193", accessionNumber: "0000320193-25-000079",
                                                  fileName: "aapl-20250628.htm", asOf: early)
            }
            let identity = try await reader.secIdentity(ticker: "AAPL", asOf: acquired)
            #expect(try identity.provenance.availability.upperBound() == acquired)
            #expect(identity.provenance.receivedAt == acquired)
            #expect(identity.provenance.requestedAt == acquired)
            #expect(identity.provenance.sourceEventAt == acquired)
            let index = try await reader.secFilingIndex(cik: "0000320193", accessionNumber: "0000320193-25-000079", asOf: acquired)
            let document = try await reader.secFilingDocument(cik: "0000320193", accessionNumber: "0000320193-25-000079",
                                                            fileName: "aapl-20250628.htm", asOf: acquired)
            #expect(try index.provenance.availability.upperBound() == acquired)
            #expect(try document.provenance.availability.upperBound() == acquired)
            let offline = try await OfflineResearchEvidenceReader(store: reader).inspect(symbol: "AAPL", cutoff: early,
                barWindow: .init(start: now.addingTimeInterval(-1), end: early), dictionary: .foundationV1())
            #expect(offline.identity == nil && offline.cutoff == early && !offline.mayRunValuation)
            let exact = try await OfflineResearchEvidenceReader(store: reader).inspect(symbol: "AAPL", cutoff: acquired,
                barWindow: .init(start: now.addingTimeInterval(-1), end: acquired), dictionary: .foundationV1())
            #expect(try exact.identity?.provenance.availability.upperBound() == acquired)
            let replay = try JSONDecoder().decode(OfflineResearchEvidence.self, from: ResearchDocument.encoded(exact))
            #expect(try ResearchDocument.encoded(replay) == ResearchDocument.encoded(exact))
        }
        let row = try #require(database.read { db in try Row.fetchOne(db, sql: "SELECT * FROM p1_sec_identities") })
        let bytes: Data = row["record_json"]
        let decoded = try JSONDecoder().decode(SECCompanyIdentityRecord.self, from: bytes)
        #expect(try decoded.provenance.availability.upperBound() == acquired)
        #expect(row["record_hash"] == digest(bytes))
        #expect(row["available_at_ms"] == (try MillisecondInstant(flooring: acquired).milliseconds))
        try database.transaction { db in try db.execute(sql: "UPDATE p1_sec_identities SET available_at_ms = available_at_ms - 1") }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await reopened.secIdentity(ticker: "AAPL", asOf: acquired) }
    }

    @Test func factsAndSubmissionsRequireExactSameMillisecondEvidence() async throws {
        let acquired = now.addingTimeInterval(0.0004), early = now.addingTimeInterval(0.0002)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-facts-precise-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try DatabaseStore(path: path), store = try BusinessDataStore(database: database)
        let client = try client([HTTPPayload(statusCode: 200, mediaType: "application/json", body: factBytes),
                                HTTPPayload(statusCode: 200, mediaType: "application/json", body: submissionBytes)],
                                at: acquired, capabilities: [.companyFacts, .submissions])
        let facts = try await client.companyFacts(request(.companyFacts, resource: "0000320193", at: acquired))
        let submissions = try await client.submissions(request(.submissions, resource: "0000320193", at: acquired))
        try await store.ingestSECCompanyFacts(facts, expectedRevision: store.revision())
        try await store.ingestSECSubmissions(submissions, expectedRevision: store.revision())
        for (table, value) in [("p1_sec_facts", try JSONEncoder().encode(facts.exchange.result.items[0])),
                               ("p1_sec_submissions", try JSONEncoder().encode(submissions.exchange.result.items[0]))] {
            var object = try #require(JSONSerialization.jsonObject(with: value) as? [String: Any])
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["availability"] = ["instant": ["_0": acquired.timeIntervalSinceReferenceDate, "evidence": "synthetic precise availability"]]
            if table == "p1_sec_submissions" {
                object["acceptedAt"] = acquired.timeIntervalSinceReferenceDate
                provenance["sourceEventAt"] = acquired.timeIntervalSinceReferenceDate
            }
            object["provenance"] = provenance
            try replaceRecord(database, table: table, bytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), indexedAt: acquired)
        }
        let reopened = try BusinessDataStore(path: path)
        #expect(try await reopened.secFactVersions(cik: "0000320193", asOf: early).isEmpty)
        #expect(try await reopened.secSubmissions(cik: "0000320193", asOf: early).isEmpty)
        let availableFacts = try await reopened.secFactVersions(cik: "0000320193", asOf: acquired)
        let availableSubmissions = try await reopened.secSubmissions(cik: "0000320193", asOf: acquired)
        #expect(availableFacts.count == 1 && availableSubmissions.count == 1)
        #expect(availableSubmissions.first?.acceptedAt == acquired)
        #expect(try availableFacts.first?.provenance.availability.upperBound() == acquired)
        let dictionary = try FinancialFieldDictionary.foundationV1()
        let normalized = try FinancialNormalizer.normalizeComplete(availableFacts, dictionary: dictionary, asOf: acquired)
        let receipt = try await reopened.persistNormalization(normalized, dictionary: dictionary, expectedRevision: reopened.revision())
        let replayed = try await BusinessDataStore(path: path).normalization(runID: receipt.runID)
        #expect(replayed == normalized && replayed.asOf == acquired)
        let legacyResult = try legacyBytes(normalized)
        try database.transaction { db in
            try db.execute(sql: "UPDATE p1_financial_normalization_runs SET result_json = ?, result_hash = ? WHERE run_id = ?",
                           arguments: [legacyResult, digest(legacyResult), receipt.runID])
        }
        await #expect(throws: BusinessStoreError.sourceMismatch) {
            try await BusinessDataStore(path: path).normalization(runID: receipt.runID)
        }
        let later = now.addingTimeInterval(1)
        let recomputed = try FinancialNormalizer.normalizeComplete(availableFacts, dictionary: dictionary, asOf: later)
        let fresh = try await reopened.persistNormalization(recomputed, dictionary: dictionary, expectedRevision: reopened.revision())
        #expect(try await BusinessDataStore(path: path).normalization(runID: fresh.runID) == recomputed)
    }

    @Test func legacyInstantAndIntervalAvailabilityStayConservativeWithoutRewritingBytes() async throws {
        let acquired = now.addingTimeInterval(0.0004), early = now.addingTimeInterval(0.0002)
        let next = try MillisecondInstant(milliseconds: MillisecondInstant(rounding: now).milliseconds + 1).date
        for interval in [false, true] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-legacy-\(UUID()).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let database = try DatabaseStore(path: path), store = try BusinessDataStore(database: database)
            let client = try client([HTTPPayload(statusCode: 200, mediaType: "application/json", body: identityBytes)],
                                    at: acquired, capabilities: [.companyIdentity])
            let accepted = try await client.companyIdentity(request(.companyIdentity, resource: "AAPL", at: acquired))
            try await store.ingestSECIdentities(accepted, expectedRevision: store.revision())
            var legacy = try legacyBytes(accepted.exchange.result.items[0])
            if interval {
                var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
                var provenance = try #require(object["provenance"] as? [String: Any])
                provenance["availability"] = ["interval": ["earliest": try MillisecondInstant(rounding: now.addingTimeInterval(-1)).iso8601,
                    "latest": try MillisecondInstant(rounding: acquired).iso8601, "evidence": "synthetic legacy interval"]]
                object["provenance"] = provenance
                legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            }
            try replaceRecord(database, table: "p1_sec_identities", bytes: legacy, indexedAt: now)
            let reopened = try BusinessDataStore(path: path)
            for cutoff in [early, now.addingTimeInterval(0.0008)] {
                await #expect(throws: SnapshotError.missingReference) { try await reopened.secIdentity(ticker: "AAPL", asOf: cutoff) }
            }
            let identity = try await reopened.secIdentity(ticker: "AAPL", asOf: next)
            #expect(try identity.provenance.availability.upperBound() == next)
            #expect(identity.provenance.receivedAt == now)
            if interval {
                guard case let .interval(earliest, latest, _) = identity.provenance.availability else {
                    Issue.record("Legacy interval disappeared"); return
                }
                #expect(earliest == now.addingTimeInterval(-1) && latest == next)
            }
            let revision = await reopened.revision()
            let duplicate = try await reopened.ingestSECIdentities(accepted, expectedRevision: revision)
            #expect(duplicate.insertedRecords == 0 && duplicate.insertedDocuments == 0 && duplicate.revision == revision)
            let row = try #require(database.read { db in try Row.fetchOne(db, sql: "SELECT * FROM p1_sec_identities") })
            let retained: Data = row["record_json"]
            #expect(retained == legacy && row["record_hash"] == digest(legacy))
            #expect(row["available_at_ms"] == (try MillisecondInstant(rounding: now).milliseconds))
            #expect(try await reopened.sourceDocument(reference: accepted.rawPayload.reference).payload == identityBytes)
        }
    }

    @Test func legacySubmissionDuplicatesAndDateOnlyNormalizationRemainCompatible() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sec-legacy-normalize-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try DatabaseStore(path: path), store = try BusinessDataStore(database: database)
        let client = try client([HTTPPayload(statusCode: 200, mediaType: "application/json", body: submissionBytes),
                                HTTPPayload(statusCode: 200, mediaType: "application/json", body: factBytes)],
                                at: now, capabilities: [.submissions, .companyFacts])
        let submissions = try await client.submissions(request(.submissions, resource: "0000320193", at: now))
        let facts = try await client.companyFacts(request(.companyFacts, resource: "0000320193", at: now))
        try await store.ingestSECSubmissions(submissions, expectedRevision: store.revision())
        try await store.ingestSECCompanyFacts(facts, expectedRevision: store.revision())
        let legacySubmission = try legacyBytes(submissions.exchange.result.items[0])
        try replaceRecord(database, table: "p1_sec_submissions", bytes: legacySubmission, indexedAt: now)
        let fact = facts.exchange.result.items[0], bound = try fact.provenance.availability.upperBound()
        try replaceRecord(database, table: "p1_sec_facts", bytes: legacyBytes(fact), indexedAt: bound)
        let reopened = try BusinessDataStore(path: path)
        let revision = await reopened.revision()
        let duplicate = try await reopened.ingestSECSubmissions(submissions, expectedRevision: revision)
        #expect(duplicate.insertedRecords == 0 && duplicate.insertedDocuments == 0 && duplicate.revision == revision)
        let restored = try await reopened.secSubmissions(cik: "0000320193", asOf: now.addingTimeInterval(1))
        #expect(restored.first?.acceptedAt == now && restored.first?.provenance.sourceEventAt == now)
        let availableFacts = try await reopened.secFactVersions(cik: "0000320193", asOf: bound)
        #expect(availableFacts == [fact]) // Date-only evidence has no unknown submillisecond instant.
        let dictionary = try FinancialFieldDictionary.foundationV1()
        let normalized = try FinancialNormalizer.normalizeComplete(availableFacts, dictionary: dictionary, asOf: bound)
        let receipt = try await reopened.persistNormalization(normalized, dictionary: dictionary, expectedRevision: reopened.revision())
        #expect(try await BusinessDataStore(path: path).normalization(runID: receipt.runID) == normalized)
        let legacyResult = try legacyBytes(normalized)
        try database.transaction { db in
            try db.execute(sql: "UPDATE p1_financial_normalization_runs SET result_json = ?, result_hash = ? WHERE run_id = ?",
                           arguments: [legacyResult, digest(legacyResult), receipt.runID])
        }
        #expect(try await BusinessDataStore(path: path).normalization(runID: receipt.runID) == normalized)
    }
}
