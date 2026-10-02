import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import DataProviders
@testable import MarketDataProviders
@testable import Persistence

private func equityDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private let equityNow = equityDate("2026-09-18T15:00:00Z")
private let dailyTime = "2026-09-17T04:00:00Z"
private let quoteJSON = #"{"symbol":"AAPL","quote":{"t":"2026-09-18T14:59:59.123456789Z","bp":123.1234567890123456789,"ap":124.01,"bs":10,"as":20,"bx":"V","ax":"V"}}"#
private let barsJSON = #"{"symbol":"AAPL","bars":[{"t":"2026-09-17T04:00:00Z","o":100.1,"h":110,"l":99.9,"c":105.1234567890123456789,"v":123456,"n":100,"vw":103.5}],"next_page_token":null}"#
private func equityPayload(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPPayload {
    HTTPPayload(statusCode: status, mediaType: "application/json", headers: headers, body: Data(text.utf8))
}
private final class FixtureEquityClock: EquityRequestClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var waits: [TimeInterval] = []
    func now() -> Date { equityNow.addingTimeInterval(uptime()) }
    func uptime() -> TimeInterval { lock.withLock { elapsed } }
    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation(); lock.withLock { elapsed += seconds; waits.append(seconds) }
    }
    func delays() -> [TimeInterval] { lock.withLock { waits } }
}
private actor EquityFixtureTransport: HTTPTransport {
    var responses: [HTTPPayload]
    private var requests: [URLRequest] = []
    init(_ responses: [HTTPPayload]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        requests.append(request)
        guard !responses.isEmpty else { throw ProviderFailure.offline }
        return responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}
private func equityRequest(_ capability: ProviderCapability = .quote, feed: String = "iex", version: String = AlpacaIEXProvider.configurationVersion,
                           mode: QueryMode = .latest, range: DateRange? = nil, token: String? = nil) -> ProviderRequest {
    let window = range ?? (capability == .bars ? .init(start: equityDate("2026-09-16T04:00:00Z"), end: equityDate("2026-09-18T03:59:59Z")) : nil)
    return ProviderRequest(providerID: "alpaca", feedID: feed, resourceID: "AAPL", capability: capability, mode: mode,
        range: window.map(DataWindow.sourceEvents), usage: .liveAnalysis, configurationVersion: version,
        entitlementVersion: "synthetic-rights.v1", requestedAt: equityNow, pageToken: token)
}
private func equityRights() -> EntitlementSnapshot {
    EntitlementSnapshot(providerID: "alpaca", feedID: "iex", version: "synthetic-rights.v1", evidenceRef: "synthetic-rights",
        licenseRef: "synthetic-license", capabilities: [.quote, .bars], usages: [.liveAnalysis],
        validFrom: equityNow.addingTimeInterval(-86400), validThrough: equityNow.addingTimeInterval(86400))
}
private func equityProvider(_ transport: any HTTPTransport, clock: any EquityRequestClock = FixtureEquityClock()) throws -> AlpacaIEXProvider {
    try AlpacaIEXProvider(apiKey: Data("SYNTHETIC_KEY".utf8), secret: Data("SYNTHETIC_SECRET".utf8),
        evidenceRef: "synthetic-evidence", licenseRef: "synthetic-license", transport: transport, clock: clock)
}
private func equityAccepted(_ json: String, request: ProviderRequest = equityRequest(.bars)) async throws -> AcceptedProviderPayload<EquityRecord> {
    let provider = try equityProvider(EquityFixtureTransport([equityPayload(json)]))
    return try await EquityDataClient(provider: provider, entitlement: equityRights()).fetch(request)
}
private actor LateEquityTransport: HTTPTransport {
    var started = false
    var onStart: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<HTTPPayload, Never>?
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        started = true; onStart?.resume(); onStart = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForStart() async { if !started { await withCheckedContinuation { onStart = $0 } } }
    func release() { pending?.resume(returning: equityPayload(quoteJSON)); pending = nil }
}
private actor EquitySleepGate {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitForSleep() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func release() { pending?.resume(); pending = nil }
}
private struct PausedEquityClock: EquityRequestClock {
    let gate: EquitySleepGate
    func now() -> Date { equityNow }
    func uptime() -> TimeInterval { 0 }
    func sleep(seconds: TimeInterval) async throws { await gate.pause(); try Task.checkCancellation() }
}
private struct IncorrectRawEquityProvider: EquityDataProvider {
    let response: ProviderPayloadResponse<EquityRecord>
    let id = "alpaca"
    let capabilitySnapshot = CapabilitySnapshot(providerID: "alpaca", version: AlpacaIEXProvider.configurationVersion,
                                                feeds: ["iex"], capabilities: [.quote, .bars])
    func quote(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord> { response }
    func dailyBars(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord> { response }
}

@Suite struct PhaseOneEquityProviderTests {
    @Test func exactQuoteRetainsSourceAndNeverGrantsAnalysisQualification() async throws {
        let transport = EquityFixtureTransport([equityPayload(quoteJSON)])
        let client = EquityDataClient(provider: try equityProvider(transport), entitlement: equityRights())
        let accepted = try await client.fetch(equityRequest())
        let item = try #require(accepted.exchange.result.items.first)
        #expect(item.quote?.bid.decimalString == "123.1234567890123456789")
        #expect(item.sourceTimestamp == "2026-09-18T14:59:59.123456789Z")
        #expect(item.provenance.rawHash == digest(Data(quoteJSON.utf8)))
        #expect(item.coverage.contains("not consolidated NBBO"))
        #expect(item.timeliness == .realtime && item.quality(at: equityNow).isEmpty)
        #expect(!item.provenance.isAvailable(asOf: equityNow))
        #expect(try item.displayQuote(at: equityNow).qualifiedUsages.isEmpty)
        #expect(item.quality(at: equityNow.addingTimeInterval(120)).contains(.stale))
        let request = try #require(await transport.captured().first)
        #expect(request.url?.host == "data.alpaca.markets")
        #expect(request.url?.query == "feed=iex&currency=USD")
        #expect(request.value(forHTTPHeaderField: "APCA-API-KEY-ID") == "SYNTHETIC_KEY")
        #expect(request.value(forHTTPHeaderField: "APCA-API-SECRET-KEY") == "SYNTHETIC_SECRET")
        #expect(!accepted.rawPayload.bytes.contains(Data("SYNTHETIC_SECRET".utf8)))
    }
    @Test func barsPinRawFeedCurrencySymbolMappingAndPreservePageBoundary() async throws {
        let transport = EquityFixtureTransport([equityPayload(barsJSON.replacingOccurrences(of: "null", with: "\"next+/=\""))])
        let result = try await EquityDataClient(provider: equityProvider(transport), entitlement: equityRights()).fetch(equityRequest(.bars))
        #expect(result.exchange.result.status == .partial)
        #expect(result.continuationTokens == ["next+/="])
        let item = try #require(result.exchange.result.items.first)
        #expect(item.bar?.close.decimalString == "105.1234567890123456789")
        #expect(item.adjustment == "raw" && item.timeliness == .endOfDay)
        let url = try #require(await transport.captured().first?.url)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(query["feed"] == "iex" && query["asof"] == "-" && query["adjustment"] == "raw")
        #expect(query["timeframe"] == "1Day" && query["currency"] == "USD" && query["sort"] == "asc")
    }
    @Test func configurationRightsFeedAndPITFailBeforeAnyHTTPCall() async throws {
        let transport = EquityFixtureTransport([]), provider = try equityProvider(transport)
        let client = EquityDataClient(provider: provider, entitlement: equityRights())
        for request in [equityRequest(version: "wrong"), equityRequest(feed: "sip"),
                        equityRequest(.bars, mode: .asOf(equityNow))] {
            await #expect(throws: (any Error).self) { try await client.fetch(request) }
        }
        await #expect(throws: ProviderFailure.notEntitled) {
            try await EquityDataClient(provider: provider, entitlement: nil).fetch(equityRequest())
        }
        #expect(await transport.captured().isEmpty)
    }
    @Test func currentDayFutureAndOverlongBarWindowsDoNotDispatch() async throws {
        let transport = EquityFixtureTransport([]), client = EquityDataClient(provider: try equityProvider(transport), entitlement: equityRights())
        for range in [DateRange(start: equityNow, end: equityNow),
                      .init(start: equityDate("2024-01-01T00:00:00Z"), end: equityDate("2026-01-01T00:00:00Z"))] {
            await #expect(throws: ContractError.invalidRange) { try await client.fetch(equityRequest(.bars, range: range)) }
        }
        #expect(await transport.captured().isEmpty)
    }
    @Test func emptyPartialAndErrorRemainDistinct() async throws {
        let empty = try await equityAccepted(#"{"symbol":"AAPL","bars":[],"next_page_token":null}"#)
        #expect(empty.exchange.result.status == .empty && empty.exchange.result.emptyReason == .noResults)
        let partial = try await equityAccepted(#"{"symbol":"AAPL","bars":null,"next_page_token":"next"}"#)
        #expect(partial.exchange.result.status == .partial && partial.exchange.result.emptyReason == nil)
        let noQuote = try await equityAccepted(#"{"symbol":"AAPL","quote":null}"#, request: equityRequest())
        #expect(noQuote.exchange.result.status == .empty)
        for body in [#"{"message":"rate limit exceeded"}"#, #"{"symbol":"AAPL"}"#] {
            await #expect(throws: ProviderFailure.malformedResponse) { try await equityAccepted(body) }
        }
    }
    @Test func exactNumericLexerRejectsPrecisionLossStringsDuplicatesAndMalformedJSON() async throws {
        let object = try #require(MarketJSON.parse(Data(#"{"small":1e-18,"large":1.234e3,"zero":-0.0}"#.utf8)).object)
        #expect(try object["small"]?.money().decimalString == "0.000000000000000001")
        #expect(try object["large"]?.money().decimalString == "1234")
        #expect(try object["zero"]?.money().decimalString == "0")
        for value in ["123.123456789012345678901234567890123456789", "1e9999", "\"1.23\"", "true"] {
            await #expect(throws: ProviderFailure.malformedResponse) {
                try await equityAccepted(quoteJSON.replacingOccurrences(of: "123.1234567890123456789", with: value), request: equityRequest())
            }
        }
        for body in [#"{"bp":1,"bp":2}"#, #"{"bp":01}"#, #"[1,]"#, #"{"a":1,}"#, #"{"a":"\uD800"}"#, #"null false"#] {
            #expect(throws: ProviderFailure.malformedResponse) { try MarketJSON.parse(Data(body.utf8)) }
        }
    }
    @Test func badSymbolFeedExchangeTimesAndOHLCNeverProduceUsableRecords() async throws {
        for body in [barsJSON.replacingOccurrences(of: "AAPL", with: "MSFT"),
                     barsJSON.replacingOccurrences(of: #""h":110"#, with: #""h":99"#),
                     barsJSON.replacingOccurrences(of: dailyTime, with: "2026-09-17T05:00:00Z"),
                     barsJSON.replacingOccurrences(of: dailyTime, with: "2026-09-19T04:00:00Z"),
                     barsJSON.replacingOccurrences(of: dailyTime, with: "2026-09-01T04:00:00Z")] {
            await #expect(throws: (any Error).self) { try await equityAccepted(body) }
        }
        await #expect(throws: (any Error).self) {
            try await equityAccepted(quoteJSON.replacingOccurrences(of: #""bx":"V""#, with: #""bx":"Q""#), request: equityRequest())
        }
        await #expect(throws: (any Error).self) {
            try await equityAccepted(quoteJSON.replacingOccurrences(of: "14:59:59", with: "15:10:59"), request: equityRequest())
        }
    }
    @Test func zeroAndCrossedQuoteAreRetainedAsInvalidNotMadeIntoMissingOrGoodPrices() async throws {
        for bid in ["0", "200"] {
            let result = try await equityAccepted(quoteJSON.replacingOccurrences(of: "123.1234567890123456789", with: bid), request: equityRequest())
            let item = try #require(result.exchange.result.items.first)
            #expect(item.quote?.bid.decimalString == bid && item.quality(at: equityNow).contains(.invalid))
        }
    }
    @Test func paginationRejectsSameTokenDuplicatesAndMissingTokenField() async throws {
        await #expect(throws: ContractError.invalidCoverage) {
            try await equityAccepted(barsJSON.replacingOccurrences(of: "null", with: "\"repeat\""), request: equityRequest(.bars, token: "repeat"))
        }
        let duplicated = barsJSON.replacingOccurrences(of: "}],", with: #"},{"t":"2026-09-17T04:00:00Z","o":100,"h":110,"l":99,"c":105,"v":1}],"#)
        await #expect(throws: (any Error).self) { try await equityAccepted(duplicated) }
        await #expect(throws: ProviderFailure.malformedResponse) {
            try await equityAccepted(#"{"symbol":"AAPL","bars":[]}"#)
        }
    }
    @Test func rateLimitHonorsServerResetAndUsesSameFeedOnRetry() async throws {
        let clock = FixtureEquityClock()
        let transport = EquityFixtureTransport([equityPayload("{}", status: 429,
            headers: ["Retry-After": "2", "X-RateLimit-Reset": String(Int(equityNow.timeIntervalSince1970 + 4))]), equityPayload(quoteJSON)])
        let client = EquityDataClient(provider: try equityProvider(transport, clock: clock), entitlement: equityRights())
        _ = try await client.fetch(equityRequest())
        #expect(clock.delays() == [4])
        let requests = await transport.captured()
        #expect(requests.count == 2 && requests[0].url == requests[1].url)
    }
    @Test func retryBudgetNeverShortensServerWaitOrRetriesAuthAndEntitlementErrors() async throws {
        for status in [401, 403, 404, 429] {
            let transport = EquityFixtureTransport([equityPayload("{}", status: status, headers: ["Retry-After": "300"]), equityPayload(quoteJSON)])
            let clock = FixtureEquityClock(), provider = try equityProvider(transport, clock: clock)
            let expected: ProviderFailure = status == 401 ? .authInvalid : status == 403 ? .notEntitled : status == 404 ? .symbolUnavailable : .rateLimited
            await #expect(throws: expected) { try await EquityDataClient(provider: provider, entitlement: equityRights()).fetch(equityRequest()) }
            #expect(await transport.captured().count == 1 && clock.delays().isEmpty)
        }
        let transport = EquityFixtureTransport(Array(repeating: equityPayload("{}", status: 503), count: 4))
        let clock = FixtureEquityClock(), provider = try equityProvider(transport, clock: clock)
        await #expect(throws: ProviderFailure.offline) { try await EquityDataClient(provider: provider, entitlement: equityRights()).fetch(equityRequest()) }
        #expect(await transport.captured().count == 3 && clock.delays() == [1, 2])
    }
    @Test func serverDateRetryAndSharedSpacingApplyToSeparateCalls() async throws {
        let clock = FixtureEquityClock()
        let transport = EquityFixtureTransport([equityPayload("{}", status: 429, headers: ["Retry-After": "Fri, 18 Sep 2026 15:00:02 GMT"]),
                                                 equityPayload(quoteJSON), equityPayload(quoteJSON)])
        let provider = try equityProvider(transport, clock: clock)
        let client = EquityDataClient(provider: provider, entitlement: equityRights())
        _ = try await client.fetch(equityRequest()); _ = try await client.fetch(equityRequest())
        #expect(clock.delays().count == 2 && abs(clock.delays()[0] - 2) < 0.001 && abs(clock.delays()[1] - 0.35) < 0.001)
    }
    @Test func cancellationDiscardsAResponseFromTransportThatIgnoresCancel() async throws {
        let transport = LateEquityTransport()
        let client = EquityDataClient(provider: try equityProvider(transport), entitlement: equityRights())
        let task = Task { try await client.fetch(equityRequest()) }
        await transport.waitForStart(); task.cancel(); await transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func malformedHeadersAndWrongMediaFailClosed() async throws {
        for response in [equityPayload("{}", status: 429, headers: ["Retry-After": "not-a-date"]),
                         HTTPPayload(statusCode: 200, mediaType: "text/html", body: Data(quoteJSON.utf8))] {
            let transport = EquityFixtureTransport([response, equityPayload(quoteJSON)])
            let client = EquityDataClient(provider: try equityProvider(transport), entitlement: equityRights())
            await #expect(throws: (any Error).self) { try await client.fetch(equityRequest()) }
            #expect(await transport.captured().count == 1)
        }
    }
    @Test func cancellationDuringBackoffMakesNoSecondRequest() async throws {
        let gate = EquitySleepGate(), transport = EquityFixtureTransport([equityPayload("{}", status: 429), equityPayload(quoteJSON)])
        let client = EquityDataClient(provider: try equityProvider(transport, clock: PausedEquityClock(gate: gate)), entitlement: equityRights())
        let task = Task { try await client.fetch(equityRequest()) }
        await gate.waitForSleep(); task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.captured().count == 1)
    }
    @Test func substitutedRawBytesAndOldRequestCannotBecomeAcceptedForPersistence() async throws {
        let request = equityRequest()
        let response = try await equityProvider(EquityFixtureTransport([equityPayload(quoteJSON)])).quote(request: request)
        let wrongRaw = try ProviderRawPayload(reference: response.rawPayload.reference, mediaType: "application/json",
            bytes: Data("{}".utf8), storageAvailableAt: equityNow, evidenceRef: "synthetic-evidence", licenseRef: "synthetic-license")
        let incorrect = IncorrectRawEquityProvider(response: .init(result: response.result, rawPayload: wrongRaw))
        await #expect(throws: ContractError.mismatchedSource) {
            try await EquityDataClient(provider: incorrect, entitlement: equityRights()).fetch(request)
        }
        let oldRequest = IncorrectRawEquityProvider(response: response)
        await #expect(throws: ContractError.mismatchedRequest) {
            try await EquityDataClient(provider: oldRequest, entitlement: equityRights()).fetch(equityRequest())
        }
    }
    @Test func quoteSizesRequireWholeRoundLotsWithoutRoundingOrShareConversion() async throws {
        for field in ["bs", "as"] {
            let original = field == "bs" ? "10" : "20"
            for size in ["0.5", "0.75", "-0.5"] {
                let json = quoteJSON.replacingOccurrences(of: "\"" + field + "\":" + original,
                                                         with: "\"" + field + "\":" + size)
                await #expect(throws: ContractError.invalidNormalization) {
                    try await equityAccepted(json, request: equityRequest())
                }
            }
        }
        for size in ["0", "10", "10.0", "1e1"] {
            let json = quoteJSON.replacingOccurrences(of: "\"bs\":10", with: "\"bs\":" + size)
            let accepted = try await equityAccepted(json, request: equityRequest())
            let item = try #require(accepted.exchange.result.items.first)
            #expect(item.quote?.sizeUnit == "round lots")
            #expect(item.quote?.bidSize.decimalString == (size == "0" ? "0" : "10"))
            #expect(item.quality(at: equityNow).contains(.invalid) == (size == "0"))
        }
    }
    @Test func timestampRoundingIsExactAndWinterDailyBarsUseNewYorkMidnight() async throws {
        #expect(try MillisecondInstant(rounding: EquityRecord.sourceTime("2026-09-18T15:00:00.122500000Z")).iso8601 == "2026-09-18T15:00:00.122Z")
        #expect(try MillisecondInstant(rounding: EquityRecord.sourceTime("2026-09-18T15:00:00.123500000Z")).iso8601 == "2026-09-18T15:00:00.124Z")
        #expect(throws: (any Error).self) { try EquityRecord.sourceTime("2026-02-30T15:00:00Z") }
        let window = DateRange(start: equityDate("2026-02-02T00:00:00Z"), end: equityDate("2026-02-03T00:00:00Z"))
        let result = try await equityAccepted(barsJSON.replacingOccurrences(of: dailyTime, with: "2026-02-02T05:00:00Z"), request: equityRequest(.bars, range: window))
        #expect(result.exchange.result.items.count == 1)
        await #expect(throws: ContractError.invalidNormalization) {
            try await equityAccepted(barsJSON.replacingOccurrences(of: dailyTime, with: "2026-02-02T04:00:00Z"), request: equityRequest(.bars, range: window))
        }
    }
}

@Suite struct PhaseOneEquityPersistenceTests {
    @Test func emptyOfflineStoreReportsMissingInputsWithoutProducingAResearchPrice() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("empty-evidence-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let audit = try await OfflineResearchEvidenceReader(store: BusinessDataStore(path: path)).inspect(
            symbol: "AAPL", cutoff: equityNow,
            barWindow: .init(start: equityDate("2026-09-16T00:00:00Z"), end: equityNow),
            dictionary: .foundationV1())
        #expect(audit.identity == nil && audit.normalization == nil)
        #expect(audit.sourceHashes.isEmpty && audit.dailyBarCount == 0)
        #expect(audit.gaps.contains(.missingIdentity))
        #expect(audit.gaps.contains(.missingFinancialFacts))
        #expect(audit.gaps.contains(.missingDailyBar))
        #expect(!audit.mayRunValuation)
    }

    @Test func acquisitionPipelineRetainsUnknownAvailabilityInOfflineEvidence() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("equity-pipeline-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BusinessDataStore(path: path)
        let transport = EquityFixtureTransport([equityPayload(barsJSON)])
        let pipeline = EquityAcquisitionPipeline(client: EquityDataClient(
            provider: try equityProvider(transport), entitlement: equityRights()), store: store)
        let receipt = try await pipeline.ingest(equityRequest(.bars))
        #expect(receipt.status == .complete && receipt.itemCount == 1)
        #expect(receipt.insertedDocuments == 1 && receipt.insertedRecords == 1)
        let audit = try await OfflineResearchEvidenceReader(store: store).inspect(symbol: "AAPL",
            cutoff: equityNow, barWindow: .init(start: equityDate("2026-09-16T00:00:00Z"), end: equityNow),
            dictionary: .foundationV1())
        #expect(audit.identity == nil && audit.normalization == nil)
        #expect(audit.dailyBarCount == 1)
        #expect(audit.gaps.contains(.missingIdentity))
        #expect(audit.gaps.contains(.unqualifiedDailyBar))
        #expect(!audit.mayRunValuation)
        #expect(audit.sourceHashes.count == 1)
        #expect(await transport.captured().count == 1)
    }

    @Test func acceptedRawTypedAndPartialPageSurviveRestartWithoutPITPromotion() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("equity-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try BusinessDataStore(path: path)
        let json = barsJSON.replacingOccurrences(of: "null", with: "\"page-2\"")
        let accepted = try await equityAccepted(json)
        let receipt = try await store.ingestEquity(accepted, expectedRevision: store.revision())
        #expect(receipt.insertedDocuments == 1 && receipt.insertedRecords == 1 && receipt.insertedPages == 1)
        let reopened = try BusinessDataStore(path: path)
        let values = try await reopened.equityRecords(symbol: "AAPL", kind: .dailyBar,
            range: .init(start: equityDate("2026-09-01T00:00:00Z"), end: equityNow))
        let item = try #require(values.first)
        #expect(item.bar?.close.decimalString == "105.1234567890123456789")
        #expect(!item.provenance.isAvailable(asOf: equityNow))
        #expect(try await reopened.sourceDocument(reference: accepted.rawPayload.reference).payload == Data(json.utf8))
        let page = try #require(await reopened.equityPages(symbol: "AAPL").first)
        #expect(page.status == ProviderResultStatus.partial.rawValue && page.nextPageToken == "page-2")
    }
    @Test func repeatRetrievalIsNoopAndRevisedBarsRemainSeparateVersions() async throws {
        let store = try BusinessDataStore(path: ":memory:")
        let first = try await equityAccepted(barsJSON)
        let receipt = try await store.ingestEquity(first, expectedRevision: store.revision())
        let duplicate = try await equityAccepted(barsJSON)
        let again = try await store.ingestEquity(duplicate, expectedRevision: store.revision())
        #expect(again.insertedDocuments == 0 && again.insertedRecords == 0 && again.insertedPages == 0 && again.revision == receipt.revision)
        let changed = try await equityAccepted(barsJSON.replacingOccurrences(of: "105.1234567890123456789", with: "106.01"))
        _ = try await store.ingestEquity(changed, expectedRevision: store.revision())
        let values = try await store.equityRecords(symbol: "AAPL", kind: .dailyBar,
            range: .init(start: equityDate("2026-09-01T00:00:00Z"), end: equityNow))
        #expect(values.count == 2 && Set(values.map { $0.contentVersion() }).count == 2)
    }
    @Test func SQLiteFailureRollsBackRawAndTypedAndSameAcceptedPageCanRetry() async throws {
        let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
        let accepted = try await equityAccepted(barsJSON), revision = await store.revision()
        try database.transaction { db in
            try db.execute(sql: "CREATE TRIGGER synthetic_fail_page BEFORE INSERT ON p1_equity_pages BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        await #expect(throws: (any Error).self) { try await store.ingestEquity(accepted, expectedRevision: revision) }
        #expect(await store.revision() == revision)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_equity_records") } == 0)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 0)
        try database.transaction { try $0.execute(sql: "DROP TRIGGER synthetic_fail_page") }
        #expect(try await store.ingestEquity(accepted, expectedRevision: revision).insertedRecords == 1)
    }
    @Test func staleRevisionAndCachePurgeCannotDamageStoredMarketSources() async throws {
        let store = try BusinessDataStore(path: ":memory:")
        let first = try await equityAccepted(barsJSON), old = await store.revision()
        _ = try await store.ingestEquity(first, expectedRevision: old)
        let second = try await equityAccepted(quoteJSON, request: equityRequest())
        await #expect(throws: SnapshotError.stalePlan) { try await store.ingestEquity(second, expectedRevision: old) }
        let purge = try await store.purgeCache(seriesIDs: ["unused-series"], expectedRevision: store.revision())
        #expect(purge.removedDocuments == 0)
        #expect(try await store.sourceDocument(reference: first.rawPayload.reference).payload == Data(barsJSON.utf8))
    }
    @Test func corruptedTypedOrRawBytesFailInsteadOfReturningPartialMarketHistory() async throws {
        for raw in [true, false] {
            let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
            let accepted = try await equityAccepted(barsJSON)
            _ = try await store.ingestEquity(accepted, expectedRevision: store.revision())
            try database.transaction { db in
                try db.execute(sql: raw ? "UPDATE p1_source_documents SET payload = X'00'" : "UPDATE p1_equity_records SET record_json = X'00'")
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) {
                try await store.equityRecords(symbol: "AAPL", kind: .dailyBar, range: .init(start: equityDate("2026-09-01T00:00:00Z"), end: equityNow))
            }
        }
    }
    @Test func migrationFromSECFoundationKeepsExistingRows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("equity-upgrade-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Recreate the exact predecessor catalog: v4 adds only these two empty tables/index.
        do {
            let prior = try DatabaseStore(path: path)
            try prior.transaction { db in
                try db.execute(sql:"DROP TABLE p1_watchlist_conflicts")
                try db.execute(sql:"DELETE FROM grdb_migrations WHERE identifier = 'business.p1.v6'")
                try db.execute(sql: "DROP TABLE p1_watchlist")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'business.p1.v5'")
                try db.execute(sql: "DROP TABLE p1_equity_pages")
                try db.execute(sql: "DROP TABLE p1_equity_records")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'business.p1.v4'")
                try db.execute(sql: "CREATE TABLE synthetic_prior_row (value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO synthetic_prior_row VALUES ('preserve')")
                try db.execute(sql: "INSERT INTO p1_financial_dictionaries VALUES ('synthetic.v1', ?, X'5B5D')", arguments: [digest(Data("[]".utf8))])
            }
        }
        let upgraded = try DatabaseStore(path: path)
        #expect(try upgraded.read { try String.fetchOne($0, sql: "SELECT value FROM synthetic_prior_row") } == "preserve")
        #expect(try upgraded.read { try String.fetchOne($0, sql: "SELECT version FROM p1_financial_dictionaries") } == "synthetic.v1")
        #expect(try upgraded.migrationVersions().contains("business.p1.v4"))
    }
    @Test func corruptedPageOrMissingRecordCannotMasqueradeAsSuccessfulDuplicate() async throws {
        for missing in [true, false] {
            let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
            let accepted = try await equityAccepted(barsJSON)
            _ = try await store.ingestEquity(accepted, expectedRevision: store.revision())
            try database.transaction { db in
                try db.execute(sql: missing ? "DELETE FROM p1_equity_records" : "UPDATE p1_equity_pages SET page_hash = ?",
                               arguments: missing ? [] : [String(repeating: "0", count: 64)])
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.equityPages(symbol: "AAPL") }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.ingestEquity(accepted, expectedRevision: store.revision()) }
        }
    }
    @Test func recordColumnCorruptionFailsReadsPagesAndBothDeduplicationPaths() async throws {
        for column in ["source_reference", "received_at_ms", "source_event_ms", "kind", "symbol"] {
            let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
            let bars = try await equityAccepted(barsJSON)
            let quote = try await equityAccepted(quoteJSON, request: equityRequest())
            _ = try await store.ingestEquity(bars, expectedRevision: store.revision())
            _ = try await store.ingestEquity(quote, expectedRevision: store.revision())
            let revision = await store.revision()
            let freshPage = try await equityAccepted(barsJSON + "\n")
            try database.transaction { db in
                switch column {
                case "source_reference":
                    try db.execute(sql: "UPDATE p1_equity_records SET source_reference = ? WHERE kind = 'dailyBar'", arguments: [quote.rawPayload.reference])
                case "received_at_ms", "source_event_ms":
                    try db.execute(sql: "UPDATE p1_equity_records SET \(column) = \(column) + 1 WHERE kind = 'dailyBar'")
                case "kind": try db.execute(sql: "UPDATE p1_equity_records SET kind = 'quote' WHERE kind = 'dailyBar'")
                default: try db.execute(sql: "UPDATE p1_equity_records SET symbol = 'MSFT' WHERE kind = 'dailyBar'")
                }
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) {
                try await store.equityRecords(symbol: column == "symbol" ? "MSFT" : "AAPL",
                    kind: column == "kind" ? .quote : .dailyBar,
                    range: .init(start: equityDate("2026-09-01T00:00:00Z"), end: equityNow))
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.equityPages(symbol: "AAPL") }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.ingestEquity(bars, expectedRevision: revision) }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.ingestEquity(freshPage, expectedRevision: revision) }
            #expect(await store.revision() == revision)
            #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 2)
            #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_equity_pages") } == 2)
        }
    }
    @Test func distinctPagesReuseContentButValidateTheRecordsOriginalSource() async throws {
        let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
        let first = try await equityAccepted(barsJSON)
        let second = try await equityAccepted(barsJSON + "\n")
        _ = try await store.ingestEquity(first, expectedRevision: store.revision())
        let receipt = try await store.ingestEquity(second, expectedRevision: store.revision())
        #expect(receipt.insertedRecords == 0 && receipt.insertedDocuments == 1 && receipt.insertedPages == 1)
        #expect(try await store.equityPages(symbol: "AAPL").count == 2)
        let records = try await store.equityRecords(symbol: "AAPL", kind: .dailyBar,
            range: .init(start: equityDate("2026-09-01T00:00:00Z"), end: equityNow))
        #expect(records.count == 1 && records.first?.provenance.rawObjectRef == first.rawPayload.reference)
        let duplicate = try await store.ingestEquity(second, expectedRevision: receipt.revision)
        #expect(duplicate.insertedRecords == 0 && duplicate.insertedPages == 0 && duplicate.revision == receipt.revision)
        try database.transaction { db in
            try db.execute(sql: "UPDATE p1_source_documents SET payload = X'00' WHERE reference = ?", arguments: [first.rawPayload.reference])
        }
        // The second page's own source is intact; its shared record still depends on the first source.
        #expect(try await store.sourceDocument(reference: second.rawPayload.reference).payload == Data((barsJSON + "\n").utf8))
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.ingestEquity(second, expectedRevision: receipt.revision) }
        let third = try await equityAccepted(barsJSON + "\n\n")
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.ingestEquity(third, expectedRevision: receipt.revision) }
        #expect(await store.revision() == receipt.revision)
    }

}
