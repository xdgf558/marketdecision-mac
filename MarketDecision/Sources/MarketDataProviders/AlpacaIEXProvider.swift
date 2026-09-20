import Foundation
import CoreDomain
import DataContracts
import DataProviders

/// Candidate adapter only: no default credentials, account enrollment, qualification or App wiring.
/// Feed is explicitly IEX on every request; no SIP fallback, adjusted prices or symbol remapping.
public struct AlpacaIEXProvider: EquityDataProvider {
    public static let configurationVersion = "alpaca-iex-raw-daily.v1"
    public let id = "alpaca"
    public let capabilitySnapshot = CapabilitySnapshot(providerID: "alpaca", version: configurationVersion,
        feeds: ["iex"], capabilities: [.quote, .bars]) // Historical retrieval does not prove vintage PIT.
    private let apiKey: String, secret: String, evidenceRef: String, licenseRef: String
    private let executor: EquityHTTPExecutor
    private let clock: any EquityRequestClock

    public init(apiKey: Data, secret: Data, evidenceRef: String, licenseRef: String,
                transport: any HTTPTransport, clock: any EquityRequestClock = SystemEquityRequestClock()) throws {
        func credential(_ bytes: Data) throws -> String {
            guard let value = String(data: bytes, encoding: .utf8),
                  value.range(of: #"^[A-Za-z0-9_-]{4,256}\z"#, options: .regularExpression) != nil else {
                throw ProviderFailure.authInvalid
            }
            return value
        }
        self.apiKey = try credential(apiKey); self.secret = try credential(secret)
        guard !evidenceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !licenseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContractError.invalidIdentity }
        self.evidenceRef = evidenceRef; self.licenseRef = licenseRef; self.clock = clock
        self.executor = EquityHTTPExecutor(transport: transport, clock: clock)
    }

    public func quote(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord> {
        try validate(request, capability: .quote)
        guard request.range == nil, request.pageToken == nil else { throw ContractError.invalidRequest }
        let raw = try await fetch(request, path: "quotes/latest", query: [])
        guard let object = try MarketJSON.parse(raw.bytes).object, object["symbol"]?.string == request.resourceID,
              let field = object["quote"] else { throw ProviderFailure.malformedResponse }
        var items: [EquityRecord] = []
        if !field.isNull {
            guard let value = field.object, let timestamp = value["t"]?.string,
                  let bidExchange = value["bx"]?.string, let askExchange = value["ax"]?.string else {
                throw ProviderFailure.malformedResponse
            }
            let prices = try EquityQuoteValues(bid: number(value, "bp"), ask: number(value, "ap"),
                bidSize: number(value, "bs"), askSize: number(value, "as"), bidExchange: bidExchange, askExchange: askExchange)
            let provenance = try provenance(request, raw: raw, timestamp: timestamp, quote: prices, bar: nil)
            items = [try EquityRecord(symbol: request.resourceID, sourceTimestamp: timestamp, quote: prices, provenance: provenance)]
        }
        return try response(request, raw: raw, items: items, next: nil)
    }

    public func dailyBars(request: ProviderRequest) async throws -> ProviderPayloadResponse<EquityRecord> {
        try validate(request, capability: .bars)
        guard case let .sourceEvents(range)? = request.range else { throw ContractError.invalidRange }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // The whole request must precede today's NY session date. This does not certify finality
        // or calendar completeness; it only excludes current/future daily aggregates.
        guard range.end < calendar.startOfDay(for: request.requestedAt),
              range.end.timeIntervalSince(range.start) <= 366 * 86_400,
              try MillisecondInstant(rounding: range.start).date == range.start,
              try MillisecondInstant(rounding: range.end).date == range.end else { throw ContractError.invalidRange }
        var query = [URLQueryItem(name: "timeframe", value: "1Day"), URLQueryItem(name: "adjustment", value: "raw"),
                     URLQueryItem(name: "asof", value: "-"), URLQueryItem(name: "sort", value: "asc"),
                     URLQueryItem(name: "limit", value: "1000"),
                     URLQueryItem(name: "start", value: try MillisecondInstant(rounding: range.start).iso8601),
                     URLQueryItem(name: "end", value: try MillisecondInstant(rounding: range.end).iso8601)]
        if let token = request.pageToken {
            guard validToken(token) else { throw ContractError.invalidRequest }
            query.append(URLQueryItem(name: "page_token", value: token))
        }
        let raw = try await fetch(request, path: "bars", query: query)
        guard let object = try MarketJSON.parse(raw.bytes).object, object["symbol"]?.string == request.resourceID,
              let field = object["bars"], let tokenField = object["next_page_token"] else {
            throw ProviderFailure.malformedResponse
        }
        let next = tokenField.isNull ? nil : tokenField.string
        guard tokenField.isNull || next.map(validToken) == true,
              let values = field.isNull ? [] : field.array, values.count <= 1000 else { throw ProviderFailure.malformedResponse }
        let items = try values.map { value -> EquityRecord in
            guard let object = value.object, let timestamp = object["t"]?.string else { throw ProviderFailure.malformedResponse }
            let prices = try EquityDailyBarValues(open: number(object, "o"), high: number(object, "h"),
                low: number(object, "l"), close: number(object, "c"), volume: number(object, "v"),
                vwap: optionalNumber(object["vw"]), trades: optionalInteger(object["n"]))
            return try EquityRecord(symbol: request.resourceID, sourceTimestamp: timestamp, bar: prices,
                provenance: provenance(request, raw: raw, timestamp: timestamp, quote: nil, bar: prices))
        }
        guard zip(items, items.dropFirst()).allSatisfy({ $0.provenance.sourceEventAt! < $1.provenance.sourceEventAt! }) else {
            throw ProviderFailure.malformedResponse
        }
        return try response(request, raw: raw, items: items, next: next)
    }

    private func validate(_ request: ProviderRequest, capability: ProviderCapability) throws {
        try Task.checkCancellation(); try request.validate(); try EquityRecord.validateSymbol(request.resourceID)
        guard request.providerID == id, request.feedID == "iex", request.capability == capability,
              request.configurationVersion == Self.configurationVersion,
              request.requestedAt <= clock.now() else { throw ContractError.mismatchedRequest }
        guard case .latest = request.mode else { throw ProviderFailure.pitUnavailable }
        guard request.usage != .historicalFill, request.usage != .ledgerMark else { throw ProviderFailure.unsupported }
    }
    private func fetch(_ request: ProviderRequest, path: String, query: [URLQueryItem]) async throws -> ProviderRawPayload {
        var components = URLComponents()
        components.scheme = "https"; components.host = "data.alpaca.markets"
        components.path = "/v2/stocks/" + request.resourceID + "/" + path
        components.queryItems = query + [URLQueryItem(name: "feed", value: "iex"), URLQueryItem(name: "currency", value: "USD")]
        guard let url = components.url else { throw ContractError.invalidRequest }
        var outgoing = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        outgoing.httpMethod = "GET"; outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        outgoing.setValue(apiKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        outgoing.setValue(secret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        let payload = try await executor.send(outgoing)
        try Task.checkCancellation()
        guard payload.mediaType?.lowercased().split(separator: ";").first == "application/json",
              !payload.body.isEmpty, payload.body.count <= 4 * 1_024 * 1_024 else { throw ProviderFailure.malformedResponse }
        let received = try MillisecondInstant(rounding: clock.now()).date
        guard received >= request.requestedAt else { throw ContractError.invalidTime }
        return try ProviderRawPayload(reference: "alpaca/iex/" + request.id.uuidString.lowercased(), mediaType: "application/json",
            bytes: payload.body, storageAvailableAt: received, evidenceRef: evidenceRef, licenseRef: licenseRef)
    }
    private func provenance(_ request: ProviderRequest, raw: ProviderRawPayload, timestamp: String,
                            quote: EquityQuoteValues?, bar: EquityDailyBarValues?) throws -> Provenance {
        let time = try EquityRecord.sourceTime(timestamp)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.dateComponents([.year, .month, .day], from: time)
        return Provenance(providerID: id, feedID: "iex", sourceEventAt: time, receivedAt: raw.storageAvailableAt,
            availableAt: nil, evidenceRef: evidenceRef, origin: .provider, endpointDescriptor: request.capability.endpointDescriptor.rawValue,
            requestedAt: request.requestedAt, requestID: request.id,
            observationDate: .init(year: date.year!, month: date.month!, day: date.day!),
            versionID: EquityRecord.contentVersion(symbol: request.resourceID, timestamp: timestamp, quote: quote, bar: bar),
            versionKind: .localContent, availability: .unknown, rawObjectRef: raw.reference, rawHash: raw.contentHash,
            normalizationVersion: "equity.raw-iex.v1", licenseRef: licenseRef, attribution: "Alpaca / IEX single exchange")
    }
    private func response(_ request: ProviderRequest, raw: ProviderRawPayload, items: [EquityRecord], next: String?) throws -> ProviderPayloadResponse<EquityRecord> {
        let result = try ProviderResult(request: request, receivedAt: raw.storageAvailableAt, items: items,
            coverage: .init(expectedCount: nil), nextPageToken: next,
            emptyReason: items.isEmpty && next == nil ? .noResults : nil)
        return ProviderPayloadResponse(result: result, rawPayload: raw, continuationTokens: next.map { [$0] } ?? [])
    }
    private func number(_ object: [String: MarketJSON], _ key: String) throws -> Money {
        guard let value = object[key] else { throw ProviderFailure.malformedResponse }; return try value.money()
    }
    private func optionalNumber(_ value: MarketJSON?) throws -> Money? { try value.flatMap { $0.isNull ? nil : try $0.money() } }
    private func optionalInteger(_ value: MarketJSON?) throws -> Int? { try value.flatMap { $0.isNull ? nil : try $0.integer() } }
    private func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}
