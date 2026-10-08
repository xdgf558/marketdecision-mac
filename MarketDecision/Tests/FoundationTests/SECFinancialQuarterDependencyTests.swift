import Foundation
import CryptoKit
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

private let dependencyCIK = "0000999999"
private typealias DependencyRecords = (facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord])

private func dependencyProvenance(_ id: String, endpoint: EndpointDescriptor, end: MarketDate) throws -> Provenance {
    let filed = try end.addingDays(30)
    return .init(providerID: "sec-edgar", feedID: "public-edgar", sourceEventAt: nil,
        receivedAt: secFinancialFixtureCutoff, availableAt: nil, evidenceRef: "synthetic-quarter-dependency",
        origin: .filing, endpointDescriptor: endpoint.rawValue, requestedAt: secFinancialFixtureCutoff.addingTimeInterval(-1),
        requestID: UUID(uuidString: "99999999-1111-2222-3333-444444444444")!, observationDate: end,
        versionID: "synthetic-version/" + id, versionKind: .sourceVersion,
        availability: .instant(try filed.start(in: TimeZone(secondsFromGMT: 0)!), evidence: "synthetic exact availability"),
        rawObjectRef: "synthetic/dependency/" + endpoint.rawValue, rawHash: String(repeating: "b", count: 64),
        normalizationVersion: "synthetic-dependency.v1", licenseRef: "synthetic-only")
}

private func dependencyFact(year: Int, index: Int, end: MarketDate, concept: String, value: Int,
                            start: MarketDate? = nil) throws -> SECCompanyFactRecord {
    let start = try start ?? MarketDate(iso8601: "\(year)-01-01")
    let id = "synthetic/\(year)/\(index)/\(concept)/" + start.iso8601
    return try .init(recordID: id, factID: id, cik: dependencyCIK, taxonomy: "us-gaap", concept: concept,
        label: concept, description: "Invented fiscal dependency fixture", unit: "USD", sourceValue: String(value),
        value: Money(String(value)), startDate: start, endDate: end, periodKind: .duration,
        accessionNumber: "\(dependencyCIK)-\(String(format: "%02d", year % 100))-00000\(index + 1)", form: index == 3 ? "10-K" : "10-Q",
        filedDate: end.addingDays(30), fiscalYear: 2099, fiscalPeriod: "FY", frame: nil,
        provenance: dependencyProvenance(id, endpoint: .companyFacts, end: end))
}

private func dependencyYear(_ year: Int, annualRevenue: Int,
                            ends: [String] = ["03-31", "06-30", "09-30", "12-31"]) throws -> DependencyRecords {
    var records: DependencyRecords = ([], [])
    for (index, suffix) in ends.enumerated() {
        let end = try MarketDate(iso8601: "\(year)-" + suffix), id = "synthetic/submission/\(year)/\(index)"
        records.submissions.append(try .init(recordID: id, cik: dependencyCIK,
            accessionNumber: "\(dependencyCIK)-\(String(format: "%02d", year % 100))-00000\(index + 1)", form: index == 3 ? "10-K" : "10-Q",
            filingDate: end.addingDays(30), reportDate: end, acceptedAt: nil, primaryDocument: "synthetic.htm",
            isAmendment: false, provenance: dependencyProvenance(id, endpoint: .submissions, end: end)))
        records.facts.append(try dependencyFact(year: year, index: index, end: end,
            concept: "RevenueFromContractWithCustomerExcludingAssessedTax", value: annualRevenue * (index + 1) / 4))
        if index == 3 {
            records.facts.append(try dependencyFact(year: year, index: index, end: end,
                concept: "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest", value: 100))
            records.facts.append(try dependencyFact(year: year, index: index, end: end, concept: "IncomeTaxExpenseBenefit", value: 20))
        }
    }
    return records
}

private func dependencySixYears(malformedYear: Int? = nil) throws -> DependencyRecords {
    var records: DependencyRecords = ([], [])
    for year in 2020...2025 {
        // Entirely invented dates and amounts: annual revenue doubles each year.
        let ends = year == malformedYear ? ["03-31", "06-30", "11-30", "12-31"]
            : ["03-31", "06-30", "09-30", "12-31"]
        let yearRecords = try dependencyYear(year, annualRevenue: 100 * (1 << (year - 2020)), ends: ends)
        records.facts += yearRecords.facts; records.submissions += yearRecords.submissions
    }
    return records
}

private func dependencyReport(_ records: DependencyRecords) async throws -> SECFinancialReport {
    try await .make(cik: dependencyCIK, facts: records.facts, submissions: records.submissions,
                    cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
}

@Suite struct SECFinancialQuarterDependencyTests {
    @Test func overlappingAnnualCandidatePreservesLegacyEightQuarterReport() async throws {
        var records = try dependencySixYears()
        let end = try MarketDate(iso8601: "2025-09-30")
        let id = "synthetic/overlapping-annual"
        records.facts.append(try dependencyFact(year: 2025, index: 3, end: end,
            concept: "Revenues", value: 2400, start: MarketDate(iso8601: "2024-12-01")))
        records.submissions.append(try .init(recordID: id, cik: dependencyCIK,
            accessionNumber: "\(dependencyCIK)-25-000005", form: "10-K", filingDate: end.addingDays(30),
            reportDate: end, acceptedAt: nil, primaryDocument: "synthetic-transition.htm", isAmendment: false,
            provenance: dependencyProvenance(id, endpoint: .submissions, end: end)))
        let prepared = try SECFinancialEvidenceAdapter.prepare(cik: dependencyCIK, facts: records.facts,
            submissions: records.submissions, cutoff: secFinancialFixtureCutoff, classification: nil)
        #expect(prepared.evidence.quarters.count == 8)
        #expect(prepared.evidence.quarters.first?.start.iso8601 == "2024-01-01")
        let report = try await dependencyReport(records)
        #expect(report.evidence.quarters.count == 8)
        #expect(report.evidence.quarters.first?.start.iso8601 == "2024-01-01")
        let bytes = try SECFinancialReport.bytes(report)
        // Captured from the original all-history adapter before either dependency-bound change.
        // This covers the full input/evidence/model/cache serialization, not just quarter count.
        let legacyHash = "d64ac95c53c2c02cd5bb1f2a864ff371c2614d318f228818e6d71fd336355813"
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == legacyHash)
        let reopened = try JSONDecoder().decode(SECFinancialReport.self, from: bytes)
        try reopened.validateEvidence(facts: records.facts, submissions: records.submissions, classification: nil)
        #expect(try reopened.cachedReportsMatch(await reopened.recompute()))
    }

    @Test func unrelatedOldQuarterGeometryDoesNotPoisonCurrentReportOrAnnualInputs() async throws {
        let current = try dependencySixYears(), baseline = try await dependencyReport(current)
        let old = try dependencyYear(2003, annualRevenue: 4, ends: ["03-31", "06-30", "11-30", "12-31"])
        let complete: DependencyRecords = (current.facts + old.facts, current.submissions + old.submissions)
        let report = try await dependencyReport(complete)
        #expect(report.evidence.quarters.count == 8 && report.evidence.quarters.first?.start.iso8601 == "2024-01-01")
        #expect(report.evidence.fiscalYears.count == 3 && report.evidence.fiscalYears.first?.start.iso8601 == "2023-01-01")
        #expect(report.evidence.revenueYears.count == 6 && report.evidence.revenueYears.first?.start.iso8601 == "2020-01-01")
        #expect(report.baseReport.metrics["normalizedTax"]?.value == (try Money("0.2")))
        #expect(report.completionReport.metrics["revenueCAGR5Y"]?.value == (try Money("1")))
        #expect(report.completionReport.metrics["revenueCAGR5YChange"]?.value == (try Money("3100")))
        #expect(try SECFinancialReport.bytes(report.inputSnapshot) == SECFinancialReport.bytes(baseline.inputSnapshot))
        let baselineReplay = try await baseline.recompute()
        #expect(try report.cachedReportsMatch(baselineReplay))
        #expect(try SECFinancialReport.bytes(report.evidence.facts) == SECFinancialReport.bytes(baseline.evidence.facts))
        for submission in old.submissions {
            #expect(report.evidence.submissions.contains(submission))
        }
        // The saved report retains all six annual dependencies and the unchanged old metadata.
        // Rebuilding from compact evidence and binding again to ALL parent records must agree.
        let bytes = try SECFinancialReport.bytes(report)
        let reopened = try JSONDecoder().decode(SECFinancialReport.self, from: bytes)
        try reopened.validateEvidence(facts: complete.facts, submissions: complete.submissions, classification: nil)
        let replay = try await reopened.recompute()
        #expect(try reopened.cachedReportsMatch(replay))
        #expect(try SECFinancialReport.bytes(reopened) == bytes)
    }

    @Test(arguments: [2020, 2022])
    func retainedAnnualDependenciesDoNotRequireUnselectedQuarterGeometry(_ year: Int) async throws {
        let baseline = try await dependencyReport(dependencySixYears())
        let records = try dependencySixYears(malformedYear: year)
        let report = try await dependencyReport(records)
        // Annual growth dependencies outside the conservative quarter horizon remain selected
        // despite malformed quarter geometry. No annual source or metadata is rewritten.
        #expect(report.evidence.revenueYears.count == 6)
        #expect(report.evidence.fiscalYears.count == 3)
        #expect(report.evidence.facts.contains { $0.endDate.iso8601 == "\(year)-11-30" })
        #expect(report.baseReport.metrics["normalizedTax"]?.value == (try Money("0.2")))
        #expect(report.completionReport.metrics["revenueCAGR5Y"]?.value == (try Money("1")))
        #expect(try SECFinancialReport.bytes(report.inputSnapshot) == SECFinancialReport.bytes(baseline.inputSnapshot))
        let reopened = try JSONDecoder().decode(SECFinancialReport.self, from: SECFinancialReport.bytes(report))
        try reopened.validateEvidence(facts: records.facts, submissions: records.submissions, classification: nil)
        let replay = try await reopened.recompute()
        #expect(try reopened.cachedReportsMatch(replay))
        #expect(try baseline.cachedReportsMatch(replay))
    }

    @Test(arguments: [2023, 2024, 2025])
    func requiredAnnualQuarterGeometryStillRejects(_ year: Int) throws {
        // 2023 is inside the conservative horizon even though these particular inputs later
        // select only 2024–2025 quarters. Keep the original refusal throughout that horizon.
        let records = try dependencySixYears(malformedYear: year)
        #expect(throws: SECFinancialError.ambiguousPeriods) {
            try SECFinancialEvidenceAdapter.prepare(cik: dependencyCIK, facts: records.facts,
                submissions: records.submissions, cutoff: secFinancialFixtureCutoff, classification: nil)
        }
    }

    @Test func currentPartialQuarterGeometryStillRejects() throws {
        var records = try dependencySixYears()
        let partial = try dependencyYear(2026, annualRevenue: 6400, ends: ["06-30"])
        records.facts += partial.facts; records.submissions += partial.submissions
        #expect(throws: SECFinancialError.ambiguousPeriods) {
            try SECFinancialEvidenceAdapter.prepare(cik: dependencyCIK, facts: records.facts,
                submissions: records.submissions, cutoff: secFinancialFixtureCutoff, classification: nil)
        }
    }

    @Test func currentPartialKeepsEightQuartersAndAllSixAnnualDependencies() throws {
        var records = try dependencySixYears()
        let old = try dependencyYear(2003, annualRevenue: 4, ends: ["03-31", "06-30", "11-30", "12-31"])
        let partial = try dependencyYear(2026, annualRevenue: 6400, ends: ["03-31", "06-30"])
        records.facts += old.facts + partial.facts; records.submissions += old.submissions + partial.submissions
        let prepared = try SECFinancialEvidenceAdapter.prepare(cik: dependencyCIK, facts: records.facts,
            submissions: records.submissions, cutoff: secFinancialFixtureCutoff, classification: nil)
        #expect(prepared.evidence.quarters.count == 8)
        #expect(prepared.evidence.quarters.first?.start.iso8601 == "2024-07-01")
        #expect(prepared.evidence.quarters.last?.end.iso8601 == "2026-06-30")
        #expect(prepared.evidence.revenueYears.count == 6)
        #expect(prepared.input.financials.fiscalYears.count == 3)
    }

    @Test func requiredAnnualStartAmbiguityAndMissingLatestEvidenceStillReject() throws {
        var ambiguous = try dependencySixYears()
        ambiguous.facts.append(try dependencyFact(year: 2025, index: 3, end: MarketDate(iso8601: "2025-12-31"),
            concept: "Revenues", value: 3200, start: MarketDate(iso8601: "2025-01-02")))
        #expect(throws: SECFinancialError.ambiguousPeriods) {
            try SECFinancialEvidenceAdapter.prepare(cik: dependencyCIK, facts: ambiguous.facts,
                submissions: ambiguous.submissions, cutoff: secFinancialFixtureCutoff, classification: nil)
        }
        var missing = try dependencySixYears()
        missing.facts.removeAll { $0.endDate.iso8601 == "2025-12-31" }
        #expect(throws: SECFinancialError.insufficientPeriods) {
            try SECFinancialEvidenceAdapter.prepare(cik: dependencyCIK, facts: missing.facts,
                submissions: missing.submissions, cutoff: secFinancialFixtureCutoff, classification: nil)
        }
    }
}
