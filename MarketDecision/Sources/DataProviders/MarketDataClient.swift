import Foundation
import DataContracts

/// Enforces the same context before dispatch and after return. No retry or feed fallback is implicit.
public struct MarketDataClient<Provider: MarketDataProvider>: Sendable {
    public let provider: Provider
    public let entitlement: EntitlementSnapshot?
    public init(provider: Provider, entitlement: EntitlementSnapshot?) { self.provider = provider; self.entitlement = entitlement }
    private func session(_ request: ProviderRequest, for capability: ProviderCapability) throws -> ProviderSession {
        try Task.checkCancellation()
        guard request.capability == capability, request.providerID == provider.id else { throw ContractError.mismatchedRequest }
        return try ProviderSession(request: request, capabilities: provider.capabilitySnapshot, entitlement: entitlement)
    }
    public func quote(_ request: ProviderRequest) async throws -> ProviderExchange<Quote> {
        let session = try session(request, for: .quote)
        let result = try await provider.quote(request: request)
        try Task.checkCancellation()
        return try session.accept(result)
    }
    public func bars(_ request: ProviderRequest) async throws -> ProviderExchange<Provider.Bar> {
        let session = try session(request, for: .bars)
        let result = try await provider.bars(request: request)
        try Task.checkCancellation()
        return try session.accept(result)
    }
    public func optionExpirations(_ request: ProviderRequest) async throws -> ProviderExchange<Provider.Expiration> {
        let session = try session(request, for: .optionExpirations)
        let result = try await provider.optionExpirations(request: request)
        try Task.checkCancellation()
        return try session.accept(result)
    }
    public func optionChain(_ request: ProviderRequest) async throws -> ProviderExchange<Provider.Chain> {
        let session = try session(request, for: .optionChain)
        let result = try await provider.optionChain(request: request)
        try Task.checkCancellation()
        for item in result.items { try item.validateRequestCycle() }
        return try session.accept(result)
    }
}
