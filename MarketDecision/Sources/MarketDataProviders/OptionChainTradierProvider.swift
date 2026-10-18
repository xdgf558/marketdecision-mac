import Foundation
import DataContracts
import DataProviders

/// Candidate only. Does not install a URLSession, XPC service, Keychain path, account or entitlement.
/// The token is injected into this short-lived owner and never enters the frozen source envelope.
public struct TradierOptionChainProvider: OptionChainCaptureProvider {
    public let environment: OptionChainEnvironment
    public let timestampUnit: OptionChainTimestampUnit
    public let synthetic: Bool
    private let token: String
    private let transport: any HTTPTransport
    private let clock: any EquityRequestClock
    public init(token: Data, environment: OptionChainEnvironment, timestampUnit: OptionChainTimestampUnit,
                synthetic: Bool = false, transport: any HTTPTransport,
                clock: any EquityRequestClock = SystemEquityRequestClock()) throws {
        guard let value = String(data: token, encoding: .utf8), value.range(of: #"^[A-Za-z0-9._-]{4,256}\z"#, options: .regularExpression) != nil else {
            throw ProviderFailure.authInvalid
        }
        self.token = value; self.environment = environment; self.timestampUnit = timestampUnit
        self.synthetic = synthetic; self.transport = transport; self.clock = clock
    }
    public func page(request: ProviderRequest, expiration: MarketDate?) async throws -> OptionChainRawPage {
        try Task.checkCancellation(); try request.validate(); try EquityRecord.validateSymbol(request.resourceID)
        guard request.providerID == "tradier", request.feedID == environment.feedID, request.usage == .replay,
              request.configurationVersion == OptionChainCapture.configurationVersion, request.mode == .latest,
              request.range == nil, request.pageToken == nil, request.requestedAt <= clock.now() else { throw ContractError.mismatchedRequest }
        var url = URLComponents(); url.scheme = "https"; url.host = environment.host
        switch request.capability {
        case .quote:
            guard expiration == nil else { throw ContractError.invalidRequest }
            url.path = "/v1/markets/quotes"
            url.queryItems = [.init(name: "symbols", value: request.resourceID), .init(name: "greeks", value: "false")]
        case .optionExpirations:
            guard expiration == nil else { throw ContractError.invalidRequest }
            url.path = "/v1/markets/options/expirations"
            url.queryItems = [.init(name: "symbol", value: request.resourceID), .init(name: "includeAllRoots", value: "true")]
        case .optionChain:
            guard let expiration else { throw ContractError.invalidRequest }
            _ = try expiration.start(in: TimeZone(secondsFromGMT: 0)!)
            url.path = "/v1/markets/options/chains"
            url.queryItems = [.init(name: "symbol", value: request.resourceID), .init(name: "expiration", value: expiration.iso8601),
                              .init(name: "greeks", value: "false")]
        default: throw ProviderFailure.unsupported
        }
        guard let endpoint = url.url else { throw ContractError.invalidRequest }
        var outgoing = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        outgoing.httpMethod = "GET"; outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        outgoing.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let response: HTTPPayload
        do { response = try await transport.send(outgoing) }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); throw ProviderFailure.offline }
        try Task.checkCancellation()
        guard response.mediaType?.lowercased().split(separator: ";").first == "application/json",
              !response.body.isEmpty, response.body.count <= 4 * 1_024 * 1_024 else { throw ProviderFailure.malformedResponse }
        let receivedAt = clock.now()
        guard receivedAt.timeIntervalSince1970.isFinite, request.requestedAt <= receivedAt else { throw ContractError.invalidTime }
        return OptionChainRawPage(request: request, expiration: expiration, receivedAt: receivedAt,
                                  statusCode: response.statusCode, bytes: response.body)
    }
}
