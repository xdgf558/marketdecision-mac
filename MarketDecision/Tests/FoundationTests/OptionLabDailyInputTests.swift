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
}
