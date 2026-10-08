import Foundation
import CoreDomain
import DataContracts
import DataProviders
import MarketDataProviders
import Persistence
import SecuritySupport
import FundamentalsEngine

public enum EquityResearchError: Error, Sendable, Equatable { case busy, staleCredentials, missingCredentials, invalidInput }

public struct EquityResearchProviderSession: Sendable {
    public let provider: any EquityDataProvider
    public let close: @Sendable () async -> Void
    public init(provider: any EquityDataProvider, close: @escaping @Sendable () async -> Void) {
        self.provider = provider; self.close = close
    }
}

/// Immutable exchange evidence; these records retain UNKNOWN availability and local content
/// versions. In particular, the daily pages cannot become historical valuation inputs.
public struct EquityResearchPage: Sendable, Codable {
    public let request: ProviderRequest
    public let receivedAt: Date
    public let status: String
    public let nextPageToken: String?
    public let records: [EquityRecord]
    public let rawSource: SECValuationSourceMaterial
    public let rights: SECCapturedPriceRights
    init(_ accepted: AcceptedProviderPayload<EquityRecord>, rights: SECCapturedPriceRights) throws {
        let result = accepted.exchange.result
        request = result.request; receivedAt = result.receivedAt; status = result.status.rawValue
        nextPageToken = result.nextPageToken; records = result.items
        rawSource = try SECValuationSourceMaterial(reference: accepted.rawPayload.reference,
            contentHash: accepted.rawPayload.contentHash, bytes: accepted.rawPayload.bytes)
        self.rights = rights
    }
}

public struct EquityResearchCapture: Sendable {
    public let symbol: String
    public let pages: [EquityResearchPage]
    public let quoteEvidence: SECValuationPriceEvidence?
    public let dailyBarsComplete: Bool
    public var dailyBarCount: Int { pages.filter { $0.request.capability == .bars }.reduce(0) { $0 + $1.records.count } }
}

/// One instance is shared by all windows. Credential changes and captures share this gate;
/// cancelling an operation never re-pins its database revision to a newer generation.
public actor EquityResearchAcquisition {
    public typealias Factory = @Sendable (EquityCredentials, SECCapturedPriceRights) throws -> EquityResearchProviderSession
    public static let maximumDailyPages = 4
    private let database: BusinessDataStore
    private let factory: Factory
    private let clock: @Sendable () -> Date
    private let captureOrigin: SECReferenceCaptureOrigin
    private let workspaceLock: WorkspaceImportLock
    private var credentialRevision = UUID()
    private var credentialUpdate: UUID?
    private var active: (id: UUID, task: Task<EquityResearchCapture, Error>)?

    /// Standalone injected captures have an isolated memory permit. AppEnvironment injects
    /// the persistent workspace permit shared with SEC imports.
    public init(database: BusinessDataStore, factory: @escaping Factory,
                clock: @escaping @Sendable () -> Date = { Date() },
                captureOrigin: SECReferenceCaptureOrigin = .providerCapture) {
        self.database = database; self.factory = factory; self.clock = clock; self.captureOrigin = captureOrigin
        self.workspaceLock = WorkspaceImportLock()
    }

    init(database: BusinessDataStore, factory: @escaping Factory,
         clock: @escaping @Sendable () -> Date = { Date() },
         captureOrigin: SECReferenceCaptureOrigin = .providerCapture, workspaceLock: WorkspaceImportLock) {
        self.database = database; self.factory = factory; self.clock = clock; self.captureOrigin = captureOrigin
        self.workspaceLock = workspaceLock
    }

    /// nil is for a fresh explicit presence check, never for a save/delete confirmation.
    func beginCredentialUpdate(expectedRevision: UUID?) throws -> UUID {
        guard credentialUpdate == nil else { throw EquityResearchError.busy }
        if let expectedRevision, expectedRevision != credentialRevision { throw EquityResearchError.staleCredentials }
        active?.task.cancel()
        credentialRevision = UUID(); credentialUpdate = credentialRevision
        return credentialRevision
    }
    func endCredentialUpdate(_ token: UUID) {
        guard credentialUpdate == token else { return }
        credentialUpdate = nil
    }

    public func cancel() { active?.task.cancel() }

    public func capture(symbol: String, classID: String, side: SECReferencePriceSide,
                        rights: SECCapturedPriceRights, bars: DateRange?,
                        credentialStore: any CredentialReadingStorage,
                        expectedCredentialRevision: UUID) async throws -> EquityResearchCapture {
        guard active == nil, credentialUpdate == nil else { throw EquityResearchError.busy }
        guard credentialRevision == expectedCredentialRevision else { throw EquityResearchError.staleCredentials }
        try Self.validate(symbol: symbol, classID: classID, rights: rights, bars: bars, now: clock())
        try Task.checkCancellation()
        let lease: WorkspaceImportLease
        do { lease = try workspaceLock.tryAcquire() }
        catch WorkspaceImportLockError.busy { throw EquityResearchError.busy }
        // Keep the lease while the child unwinds, including its awaited session.close().
        // Credential revisions remain per instance; this does not synchronize Keychain edits.
        defer { lease.release() }
        try Task.checkCancellation()
        let id = UUID(), database = database, factory = factory, clock = clock, origin = captureOrigin
        let task = Task {
            try await Self.perform(symbol: symbol, classID: classID, side: side, rights: rights, bars: bars,
                credentialStore: credentialStore, database: database, factory: factory, clock: clock, origin: origin)
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard credentialRevision == expectedCredentialRevision else { throw EquityResearchError.staleCredentials }
            return result
        } onCancel: { task.cancel() }
    }

    private static func validate(symbol: String, classID: String, rights: SECCapturedPriceRights,
                                 bars: DateRange?, now: Date) throws {
        try EquityRecord.validateSymbol(symbol)
        guard symbol.range(of: #"^[A-Z][A-Z0-9.\-]{0,14}\z"#, options: .regularExpression) != nil,
              !classID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, classID.utf8.count <= 128,
              !classID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              rights.providerID == "alpaca", rights.feedID == "iex",
              rights.recordedAt <= now, rights.validFrom <= now, now <= rights.validThrough,
              rights.validThrough.timeIntervalSince(rights.validFrom) <= 15 * 60,
              rights.scope == "personal-local-captured-reference-and-retention.v1",
              rights.evidenceHash == digest(rights.evidenceBytes), !rights.evidenceBytes.isEmpty,
              !rights.assertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw EquityResearchError.invalidInput }
        _ = try SECCapturedPriceRights(entitlementVersion: rights.entitlementVersion,
            evidenceReference: rights.evidenceReference, licenseReference: rights.licenseReference,
            recordedAt: rights.recordedAt, validFrom: rights.validFrom, validThrough: rights.validThrough,
            assertion: rights.assertion, evidenceBytes: rights.evidenceBytes)
        if let bars {
            try bars.validate()
            var calendar = Calendar(identifier: .gregorian)
            guard let zone = TimeZone(identifier: "America/New_York") else { throw EquityResearchError.invalidInput }
            calendar.timeZone = zone
            guard bars.end < calendar.startOfDay(for: now), bars.end.timeIntervalSince(bars.start) <= 366 * 86_400,
                  try MillisecondInstant(rounding: bars.start).date == bars.start,
                  try MillisecondInstant(rounding: bars.end).date == bars.end else { throw EquityResearchError.invalidInput }
        }
    }

    private static func perform(symbol: String, classID: String, side: SECReferencePriceSide,
                                rights: SECCapturedPriceRights, bars: DateRange?,
                                credentialStore: any CredentialReadingStorage, database: BusinessDataStore,
                                factory: Factory, clock: @Sendable () -> Date,
                                origin: SECReferenceCaptureOrigin) async throws -> EquityResearchCapture {
        try Task.checkCancellation()
        // Pin BEFORE reading secrets or constructing a transport, and retain this lineage.
        var revision = await database.revision()
        guard let encoded = try await credentialStore.read(reference: EquityCredentials.reference) else {
            throw EquityResearchError.missingCredentials
        }
        try Task.checkCancellation()
        let credentials = try EquityCredentials.decode(encoded)
        try validate(symbol: symbol, classID: classID, rights: rights, bars: bars, now: clock())
        let session = try factory(credentials, rights)
        do {
            let provider = AnyEquityResearchProvider(session.provider)
            // This assertion grants only a short local replay operation. It does not certify a
            // subscription, extend the underlying license, or permit live/PIT/ledger use.
            let entitlement = EntitlementSnapshot(providerID: "alpaca", feedID: "iex", version: rights.entitlementVersion,
                evidenceRef: rights.evidenceReference, licenseRef: rights.licenseReference,
                capabilities: [.quote, .bars], usages: [.replay], validFrom: rights.validFrom, validThrough: rights.validThrough)
            let pipeline = EquityAcquisitionPipeline(client: EquityDataClient(provider: provider, entitlement: entitlement), store: database)
            func request(_ capability: ProviderCapability, token: String? = nil) throws -> ProviderRequest {
                let now = try MillisecondInstant(flooring: clock()).date
                guard rights.recordedAt <= now, now <= rights.validThrough else { throw EquityResearchError.invalidInput }
                return ProviderRequest(providerID: "alpaca", feedID: "iex", resourceID: symbol,
                    capability: capability, mode: .latest, range: capability == .bars ? bars.map(DataWindow.sourceEvents) : nil,
                    usage: .replay, configurationVersion: AlpacaIEXProvider.configurationVersion,
                    entitlementVersion: rights.entitlementVersion, requestedAt: now, pageToken: token)
            }
            try Task.checkCancellation()
            let quote = try await pipeline.ingest(request(.quote), expectedRevision: revision)
            revision = quote.receipt.revision
            try Task.checkCancellation()
            var pages = [try EquityResearchPage(quote.accepted, rights: rights)]
            let evidence: SECValuationPriceEvidence?
            if let record = pages[0].records.first {
                // An accepted but stale/crossed/invalid quote stays in captured evidence without
                // becoming a selectable valuation reference.
                evidence = try? SECValuationPriceEvidence(classID: classID, record: record, request: pages[0].request,
                    rawSource: pages[0].rawSource, rights: rights, selectedSide: side, captureOrigin: origin)
            } else { evidence = nil }
            var complete = bars == nil
            if bars != nil {
                var next: String?, tokens = Set<String>()
                for _ in 0..<maximumDailyPages {
                    try Task.checkCancellation()
                    let page = try await pipeline.ingest(request(.bars, token: next), expectedRevision: revision)
                    revision = page.receipt.revision
                    try Task.checkCancellation()
                    pages.append(try EquityResearchPage(page.accepted, rights: rights))
                    next = page.accepted.exchange.result.nextPageToken
                    if next == nil { complete = true; break }
                    guard let next, tokens.insert(next).inserted else { throw ContractError.invalidCoverage }
                }
            }
            let result = EquityResearchCapture(symbol: symbol, pages: pages, quoteEvidence: evidence, dailyBarsComplete: complete)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }
}

private struct AnyEquityResearchProvider: EquityDataProvider {
    let wrapped: any EquityDataProvider
    init(_ wrapped: any EquityDataProvider) { self.wrapped = wrapped }
    var id: String { wrapped.id }
    var capabilitySnapshot: CapabilitySnapshot { wrapped.capabilitySnapshot }
    func quote(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord> { try await wrapped.quote(request: request) }
    func dailyBars(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord> { try await wrapped.dailyBars(request: request) }
}
