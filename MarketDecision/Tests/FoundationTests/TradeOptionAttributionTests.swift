import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import PortfolioEngine

@Suite("Trade-time option observation attribution")
struct TradeOptionAttributionTests {
    func input(_ source: TradeOptionAttributionInput, observations: [TradeOptionObservation]? = nil,
               performance: PerformanceInput? = nil, mode: TradeOptionAttributionMode? = nil) -> TradeOptionAttributionInput {
        .init(id: source.id, createdAt: source.createdAt, mode: mode ?? source.mode,
              performance: performance ?? source.performance, observations: observations ?? source.observations)
    }
    func observation(_ o: TradeOptionObservation, id: String? = nil, event: String? = nil, lot: String? = nil,
                     identity: String? = nil, contract: String? = nil, feed: String? = nil,
                     knownAt: Date? = nil, source: PerformanceEvidence? = nil, report: OptionLabReport? = nil,
                     rank: TradeOptionIVRankObservation?? = nil) -> TradeOptionObservation {
        .init(id: id ?? o.id, accountID: o.accountID, openingEventID: event ?? o.openingEventID, lotID: lot ?? o.lotID,
            instrumentIdentity: identity ?? o.instrumentIdentity, contractID: contract ?? o.contractID,
            feedID: feed ?? o.feedID, session: o.session, observedAt: o.observedAt, knownAt: knownAt ?? o.knownAt,
            source: source ?? o.source, report: report ?? o.report, ivRank: rank ?? o.ivRank)
    }
    func performance(_ p: PerformanceInput, events: [LedgerEvent]) -> PerformanceInput {
        .init(request: p.request, ledgerRevision: p.ledgerRevision, accounts: p.accounts, events: events)
    }
    func withoutPricing(_ p: OptionLabInput) -> OptionLabInput {
        .init(id: p.id, createdAt: p.createdAt, asOf: p.asOf, strategy: p.strategy, shortLeg: p.shortLeg, longLeg: p.longLeg,
            underlying: p.underlying, capital: p.capital, policy: p.policy, expiry: p.expiry, scenarioPrices: p.scenarioPrices)
    }
    @Test func closedSyntheticRoundsKeepPnLAndUnknownHistorySeparate() throws {
        let report = try TradeOptionAttributionEngine.calculate(TradeOptionAttributionDemo.input())
        #expect(report.rows.count == 4 && report.researchOnly && report.input.containsSynthetic)
        #expect(report.rows.allSatisfy { $0.round.economicState == .closed })
        #expect(report.rows.first { $0.id == "call-long-lot" }?.round.netPnL == (try Money("98")))
        #expect(report.rows.first { $0.id == "call-short-lot" }?.round.netPnL == (try Money("-52")))
        #expect(report.rows.first { $0.id == "put-short-lot" }?.round.netPnL == (try Money("0")))
        let unknown = try #require(report.rows.first { $0.id == "unknown-lot" })
        #expect(unknown.delta == nil && unknown.ivRank == nil && unknown.deltaGap == .missingObservation)
        for axis in [TradeOptionAttributionAxis.absoluteDelta, .ivRank] {
            let groups = report.groupedStatistics.filter { $0.axis == axis }
            #expect(groups.flatMap(\.roundIDs).count == 4)
            #expect(try groups.reduce(Money("0")) { try $0.adding($1.completedNetPnL ?? Money("0")) } == Money("96"))
            #expect(groups.reduce(0) { $0 + $1.statistics.eligibleN } == 4)
            #expect(groups.reduce(0) { $0 + $1.statistics.zeros } == 1)
            #expect(groups.allSatisfy { $0.statistics.winRate.value == nil && $0.statistics.expectancy.value == nil })
        }
    }
    @Test func signedTradeAndQuantityDoNotChangeCanonicalDelta() throws {
        let report = try TradeOptionAttributionEngine.calculate(TradeOptionAttributionDemo.input())
        let long = try #require(report.rows.first { $0.id == "call-long-lot" }), short = try #require(report.rows.first { $0.id == "call-short-lot" })
        #expect(long.delta == short.delta && long.impliedVolatility == short.impliedVolatility)
        #expect(long.ivRankBasis == .recordedUnverified)
        #expect(report.groupedStatistics.filter { $0.axis == .ivRank && $0.ivRankBasis == .recordedUnverified }.flatMap(\.roundIDs).count == 2)
    }
    @Test func approvedBucketBoundariesIncludeTailsAndUnknown() {
        let deltas: [(Double, String)] = [(0,"0"),(-0.249999,"0"),(-0.25,"1"),(0.499999,"1"),(0.5,"2"),(-0.75,"3"),(1,"3")]
        for (value, expected) in deltas { #expect(TradeOptionAttributionEngine.bucket(value, axis: .absoluteDelta).0 == expected) }
        let ranks: [(Double, String)] = [(-0.1,"0"),(0,"1"),(24.99,"1"),(25,"2"),(50,"3"),(75,"4"),(100,"4"),(100.01,"5")]
        for (value, expected) in ranks { #expect(TradeOptionAttributionEngine.bucket(value, axis: .ivRank).0 == expected) }
        #expect(TradeOptionAttributionEngine.bucket(nil, axis: .ivRank).0 == "unknown")
        #expect(TradeOptionAttributionEngine.bucket(nil, axis: .absoluteDelta).0 == "unknown")
    }
    @Test func duplicateObservationIDEventAndLotAreRejected() throws {
        let i = try TradeOptionAttributionDemo.input(), first = try #require(i.observations.first)
        for extra in [first, observation(first, id: "different"), observation(first, id: "other", event: "other-event")] {
            #expect(throws: TradeOptionAttributionError.duplicateObservation) { try TradeOptionAttributionEngine.calculate(input(i, observations: i.observations + [extra])) }
        }
    }
    @Test func observationCannotBindCloseWrongLotOrDifferentContract() throws {
        let i = try TradeOptionAttributionDemo.input(), first = try #require(i.observations.first)
        for changed in [observation(first, event: first.openingEventID + "-close"), observation(first, lot: "wrong"), observation(first, identity: "wrong")] {
            #expect(throws: TradeOptionAttributionError.unknownOpening) { try TradeOptionAttributionEngine.calculate(input(i, observations: [changed])) }
        }
        #expect(throws: TradeOptionAttributionError.mismatchedContract) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(first, contract: "WRONG")])) }
    }
    @Test func futureKnownTimeAndLaterSourceCannotBecomeTradeTimeEvidence() throws {
        let i = try TradeOptionAttributionDemo.input(), first = try #require(i.observations.first)
        let trade = try #require(i.performance.events.first { $0.id == first.openingEventID })
        #expect(throws: TradeOptionAttributionError.invalidTiming) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(first, knownAt: trade.effectiveAt.addingTimeInterval(0.0001))])) }
        let late = PerformanceEvidence(id: "late", source: "fixture", kind: .synthetic, availableAt: trade.effectiveAt.addingTimeInterval(1), reference: "late record", rawDocument: Data("late".utf8))
        #expect(throws: TradeOptionAttributionError.invalidTiming) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(first, source: late)])) }
    }
    @Test func openingExactlyAtDeclaredAvailabilityIsAccepted() throws {
        let i = try TradeOptionAttributionDemo.input(), first = try #require(i.observations.first)
        let trade = try #require(i.performance.events.first { $0.id == first.openingEventID })
        let report = try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(first, knownAt: trade.effectiveAt)]))
        #expect(report.rows.first { $0.observationID == first.id }?.delta != nil)
    }
    @Test func sixtySecondLimitUsesOpeningTimeRatherThanReportAsOf() throws {
        let i = try TradeOptionAttributionDemo.input(), first = try #require(i.observations.first)
        let changed = i.performance.events.map { e in
            e.id == first.openingEventID ? LedgerEvent(id: e.id, accountID: e.accountID, effectiveAt: first.observedAt.addingTimeInterval(60.0001),
                providerSequence: e.providerSequence, source: e.source, payload: e.payload) : e
        }.sorted { ($0.effectiveAt, $0.id) < ($1.effectiveAt, $1.id) }
        #expect(throws: TradeOptionAttributionError.invalidTiming) { try TradeOptionAttributionEngine.calculate(input(i, observations: [first], performance: performance(i.performance, events: changed))) }
    }
    @Test func missingLocalPricingDoesNotUseManualVolatilityForDelta() throws {
        let i = try TradeOptionAttributionDemo.input(), first = try #require(i.observations.first)
        let noPricing = try OptionLabEngine.calculate(withoutPricing(first.report.input))
        let r = try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(first, report: noPricing)]))
        let row = try #require(r.rows.first { $0.id == first.lotID })
        #expect(row.delta == nil && row.impliedVolatility == nil && row.deltaGap == .missingCanonicalIV)
        #expect(row.ivRank == 62.5 && row.ivRankBasis == .recordedUnverified)
    }
    @Test func syntheticEvidenceCannotEnterOrdinaryLedgerMode() throws {
        let i = try TradeOptionAttributionDemo.input()
        #expect(throws: TradeOptionAttributionError.syntheticEvidence) { try TradeOptionAttributionEngine.calculate(input(i, mode: .ledger)) }
    }
    @Test func recordedRankNeedsMatchingFeedSessionAndFiniteValue() throws {
        let i = try TradeOptionAttributionDemo.input(), o = try #require(i.observations.first), original = try #require(o.ivRank)
        for (value, feed, session) in [(Double.infinity, original.feedID, original.session), (10.0, "WRONG", original.session), (10.0, original.feedID, MarketDate(year: 2020, month: 1, day: 1))] {
            let rank = TradeOptionIVRankObservation(value: value, symbol: original.symbol, feedID: feed, session: session,
                observedAt: original.observedAt, knownAt: original.knownAt, methodReference: original.methodReference, source: original.source)
            #expect(throws: TradeOptionAttributionError.mismatchedContract) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(o, rank: .some(rank))])) }
        }
    }
    @Test func completeFrozenInputRoundTripsAndRejectsChangedResults() throws {
        let original = try TradeOptionAttributionEngine.calculate(TradeOptionAttributionDemo.input())
        let data = try JSONEncoder().encode(original)
        let saved = try JSONDecoder().decode(TradeOptionAttributionReport.self, from: data)
        #expect(try TradeOptionAttributionEngine.replay(saved) == original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(json["rows"] as? [[String: Any]])
        let index = try #require(rows.firstIndex { $0["delta"] != nil })
        rows[index]["delta"] = 0.001; json["rows"] = rows
        let tampered = try JSONDecoder().decode(TradeOptionAttributionReport.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: TradeOptionAttributionError.incompatibleReport) { try TradeOptionAttributionEngine.replay(tampered) }
    }
    @Test func sourceDocumentIsRequiredAndCannotClaimReportKnownBeforeCreation() throws {
        let i = try TradeOptionAttributionDemo.input(), o = try #require(i.observations.first)
        let empty = PerformanceEvidence(id: "empty", source: "source", kind: .synthetic, availableAt: o.source.availableAt, reference: "source", rawDocument: Data())
        #expect(throws: TradeOptionAttributionError.invalidEvidence) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(o, source: empty)])) }
        #expect(throws: TradeOptionAttributionError.invalidTiming) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(o, knownAt: o.observedAt)])) }
    }
    @Test func stillOpenRoundsDoNotBecomeCompletedGroupPnL() throws {
        let i = try TradeOptionAttributionDemo.input()
        let events = i.performance.events.filter { !$0.id.hasSuffix("-close") }
        let report = try TradeOptionAttributionEngine.calculate(input(i, performance: performance(i.performance, events: events)))
        #expect(report.rows.allSatisfy { $0.round.economicState == .open })
        #expect(report.groupedStatistics.allSatisfy { $0.completedNetPnL == nil && $0.statistics.eligibleN == 0 })
    }
    @Test func fullHistoricalRankIsReplayedAndKeptSeparateFromRecordedValue() throws {
        let i = try TradeOptionAttributionDemo.input(), o = try #require(i.observations.first { $0.report.input.underlying.symbol == "DEMO" })
        let history = try OptionVolatilityHistoryEngine.calculate(OptionVolatilityHistoryDemo.input())
        let rank = TradeOptionIVRankObservation(value: try #require(history.ivRank), symbol: "DEMO", feedID: history.input.current.input.feedID,
            session: o.session, observedAt: history.input.current.input.asOf, knownAt: o.knownAt,
            methodReference: history.model.formulaVersion, source: o.source, history: history)
        let observations = i.observations.map { $0.id == o.id ? observation(o, feed: rank.feedID, rank: .some(rank)) : $0 }
        let report = try TradeOptionAttributionEngine.calculate(input(i, observations: observations))
        #expect(report.rows.first { $0.id == o.lotID }?.ivRankBasis == .replayedHistory)
        #expect(report.groupedStatistics.contains { $0.axis == .ivRank && $0.ivRankBasis == .replayedHistory })
        #expect(report.groupedStatistics.contains { $0.axis == .ivRank && $0.ivRankBasis == .recordedUnverified })
        let wrong = TradeOptionIVRankObservation(value: rank.value + 1, symbol: rank.symbol, feedID: rank.feedID, session: rank.session,
            observedAt: rank.observedAt, knownAt: rank.knownAt, methodReference: rank.methodReference, source: rank.source, history: history)
        #expect(throws: TradeOptionAttributionError.invalidEvidence) { try TradeOptionAttributionEngine.calculate(input(i, observations: [observation(o, feed: rank.feedID, rank: .some(wrong))])) }
    }
    @Test func sharedIdentityCannotReferToConflictingSourceBytesOrReports() throws {
        let i = try TradeOptionAttributionDemo.input(), first = i.observations[0], second = i.observations[1]
        let differentSource = PerformanceEvidence(id: first.source.id, source: second.source.source, kind: .synthetic,
            availableAt: second.source.availableAt, reference: second.source.reference, rawDocument: Data("other source bytes".utf8))
        #expect(throws: TradeOptionAttributionError.invalidEvidence) {
            try TradeOptionAttributionEngine.calculate(input(i, observations: [first, observation(second, source: differentSource, rank: .some(nil))]))
        }
        let p = second.report.input
        let changed = OptionLabInput(id: p.id, createdAt: p.createdAt.addingTimeInterval(-0.5), asOf: p.asOf,
            strategy: p.strategy, shortLeg: p.shortLeg, longLeg: p.longLeg, underlying: p.underlying, capital: p.capital,
            policy: p.policy, expiry: p.expiry, scenarioPrices: p.scenarioPrices, pricing: p.pricing)
        let report = try OptionLabEngine.calculate(changed)
        #expect(throws: TradeOptionAttributionError.duplicateObservation) {
            try TradeOptionAttributionEngine.calculate(input(i, observations: [first, observation(second, report: report)]))
        }
    }
    @Test func nonOptionOpeningRoundIsExplicitlyExcludedWithoutChangingOptionPnL() throws {
        let i = try TradeOptionAttributionDemo.input(), instrument = LedgerInstrument.equity(.init(id: "SYNTHETIC-STOCK", symbol: "STK"))
        func event(_ id: String, time: Date, side: LedgerSide, effect: LedgerTradeEffect) throws -> LedgerEvent {
            .init(id: id, accountID: i.performance.request.accountID, effectiveAt: time,
                source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: id, evidence: "Synthetic stock round"),
                payload: .trade(.init(instrument: instrument, side: side, effect: effect, quantity: try Money("1"),
                    unitPrice: try Money(effect == .open ? "10" : "11"), fee: try Money("0"), openingLotID: effect == .open ? "stock-lot" : nil)))
        }
        let at = i.observations[0].observedAt
        let events = (i.performance.events + [try event("stock-open", time: at.addingTimeInterval(5), side: .buy, effect: .open),
            try event("stock-close", time: at.addingTimeInterval(3599), side: .sell, effect: .close)]).sorted { ($0.effectiveAt, $0.id) < ($1.effectiveAt, $1.id) }
        let report = try TradeOptionAttributionEngine.calculate(input(i, performance: performance(i.performance, events: events)))
        #expect(report.excludedNonOptionRoundIDs == ["stock-lot"] && report.rows.count == 4)
        let optionPnL = try report.rows.reduce(Money("0")) { try $0.adding($1.round.netPnL ?? Money("0")) }
        #expect(optionPnL == (try Money("96")))
    }
    @Test func reversedOpeningCannotKeepAnObservationBinding() throws {
        let i = try TradeOptionAttributionDemo.input(), o = i.observations[0]
        var events = i.performance.events.filter { $0.id != o.openingEventID + "-close" }
        let reversal = LedgerEvent(id: "void-opening", accountID: o.accountID, effectiveAt: i.performance.request.calculatedAt,
            source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: "void-opening", evidence: "Synthetic correction"),
            payload: .reversal(.init(originalEventID: o.openingEventID, reason: "void opening")))
        events.append(reversal)
        #expect(throws: TradeOptionAttributionError.unknownOpening) {
            try TradeOptionAttributionEngine.calculate(input(i, observations: [o], performance: performance(i.performance, events: events)))
        }
    }
}
