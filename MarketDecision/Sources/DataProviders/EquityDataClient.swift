import Foundation
import DataContracts

/// Stock-only raw payload path; does not pretend to implement Phase 3 option operations.
public protocol EquityDataProvider: ProviderIdentity {
    func quote(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord>
    func dailyBars(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord>
}
public struct EquityDataClient<Provider: EquityDataProvider>: Sendable {
    public let provider: Provider
    public let entitlement: EntitlementSnapshot?
    public init(provider: Provider, entitlement: EntitlementSnapshot?) { self.provider = provider; self.entitlement = entitlement }
    public func fetch(_ request: ProviderRequest) async throws -> AcceptedProviderPayload<EquityRecord> {
        try Task.checkCancellation()
        guard request.providerID == provider.id, [.quote, .bars].contains(request.capability) else {
            throw ContractError.mismatchedRequest
        }
        let session = try ProviderSession(request: request, capabilities: provider.capabilitySnapshot, entitlement: entitlement)
        let response = try await (request.capability == .quote ? provider.quote(request: request) : provider.dailyBars(request: request))
        try Task.checkCancellation()
        for item in response.result.items {
            try item.validate()
            guard item.symbol == request.resourceID, item.kind == (request.capability == .quote ? .quote : .dailyBar) else {
                throw ContractError.mismatchedSource
            }
        }
        return try acceptProviderPayload(response, using: session)
    }
}
