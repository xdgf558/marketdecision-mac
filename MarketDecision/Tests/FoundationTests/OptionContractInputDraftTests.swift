import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import AppComposition

@Suite("Contract parameters without invented account or quote evidence")
struct OptionContractInputDraftTests {
    private let calculation = Date(timeIntervalSince1970: 1_760_000_000.0004)

    private func draft(_ strategy: OptionLabStrategy = .cashSecuredPut) -> OptionLabInputDraft {
        var value = OptionLabInputDraft()
        value.strategy = strategy; value.symbol = "DEMO"; value.asset = strategy == .coveredCall ? .etf : .stock
        value.underlyingPrice = "100"; value.shortLeg.quantity = "3"
        value.shortLeg.strike = "100"; value.shortLeg.enteredPrice = "2"
        value.settlementAt = "2025-11-14T21:00:00Z"
        if value.hasLongLeg {
            value.longLeg.strike = strategy == .putCreditSpread ? "95" : "105"
            value.longLeg.enteredPrice = "0.8"
        }
        return value
    }

    @Test(arguments: OptionLabStrategy.allCases)
    func primaryParametersCalculateEveryStrategyWithUnknownFunding(_ strategy: OptionLabStrategy) throws {
        let value = draft(strategy), before = value
        #expect(value.usesContractParametersOnly && value.usesEnteredPrices)
        #expect(value.calculationChecklist(createdAt: calculation).isEmpty)
        let input = try value.buildForCalculation(createdAt: calculation)
        #expect(value == before)
        #expect(input.isContractOnly && input.entryMode == .contractParameters && input.capital == nil)
        #expect(input.underlying.asset == value.asset && input.underlying.symbol == value.symbol)
        #expect(input.createdAt == calculation && input.asOf == calculation)
        #expect(input.underlying.quotedAt == calculation && input.underlying.receivedAt == calculation)
        #expect(input.shortLeg.quotedAt == calculation && input.shortLeg.receivedAt == calculation)
        #expect(input.shortLeg.source.origin == .manual && input.underlying.source.origin == .manual)
        #expect(input.shortLeg.source.reference.contains("not market quote times"))
        #expect(input.shortLeg.contractID.hasPrefix("MANUAL-PARAMETERS:"))
        #expect(input.shortLeg.quantity == 3 && (input.longLeg?.quantity ?? 3) == 3)
        #expect(input.shortLeg.bid == nil && input.shortLeg.ask == nil && input.shortLeg.tick == nil)
        #expect(input.shortLeg.bidSize == nil && input.shortLeg.askSize == nil)
        #expect(input.underlying.bid == nil && input.underlying.ask == nil)
        #expect(input.pricing == nil && input.risk == nil && input.scenario == nil && input.chainEvidence == nil)
        #expect(input.expiry.date.iso8601 == "2025-11-14")
        #expect(input.scenarioPrices == (try value.chartPricesFromEnteredInputs()))
        let report = try OptionLabEngine.calculate(input)
        #expect(report.selectedOutcome.funding == .notAssessed && !report.selectedOutcome.canFund)
        #expect(report.selectedOutcome.availableCashAfterFees == nil && report.researchOnly)
        #expect(report.selectedOutcome.totalFees == (try Money(value.hasLongLeg ? "3.9" : "1.95")))
        #expect(report.selectedOutcome.grossCredit == (try Money(value.hasLongLeg ? "360" : "600")))
    }

    @Test func simpleChecklistNeverRequiresAccountIDsQuoteAssistanceOrPlotSamples() {
        let value = OptionLabInputDraft()
        let checklist = value.calculationChecklist(createdAt: calculation)
        #expect(!checklist.isEmpty)
        #expect(!checklist.groups.contains { [.capital, .chart, .pricing, .risk, .scenario].contains($0.section) })
        #expect(checklist.groups.flatMap(\.issues).contains { $0.id == "timing.expiry" })
        #expect(!checklist.groups.flatMap(\.issues).contains { $0.id.contains("quoteMode") || $0.id.contains("evidenceMode") })
        #expect(value.asOf.isEmpty && value.sourceReference.isEmpty && value.shortLeg.contractID.isEmpty)
        #expect(value.cashBeforeTrade.isEmpty && value.availableShares.isEmpty && value.scenarioPrices.isEmpty)
    }

    @Test(arguments: ["expiry", "dateOnly", "wrongNYDate", "expired", "spotZero", "spotNegative", "strikeZero", "premiumMissing", "premiumNegative", "quantityZero", "quantityFraction", "quantityHuge", "longPremium", "wrongStrikeOrder", "feeMissing", "feeNegative"])
    func missingOrInvalidPrimaryInputsAreRejected(_ field: String) throws {
        var value = draft(.putCreditSpread)
        switch field {
        case "expiry": value.settlementAt = ""
        case "dateOnly": value.expirationDate = "2025-11-14"; value.settlementAt = ""
        case "wrongNYDate": value.expirationDate = "2025-11-15"
        case "expired": value.settlementAt = "2025-01-01T21:00:00Z"
        case "spotZero": value.underlyingPrice = "0"
        case "spotNegative": value.underlyingPrice = "-1"
        case "strikeZero": value.shortLeg.strike = "0"
        case "premiumMissing": value.shortLeg.enteredPrice = ""
        case "premiumNegative": value.shortLeg.enteredPrice = "-1"
        case "quantityZero": value.shortLeg.quantity = "0"
        case "quantityFraction": value.shortLeg.quantity = "1.5"
        case "quantityHuge": value.shortLeg.quantity = String(Int.max)
        case "longPremium": value.longLeg.enteredPrice = ""
        case "wrongStrikeOrder": value.longLeg.strike = "105"
        case "feeMissing": value.openingFeePerContract = ""
        default: value.ticketFee = "-1"
        }
        let before = value
        #expect(!value.calculationChecklist(createdAt: calculation).isEmpty)
        #expect(throws: (any Error).self) { try value.buildForCalculation(createdAt: calculation) }
        #expect(value == before)
    }

    @Test func explicitExpiryInstantDeterminesNewYorkDateWithoutInventedTime() throws {
        var value = draft()
        value.settlementAt = "2025-11-01T00:30:00Z"
        let input = try value.buildForCalculation(createdAt: calculation)
        #expect(input.expiry.date.iso8601 == "2025-10-31")
        #expect(input.expiry.settlementAt == ISO8601DateFormatter().date(from: value.settlementAt))
        value.expirationDate = "2025-11-01"
        #expect(throws: OptionLabDraftError.invalidDate) { try value.buildForCalculation(createdAt: calculation) }
    }

    @Test(arguments: [OptionLabStrategy.putCreditSpread, .callCreditSpread])
    func enteringAdvancedResearchCarriesSharedStrategyQuantity(_ strategy: OptionLabStrategy) throws {
        var value = draft(strategy)
        value.shortLeg.quantity = "5"; value.longLeg.quantity = "1"
        let original = value
        #expect(value.calculationChecklist(createdAt: calculation).isEmpty)
        let input = try value.buildForCalculation(createdAt: calculation)
        #expect(input.shortLeg.quantity == 5 && input.longLeg?.quantity == 5)
        #expect(value == original) // Read-only calculation does not mutate the draft.
        var expected = original
        expected.longLeg.quantity = "5"; expected.usesContractParametersOnly = false
        try value.enterAdvancedResearch()
        #expect(value == expected) // No source, cash or quote evidence is filled.
        #expect(!value.calculationChecklist(createdAt: calculation).groups.flatMap(\.issues).contains { $0.id == "longLeg.quantityMatch" })
        #expect(!value.calculationChecklist(createdAt: calculation).isEmpty) // Full evidence is still required.

        value.longLeg.quantity = "2"
        let edited = value
        try value.enterAdvancedResearch()
        #expect(value == edited) // Already-full drafts retain explicit per-leg edits.
        #expect(value.calculationChecklist(createdAt: calculation).groups.flatMap(\.issues).contains { $0.id == "longLeg.quantityMatch" })
    }

    @Test(arguments: ["", "0", "-1", "1.5", "invalid", String(Int.max)])
    func invalidStrategyQuantityRejectsCalculationOpeningAndTransitionAtomically(_ quantity: String) throws {
        var value = draft(.putCreditSpread)
        value.expirationDate = "2025-11-14"
        value.shortLeg.quantity = quantity; value.longLeg.quantity = "1"
        let original = value
        #expect(value.calculationChecklist(createdAt: calculation).groups.flatMap(\.issues).contains { $0.id == "shortLeg.quantity" })
        #expect(throws: OptionLabDraftError.invalidNumber) { try value.buildForCalculation(createdAt: calculation) }
        #expect(throws: OptionLabDraftError.invalidNumber) {
            try OptionTradeEntryDraft(openingFrom: value, automaticContractTerms: true)
        }
        #expect(throws: OptionLabDraftError.invalidNumber) { try value.enterAdvancedResearch() }
        #expect(value == original)
    }

    @Test func singleLegTransitionDoesNotRewriteUnusedProtectionFields() throws {
        var value = draft(.coveredCall)
        value.longLeg.quantity = "unused"
        var expected = value
        expected.usesContractParametersOnly = false
        try value.enterAdvancedResearch()
        #expect(value == expected)
    }

    @Test func explicitFeesAndChartSamplesAreRetainedAndInvalidSamplesAreNeverReplaced() throws {
        var value = draft()
        value.openingFeePerContract = "1.2"; value.ticketFee = "2"; value.terminalFeeTotal = "3"
        value.lambda = "0.4"; value.scenarioPrices = "80\n120"
        let input = try value.buildForCalculation(createdAt: calculation)
        #expect(input.policy.lambda == (try Money("0.4")))
        #expect(input.scenarioPrices.map(\.decimalString) == ["80", "120"])
        #expect(try OptionLabEngine.calculate(input).selectedOutcome.totalFees == Money("8.6"))
        for invalid in ["80\ninvalid", "-1", "100\n100.0"] {
            value.scenarioPrices = invalid
            #expect(value.calculationChecklist(createdAt: calculation).groups.contains { $0.section == .chart })
            #expect(throws: (any Error).self) { try value.buildForCalculation(createdAt: calculation) }
            #expect(value.scenarioPrices == invalid)
        }
    }

    @Test(arguments: ["underlyingQuote", "legQuote", "depth", "tick", "capital", "pricing", "risk", "scenario", "contractID", "quoteTime", "source", "twoSided"])
    func advancedInputsRequireExplicitFullEvidenceModeWithoutLoss(_ field: String) throws {
        var value = draft()
        switch field {
        case "underlyingQuote": value.underlyingBid = "99"; value.underlyingAsk = "101"
        case "legQuote": value.shortLeg.bid = "1.9"; value.shortLeg.ask = "2.1"
        case "depth": value.shortLeg.bidSize = "3"; value.shortLeg.askSize = "4"
        case "tick": value.shortLeg.tick = "0.01"
        case "capital": value.cashBeforeTrade = "10000"
        case "pricing": value.pricing.enabled = true; value.pricing.rate = "0.05"
        case "risk": value.risk.enabled = true; value.risk.sourceReference = "explicit risk assumption"
        case "scenario": value.scenario.enabled = true; value.scenario.spotShocks = "0.1"
        case "contractID": value.shortLeg.contractID = "user-supplied-id"
        case "quoteTime": value.underlyingQuotedAt = "2025-10-09T08:53:20Z"
        case "source": value.sourceReference = "user-supplied-source"
        default: value.usesEnteredPrices = false
        }
        let before = value
        #expect(!value.calculationChecklist(createdAt: calculation).isEmpty)
        #expect(throws: OptionLabDraftError.requiresFullEvidence) { try value.buildForCalculation(createdAt: calculation) }
        #expect(value == before)
    }

    @Test func frozenInputReplayAndCopiedSimpleDraftRetainModeSourcesAndExactTimes() throws {
        let input = try draft(.callCreditSpread).buildForCalculation(createdAt: calculation)
        let report = try OptionLabEngine.calculate(input)
        let restored = try JSONDecoder().decode(OptionLabReport.self, from: JSONEncoder().encode(report))
        #expect(try OptionLabEngine.replay(restored) == report)
        let copy = OptionLabInputDraft(input: restored.input)
        #expect(copy.usesContractParametersOnly && copy.usesEnteredPrices)
        #expect(copy.cashBeforeTrade.isEmpty && copy.availableShares.isEmpty)
        #expect(copy.calculationChecklist(createdAt: calculation).isEmpty)
        let rebuilt = try copy.buildForCalculation(createdAt: calculation)
        #expect(rebuilt.asOf == input.asOf && rebuilt.expiry == input.expiry)
        #expect(rebuilt.shortLeg == input.shortLeg && rebuilt.longLeg == input.longLeg && rebuilt.underlying == input.underlying)
        #expect(rebuilt.capital == nil && rebuilt.entryMode == input.entryMode && rebuilt.policy == input.policy)
        let later = calculation.addingTimeInterval(3600)
        let newCalculation = try copy.buildForCalculation(createdAt: later)
        #expect(newCalculation.asOf == later && newCalculation.shortLeg.quotedAt == later)
        #expect(try OptionLabEngine.replay(restored).input.asOf == calculation)
    }

    @Test func copiedLocalRecordTimesCannotBecomeFullQuoteEvidenceWithoutExplicitConfirmation() throws {
        let input = try draft().buildForCalculation(createdAt: calculation)
        var copy = OptionLabInputDraft(input: input)
        try copy.enterAdvancedResearch()
        copy.cashBeforeTrade = "100000"; copy.committedCash = "0"
        copy.availableShares = "0"; copy.committedShares = "0"; copy.capitalReference = "explicit balance"
        #expect(copy.calculationChecklist(createdAt: calculation).groups.flatMap(\.issues).contains { $0.id == "timing.recordedMetadata" })
        #expect(throws: OptionLabDraftError.requiresFullEvidence) { try copy.buildForCalculation(createdAt: calculation) }
        try copy.applyManualQuoteAssistance(quotedAt: calculation, settlementAt: input.expiry.settlementAt,
            quoteReference: "user-confirmed full manual quote assumption", expiryReference: "user-confirmed expiry assumption")
        #expect(copy.calculationChecklist(createdAt: calculation).isEmpty)
        let full = try copy.buildForCalculation(createdAt: calculation)
        #expect(full.entryMode == nil && full.capital != nil)
        #expect(full.underlying.source.reference == "user-confirmed full manual quote assumption")
    }

    @Test func oldSyntheticAndChainCopiesStayFullAndStrictBuilderStillRequiresOriginalEvidence() throws {
        let simple = draft()
        #expect(throws: (any Error).self) { try simple.build(createdAt: calculation) }
        var full = simple
        try full.enterAdvancedResearch()
        let settlement = try #require(ISO8601DateFormatter().date(from: full.settlementAt))
        try full.applyManualQuoteAssistance(quotedAt: calculation, settlementAt: settlement,
            quoteReference: "explicit full manual source", expiryReference: "explicit user expiry")
        full.cashBeforeTrade = "100000"; full.committedCash = "0"
        full.availableShares = "0"; full.committedShares = "0"; full.capitalReference = "explicit balance"
        try full.useChartPricesFromEnteredInputs()
        let original = try full.build(createdAt: calculation)
        #expect(original.entryMode == nil && original.capital != nil)
        let copied = OptionLabInputDraft(input: original)
        #expect(!copied.usesContractParametersOnly && copied.usesEnteredPrices)
        #expect(copied.calculationChecklist(createdAt: calculation) == copied.dailyInputChecklist())
        let rebuilt = try copied.buildForCalculation(createdAt: calculation)
        #expect(rebuilt.entryMode == nil && rebuilt.capital == original.capital && rebuilt.shortLeg == original.shortLeg)
        var synthetic = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        #expect(!synthetic.usesContractParametersOnly && synthetic.origin == .synthetic)
        synthetic.usesContractParametersOnly = true
        #expect(throws: OptionLabDraftError.requiresFullEvidence) { try synthetic.buildForCalculation(createdAt: calculation) }
        var chain = try OptionChainLabBridge.draft(OptionChainDemo.capture(), strategy: .cashSecuredPut,
            shortID: "DEMO261113P00100000", longID: nil, quantity: 1)
        #expect(!chain.usesContractParametersOnly && chain.chainEvidence != nil)
        chain.usesContractParametersOnly = true
        #expect(throws: OptionLabDraftError.requiresFullEvidence) { try chain.buildForCalculation(createdAt: calculation) }
    }
}
