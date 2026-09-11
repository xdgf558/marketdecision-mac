import Foundation
import DataContracts

public struct ProviderRawPayload: Sendable {
    public let reference: String
    public let mediaType: String
    public let bytes: Data
    public let storageAvailableAt: Date
    public let evidenceRef: String
    public let licenseRef: String

    public init(reference: String, mediaType: String, bytes: Data, storageAvailableAt: Date,
                evidenceRef: String, licenseRef: String) throws {
        guard reference.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/\-]{0,511}\z"#, options: .regularExpression) != nil,
              !reference.contains(".."), !reference.contains("://"), !reference.contains("@"),
              mediaType.range(of: #"^[A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*\z"#, options: .regularExpression) != nil,
              !bytes.isEmpty, bytes.count <= 100 * 1_024 * 1_024, storageAvailableAt.timeIntervalSince1970.isFinite,
              !evidenceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !licenseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ContractError.invalidIdentity }
        self.reference = reference; self.mediaType = mediaType; self.bytes = bytes
        self.storageAvailableAt = storageAvailableAt; self.evidenceRef = evidenceRef; self.licenseRef = licenseRef
    }
    public var contentHash: String { digest(bytes) }
}

public struct ProviderPayloadResponse<Item: ProviderRecord>: Sendable {
    public let result: ProviderResult<Item>
    public let rawPayload: ProviderRawPayload
    public let continuationTokens: [String]
    public init(result: ProviderResult<Item>, rawPayload: ProviderRawPayload, continuationTokens: [String] = []) {
        self.result = result; self.rawPayload = rawPayload; self.continuationTokens = continuationTokens
    }
}
public typealias CalendarProviderResponse<Item: ProviderRecord> = ProviderPayloadResponse<Item>

/// The only public input accepted by calendar/event persistence. Its initializer is internal,
/// so production code can obtain it only after ProviderSession accepts the exact response.
public struct AcceptedProviderPayload<Item: ProviderRecord>: Sendable {
    public let exchange: ProviderExchange<Item>
    public let rawPayload: ProviderRawPayload
    public let continuationTokens: [String]
    init(exchange: ProviderExchange<Item>, rawPayload: ProviderRawPayload, continuationTokens: [String]) {
        self.exchange = exchange; self.rawPayload = rawPayload; self.continuationTokens = continuationTokens
    }
}

func acceptProviderPayload<Item: ProviderRecord>(_ response: ProviderPayloadResponse<Item>,
                                                 using session: ProviderSession) throws -> AcceptedProviderPayload<Item> {
    let exchange = try session.accept(response.result)
    let raw = response.rawPayload
    guard Set(response.continuationTokens).count == response.continuationTokens.count,
          response.continuationTokens.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          response.result.nextPageToken == response.continuationTokens.first,
          raw.storageAvailableAt <= response.result.receivedAt,
          raw.licenseRef == exchange.entitlement.licenseRef,
          exchange.result.items.allSatisfy({ item in
              item.provenance.rawObjectRef == raw.reference && item.provenance.rawHash == raw.contentHash
                  && item.provenance.evidenceRef == raw.evidenceRef && item.provenance.licenseRef == raw.licenseRef
          }) else { throw ContractError.mismatchedSource }
    return AcceptedProviderPayload(exchange: exchange, rawPayload: raw, continuationTokens: response.continuationTokens)
}

public struct MarketCalendarClient<Provider: MarketCalendarProvider>: Sendable {
    public let provider: Provider
    public let entitlement: EntitlementSnapshot?
    public init(provider: Provider, entitlement: EntitlementSnapshot?) { self.provider = provider; self.entitlement = entitlement }
    public func sessions(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<MarketSessionRecord> {
        try Task.checkCancellation()
        guard request.capability == .marketCalendar, request.providerID == provider.id else { throw ContractError.mismatchedRequest }
        let session = try ProviderSession(request: request, capabilities: provider.capabilitySnapshot, entitlement: entitlement)
        let response = try await provider.sessions(request: request)
        try Task.checkCancellation()
        return try acceptProviderPayload(response, using: session)
    }
}

public struct CorporateEventsClient<Provider: CorporateEventsProvider>: Sendable {
    public let provider: Provider
    public let entitlement: EntitlementSnapshot?
    public init(provider: Provider, entitlement: EntitlementSnapshot?) { self.provider = provider; self.entitlement = entitlement }
    public func events(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<CorporateEventRecord> {
        try Task.checkCancellation()
        guard [.earningsCalendar, .dividends].contains(request.capability), request.providerID == provider.id
        else { throw ContractError.mismatchedRequest }
        let session = try ProviderSession(request: request, capabilities: provider.capabilitySnapshot, entitlement: entitlement)
        let response = try await provider.events(request: request)
        try Task.checkCancellation()
        return try acceptProviderPayload(response, using: session)
    }
}
