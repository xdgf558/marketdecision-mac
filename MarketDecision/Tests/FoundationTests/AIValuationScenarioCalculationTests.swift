import Foundation
import Testing
import CoreDomain
import AIInsights
import AppComposition

@Suite("Confirmed AI price-to-sales scenario calculations")
struct AIValuationScenarioCalculationTests {
    private func input(revenue: String? = "1200", shares: String = "100",
                       price: String = "20") throws -> AIInsightInput {
        let source = AIInsightReferenceValuationContext.referenceSourceID
        let cap = try Money(price).multiplied(by: shares)
        let salesMultiple: Money?
        if let revenue, let amount = try? Money(revenue), amount.amount > 0 {
            let value = try cap.divided(by: amount.decimalString)
            salesMultiple = value.amount > 0 ? value : nil
        } else { salesMultiple = nil }
        return AIInsightInput(ticker: "DEMO", companyName: "Synthetic Scenario Company",
            periodEnd: "2026-09-30", cutoff: "2026-10-22T00:00:00.000400Z",
            metrics: [
                .init(id: "base.revenue", label: "营业收入（TTM 2025-10-01—2026-09-30）",
                      value: revenue, unit: "USD", unavailable: revenue == nil ? "missingInput" : nil,
                      sourceIDs: ["local.base"]),
                .init(id: "reference.price", label: "用户参考价", value: price, unit: "USD/share",
                      unavailable: nil, sourceIDs: [source]),
                .init(id: "reference.shares", label: "用户确认实际股数", value: shares, unit: "shares",
                      unavailable: nil, sourceIDs: [source]),
                .init(id: "reference.marketCap", label: "本地参考市值", value: cap.decimalString, unit: "USD",
                      unavailable: nil, sourceIDs: [source]),
                .init(id: "reference.pe", label: "参考市盈率", value: nil, unit: "multiple",
                      unavailable: "missingInput", sourceIDs: [source]),
                .init(id: "reference.ps", label: "参考市销率", value: salesMultiple?.decimalString, unit: "multiple",
                      unavailable: salesMultiple == nil ? "missingInput" : nil, sourceIDs: [source]),
                .init(id: "reference.pfcf", label: "参考市现率", value: nil, unit: "multiple",
                      unavailable: "missingInput", sourceIDs: [source])
            ], sources: [
                .init(id: "local.base", label: "Synthetic replayed TTM financials"),
                .init(id: source, label: "Synthetic user-confirmed reference inputs")
            ], referenceValuation: .init(referenceAt: "2026-10-25T03:53:57.000400Z",
                                         sharesAsOf: "2026-10-15"))
    }

    private func proposal(_ low: String = "1", _ middle: String = "2",
                          _ high: String = "3") -> AIPriceSalesScenarioProposal {
        let claim = AIInsightClaim(text: "合成假设，不是可比公司或历史估值事实。",
                                   evidenceIDs: ["base.revenue", "reference.shares"])
        return AIPriceSalesScenarioProposal(
            conservative: .init(multiple: low, rationale: claim),
            base: .init(multiple: middle, rationale: claim),
            optimistic: .init(multiple: high, rationale: claim))
    }

    private func replacingMetrics(_ source: AIInsightInput, _ metrics: [AIInsightMetric]) -> AIInsightInput {
        AIInsightInput(format: source.format, ticker: source.ticker, companyName: source.companyName,
            periodEnd: source.periodEnd, cutoff: source.cutoff, metrics: metrics,
            sources: source.sources, referenceValuation: source.referenceValuation)
    }

    @Test func threeScenarioPricesUseRevenueAndSharesRatherThanReferencePrice() throws {
        let first = try AIValuationScenarioCalculation.calculate(input: input(), proposal: proposal())
        let changedPrice = try AIValuationScenarioCalculation.calculate(input: input(price: "80"), proposal: proposal())
        #expect(AIValuationScenarioCalculation.method == "confirmed-ai-ps-scenarios.v1")
        #expect(first.rows.map(\.scenario) == [.conservative, .base, .optimistic])
        #expect(first.rows.map { $0.targetMultiple.decimalString } == ["1", "2", "3"])
        #expect(first.rows.map { $0.price.decimalString } == ["12", "24", "36"])
        #expect(changedPrice.rows == first.rows)
        #expect(first.referencePrice.decimalString == "20")
        #expect(changedPrice.referencePrice.decimalString == "80")
        #expect(first.inputDigest != changedPrice.inputDigest)
    }

    @Test func multiplicationPrecedesDivisionWithoutRoundedPerShareIntermediate() throws {
        let result = try AIValuationScenarioCalculation.calculate(
            input: input(revenue: "1", shares: "3", price: "1"), proposal: proposal("3", "6", "9"))
        // The independently known rational results are 1*3/3, 1*6/3 and 1*9/3.
        // Dividing 1/3 at an intermediate 18-place boundary would not produce them.
        #expect(result.rows.map { $0.price.decimalString } == ["1", "2", "3"])
    }

    @Test func largeExactFinancialValuesRetainTheirDecimalDigits() throws {
        let result = try AIValuationScenarioCalculation.calculate(
            input: input(revenue: "9007199254740993.125"), proposal: proposal())
        #expect(result.rows.map { $0.price.decimalString } == [
            "90071992547409.93125", "180143985094819.8625", "270215977642229.79375"
        ])
    }

    @Test func missingNonpositiveAndFractionalShareInputsCannotProducePrices() throws {
        for revenue in [nil, "0", "-1"] as [String?] {
            let value = try input(revenue: revenue)
            #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
                try AIValuationScenarioCalculation.calculate(input: value, proposal: proposal())
            }
        }
        for shares in ["0", "-1", "1.5"] {
            let value = try input(shares: shares)
            #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
                try AIValuationScenarioCalculation.calculate(input: value, proposal: proposal())
            }
        }
        let complete = try input()
        for id in ["base.revenue", "reference.shares", "reference.price"] {
            let missing = replacingMetrics(complete, complete.metrics.filter { $0.id != id })
            #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
                try AIValuationScenarioCalculation.calculate(input: missing, proposal: proposal())
            }
        }
    }

    @Test func duplicateWrongUnitAndWrongSourceCannotSubstituteTheTTMRevenue() throws {
        let original = try input()
        let revenue = try #require(original.metrics.first { $0.id == "base.revenue" })
        let duplicate = replacingMetrics(original, original.metrics + [revenue])
        #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
            try AIValuationScenarioCalculation.calculate(input: duplicate, proposal: proposal())
        }
        for changed in [
            AIInsightMetric(id: revenue.id, label: revenue.label, value: revenue.value, unit: "ratio",
                            unavailable: nil, sourceIDs: revenue.sourceIDs),
            AIInsightMetric(id: revenue.id, label: revenue.label, value: revenue.value, unit: revenue.unit,
                            unavailable: nil, sourceIDs: ["local.userReference"])
        ] {
            let value = replacingMetrics(original, original.metrics.map { $0.id == revenue.id ? changed : $0 })
            #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
                try AIValuationScenarioCalculation.calculate(input: value, proposal: proposal())
            }
        }
    }

    @Test func unorderedNonpositiveOrUncitedAssumptionsDoNotCalculate() throws {
        let source = try input()
        for invalid in [proposal("2", "1", "3"), proposal("1", "1", "2"),
                        proposal("0", "1", "2"), proposal("-1", "1", "2")] {
            #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
                try AIValuationScenarioCalculation.calculate(input: source, proposal: invalid)
            }
        }
        let invalid = AIPriceSalesScenarioAssumption(multiple: "1",
            rationale: .init(text: "未绑定当次输入的假设。", evidenceIDs: ["invented.source"]))
        let uncited = AIPriceSalesScenarioProposal(conservative: invalid,
            base: proposal().base, optimistic: proposal().optimistic)
        #expect(throws: AIValuationScenarioCalculationError.invalidInput) {
            try AIValuationScenarioCalculation.calculate(input: source, proposal: uncited)
        }
    }

    @Test func overflowAndSubprecisionNeverPublishZeroOrPartialPrices() throws {
        let huge = "1" + String(repeating: "0", count: 127)
        let overflow = try input(revenue: huge)
        let oversized = proposal(huge, "2" + String(repeating: "0", count: 127),
                                 "3" + String(repeating: "0", count: 127))
        #expect(throws: AIValuationScenarioCalculationError.unrepresentablePrice) {
            try AIValuationScenarioCalculation.calculate(input: overflow, proposal: oversized)
        }
        let tiny = try input(revenue: "1", shares: "100000000000000000000", price: "1")
        #expect(throws: AIValuationScenarioCalculationError.unrepresentablePrice) {
            try AIValuationScenarioCalculation.calculate(input: tiny, proposal: proposal())
        }
    }

    @Test func resultRetainsTheExactInputDigestProposalAndDates() throws {
        let source = try input(), assumptions = proposal()
        let result = try AIValuationScenarioCalculation.calculate(input: source, proposal: assumptions)
        #expect(result.inputDigest == (try source.digest()))
        #expect(result.proposal == assumptions)
        #expect(result.ttmRevenue.decimalString == "1200")
        #expect(result.shares.decimalString == "100")
        #expect(result.periodEnd == "2026-09-30")
        #expect(result.referenceAt == "2026-10-25T03:53:57.000400Z")
        #expect(result.sharesAsOf == "2026-10-15")
        let roundTrip = try JSONDecoder().decode(AIInsightInput.self, from: source.encoded())
        let replay = try AIValuationScenarioCalculation.calculate(input: roundTrip, proposal: assumptions)
        #expect(replay == result)
        let changed = try AIValuationScenarioCalculation.calculate(input: source, proposal: proposal("1", "2", "4"))
        #expect(changed.inputDigest == result.inputDigest)
        #expect(changed.proposal != result.proposal)
        #expect(changed.rows.map { $0.price.decimalString } == ["12", "24", "48"])
    }
}
