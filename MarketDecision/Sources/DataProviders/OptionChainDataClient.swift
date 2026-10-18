import Foundation
import DataContracts

/// Raw single-cycle collection protocol. No default production transport or credentials.
public protocol OptionChainCaptureProvider: Sendable {
    var environment: OptionChainEnvironment { get }
    var timestampUnit: OptionChainTimestampUnit { get }
    var synthetic: Bool { get }
    func page(request: ProviderRequest, expiration: MarketDate?) async throws -> OptionChainRawPage
}
public struct OptionChainDataClient<Provider: OptionChainCaptureProvider>: Sendable {
    public let provider: Provider
    public let rights: OptionChainRights
    public init(provider: Provider, rights: OptionChainRights) { self.provider = provider; self.rights = rights }
    /// Expirations are an explicit bounded selection. Fetching ends in a partial envelope at
    /// pageBudget; no later page, empty result or failed HTTP page can silently fill the gap.
    public func capture(symbol: String, expirations: [MarketDate], requestedAt: Date,
                        id: UUID = UUID(), pageBudget: Int = 14) async throws -> OptionChainCapture {
        try Task.checkCancellation()
        try EquityRecord.validateSymbol(symbol)
        guard !expirations.isEmpty, expirations.count <= 12, expirations == expirations.sorted(),
              Set(expirations).count == expirations.count, (2...14).contains(pageBudget) else { throw ContractError.invalidCoverage }
        for expiry in expirations { _ = try expiry.start(in: TimeZone(secondsFromGMT: 0)!) }
        let capabilities = OptionChainCapture.capabilities(environment: provider.environment)
        let entitlement = rights.entitlement(environment: provider.environment)
        func request(_ capability: ProviderCapability) throws -> ProviderRequest {
            let value = ProviderRequest(id: id, providerID: "tradier", feedID: provider.environment.feedID,
                resourceID: symbol, capability: capability, mode: .latest, usage: .replay,
                configurationVersion: OptionChainCapture.configurationVersion, entitlementVersion: rights.version, requestedAt: requestedAt)
            try ProviderAccess.validate(value, capabilities: capabilities, entitlement: entitlement)
            return value
        }
        // Validate every required capability before the first dispatch, not after reading quote bytes.
        let quote = try request(.quote), dates = try request(.optionExpirations), chain = try request(.optionChain)
        var pages: [OptionChainRawPage] = []
        for (request, expiry) in [(quote, Optional<MarketDate>.none), (dates, nil)] + expirations.map({ (chain, Optional($0)) }) {
            try Task.checkCancellation()
            if pages.count >= pageBudget { break }
            if let expiry {
                guard let prior = pages.last else { throw ContractError.invalidCoverage }
                let interim = try OptionChainCapture(id: id, createdAt: prior.receivedAt, requestedAt: requestedAt,
                    symbol: symbol, environment: provider.environment, timestampUnit: provider.timestampUnit, synthetic: provider.synthetic,
                    rights: rights, requestedExpirations: expirations, pages: pages)
                guard interim.snapshot.listedExpirations.contains(expiry) else { throw ContractError.invalidCoverage }
            }
            let page = try await provider.page(request: request, expiration: expiry)
            try Task.checkCancellation() // An ignoring provider cannot publish a late success after cancellation.
            guard page.request == request, page.expiration == expiry else { throw ContractError.mismatchedRequest }
            pages.append(page)
            // Accept and replay every page immediately; malformed/provider-error data never flows to the next request.
            let interim = try OptionChainCapture(id: id, createdAt: page.receivedAt, requestedAt: requestedAt,
                symbol: symbol, environment: provider.environment, timestampUnit: provider.timestampUnit, synthetic: provider.synthetic,
                rights: rights, requestedExpirations: expirations, pages: pages)
            if !interim.snapshot.failures.isEmpty || interim.snapshot.status == .empty { return interim }
        }
        guard let last = pages.last else { throw ContractError.invalidCoverage }
        try Task.checkCancellation()
        return try OptionChainCapture(id: id, createdAt: last.receivedAt, requestedAt: requestedAt, symbol: symbol,
            environment: provider.environment, timestampUnit: provider.timestampUnit, synthetic: provider.synthetic,
            rights: rights, requestedExpirations: expirations, pages: pages)
    }
}
