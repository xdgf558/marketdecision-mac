import Foundation
import DataContracts
import DataProviders

public enum BundledCalendarError: Error, Equatable { case invalidManifest, unsupportedRange }

private struct CalendarException: Codable {
    let date: String
    let state: MarketSessionState
    let reason: String
}
private struct CalendarManifest: Codable {
    let version: String
    let availableAt: String
    let coverageStart: String
    let coverageEnd: String
    let markets: [USEquityMarket]
    let sources: [String]
    let exceptions: [CalendarException]
}

/// Versioned, locally bundled schedule facts. The manifest is deliberately treated as a source
/// payload and still requires caller-supplied rights/evidence configuration; bundling does not
/// certify vendor qualification or grant a redistribution license.
public struct BundledUSMarketCalendarProvider: MarketCalendarProvider {
    public static let providerID = "bundled-us-calendar"
    public static let feedID = "official-curated-2024-2028"
    public static let configurationVersion = "calendar-config.v1"
    public static let resourceID = "XNYS+XNAS"

    public let id = Self.providerID
    public let capabilitySnapshot: CapabilitySnapshot
    private let manifest: CalendarManifest
    private let payload: Data
    private let availableAt: Date
    private let evidenceRef: String
    private let licenseRef: String

    public init(evidenceRef: String, licenseRef: String) throws {
        guard !evidenceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !licenseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = Bundle.module.url(forResource: "us-equity-calendar-2024-2028.v1", withExtension: "json")
        else { throw BundledCalendarError.invalidManifest }
        let payload = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(CalendarManifest.self, from: payload)
        let availableAt = try Self.instant(manifest.availableAt)
        let start = try MarketDate(iso8601: manifest.coverageStart), end = try MarketDate(iso8601: manifest.coverageEnd)
        guard manifest.version == "us-equity-calendar.v1", start <= end,
              Set(manifest.markets) == Set(USEquityMarket.allCases), manifest.sources.count >= 2,
              Set(manifest.exceptions.map(\.date)).count == manifest.exceptions.count,
              manifest.exceptions.allSatisfy({ $0.state == .closed || $0.state == .earlyClose })
        else { throw BundledCalendarError.invalidManifest }
        self.manifest = manifest; self.payload = payload; self.availableAt = availableAt
        self.evidenceRef = evidenceRef; self.licenseRef = licenseRef
        capabilitySnapshot = CapabilitySnapshot(providerID: Self.providerID, version: Self.configurationVersion,
                                                feeds: [Self.feedID], capabilities: [.marketCalendar])
    }

    public func sessions(request: ProviderRequest) async throws -> CalendarProviderResponse<MarketSessionRecord> {
        try Task.checkCancellation()
        guard request.providerID == id, request.feedID == Self.feedID, request.resourceID == Self.resourceID,
              request.capability == .marketCalendar, request.pageToken == nil,
              case .latest = request.mode,
              case let .observationDates(range)? = request.range,
              range.start >= (try MarketDate(iso8601: manifest.coverageStart)),
              range.end <= (try MarketDate(iso8601: manifest.coverageEnd)), request.requestedAt >= availableAt
        else { throw BundledCalendarError.unsupportedRange }
        let rawRef = "bundled/us-equity-calendar/" + request.id.uuidString.lowercased() + ".v1.json"
        let rawHash = digest(payload)
        let exceptions = try Dictionary(uniqueKeysWithValues: manifest.exceptions.map { (try MarketDate(iso8601: $0.date), $0) })
        var items: [MarketSessionRecord] = []
        for date in try range.start.days(through: range.end) {
            let weekday = try Self.weekday(date)
            for market in USEquityMarket.allCases {
                let exception = exceptions[date]
                let state: MarketSessionState = exception?.state ?? ([1, 7].contains(weekday) ? .closed : .regular)
                let reason = exception?.reason ?? (state == .closed ? "weekend" : nil)
                let times = try Self.times(for: date, state: state)
                let provenance = Provenance(providerID: id, feedID: Self.feedID, sourceEventAt: availableAt,
                    receivedAt: request.requestedAt, availableAt: nil, evidenceRef: evidenceRef, origin: .provider,
                    endpointDescriptor: EndpointDescriptor.marketCalendar.rawValue, requestedAt: request.requestedAt,
                    requestID: request.id, observationDate: date, versionID: manifest.version,
                    versionKind: .sourceVersion, availability: .instant(availableAt, evidence: evidenceRef),
                    rawObjectRef: rawRef, rawHash: rawHash, normalizationVersion: "us-market-calendar.v1",
                    licenseRef: licenseRef, attribution: "NYSE and Nasdaq official schedules")
                items.append(try MarketSessionRecord(market: market, date: date, state: state,
                                                     opensAt: times?.0, closesAt: times?.1, reason: reason,
                                                     provenance: provenance))
            }
        }
        let result = try ProviderResult(request: request, receivedAt: request.requestedAt, items: items,
                                        coverage: .init(expectedCount: items.count))
        let raw = try ProviderRawPayload(reference: rawRef, mediaType: "application/json", bytes: payload,
                                         storageAvailableAt: request.requestedAt, evidenceRef: evidenceRef, licenseRef: licenseRef)
        return CalendarProviderResponse(result: result, rawPayload: raw)
    }

    private static func instant(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { throw BundledCalendarError.invalidManifest }
        return date
    }
    private static func weekday(_ date: MarketDate) throws -> Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.component(.weekday, from: try date.start(in: calendar.timeZone))
    }
    private static func times(for date: MarketDate, state: MarketSessionState) throws -> (Date, Date)? {
        guard state == .regular || state == .earlyClose else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = try date.start(in: calendar.timeZone)
        guard let open = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: day),
              let close = calendar.date(bySettingHour: state == .regular ? 16 : 13, minute: 0, second: 0, of: day)
        else { throw ContractError.invalidTime }
        return (open, close)
    }
}
