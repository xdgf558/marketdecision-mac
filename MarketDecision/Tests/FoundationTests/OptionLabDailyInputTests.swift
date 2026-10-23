import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import AppComposition

@Suite("Daily manual option input without invented market evidence")
struct OptionLabDailyInputTests {
    private let quote = Date(timeIntervalSince1970: 1_760_000_000.0004)
    private let expiry = Date(timeIntervalSince1970: 1_762_120_800)

    private func numericDraft() -> OptionLabInputDraft {
        var value = OptionLabInputDraft()
        value.symbol = "DEMO"; value.underlyingBid = "100"; value.underlyingAsk = "100.02"
        value.shortLeg.strike = "100"; value.shortLeg.bid = "2"; value.shortLeg.ask = "2.2"
        value.shortLeg.bidSize = "10"; value.shortLeg.askSize = "12"; value.shortLeg.tick = "0.01"
        value.cashBeforeTrade = "100000"; value.committedCash = "0"
        value.availableShares = "0"; value.committedShares = "0"; value.capitalReference = "explicit manual balance"
        return value
    }
    private func apply(_ value: inout OptionLabInputDraft) throws {
        try value.applyManualQuoteAssistance(quotedAt: quote, settlementAt: expiry,
            quoteReference: "user-confirmed same-time assumption", expiryReference: "explicit user expiry assumption")
    }

    @Test func explicitManualAssistanceBuildsCompleteInputWithoutChangingNumericAssumptions() throws {
        var value = numericDraft(), previous = value
        try apply(&value); try value.useChartPricesFromEnteredInputs()
        let input = try value.build(createdAt: quote.addingTimeInterval(1))
        #expect(input.underlying.quotedAt == quote && input.underlying.receivedAt == quote && input.asOf == quote)
        #expect(input.shortLeg.quotedAt == quote && input.shortLeg.receivedAt == quote)
        #expect(input.expiry.settlementAt == expiry)
        #expect(input.underlying.source.origin == .manual && input.shortLeg.source.origin == .manual)
        #expect(input.shortLeg.contractID.hasPrefix("MANUAL-") && input.chainEvidence == nil)
        #expect(input.shortLeg.bid == (try Money(previous.shortLeg.bid)))
        #expect(value.shortLeg.tick == previous.shortLeg.tick && value.shortLeg.bidSize == previous.shortLeg.bidSize)
        #expect(value.cashBeforeTrade == previous.cashBeforeTrade && value.committedCash == previous.committedCash)
        #expect(value.lambda == previous.lambda && value.openingFeePerContract == previous.openingFeePerContract)
        #expect(value.ticketFee == previous.ticketFee && value.terminalFeeTotal == previous.terminalFeeTotal)
        #expect(!value.pricing.enabled && !value.risk.enabled && !value.scenario.enabled)
        #expect(value.dailyInputIssues.isEmpty)
        let report = try OptionLabEngine.calculate(input)
        #expect(report.pricing == nil && report.researchOnly)
        // Reapplying a different explicit time preserves an established internal ID.
        previous = value
        try value.applyManualQuoteAssistance(quotedAt: quote.addingTimeInterval(1), settlementAt: expiry,
            quoteReference: "second explicit assumption", expiryReference: "explicit expiry")
        #expect(value.shortLeg.contractID == previous.shortLeg.contractID)
    }

    @Test func helperRejectsSyntheticAndAttachedChainInputsWithoutMutation() throws {
        var synthetic = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        let before = synthetic
        #expect(throws: OptionLabDraftError.missingField) { try apply(&synthetic) }
        #expect(synthetic == before)
        var chain = try OptionChainLabBridge.draft(OptionChainDemo.capture(), strategy: .cashSecuredPut,
            shortID: "DEMO261113P00100000", longID: nil, quantity: 1)
        let beforeChain = chain
        #expect(!chain.canUseManualQuoteAssistance)
        #expect(throws: OptionLabDraftError.missingField) { try apply(&chain) }
        #expect(chain == beforeChain && chain.chainEvidence != nil)
    }

    @Test func invalidHelperInputsLeaveDraftAtomicAndDoNotFillUnknownNumerics() throws {
        var value = OptionLabInputDraft()
        let before = value
        #expect(throws: OptionLabDraftError.missingField) {
            try value.applyManualQuoteAssistance(quotedAt: quote, settlementAt: expiry, quoteReference: " ", expiryReference: "known")
        }
        #expect(value == before)
        #expect(throws: OptionLabDraftError.invalidDate) {
            try value.applyManualQuoteAssistance(quotedAt: quote, settlementAt: quote, quoteReference: "known", expiryReference: "known")
        }
        #expect(value == before)
        try apply(&value)
        #expect(value.shortLeg.tick.isEmpty && value.shortLeg.bidSize.isEmpty && value.shortLeg.askSize.isEmpty)
        #expect(value.cashBeforeTrade.isEmpty && value.committedCash.isEmpty && value.availableShares.isEmpty && value.committedShares.isEmpty)
        #expect(value.underlyingBid.isEmpty && value.shortLeg.bid.isEmpty && value.scenarioPrices.isEmpty)
        #expect(value.dailyInputIssues.contains { $0.contains("tick") })
        #expect(value.dailyInputIssues.contains { $0.contains("资金") })
    }

    @Test func newYorkExpiryDateAndFractionalQuoteSurviveHelperWithoutUTCDaySubstitution() throws {
        var value = numericDraft()
        let midnightUTC = try #require(ISO8601DateFormatter().date(from: "2025-11-01T00:30:00Z"))
        try value.applyManualQuoteAssistance(quotedAt: quote, settlementAt: midnightUTC,
            quoteReference: "explicit manual quote", expiryReference: "New York local expiry")
        try value.useChartPricesFromEnteredInputs()
        let input = try value.build(createdAt: quote.addingTimeInterval(1))
        #expect(value.expirationDate == "2025-10-31")
        #expect(input.expiry.settlementAt == midnightUTC && input.asOf == quote)
        #expect(input.shortLeg.quotedAt == quote && input.underlying.quotedAt == quote)
    }

    @Test func chartSamplesUseOnlyEnteredPricesAndRemainAnExplicitAction() throws {
        var value = numericDraft()
        value.strategy = .putCreditSpread; value.longLeg.strike = "95"
        #expect(value.scenarioPrices.isEmpty)
        let suggestions = try value.chartPricesFromEnteredInputs()
        #expect(suggestions.map(\.decimalString) == ["95", "100", "100.02"])
        #expect(value.scenarioPrices.isEmpty)
        try value.useChartPricesFromEnteredInputs()
        #expect(value.scenarioPrices == "95\n100\n100.02")
        let before = value
        value.longLeg.strike = ""
        #expect(throws: (any Error).self) { try value.useChartPricesFromEnteredInputs() }
        #expect(value.scenarioPrices == before.scenarioPrices)
        #expect(!value.pricing.enabled && !value.risk.enabled)
    }

    @Test func missingTickStaysMissingAndExistingEngineStillRejectsTheCalculation() throws {
        var value = numericDraft(); value.shortLeg.tick = ""
        try apply(&value); try value.useChartPricesFromEnteredInputs()
        let input = try value.build(createdAt: quote.addingTimeInterval(1))
        #expect(input.shortLeg.tick == nil)
        #expect(throws: OptionLabError.missingTick) { try OptionLabEngine.calculate(input) }
        #expect(value.dailyInputIssues.contains { $0.contains("tick") })
    }

    @Test func dailyPreparationWithoutOptInsOnlyInspectsAndNeverInventsMissingValues() throws {
        var value = OptionLabInputDraft()
        let before = value
        let checklist = try value.prepareDaily()
        #expect(value == before && !checklist.isEmpty)
        #expect(checklist.groups.contains { $0.section == .shortLeg && $0.issues.contains { $0.id == "shortLeg.tick" } })
        #expect(checklist.groups.contains { $0.section == .capital })
        #expect(!checklist.groups.contains { [.longLeg, .pricing, .risk, .scenario].contains($0.section) })

        let times = OptionDailyQuoteAssistance(quotedAt: quote, settlementAt: expiry,
            quoteReference: "explicit common manual quote", expiryReference: "explicit expiry", confirmedCommonQuoteTime: true)
        _ = try value.prepareDaily(.init(quoteAssistance: times))
        #expect(value.shortLeg.tick.isEmpty && value.shortLeg.bidSize.isEmpty && value.shortLeg.askSize.isEmpty)
        #expect(value.underlyingBid.isEmpty && value.underlyingAsk.isEmpty && value.shortLeg.bid.isEmpty && value.shortLeg.ask.isEmpty)
        #expect(value.cashBeforeTrade.isEmpty && value.committedCash.isEmpty && value.availableShares.isEmpty && value.committedShares.isEmpty)
        #expect(value.pricing.rate.isEmpty && value.pricing.dividendYield.isEmpty && value.pricing.volatility.isEmpty)
        #expect(!value.pricing.enabled && !value.scenario.enabled && !value.risk.enabled && value.scenarioPrices.isEmpty)
        #expect(value.origin == .manual && value.chainEvidence == nil)
    }

    @Test func dailyPreparationRequiresConfirmedCommonTimeAndRejectsSyntheticOrChainRewriting() throws {
        let unconfirmed = OptionDailyQuoteAssistance(quotedAt: quote, settlementAt: expiry,
            quoteReference: "manual quote", expiryReference: "expiry", confirmedCommonQuoteTime: false)
        var value = numericDraft()
        let before = value
        #expect(throws: OptionLabDraftError.missingField) { try value.prepareDaily(.init(quoteAssistance: unconfirmed)) }
        #expect(value == before)

        let confirmed = OptionDailyQuoteAssistance(quotedAt: quote, settlementAt: expiry,
            quoteReference: "manual quote", expiryReference: "expiry", confirmedCommonQuoteTime: true)
        var synthetic = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        let originalSynthetic = synthetic
        #expect(throws: OptionLabDraftError.missingField) { try synthetic.prepareDaily(.init(quoteAssistance: confirmed)) }
        #expect(synthetic == originalSynthetic && synthetic.origin == .synthetic)
        var chain = try OptionChainLabBridge.draft(OptionChainDemo.capture(), strategy: .cashSecuredPut,
            shortID: "DEMO261113P00100000", longID: nil, quantity: 1)
        let originalChain = chain
        #expect(throws: OptionLabDraftError.missingField) { try chain.prepareDaily(.init(quoteAssistance: confirmed)) }
        #expect(chain == originalChain && chain.chainEvidence != nil)
        _ = try chain.prepareDaily()
        #expect(chain == originalChain) // Reading guidance never flattens chain evidence.
    }

    @Test func protectionQuantityChangesOnlyAfterExplicitSynchronization() throws {
        var value = numericDraft()
        value.strategy = .putCreditSpread; value.shortLeg.quantity = "3"; value.longLeg.quantity = "2"
        value.longLeg.strike = "95"; value.longLeg.bid = "0.8"; value.longLeg.ask = "1"
        let before = value
        let checklist = try value.prepareDaily()
        #expect(value == before)
        #expect(checklist.groups.contains { $0.section == .longLeg && $0.issues.contains { $0.id == "longLeg.quantityMatch" } })
        let after = try value.prepareDaily(.init(synchronizeProtectionQuantity: true))
        var expected = before; expected.longLeg.quantity = "3"
        #expect(value == expected)
        #expect(!after.groups.flatMap(\.issues).contains { $0.id == "longLeg.quantityMatch" })
        #expect(value.longLeg.tick.isEmpty && value.longLeg.bidSize.isEmpty && value.longLeg.askSize.isEmpty)

        var single = numericDraft()
        let singleBefore = single
        #expect(throws: OptionLabDraftError.missingField) { try single.prepareDaily(.init(synchronizeProtectionQuantity: true)) }
        #expect(single == singleBefore)
    }

    @Test func latePreparationFailureRollsBackTimeIdentityQuantityAndChartTogether() throws {
        var value = numericDraft()
        value.strategy = .putCreditSpread; value.shortLeg.quantity = "3"; value.longLeg.quantity = "1"
        value.scenarioPrices = "90\n110" // Kept if requested chart extraction fails.
        let before = value
        let times = OptionDailyQuoteAssistance(quotedAt: quote, settlementAt: expiry,
            quoteReference: "explicit common quote", expiryReference: "explicit expiry", confirmedCommonQuoteTime: true)
        #expect(throws: (any Error).self) {
            try value.prepareDaily(.init(quoteAssistance: times, synchronizeProtectionQuantity: true, useEnteredPricesForChart: true))
        }
        #expect(value == before) // Missing long strike failed after the other proposed edits.
        #expect(value.shortLeg.contractID.isEmpty && value.longLeg.contractID.isEmpty)
        value.longLeg.strike = "95"; value.shortLeg.quantity = "1.5"
        let invalidQuantity = value
        #expect(throws: OptionLabDraftError.invalidNumber) {
            try value.prepareDaily(.init(quoteAssistance: times, synchronizeProtectionQuantity: true))
        }
        #expect(value == invalidQuantity)
    }

    @Test func requestedChartSamplingUsesEnteredPricesAndOtherwiseKeepsCustomSamples() throws {
        var value = numericDraft()
        value.strategy = .putCreditSpread; value.longLeg.strike = "95"
        value.scenarioPrices = "80\n120"
        let before = value
        _ = try value.prepareDaily()
        #expect(value == before)
        _ = try value.prepareDaily(.init(useEnteredPricesForChart: true))
        var expected = before; expected.scenarioPrices = "95\n100\n100.02"
        #expect(value == expected)
        #expect(value.shortLeg.quotedAt.isEmpty && value.shortLeg.tick == before.shortLeg.tick)
        #expect(!value.pricing.enabled && !value.scenario.enabled)
    }

    @Test func checkingCopiedInputPreservesExactDatesSourcesAndSyntheticStatus() throws {
        var originalDraft = numericDraft()
        try apply(&originalDraft); try originalDraft.useChartPricesFromEnteredInputs()
        let original = try originalDraft.build(createdAt: quote.addingTimeInterval(1))
        var copied = OptionLabInputDraft(input: original)
        let before = copied
        #expect(try copied.prepareDaily().isEmpty)
        #expect(copied == before)
        let rebuilt = try copied.build(createdAt: original.createdAt)
        #expect(rebuilt.asOf == quote && rebuilt.expiry.settlementAt == expiry)
        #expect(rebuilt.shortLeg.quotedAt == original.shortLeg.quotedAt && rebuilt.shortLeg.receivedAt == original.shortLeg.receivedAt)
        #expect(rebuilt.underlying.quotedAt == original.underlying.quotedAt && rebuilt.underlying.receivedAt == original.underlying.receivedAt)
        #expect(rebuilt.shortLeg.source == original.shortLeg.source && rebuilt.underlying.source == original.underlying.source)
        #expect(rebuilt.expiry.source == original.expiry.source && rebuilt.chainEvidence == original.chainEvidence)
        var synthetic = try OptionLabInputDraft.synthetic(strategy: .putCreditSpread)
        let syntheticBefore = synthetic
        _ = try synthetic.prepareDaily()
        #expect(synthetic == syntheticBefore && synthetic.origin == .synthetic)
    }

    @Test func checklistGroupsHaveStableUniqueIDsAndOptionalInputsRemainExplicit() throws {
        var value = numericDraft()
        try apply(&value); try value.useChartPricesFromEnteredInputs()
        #expect(value.dailyInputChecklist().isEmpty)
        value.pricing.enabled = true; value.risk.enabled = true; value.scenario.enabled = true
        value.risk.earnings.enabled = true; value.risk.dividend.enabled = true
        let checklist = value.dailyInputChecklist()
        #expect(checklist == value.dailyInputChecklist())
        #expect(checklist.groups.map(\.section) == [.pricing, .risk, .scenario])
        let ids = checklist.groups.flatMap(\.issues).map(\.id)
        #expect(Set(ids).count == ids.count && checklist.issueCount == ids.count)
        #expect(ids.contains("pricing.assumptions") && ids.contains("risk.earnings") && ids.contains("risk.dividend") && ids.contains("scenario.axes"))
        #expect(value.dailyInputIssues == checklist.groups.flatMap { $0.issues.map(\.message) })
        #expect(value.pricing.rate.isEmpty && value.pricing.dividendYield.isEmpty && value.scenario.spotShocks.isEmpty)
    }
}
