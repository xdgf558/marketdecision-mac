import Foundation
import DataContracts
import DataProviders

/// The App's only candidate-chain factory. In-memory HTTP-shaped pages, no URLSession,
/// credentials, XPC connection or real request; the same client/parser accepts every page.
public enum OptionChainSyntheticCollection {
    public static func capture(id: UUID = UUID(), pageBudget: Int = 14) async throws -> OptionChainCapture {
        let transport = SyntheticTransport()
        let provider = try TradierOptionChainProvider(token: Data("SYNTHETIC-OPTION-TOKEN".utf8), environment: .sandbox,
            timestampUnit: .unixMilliseconds, synthetic: true, transport: transport, clock: SyntheticClock())
        return try await OptionChainDataClient(provider: provider, rights: OptionChainDemo.rights).capture(
            symbol: OptionChainDemo.symbol, expirations: OptionChainDemo.expirations, requestedAt: OptionChainDemo.time,
            id: id, pageBudget: pageBudget)
    }
    private struct SyntheticClock: EquityRequestClock {
        func now() -> Date { OptionChainDemo.time.addingTimeInterval(4) }
        func uptime() -> TimeInterval { 0 }
        func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation() }
    }
    private struct SyntheticTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> HTTPPayload {
            try Task.checkCancellation()
            guard let url = request.url, url.host == "sandbox.tradier.com",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ContractError.invalidRequest }
            let capability: ProviderCapability
            switch url.path {
            case "/v1/markets/quotes": capability = .quote
            case "/v1/markets/options/expirations": capability = .optionExpirations
            case "/v1/markets/options/chains": capability = .optionChain
            default: throw ContractError.invalidEndpoint
            }
            let expiry = try components.queryItems?.first { $0.name == "expiration" }?.value.map(MarketDate.init(iso8601:))
            return HTTPPayload(statusCode: 200, mediaType: "application/json", body: try OptionChainDemo.body(capability: capability, expiration: expiry))
        }
    }
}
