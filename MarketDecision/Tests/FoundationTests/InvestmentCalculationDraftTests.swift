import Foundation
import Testing
import CoreDomain
import PortfolioEngine
@testable import AppComposition

@Suite("Investment calculation evidence preparation")
struct InvestmentCalculationDraftTests {
    private let account = LedgerAccount(id: "ordinary-account", name: "Local account")
    private func at(_ value: String) throws -> Date { try LedgerCSV.timestamp(value) }
    private func evidence(_ id: String, kind: PerformanceEvidenceKind = .userConfirmed) throws -> PerformanceEvidence {
        .init(id: id, source: "local statement", kind: kind,
              availableAt: try at("2026-01-02T12:00:00.0004Z"), reference: "local/" + id,
              rawDocument: Data([0, 255, 10, 13]) + Data(id.utf8))
    }
    private func proof(_ id: String) -> PortfolioEvidenceDraft {
        var value = PortfolioEvidenceDraft()
        value.id = id; value.source = "new local statement"; value.reference = "local/" + id
        value.availableAt = "2026-01-08T12:00:00Z"; value.text = "explicit new evidence " + id
        return value
    }
    private func base(calendar: [String] = ["2026-01-02", "2026-01-05"]) throws -> PerformanceRequest {
        let session = try PerformanceSession(id: "original-session", instrumentID: "equity:OLD",
            opensAt: at("2026-01-02T14:30:00.0001Z"), closesAt: at("2026-01-02T21:00:00.0004Z"), evidence: evidence("session"))
        let price = try PerformancePrice(id: "original-price", instrumentID: "equity:OLD", sessionID: session.id,
            quoteAt: at("2026-01-02T20:59:59.9999Z"), bid: Money("10.005"), ask: Money("10.025"), last: Money("10.01"),
            basis: .splitAdjusted, quality: [.stale, .indicative], timeliness: .delayed, evidence: evidence("price"))
        let first = try PerformanceDayInput(day: "2026-01-02", valuationAt: at("2026-01-02T21:00:00.0006Z"), sessions: [session], prices: [price])
        let second = try PerformanceDayInput(day: "2026-01-05", valuationAt: at("2026-01-05T21:00:00Z"), sessions: [], prices: [])
        return try PerformanceRequest(accountID: account.id, calculatedAt: at("2026-01-08T12:00:00Z"),
            calendar: .init(tradingDays: calendar, evidence: evidence("calendar")), days: [first, second],
            accruals: [.init(id: "accrual", kind: .interestReceivable, recognizedAt: at("2026-01-02T12:00:00.0003Z"),
                             amount: Money("0.42"), settlements: [], evidence: evidence("accrual"))],
            rateCurves: [.init(id: "rate", source: .explicitUserConstant, observationAt: at("2026-01-02T12:00:00Z"),
                              validFrom: at("2026-01-02T13:00:00Z"), validThrough: at("2026-01-09T21:00:00Z"),
                              points: [.init(termYears: 2, annualRate: Money("0.04"), unit: .annualDecimal)],
                              evidence: evidence("rate"), sourceInput: Data([0, 255, 1]), sourceVersion: "frozen-rate-context")],
            benchmark: .init(symbol: "SPY", points: [.init(day: "2026-01-02", totalReturnIndex: Money("1.0001"), evidence: evidence("benchmark"))],
                             isTotalReturn: true, sourceInput: Data([255, 254, 0]), sourceVersion: "frozen-benchmark-context"),
            externalFlowsComplete: true, flowCompletenessEvidence: evidence("flows"),
            roundAllocations: [.init(lotID: "lot", roundLotID: "round", fraction: Money("1"), evidence: evidence("round"))],
            incomeAllocations: [.init(ledgerEventID: "income", roundLotID: "round", amount: Money("0.42"), evidence: evidence("income"))],
            purposeEvidence: [.init(roundLotID: "round", outcome: .success, evidence: evidence("purpose"))])
    }
    private func trade(_ id: String, symbol: String, timestamp: String, effect: LedgerTradeEffect = .open,
                       group: String? = nil) throws -> LedgerEvent {
        try .init(id: id, accountID: account.id, effectiveAt: at(timestamp),
            source: .init(sourceSystem: "local", externalTransactionID: id, evidence: "local event " + id),
            payload: .trade(.init(instrument: .equity(.init(id: symbol, symbol: symbol)), side: effect == .open ? .buy : .sell,
                effect: effect, quantity: Money("1"), unitPrice: Money("10"), fee: Money("0"),
                openingLotID: effect == .open ? "lot-" + id : nil)), multiLegGroupID: group)
    }

    @Test func reusePreservesTypedPrecisionBytesPriceFlagsAndAllAdvancedContext() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        let rebuilt = try draft.build(calculatedAt: original.calculatedAt)
        #expect(rebuilt == original)
        #expect(rebuilt.days[0].prices[0].basis == .splitAdjusted)
        #expect(rebuilt.days[0].prices[0].quality == [.stale, .indicative])
        #expect(rebuilt.days[0].prices[0].timeliness == .delayed)
        #expect(rebuilt.days[0].valuationAt == original.days[0].valuationAt)
        #expect(rebuilt.rateCurves[0].sourceInput == Data([0, 255, 1]))
        #expect(rebuilt.benchmark?.sourceInput == Data([255, 254, 0]))
        #expect(rebuilt.days[0].prices[0].evidence.rawDocument == original.days[0].prices[0].evidence.rawDocument)
    }

    @Test func flowCompletenessAlwaysNeedsFreshConfirmationAndMissingProofIsRejected() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        let incomplete = try draft.build(calculatedAt: original.calculatedAt)
        #expect(!incomplete.externalFlowsComplete && incomplete.flowCompletenessEvidence == nil)
        #expect(draft.reusedRequest?.flowCompletenessEvidence == original.flowCompletenessEvidence)
        draft.externalFlowsComplete = true
        #expect(try draft.build(calculatedAt: original.calculatedAt).flowCompletenessEvidence == original.flowCompletenessEvidence)
        draft.usesNewFlowEvidence = true
        #expect(throws: (any Error).self) { try draft.build(calculatedAt: original.calculatedAt) }
        draft.flowEvidence = proof("reconfirmed-new-flow")
        #expect(try draft.build(calculatedAt: original.calculatedAt).flowCompletenessEvidence?.id == "reconfirmed-new-flow")
        let noProof = PerformanceRequest(accountID: account.id, calculatedAt: original.calculatedAt,
                                        calendar: original.calendar, days: original.days)
        var missing = try InvestmentCalculationDraft(accountID: account.id, reusing: noProof)
        missing.externalFlowsComplete = true
        missing.usesNewFlowEvidence = false
        #expect(throws: InvestmentDraftError.missingFlowEvidence) { try missing.build(calculatedAt: original.calculatedAt) }
    }

    @Test func accountAndSyntheticEvidenceAreRejectedIncludingNestedAdvancedEvidence() throws {
        let original = try base()
        #expect(throws: InvestmentDraftError.accountMismatch) { try InvestmentCalculationDraft(accountID: "other", reusing: original) }
        let synthetic = try PortfolioSyntheticExample.input().request
        #expect(throws: InvestmentDraftError.syntheticEvidence) { try InvestmentCalculationDraft(accountID: synthetic.accountID, reusing: synthetic) }
        let advanced = PerformanceRequest(accountID: account.id, calculatedAt: original.calculatedAt,
            calendar: original.calendar, days: original.days,
            purposeEvidence: [try .init(roundLotID: "round", outcome: .success, evidence: evidence("hidden", kind: .synthetic))])
        #expect(throws: InvestmentDraftError.syntheticEvidence) { try InvestmentCalculationDraft(accountID: account.id, reusing: advanced) }
    }

    @Test func calendarCropsDeclaredDatesAndNeverInfersWeekendsOrExtension() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        #expect(try draft.selectedCalendar().tradingDays == ["2026-01-02", "2026-01-05"])
        draft.startDay = "2026-01-03"
        #expect(try draft.selectedCalendar().tradingDays == ["2026-01-05"])
        #expect(try draft.build(calculatedAt: original.calculatedAt).days.map(\.day) == ["2026-01-05"])
        draft.endDay = "2026-01-06"
        #expect(throws: InvestmentDraftError.invalidCalendar) { try draft.selectedCalendar() }
        draft.replacesCalendar = true
        draft.replacementTradingDays = "2026-01-02\n2026-01-05\n2026-01-06"
        #expect(throws: (any Error).self) { try draft.selectedCalendar() }
        draft.replacementCalendarEvidence = proof("new-calendar")
        #expect(try draft.selectedCalendar().tradingDays == ["2026-01-05", "2026-01-06"])
        let built = try draft.build(calculatedAt: original.calculatedAt)
        #expect(built.days.map(\.day) == ["2026-01-05"]) // New date has no invented valuation.
        #expect(built.calendar.evidence.id == "new-calendar")
    }

    @Test func requiredHoldingsUseEachHistoricalInstantAndActiveCorrectionsNotCurrentLots() throws {
        let original = try base(calendar: ["2026-01-02", "2026-01-05", "2026-01-06"])
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        var third = PortfolioDayDraft(); third.day = "2026-01-06"; third.valuationAt = "2026-01-06T21:00:00Z"
        draft.supplementalDays = [third]
        let oldBuy = try trade("old-buy", symbol: "OLD", timestamp: "2026-01-02T15:00:00Z")
        let oldClose = try trade("old-close", symbol: "OLD", timestamp: "2026-01-05T15:00:00Z", effect: .close)
        let newBuy = try trade("new-buy", symbol: "NEW", timestamp: "2026-01-06T15:00:00Z")
        let reversed = try trade("reversed-buy", symbol: "VOID", timestamp: "2026-01-02T16:00:00Z")
        let correction = try LedgerEvent(id: "correction", accountID: account.id, effectiveAt: at("2026-01-07T12:00:00Z"),
            source: .init(sourceSystem: "local", externalTransactionID: "correction", evidence: "void accidental entry"),
            payload: .reversal(.init(originalEventID: reversed.id, reason: "incorrect")))
        let events = [oldBuy, oldClose, newBuy, reversed, correction]
        let rows = try draft.requirements(accounts: [account], events: events)
        #expect(rows.map(\.instrumentIDs) == [["equity:OLD"], [], ["equity:NEW"]])
        #expect(rows.map(\.missingInstrumentIDs) == [[], [], ["equity:NEW"]])
        try draft.fillMissingQuotes(accounts: [account], events: events)
        let inserted = try #require(draft.supplementalDays.first { $0.day == third.day }?.quotes.first)
        #expect(inserted.instrumentID == "equity:NEW")
        #expect(inserted.bid.isEmpty && inserted.ask.isEmpty && inserted.quoteAt.isEmpty && inserted.opensAt.isEmpty)
        try draft.fillMissingQuotes(accounts: [account], events: events)
        #expect(draft.supplementalDays.first { $0.day == third.day }?.quotes.count == 1)
    }

    @Test func fillingReturnsTheSameRequirementsWithoutTreatingPendingQuotesAsEvidence() throws {
        let original = try base(calendar: ["2026-01-02", "2026-01-05", "2026-01-06"])
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        let events = [try trade("buy", symbol: "NEW", timestamp: "2026-01-02T15:00:00Z")]
        let expected = try draft.requirements(accounts: [account], events: events)
        let returned = try draft.fillMissingQuotes(accounts: [account], events: events)
        #expect(returned == expected)
        #expect(returned == (try draft.requirements(accounts: [account], events: events)))
        #expect(returned.last?.reason != nil) // Missing valuation remains explicit.
        #expect(draft.supplementalDays.map(\.day) == original.calendar.tradingDays)
        #expect(draft.supplementalDays[0].quotes.map(\.instrumentID) == ["equity:NEW"])
        let filled = draft
        #expect(try draft.fillMissingQuotes(accounts: [account], events: events) == returned)
        #expect(draft == filled) // A second preparation never creates new pending identities.
        #expect(draft.reusedRequest == original && !draft.externalFlowsComplete)
    }

    @Test func dailyQuoteAdditionRejectsDuplicateInstrumentWithoutReplacingInputOrRelaxingSessionConflicts() throws {
        var day = PortfolioDayDraft(); day.day = "2026-01-05"
        #expect(!day.canAddSupplementalQuote(instrumentID: "  "))
        #expect(!day.appendSupplementalQuote(instrumentID: ""))
        #expect(day.appendSupplementalQuote(instrumentID: "equity:OLD"))
        day.quotes[0].opensAt = "2026-01-05T14:30:00Z"
        day.quotes[0].closesAt = "2026-01-05T21:00:00Z"
        day.quotes[0].quoteAt = "2026-01-05T20:59:00Z"
        day.quotes[0].bid = "12"; day.quotes[0].ask = "13"
        day.quotes[0].sessionEvidence = proof("pending-session")
        day.quotes[0].priceEvidence = proof("pending-price")
        let entered = day
        #expect(!day.canAddSupplementalQuote(instrumentID: "equity:OLD"))
        #expect(!day.appendSupplementalQuote(instrumentID: "equity:OLD"))
        #expect(day == entered)
        #expect(day.appendSupplementalQuote(instrumentID: "equity:NEW"))
        #expect(day.quotes.first == entered.quotes.first && day.quotes.count == 2)

        // The editing helper is not permission to bypass the lower-level guard.
        let original = try base()
        var conflicting = entered
        var second = entered.quotes[0]; second.id = UUID().uuidString
        second.quoteAt = "2026-01-05T20:59:30Z"
        conflicting.quotes.append(second)
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        draft.supplementalDays = [conflicting]
        #expect(throws: InvestmentDraftError.conflictingSession) { try draft.build(calculatedAt: original.calculatedAt) }
    }

    @Test func cancelledPreparationThrowsInsteadOfReturningRowsOrPartlyFillingTheDraft() async throws {
        let original = try base(calendar: ["2026-01-02", "2026-01-05", "2026-01-06"])
        var initial = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        var invalid = PortfolioDayDraft(); invalid.day = "2026-01-06"; invalid.valuationAt = "invalid date"
        initial.supplementalDays = [invalid]
        let immutableInput = initial
        let accounts = [account]
        let events = [try trade("buy", symbol: "NEW", timestamp: "2026-01-02T15:00:00Z")]
        let result = await Task.detached { () -> (Bool, Bool, Bool) in
            var draft = immutableInput
            // Explicit self-cancellation avoids timeout or scheduler-speed assumptions.
            withUnsafeCurrentTask { $0?.cancel() }
            var requirementsCancelled = false, fillCancelled = false
            do { _ = try draft.requirements(accounts: accounts, events: events) }
            catch is CancellationError { requirementsCancelled = true }
            catch { }
            do { _ = try draft.fillMissingQuotes(accounts: accounts, events: events) }
            catch is CancellationError { fillCancelled = true }
            catch { }
            return (requirementsCancelled, fillCancelled, draft == immutableInput)
        }.value
        #expect(result.0 && result.1 && result.2)
    }

    @Test func validMultiLegMembershipIsCheckedBeforeCuttingAtAnIntermediateValuation() throws {
        let original = try base()
        let first = try trade("leg-a", symbol: "A", timestamp: "2026-01-02T15:00:00Z", group: "group")
        let later = try trade("leg-b", symbol: "B", timestamp: "2026-01-05T15:00:00Z", group: "group")
        let draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        #expect(try draft.requirements(accounts: [account], events: [first, later]).map(\.instrumentIDs) == [["equity:A"], ["equity:A", "equity:B"]])
        #expect(throws: LedgerError.invalidStrategy) { try draft.requirements(accounts: [account], events: [first]) }
    }

    @Test func missingOrInvalidValuationKeepsTheDateVisibleAndDoesNotGuessHoldings() throws {
        let original = try base(calendar: ["2026-01-02", "2026-01-05", "2026-01-06"])
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        let events = [try trade("buy", symbol: "NEW", timestamp: "2026-01-02T15:00:00Z")]
        let missing = try #require(draft.requirements(accounts: [account], events: events).last)
        #expect(missing.day == "2026-01-06" && missing.valuationAt == nil && missing.instrumentIDs.isEmpty && missing.reason != nil)
        var invalid = PortfolioDayDraft(); invalid.day = "2026-01-06"; invalid.valuationAt = "bad date"
        draft.supplementalDays = [invalid]
        let invalidRow = try #require(draft.requirements(accounts: [account], events: events).last)
        #expect(invalidRow.valuationAt == nil && invalidRow.reason != nil)
        #expect(throws: (any Error).self) { try draft.build(calculatedAt: original.calculatedAt) }
    }

    @Test func reusedSessionAcceptsNewPriceWithoutReconstructingItsDatesOrEvidence() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        var day = PortfolioDayDraft(); day.day = "2026-01-02"
        var quote = PortfolioQuoteDraft(); quote.instrumentID = "equity:OLD"
        quote.quoteAt = "2026-01-02T21:00:00.0004Z"; quote.bid = "12"; quote.ask = "12.01"; quote.priceEvidence = proof("replacement-price")
        day.quotes = [quote]; draft.supplementalDays = [day]
        let built = try draft.build(calculatedAt: original.calculatedAt)
        #expect(built.days[0].sessions == original.days[0].sessions)
        #expect(built.days[0].valuationAt == original.days[0].valuationAt)
        #expect(built.days[0].prices[0] == original.days[0].prices[0])
        #expect(built.days[0].prices[1].sessionID == original.days[0].sessions[0].id)
        draft.supplementalDays[0].quotes[0].opensAt = "2026-01-02T14:30:00Z"
        #expect(throws: InvestmentDraftError.conflictingSession) { try draft.build(calculatedAt: original.calculatedAt) }
    }

    @Test func priceAndSourceIdentitiesCannotBeReusedForEditedContent() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        var day = PortfolioDayDraft(); day.day = "2026-01-02"
        var quote = PortfolioQuoteDraft(); quote.instrumentID = "equity:OLD"
        quote.quoteAt = "2026-01-02T21:00:00.0004Z"; quote.bid = "12"; quote.ask = "13"; quote.priceEvidence = proof("price")
        day.quotes = [quote]; draft.supplementalDays = [day]
        #expect(throws: InvestmentDraftError.duplicateIdentity) { try draft.build(calculatedAt: original.calculatedAt) }
        draft.supplementalDays[0].quotes[0].priceEvidence = proof("new-price")
        let valid = try draft.build(calculatedAt: original.calculatedAt)
        var conflict = draft.supplementalDays[0].quotes[0]; conflict.bid = "14"
        draft.supplementalDays[0].quotes.append(conflict)
        #expect(throws: InvestmentDraftError.duplicateIdentity) { try draft.build(calculatedAt: original.calculatedAt) }
        #expect(valid.days[0].prices.count == 2)
    }

    @Test func calendarEvidenceIDCannotBeReboundWhenExtendingOrCropping() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        draft.replacesCalendar = true; draft.replacementTradingDays = "2026-01-02\n2026-01-05"
        draft.replacementCalendarEvidence = proof("calendar")
        #expect(throws: InvestmentDraftError.duplicateIdentity) { try draft.build(calculatedAt: original.calculatedAt) }
        draft.replacementCalendarEvidence.id = "new-calendar"
        #expect(try draft.build(calculatedAt: original.calculatedAt).calendar.evidence.id == "new-calendar")
    }

    @Test func evidenceNeverCarriesFromOneDateIntoAnotherAndReusedValuationCannotBeRounded() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        let events = [try trade("buy", symbol: "OLD", timestamp: "2026-01-02T15:00:00Z")]
        let rows = try draft.requirements(accounts: [account], events: events)
        #expect(rows[0].missingInstrumentIDs.isEmpty)
        #expect(rows[1].missingInstrumentIDs == ["equity:OLD"])
        var day = PortfolioDayDraft(); day.day = "2026-01-02"; day.valuationAt = "2026-01-02T21:00:00.001Z"
        draft.supplementalDays = [day]
        #expect(throws: InvestmentDraftError.reusedValuationChanged) { try draft.build(calculatedAt: original.calculatedAt) }
    }
    @Test func narrowingThenRestoringPeriodKeepsUnselectedSupplementDraftsWithoutConsumingThem() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        var first = PortfolioDayDraft(); first.day = "2026-01-02"
        var quote = PortfolioQuoteDraft(); quote.instrumentID = "equity:OLD"
        quote.quoteAt = "2026-01-02T21:00:00.0004Z"; quote.bid = "12"; quote.ask = "13"; quote.priceEvidence = proof("new-price")
        first.quotes = [quote]; draft.supplementalDays = [first]
        draft.startDay = "2026-01-05"
        let cropped = try draft.build(calculatedAt: original.calculatedAt)
        #expect(cropped.days.count == 1 && cropped.days[0].day == "2026-01-05" && cropped.days[0].prices.isEmpty)
        #expect(draft.supplementalDays == [first])
        draft.startDay = "2026-01-02"
        #expect(try draft.build(calculatedAt: original.calculatedAt).days[0].prices.count == 2)
        draft.startDay = "2026-01-05"
        draft.supplementalDays[0].day = "invalid"
        #expect(throws: InvestmentDraftError.invalidCalendar) { try draft.build(calculatedAt: original.calculatedAt) }
        draft.supplementalDays = [first, first]
        #expect(throws: InvestmentDraftError.duplicateIdentity) { try draft.build(calculatedAt: original.calculatedAt) }
    }

    @Test func reuseWithoutFlowProofDefaultsToNewEvidenceAndCanBeCompleted() throws {
        let original = try base()
        let noProof = PerformanceRequest(accountID: account.id, calculatedAt: original.calculatedAt,
                                        calendar: original.calendar, days: original.days)
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: noProof)
        #expect(draft.usesNewFlowEvidence && !draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        #expect(throws: (any Error).self) { try draft.build(calculatedAt: original.calculatedAt) }
        draft.flowEvidence = proof("new-flow-proof")
        let completed = try draft.build(calculatedAt: original.calculatedAt)
        #expect(completed.externalFlowsComplete && completed.flowCompletenessEvidence?.id == "new-flow-proof")
        #expect(completed.days == original.days)
        let fresh = try InvestmentCalculationDraft(accountID: account.id)
        #expect(fresh.usesNewFlowEvidence && !fresh.externalFlowsComplete)
    }

    @Test func everyRangeOrCalendarEditRevokesFlowConfirmationInTheDraft() throws {
        let original = try base()
        var draft = try InvestmentCalculationDraft(accountID: account.id, reusing: original)
        draft.externalFlowsComplete = true
        draft.startDay = "2026-01-03"
        #expect(!draft.externalFlowsComplete)
        let unconfirmed = try draft.build(calculatedAt: original.calculatedAt)
        #expect(!unconfirmed.externalFlowsComplete && unconfirmed.flowCompletenessEvidence == nil)

        draft.externalFlowsComplete = true
        draft.endDay = "2026-01-06"
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.replacesCalendar = true
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.replacementTradingDays = "2026-01-02\n2026-01-05\n2026-01-06"
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.replacementCalendarEvidence = proof("new-calendar")
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.replacementCalendarEvidence.text += " updated source"
        #expect(!draft.externalFlowsComplete)
        #expect(draft.reusedRequest?.flowCompletenessEvidence == original.flowCompletenessEvidence)

        // Binding writebacks with unchanged values do not create spurious edits.
        draft.externalFlowsComplete = true
        let sameStart = draft.startDay, sameEnd = draft.endDay
        let sameCalendar = draft.replacementTradingDays, sameEvidence = draft.replacementCalendarEvidence
        draft.startDay = sameStart; draft.endDay = sameEnd; draft.replacesCalendar = true
        draft.replacementTradingDays = sameCalendar; draft.replacementCalendarEvidence = sameEvidence
        #expect(draft.externalFlowsComplete)

        var row = PortfolioDayDraft(); row.day = "2026-01-06"
        draft.supplementalDays = [row]
        #expect(draft.externalFlowsComplete) // Empty fillMissingQuotes placeholder.
        var quote = PortfolioQuoteDraft(); quote.instrumentID = "equity:NEW"
        draft.supplementalDays[0].quotes = [quote]
        draft.supplementalDays[0].quotes[0].bid = "42"
        #expect(draft.externalFlowsComplete) // Quote edits do not change flow endpoints.
        draft.supplementalDays[0].valuationAt = "2026-01-06T21:00:00Z"
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.supplementalDays[0].day = "2026-01-05"
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.supplementalDays[0].valuationAt = "2026-01-05T21:00:00Z"
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.supplementalDays[0].valuationAt = ""
        #expect(!draft.externalFlowsComplete)
        draft.externalFlowsComplete = true
        draft.supplementalDays.removeAll()
        #expect(draft.externalFlowsComplete) // Removing an empty placeholder is not an endpoint edit.
    }

}
