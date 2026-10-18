import Foundation
import Testing
import CoreDomain
import DataContracts
import DataProviders
import MarketDataProviders

@Suite("Candidate option chain collection")
struct OptionChainProviderTests {
    @Test func fullSyntheticHTTPCollectionRetainsSourcesAndNoEligibility() async throws {
        let capture = try await OptionChainSyntheticCollection.capture()
        try capture.validate()
        #expect(capture.snapshot.status == .complete)
        #expect(capture.pages.count == 4)
        #expect(capture.snapshot.contracts.count == 8)
        #expect(capture.snapshot.underlying?.quote.qualifiedUsages.isEmpty == true)
        #expect(capture.snapshot.underlying?.timeliness == .delayed)
        #expect(capture.snapshot.contracts.allSatisfy { $0.provenance.availability == .unknown && $0.quote.quality.contains(.synthetic) })
        #expect(!capture.snapshot.qualifiedForLiveAnalysis && !capture.snapshot.qualifiedForPIT)
    }
    @Test func frozenEnvelopeRoundtripReplaysExactNumbersAndClocks() throws {
        let original = try OptionChainDemo.capture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(original)
        let reopened = try JSONDecoder().decode(OptionChainCapture.self, from: bytes)
        try reopened.validate()
        #expect(reopened == original)
        #expect(try encoder.encode(reopened) == bytes)
        #expect(reopened.snapshot.underlying?.bid.decimalString == "99.95")
        #expect(reopened.snapshot.contracts.first?.quote.bidAt == OptionChainDemo.time)
    }
    @Test func requestsAreClosedGETsWithNoProviderGreeksOrImplicitPagination() async throws {
        let transport = ChainHTTPProbe()
        let value = try await client(transport).capture(symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time)
        let requests = await transport.requests
        #expect(requests.count == 4 && value.snapshot.status == .complete)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "sandbox.tradier.com" && $0.url?.scheme == "https" })
        #expect(requests.allSatisfy { $0.httpBody == nil && $0.url?.user == nil })
        #expect(requests[0].url?.query?.contains("greeks=false") == true)
        #expect(requests[2].url?.query?.contains("greeks=false") == true)
        #expect(requests[2].url?.query?.contains("page") == false)
        #expect(requests[1].url?.query?.contains("includeAllRoots=true") == true)
    }
    @Test func absentChainRightsRejectBeforeAnyHTTPRequest() async throws {
        let transport = ChainHTTPProbe()
        let rights = OptionChainRights(version: "synthetic-rights.v1", evidenceRef: "synthetic", licenseRef: "synthetic-only",
            validFrom: OptionChainDemo.time.addingTimeInterval(-1), validThrough: OptionChainDemo.time.addingTimeInterval(20),
            capabilities: [.quote, .optionExpirations], usages: [.replay])
        await #expect(throws: ProviderFailure.notEntitled) {
            _ = try await client(transport, rights: rights).capture(symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time)
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func expiredRightsRejectBeforeAnyHTTPRequest() async throws {
        let transport = ChainHTTPProbe()
        let rights = OptionChainRights(version: "old", evidenceRef: "synthetic", licenseRef: "synthetic-only",
            validFrom: OptionChainDemo.time.addingTimeInterval(-20), validThrough: OptionChainDemo.time.addingTimeInterval(-1),
            capabilities: [.quote, .optionExpirations, .optionChain], usages: [.replay])
        await #expect(throws: ProviderFailure.notEntitled) {
            _ = try await client(transport, rights: rights).capture(symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time)
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func boundedExpirationCollectionIsPartialNotComplete() async throws {
        let capture = try await OptionChainSyntheticCollection.capture(pageBudget: 3)
        #expect(capture.snapshot.status == .partial)
        #expect(capture.snapshot.completedExpirations == [OptionChainDemo.expirations[0]])
        #expect(capture.snapshot.requestedExpirations.count == 2)
    }
    @Test func throttlingIsErrorNeverEmptySuccess() async throws {
        let transport = ChainHTTPProbe(status: 429)
        let capture = try await client(transport).capture(symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time)
        #expect(capture.snapshot.status == .error)
        #expect(capture.snapshot.failures == [.rateLimited])
        #expect(await transport.requests.count == 1)
    }
    @Test func secondExpiryFailureRetainsOnlyDeclaredPartialCoverage() async throws {
        let transport = ChainHTTPProbe(failAt: 3)
        let capture = try await client(transport).capture(symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time)
        #expect(capture.snapshot.status == .partial)
        #expect(capture.snapshot.failures == [.notEntitled])
        #expect(capture.snapshot.contracts.count == 4)
        #expect(capture.snapshot.completedExpirations.count == 1)
    }
    @Test func emptyChainsRemainExplicitEmpty() throws {
        let capture = try replacingBodies { page in page.request.capability == .optionChain ? Data(#"{"options":null}"#.utf8) : page.bytes }
        #expect(capture.snapshot.status == .empty)
        #expect(capture.snapshot.completedExpirations.count == 2)
    }
    @Test func missingUnderlyingDoesNotAuthorizeCompleteChain() throws {
        let capture = try replacingBodies { page in page.request.capability == .quote ? Data(#"{"quotes":null}"#.utf8) : page.bytes }
        #expect(capture.snapshot.status == .partial && capture.snapshot.underlying == nil)
    }
    @Test func fractionalContractQuantityRejectedWithoutRounding() throws {
        #expect(throws: ProviderFailure.malformedResponse) {
            _ = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: "\"bidsize\":10", with: "\"bidsize\":0.5").utf8) }
        }
    }
    @Test func mismatchedUnderlyingAndDuplicateContractRejected() throws {
        #expect(throws: ProviderFailure.malformedResponse) {
            _ = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: "\"underlying\":\"DEMO\"", with: "\"underlying\":\"OTHER\"").utf8) }
        }
        #expect(throws: ContractError.duplicateRecord) {
            _ = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: "P00100000", with: "C00100000").utf8) }
        }
    }
    @Test func separateBidAskClocksUseOlderSideAndNeverReceiptFallback() throws {
        let timestamp = String(Int(OptionChainDemo.time.timeIntervalSince1970 * 1000))
        let old = String(Int(OptionChainDemo.time.addingTimeInterval(-1).timeIntervalSince1970 * 1000))
        let changed = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: "\"bid_date\":" + timestamp, with: "\"bid_date\":" + old).utf8) }
        #expect(changed.snapshot.underlying?.quoteTime == OptionChainDemo.time.addingTimeInterval(-1))
        let missing = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: "\"bid_date\":" + timestamp, with: "\"bid_date\":null").utf8) }
        #expect(missing.snapshot.underlying?.quoteTime == nil)
        #expect(missing.snapshot.underlying?.quality.contains(.missing) == true)
    }
    @Test func timestampUnitsAreExplicitNoMagnitudeGuessing() throws {
        let original = try OptionChainDemo.capture()
        #expect(throws: ContractError.invalidTime) {
            _ = try OptionChainCapture(id: original.id, createdAt: original.createdAt, requestedAt: original.requestedAt,
                symbol: original.symbol, environment: original.environment, timestampUnit: .unixSeconds, synthetic: true,
                rights: original.rights, requestedExpirations: original.requestedExpirations, pages: original.pages)
        }
    }
    @Test func corruptRawAndForgedNormalizedValueFailReplay() throws {
        let capture = try OptionChainDemo.capture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(capture)) as? [String: Any])
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        snapshot["status"] = "partial"; object["snapshot"] = snapshot
        let forged = try JSONDecoder().decode(OptionChainCapture.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ContractError.invalidNormalization) { try forged.validate() }
        object = try #require(JSONSerialization.jsonObject(with: encoder.encode(capture)) as? [String: Any])
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[0]["contentHash"] = String(repeating: "0", count: 64); object["pages"] = pages
        let corrupt = try JSONDecoder().decode(OptionChainCapture.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ContractError.mismatchedSource) { try corrupt.validate() }
    }
    @Test func lateIgnoredCancellationCannotPublishCapture() async throws {
        let provider = PausedChainProvider()
        let task = Task { try await OptionChainDataClient(provider: provider, rights: OptionChainDemo.rights).capture(
            symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time) }
        await provider.waitUntilStarted()
        task.cancel(); await provider.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await provider.calls == 1)
    }
    @Test func wrongCapabilitySnapshotAndMixedFeedCannotReplay() throws {
        let capture = try OptionChainDemo.capture()
        for mismatch in ["configuration", "feed", "cycle"] {
            let old = capture.pages[2]
            let request = ProviderRequest(id: mismatch == "cycle" ? UUID() : old.request.id,
                providerID: "tradier", feedID: mismatch == "feed" ? "another-feed" : old.request.feedID,
                resourceID: old.request.resourceID, capability: old.request.capability, mode: .latest, usage: .replay,
                configurationVersion: mismatch == "configuration" ? "wrong-version" : old.request.configurationVersion,
                entitlementVersion: old.request.entitlementVersion, requestedAt: old.request.requestedAt)
            var pages = capture.pages
            pages[2] = .init(request: request, expiration: old.expiration, receivedAt: old.receivedAt, statusCode: 200, bytes: old.bytes)
            #expect(throws: (any Error).self) {
                _ = try OptionChainCapture(id: capture.id, createdAt: capture.createdAt, requestedAt: capture.requestedAt,
                    symbol: capture.symbol, environment: capture.environment, timestampUnit: capture.timestampUnit,
                    synthetic: true, rights: capture.rights, requestedExpirations: capture.requestedExpirations, pages: pages)
            }
        }
    }
    @Test func unexpectedExpirationDoesNotBecomeDeclaredScope() throws {
        #expect(throws: ProviderFailure.malformedResponse) {
            _ = try replacingBodies { page in
                let text = String(decoding: page.bytes, as: UTF8.self)
                return Data((page.request.capability == .optionChain ? text.replacingOccurrences(of: "2026-11-13", with: "2026-11-14") : text).utf8)
            }
        }
    }
    @Test func futureQuoteClockIsRejectedAndOldQuoteRemainsStale() throws {
        let timestamp = String(Int(OptionChainDemo.time.timeIntervalSince1970 * 1000))
        let future = String(Int(OptionChainDemo.time.addingTimeInterval(60).timeIntervalSince1970 * 1000))
        #expect(throws: ContractError.invalidTime) {
            _ = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: timestamp, with: future).utf8) }
        }
        let old = String(Int(OptionChainDemo.time.addingTimeInterval(-900).timeIntervalSince1970 * 1000))
        let stale = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: timestamp, with: old).utf8) }
        #expect(stale.snapshot.underlying?.quality.contains(.stale) == true)
        #expect(stale.snapshot.contracts.allSatisfy { $0.quote.quality.contains(.stale) })
    }
    @Test func asOfRequestIsRejectedBeforeTransportWithoutLatestFallback() async throws {
        let transport = ChainHTTPProbe()
        let provider = try TradierOptionChainProvider(token: Data("SYNTHETIC-ONLY".utf8), environment: .sandbox,
            timestampUnit: .unixMilliseconds, synthetic: true, transport: transport, clock: ChainFixedClock())
        let request = ProviderRequest(providerID: "tradier", feedID: OptionChainEnvironment.sandbox.feedID,
            resourceID: "DEMO", capability: .quote, mode: .asOf(OptionChainDemo.time),
            range: .sourceEvents(.init(start: OptionChainDemo.time, end: OptionChainDemo.time)), usage: .replay,
            configurationVersion: OptionChainCapture.configurationVersion,
            entitlementVersion: OptionChainDemo.rights.version, requestedAt: OptionChainDemo.time)
        await #expect(throws: ContractError.mismatchedRequest) { _ = try await provider.page(request: request, expiration: nil) }
        #expect(await transport.requests.isEmpty)
    }
    @Test func rawPageOwnsBytesEvenForExternallyMutableDataView() throws {
        let source = try OptionChainDemo.capture().pages[0]
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: source.bytes.count, alignment: 1)
        defer { pointer.deallocate() }
        source.bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: source.bytes.count))
        let view = Data(bytesNoCopy: pointer, count: source.bytes.count, deallocator: .none)
        let page = OptionChainRawPage(request: source.request, receivedAt: source.receivedAt, statusCode: 200, bytes: view)
        pointer.storeBytes(of: UInt8(0), as: UInt8.self)
        #expect(page.bytes == source.bytes)
        #expect(page.contentHash == digest(source.bytes))
    }
    @Test func optionTypedUnderlyingCannotMasqueradeAsStock() throws {
        #expect(throws: ProviderFailure.malformedResponse) {
            _ = try replacingBodies { Data(String(decoding: $0.bytes, as: UTF8.self).replacingOccurrences(of: "\"type\":\"stock\"", with: "\"type\":\"option\"").utf8) }
        }
    }
    @Test func noListedExpirationsIsExplicitEmptyAndStopsBeforeChain() async throws {
        let transport = ChainHTTPProbe(noExpirations: true)
        let capture = try await client(transport).capture(symbol: "DEMO", expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time)
        #expect(capture.snapshot.status == .empty)
        #expect(capture.snapshot.listedExpirations.isEmpty)
        #expect(capture.snapshot.completedExpirations.isEmpty)
        #expect(capture.pages.count == 2)
        #expect(await transport.requests.count == 2)
    }
    @Test func rightsExpiredDuringCollectionRejectTheLatePage() throws {
        let capture = try OptionChainDemo.capture()
        let rights = OptionChainRights(version: capture.rights.version, evidenceRef: capture.rights.evidenceRef,
            licenseRef: capture.rights.licenseRef, validFrom: capture.rights.validFrom,
            validThrough: OptionChainDemo.time.addingTimeInterval(1.5), capabilities: capture.rights.capabilities,
            usages: capture.rights.usages)
        #expect(throws: ProviderFailure.notEntitled) {
            _ = try OptionChainCapture(id: capture.id, createdAt: capture.createdAt, requestedAt: capture.requestedAt,
                symbol: capture.symbol, environment: capture.environment, timestampUnit: capture.timestampUnit,
                synthetic: true, rights: rights, requestedExpirations: capture.requestedExpirations, pages: capture.pages)
        }
    }
    private func client(_ transport: ChainHTTPProbe, rights: OptionChainRights = OptionChainDemo.rights) throws -> OptionChainDataClient<TradierOptionChainProvider> {
        .init(provider: try TradierOptionChainProvider(token: Data("SYNTHETIC-ONLY".utf8), environment: .sandbox,
            timestampUnit: .unixMilliseconds, synthetic: true, transport: transport, clock: ChainFixedClock()), rights: rights)
    }
    private func replacingBodies(_ replacement: (OptionChainRawPage) throws -> Data) throws -> OptionChainCapture {
        let original = try OptionChainDemo.capture()
        let pages = try original.pages.map { OptionChainRawPage(request: $0.request, expiration: $0.expiration,
            receivedAt: $0.receivedAt, statusCode: $0.statusCode, bytes: try replacement($0)) }
        return try .init(id: original.id, createdAt: original.createdAt, requestedAt: original.requestedAt,
            symbol: original.symbol, environment: original.environment, timestampUnit: original.timestampUnit, synthetic: true,
            rights: original.rights, requestedExpirations: original.requestedExpirations, pages: pages)
    }
}
private struct ChainFixedClock: EquityRequestClock {
    func now() -> Date { OptionChainDemo.time.addingTimeInterval(5) }
    func uptime() -> TimeInterval { 0 }
    func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation() }
}
private actor ChainHTTPProbe: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int, failAt: Int?
    let noExpirations: Bool
    init(status: Int = 200, failAt: Int? = nil, noExpirations: Bool = false) {
        self.status = status; self.failAt = failAt; self.noExpirations = noExpirations
    }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        let index = requests.count; requests.append(request)
        if index == 1 && noExpirations {
            return .init(statusCode: 200, mediaType: "application/json", body: Data(#"{"expirations":null}"#.utf8))
        }
        if index == failAt { return .init(statusCode: 403, mediaType: "application/json", body: Data(#"{"error":"synthetic"}"#.utf8)) }
        if status != 200 { return .init(statusCode: status, mediaType: "application/json", body: Data(#"{"error":"synthetic"}"#.utf8)) }
        let capability: ProviderCapability = index == 0 ? .quote : (index == 1 ? .optionExpirations : .optionChain)
        let expiry = index < 2 ? nil : OptionChainDemo.expirations[index - 2]
        return .init(statusCode: 200, mediaType: "application/json", body: try OptionChainDemo.body(capability: capability, expiration: expiry))
    }
}
private actor PausedChainProvider: OptionChainCaptureProvider {
    nonisolated let environment = OptionChainEnvironment.sandbox
    nonisolated let timestampUnit = OptionChainTimestampUnit.unixMilliseconds
    nonisolated let synthetic = true
    var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async { if calls > 0 { return }; await withCheckedContinuation { started = $0 } }
    func release() { pending?.resume(); pending = nil }
    func page(request: ProviderRequest, expiration: MarketDate?) async throws -> OptionChainRawPage {
        calls += 1
        await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
        return .init(request: request, expiration: expiration, receivedAt: OptionChainDemo.time.addingTimeInterval(1),
                     statusCode: 200, bytes: try OptionChainDemo.body(capability: request.capability, expiration: expiration))
    }
}
