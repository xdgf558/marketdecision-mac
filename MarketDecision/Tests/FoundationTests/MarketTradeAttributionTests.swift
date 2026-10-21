import Foundation
import Testing
import CoreDomain
import MarketAnalytics
@testable import PortfolioEngine

@Suite("Frozen opening-time market attribution")
struct MarketTradeAttributionTests {
    func fixture() throws -> MarketTradeAttributionInput {
        let at = try MillisecondInstant(iso8601: "2026-10-19T20:00:00.000Z").date
        let snapshot = try MarketStateEngine.calculate(.init(createdAt: at, asOf: at, sessionDate: "2026-10-19",
            sessions: [.init(date: "2026-10-19", closeAt: at)], calendarEvidence: "SYNTHETIC-SESSION", series: []))
        return try MarketTradeAttributionDemo.input(snapshot: snapshot)
    }
    func input(_ p: MarketTradeAttributionInput, observations: [MarketTradeObservation]? = nil,
               mode: MarketTradeAttributionMode? = nil, performance: PerformanceInput? = nil) -> MarketTradeAttributionInput {
        .init(id: p.id, createdAt: p.createdAt, mode: mode ?? p.mode,
              performance: performance ?? p.performance, observations: observations ?? p.observations)
    }
    func observation(_ o: MarketTradeObservation, id: String? = nil, event: String? = nil, lot: String? = nil,
                     account: String? = nil, knownAt: Date? = nil, source: PerformanceEvidence? = nil,
                     snapshot: MarketStateReport? = nil, nextScheduledClose: MarketNextCloseEvidence? = nil) -> MarketTradeObservation {
        .init(id: id ?? o.id, accountID: account ?? o.accountID, openingEventID: event ?? o.openingEventID,
            lotID: lot ?? o.lotID, knownAt: knownAt ?? o.knownAt, source: source ?? o.source, snapshot: snapshot ?? o.snapshot,
            nextScheduledClose: nextScheduledClose ?? o.nextScheduledClose)
    }
    func moved(_ p: MarketTradeAttributionInput, openingAt: Date) throws -> MarketTradeAttributionInput {
        let first = try #require(p.performance.events.first { $0.id == "open-0" })
        let offset = openingAt.timeIntervalSince(first.effectiveAt), calculated = p.performance.request.calculatedAt.addingTimeInterval(offset)
        let events = p.performance.events.map { e in
            LedgerEvent(id: e.id, accountID: e.accountID, effectiveAt: e.effectiveAt.addingTimeInterval(offset), providerSequence: e.providerSequence,
                source: e.source, payload: e.payload, rollGroupID: e.rollGroupID, multiLegGroupID: e.multiLegGroupID, notes: e.notes)
        }
        let request = PerformanceRequest(accountID: p.performance.request.accountID, calculatedAt: calculated,
            calendar: .init(tradingDays: [PerformanceDates.marketDay(openingAt)], evidence: p.performance.request.calendar.evidence), days: [])
        return .init(id: p.id, createdAt: calculated, mode: p.mode,
            performance: .init(request: request, ledgerRevision: p.performance.ledgerRevision, accounts: p.performance.accounts, events: events), observations: p.observations)
    }
    @Test func missingAndUnreliableSnapshotsRemainSeparateWithExactFeePnL() throws {
        let report = try MarketTradeAttributionEngine.calculate(fixture())
        #expect(report.rows.count == 2 && report.groupedStatistics.count == 2)
        #expect(report.rows.first { $0.id == "lot-0" }?.gap == .unavailableMarketState)
        #expect(report.rows.first { $0.id == "lot-1" }?.gap == .missingSnapshot)
        #expect(report.rows.allSatisfy { $0.label == nil })
        #expect(report.rows.first { $0.id == "lot-0" }?.round.netPnL == (try Money("18")))
        #expect(report.rows.first { $0.id == "lot-1" }?.round.netPnL == (try Money("-22")))
        #expect(try report.groupedStatistics.reduce(Money("0")) { try $0.adding($1.completedNetPnL ?? Money("0")) } == Money("-4"))
        #expect(report.groupedStatistics.allSatisfy { $0.statistics.winRate.value == nil && $0.statistics.expectancy.value == nil })
        #expect(report.researchOnly && report.containsSynthetic)
    }
    @Test func absentOpeningSnapshotsNeverTakeAnotherLotsObservation() throws {
        let p = try fixture()
        let report = try MarketTradeAttributionEngine.calculate(input(p, observations: []))
        #expect(report.rows.allSatisfy { $0.gap == .missingSnapshot && $0.snapshotID == nil })
        #expect(report.groupedStatistics.count == 1)
    }
    @Test func duplicateObservationEventAndLotAreRejected() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        for extra in [o, observation(o, id: "unique"), observation(o, id: "unique", event: "other")] {
            #expect(throws: MarketTradeAttributionError.duplicateObservation) {
                try MarketTradeAttributionEngine.calculate(input(p, observations: [o, extra]))
            }
        }
    }
    @Test func closeWrongAccountAndWrongLotCannotSupplyOpeningEvidence() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        for changed in [observation(o, event: "close-0"), observation(o, lot: "lot-1"), observation(o, account: "other")] {
            #expect(throws: MarketTradeAttributionError.unknownOpening) {
                try MarketTradeAttributionEngine.calculate(input(p, observations: [changed]))
            }
        }
    }
    @Test func subMillisecondLateEvidenceIsRejected() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        let opening = try #require(p.performance.events.first { $0.id == o.openingEventID })
        #expect(throws: MarketTradeAttributionError.invalidTiming) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, knownAt: opening.effectiveAt.addingTimeInterval(0.0004))]))
        }
    }
    @Test func exactlyAtOpeningAvailabilityRemainsValid() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        let opening = try #require(p.performance.events.first { $0.id == o.openingEventID })
        let result = try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, knownAt: opening.effectiveAt)]))
        #expect(result.rows.first { $0.id == o.lotID }?.snapshotID == o.snapshot.input.id)
    }
    @Test func laterSourceCannotBeSmuggledThroughEarlierKnownAt() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        let source = PerformanceEvidence(id: o.source.id, source: o.source.source, kind: .synthetic,
            availableAt: o.knownAt.addingTimeInterval(60), reference: o.source.reference, rawDocument: o.source.rawDocument)
        #expect(throws: MarketTradeAttributionError.invalidTiming) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, source: source)]))
        }
    }
    @Test func retrospectivelyCreatedSnapshotCannotBecomeOpeningTimeEvidence() throws {
        let p = try fixture(), o = try #require(p.observations.first), s = o.snapshot.input
        let later = try MarketStateEngine.calculate(.init(id: s.id, createdAt: s.createdAt.addingTimeInterval(60), asOf: s.asOf,
            sessionDate: s.sessionDate, sessions: s.sessions, calendarEvidence: s.calendarEvidence, series: s.series))
        #expect(throws: MarketTradeAttributionError.invalidTiming) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, snapshot: later)]))
        }
    }
    @Test func syntheticEvidenceCannotEnterOrdinaryLedgerAttribution() throws {
        let p = try fixture()
        #expect(throws: MarketTradeAttributionError.syntheticEvidence) {
            try MarketTradeAttributionEngine.calculate(input(p, mode: .ledger))
        }
    }
    @Test func completeJSONRoundTripReplaysWithoutOriginalMemoryInput() throws {
        let encoded = try JSONEncoder().encode(MarketTradeAttributionEngine.calculate(fixture()))
        let restored = try JSONDecoder().decode(MarketTradeAttributionReport.self, from: encoded)
        #expect(try MarketTradeAttributionEngine.replay(restored) == restored)
    }
    @Test func forgedCachedLabelCannotPassReplay() throws {
        let report = try MarketTradeAttributionEngine.calculate(fixture())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var rows = try #require(json["rows"] as? [[String: Any]])
        rows[0]["label"] = "强势扩张"; json["rows"] = rows
        let forged = try JSONDecoder().decode(MarketTradeAttributionReport.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: MarketTradeAttributionError.incompatibleReport) { try MarketTradeAttributionEngine.replay(forged) }
    }
    @Test func forgedEmbeddedSnapshotCannotBeUsedEvenWhenOuterEnvelopeIsNew() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(o.snapshot)) as? [String: Any])
        var current = try #require(json["current"] as? [String: Any])
        current["confirmedLabel"] = "expansion"; json["current"] = current
        let forged = try JSONDecoder().decode(MarketStateReport.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: Error.self) { try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, snapshot: forged)])) }
    }
    @Test func sameSnapshotIdentityCannotDescribeTwoDifferentInputs() throws {
        let p = try fixture(), o = try #require(p.observations.first), s = o.snapshot.input
        let changed = try MarketStateEngine.calculate(.init(id: s.id, createdAt: s.createdAt, asOf: s.asOf,
            sessionDate: s.sessionDate, sessions: s.sessions, calendarEvidence: "SYNTHETIC-OTHER-DECLARATION", series: s.series))
        let other = observation(o, id: "second", event: "open-1", lot: "lot-1", snapshot: changed)
        #expect(throws: MarketTradeAttributionError.duplicateObservation) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [o, other]))
        }
    }
    @Test func observationsWithSameSourceIDCannotContradictEachOther() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        let changed = PerformanceEvidence(id: o.source.id, source: o.source.source, kind: .synthetic,
            availableAt: o.source.availableAt, reference: o.source.reference, rawDocument: Data("SYNTHETIC-CONFLICT".utf8))
        let other = observation(o, id: "second", event: "open-1", lot: "lot-1", source: changed)
        #expect(throws: MarketTradeAttributionError.invalidEvidence) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [o, other]))
        }
    }
    @Test func missingNextSessionEvidenceIsAnExplicitGapAndNeverALabel() throws {
        let p = try fixture(), o = try #require(p.observations.first)
        let noCalendar = MarketTradeObservation(id: o.id, accountID: o.accountID, openingEventID: o.openingEventID,
            lotID: o.lotID, knownAt: o.knownAt, source: o.source, snapshot: o.snapshot)
        let report = try MarketTradeAttributionEngine.calculate(input(p, observations: [noCalendar]))
        let row = try #require(report.rows.first { $0.id == o.lotID })
        #expect(row.gap == .missingSessionValidity && row.label == nil && row.snapshotID == o.snapshot.input.id)
        #expect(report.groupedStatistics.contains { $0.label == "缺少下一收盘会话证据" })
    }
    @Test func monthsOldSnapshotIsKeptAsExpiredEvidenceWithoutLabelBackfill() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        let delayed = try moved(p, openingAt: next.closeAt.addingTimeInterval(120 * 86_400))
        let report = try MarketTradeAttributionEngine.calculate(delayed), row = try #require(report.rows.first { $0.id == o.lotID })
        #expect(row.gap == .staleSnapshot && row.label == nil)
        let expectedPnL = try Money("18")
        #expect(row.snapshotID == o.snapshot.input.id && row.round.netPnL == expectedPnL)
    }
    @Test func nextScheduledCloseHasStrictExactBoundaryWithoutMillisecondRounding() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        for offset in [-0.0004, 0, 0.0004] {
            let report = try MarketTradeAttributionEngine.calculate(moved(p, openingAt: next.closeAt.addingTimeInterval(offset)))
            let row = try #require(report.rows.first { $0.id == o.lotID })
            #expect(row.gap == (offset < 0 ? .unavailableMarketState : .staleSnapshot))
            #expect(row.label == nil) // This small fixture intentionally has no usable market scores.
        }
    }
    @Test func validNextSessionIntradayUsesFrozenPreviousCloseBound() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        let report = try MarketTradeAttributionEngine.calculate(moved(p, openingAt: next.closeAt.addingTimeInterval(-3600)))
        let row = try #require(report.rows.first { $0.id == o.lotID })
        #expect(row.gap == .unavailableMarketState) // Calendar is valid; missing scores remain missing.
        #expect(row.snapshotSession == o.snapshot.current.sessionDate)
    }
    @Test func calendarPublishedAfterKnownTimeCannotExtendSnapshotValidity() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        let source = PerformanceEvidence(id: next.calendar.id, source: next.calendar.source, kind: next.calendar.kind,
            availableAt: o.knownAt.addingTimeInterval(0.0004), reference: next.calendar.reference, rawDocument: next.calendar.rawDocument)
        let later = MarketNextCloseEvidence(sessionDate: next.sessionDate, closeAt: next.closeAt, calendar: source)
        #expect(throws: MarketTradeAttributionError.invalidTiming) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, nextScheduledClose: later)]))
        }
    }
    @Test func nextCloseMustBeLaterAndItsDateMustMatchNewYorkSession() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        let midnightUTC = try MillisecondInstant(iso8601: "2026-10-20T00:30:00.000Z").date
        for bad in [MarketNextCloseEvidence(sessionDate: "2026-10-20", closeAt: midnightUTC, calendar: next.calendar),
                    .init(sessionDate: o.snapshot.current.sessionDate, closeAt: o.snapshot.current.asOf, calendar: next.calendar),
                    .init(sessionDate: "2026-02-30", closeAt: next.closeAt, calendar: next.calendar)] {
            #expect(throws: MarketTradeAttributionError.invalidTiming) {
                try MarketTradeAttributionEngine.calculate(input(p, observations: [observation(o, nextScheduledClose: bad)]))
            }
        }
    }
    @Test func sameSnapshotAndCalendarCannotDeclareDifferentNextCloses() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        let later = MarketNextCloseEvidence(sessionDate: "2026-10-21", closeAt: next.closeAt.addingTimeInterval(86_400), calendar: next.calendar)
        let other = observation(o, id: "second", event: "open-1", lot: "lot-1", nextScheduledClose: later)
        #expect(throws: MarketTradeAttributionError.invalidEvidence) {
            try MarketTradeAttributionEngine.calculate(input(p, observations: [o, other]))
        }
    }
    @Test func differentSnapshotsMayReuseOneCalendarDocument() throws {
        let p = try fixture(), o = try #require(p.observations.first), next = try #require(o.nextScheduledClose)
        let previousClose = try MillisecondInstant(iso8601: "2026-10-16T20:00:00.000Z").date
        let previous = try MarketStateEngine.calculate(.init(createdAt: o.snapshot.input.createdAt,
            asOf: previousClose, sessionDate: "2026-10-16",
            sessions: [.init(date: "2026-10-16", closeAt: previousClose)], calendarEvidence: "SYNTHETIC-SESSION", series: []))
        let oldNext = MarketNextCloseEvidence(sessionDate: "2026-10-19", closeAt: o.snapshot.current.asOf, calendar: next.calendar)
        let other = observation(o, id: "second", event: "open-1", lot: "lot-1", snapshot: previous, nextScheduledClose: oldNext)
        let report = try MarketTradeAttributionEngine.calculate(input(p, observations: [o, other]))
        #expect(report.rows.first { $0.id == "lot-0" }?.gap == .unavailableMarketState)
        #expect(report.rows.first { $0.id == "lot-1" }?.gap == .staleSnapshot)
        #expect(try MarketTradeAttributionEngine.replay(report) == report)
    }
    @Test func syntheticNextCloseAloneCannotBeUsedByOrdinaryLedgerMode() throws {
        func clean(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.mapValues(clean) }
            if let array = value as? [Any] { return array.map(clean) }
            if let text = value as? String {
                if text == "synthetic" { return "userConfirmed" }
                return text.replacingOccurrences(of: "SYNTHETIC-", with: "LOCAL-")
            }
            return value
        }
        let p = try fixture()
        var json = try #require(clean(JSONSerialization.jsonObject(with: JSONEncoder().encode(p))) as? [String: Any])
        json["mode"] = "ledger"
        var observations = try #require(json["observations"] as? [[String: Any]])
        var next = try #require(observations[0]["nextScheduledClose"] as? [String: Any])
        var evidence = try #require(next["calendar"] as? [String: Any]); evidence["kind"] = "synthetic"
        next["calendar"] = evidence; observations[0]["nextScheduledClose"] = next; json["observations"] = observations
        let mixed = try JSONDecoder().decode(MarketTradeAttributionInput.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: MarketTradeAttributionError.syntheticEvidence) { try MarketTradeAttributionEngine.calculate(mixed) }
    }
}
