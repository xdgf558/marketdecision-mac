import Foundation
import CryptoKit
import CoreDomain
import DataContracts

/// Compatibility entry point used by the existing offline demo UI.
public protocol QuoteProvider: Sendable {
    var id: String { get }
    func quote(for symbol: String) async throws -> Quote
}
public typealias ProviderError = ProviderFailure
public struct MockRecord: ProviderRecord {
    public let recordID: String
    public let provenance: Provenance
}
public struct MockChainRecord: OptionChainRecord {
    public let recordID: String
    public let provenance: Provenance
    public let underlyingQuote: Quote
    public let contractProvenances: [Provenance]
}
/// Deterministic synthetic transport fixture. Its rights record is synthetic, not vendor evidence.
/// No sample can pass Quote.eligibility because all returned quotes carry the synthetic flag.
public struct MockQuoteProvider: QuoteProvider, MarketDataProvider {
    public typealias Bar = MockRecord
    public typealias Expiration = MockRecord
    public typealias Chain = MockChainRecord
    public enum Scenario: Sendable { case complete, partial, empty, failure(ProviderFailure) }
    public let id = "mock.synthetic.v1"
    public let scenario: Scenario
    public init(scenario: Scenario = .complete) { self.scenario = scenario }
    public var capabilitySnapshot: CapabilitySnapshot {
        CapabilitySnapshot(providerID: id, version: "mock.capabilities.v1", feeds: ["synthetic"], capabilities: [.quote])
    }
    public func request(for symbol: String, at date: Date) -> ProviderRequest {
        ProviderRequest(providerID: id, feedID: "synthetic", resourceID: symbol, capability: .quote, mode: .latest,
                        usage: .liveAnalysis, configurationVersion: "mock.config.v1", entitlementVersion: "mock.rights.v1", requestedAt: date)
    }
    private func syntheticRights(at date: Date) -> EntitlementSnapshot {
        EntitlementSnapshot(providerID: id, feedID: "synthetic", version: "mock.rights.v1", evidenceRef: "synthetic-rights-only",
                            licenseRef: "synthetic-fixture", capabilities: [.quote], usages: [.liveAnalysis], validFrom: date, validThrough: date)
    }
    public func quote(for symbol: String) async throws -> Quote {
        let request = request(for: symbol, at: Date(timeIntervalSince1970: 1_783_000_000))
        let result = try await quote(request: request)
        try result.validate(matching: request)
        guard result.status == .complete, let quote = result.items.first else { throw ProviderFailure.malformedResponse }
        return quote
    }
    public func quote(request: ProviderRequest) async throws -> ProviderResult<Quote> {
        try Task.checkCancellation()
        try ProviderAccess.validate(request, capabilities: capabilitySnapshot, entitlement: syntheticRights(at: request.requestedAt))
        guard request.capability == .quote else { throw ProviderFailure.unsupported }
        guard request.resourceID == "DEMO" else { throw ProviderFailure.symbolUnavailable }
        if case let .failure(error) = scenario {
            return try ProviderResult(request: request, receivedAt: request.requestedAt, items: [], coverage: .init(expectedCount: nil), errors: [error])
        }
        if case .empty = scenario {
            return try ProviderResult(request: request, receivedAt: request.requestedAt, items: [], coverage: .init(expectedCount: 0), emptyReason: .noResults)
        }
        let raw = Data("DEMO|99.50|100.50|synthetic".utf8)
        let provenance = Provenance(providerID: id, feedID: request.feedID, sourceEventAt: request.requestedAt,
            receivedAt: request.requestedAt, availableAt: nil, evidenceRef: "synthetic-quote-only", origin: .derived,
            endpointDescriptor: "mock/quotes/{symbol}", requestedAt: request.requestedAt, requestID: request.id,
            versionID: "synthetic.quote.v1", versionKind: .localContent, rawObjectRef: "synthetic.quote.raw.v1",
            rawHash: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(), normalizationVersion: "mock.normalize.v1",
            licenseRef: "synthetic-fixture")
        let quote = Quote(symbol: request.resourceID, bid: try Money("99.50"), ask: try Money("100.50"),
                          provenance: provenance, timeliness: .unknown, quality: [.synthetic])
        let partial: Bool
        if case .partial = scenario { partial = true } else { partial = false }
        return try ProviderResult(request: request, receivedAt: request.requestedAt, items: [quote],
                                  coverage: .init(expectedCount: 1, truncated: partial))
    }
    public func bars(request: ProviderRequest) async throws -> ProviderResult<MockRecord> { try Task.checkCancellation(); throw ProviderFailure.unsupported }
    public func optionExpirations(request: ProviderRequest) async throws -> ProviderResult<MockRecord> { try Task.checkCancellation(); throw ProviderFailure.unsupported }
    public func optionChain(request: ProviderRequest) async throws -> ProviderResult<MockChainRecord> { try Task.checkCancellation(); throw ProviderFailure.unsupported }
}
