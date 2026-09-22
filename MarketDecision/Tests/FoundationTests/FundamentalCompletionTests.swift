import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

private let completionExecution = Date(timeIntervalSince1970: 1_800_000_000)
private func completionDay(_ text: String) throws -> MarketDate { try .init(iso8601: text) }
private func completionNear(_ actual: Money?, _ expected: String) throws {
    #expect(try #require(actual).subtracting(Money(expected)).amount.magnitude <= Decimal(string: "0.000000000001")!)
}

private struct CompletionFixture {
    var facts: [NormalizedFinancialFact] = []
    var quarters: [FiscalQuarter] = []
    var years: [FiscalYearWindow] = []
    var split: String? = "synthetic-known-no-split"
    let asOf = Date(timeIntervalSince1970: 1_735_862_400)
    init() throws {
        for year in 2022...2023 {
            for (start, end) in [("01-01", "03-31"), ("04-01", "06-30"), ("07-01", "09-30"), ("10-01", "12-31")] {
                quarters.append(try .init(start: completionDay("\(year)-" + start), end: completionDay("\(year)-" + end)))
            }
        }
        for (index, q) in quarters.enumerated() {
            for (field, amount) in [(FundamentalField.revenue.rawValue, "100"), (FundamentalField.netIncome.rawValue, "4"),
                (FundamentalField.ocf.rawValue, index < 4 ? "20" : "30"), (FundamentalField.capex.rawValue, "5"),
                (FundamentalField.sbc.rawValue, index < 4 ? "2" : "3"), (FundamentalField.dividends.rawValue, "2"),
                (FundamentalField.buybacks.rawValue, "4"), (FundamentalField.issuance.rawValue, "10"),
                (FundamentalCompletionCalculator.acquisitionFieldID, "7")] {
                facts.append(try fact(field, amount, start: q.start, end: q.end))
            }
            facts.append(try fact(FundamentalGrowthCalculator.dilutedShareFieldID, index == 7 ? "8" : "10",
                start: q.start, end: q.end, nature: .nonadditive, unit: "shares"))
        }
        for (index, year) in (2018...2023).enumerated() {
            let period = try FiscalYearWindow(start: completionDay("\(year)-01-01"), end: completionDay("\(year)-12-31"))
            years.append(period)
            facts.append(try fact(FundamentalField.revenue.rawValue, ["100", "110", "121", "133.1", "146.41", "161.051"][index],
                start: period.start, end: period.end, type: .annual))
        }
        facts.append(try fact(FundamentalField.cash.rawValue, "50", start: nil, end: quarters.last!.end, type: .instant, nature: .instant))
    }
    func fact(_ field: String, _ amount: String, start: MarketDate?, end: MarketDate,
              type: FinancialPeriodType = .quarter, nature: FinancialMetricNature = .additiveFlow,
              unit: String = "USD", derivation: FinancialDerivation = .reported) throws -> NormalizedFinancialFact {
        let id = [field, type.rawValue, start?.iso8601 ?? "", end.iso8601].joined(separator: "/")
        return .init(id: id, cik: "COMPLETION-SYNTHETIC", fieldID: field, statement: .other, nature: nature,
            periodType: type, periodStart: start, periodEnd: end, fiscalYear: nil, fiscalPeriod: nil, unit: unit,
            value: try Money(amount), sourceValue: amount, derivation: derivation, sourceFactIDs: [id],
            sourceVersions: [id + "/v1"], accessionNumbers: ["synthetic"], dictionaryVersion: "completion-fixture.v1",
            availableAt: asOf, confidence: .high, limitations: [])
    }
    mutating func annual(_ index: Int, _ amount: String, nature: FinancialMetricNature = .additiveFlow,
                         derivation: FinancialDerivation = .reported) throws {
        let y = years[index]
        facts.removeAll { $0.fieldID == FundamentalField.revenue.rawValue && $0.periodType == .annual && $0.periodEnd == y.end }
        facts.append(try fact(FundamentalField.revenue.rawValue, amount, start: y.start, end: y.end,
            type: .annual, nature: nature, derivation: derivation))
    }
    mutating func quarter(_ field: String, _ index: Int, _ amount: String, nature: FinancialMetricNature = .additiveFlow,
                          unit: String = "USD", derivation: FinancialDerivation = .reported) throws {
        let q = quarters[index]
        facts.removeAll { $0.fieldID == field && $0.periodType == .quarter && $0.periodEnd == q.end }
        facts.append(try fact(field, amount, start: q.start, end: q.end, nature: nature, unit: unit, derivation: derivation))
    }
    func input() throws -> FundamentalCompletionInput {
        let financials = try FundamentalInput(cik: "COMPLETION-SYNTHETIC", normalization: .init(asOf: asOf,
            dictionaryVersion: "completion-fixture.v1", values: facts, issues: [], selectedSourceFacts: [], unmappedSourceFacts: []),
            quarters: quarters, priceDay: completionDay("2025-01-03"), splitBasisEvidence: split)
        return try .init(financials: financials, revenueYears: years)
    }
}

private func completionReport(_ fixture: CompletionFixture) async throws -> FundamentalCompletionReport {
    let model = try await FundamentalCompletionModelV1.resolve(in: ModelRegistry(), at: completionExecution)
    return try FundamentalCompletionCalculator.calculate(fixture.input(), model: model, executionDate: completionExecution)
}

@Suite struct FundamentalCompletionTests {
    @Test func fiscalAnnualCAGRUsesFourAndSixReportedYears() async throws {
        let result = try await completionReport(CompletionFixture())
        try completionNear(result.metrics["revenueCAGR3Y"]?.value, "0.1")
        try completionNear(result.metrics["revenueCAGR5Y"]?.value, "0.1")
        try completionNear(result.metrics["revenueCAGR3YChange"]?.value, "40.051")
        try completionNear(result.metrics["revenueCAGR5YChange"]?.value, "61.051")
        #expect(result.inputSnapshot.revenueYears.count == 6 && result.researchOnly)
    }

    @Test func exactRootHasIndependentHighPrecisionExpectations() throws {
        // Expected irrational values were independently evaluated at 100 decimal digits.
        for (current, prior, n, expected) in [
            ("2", "1", 3, "0.259921049894873165"), ("2", "1", 5, "0.148698354997035007"),
            ("51.2", "100", 3, "-0.2"), ("32.768", "100", 5, "-0.2"),
            ("0", "100", 5, "-1"), ("100", "100", 3, "0"),
            ("0.000000000000000001", "1000000000000000000", 3, "-0.999999999999"),
            ("1610510000000000000000000000000000000000000000000000000000000", "1", 5, "1099999999999"),
        ] {
            let actual = try FundamentalCompletionDecimal.compoundGrowth(current: Money(current), prior: Money(prior), years: n)
            #expect(actual.decimalString == expected)
        }
    }

    @Test func exactRootRoundsMidpointTiesToEvenWithoutBinaryFloatingPoint() throws {
        // These are exactly (1.5e-18)^3 and (2.5e-18)^3. Both round to 2e-18.
        for current in ["0.000000000000000000000000000000000000000000000000000003375",
                        "0.000000000000000000000000000000000000000000000000000015625"] {
            let actual = try FundamentalCompletionDecimal.compoundGrowth(current: Money(current), prior: Money("1"), years: 3)
            #expect(actual.decimalString == "-0.999999999999999998")
        }
    }

    @Test func missingMiddleAnnualFactIsNotReplacedByEndpointsOrQuarters() async throws {
        var fixture = try CompletionFixture()
        fixture.facts.removeAll { $0.periodType == .annual && $0.periodEnd == fixture.years[4].end }
        let result = try await completionReport(fixture)
        #expect(result.metrics["revenueCAGR3Y"]?.value == nil && result.metrics["revenueCAGR5Y"]?.value == nil)
        try completionNear(result.metrics["capexTTM"]?.value, "20")
        fixture = try CompletionFixture(); fixture.years = Array(fixture.years.suffix(4))
        let short = try await completionReport(fixture)
        try completionNear(short.metrics["revenueCAGR3Y"]?.value, "0.1")
        #expect(short.metrics["revenueCAGR5Y"]?.unavailable == .insufficientHistory)
    }

    @Test func annualNonadditiveOrManufacturedValuesDoNotBecomeCAGR() async throws {
        for derived in [false, true] {
            var fixture = try CompletionFixture()
            try fixture.annual(5, "161.051", nature: derived ? .additiveFlow : .nonadditive,
                derivation: derived ? .fourQuarterSum : .reported)
            #expect(try await completionReport(fixture).metrics["revenueCAGR3Y"]?.unavailable == .missingEvidence)
        }
    }

    @Test func nonpositiveAnnualBaseAndNegativeEndRemainExplicit() async throws {
        var fixture = try CompletionFixture(); try fixture.annual(0, "-10")
        let negativeBase = try await completionReport(fixture)
        #expect(negativeBase.metrics["revenueCAGR5Y"]?.unavailable == .nonpositiveDenominator)
        #expect(negativeBase.metrics["revenueCAGR5Y"]?.flags == ["LOSS_TO_PROFIT"])
        try completionNear(negativeBase.metrics["revenueCAGR5YChange"]?.value, "171.051")
        try fixture.annual(0, "0")
        #expect(try await completionReport(fixture).metrics["revenueCAGR5Y"]?.flags == ["ZERO_TO_POSITIVE"])
        fixture = try CompletionFixture(); try fixture.annual(5, "-1")
        let negativeEnd = try await completionReport(fixture)
        #expect(negativeEnd.metrics["revenueCAGR3Y"]?.unavailable == .notComparable)
        #expect(negativeEnd.metrics["revenueCAGR3Y"]?.flags == ["NEGATIVE_CAGR_ENDPOINT"])
        fixture = try CompletionFixture(); try fixture.annual(5, "0")
        try completionNear(try await completionReport(fixture).metrics["revenueCAGR5Y"]?.value, "-1")
    }

    @Test func annualWindowsRejectGapsAndPreserveSevenDayComparabilityBoundary() async throws {
        var fixture = try CompletionFixture(); fixture.years.remove(at: 1)
        #expect(throws: FundamentalError.invalidWindow) { try fixture.input() }
        for extra in [7, 8] {
            fixture = try CompletionFixture()
            fixture.facts.removeAll { $0.periodType == .annual }
            fixture.years = []
            var start = try completionDay("2017-12-20")
            for index in 0..<6 {
                let end = try start.addingDays(363 + (index == 2 ? extra : 0))
                fixture.years.append(try .init(start: start, end: end))
                fixture.facts.append(try fixture.fact(FundamentalField.revenue.rawValue, "100", start: start, end: end, type: .annual))
                start = try end.addingDays(1)
            }
            let result = try await completionReport(fixture)
            if extra == 7 { try completionNear(result.metrics["revenueCAGR5Y"]?.value, "0") }
            else { #expect(result.metrics["revenueCAGR5Y"]?.unavailable == .notComparable) }
        }
    }

    @Test func capitalAmountsRetainPositiveExpensesAndSeparateCashDirection() async throws {
        let result = try await completionReport(CompletionFixture())
        for (key, expected) in [("cash", "50"), ("dividendsTTM", "8"), ("dividendsCashFlowTTM", "-8"),
            ("buybacksTTM", "16"), ("buybacksCashFlowTTM", "-16"), ("issuanceTTM", "40"), ("issuanceCashFlowTTM", "40"),
            ("acquisitionsQuarter", "7"), ("acquisitionsTTM", "28"), ("acquisitionsCashFlowTTM", "-28"),
            ("capexTTM", "20"), ("capexCashFlowTTM", "-20"), ("sbcTTM", "12"),
            ("netBuybacksTTM", "-24"), ("netBuybacksCashFlowTTM", "24"), ("shareholderCashReturnedTTM", "-16")] {
            try completionNear(result.metrics[key]?.value, expected)
        }
        #expect(result.metrics["sbcCashFlowTTM"] == nil)
    }

    @Test func missingAcquisitionAndIssuanceAreNeverZeroOrProxyFilled() async throws {
        var fixture = try CompletionFixture()
        fixture.facts.removeAll { [FundamentalCompletionCalculator.acquisitionFieldID, FundamentalField.issuance.rawValue].contains($0.fieldID) }
        for q in fixture.quarters {
            fixture.facts.append(try fixture.fact("cash-flow.acquisitions-net-of-cash-acquired", "7", start: q.start, end: q.end))
        }
        let result = try await completionReport(fixture)
        #expect(result.metrics["acquisitionsTTM"]?.value == nil && result.metrics["netBuybacksTTM"]?.value == nil)
        #expect(result.metrics["shareholderCashReturnedTTM"]?.value == nil)
        try completionNear(result.metrics["buybacksTTM"]?.value, "16")
        try completionNear(result.metrics["sbcTTM"]?.value, "12")
    }

    @Test func negativeQuarterExpenseAndWrongAcquisitionNatureAreRejected() async throws {
        let model = try await FundamentalCompletionModelV1.resolve(in: ModelRegistry(), at: completionExecution)
        for field in [FundamentalField.capex.rawValue, FundamentalField.sbc.rawValue, FundamentalField.buybacks.rawValue,
                      FundamentalField.issuance.rawValue, FundamentalField.dividends.rawValue, FundamentalCompletionCalculator.acquisitionFieldID] {
            var fixture = try CompletionFixture(); try fixture.quarter(field, 6, "-1")
            let input = try fixture.input()
            #expect(throws: FundamentalError.incompatibleInput) {
                try FundamentalCompletionCalculator.calculate(input, model: model, executionDate: completionExecution)
            }
        }
        var fixture = try CompletionFixture()
        try fixture.quarter(FundamentalCompletionCalculator.acquisitionFieldID, 7, "7", nature: .nonadditive)
        #expect(throws: FundamentalError.incompatibleInput) {
            try FundamentalCompletionCalculator.calculate(fixture.input(), model: model, executionDate: completionExecution)
        }
    }

    @Test func exSBCPairsQuarterlyGrowthAndWeightedPerShareWithoutDoubleSubtraction() async throws {
        let result = try await completionReport(CompletionFixture())
        for (key, expected) in [("fcfExSBCQuarter", "22"), ("fcfExSBCTTM", "88"),
            ("fcfExSBCQuarterYoY", "0.692307692307692308"), ("fcfExSBCQuarterQoQ", "0"),
            ("fcfExSBCTTMYoY", "0.692307692307692308"), ("fcfExSBCTTMYoYChange", "36"),
            ("fcfExSBCPerShareQuarter", "2.75"), ("fcfExSBCPerShareQuarterYoY", "1.115384615384615385"),
            ("fcfExSBCPerShareQuarterQoQ", "0.25"), ("fcfExSBCConversion", "5.5")] {
            try completionNear(result.metrics[key]?.value, expected)
        }
        #expect(result.metrics["fcfExSBCPerShareTTM"] == nil)
    }

    @Test func exSBCNeedsSBCAndReportedSameQuarterSharesAndPreservesLosses() async throws {
        var fixture = try CompletionFixture()
        fixture.facts.removeAll { $0.fieldID == FundamentalField.sbc.rawValue && $0.periodEnd == fixture.quarters[7].end }
        #expect(try await completionReport(fixture).metrics["fcfExSBCTTM"]?.value == nil)
        fixture = try CompletionFixture()
        try fixture.quarter(FundamentalGrowthCalculator.dilutedShareFieldID, 7, "8", nature: .nonadditive, unit: "shares", derivation: .ytdDifference)
        #expect(try await completionReport(fixture).metrics["fcfExSBCPerShareQuarter"]?.unavailable == .missingEvidence)
        fixture = try CompletionFixture(); fixture.split = " "
        #expect(try await completionReport(fixture).metrics["fcfExSBCPerShareQuarter"]?.unavailable == .missingEvidence)
        fixture = try CompletionFixture()
        for i in 4..<8 { try fixture.quarter(FundamentalField.sbc.rawValue, i, "30") }
        let negative = try await completionReport(fixture)
        try completionNear(negative.metrics["fcfExSBCTTM"]?.value, "-20")
        try completionNear(negative.metrics["fcfExSBCPerShareQuarter"]?.value, "-0.625")
    }

    @Test func completeSnapshotReplaysAndRejectsMissingAnnualContext() async throws {
        let model = try await FundamentalCompletionModelV1.resolve(in: ModelRegistry(), at: completionExecution)
        let report = try await completionReport(CompletionFixture())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object["metrics"] = [:]
        let decoded = try JSONDecoder().decode(FundamentalCompletionReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try decoded.recompute(using: model).metrics == report.metrics)
        var snapshot = try #require(object["inputSnapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "revenueYears"); object["inputSnapshot"] = snapshot
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FundamentalCompletionReport.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func priorModelsAndDictionaryRemainIndependentAndUnchanged() async throws {
        let registry = ModelRegistry(), fixture = try CompletionFixture()
        let old = try await FundamentalModelV1.resolve(in: registry, at: completionExecution)
        let growth = try await FundamentalGrowthModelV1.resolve(in: registry, at: completionExecution)
        let input = try fixture.input()
        let beforeOld = try FundamentalCalculator.calculate(input.financials, model: old, executionDate: completionExecution)
        let beforeGrowth = try FundamentalGrowthCalculator.calculate(input.financials, model: growth, executionDate: completionExecution)
        let model = try await FundamentalCompletionModelV1.resolve(in: registry, at: completionExecution)
        let result = try FundamentalCompletionCalculator.calculate(input, model: model, executionDate: completionExecution)
        #expect(result.parameters == old.parameters.reference && result.parameters == growth.parameters.reference)
        #expect(result.model != beforeOld.model && result.model != beforeGrowth.model)
        #expect(try beforeOld.recompute(using: old).metrics == beforeOld.metrics)
        #expect(try beforeGrowth.recompute(using: growth).metrics == beforeGrowth.metrics)
        #expect(beforeOld.metrics["revenueCAGR3Y"] == nil && beforeGrowth.metrics["fcfExSBCTTM"] == nil)
        #expect(try FinancialFieldDictionary.fundamentalsV1().rules.count == 22)
        #expect(throws: RegistryError.referenceMismatch) { try result.recompute(using: old) }
        #expect(throws: FundamentalError.unsupportedModel) {
            try FundamentalCompletionCalculator.calculate(input, model: growth, executionDate: completionExecution)
        }
    }

    @Test func publicAPIPreservesTinyCAGRAndRefusesUnrepresentableDecimalChanges() async throws {
        var fixture = try CompletionFixture()
        try fixture.annual(0, "1000000000000000000")
        try fixture.annual(5, "0.000000000000000001")
        let report = try await completionReport(fixture)
        // (1e-36)^(1/5)-1, independently computed at 100 digits and half-even at 18.
        #expect(report.metrics["revenueCAGR5Y"]?.value?.decimalString == "-0.999999936904265552")
        fixture = try CompletionFixture()
        try fixture.annual(0, "0.0000000000000000001")
        try fixture.annual(5, "100000000000000000000")
        let input = try fixture.input()
        let model = try await FundamentalCompletionModelV1.resolve(in: ModelRegistry(), at: completionExecution)
        // The separately reported endpoint change needs 39 significant digits.
        // It must fail under Decimal38, never switch to a rounded Double result.
        #expect(throws: MoneyError.precisionExceeded) {
            try FundamentalCompletionCalculator.calculate(input, model: model, executionDate: completionExecution)
        }
    }

    @Test func snapshotDecodingRejectsUnknownVersionAndInvalidYearOrder() async throws {
        let report = try await completionReport(CompletionFixture())
        let encoded = try JSONEncoder().encode(report)
        for unknownVersion in [true, false] {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var snapshot = try #require(object["inputSnapshot"] as? [String: Any])
            if unknownVersion { snapshot["formatVersion"] = "fundamental-completion-input.future" }
            else { snapshot["revenueYears"] = Array(try #require(snapshot["revenueYears"] as? [[String: Any]]).reversed()) }
            object["inputSnapshot"] = snapshot
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(FundamentalCompletionReport.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func acquisitionUnitAndFourQuarterSumCannotMasqueradeAsSingleQuarter() async throws {
        let model = try await FundamentalCompletionModelV1.resolve(in: ModelRegistry(), at: completionExecution)
        for badUnit in [true, false] {
            var fixture = try CompletionFixture()
            try fixture.quarter(FundamentalCompletionCalculator.acquisitionFieldID, 7, "7", unit: badUnit ? "EUR" : "USD",
                derivation: badUnit ? .reported : .fourQuarterSum)
            let input = try fixture.input()
            #expect(throws: FundamentalError.incompatibleInput) {
                try FundamentalCompletionCalculator.calculate(input, model: model, executionDate: completionExecution)
            }
        }
    }
}
