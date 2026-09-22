import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

private let growthExecution = Date(timeIntervalSince1970: 1_800_000_000)
private func growthDay(_ text: String) throws -> MarketDate { try .init(iso8601: text) }
private func growthNear(_ actual: Money?, _ expected: String) throws {
    let value = try #require(actual)
    #expect(try value.subtracting(Money(expected)).amount.magnitude <= Decimal(string: "0.000000000001")!)
}

private struct GrowthFixture {
    var quarters: [FiscalQuarter] = []
    var facts: [NormalizedFinancialFact] = []
    var split: String? = "synthetic-known-no-split"
    let asOf = Date(timeIntervalSince1970: 1_735_862_400)
    init(lengths: [Int] = Array(repeating: 91, count: 8)) throws {
        var start = try growthDay("2022-01-01")
        for length in lengths {
            let end = try start.addingDays(length - 1)
            quarters.append(try .init(start: start, end: end)); start = try end.addingDays(1)
        }
        let revenue = ["60", "65", "70", "80", "90", "95", "100", "120"]
        let operating = ["6", "6.5", "7", "8", "9", "9.5", "10", "12"]
        let eps = ["0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.8", "1.2"]
        let net = ["3", "4", "5", "-10", "6", "7", "8", "5"]
        for index in quarters.indices {
            for (field, value) in [(FundamentalField.revenue, revenue[index]), (.operatingIncome, operating[index]),
                                    (.netIncome, net[index]), (.dilutedEPS, eps[index]),
                                    (.ocf, ["18", "19.5", "21", "24", "27", "28.5", "30", "36"][index]),
                                    (.capex, operating[index])] {
                facts.append(try fact(field.rawValue, value, at: index, nature: field == .dilutedEPS ? .perShare : .additiveFlow,
                    unit: field == .dilutedEPS ? "USD/shares" : "USD"))
            }
            facts.append(try fact(FundamentalGrowthCalculator.dilutedShareFieldID, index == 7 ? "8" : "10", at: index,
                nature: .nonadditive, unit: "shares"))
        }
    }
    func fact(_ field: String, _ value: String, at index: Int, nature: FinancialMetricNature = .additiveFlow,
              unit: String = "USD", derivation: FinancialDerivation = .reported,
              type: FinancialPeriodType = .quarter, start: MarketDate? = nil) throws -> NormalizedFinancialFact {
        let period = quarters[index], id = field + "/" + period.end.iso8601
        return .init(id: id, cik: "GROWTH-SYNTHETIC", fieldID: field, statement: .other, nature: nature,
            periodType: type, periodStart: start ?? period.start, periodEnd: period.end, fiscalYear: nil, fiscalPeriod: nil,
            unit: unit, value: try Money(value), sourceValue: value, derivation: derivation, sourceFactIDs: [id],
            sourceVersions: [id + "/v1"], accessionNumbers: ["synthetic"], dictionaryVersion: "growth-fixture.v1",
            availableAt: asOf, confidence: .high, limitations: [])
    }
    mutating func replace(_ field: String, _ value: String, at index: Int, nature: FinancialMetricNature = .additiveFlow,
                          unit: String = "USD", derivation: FinancialDerivation = .reported,
                          type: FinancialPeriodType = .quarter, start: MarketDate? = nil) throws {
        facts.removeAll { $0.fieldID == field && $0.periodEnd == quarters[index].end }
        facts.append(try fact(field, value, at: index, nature: nature, unit: unit, derivation: derivation, type: type, start: start))
    }
    func input() throws -> FundamentalInput {
        try .init(cik: "GROWTH-SYNTHETIC", normalization: .init(asOf: asOf, dictionaryVersion: "growth-fixture.v1",
            values: facts, issues: [], selectedSourceFacts: [], unmappedSourceFacts: []), quarters: quarters,
            priceDay: growthDay("2025-01-03"), splitBasisEvidence: split)
    }
}

private func growthReport(_ fixture: GrowthFixture) async throws -> FundamentalGrowthReport {
    let resolved = try await FundamentalGrowthModelV1.resolve(in: ModelRegistry(), at: growthExecution)
    return try FundamentalGrowthCalculator.calculate(fixture.input(), model: resolved, executionDate: growthExecution)
}

@Suite struct FundamentalGrowthTests {
    @Test func quarterPositionsDoNotBecomeTTMGrowth() async throws {
        let result = try await growthReport(GrowthFixture())
        for (key, expected) in [("revenueQuarter", "120"), ("revenueQuarterYoY", "0.5"), ("revenueQuarterQoQ", "0.2"),
            ("revenueQuarterYoYChange", "40"), ("operatingIncomeQuarterYoY", "0.5"), ("operatingIncomeQuarterQoQ", "0.2"),
            ("operatingIncomeTTMYoY", "0.472727272727272727"), ("operatingIncomeTTMYoYChange", "13"),
            ("epsQuarterYoY", "2"), ("epsQuarterQoQ", "0.5"), ("fcfQuarter", "24"),
            ("fcfQuarterYoY", "0.5"), ("fcfQuarterQoQ", "0.2"), ("netIncomeQuarterQoQ", "-0.375")] {
            try growthNear(result.metrics[key]?.value, expected)
        }
    }

    @Test func perShareUsesIndependentReportedWeightedShares() async throws {
        var fixture = try GrowthFixture()
        try fixture.replace(FundamentalField.revenue.rawValue, "100", at: 3)
        try fixture.replace(FundamentalField.ocf.rawValue, "28", at: 3)
        let result = try await growthReport(fixture)
        for (key, expected) in [("revenuePerShareQuarter", "15"), ("fcfPerShareQuarter", "3"),
            ("revenuePerShareQuarterYoY", "0.5"), ("fcfPerShareQuarterYoY", "0.5"),
            ("revenuePerShareQuarterQoQ", "0.5"), ("fcfPerShareQuarterQoQ", "0.5"),
            ("revenueQuarterYoY", "0.2"), ("fcfQuarterYoY", "0.2")] {
            try growthNear(result.metrics[key]?.value, expected)
        }
        #expect(result.metrics["revenuePerShareTTM"] == nil && result.metrics["fcfPerShareTTM"] == nil)
    }

    @Test func lossAndZeroBasesKeepChangesWithoutPercentages() async throws {
        var fixture = try GrowthFixture()
        let loss = try await growthReport(fixture)
        #expect(loss.metrics["netIncomeQuarterYoY"]?.unavailable == .nonpositiveDenominator)
        #expect(loss.metrics["netIncomeQuarterYoY"]?.flags == ["LOSS_TO_PROFIT"])
        try growthNear(loss.metrics["netIncomeQuarterYoYChange"]?.value, "15")
        try fixture.replace(FundamentalField.netIncome.rawValue, "0", at: 3)
        let zero = try await growthReport(fixture)
        #expect(zero.metrics["netIncomeQuarterYoY"]?.unavailable == .nonpositiveDenominator)
        #expect(zero.metrics["netIncomeQuarterYoY"]?.flags == ["ZERO_TO_POSITIVE"])
        try growthNear(zero.metrics["netIncomeQuarterYoYChange"]?.value, "5")
    }

    @Test func actualSharesAndAnnualWeightedSharesNeverFillQuarterlyDenominator() async throws {
        var fixture = try GrowthFixture()
        fixture.facts.removeAll { $0.fieldID == FundamentalGrowthCalculator.dilutedShareFieldID }
        let last = fixture.quarters[7]
        fixture.facts.append(.init(id: "actual", cik: "GROWTH-SYNTHETIC", fieldID: FundamentalField.actualShares.rawValue,
            statement: .shareCount, nature: .instant, periodType: .instant, periodStart: nil, periodEnd: last.end,
            fiscalYear: nil, fiscalPeriod: nil, unit: "shares", value: try Money("8"), sourceValue: "8", derivation: .reported,
            sourceFactIDs: ["actual"], sourceVersions: ["actual-v1"], accessionNumbers: ["synthetic"], dictionaryVersion: "growth-fixture.v1",
            availableAt: fixture.asOf, confidence: .high, limitations: []))
        fixture.facts.append(try fixture.fact(FundamentalGrowthCalculator.dilutedShareFieldID, "8", at: 7,
            nature: .nonadditive, unit: "shares", type: .annual, start: fixture.quarters[4].start))
        let result = try await growthReport(fixture)
        #expect(result.metrics["revenuePerShareQuarter"]?.value == nil)
        #expect(result.metrics["fcfPerShareQuarter"]?.value == nil)
        try growthNear(result.metrics["revenueQuarter"]?.value, "120")
    }

    @Test func nonadditiveShareEvidenceAndDirectEPSAreRequired() async throws {
        for variant in 0..<4 {
            var fixture = try GrowthFixture()
            try fixture.replace(FundamentalGrowthCalculator.dilutedShareFieldID, "8", at: 7,
                nature: variant == 0 ? .additiveFlow : .nonadditive,
                unit: variant == 1 ? "USD" : "shares", derivation: variant == 2 ? .ytdDifference : .reported,
                start: variant == 3 ? fixture.quarters[6].start : nil)
            #expect(try await growthReport(fixture).metrics["revenuePerShareQuarter"]?.value == nil)
        }
        var fixture = try GrowthFixture()
        try fixture.replace(FundamentalField.dilutedEPS.rawValue, "1.2", at: 7,
            nature: .perShare, unit: "USD/shares", derivation: .annualLessYTD)
        #expect(try await growthReport(fixture).metrics["epsQuarterYoY"]?.unavailable == .missingEvidence)
    }

    @Test func missingOrBlankSplitEvidenceBlocksPerShareButNotCorporateGrowth() async throws {
        for evidence: String? in [nil, "", " \n"] {
            var fixture = try GrowthFixture(); fixture.split = evidence
            let result = try await growthReport(fixture)
            #expect(result.metrics["epsQuarter"]?.unavailable == .missingEvidence)
            #expect(result.metrics["revenuePerShareQuarter"]?.unavailable == .missingEvidence)
            try growthNear(result.metrics["revenueQuarterYoY"]?.value, "0.5")
        }
    }

    @Test func nonpositiveWeightedSharesAreNotAUsableDenominator() async throws {
        for shares in ["0", "-1"] {
            var fixture = try GrowthFixture()
            try fixture.replace(FundamentalGrowthCalculator.dilutedShareFieldID, shares, at: 7, nature: .nonadditive, unit: "shares")
            #expect(try await growthReport(fixture).metrics["fcfPerShareQuarter"]?.unavailable == .nonpositiveDenominator)
        }
    }

    @Test func negativeQuarterExpendituresCannotHideInsideAPositiveTTM() async throws {
        let model = try await FundamentalGrowthModelV1.resolve(in: ModelRegistry(), at: growthExecution)
        for field in [FundamentalField.capex, .sbc, .buybacks, .issuance, .dividends] {
            var fixture = try GrowthFixture()
            try fixture.replace(field.rawValue, "-1", at: 6)
            let input = try fixture.input()
            #expect(throws: FundamentalError.incompatibleInput) {
                try FundamentalGrowthCalculator.calculate(input, model: model, executionDate: growthExecution)
            }
        }
    }

    @Test func missingQuarterDoesNotBorrowYTDOrAnnualize() async throws {
        var fixture = try GrowthFixture()
        fixture.facts.removeAll { $0.fieldID == FundamentalField.capex.rawValue && $0.periodEnd == fixture.quarters[7].end }
        let result = try await growthReport(fixture)
        #expect(result.metrics["fcfQuarterYoY"]?.value == nil && result.metrics["fcfPerShareQuarter"]?.value == nil)
        try growthNear(result.metrics["operatingIncomeTTMYoY"]?.value, "0.472727272727272727")
        fixture = try GrowthFixture(); fixture.quarters = Array(fixture.quarters.suffix(4))
        let short = try await growthReport(fixture)
        #expect(short.metrics["revenueQuarterYoY"]?.unavailable == .insufficientHistory)
        #expect(short.metrics["operatingIncomeTTMYoY"]?.unavailable == .insufficientHistory)
        try growthNear(short.metrics["revenueQuarterQoQ"]?.value, "0.2")
    }

    @Test func annualSpanDifferenceUsesTheApprovedSevenDayBoundary() async throws {
        let week = try await growthReport(GrowthFixture(lengths: [91,91,91,91,91,91,91,98]))
        try growthNear(week.metrics["operatingIncomeTTMYoY"]?.value, "0.472727272727272727")
        let longer = try await growthReport(GrowthFixture(lengths: [91,91,91,91,91,91,91,99]))
        #expect(longer.metrics["operatingIncomeTTMYoY"]?.unavailable == .notComparable)
        #expect(longer.metrics["operatingIncomeTTMYoYChange"]?.value == nil)
    }

    @Test func savedInputsRecomputeWithoutTrustingCachedMetrics() async throws {
        let model = try await FundamentalGrowthModelV1.resolve(in: ModelRegistry(), at: growthExecution)
        let report = try await growthReport(GrowthFixture())
        let encoded = try JSONEncoder().encode(report)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["metrics"] = [:]
        let decoded = try JSONDecoder().decode(FundamentalGrowthReport.self, from: JSONSerialization.data(withJSONObject: object))
        let replayed = try decoded.recompute(using: model)
        #expect(replayed.metrics == report.metrics && replayed.researchOnly)
        #expect(replayed.model == report.model && replayed.parameters == report.parameters)
        #expect(replayed.inputSnapshot.input.normalization.values == report.inputSnapshot.input.normalization.values)
        object.removeValue(forKey: "inputSnapshot")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FundamentalGrowthReport.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func newModelReusesApprovedParametersAndCannotReplaceLegacyCalculator() async throws {
        let registry = ModelRegistry()
        let legacy = try await FundamentalModelV1.resolve(in: registry, at: growthExecution)
        let fixture = try GrowthFixture(), input = try fixture.input()
        let before = try FundamentalCalculator.calculate(input, model: legacy, executionDate: growthExecution)
        let model = try await FundamentalGrowthModelV1.resolve(in: registry, at: growthExecution)
        let again = try await FundamentalGrowthModelV1.resolve(in: registry, at: growthExecution)
        _ = try FundamentalGrowthCalculator.calculate(input, model: model, executionDate: growthExecution)
        let after = try before.recompute(using: legacy)
        #expect(model.parameters.reference == legacy.parameters.reference)
        #expect(model.definition.reference == again.definition.reference)
        #expect(model.definition.reference != legacy.definition.reference)
        #expect(legacy.definition.version == "fundamentals.v1")
        #expect(after.metrics == before.metrics && after.model == before.model && after.parameters == before.parameters)
        #expect(before.metrics["revenueQuarterYoY"] == nil)
        try growthNear(after.metrics["revenueYoY"]?.value, "0.472727272727272727")
        #expect(throws: FundamentalError.unsupportedModel) {
            try FundamentalGrowthCalculator.calculate(input, model: legacy, executionDate: growthExecution)
        }
        #expect(throws: FundamentalError.unsupportedModel) {
            try FundamentalCalculator.calculate(input, model: model, executionDate: growthExecution)
        }
        let growth = try await growthReport(fixture)
        #expect(throws: RegistryError.referenceMismatch) { try growth.recompute(using: legacy) }
    }
}
