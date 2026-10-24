import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

/// Pending execution: focused regression sources for the evidence-v2 lease mapping.
/// Synthetic records contain explicit amounts, including explicit zeros; no live SEC access.
@Suite struct SECLeaseDebtMappingTests {
    private let day = try! MarketDate(iso8601: "2025-12-31")
    private let operating = "debt.operating-lease-total"

    private func fact(_ concept: String, _ value: String, id: String? = nil,
                      end: MarketDate? = nil, accession: String = "0000320193-25-000004",
                      rawHash: String = String(repeating: "a", count: 64),
                      available: Date? = nil) throws -> SECCompanyFactRecord {
        let end = end ?? day, key = id ?? concept
        let available = available ?? secFinancialFixtureCutoff.addingTimeInterval(-1)
        let source = Provenance(providerID: "sec-edgar", feedID: "public-edgar", sourceEventAt: nil,
            receivedAt: max(secFinancialFixtureCutoff, available), availableAt: nil,
            evidenceRef: "synthetic-lease-mapping", origin: .filing, endpointDescriptor: EndpointDescriptor.companyFacts.rawValue,
            requestedAt: secFinancialFixtureCutoff.addingTimeInterval(-2),
            requestID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!, observationDate: end,
            versionID: key + ".v1", versionKind: .sourceVersion,
            availability: .instant(available, evidence: "synthetic"), rawObjectRef: "synthetic/company-facts",
            rawHash: rawHash, normalizationVersion: "synthetic.v1", licenseRef: "synthetic")
        return try SECCompanyFactRecord(recordID: key, factID: key, cik: "0000320193", taxonomy: "us-gaap",
            concept: concept, label: concept, description: "Synthetic exact lease liability",
            unit: "USD", sourceValue: value, value: Money(value), startDate: nil, endDate: end,
            periodKind: .instant, accessionNumber: accession, form: "10-K", filedDate: day.addingDays(30),
            fiscalYear: 2025, fiscalPeriod: "FY", frame: nil, provenance: source)
    }

    private func normalized(_ facts: [SECCompanyFactRecord]) throws -> FinancialNormalizationResult {
        try SECLeaseDebtNormalizer.complete(FinancialNormalizer.normalize(facts,
            dictionary: .fundamentalsCompletionV2(), asOf: secFinancialFixtureCutoff), sourceFacts: facts)
    }

    @Test func dictionaryV2AddsExactLeaseComponentsAndSeparateCreditDisclosureWithoutChangingV1() throws {
        let old = try FinancialFieldDictionary.fundamentalsCompletionV1()
        let new = try FinancialFieldDictionary.fundamentalsCompletionV2()
        #expect(old.version == "financial-fields.us-gaap.completion.v1")
        #expect(new.version == "financial-fields.us-gaap.completion.v2")
        #expect(old.rules.count == 31 && new.rules.count == 36)
        #expect(new.rules.filter { !$0.fieldID.hasPrefix("lease-components.")
            && !$0.fieldID.hasPrefix("debt-disclosures.") } == old.rules)
        for concept in ["FinanceLeaseLiabilityCurrent", "FinanceLeaseLiabilityNoncurrent",
                        "OperatingLeaseLiabilityCurrent", "OperatingLeaseLiabilityNoncurrent"] {
            let value = try fact(concept, "1")
            #expect(old.rule(for: value) == nil)
            #expect(new.rule(for: value)?.nature == .instant)
        }
        #expect(new.rule(for: try fact("LiabilitiesCurrent", "1"))?.fieldID == "balance.current-liabilities")
        for concept in ["LongTermDebtAndFinanceLeaseObligationsCurrent", "OperatingLeaseLiabilityPaymentsDue",
                        "InvestmentContractLiabilities", "LineOfCreditFacilityMaximumBorrowingCapacity",
                        "AvailableForSaleSecuritiesDebtSecurities", "DebtSecuritiesAvailableForSaleAmortizedCostBasis"] {
            #expect(new.rule(for: try fact(concept, "1")) == nil)
        }
    }

    @Test func completePairUsesExactSumAndRetainsBothSourcesWithoutDuplicateDebtInputs() throws {
        let first = try fact("OperatingLeaseLiabilityCurrent", "13.1", available: secFinancialFixtureCutoff.addingTimeInterval(-2))
        let second = try fact("OperatingLeaseLiabilityNoncurrent", "26.2")
        let result = try normalized([first, second])
        let total = try #require(result.values.first { $0.fieldID == operating })
        #expect(total.value == (try Money("39.3")))
        #expect(total.sourceValue == nil && total.derivation == .leaseComponentsSum)
        #expect(total.availableAt == secFinancialFixtureCutoff.addingTimeInterval(-1))
        #expect(Set(total.sourceFactIDs) == Set([first.factID, second.factID]))
        #expect(Set(total.sourceVersions) == Set([first.provenance.versionID!, second.provenance.versionID!]))
        #expect(result.values.count == 1)
        #expect(result.selectedSourceFacts.count == 2)
    }

    @Test func missingNegativeFutureOtherPeriodOrDifferentSourceNeverProducesATotal() throws {
        let current = try fact("OperatingLeaseLiabilityCurrent", "13")
        let variants: [[SECCompanyFactRecord]] = [
            [current],
            [current, try fact("OperatingLeaseLiabilityNoncurrent", "-1")],
            [current, try fact("OperatingLeaseLiabilityNoncurrent", "27", available: secFinancialFixtureCutoff.addingTimeInterval(1))],
            [current, try fact("OperatingLeaseLiabilityNoncurrent", "27", end: day.addingDays(-1))],
            [current, try fact("OperatingLeaseLiabilityNoncurrent", "27", accession: "0000320193-25-000003")],
            [current, try fact("OperatingLeaseLiabilityNoncurrent", "27", rawHash: String(repeating: "b", count: 64))]
        ]
        for facts in variants {
            #expect(try normalized(facts).values.first { $0.fieldID == operating } == nil)
        }
    }

    @Test func explicitZeroComponentIsEvidenceButAbsenceIsNot() throws {
        let first = try fact("FinanceLeaseLiabilityCurrent", "0")
        let second = try fact("FinanceLeaseLiabilityNoncurrent", "0")
        #expect(try normalized([first]).values.isEmpty)
        let total = try #require(normalized([first, second]).values.first)
        #expect(total.fieldID == "debt.finance-lease-total" && total.value == (try Money("0")))
        #expect(total.sourceFactIDs.count == 2)
    }

    @Test func reportedTotalIsNotDoubleCountedAndCompleteSameFilingConflictIsRejected() throws {
        let first = try fact("OperatingLeaseLiabilityCurrent", "13")
        let second = try fact("OperatingLeaseLiabilityNoncurrent", "27")
        let matching = try normalized([first, second, fact("OperatingLeaseLiability", "40")])
        let total = try #require(matching.values.first { $0.fieldID == operating })
        #expect(total.value == (try Money("40")) && total.derivation == .reported)
        #expect(matching.values.count == 1)
        let conflicting = try normalized([first, second, fact("OperatingLeaseLiability", "41")])
        #expect(conflicting.values.first { $0.fieldID == operating } == nil)
        #expect(conflicting.issues.contains { $0.code == "lease-total-components-conflict" && $0.severity == .blocker })
        let partial = try normalized([first, fact("OperatingLeaseLiability", "41")])
        #expect(partial.values.first { $0.fieldID == operating }?.value == (try Money("41")))
        #expect(!partial.issues.contains { $0.code == "lease-total-components-conflict" })
    }

    @Test func blockedReportedTotalCannotBeRescuedByComponents() throws {
        let facts = try [fact("OperatingLeaseLiabilityCurrent", "13"), fact("OperatingLeaseLiabilityNoncurrent", "27"),
                         fact("OperatingLeaseLiability", "40", id: "total-a"),
                         fact("OperatingLeaseLiability", "41", id: "total-b")]
        let result = try normalized(facts)
        #expect(result.values.first { $0.fieldID == operating } == nil)
        #expect(result.issues.contains { $0.code == "mapping-conflict" })
        #expect(result.issues.contains { $0.code == "lease-total-rejected" })
    }

    @Test func legacyAndNewReportsReplayOwnEvidenceWithoutChangingModelReferences() async throws {
        var records = try secFinancialFixtureRecords()
        records.facts += try [fact("OperatingLeaseLiabilityCurrent", "13"), fact("OperatingLeaseLiabilityNoncurrent", "27")]
        let old = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts,
            submissions: records.submissions, cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff,
            evidencePolicy: SECFinancialReport.legacyPolicyVersion)
        let new = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts,
            submissions: records.submissions, cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
        #expect(old.models.map(\.reference) == new.models.map(\.reference))
        #expect(old.parameters.reference == new.parameters.reference)
        #expect(old.inputSnapshot.financials.input.normalization.values.first { $0.fieldID == operating } == nil)
        #expect(new.inputSnapshot.financials.input.normalization.values.first { $0.fieldID == operating }?.value == (try Money("40")))
        // Lease evidence does not invent the other four required debt components.
        #expect(new.baseReport.metrics["debt"]?.value == nil)
        for original in [old, new] {
            let encoded = try JSONEncoder().encode(original)
            let reopened = try JSONDecoder().decode(SECFinancialReport.self, from: encoded)
            #expect(reopened.evidencePolicy == original.evidencePolicy)
            #expect(try await reopened.cachedReportsMatch(reopened.recompute()))
            try reopened.validateEvidence(facts: records.facts, submissions: records.submissions, classification: nil)
        }
    }

    @Test func allFiveExplicitSlotsEnableExistingDebtFormulaAndReorderingIsStable() async throws {
        var records = try secFinancialFixtureRecords()
        records.facts += try [fact("ShortTermBorrowings", "1"), fact("LongTermDebtCurrent", "2"),
            fact("LongTermDebtNoncurrent", "3"), fact("FinanceLeaseLiabilityCurrent", "0"),
            fact("FinanceLeaseLiabilityNoncurrent", "0"), fact("OperatingLeaseLiabilityCurrent", "13"),
            fact("OperatingLeaseLiabilityNoncurrent", "27")]
        let report = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts,
            submissions: records.submissions, cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
        #expect(report.baseReport.metrics["debt"]?.value == (try Money("46")))
        let reversed = try await SECFinancialReport.make(cik: "0000320193", facts: Array(records.facts.reversed()),
            submissions: Array(records.submissions.reversed()), cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
        #expect(try SECFinancialReport.bytes(report) == SECFinancialReport.bytes(reversed))
    }

    @Test func drawnCreditDisclosureIsRetainedWithoutFillingDebtMaturityOrMissingSlots() async throws {
        var records = try secFinancialFixtureRecords()
        let disclosure = try fact("LineOfCredit", "206400000")
        records.facts += [disclosure,
            try fact("LineOfCreditFacilityMaximumBorrowingCapacity", "300000000"),
            try fact("AvailableForSaleSecuritiesDebtSecurities", "900000000")]
        #expect(try FinancialFieldDictionary.fundamentalsCompletionV1().rule(for: disclosure) == nil)
        let report = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts,
            submissions: records.submissions, cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
        let values = report.inputSnapshot.financials.input.normalization.values
        let retained = try #require(values.first { $0.fieldID == "debt-disclosures.line-of-credit-total" })
        #expect(retained.value == (try Money("206400000")) && retained.derivation == .reported)
        #expect(retained.sourceFactIDs == [disclosure.factID])
        #expect(!values.contains { $0.fieldID.hasPrefix("debt.") })
        #expect(report.baseReport.metrics["debt"]?.value == nil)
        #expect(report.baseReport.metrics["debt"]?.unavailable == .missingInput)
        #expect(!report.evidence.facts.contains { $0.concept == "LineOfCreditFacilityMaximumBorrowingCapacity"
            || $0.concept == "AvailableForSaleSecuritiesDebtSecurities" })
        let reopened = try JSONDecoder().decode(SECFinancialReport.self, from: JSONEncoder().encode(report))
        #expect(try await reopened.cachedReportsMatch(reopened.recompute()))
    }
}
