import Foundation
import CoreDomain
import DataContracts
import DataProviders

public struct HTTPPayload: Sendable {
    public let statusCode: Int
    public let mediaType: String?
    public let body: Data
    public init(statusCode: Int, mediaType: String?, body: Data) {
        self.statusCode = statusCode; self.mediaType = mediaType; self.body = body
    }
}
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPPayload }
public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> HTTPPayload {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.malformedResponse }
        return HTTPPayload(statusCode: http.statusCode, mediaType: http.mimeType, body: data)
    }
}

public enum AlphaVantageAdapterError: Error, Equatable { case invalidConfiguration, malformedCSV }

/// Free-key candidate adapter. It exposes provider responses only; callers must separately supply
/// and review entitlement/license evidence. No API key is built in and no provider is auto-qualified.
public struct AlphaVantageCorporateEventsProvider<Transport: HTTPTransport>: CorporateEventsProvider {
    public static var providerID: String { "alpha-vantage" }
    public static var feedID: String { "free-calendar" }
    public static var configurationVersion: String { "alpha-vantage-calendar.v1" }

    public let id = Self.providerID
    public let capabilitySnapshot: CapabilitySnapshot
    private let apiKey: Data
    private let transport: Transport
    private let evidenceRef: String
    private let licenseRef: String
    private let now: @Sendable () -> Date

    public init(apiKey: Data, transport: Transport, evidenceRef: String, licenseRef: String,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard let key = String(data: apiKey, encoding: .utf8),
              key.range(of: #"^[A-Za-z0-9]{4,128}\z"#, options: .regularExpression) != nil,
              !evidenceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !licenseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AlphaVantageAdapterError.invalidConfiguration }
        self.apiKey = apiKey; self.transport = transport; self.evidenceRef = evidenceRef
        self.licenseRef = licenseRef; self.now = now
        capabilitySnapshot = CapabilitySnapshot(providerID: Self.providerID, version: Self.configurationVersion,
                                                feeds: [Self.feedID], capabilities: [.earningsCalendar, .dividends])
    }

    public func events(request: ProviderRequest) async throws -> CalendarProviderResponse<CorporateEventRecord> {
        try Task.checkCancellation()
        guard request.providerID == id, request.feedID == Self.feedID,
              request.capability == .earningsCalendar || request.capability == .dividends,
              case .latest = request.mode, request.pageToken == nil,
              request.resourceID.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}\z"#, options: .regularExpression) != nil
        else { throw ContractError.mismatchedRequest }
        let url = try endpoint(for: request)
        let payload = try await transport.send(URLRequest(url: url))
        try Task.checkCancellation()
        guard (200...299).contains(payload.statusCode) else { throw ProviderFailure.fromHTTP(payload.statusCode) }
        try Self.rejectProviderError(payload.body)
        let receivedAt = max(now(), request.requestedAt)
        let rawRef = "provider/alpha-vantage/" + request.id.uuidString.lowercased()
            + (request.capability == .earningsCalendar ? ".csv" : ".json")
        let raw = try ProviderRawPayload(reference: rawRef,
            mediaType: request.capability == .earningsCalendar ? "text/csv" : "application/json",
            bytes: payload.body, storageAvailableAt: receivedAt, evidenceRef: evidenceRef, licenseRef: licenseRef)
        let items = try request.capability == .earningsCalendar
            ? parseEarnings(payload.body, request: request, raw: raw, receivedAt: receivedAt)
            : parseDividends(payload.body, request: request, raw: raw, receivedAt: receivedAt)
        let result = try ProviderResult(request: request, receivedAt: receivedAt, items: items,
            coverage: .init(expectedCount: items.count), emptyReason: items.isEmpty ? .noResults : nil)
        return CalendarProviderResponse(result: result, rawPayload: raw)
    }

    private func endpoint(for request: ProviderRequest) throws -> URL {
        guard let key = String(data: apiKey, encoding: .utf8) else { throw AlphaVantageAdapterError.invalidConfiguration }
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            .init(name: "function", value: request.capability == .earningsCalendar ? "EARNINGS_CALENDAR" : "DIVIDENDS"),
            .init(name: "symbol", value: request.resourceID),
            .init(name: "apikey", value: key)
        ]
        if request.capability == .earningsCalendar { components.queryItems?.insert(.init(name: "horizon", value: "3month"), at: 2) }
        guard let url = components.url else { throw AlphaVantageAdapterError.invalidConfiguration }
        return url
    }

    private static func rejectProviderError(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["Note"] != nil || object["Information"] != nil { throw ProviderFailure.rateLimited }
        if object["Error Message"] != nil { throw ProviderFailure.malformedResponse }
    }

    private func provenance(request: ProviderRequest, raw: ProviderRawPayload, receivedAt: Date,
                            eventDate: MarketDate?, versionSuffix: String) -> Provenance {
        Provenance(providerID: id, feedID: Self.feedID, sourceEventAt: request.requestedAt,
            receivedAt: receivedAt, availableAt: nil, evidenceRef: evidenceRef, origin: .provider,
            endpointDescriptor: request.capability.endpointDescriptor.rawValue, requestedAt: request.requestedAt,
            requestID: request.id, observationDate: eventDate,
            versionID: "alpha." + String(raw.contentHash.prefix(16)) + "." + versionSuffix,
            versionKind: .sourceVersion, availability: .unknown,
            rawObjectRef: raw.reference, rawHash: raw.contentHash, normalizationVersion: "alpha-calendar.v1",
            licenseRef: licenseRef, attribution: "Alpha Vantage")
    }

    private func parseEarnings(_ data: Data, request: ProviderRequest, raw: ProviderRawPayload,
                               receivedAt: Date) throws -> [CorporateEventRecord] {
        guard let text = String(data: data, encoding: .utf8) else { throw ProviderFailure.malformedResponse }
        let rows = try Self.csv(text)
        guard let headers = rows.first else { return [] }
        let names = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, $0.offset) })
        guard let symbolIndex = names["symbol"], let reportIndex = names["reportDate"],
              let fiscalIndex = names["fiscalDateEnding"] else { throw AlphaVantageAdapterError.malformedCSV }
        return try rows.dropFirst().enumerated().compactMap { offset, row in
            guard !row.allSatisfy({ $0.isEmpty }), row.indices.contains(symbolIndex), row.indices.contains(reportIndex), row.indices.contains(fiscalIndex)
            else { return nil }
            let symbol = row[symbolIndex].uppercased(), fiscal = row[fiscalIndex]
            guard symbol == request.resourceID, !fiscal.isEmpty else { throw ContractError.mismatchedSource }
            let eventDate = row[reportIndex].isEmpty ? nil : try MarketDate(iso8601: row[reportIndex])
            return try CorporateEventRecord(recordID: "earnings/" + symbol + "/" + fiscal,
                symbol: symbol, kind: .earnings, eventDate: eventDate,
                timing: eventDate == nil ? .unknown : .unknown,
                certainty: eventDate == nil ? .unknown : .estimated,
                provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                                       eventDate: eventDate, versionSuffix: String(offset)))
        }
    }

    private struct DividendEnvelope: Decodable { let data: [DividendRow]? }
    private struct DividendRow: Decodable {
        let exDividendDate: String?
        let declarationDate: String?
        let amount: String?
        enum CodingKeys: String, CodingKey {
            case exDividendDate = "ex_dividend_date", declarationDate = "declaration_date", amount
        }
    }
    private func parseDividends(_ data: Data, request: ProviderRequest, raw: ProviderRawPayload,
                                receivedAt: Date) throws -> [CorporateEventRecord] {
        let rows: [DividendRow]
        do { rows = try JSONDecoder().decode(DividendEnvelope.self, from: data).data ?? [] }
        catch { throw ProviderFailure.malformedResponse }
        return try rows.enumerated().map { offset, row in
            let eventDate = try row.exDividendDate.flatMap { $0.isEmpty ? nil : try MarketDate(iso8601: $0) }
            let amount = try row.amount.flatMap { $0.isEmpty ? nil : try Money($0) }
            let identityDate = row.declarationDate?.isEmpty == false ? row.declarationDate! : (row.exDividendDate ?? "unknown")
            return try CorporateEventRecord(recordID: "dividend/" + request.resourceID + "/" + identityDate,
                symbol: request.resourceID, kind: .exDividend, eventDate: eventDate,
                timing: .notApplicable,
                certainty: eventDate == nil ? .unknown : .confirmed,
                declaredAmount: amount, currency: amount == nil ? nil : "USD",
                provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                                       eventDate: eventDate, versionSuffix: String(offset)))
        }
    }

    private static func csv(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let scalars = Array(text.unicodeScalars); var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if quoted {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" { field.unicodeScalars.append(scalar); index += 1 }
                    else { quoted = false }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == "\"" { quoted = true }
            else if scalar == "," { row.append(field); field = "" }
            else if scalar == "\n" { row.append(field.trimmingCharacters(in: .newlines)); rows.append(row); row = []; field = "" }
            else if scalar != "\r" { field.unicodeScalars.append(scalar) }
            index += 1
        }
        guard !quoted else { throw AlphaVantageAdapterError.malformedCSV }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        if !rows.isEmpty { rows[0][0] = rows[0][0].trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) }
        return rows
    }
}
