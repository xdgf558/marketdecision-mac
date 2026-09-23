import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

@Suite struct FundamentalCompletionMappingTests {
    private let helper = PhaseOneFinancialNormalizationTests()
    private let cutoff = Date(timeIntervalSince1970: 1_741_046_400)

    @Test func exactCashTaxAndDebtSlotsNormalizeInTheNewDictionaryOnly() throws {
        let concepts = ["IncomeTaxExpenseBenefit", "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
            "DepreciationDepletionAndAmortization", "PaymentsToAcquireBusinessesGross", "ShortTermBorrowings",
            "LongTermDebtCurrent", "LongTermDebtNoncurrent", "FinanceLeaseLiability", "OperatingLeaseLiability"]
        let fields = ["income.tax", "income.pretax-income", "cash-flow.depreciation", "cash-flow.acquisitions-cash-paid",
            "debt.short-borrowings", "debt.current-excluding-leases", "debt.noncurrent-excluding-leases",
            "debt.finance-lease-total", "debt.operating-lease-total"]
        let facts = try concepts.enumerated().map { index, concept in
            try helper.fact(id: "completion-\(index)", value: String((index + 1) * 10),
                start: index < 4 ? "2024-01-01" : nil, end: "2024-12-31", filed: "2025-02-01", fp: "FY", form: "10-K", concept: concept)
        }
        let old = try FinancialFieldDictionary.fundamentalsV1()
        let new = try FinancialFieldDictionary.fundamentalsCompletionV1()
        #expect(old.version != new.version)
        #expect(old.rules.count == 22 && new.rules.count == 31)
        #expect(try FinancialFieldDictionary.foundationV1().rules.count == 10)
        let previous = try FinancialNormalizer.normalize(facts, dictionary: old, asOf: cutoff)
        #expect(previous.values.isEmpty && previous.unmappedSourceFacts.count == 9)
        let result = try FinancialNormalizer.normalize(facts, dictionary: new, asOf: cutoff)
        #expect(result.values.count == 9 && result.unmappedSourceFacts.isEmpty)
        for (index, field) in fields.enumerated() {
            let row = try #require(result.values.first { $0.fieldID == field })
            #expect(row.value == (try Money(String((index + 1) * 10))))
            #expect(row.periodType == (index < 4 ? .annual : .instant))
            #expect(row.sourceFactIDs == [facts[index].factID])
            #expect(row.dictionaryVersion == new.version)
        }
    }

    @Test func mixedOrPartialConceptsCannotSilentlyFillCompleteSlots() throws {
        let concepts = ["LongTermDebtAndCapitalLeaseObligationsCurrent", "LongTermDebtAndCapitalLeaseObligations",
            "OperatingLeaseLiabilityCurrent", "OperatingLeaseLiabilityNoncurrent", "FinanceLeaseLiabilityCurrent",
            "FinanceLeaseLiabilityNoncurrent", "PaymentsToAcquireBusinessesNetOfCashAcquired",
            "ProceedsFromStockOptionsExercised", "ProceedsFromStockPlans", "PreferredStockValue", "MinorityInterest"]
        let facts = try concepts.enumerated().map { index, concept in
            try helper.fact(id: "partial-\(index)", value: "1", start: nil, end: "2024-12-31",
                filed: "2025-02-01", fp: "FY", concept: concept)
        }
        let result = try FinancialNormalizer.normalize(facts, dictionary: .fundamentalsCompletionV1(), asOf: cutoff)
        #expect(result.values.isEmpty)
        #expect(Set(result.unmappedSourceFacts.map(\.recordID)) == Set(facts.map(\.recordID)))
    }

    @Test func classDimensionAndUnavailableVersionStillRequireEvidence() throws {
        let segmented = try helper.fact(id: "class", value: "2", start: nil, end: "2024-12-31", filed: "2025-02-01",
            fp: "FY", concept: "LongTermDebtCurrent", dimensions: ["StatementClassOfStockAxis": "ClassAMember"])
        let future = try helper.fact(id: "future", value: "3", start: nil, end: "2024-12-31", filed: "2025-02-01",
            fp: "FY", concept: "OperatingLeaseLiability", availability: cutoff.addingTimeInterval(1))
        let result = try FinancialNormalizer.normalize([segmented, future], dictionary: .fundamentalsCompletionV1(), asOf: cutoff)
        #expect(result.values.isEmpty)
        #expect(result.unmappedSourceFacts == [segmented])
        #expect(result.issues.contains { $0.code == "future-or-unavailable" })
    }
}
