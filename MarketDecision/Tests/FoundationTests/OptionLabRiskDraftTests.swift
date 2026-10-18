import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
import Persistence
@testable import AppComposition

@Suite("Explicit offline risk and scenario drafts")
struct OptionLabRiskDraftTests {
    @Test func manualAndOldSyntheticDraftsDoNotAcquireOptionalEvidence() throws {
        let blank = OptionLabInputDraft(), draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        #expect(!blank.risk.enabled && !blank.scenario.enabled)
        #expect(blank.risk.shortLeg.openInterest.isEmpty && blank.risk.shortLeg.volume.isEmpty)
        #expect(!draft.risk.enabled && !draft.scenario.enabled)
        let input = try draft.build()
        #expect(input.risk == nil && input.scenario == nil)
    }
    @Test func explicitCombinedSyntheticActionIsAtomicAndCannotPopulateManualInput() throws {
        var manual = OptionLabInputDraft(), synthetic = try OptionLabInputDraft.synthetic(strategy: .putCreditSpread)
        #expect(throws: OptionLabDraftError.missingField) { try manual.useSyntheticRiskScenarioAssumptions() }
        #expect(!manual.risk.enabled && !manual.pricing.enabled && !manual.scenario.enabled)
        synthetic.shortLeg.bid = "invalid"
        let before = synthetic
        #expect(throws: (any Error).self) { try synthetic.useSyntheticRiskScenarioAssumptions() }
        #expect(synthetic == before)
        synthetic.shortLeg.bid = "2"
        try synthetic.useSyntheticRiskScenarioAssumptions()
        let input = try synthetic.build(), risk = try #require(input.risk), scenario = try #require(input.scenario)
        #expect(input.pricing?.source.origin == .synthetic && risk.containsSyntheticInput)
        #expect(risk.liquidity.count == 2 && risk.liquidity.allSatisfy { $0.neighborsComplete && $0.neighbors.count == 2 })
        #expect(scenario.source.origin == .synthetic)
        #expect(scenario.spotShocks == (try ["-0.1", "0", "0.1"].map(Money.init)))
        #expect(scenario.volatilityPointShocks == (try ["-10", "0", "10"].map(Money.init)))
    }
    @Test func blankLiquidityEvidenceStaysUnavailableRatherThanZeroOrSafe() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        draft.risk.enabled = true; draft.risk.sourceReference = "SYNTHETIC partial evidence"
        let input = try draft.build(), risk = try #require(input.risk)
        let evidence = try #require(risk.liquidity.first)
        #expect(evidence.openInterest == nil && evidence.volume == nil)
        #expect(evidence.neighbors.isEmpty && !evidence.neighborsComplete)
        #expect(risk.earnings == nil && risk.dividend == nil)
        let report = try #require(OptionLabEngine.calculate(input).risk)
        #expect(report.liquidity.score == nil && report.liquidity.grade == .dataInsufficient)
        #expect(report.earnings.state == .dataInsufficient)
    }
    @Test func riskSourceAndIntegralCountsAreRequiredWithoutRounding() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        draft.risk.enabled = true
        #expect(throws: OptionLabDraftError.missingField) { try draft.build() }
        draft.risk.sourceReference = "SYNTHETIC evidence"; draft.risk.shortLeg.openInterest = "0.5"
        #expect(throws: OptionLabDraftError.invalidNumber) { try draft.build() }
        draft.risk.shortLeg.openInterest = "0"
        #expect(try draft.build().risk?.liquidity.first?.openInterest == 0)
    }
    @Test func enablingScenarioAloneDoesNotSilentlyEnablePricingOrFillIV() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        try draft.useSyntheticScenarioAssumptions()
        let input = try draft.build(), report = try OptionLabEngine.calculate(input)
        #expect(input.pricing == nil && report.pricing == nil)
        let matrix = try #require(report.scenario)
        #expect(matrix.cells.count == 9)
        #expect(matrix.cells.allSatisfy { $0.state == .missingPricing && $0.mid == nil && $0.conservative == nil })
    }
    @Test func scenarioUnitsRemainDifferentAndMissingAxisDoesNotAcquireDefaults() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .coveredCall)
        try draft.useSyntheticScenarioAssumptions()
        draft.scenario.spotShocks = "-0.125, 0"; draft.scenario.volatilityPointShocks = "-12.5, 0"
        let input = try #require(draft.build().scenario)
        #expect(try #require(input.spotShocks.first) == Money("-0.125"))
        #expect(try #require(input.volatilityPointShocks.first) == Money("-12.5"))
        draft.scenario.volatilityPointShocks = ""
        #expect(throws: OptionLabDraftError.missingField) { try draft.build() }
        draft.scenario.volatilityPointShocks = "0,"
        #expect(throws: OptionLabDraftError.missingField) { try draft.build() }
    }
    @Test func disabledSectionsIgnoreRetainedInvalidTextWithoutUpgradingOldInput() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        try draft.useSyntheticRiskScenarioAssumptions()
        draft.risk.enabled = false; draft.scenario.enabled = false
        draft.risk.shortLeg.volume = "not an integer"; draft.scenario.spotShocks = "not a ratio"
        let input = try draft.build()
        #expect(input.risk == nil && input.scenario == nil && input.pricing != nil)
    }
    @Test func copiedEvidencePreservesNestedSourcesCalendarsAndSubmillisecondTimes() throws {
        let date = Date(timeIntervalSince1970: 1_791_903_600.0004)
        var draft = OptionLabInputDraft(input: try OptionLabDemo.input(strategy: .callCreditSpread, at: date))
        try draft.useSyntheticRiskScenarioAssumptions()
        let original = try draft.build(createdAt: date), copied = try OptionLabInputDraft(input: original).build(createdAt: date)
        #expect(copied.id != original.id && copied.risk == original.risk && copied.scenario == original.scenario)
        #expect(copied.risk?.earnings?.announcedAt == date)
        #expect(copied.risk?.liquidity.first?.neighbors.first?.quotedAt == date)
        #expect(copied.risk?.earnings?.calendar?.sessions.contains(where: { $0.state == .closed }) == true)
    }
    @Test func calendarAndNeighborEditingRequireExplicitRowsWithoutGuessingClosedDates() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        try draft.useSyntheticRiskScenarioAssumptions()
        draft.risk.earnings.calendar.enabled = false
        #expect(try draft.build().risk?.earnings?.calendar == nil)
        draft.risk.shortLeg.neighbors = "ID|90|1|1.1|1|1|0.01|missing-time"
        #expect(throws: OptionLabDraftError.missingField) { try draft.build() }
        draft.risk.shortLeg.neighbors = ""
        #expect(try draft.build().risk?.liquidity.first?.neighbors.isEmpty == true)
        draft.risk.earnings.calendar.enabled = true
        draft.risk.earnings.calendar.sessions = "2026-10-18|closed||"
        let calendar = try #require(draft.build().risk?.earnings?.calendar)
        let session = try #require(calendar.sessions.first)
        #expect(calendar.sessions.count == 1 && session.state == .closed)
        #expect(session.opensAt == nil && session.closesAt == nil)
        // The engine must reject the declared 48-day calendar now containing one
        // row; the draft never fabricates the missing dates to satisfy it.
        #expect(throws: OptionLabRiskError.invalidCalendar) { try OptionLabEngine.calculate(draft.build()) }
    }
    @Test func editingOneNeighborPreservesOtherRowsAndUnchangedFractionalTimes() throws {
        let instant = Date(timeIntervalSince1970: 1_791_903_600.0004), base = try OptionLabDemo.input(at: instant)
        let originalA = OptionLabSource(origin: .synthetic, reference: "SYNTHETIC distinct neighbor A", enteredAt: instant)
        let originalB = OptionLabSource(origin: .manual, reference: "manual distinct neighbor B", enteredAt: instant)
        func neighbor(_ id: String, _ strike: String, _ source: OptionLabSource) throws -> OptionLabLeg {
            .init(contractID: id, symbol: base.shortLeg.symbol, right: base.shortLeg.right, strike: try Money(strike), quantity: 1,
                expirationDate: base.shortLeg.expirationDate, bid: try Money("1"), ask: try Money("1.2"),
                bidSize: 10, askSize: 20, tick: try Money("0.01"), quotedAt: instant,
                receivedAt: instant.addingTimeInterval(0.0003), source: source)
        }
        let first = try neighbor("NEIGHBOR-A", "90", originalA), second = try neighbor("NEIGHBOR-B", "110", originalB)
        var draft = OptionLabLiquidityDraft(.init(contractID: base.shortLeg.contractID, neighbors: [first, second]))
        var rows = draft.neighbors.components(separatedBy: "\n")
        try #require(rows.count == 2)
        var fields = rows[0].components(separatedBy: "|"); try #require(fields.count == 9)
        fields[4] = "25"; rows[0] = fields.joined(separator: "|")
        draft.neighbors = rows.reversed().joined(separator: "\n")
        let current = OptionLabSource(origin: .manual, reference: "current edited assumption", enteredAt: instant.addingTimeInterval(1))
        let built = try draft.build(leg: base.shortLeg, source: current)
        let unchanged = try #require(built.neighbors.first(where: { $0.contractID == second.contractID }))
        let edited = try #require(built.neighbors.first(where: { $0.contractID == first.contractID }))
        #expect(unchanged == second)
        #expect(edited.bidSize == 25 && edited.quotedAt == first.quotedAt && edited.receivedAt == first.receivedAt)
        #expect(edited.source.reference == current.reference && edited.source.origin == .synthetic)
    }
    @Test func editingOneCalendarRowPreservesOtherSessionAndUnchangedFractionalClock() throws {
        let instant = Date(timeIntervalSince1970: 1_791_903_600.0004)
        let first = OptionLabRiskSession(date: .init(year: 2026, month: 10, day: 14), state: .regular,
            opensAt: instant, closesAt: instant.addingTimeInterval(6.5 * 3600))
        let second = OptionLabRiskSession(date: .init(year: 2026, month: 10, day: 15), state: .regular,
            opensAt: instant.addingTimeInterval(86400), closesAt: instant.addingTimeInterval(86400 + 6.5 * 3600))
        let source = OptionLabSource(origin: .synthetic, reference: "SYNTHETIC fractional session clock", enteredAt: instant)
        var draft = OptionLabCalendarDraft(.init(version: "fractional-calendar", source: source,
            from: first.date, through: second.date, sessions: [first, second]))
        var rows = draft.sessions.components(separatedBy: "\n"); try #require(rows.count == 2)
        var fields = rows[0].components(separatedBy: "|"); try #require(fields.count == 4)
        fields[1] = "earlyClose"; rows[0] = fields.joined(separator: "|")
        draft.sessions = rows.reversed().joined(separator: "\n")
        let result = try draft.build(origin: .synthetic, enteredAt: instant.addingTimeInterval(1))
        let built = try #require(result)
        let edited = try #require(built.sessions.first(where: { $0.date == first.date }))
        #expect(edited.state == .earlyClose && edited.opensAt == first.opensAt && edited.closesAt == first.closesAt)
        #expect(built.sessions.first(where: { $0.date == second.date }) == second)
        #expect(built.source == source)
    }
    @Test func editingOneStraddlePricePreservesOtherSourceAndBothUnchangedFractionalTimes() throws {
        let instant = Date(timeIntervalSince1970: 1_791_903_600.0004)
        let eventSource = OptionLabSource(origin: .manual, reference: "event-level assumption", enteredAt: instant)
        func quote(_ strike: String, _ source: String) throws -> OptionLabStraddleQuote {
            .init(strike: try Money(strike), settlementAt: instant.addingTimeInterval(86400),
                callBid: try Money("2"), callAsk: try Money("2.5"), putBid: try Money("1"), putAsk: try Money("1.5"),
                quotedAt: instant.addingTimeInterval(0.0003), source: .init(origin: .synthetic, reference: source, enteredAt: instant))
        }
        let first = try quote("100", "SYNTHETIC independent straddle A"), second = try quote("105", "SYNTHETIC independent straddle B")
        var draft = OptionLabEarningsDraft(.init(eventVersion: "fractional-event", source: eventSource, announcedAt: instant,
            eventDate: .init(year: 2026, month: 10, day: 15), timing: .beforeMarket, certainty: .confirmed, straddles: [first, second]))
        var rows = draft.straddles.components(separatedBy: "\n"); try #require(rows.count == 2)
        var fields = rows[0].components(separatedBy: "|"); try #require(fields.count == 7)
        fields[2] = "2.25"; rows[0] = fields.joined(separator: "|")
        draft.straddles = rows.reversed().joined(separator: "\n")
        let result = try draft.build(origin: .synthetic, enteredAt: instant.addingTimeInterval(1))
        let built = try #require(result)
        let edited = try #require(built.straddles.first(where: { $0.strike == first.strike }))
        #expect(edited.callBid == (try Money("2.25")))
        #expect(edited.settlementAt == first.settlementAt && edited.quotedAt == first.quotedAt)
        #expect(edited.source.reference == eventSource.reference && edited.source.origin == .synthetic)
        #expect(built.straddles.first(where: { $0.strike == second.strike }) == second)
    }
    @Test func ambiguousDisplayedStraddleIdentityFailsInsteadOfPickingAnOriginalByRowOrder() throws {
        let instant = Date(timeIntervalSince1970: 1_791_903_600), source = OptionLabSource(origin: .synthetic,
            reference: "SYNTHETIC ambiguous expiry display", enteredAt: Date(timeIntervalSince1970: 1_791_903_600))
        func quote(_ fraction: Double) throws -> OptionLabStraddleQuote {
            .init(strike: try Money("100"), settlementAt: Date(timeIntervalSince1970: 2_000_000_000 + fraction),
                callBid: try Money("2"), callAsk: try Money("2.5"), putBid: try Money("1"), putAsk: try Money("1.5"),
                quotedAt: instant, source: source)
        }
        let first = try quote(0.0001), second = try quote(0.0002)
        var draft = OptionLabEarningsDraft(.init(eventVersion: "ambiguous-event", source: source, announcedAt: instant,
            eventDate: .init(year: 2026, month: 10, day: 15), timing: .beforeMarket, certainty: .confirmed, straddles: [first, second]))
        var rows = draft.straddles.components(separatedBy: "\n"); try #require(rows.count == 2)
        let secondFields = rows[1].components(separatedBy: "|")
        var fields = rows[0].components(separatedBy: "|"); try #require(fields.count == 7 && secondFields.count == 7)
        try #require(fields[1] == secondFields[1])
        fields[2] = "2.25"; rows[0] = fields.joined(separator: "|"); draft.straddles = rows.joined(separator: "\n")
        #expect(throws: OptionLabDraftError.missingField) { try draft.build(origin: .synthetic, enteredAt: instant) }
    }
    @Test @MainActor func savedRiskAndScenarioReplayBeforePublishingAndEditingInvalidatesBoth() async throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        try draft.useSyntheticRiskScenarioAssumptions()
        let input = try draft.build(), storage = try OptionLabStore(path: ":memory:")
        let model = OptionLabWorkspaceModel(storage: storage)
        await model.load(); await model.calculate(input)
        let report = try #require(model.report)
        #expect(report.risk != nil && report.scenario?.cells.count == 9)
        #expect(await model.save())
        model.disappear(); await model.load()
        #expect(model.report == nil)
        await model.open(input.id)
        #expect(model.savedID == input.id && model.report == report)
        var copied = OptionLabInputDraft(input: input)
        copied.risk.shortLeg.openInterest = ""
        #expect(try copied.build().risk?.liquidity.first?.openInterest == nil)
        model.draftChanged()
        #expect(model.report == nil && !model.canSave && model.savedID == nil)
    }
}
