import Foundation
import Testing
import CoreDomain
import OptionsAnalytics
@testable import AppComposition

@Suite("Optional covered-call holding cost in contract and full drafts")
struct OptionCoveredCallCostDraftTests {
    private let calculation = Date(timeIntervalSince1970: 1_760_000_000.0004)

    private func draft() -> OptionLabInputDraft {
        var value = OptionLabInputDraft()
        value.strategy = .coveredCall; value.symbol = "DEMO"
        value.underlyingPrice = "44.92"; value.shortLeg.quantity = "10"
        value.shortLeg.strike = "60"; value.shortLeg.enteredPrice = "0.7"
        value.settlementAt = "2025-11-14T21:00:00Z"
        return value
    }

    private func fullDraft() throws -> OptionLabInputDraft {
        var value = draft()
        value.usesContractParametersOnly = false
        let settlement = try #require(ISO8601DateFormatter().date(from: value.settlementAt))
        try value.applyManualQuoteAssistance(quotedAt: calculation, settlementAt: settlement,
            quoteReference: "explicit manual quote assumption", expiryReference: "explicit manual expiry")
        value.cashBeforeTrade = "10000"; value.committedCash = "0"
        value.availableShares = "1000"; value.committedShares = "0"
        value.capitalReference = "explicit manual capital assumption"
        try value.useChartPricesFromEnteredInputs()
        return value
    }

    @Test func emptyCostDoesNotAcquireCurrentPriceOrZeroBasis() throws {
        for raw in ["", " ", "\n\t"] {
            var simple = draft(), full = try fullDraft()
            simple.coveredCallCostPerShare = raw; full.coveredCallCostPerShare = raw
            #expect(simple.calculationChecklist(createdAt: calculation).isEmpty)
            #expect(full.dailyInputChecklist().isEmpty)
            let input = try simple.buildForCalculation(createdAt: calculation)
            #expect(input.coveredCallCostPerShare == nil)
            #expect(try full.build(createdAt: calculation).coveredCallCostPerShare == nil)
            #expect(try OptionLabEngine.calculate(input).schemaVersion == OptionLabEngine.contractSchemaVersion)
            #expect(simple.coveredCallCostPerShare == raw)
        }
    }

    @Test(arguments: ["0", "50", "70.125", " 50.00 "])
    func explicitCostIsKeptWithoutPromotingCapitalOrReplacingSpot(_ raw: String) throws {
        var simple = draft(), full = try fullDraft()
        simple.coveredCallCostPerShare = raw; full.coveredCallCostPerShare = raw
        let before = simple
        let expected = try Money(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(simple.calculationChecklist(createdAt: calculation).isEmpty)
        #expect(full.dailyInputChecklist().isEmpty)
        let input = try simple.buildForCalculation(createdAt: calculation)
        let complete = try full.build(createdAt: calculation)
        #expect(input.coveredCallCostPerShare == expected && complete.coveredCallCostPerShare == expected)
        #expect(input.underlying.enteredPrice == (try Money("44.92")))
        #expect(complete.underlying.enteredPrice == input.underlying.enteredPrice)
        #expect(input.capital == nil && input.isContractOnly)
        #expect(try OptionLabEngine.calculate(input).selectedOutcome.funding == .notAssessed)
        #expect(simple == before)
    }

    @Test(arguments: ["-0.01", "NaN", "unknown", "1.2.3"])
    func invalidProvidedCostIsRejectedInBothModes(_ raw: String) throws {
        var simple = draft(), full = try fullDraft()
        simple.coveredCallCostPerShare = raw; full.coveredCallCostPerShare = raw
        let before = simple
        for value in [simple, full] {
            #expect(value.calculationChecklist(createdAt: calculation).groups.flatMap(\.issues)
                .contains { $0.id == "underlying.coveredCallCost" })
            #expect(throws: OptionLabDraftError.invalidNumber) { try value.buildForCalculation(createdAt: calculation) }
            #expect(throws: OptionLabDraftError.invalidNumber) { try value.build(createdAt: calculation) }
        }
        #expect(simple == before)
    }

    @Test(arguments: [OptionLabStrategy.cashSecuredPut, .putCreditSpread, .callCreditSpread])
    func otherStrategiesCannotSilentlyIgnoreProvidedCost(_ strategy: OptionLabStrategy) throws {
        var simple = draft(), full = try fullDraft()
        simple.strategy = strategy; full.strategy = strategy
        simple.coveredCallCostPerShare = "50"; full.coveredCallCostPerShare = "50"
        for value in [simple, full] {
            #expect(value.calculationChecklist(createdAt: calculation).groups.flatMap(\.issues)
                .contains { $0.id == "underlying.coveredCallCost" })
            #expect(throws: OptionLabDraftError.invalidNumber) { try value.buildForCalculation(createdAt: calculation) }
            #expect(throws: OptionLabDraftError.invalidNumber) { try value.build(createdAt: calculation) }
        }
    }

    @Test func costSurvivesFrozenEncodingAndCopiedDraftWithoutChangingOriginalInput() throws {
        var value = draft(); value.coveredCallCostPerShare = "50"
        let input = try value.buildForCalculation(createdAt: calculation)
        let encoded = try JSONEncoder().encode(input)
        let restored = try JSONDecoder().decode(OptionLabInput.self, from: encoded)
        #expect(restored == input && restored.coveredCallCostPerShare == (try Money("50")))
        let report = try OptionLabEngine.calculate(restored)
        let frozen = try JSONDecoder().decode(OptionLabReport.self, from: JSONEncoder().encode(report))
        #expect(try OptionLabEngine.replay(frozen) == report)
        var copy = OptionLabInputDraft(input: frozen.input)
        #expect(copy.coveredCallCostPerShare == "50" && copy.usesContractParametersOnly)
        #expect(copy.calculationChecklist(createdAt: calculation).isEmpty)
        #expect(try copy.buildForCalculation(createdAt: calculation).coveredCallCostPerShare == Money("50"))
        copy.coveredCallCostPerShare = "51"
        #expect(copy != OptionLabInputDraft(input: frozen.input))
        #expect(try copy.buildForCalculation(createdAt: calculation).coveredCallCostPerShare == Money("51"))
        #expect(frozen.input.coveredCallCostPerShare == (try Money("50")))
    }

    @Test func enteringFullResearchRetainsCostAndStillRequiresSourceConfirmation() throws {
        var value = draft(); value.coveredCallCostPerShare = "50"
        let input = try value.buildForCalculation(createdAt: calculation)
        var copy = OptionLabInputDraft(input: input)
        copy.usesContractParametersOnly = false
        #expect(copy.coveredCallCostPerShare == "50")
        #expect(throws: OptionLabDraftError.requiresFullEvidence) { try copy.buildForCalculation(createdAt: calculation) }
        copy.cashBeforeTrade = "10000"; copy.committedCash = "0"
        copy.availableShares = "1000"; copy.committedShares = "0"; copy.capitalReference = "explicit balance"
        try copy.applyManualQuoteAssistance(quotedAt: calculation, settlementAt: input.expiry.settlementAt,
            quoteReference: "reconfirmed manual quote assumption", expiryReference: "reconfirmed manual expiry")
        #expect(copy.dailyInputChecklist().isEmpty)
        let full = try copy.buildForCalculation(createdAt: calculation)
        #expect(!full.isContractOnly && full.coveredCallCostPerShare == (try Money("50")))
        #expect(full.underlying.enteredPrice == input.underlying.enteredPrice)
        let copiedFull = OptionLabInputDraft(input: full)
        #expect(copiedFull.coveredCallCostPerShare == "50" && !copiedFull.usesContractParametersOnly)
        copy.usesContractParametersOnly = true
        #expect(copy.coveredCallCostPerShare == "50")
        // Mode changes cannot silently discard the explicit full-source evidence.
        #expect(throws: OptionLabDraftError.requiresFullEvidence) { try copy.buildForCalculation(createdAt: calculation) }
    }
}
