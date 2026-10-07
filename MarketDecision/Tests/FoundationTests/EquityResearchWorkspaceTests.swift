import Foundation
import Testing
import CoreDomain
import DataContracts
import DataProviders
import MarketDataProviders
import Persistence
import SecuritySupport
import FundamentalsEngine
@testable import AppComposition

private let researchNow = Date(timeIntervalSince1970: 1_789_743_600) // 2026-09-18 15:00 UTC
private let researchQuote = #"{"symbol":"AAPL","quote":{"t":"2026-09-18T14:59:59Z","bp":123.125,"ap":124.01,"bs":10,"as":20,"bx":"V","ax":"V"}}"#
private func researchPayload(_ body: String, status: Int = 200) -> HTTPPayload {
    .init(statusCode: status, mediaType: "application/json", body: Data(body.utf8))
}
private actor ResearchGate {
    var entered = false
    var pending: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { pending = $0 } }
    func wait() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { pending?.resume(); pending = nil }
}
private actor ResearchCredentials: CredentialReadingStorage {
    var value: Data?
    var reads = 0, checks = 0, saves = 0, deletes = 0
    var failWrite = false
    var readGate: ResearchGate?
    init(saved: Bool = true) throws { value = saved ? try EquityCredentials(apiKey: "SYNTHETIC_KEY", secret: "SYNTHETIC_SECRET").encoded() : nil }
    func contains(reference: String) throws -> Bool { #expect(reference == EquityCredentials.reference); checks += 1; return value != nil }
    func read(reference: String) async throws -> Data? {
        #expect(reference == EquityCredentials.reference); reads += 1
        let captured = value
        if let readGate { await readGate.pause() }
        return captured
    }
    func save(_ secret: Data, reference: String) throws {
        #expect(reference == EquityCredentials.reference); saves += 1; value = secret
        if failWrite { throw ResearchInjectedError() }
    }
    func delete(reference: String) throws { #expect(reference == EquityCredentials.reference); deletes += 1; value = nil; if failWrite { throw ResearchInjectedError() } }
    func setFail(_ fail: Bool) { failWrite = fail }
    func setGate(_ gate: ResearchGate) { readGate = gate }
    func setBytes(_ bytes: Data) { value = bytes }
    func counts() -> [Int] { [checks, reads, saves, deletes] }
}
private struct ResearchInjectedError: Error, LocalizedError {
    var errorDescription: String? { Issue.record("Credential/network error description must not be inspected"); return "SYNTHETIC_SECRET" }
}
private final class ResearchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0, closed = 0
    func create() { lock.withLock { created += 1 } }
    func close() { lock.withLock { closed += 1 } }
    func values() -> [Int] { lock.withLock { [created, closed] } }
}
private final class ResearchClock: EquityRequestClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private let base: Date
    init(base: Date = researchNow) { self.base = base }
    func now() -> Date { base.addingTimeInterval(uptime()) }
    func uptime() -> TimeInterval { lock.withLock { elapsed } }
    func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation(); lock.withLock { elapsed += seconds } }
}
private actor ResearchTransport: HTTPTransport {
    let gate: ResearchGate?
    var responses: [HTTPPayload]
    var sent = 0
    init(_ responses: [HTTPPayload], gate: ResearchGate? = nil) { self.responses = responses; self.gate = gate }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        sent += 1
        if sent == 1, let gate { await gate.pause() }
        guard !responses.isEmpty else { throw ResearchInjectedError() }
        return responses.removeFirst()
    }
}
private struct ResearchHarness {
    let database: BusinessDataStore
    let credentials: ResearchCredentials
    let transport: ResearchTransport
    let counter: ResearchCounter
    let acquisition: EquityResearchAcquisition
    init(saved: Bool = true, responses: [HTTPPayload] = [researchPayload(researchQuote)], gate: ResearchGate? = nil,
         clockBase: Date = researchNow) throws {
        database = try BusinessDataStore(path: ":memory:")
        credentials = try ResearchCredentials(saved: saved)
        let transport = ResearchTransport(responses, gate: gate), counter = ResearchCounter(), clock = ResearchClock(base: clockBase)
        self.transport = transport; self.counter = counter
        acquisition = EquityResearchAcquisition(database: database, factory: { credentials, rights in
            counter.create()
            let provider = try AlpacaIEXProvider(apiKey: credentials.apiKey, secret: credentials.secret,
                evidenceRef: rights.evidenceReference, licenseRef: rights.licenseReference, transport: transport, clock: clock)
            return EquityResearchProviderSession(provider: provider, close: { counter.close() })
        }, clock: { clock.now() }, captureOrigin: .syntheticFixture)
    }
    @MainActor func model(networkAvailable: Bool = true) -> EquityResearchWorkspaceModel {
        let model = EquityResearchWorkspaceModel(store: credentials, acquisition: acquisition,
            networkAvailable: networkAvailable, clock: { researchNow })
        model.appear(); model.symbolDraft = "AAPL"; model.classIDDraft = "common-A"
        model.rightsAssertion = "Synthetic local captured-reference rights assertion"
        model.rightsEvidence = "Synthetic fixture rights text; no provider certification"
        model.rightsEvidenceReference = "synthetic-rights"; model.rightsLicenseReference = "synthetic-license"
        return model
    }
}

@Suite @MainActor struct EquityResearchWorkspaceTests {
    @Test func productionCompositionAndPageConstructionNeverReadCredentialsOrStartTransport() async throws {
        let credentials = try ResearchCredentials()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"), credentials: credentials)
        let first = try environment.makeEquityResearchWorkspace(), second = try environment.makeEquityResearchWorkspace()
        first.appear(); second.appear()
        #expect(first.presence == .unknown && second.presence == .unknown)
        #expect(!first.networkAvailable && !second.networkAvailable && !first.canFetch && !second.canFetch)
        #expect(first.networkUnavailableMessage != nil && second.networkUnavailableMessage != nil)
        #expect(!first.isFetching && !second.isFetching && first.result == nil && second.result == nil)
        #expect(await credentials.counts() == [0, 0, 0, 0])
    }
    @Test func unavailableHelperBlocksDirectFetchBeforeSecretReadButPreservesCredentialManagement() async throws {
        let h = try ResearchHarness(), model = h.model(networkAvailable: false)
        _ = await model.checkCredentials(); model.rightsConfirmed = true
        #expect(model.presence == .saved && model.canDeleteCredentials && !model.canFetch)
        await model.fetch()
        #expect(model.result == nil && !model.isFetching && model.hasFetchError)
        #expect(model.fetchMessage == model.networkUnavailableMessage)
        #expect(await h.credentials.counts() == [1, 0, 0, 0])
        #expect(h.counter.values() == [0, 0])
        #expect(await h.transport.sent == 0)
        model.requestDeleteCredentials()
        let confirmation = try #require(model.confirmation)
        await model.respondToConfirmation(id: confirmation.id, confirmed: true)
        #expect(model.presence == .absent)
        #expect(await h.credentials.deletes == 1)
        #expect(await h.credentials.reads == 0)
    }
    @Test func constructionAndPresenceChecksNeverReadSecretsOrBuildProvider() async throws {
        let h = try ResearchHarness(), model = h.model()
        #expect(await h.credentials.counts() == [0, 0, 0, 0])
        #expect(model.presence == .unknown && !model.rightsConfirmed)
        #expect(await model.checkCredentials())
        #expect(await h.credentials.counts() == [1, 0, 0, 0])
        #expect(h.counter.values() == [0, 0])
    }
    @Test func missingRightsInvalidEvidenceAndInvalidSymbolDoNotReadOrDispatch() async throws {
        let h = try ResearchHarness(), model = h.model()
        _ = await model.checkCredentials()
        await model.fetch()
        model.rightsConfirmed = true; model.rightsEvidence = ""
        await model.fetch()
        model.rightsEvidence = "Synthetic evidence"; model.symbolDraft = "AAPL?token"
        await model.fetch()
        #expect(await h.credentials.counts() == [1, 0, 0, 0])
        #expect(h.counter.values() == [0, 0] && model.result == nil && model.hasFetchError)
    }
    @Test func oneEnvelopeAtomicSaveAndExplicitRevisionBoundReplacement() async throws {
        let h = try ResearchHarness(saved: false), model = h.model()
        _ = await model.checkCredentials()
        model.keyDraft = "NEW_KEY"; model.secretDraft = "NEW_SECRET"
        await model.requestSaveCredentials()
        #expect(model.presence == .saved && model.keyDraft.isEmpty && model.secretDraft.isEmpty)
        let first = try EquityCredentials.decode(#require(await h.credentials.value))
        #expect(first.apiKey == Data("NEW_KEY".utf8) && first.secret == Data("NEW_SECRET".utf8))
        model.keyDraft = "SECOND_KEY"; model.secretDraft = "SECOND_SECRET"
        await model.requestSaveCredentials()
        let confirmation = try #require(model.confirmation)
        #expect(await h.credentials.saves == 1)
        await model.respondToConfirmation(id: UUID(), confirmed: true)
        #expect(await h.credentials.saves == 1)
        await model.respondToConfirmation(id: confirmation.id, confirmed: true)
        await model.respondToConfirmation(id: confirmation.id, confirmed: true)
        #expect(await h.credentials.saves == 2)
    }
    @Test func editedDraftCancelledAndCrossWindowStaleConfirmationCannotWrite() async throws {
        let h = try ResearchHarness(), first = h.model(), second = h.model()
        _ = await first.checkCredentials()
        first.keyDraft = "REPLACE_KEY"; first.secretDraft = "REPLACE_SECRET"
        await first.requestSaveCredentials()
        let edited = try #require(first.confirmation)
        first.secretDraft = "CHANGED_SECRET"
        await first.respondToConfirmation(id: edited.id, confirmed: true)
        first.requestDeleteCredentials()
        let cancelled = try #require(first.confirmation)
        await first.respondToConfirmation(id: cancelled.id, confirmed: false)
        first.requestDeleteCredentials()
        let stale = try #require(first.confirmation)
        _ = await second.checkCredentials()
        await first.respondToConfirmation(id: stale.id, confirmed: true)
        #expect(await h.credentials.counts() == [2, 0, 0, 0])
        #expect(first.presence == .unknown && first.hasCredentialError)
    }
    @Test func writeThenFailureRequiresPresenceCheckAndNeverInspectsErrorText() async throws {
        let h = try ResearchHarness(saved: false), model = h.model()
        _ = await model.checkCredentials(); await h.credentials.setFail(true)
        model.keyDraft = "NEW_KEY"; model.secretDraft = "NEW_SECRET"
        await model.requestSaveCredentials()
        #expect(model.presence == .unknown && model.hasCredentialError)
        await model.requestSaveCredentials()
        #expect(await h.credentials.saves == 1)
        #expect(!(model.credentialMessage ?? "").contains("NEW_SECRET"))
        await h.credentials.setFail(false); _ = await model.checkCredentials()
        #expect(model.presence == .saved)
    }
    @Test func completeQuoteFreezesExactAcceptedSourceAndReplayOnlyRights() async throws {
        let h = try ResearchHarness(), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true; model.selectedSide = .ask
        await model.fetch()
        let capture = try #require(model.result), evidence = try #require(capture.quoteEvidence)
        #expect(capture.pages.count == 1 && capture.pages[0].status == "complete")
        #expect(evidence.selectedPrice?.decimalString == "124.01" && evidence.classID == "common-A")
        #expect(evidence.rawSource.bytes == Data(researchQuote.utf8))
        #expect(evidence.rawSource.contentHash == digest(Data(researchQuote.utf8)))
        #expect(evidence.request.usage == .replay && evidence.record.provenance.availability == .unknown)
        #expect(evidence.record.provenance.versionKind == .localContent)
        #expect(try evidence.record.displayQuote(at: researchNow).qualifiedUsages.isEmpty)
        #expect(evidence.rights.validThrough.timeIntervalSince(evidence.rights.validFrom) == 900)
        let source = try await h.database.sourceDocument(reference: evidence.rawSource.reference)
        #expect(source.payload == evidence.rawSource.bytes)
        #expect(try await h.database.equityPages(symbol: "AAPL").count == 1)
        #expect(h.counter.values() == [1, 1])
        #expect(await h.credentials.counts() == [1, 1, 0, 0])
    }
    @Test func emptyAndInvalidQuotesRemainEvidenceWithoutReferencePrices() async throws {
        for body in [#"{"symbol":"AAPL","quote":null}"#, researchQuote.replacingOccurrences(of: "123.125", with: "200")] {
            let h = try ResearchHarness(responses: [researchPayload(body)]), model = h.model()
            _ = await model.checkCredentials(); model.rightsConfirmed = true
            await model.fetch()
            let capture = try #require(model.result)
            #expect(capture.quoteEvidence == nil)
            #expect(capture.pages[0].rawSource.bytes == Data(body.utf8) && !model.hasFetchError)
            #expect(h.counter.values() == [1, 1])
        }
    }
    @Test func fractionalRequestClockNeverAdvancesDispatchIntoTheFuture() async throws {
        let precise = researchNow.addingTimeInterval(0.0006)
        let h = try ResearchHarness(clockBase: precise), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true
        await model.fetch()
        let capture = try #require(model.result), evidence = try #require(capture.quoteEvidence)
        #expect(evidence.request.requestedAt == researchNow && evidence.request.requestedAt <= precise)
        #expect(capture.pages.count == 1 && h.counter.values() == [1, 1])
    }
    @Test func providerErrorClearsOldResultAndAlwaysClosesSession() async throws {
        let h = try ResearchHarness(responses: [researchPayload(researchQuote), researchPayload("{}", status: 401)]), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true
        await model.fetch(); #expect(model.result != nil)
        await model.fetch()
        #expect(model.result == nil && model.hasFetchError)
        #expect(h.counter.values() == [2, 2])
        #expect(try await h.database.equityPages(symbol: "AAPL").count == 1)
    }
    @Test func missingAndMalformedEnvelopesNeverConstructProvider() async throws {
        for bytes in [Data("{}".utf8), Data(repeating: 0, count: 4_097)] {
            let h = try ResearchHarness(), model = h.model()
            await h.credentials.setBytes(bytes); _ = await model.checkCredentials(); model.rightsConfirmed = true
            await model.fetch()
            #expect(h.counter.values() == [0, 0] && model.result == nil && model.presence == .unknown)
        }
    }
    @Test func boundedDailyPaginationRemainsPartialAndDoesNotCreateHistoricalQualification() async throws {
        let responses = [researchPayload(researchQuote)] + (1...4).map {
            researchPayload("{\"symbol\":\"AAPL\",\"bars\":[],\"next_page_token\":\"page-\($0)\"}")
        }
        let h = try ResearchHarness(responses: responses), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true; model.includeDailyBars = true
        await model.fetch()
        let capture = try #require(model.result)
        #expect(capture.pages.count == 5 && !capture.dailyBarsComplete && capture.dailyBarCount == 0)
        #expect(capture.pages.dropFirst().allSatisfy { $0.status == "partial" && $0.request.usage == .replay })
        #expect(await h.transport.sent == 5 && h.counter.values() == [1, 1])
    }
    @Test func cancelAndLateResponseNeverPublishOrIngest() async throws {
        let gate = ResearchGate(), h = try ResearchHarness(gate: gate), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true
        let operation = Task { await model.fetch() }
        await gate.wait(); model.cancelFetch(); await gate.release(); await operation.value
        #expect(model.result == nil && !model.isFetching && !model.hasFetchError)
        #expect(try await h.database.equityPages(symbol: "AAPL").isEmpty)
        #expect(h.counter.values() == [1, 1])
    }
    @Test func credentialChangeCancelsCrossWindowFetchBeforeLateResponseCanPersist() async throws {
        let gate = ResearchGate(), h = try ResearchHarness(gate: gate), first = h.model(), second = h.model()
        _ = await first.checkCredentials(); first.rightsConfirmed = true
        let operation = Task { await first.fetch() }
        await gate.wait(); _ = await second.checkCredentials()
        second.requestDeleteCredentials()
        let confirmation = try #require(second.confirmation)
        await second.respondToConfirmation(id: confirmation.id, confirmed: true)
        await gate.release(); await operation.value
        #expect(first.result == nil && second.presence == .absent)
        #expect(try await h.database.equityPages(symbol: "AAPL").isEmpty)
        #expect(h.counter.values() == [1, 1])
    }
    @Test func sharedCaptureGateRejectsAnotherWindowBeforeSecretRead() async throws {
        let gate = ResearchGate(), h = try ResearchHarness(gate: gate), model = h.model()
        let revision = try await h.acquisition.beginCredentialUpdate(expectedRevision: nil)
        await h.acquisition.endCredentialUpdate(revision)
        let rights = try SECCapturedPriceRights(entitlementVersion: "synthetic-rights", evidenceReference: "synthetic-rights",
            licenseReference: "synthetic-license", recordedAt: researchNow, validFrom: researchNow,
            validThrough: researchNow.addingTimeInterval(900), assertion: "Synthetic assertion", evidenceBytes: Data("Synthetic evidence".utf8))
        let operation = Task { try await h.acquisition.capture(symbol: "AAPL", classID: "common", side: .bid,
            rights: rights, bars: nil, credentialStore: h.credentials, expectedCredentialRevision: revision) }
        await gate.wait()
        await #expect(throws: EquityResearchError.busy) {
            try await h.acquisition.capture(symbol: "AAPL", classID: "common", side: .bid,
                rights: rights, bars: nil, credentialStore: h.credentials, expectedCredentialRevision: revision)
        }
        #expect(await h.credentials.reads == 1)
        await gate.release(); _ = try await operation.value
        #expect(model.result == nil && h.counter.values() == [1, 1])
    }
    @Test func originalDatabaseRevisionSurvivesSuspendedCredentialRead() async throws {
        let gate = ResearchGate(), h = try ResearchHarness(), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true; await h.credentials.setGate(gate)
        let operation = Task { await model.fetch() }
        await gate.wait()
        let plan = try await h.database.prepareDeletion(.allBusiness, expectedRevision: h.database.revision())
        _ = try await h.database.commit(PlanApproval(planID: plan.id, digest: plan.digest))
        await gate.release(); await operation.value
        #expect(model.result == nil && model.hasFetchError)
        #expect(try await h.database.equityPages(symbol: "AAPL").isEmpty)
        #expect(h.counter.values() == [1, 1])
    }
    @Test func disappearedSessionCannotPublishLateResultsIntoReopenedPage() async throws {
        let gate = ResearchGate(), h = try ResearchHarness(gate: gate), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true
        let operation = Task { await model.fetch() }
        await gate.wait(); model.disappear(); model.appear()
        await gate.release(); await operation.value
        #expect(model.result == nil && !model.isFetching)
        #expect(try await h.database.equityPages(symbol: "AAPL").isEmpty)
        #expect(h.counter.values() == [1, 1])
    }
    @Test func changingRequestDraftInvalidatesLateCaptureAndPreviouslySelectedEvidence() async throws {
        let gate = ResearchGate(), h = try ResearchHarness(gate: gate), model = h.model()
        _ = await model.checkCredentials(); model.rightsConfirmed = true
        let operation = Task { await model.fetch() }
        await gate.wait(); model.classIDDraft = "another-class"
        await gate.release(); await operation.value
        #expect(model.result == nil && !model.isFetching)
        #expect(try await h.database.equityPages(symbol: "AAPL").isEmpty)
        let completed = try ResearchHarness(), other = completed.model()
        _ = await other.checkCredentials(); other.rightsConfirmed = true
        await other.fetch(); #expect(other.result?.quoteEvidence != nil)
        other.selectedSide = .ask
        #expect(other.result == nil)
    }
}

@Suite struct EquityResearchCredentialTests {
    @Test func envelopeRejectsPartialMalformedAndWhitespaceWithoutCredentialTransformation() throws {
        let envelope = try EquityCredentials(apiKey: "SYNTHETIC_KEY", secret: "SYNTHETIC_SECRET")
        let decoded = try EquityCredentials.decode(envelope.encoded())
        #expect(decoded.apiKey == envelope.apiKey && decoded.secret == envelope.secret)
        for pair in [("", "SECRET"), (" KEY", "SECRET"), ("KEY1", "SECRET\n"), ("KEY1", "") ] {
            #expect(throws: EquityCredentialError.self) { try EquityCredentials(apiKey: pair.0, secret: pair.1) }
        }
        #expect(throws: EquityCredentialError.self) { try EquityCredentials.decode(Data(#"{"format":"equity-credentials.v1","apiKey":"S0VZMQ=="}"#.utf8)) }
    }
}
