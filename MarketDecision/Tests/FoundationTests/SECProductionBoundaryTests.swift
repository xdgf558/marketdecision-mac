import Foundation
import Testing
import CoreDomain
import DataContracts
import DataProviders
@testable import SECProvider

private actor SECProductionFixtureGate: SECRequestGate {
    private(set) var waits = 0
    func wait() async throws { try Task.checkCancellation(); waits += 1 }
}

private actor SECProductionFixtureTransport: HTTPTransport {
    private let body: Data
    private(set) var sends = 0
    init(_ body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        sends += 1
        return HTTPPayload(statusCode: 200, mediaType: "application/json", body: body)
    }
}

/// A locked monotonic test clock. Each sleep entry and completion is an observable event,
/// so a broken implementation that releases *all* sleepers still reaches the assertion.
private final class SECManualClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct Observer {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    private var sleepers: [Sleeper] = []
    private var observers: [Observer] = []
    private var events = 0
    private var completions = 0
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                sleepers.append(Sleeper(deadline: deadline, continuation: continuation)); events += 1
                return readyObservers()
            }
            ready.forEach { $0.resume() }
        }
    }
    func completed() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            completions += 1; events += 1
            return readyObservers()
        }
        ready.forEach { $0.resume() }
    }
    func waitForEvents(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if events >= count { return true }
                observers.append(Observer(count: count, continuation: continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
    func advance(by duration: Duration) {
        let ready = lock.withLock { () -> [Sleeper] in
            instant = instant.advanced(by: duration)
            let ready = sleepers.filter { $0.deadline <= instant }
            sleepers.removeAll { $0.deadline <= instant }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }
    func snapshot() -> (completions: Int, deadlines: [ContinuousClock.Instant]) {
        lock.withLock { (completions, sleepers.map(\.deadline)) }
    }
    private func readyObservers() -> [CheckedContinuation<Void, Never>] {
        let ready = observers.filter { $0.count <= events }.map(\.continuation)
        observers.removeAll { $0.count <= events }
        return ready
    }
}

private let secBoundaryNow = Date(timeIntervalSince1970: 1_800_000_000)
private func secBoundaryRequest(_ capability: ProviderCapability, resource: String = "0000320193",
                                page: String? = nil) -> ProviderRequest {
    ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: resource,
        capability: capability, mode: .latest, usage: .pitResearch, configurationVersion: "sec-edgar.v1",
        entitlementVersion: "synthetic-sec-boundary.v1", requestedAt: secBoundaryNow, pageToken: page)
}
private func secBoundaryProvider(_ body: Data) throws
    -> (SECEdgarProvider<SECProductionFixtureTransport, SECProductionFixtureGate>, SECProductionFixtureTransport,
        SECProductionFixtureGate) {
    let transport = SECProductionFixtureTransport(body), gate = SECProductionFixtureGate()
    return (try SECEdgarProvider(userAgent: "SyntheticTests/1.0 tests@example.invalid", transport: transport, gate: gate,
        evidenceRef: "synthetic-sec-production-boundary", licenseRef: "synthetic-only",
        now: { secBoundaryNow }), transport, gate)
}
private func secBoundarySubmissions(cikJSON: String? = "320193", accepted: String = "2025-08-01T20:01:02.000Z",
                                    files: [String] = [], topLevel: Bool = false,
                                    form: String = "10-Q", primaryDocument: String = "filing.htm") throws -> Data {
    let columns: [String: Any] = [
        // The accession's first component is allowed to belong to a filing agent, not the issuer.
        "accessionNumber": ["0001193125-25-000079"], "filingDate": ["2025-08-01"], "reportDate": ["2025-06-28"],
        "acceptanceDateTime": [accepted], "form": [form], "primaryDocument": [primaryDocument]
    ]
    var object: [String: Any] = topLevel ? columns : ["filings": ["recent": columns, "files": files.map { ["name": $0] }]]
    if let cikJSON {
        object["cik"] = try JSONSerialization.jsonObject(with: Data(cikJSON.utf8), options: [.fragmentsAllowed])
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func secBoundaryCompanyFacts(labelJSON: String?) throws -> Data {
    let fact: [String: Any] = ["val": 42, "accn": "0001193125-25-000079", "filed": "2025-08-01",
                             "form": "10-Q", "end": "2025-06-30", "fy": 2025, "fp": "Q2"]
    var definition: [String: Any] = ["description": NSNull(), "units": ["USD": [fact]]]
    if let labelJSON {
        definition["label"] = try JSONSerialization.jsonObject(with: Data(labelJSON.utf8), options: [.fragmentsAllowed])
    }
    return try JSONSerialization.data(withJSONObject: ["cik": 320193, "entityName": "Synthetic issuer",
        "facts": ["us-gaap": ["SyntheticMetric": definition]]], options: [.sortedKeys])
}

private func secBoundaryFilingIndex(sizeJSON: String?) throws -> Data {
    var item: [String: Any] = ["name": "filing.htm", "type": "text/html"]
    if let sizeJSON {
        item["size"] = try JSONSerialization.jsonObject(with: Data(sizeJSON.utf8), options: [.fragmentsAllowed])
    }
    return try JSONSerialization.data(withJSONObject: ["directory": ["item": [item]]], options: [.sortedKeys])
}

@Suite struct SECProductionBoundaryTests {
    @Test(arguments: ["123", "\"123\"", "0", "\"0\""])
    func filingIndexAcceptsExactNumericAndDigitStringSizes(size: String) async throws {
        let bytes = try secBoundaryFilingIndex(sizeJSON: size)
        let (provider, _, _) = try secBoundaryProvider(bytes)
        let result = try await provider.filingIndex(request: secBoundaryRequest(.filingIndex,
            resource: "0000320193/0001193125-25-000079"))
        let item = try #require(result.result.items.first?.files.first)
        #expect(item.size == (size.contains("123") ? 123 : 0))
        #expect(result.rawPayload.bytes == bytes)
    }

    @Test(arguments: ["\"\"", "null", "omitted"])
    func filingIndexUnknownSizeIsPreservedAndNeverBecomesZero(size: String) async throws {
        let bytes = try secBoundaryFilingIndex(sizeJSON: size == "omitted" ? nil : size)
        let (provider, _, _) = try secBoundaryProvider(bytes)
        let result = try await provider.filingIndex(request: secBoundaryRequest(.filingIndex,
            resource: "0000320193/0001193125-25-000079"))
        let index = try #require(result.result.items.first)
        #expect(result.result.status == .complete && index.files.count == 1)
        #expect(index.files[0].name == "filing.htm" && index.files[0].size == nil)
        #expect(result.rawPayload.bytes == bytes)
        let (zeroProvider, _, _) = try secBoundaryProvider(secBoundaryFilingIndex(sizeJSON: "0"))
        let zero = try await zeroProvider.filingIndex(request: secBoundaryRequest(.filingIndex,
            resource: "0000320193/0001193125-25-000079"))
        #expect(index.provenance.versionID != zero.result.items[0].provenance.versionID)
    }

    @Test(arguments: ["true", "-1", "1.5", "\"-1\"", "\"+1\"", "\" 1\"", "\"1 \"", "\"1.0\"",
                      "\"1e3\"", "\"9223372036854775808\"", "999999999999999999999", "[]", "{}"])
    func malformedFilingSizesCannotBeRoundedOrCoerced(size: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundaryFilingIndex(sizeJSON: size))
        await #expect(throws: SECAdapterError.malformedResponse) {
            try await provider.filingIndex(request: secBoundaryRequest(.filingIndex,
                resource: "0000320193/0001193125-25-000079"))
        }
    }

    @Test func filingSizeCodableRetainsOldKnownValuesAndNewUnknownValues() throws {
        let old = Data(#"{"name":"filing.htm","type":"text/html","size":123}"#.utf8)
        let known = try JSONDecoder().decode(SECFilingFile.self, from: old)
        #expect(known.size == 123)
        #expect(try JSONDecoder().decode(SECFilingFile.self, from: JSONEncoder().encode(known)) == known)
        let unknown = try SECFilingFile(name: "filing.htm", type: "text/html", size: nil)
        #expect(try JSONDecoder().decode(SECFilingFile.self, from: JSONEncoder().encode(unknown)) == unknown)
        #expect(throws: SECContractError.invalidFiling) { try SECFilingFile(name: "../filing.htm", type: "text/html", size: nil) }
        #expect(throws: SECContractError.invalidFiling) { try SECFilingFile(name: "filing.htm", type: "text/html", size: -1) }
    }

    @Test(arguments: ["null", "omitted"])
    func missingCompanyFactLabelPreservesTheFactWithoutInventingSourceText(label: String) async throws {
        let bytes = try secBoundaryCompanyFacts(labelJSON: label == "omitted" ? nil : label)
        let (provider, _, _) = try secBoundaryProvider(bytes)
        let result = try await provider.companyFacts(request: secBoundaryRequest(.companyFacts))
        let item = try #require(result.result.items.first)
        let expectedValue = try Money("42")
        #expect(result.result.status == .complete && result.result.items.count == 1)
        #expect(item.label.isEmpty && item.description.isEmpty)
        #expect(item.concept == "SyntheticMetric" && item.taxonomy == "us-gaap")
        #expect(item.unit == "USD" && item.sourceValue == "42" && item.value == expectedValue)
        #expect(item.endDate == MarketDate(year: 2025, month: 6, day: 30))
        #expect(item.provenance.rawHash == result.rawPayload.contentHash)
        #expect(result.rawPayload.bytes == bytes)
    }

    @Test(arguments: ["true", "42", "[]", "{}"])
    func nonStringCompanyFactLabelCannotBeCoercedIntoSourceText(label: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundaryCompanyFacts(labelJSON: label))
        await #expect(throws: SECAdapterError.malformedResponse) {
            try await provider.companyFacts(request: secBoundaryRequest(.companyFacts))
        }
    }

    @Test(arguments: ["DEF 14A", "S-8 POS", "SC 13G/A", "SCHEDULE 13G/A"])
    func preservesSpacedFormsAndSafePrimaryRenderingPaths(form: String) async throws {
        let path = "synthetic-render/primary.xml"
        let bytes = try secBoundarySubmissions(form: form, primaryDocument: path)
        let (provider, _, _) = try secBoundaryProvider(bytes)
        let result = try await provider.submissions(request: secBoundaryRequest(.submissions))
        let item = try #require(result.result.items.first)
        #expect(result.result.status == .complete && result.result.items.count == 1)
        #expect(item.form == form && item.primaryDocument == path)
        #expect(item.isAmendment == form.hasSuffix("/A"))
        #expect(result.rawPayload.bytes == bytes)
        let (changed, _, _) = try secBoundaryProvider(secBoundarySubmissions(form: form,
            primaryDocument: "other-render/primary.xml"))
        let revision = try await changed.submissions(request: secBoundaryRequest(.submissions))
        #expect(item.provenance.versionID != revision.result.items[0].provenance.versionID)
    }

    @Test func mixedPagePreservesNonfinancialSubmissionMetadataWithoutFiltering() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: secBoundarySubmissions()) as? [String: Any])
        var filings = try #require(object["filings"] as? [String: Any])
        var recent = try #require(filings["recent"] as? [String: [String]])
        for key in Array(recent.keys) {
            let value = recent[key]![0]
            recent[key]!.append(value)
        }
        recent["accessionNumber"]![1] = "0001193125-25-000080"
        recent["form"]![1] = "DEF 14A"
        recent["primaryDocument"]![1] = "synthetic-render/primary.xml"
        filings["recent"] = recent; object["filings"] = filings
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let (provider, _, _) = try secBoundaryProvider(bytes)
        let result = try await provider.submissions(request: secBoundaryRequest(.submissions))
        #expect(result.result.status == .complete && result.result.items.count == 2)
        #expect(result.result.items.map(\.form) == ["10-Q", "DEF 14A"])
        #expect(result.result.items.map(\.primaryDocument) == ["filing.htm", "synthetic-render/primary.xml"])
        #expect(result.rawPayload.bytes == bytes)
    }

    @Test func missingPrimaryMetadataStaysEmptyButCannotAuthorizeDownload() async throws {
        let bytes = try secBoundarySubmissions(primaryDocument: "")
        let (provider, _, _) = try secBoundaryProvider(bytes)
        let result = try await provider.submissions(request: secBoundaryRequest(.submissions))
        let item = try #require(result.result.items.first)
        #expect(result.result.status == .complete && result.result.items.count == 1)
        #expect(item.primaryDocument.isEmpty && item.form == "10-Q")
        #expect(result.rawPayload.bytes == bytes)
        #expect(!SECSubmissionRecord.validPrimaryDocumentPath(item.primaryDocument))
        #expect(!SECSubmissionRecord.validFileName(item.primaryDocument))
        #expect(throws: SECContractError.invalidFiling) { try SECFilingFile(name: "", type: "text/html", size: 1) }
        let (download, transport, gate) = try secBoundaryProvider(Data())
        await #expect(throws: SECAdapterError.invalidResource) {
            try await download.filingDocument(request: secBoundaryRequest(.filingDocument,
                resource: item.cik + "/" + item.accessionNumber + "/" + item.primaryDocument))
        }
        #expect(await gate.waits == 0)
        #expect(await transport.sends == 0)
    }

    @Test(arguments: ["/primary.xml", "../primary.xml", "render/../primary.xml", "render//primary.xml",
                      "render/./primary.xml", "render\\primary.xml", "render/%2e%2e/primary.xml",
                      "https://example.invalid/primary.xml", "user@host/primary.xml", "render/primary.xml?x=1",
                      "render/primary.xml#part", "render/"])
    func unsafePrimaryReferenceCannotBeNormalizedIntoAValidPath(path: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundarySubmissions(primaryDocument: path))
        await #expect(throws: SECContractError.invalidFiling) {
            try await provider.submissions(request: secBoundaryRequest(.submissions))
        }
    }

    @Test(arguments: [" DEF 14A", "DEF  14A", "DEF 14A ", "DEF\t14A", "DEF\n14A", "10-K/B", "10-K?x",
                      String(repeating: "A", count: 65)])
    func malformedFormsRemainRejectedWithoutTrimmingOrRewriting(form: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundarySubmissions(form: form))
        await #expect(throws: SECContractError.invalidFiling) {
            try await provider.submissions(request: secBoundaryRequest(.submissions))
        }
    }

    @Test func primaryRenderingPathDoesNotRelaxIndexOrDownloadFilenameBoundary() async throws {
        let path = "synthetic-render/primary.xml"
        #expect(SECSubmissionRecord.validPrimaryDocumentPath(path))
        #expect(!SECSubmissionRecord.validFileName(path))
        #expect(throws: SECContractError.invalidFiling) { try SECFilingFile(name: path, type: "text/html", size: 1) }
        let (provider, transport, gate) = try secBoundaryProvider(Data())
        await #expect(throws: SECAdapterError.invalidResource) {
            try await provider.filingDocument(request: secBoundaryRequest(.filingDocument,
                resource: "0000320193/0001193125-25-000079/" + path))
        }
        #expect(await gate.waits == 0)
        #expect(await transport.sends == 0)
    }

    @Test func concurrentAndOverdueRateWaitersCannotShareAGrant() async throws {
        let clock = SECManualClock()
        let limiter = try SECRateLimiter(requestsPerSecond: 10, now: { clock.now() },
            sleepUntil: { try await clock.sleep(until: $0) })
        try await limiter.wait()
        let tasks = (0..<3).map { _ in
            Task { () -> Bool in
                do { try await limiter.wait(); clock.completed(); return true }
                catch { clock.completed(); return false }
            }
        }
        await clock.waitForEvents(3)
        let initial = clock.snapshot()
        #expect(initial.completions == 0 && initial.deadlines.count == 3)
        // Deliberately wake every initial waiter late; only one can receive the current slot.
        clock.advance(by: .seconds(1))
        await clock.waitForEvents(6)
        let first = clock.snapshot()
        #expect(first.completions == 1 && first.deadlines.count == 2)
        #expect(first.deadlines.allSatisfy { $0 == clock.now().advanced(by: .milliseconds(100)) })
        clock.advance(by: .seconds(1))
        // Either requeued or completed, each remaining task contributes an event. The original
        // buggy implementation has already completed all tasks and therefore needs no release.
        if first.deadlines.count == 2 { await clock.waitForEvents(8) }
        clock.advance(by: .seconds(1))
        for task in tasks { #expect(await task.value) }
        #expect(clock.snapshot().completions == 3)
    }

    @Test func rateIntervalRoundsUpAndCancelledWaitDoesNotConsumeNextSlot() async throws {
        let clock = SECManualClock(), start = clock.now()
        let limiter = try SECRateLimiter(requestsPerSecond: 3, now: { clock.now() },
            sleepUntil: { try await clock.sleep(until: $0) })
        try await limiter.wait()
        let cancelled = Task { () -> Bool in
            do { try await limiter.wait(); clock.completed(); return false }
            catch is CancellationError { clock.completed(); return true }
            catch { clock.completed(); return false }
        }
        await clock.waitForEvents(1)
        #expect(clock.snapshot().deadlines == [start.advanced(by: .nanoseconds(333_333_334))])
        cancelled.cancel()
        clock.advance(by: .nanoseconds(333_333_334))
        #expect(await cancelled.value)
        // Cancellation did not advance the deadline: the next caller gets the elapsed slot.
        try await limiter.wait()
        #expect(clock.snapshot().deadlines.isEmpty)
    }

    @Test(arguments: ["320193", "\"0000320193\""])
    func submissionsAcceptStrictNumericOrPaddedStringCIK(cik: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundarySubmissions(cikJSON: cik))
        let result = try await provider.submissions(request: secBoundaryRequest(.submissions))
        #expect(result.result.items.count == 1)
        #expect(result.result.items[0].cik == "0000320193")
        #expect(result.result.items[0].accessionNumber == "0001193125-25-000079")
    }

    @Test(arguments: ["true", "320193.5", "-320193", "10000320193", "\"+320193\"", "0", "null"])
    func malformedSubmissionCIKCannotBeRoundedOrGuessed(cik: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundarySubmissions(cikJSON: cik))
        await #expect(throws: (any Error).self) { try await provider.submissions(request: secBoundaryRequest(.submissions)) }
    }

    @Test func continuationMustMatchRequestIssuerBeforeDispatchAndInResponse() async throws {
        let foreign = "CIK0000789019-submissions-001.json"
        let (provider, transport, gate) = try secBoundaryProvider(secBoundarySubmissions())
        await #expect(throws: SECAdapterError.invalidResource) {
            try await provider.submissions(request: secBoundaryRequest(.submissions, page: foreign))
        }
        #expect(await gate.waits == 0)
        #expect(await transport.sends == 0)
        let (foreignListing, _, _) = try secBoundaryProvider(secBoundarySubmissions(files: [foreign]))
        await #expect(throws: SECAdapterError.malformedResponse) {
            try await foreignListing.submissions(request: secBoundaryRequest(.submissions))
        }
        let (older, _, _) = try secBoundaryProvider(secBoundarySubmissions(cikJSON: nil, topLevel: true))
        let page = try await older.submissions(request: secBoundaryRequest(.submissions,
            page: "CIK0000320193-submissions-001.json"))
        #expect(page.result.items[0].cik == "0000320193")
        await #expect(throws: SECAdapterError.invalidResource) {
            try await older.submissions(request: secBoundaryRequest(.submissions))
        }
    }

    @Test func unrelatedNullExchangeDoesNotPreventExactLookupButSelectedNullIsRejected() async throws {
        let data = Data(#"{"fields":["cik","name","ticker","exchange"],"data":[[789019,"Unlisted fixture","OTHER",null],[320193,"Issuer fixture","AAPL","Nasdaq"]]}"#.utf8)
        let (provider, _, _) = try secBoundaryProvider(data)
        let result = try await provider.companyIdentity(request: secBoundaryRequest(.companyIdentity, resource: "AAPL"))
        #expect(result.result.items.count == 1 && result.result.items[0].cik == "0000320193")
        await #expect(throws: SECAdapterError.incompleteColumns) {
            try await provider.companyIdentity(request: secBoundaryRequest(.companyIdentity, resource: "OTHER"))
        }
    }

    @Test(arguments: [
        #"[[320193,"Issuer","AAPL","Nasdaq"],[789019,"Other issuer","AAPL","Nasdaq"]]"#,
        #"[[320193,"Issuer","AAPL","Nasdaq"],[320193,"Issuer","AAPL","NYSE"]]"#,
        #"[[320193,"Issuer","AAPL","Nasdaq"],[320193,"Conflicting name","AAPL","Nasdaq"]]"#,
        #"[[320193.5,"Issuer","AAPL","Nasdaq"]]"#,
        #"[[true,"Issuer","AAPL","Nasdaq"]]"#
    ])
    func ambiguousOrNonintegralIdentityNeverSelectsAnIssuer(rows: String) async throws {
        let data = Data((#"{"fields":["cik","name","ticker","exchange"],"data":"# + rows + "}").utf8)
        let (provider, _, _) = try secBoundaryProvider(data)
        await #expect(throws: (any Error).self) {
            try await provider.companyIdentity(request: secBoundaryRequest(.companyIdentity, resource: "AAPL"))
        }
    }

    @Test func acceptanceFractionSurvivesParsingAndDistinctSourceTokensKeepDistinctVersions() async throws {
        let (first, _, _) = try secBoundaryProvider(secBoundarySubmissions(accepted: "2025-08-01T20:01:02.000100Z"))
        let (second, _, _) = try secBoundaryProvider(secBoundarySubmissions(accepted: "2025-08-01T20:01:02.000400Z"))
        let left = try #require(try await first.submissions(request: secBoundaryRequest(.submissions)).result.items.first)
        let right = try #require(try await second.submissions(request: secBoundaryRequest(.submissions)).result.items.first)
        let a = try #require(left.acceptedAt), b = try #require(right.acceptedAt)
        #expect(a < b)
        #expect(try MillisecondInstant(rounding: a) == MillisecondInstant(rounding: b))
        #expect(left.provenance.versionID != right.provenance.versionID)
        #expect(left.provenance.sourceEventAt == a && right.provenance.sourceEventAt == b)
        #expect(try left.provenance.availability.upperBound() == a)
        #expect(try right.provenance.availability.upperBound() == b)
        // Even below Foundation Date resolution, an altered source token is a distinct revision.
        let (fineA, _, _) = try secBoundaryProvider(secBoundarySubmissions(accepted: "2025-08-01T20:01:02.000000001Z"))
        let (fineB, _, _) = try secBoundaryProvider(secBoundarySubmissions(accepted: "2025-08-01T20:01:02.000000002Z"))
        let fa = try await fineA.submissions(request: secBoundaryRequest(.submissions))
        let fb = try await fineB.submissions(request: secBoundaryRequest(.submissions))
        #expect(fa.result.items[0].provenance.versionID != fb.result.items[0].provenance.versionID)
    }

    @Test(arguments: ["2025-02-30T20:01:02Z", "2025-08-01T24:01:02Z", "2025-08-01T20:01:02",
                      "2025-08-01T20:01:02.0000000001Z", "2025-08-01T20:01:02+24:00"])
    func malformedAcceptanceTimeIsNotSilentlyNormalized(accepted: String) async throws {
        let (provider, _, _) = try secBoundaryProvider(secBoundarySubmissions(accepted: accepted))
        await #expect(throws: SECAdapterError.malformedResponse) {
            try await provider.submissions(request: secBoundaryRequest(.submissions))
        }
    }
}
