import Foundation
import Testing
import CoreDomain
@testable import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

/// Pending execution. Synthetic source bytes exercise the production SEC acceptance and
/// financial-report path; the LMND-like amounts are not real-company validation evidence.
@Suite struct SECFinancialDebtBreakdownTests {
    @Test func separateLeaseAndDrawnCreditDisclosuresLeaveExactlyFourMissingComponents() async throws {
        let parent = try await secFinancialReportFixtureParent(includeDebtDisclosure: true)
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        let report = document.financials
        #expect(try await report.cachedReportsMatch(report.recompute()))
        let breakdown = SECFinancialDebtBreakdown(report: report)
        #expect(breakdown.period == "2024-12-31" && !breakdown.usesLegacyEvidence)
        #expect(breakdown.components.count == 5 && breakdown.missingCount == 4)
        #expect(Set(breakdown.components.filter { $0.value == nil }.map(\.id)) == Set([
            "debt.short-borrowings", "debt.current-excluding-leases", "debt.noncurrent-excluding-leases", "debt.finance-lease-total"
        ]))
        let lease = try #require(breakdown.components.first { $0.id == "debt.operating-lease-total" })
        #expect(lease.value == (try Money("20000000")))
        #expect(lease.sourceConcepts == ["us-gaap:OperatingLeaseLiability"])
        #expect(breakdown.disclosures.count == 1)
        let credit = try #require(breakdown.disclosures.first)
        #expect(credit.id == "debt-disclosures.line-of-credit-total")
        #expect(credit.value == (try Money("206400000")))
        #expect(credit.sourceConcepts == ["us-gaap:LineOfCredit"])
        #expect(credit.explanation.contains("未拆分期限"))
        #expect(report.baseReport.metrics["debt"]?.value == nil)
        #expect(report.baseReport.metrics["debt"]?.unavailable == .missingInput)
    }

    @Test func absentDebtInputsRemainFiveMissingValuesRatherThanZeros() async throws {
        let parent = try await secFinancialReportFixtureParent()
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        let breakdown = SECFinancialDebtBreakdown(report: document.financials)
        #expect(breakdown.components.count == 5 && breakdown.missingCount == 5)
        #expect(breakdown.components.allSatisfy { $0.value == nil })
        #expect(breakdown.components.allSatisfy { $0.explanation.contains("不代表该项为零") })
        #expect(breakdown.disclosures.isEmpty)
        #expect(document.financials.baseReport.metrics["debt"]?.value == nil)
    }

    @Test func legacyReplayKeepsOldEvidenceAndDoesNotAcquireNewCreditDisclosure() async throws {
        let parent = try await secFinancialReportFixtureParent(sic: nil, includeDebtDisclosure: true)
        let expectedCredit = try Money("206400000")
        #expect(parent.facts.contains { $0.concept == "LineOfCredit" && $0.value == expectedCredit })
        let original = try await SECFinancialReport.make(cik: parent.identity.cik, facts: parent.facts,
            submissions: parent.submissions, cutoff: parent.cutoff, executionDate: parent.cutoff.addingTimeInterval(1),
            evidencePolicy: SECFinancialReport.legacyPolicyVersion)
        let originalBytes = try SECFinancialReport.bytes(original)
        let reopened = try JSONDecoder().decode(SECFinancialReport.self, from: originalBytes)
        #expect(try SECFinancialReport.bytes(reopened) == originalBytes)
        #expect(reopened.evidencePolicy == SECFinancialReport.legacyPolicyVersion)
        #expect(reopened.inputSnapshot.financials.input.normalization.dictionaryVersion == "financial-fields.us-gaap.completion.v1")
        #expect(try await reopened.cachedReportsMatch(reopened.recompute()))
        try reopened.validateEvidence(facts: parent.facts, submissions: parent.submissions, classification: nil)
        let breakdown = SECFinancialDebtBreakdown(report: reopened)
        #expect(breakdown.usesLegacyEvidence && breakdown.missingCount == 4)
        #expect(breakdown.disclosures.isEmpty)
        #expect(!reopened.evidence.facts.contains { $0.concept == "LineOfCredit" })
        #expect(reopened.baseReport.metrics["debt"]?.value == nil)
    }
}
