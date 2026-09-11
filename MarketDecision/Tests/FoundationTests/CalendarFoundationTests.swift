import Foundation
import Testing
import CoreDomain
import DataContracts
import DataProviders
import MarketDataProviders
import Persistence

private func calendarUTC(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private let calendarNow = calendarUTC("2026-09-12T12:00:00Z")
private func calendarRights(provider: String, feed: String, capabilities: Set<ProviderCapability>, license: String) -> EntitlementSnapshot {
    EntitlementSnapshot(providerID: provider, feedID: feed, version: "rights.v1", evidenceRef: "rights-reviewed-locally",
                        licenseRef: license, capabilities: capabilities, usages: [.pitResearch, .liveAnalysis],
                        validFrom: calendarNow.addingTimeInterval(-86_400), validThrough: calendarNow.addingTimeInterval(86_400))
}
private func calendarRequest(start: String, end: String) throws -> ProviderRequest {
    ProviderRequest(providerID: BundledUSMarketCalendarProvider.providerID,
                    feedID: BundledUSMarketCalendarProvider.feedID,
                    resourceID: BundledUSMarketCalendarProvider.resourceID, capability: .marketCalendar,
                    mode: .latest, range: .observationDates(.init(start: try MarketDate(iso8601: start), end: try MarketDate(iso8601: end))),
                    usage: .pitResearch, configurationVersion: BundledUSMarketCalendarProvider.configurationVersion,
                    entitlementVersion: "rights.v1", requestedAt: calendarNow)
}
private func calendarClient() throws -> MarketCalendarClient<BundledUSMarketCalendarProvider> {
    let license = "calendar-license-review.v1"
    let provider = try BundledUSMarketCalendarProvider(evidenceRef: "calendar-source-review.v1", licenseRef: license)
    return MarketCalendarClient(provider: provider,
        entitlement: calendarRights(provider: provider.id, feed: BundledUSMarketCalendarProvider.feedID,
                                    capabilities: [.marketCalendar], license: license))
}
private func temporaryCalendarPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("market-calendar-\(UUID().uuidString).sqlite").path
}

private struct FixtureHTTPTransport: HTTPTransport {
    let payload: HTTPPayload
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        guard request.url?.scheme == "https", request.url?.host == "www.alphavantage.co" else { throw ProviderFailure.malformedResponse }
        return payload
    }
}
private func eventRequest(_ capability: ProviderCapability, symbol: String = "IBM") -> ProviderRequest {
    ProviderRequest(providerID: "alpha-vantage", feedID: "free-calendar", resourceID: symbol,
                    capability: capability, mode: .latest,
                    range: .sourceEvents(.init(start: calendarNow, end: calendarNow)), usage: .pitResearch,
                    configurationVersion: "alpha-vantage-calendar.v1", entitlementVersion: "rights.v1", requestedAt: calendarNow)
}
private func eventRights(_ capabilities: Set<ProviderCapability>) -> EntitlementSnapshot {
    calendarRights(provider: "alpha-vantage", feed: "free-calendar", capabilities: capabilities, license: "alpha-license-review.v1")
}

private struct IncompleteCalendarProvider: MarketCalendarProvider {
    let mismatchedRaw: Bool
    init(mismatchedRaw: Bool = false) { self.mismatchedRaw = mismatchedRaw }
    let id = "incomplete-calendar"
    let capabilitySnapshot = CapabilitySnapshot(providerID: "incomplete-calendar", version: "caps.v1",
                                                feeds: ["fixture"], capabilities: [.marketCalendar])
    func sessions(request: ProviderRequest) async throws -> CalendarProviderResponse<MarketSessionRecord> {
        let bytes = Data("partial calendar".utf8), rawRef = "fixture/partial-calendar"
        let provenance = Provenance(providerID: id, feedID: "fixture", sourceEventAt: calendarNow,
            receivedAt: calendarNow, availableAt: nil, evidenceRef: "fixture-evidence", origin: .provider,
            endpointDescriptor: EndpointDescriptor.marketCalendar.rawValue, requestedAt: request.requestedAt,
            requestID: request.id, observationDate: .init(year: 2026, month: 11, day: 27), versionID: "fixture.v1",
            versionKind: .sourceVersion, availability: .instant(calendarNow, evidence: "fixture-evidence"),
            rawObjectRef: rawRef, rawHash: digest(bytes), normalizationVersion: "fixture.v1", licenseRef: "fixture-license")
        let item = try MarketSessionRecord(market: .nyse, date: .init(year: 2026, month: 11, day: 27),
            state: .earlyClose, opensAt: calendarUTC("2026-11-27T14:30:00Z"), closesAt: calendarUTC("2026-11-27T18:00:00Z"),
            reason: "fixture early close", provenance: provenance)
        let result = try ProviderResult(request: request, receivedAt: calendarNow, items: [item],
            coverage: .init(expectedCount: 2, missing: [.init(resourceID: "XNAS/2026-11-27", reason: .offline)]))
        return CalendarProviderResponse(result: result,
            rawPayload: try ProviderRawPayload(reference: rawRef, mediaType: "text/plain",
                bytes: mismatchedRaw ? Data("substituted payload".utf8) : bytes,
                storageAvailableAt: calendarNow, evidenceRef: "fixture-evidence", licenseRef: "fixture-license"))
    }
}

private struct KnownEventProvider: CorporateEventsProvider {
    let version: String
    let eventDate: MarketDate
    let availableAt: Date
    let id = "known-events"
    let capabilitySnapshot = CapabilitySnapshot(providerID: "known-events", version: "caps.v1",
                                                feeds: ["fixture"], capabilities: [.earningsCalendar])
    func events(request: ProviderRequest) async throws -> CalendarProviderResponse<CorporateEventRecord> {
        let bytes = Data("known-event-\(version)".utf8), rawRef = "fixture/known-event/\(version)"
        let provenance = Provenance(providerID: id, feedID: "fixture", sourceEventAt: request.requestedAt,
            receivedAt: request.requestedAt, availableAt: nil, evidenceRef: "fixture-evidence", origin: .provider,
            endpointDescriptor: EndpointDescriptor.earningsCalendar.rawValue, requestedAt: request.requestedAt,
            requestID: request.id, observationDate: eventDate, versionID: version, versionKind: .sourceVersion,
            availability: .instant(availableAt, evidence: "fixture-evidence"), rawObjectRef: rawRef,
            rawHash: digest(bytes), normalizationVersion: "fixture.v1", licenseRef: "fixture-license")
        let item = try CorporateEventRecord(recordID: "earnings/IBM/2026-09-30", symbol: "IBM", kind: .earnings,
            eventDate: eventDate, timing: .unknown, certainty: .estimated, provenance: provenance)
        let result = try ProviderResult(request: request, receivedAt: request.requestedAt, items: [item], coverage: .init(expectedCount: 1))
        return CalendarProviderResponse(result: result,
            rawPayload: try ProviderRawPayload(reference: rawRef, mediaType: "text/plain", bytes: bytes,
                storageAvailableAt: request.requestedAt, evidenceRef: "fixture-evidence", licenseRef: "fixture-license"))
    }
}
private func knownEventRequest() -> ProviderRequest {
    ProviderRequest(providerID: "known-events", feedID: "fixture", resourceID: "IBM", capability: .earningsCalendar,
        mode: .latest, range: .sourceEvents(.init(start: calendarNow, end: calendarNow)), usage: .pitResearch,
        configurationVersion: "caps.v1", entitlementVersion: "rights.v1", requestedAt: calendarNow)
}

@Suite struct PhaseOneCalendarTests {
    @Test func bundledScheduleCoversUnexpectedClosuresHalfDaysAndDST() async throws {
        let client = try calendarClient()
        let mourning = try await client.sessions(calendarRequest(start: "2025-01-09", end: "2025-01-09")).exchange.result.items
        #expect(mourning.count == 2 && mourning.allSatisfy { $0.state == .closed && $0.reason == "National Day of Mourning" })

        let thanksgiving = try await client.sessions(calendarRequest(start: "2026-11-26", end: "2026-11-27")).exchange.result.items
        #expect(thanksgiving.filter { $0.date.iso8601 == "2026-11-26" }.allSatisfy { $0.state == .closed })
        #expect(thanksgiving.filter { $0.date.iso8601 == "2026-11-27" }.allSatisfy {
            $0.state == .earlyClose && $0.closesAt == calendarUTC("2026-11-27T18:00:00Z")
        })

        let dst = try await client.sessions(calendarRequest(start: "2026-03-06", end: "2026-03-09")).exchange.result.items
        let before = try #require(dst.first { $0.market == .nyse && $0.date.iso8601 == "2026-03-06" })
        let after = try #require(dst.first { $0.market == .nyse && $0.date.iso8601 == "2026-03-09" })
        #expect(before.opensAt == calendarUTC("2026-03-06T14:30:00Z"))
        #expect(after.opensAt == calendarUTC("2026-03-09T13:30:00Z"))
    }

    @Test func acceptedCalendarPersistsReopensAndNeverFillsMissingAsOfRows() async throws {
        let path = temporaryCalendarPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let accepted = try await calendarClient().sessions(calendarRequest(start: "2026-11-26", end: "2026-11-27"))
        let store = try BusinessDataStore(path: path)
        let receipt = try await store.ingestMarketCalendar(accepted, expectedRevision: store.revision())
        #expect(receipt.insertedDocuments == 1 && receipt.insertedRecords == 4)
        _ = try await store.purgeCache(seriesIDs: ["unrelated-series"], expectedRevision: store.revision())
        #expect(try await store.sourceDocument(reference: accepted.rawPayload.reference).contentHash == accepted.rawPayload.contentHash)
        let reopened = try BusinessDataStore(path: path)
        let rows = try await reopened.marketSessions(market: .nasdaq,
            range: .init(start: try MarketDate(iso8601: "2026-11-26"), end: try MarketDate(iso8601: "2026-11-27")), asOf: calendarNow)
        #expect(rows.map(\.state) == [.closed, .earlyClose])
        await #expect(throws: TradingCalendarError.nonTradingDay) {
            try await reopened.validateExpiration(try MarketDate(iso8601: "2026-11-26"), market: .nasdaq, asOf: calendarNow)
        }
        await #expect(throws: TradingCalendarError.incompleteCoverage) {
            try await reopened.marketSession(market: .nasdaq, on: try MarketDate(iso8601: "2026-11-27"),
                                             asOf: calendarUTC("2026-09-10T23:59:59Z"))
        }
    }

    @Test func partialCalendarCannotEnterSQLiteEvenAfterTransportAcceptance() async throws {
        let provider = IncompleteCalendarProvider()
        let request = ProviderRequest(providerID: provider.id, feedID: "fixture", resourceID: "XNYS+XNAS",
            capability: .marketCalendar, mode: .latest,
            range: .observationDates(.init(start: .init(year: 2026, month: 11, day: 27), end: .init(year: 2026, month: 11, day: 27))),
            usage: .pitResearch, configurationVersion: "caps.v1", entitlementVersion: "rights.v1", requestedAt: calendarNow)
        let rights = calendarRights(provider: provider.id, feed: "fixture", capabilities: [.marketCalendar], license: "fixture-license")
        let accepted = try await MarketCalendarClient(provider: provider, entitlement: rights).sessions(request)
        #expect(accepted.exchange.result.status == .partial)
        let store = try BusinessDataStore(path: ":memory:")
        await #expect(throws: TradingCalendarError.incompleteCoverage) {
            try await store.ingestMarketCalendar(accepted, expectedRevision: store.revision())
        }
    }

    @Test func acceptedPipelineRejectsRawPayloadSubstitutionBeforePersistence() async throws {
        let provider = IncompleteCalendarProvider(mismatchedRaw: true)
        let request = ProviderRequest(providerID: provider.id, feedID: "fixture", resourceID: "XNYS+XNAS",
            capability: .marketCalendar, mode: .latest,
            range: .observationDates(.init(start: .init(year: 2026, month: 11, day: 27), end: .init(year: 2026, month: 11, day: 27))),
            usage: .pitResearch, configurationVersion: "caps.v1", entitlementVersion: "rights.v1", requestedAt: calendarNow)
        let rights = calendarRights(provider: provider.id, feed: "fixture", capabilities: [.marketCalendar], license: "fixture-license")
        await #expect(throws: ContractError.mismatchedSource) {
            try await MarketCalendarClient(provider: provider, entitlement: rights).sessions(request)
        }
    }

    @Test func freeKeyEarningsPreserveEstimatedAndUnknownStatesWithoutInventingPIT() async throws {
        let csv = "symbol,name,reportDate,fiscalDateEnding,estimate,currency\nIBM,IBM,2026-10-20,2026-09-30,2.3,USD\nIBM,IBM,,2026-12-31,,USD\n"
        let provider = try AlphaVantageCorporateEventsProvider(apiKey: Data("demo".utf8),
            transport: FixtureHTTPTransport(payload: .init(statusCode: 200, mediaType: "text/csv", body: Data(csv.utf8))),
            evidenceRef: "alpha-source-review.v1", licenseRef: "alpha-license-review.v1", now: { calendarNow })
        let accepted = try await CorporateEventsClient(provider: provider, entitlement: eventRights([.earningsCalendar])).events(eventRequest(.earningsCalendar))
        #expect(accepted.exchange.result.items.map(\.certainty) == [.estimated, .unknown])
        #expect(accepted.exchange.result.items[1].eventDate == nil && accepted.exchange.result.items[1].timing == .unknown)
        #expect(accepted.exchange.result.items.allSatisfy { !$0.provenance.isAvailable(asOf: calendarNow) })

        let store = try BusinessDataStore(path: ":memory:")
        _ = try await store.ingestCorporateEvents(accepted, expectedRevision: store.revision())
        let events = try await store.corporateEvents(symbol: "IBM", kind: .earnings,
            range: .init(start: .init(year: 2026, month: 10, day: 1), end: .init(year: 2026, month: 12, day: 31)))
        #expect(events.count == 2 && events.last?.eventDate == nil)
        let historical = try await store.corporateEvents(symbol: "IBM", kind: .earnings,
            range: .init(start: .init(year: 2026, month: 10, day: 1), end: .init(year: 2026, month: 12, day: 31)), asOf: calendarNow)
        #expect(historical.isEmpty)
    }

    @Test func dividendsKeepZeroDistinctAndPairAmountWithCurrency() async throws {
        let json = #"{"data":[{"ex_dividend_date":"2026-10-15","declaration_date":"2026-09-01","amount":"0"},{"ex_dividend_date":"","declaration_date":"2026-09-02","amount":""}]}"#
        let provider = try AlphaVantageCorporateEventsProvider(apiKey: Data("demo".utf8),
            transport: FixtureHTTPTransport(payload: .init(statusCode: 200, mediaType: "application/json", body: Data(json.utf8))),
            evidenceRef: "alpha-source-review.v1", licenseRef: "alpha-license-review.v1", now: { calendarNow })
        let accepted = try await CorporateEventsClient(provider: provider, entitlement: eventRights([.dividends])).events(eventRequest(.dividends))
        let event = try #require(accepted.exchange.result.items.first)
        let zero = try Money("0")
        #expect(event.declaredAmount == zero && event.currency == "USD")
        #expect(event.timing == .notApplicable && event.certainty == .confirmed)
        let unknown = try #require(accepted.exchange.result.items.last)
        #expect(unknown.eventDate == nil && unknown.timing == .notApplicable && unknown.certainty == .unknown)
    }

    @Test func providerThrottleIsAnErrorNotAnEmptyCalendar() async throws {
        let body = Data(#"{"Note":"standard API call frequency reached"}"#.utf8)
        let provider = try AlphaVantageCorporateEventsProvider(apiKey: Data("demo".utf8),
            transport: FixtureHTTPTransport(payload: .init(statusCode: 200, mediaType: "application/json", body: body)),
            evidenceRef: "alpha-source-review.v1", licenseRef: "alpha-license-review.v1", now: { calendarNow })
        await #expect(throws: ProviderFailure.rateLimited) {
            try await CorporateEventsClient(provider: provider, entitlement: eventRights([.earningsCalendar])).events(eventRequest(.earningsCalendar))
        }
    }

    @Test func eventRevisionIsSelectedBeforeDateFilteringAndNeverFallsBackToLatest() async throws {
        let rights = calendarRights(provider: "known-events", feed: "fixture", capabilities: [.earningsCalendar], license: "fixture-license")
        let v1 = try await CorporateEventsClient(provider: KnownEventProvider(version: "v1",
            eventDate: try MarketDate(iso8601: "2026-10-20"), availableAt: calendarUTC("2026-09-10T12:00:00Z")),
            entitlement: rights).events(knownEventRequest())
        let v2 = try await CorporateEventsClient(provider: KnownEventProvider(version: "v2",
            eventDate: try MarketDate(iso8601: "2026-11-20"), availableAt: calendarUTC("2026-09-11T12:00:00Z")),
            entitlement: rights).events(knownEventRequest())
        let store = try BusinessDataStore(path: ":memory:")
        _ = try await store.ingestCorporateEvents(v1, expectedRevision: store.revision())
        _ = try await store.ingestCorporateEvents(v2, expectedRevision: store.revision())
        let october = MarketDateRange(start: .init(year: 2026, month: 10, day: 1), end: .init(year: 2026, month: 10, day: 31))
        let historical = try await store.corporateEvents(symbol: "IBM", kind: .earnings, range: october,
                                                        asOf: calendarUTC("2026-09-10T12:00:00Z"))
        #expect(historical.map { $0.eventDate?.iso8601 } == ["2026-10-20"])
        #expect(try await store.corporateEvents(symbol: "IBM", kind: .earnings, range: october).isEmpty)
        let november = MarketDateRange(start: .init(year: 2026, month: 11, day: 1), end: .init(year: 2026, month: 11, day: 30))
        #expect(try await store.corporateEvents(symbol: "IBM", kind: .earnings, range: november).map { $0.eventDate?.iso8601 } == ["2026-11-20"])
    }
}
