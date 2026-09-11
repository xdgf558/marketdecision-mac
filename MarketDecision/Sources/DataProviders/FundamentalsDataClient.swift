import Foundation
import DataContracts

/// Validates capability, rights, request identity, raw bytes and item provenance before persistence.
/// The accepted wrapper cannot be constructed by callers without this module's validation path.
public struct FundamentalsDataClient<Provider: FundamentalsProvider>: Sendable {
    public let provider: Provider
    public let entitlement: EntitlementSnapshot?
    public init(provider: Provider, entitlement: EntitlementSnapshot?) {
        self.provider = provider; self.entitlement = entitlement
    }

    public func companyIdentity(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<Provider.Identity> {
        try await accepted(request, capability: .companyIdentity) { try await provider.companyIdentity(request: $0) }
    }
    public func submissions(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<Provider.Submission> {
        try await accepted(request, capability: .submissions) { try await provider.submissions(request: $0) }
    }
    public func companyFacts(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<Provider.Facts> {
        try await accepted(request, capability: .companyFacts) { try await provider.companyFacts(request: $0) }
    }
    public func filingIndex(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<Provider.FilingIndex> {
        try await accepted(request, capability: .filingIndex) { try await provider.filingIndex(request: $0) }
    }
    public func filingDocument(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<Provider.FilingDocument> {
        try await accepted(request, capability: .filingDocument) { try await provider.filingDocument(request: $0) }
    }

    private func accepted<Item: ProviderRecord>(_ request: ProviderRequest, capability: ProviderCapability,
        fetch: (ProviderRequest) async throws -> ProviderPayloadResponse<Item>) async throws -> AcceptedProviderPayload<Item> {
        try Task.checkCancellation()
        guard request.capability == capability, request.providerID == provider.id else {
            throw ContractError.mismatchedRequest
        }
        let session = try ProviderSession(request: request, capabilities: provider.capabilitySnapshot,
                                          entitlement: entitlement)
        let response = try await fetch(request)
        try Task.checkCancellation()
        return try acceptProviderPayload(response, using: session)
    }
}
