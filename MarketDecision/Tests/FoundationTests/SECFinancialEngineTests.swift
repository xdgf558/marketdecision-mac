import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

let secFinancialFixtureCutoff = Date(timeIntervalSince1970: 1_791_072_000) // October 2026, after approved model introduction.

func secFinancialFixtureRecords() throws -> (facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord]) {
    var facts: [SECCompanyFactRecord] = [], submissions: [SECSubmissionRecord] = []
    let concepts = [("RevenueFromContractWithCustomerExcludingAssessedTax", 10), ("OperatingIncomeLoss", 2),
                    ("NetIncomeLoss", 1), ("NetCashProvidedByUsedInOperatingActivities", 3),
                    ("PaymentsToAcquirePropertyPlantAndEquipment", 1), ("GrossProfit", 4)]
    for year in [2024, 2025] {
        for (index, suffix) in ["03-31", "06-30", "09-30", "12-31"].enumerated() {
            let end = try MarketDate(iso8601: "\(year)-" + suffix)
            let form = index == 3 ? "10-K" : "10-Q"
            let accession = "0000320193-\(year % 100)-00000\(index + 1)"
            let filed = try end.addingDays(30)
            let available = try filed.start(in: TimeZone(secondsFromGMT: 0)!)
            let id = "\(year)-\(index)"
            let sp = secFinancialFixtureProvenance(id: "submission-" + id, endpoint: .submissions, day: end, available: available)
            submissions.append(try SECSubmissionRecord(recordID: "submission-" + id, cik: "0000320193", accessionNumber: accession,
                form: form, filingDate: filed, reportDate: end, acceptedAt: nil, primaryDocument: "fixture.htm", isAmendment: false, provenance: sp))
            for (concept, scale) in concepts {
                let value = String(((index + 1) * (index + 2) / 2) * scale)
                let key = concept + "-" + id
                facts.append(try SECCompanyFactRecord(recordID: key, factID: key, cik: "0000320193", taxonomy: "us-gaap",
                    concept: concept, label: concept, description: "Synthetic cumulative period fixture", unit: "USD",
                    sourceValue: value, value: Money(value), startDate: MarketDate(iso8601: "\(year)-01-01"), endDate: end,
                    periodKind: .duration, accessionNumber: accession, form: form, filedDate: filed,
                    fiscalYear: 2099, fiscalPeriod: "FY", frame: nil,
                    provenance: secFinancialFixtureProvenance(id: key, endpoint: .companyFacts, day: end, available: available)))
            }
        }
    }
    return (facts, submissions)
}

private func secFinancialFixtureProvenance(id: String, endpoint: EndpointDescriptor, day: MarketDate, available: Date) -> Provenance {
    .init(providerID: "sec-edgar", feedID: "public-edgar", sourceEventAt: nil,
        receivedAt: secFinancialFixtureCutoff, availableAt: nil, evidenceRef: "synthetic-sec-financial", origin: .filing,
        endpointDescriptor: endpoint.rawValue, requestedAt: secFinancialFixtureCutoff.addingTimeInterval(-1),
        requestID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!, observationDate: day,
        versionID: "v1-" + id, versionKind: .sourceVersion, availability: .instant(available, evidence: "synthetic"),
        rawObjectRef: "synthetic/" + endpoint.rawValue, rawHash: String(repeating: "a", count: 64),
        normalizationVersion: "synthetic.v1", licenseRef: "synthetic")
}

private func secFinancialChangedFact(_ fact: SECCompanyFactRecord, changes: [String: Any]) throws -> SECCompanyFactRecord {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fact)) as? [String: Any])
    for (key, value) in changes { object[key] = value }
    return try JSONDecoder().decode(SECCompanyFactRecord.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}
private func secFinancialMake(_ records: (facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord]),
                              classification: SECFinancialClassificationEvidence? = nil) async throws -> SECFinancialReport {
    try await .make(cik: "0000320193", facts: records.facts, submissions: records.submissions,
                    cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff, classification: classification)
}

@Suite struct SECFinancialEngineTests {
    @Test func exactPeriodEvidenceIgnoresFiscalLabelsAndUsesIndependentCashOracle() async throws {
        let records = try secFinancialFixtureRecords(), report = try await secFinancialMake(records)
        #expect(report.evidence.quarters.count == 8)
        #expect(report.evidence.quarters.first?.start.iso8601 == "2024-01-01")
        #expect(report.evidence.quarters.last?.end.iso8601 == "2025-12-31")
        #expect(report.baseReport.metrics["revenue"]?.value == (try Money("100")))
        #expect(report.baseReport.metrics["fcf"]?.value == (try Money("20")))
        #expect(report.baseReport.metrics["operatingMargin"]?.value == (try Money("0.2")))
        #expect(report.growthReport.metrics["revenueQuarter"]?.value == (try Money("40")))
        #expect(report.inputSnapshot.financials.input.normalization.values.allSatisfy { $0.fiscalYear == nil })
        #expect(report.inputSnapshot.financials.input.normalization.selectedSourceFacts.isEmpty)
        #expect(report.inputSnapshot.financials.input.normalization.unmappedSourceFacts.isEmpty)
        try report.validateEvidence(facts: records.facts, submissions: records.submissions, classification: nil)
    }

    @Test func unknownIndustryAndObservedSICNeverGrantSensitiveOrPriceMetrics() async throws {
        let observed = try SECFinancialClassificationEvidence(sic: 7372, sourceReference: "synthetic/submissions",
            sourceVersion: "observed.v1", sourceHash: String(repeating: "a", count: 64))
        let report = try await secFinancialMake(secFinancialFixtureRecords(), classification: observed)
        #expect(report.evidence.classification?.sic == 7372)
        #expect(report.baseReport.metrics["roic"]?.unavailable == .missingEvidence)
        #expect(report.baseReport.metrics["netDebtEBITDA"]?.unavailable == .missingEvidence)
        #expect(report.baseReport.metrics["marketCap"]?.value == nil)
        #expect(report.baseReport.metrics["peEPS"]?.value == nil)
        #expect(report.growthReport.metrics["epsQuarter"]?.value == nil)
        #expect(!report.capitalInputsAllowed && !report.historicalPITQualified)
    }

    @Test func missingQuarterCorroborationRefusesInsteadOfFallingBackToOlderYear() async throws {
        var records = try secFinancialFixtureRecords()
        records.submissions.removeAll { $0.reportDate?.iso8601 == "2025-06-30" }
        await #expect(throws: SECFinancialError.insufficientPeriods) { try await secFinancialMake(records) }
    }

    @Test func conflictingAnnualStartRefusesAmbiguousCalendar() async throws {
        var records = try secFinancialFixtureRecords()
        let existing = try #require(records.facts.first { $0.concept == "RevenueFromContractWithCustomerExcludingAssessedTax" && $0.endDate.iso8601 == "2025-12-31" })
        records.facts.append(try secFinancialChangedFact(existing, changes: ["recordID": "conflicting-year", "factID": "conflicting-year",
            "startDate": ["year": 2025, "month": 1, "day": 2]]))
        await #expect(throws: SECFinancialError.ambiguousPeriods) { try await secFinancialMake(records) }
    }

    @Test func newerIncompleteQuarterIsNotSilentlyDropped() async throws {
        var records = try secFinancialFixtureRecords()
        let old = try #require(records.submissions.last)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["recordID"] = "newer-quarter"; object["form"] = "10-Q"
        object["reportDate"] = ["year": 2026, "month": 3, "day": 31]
        records.submissions.append(try JSONDecoder().decode(SECSubmissionRecord.self, from: JSONSerialization.data(withJSONObject: object)))
        await #expect(throws: SECFinancialError.insufficientPeriods) { try await secFinancialMake(records) }
    }

    @Test func codableReportReplaysOnlyFromFrozenInputsAndPreservesExactCutoff() async throws {
        let records = try secFinancialFixtureRecords()
        let cutoff = secFinancialFixtureCutoff.addingTimeInterval(0.0002)
        let report = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts, submissions: records.submissions,
            cutoff: cutoff, executionDate: cutoff)
        let data = try JSONEncoder().encode(report)
        let saved = try JSONDecoder().decode(SECFinancialReport.self, from: data)
        #expect(saved.cutoff == cutoff)
        #expect(try await saved.cachedReportsMatch(saved.recompute()))
        #expect(saved.models.map(\.reference) == report.models.map(\.reference))
        #expect(saved.evidence.facts.allSatisfy { $0.fiscalYear == 2099 })
    }

    @Test func changedCachedNumberDoesNotPassReplayAndMissingInputSnapshotIsRejected() async throws {
        let report = try await secFinancialMake(secFinancialFixtureRecords())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var base = try #require(object["baseReport"] as? [String: Any])
        var metrics = try #require(base["metrics"] as? [String: Any])
        var revenue = try #require(metrics["revenue"] as? [String: Any])
        revenue["value"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Money("999")), options: [.fragmentsAllowed])
        metrics["revenue"] = revenue; base["metrics"] = metrics; object["baseReport"] = base
        let changed = try JSONDecoder().decode(SECFinancialReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try await !changed.cachedReportsMatch(changed.recompute()))
        object.removeValue(forKey: "inputSnapshot")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SECFinancialReport.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func parentEvidenceComparisonRejectsOmittedConflictAndWrongClassification() async throws {
        var records = try secFinancialFixtureRecords()
        let report = try await secFinancialMake(records)
        let old = try #require(records.facts.first { $0.concept == "RevenueFromContractWithCustomerExcludingAssessedTax" })
        records.facts.append(try secFinancialChangedFact(old, changes: ["recordID": "conflict-alias", "factID": "conflict-alias",
            "concept": "Revenues", "sourceValue": "999", "value": "999"]))
        #expect(throws: (any Error).self) { try report.validateEvidence(facts: records.facts, submissions: records.submissions, classification: nil) }
        let observed = try SECFinancialClassificationEvidence(sic: 7372, sourceReference: "synthetic/submissions",
            sourceVersion: "v1", sourceHash: String(repeating: "a", count: 64))
        #expect(throws: SECFinancialError.inconsistentEvidence) {
            try report.validateEvidence(facts: report.evidence.facts, submissions: report.evidence.submissions, classification: observed)
        }
    }


    @Test func parentLatestRevisionChangesInputAndCannotReuseAnOlderReport() async throws {
        var records = try secFinancialFixtureRecords()
        let original = try await secFinancialMake(records)
        let old = try #require(records.facts.first { $0.concept == "RevenueFromContractWithCustomerExcludingAssessedTax" && $0.endDate.iso8601 == "2025-12-31" })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["recordID"] = "revised-annual"; object["sourceValue"] = "110"; object["value"] = "110"
        var source = try #require(object["provenance"] as? [String: Any])
        source["versionID"] = "revised-annual.v2"
        source["availability"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AvailabilityEvidence.instant(secFinancialFixtureCutoff.addingTimeInterval(-1), evidence: "synthetic amendment")))
        object["provenance"] = source
        records.facts.append(try JSONDecoder().decode(SECCompanyFactRecord.self, from: JSONSerialization.data(withJSONObject: object)))
        #expect(throws: SECFinancialError.inconsistentEvidence) {
            try original.validateEvidence(facts: records.facts, submissions: records.submissions, classification: nil)
        }
        let revised = try await secFinancialMake(records)
        #expect(revised.baseReport.metrics["revenue"]?.value == (try Money("110")))
        #expect(revised.baseReport.sourceVersions.contains("revised-annual.v2"))
    }

    @Test func absentMappedExpenseRemainsMissingAndRecordOrderIsDeterministic() async throws {
        var records = try secFinancialFixtureRecords()
        records.facts.removeAll { $0.concept == "PaymentsToAcquirePropertyPlantAndEquipment" }
        let first = try await secFinancialMake(records)
        let reversed = try await secFinancialMake((facts: Array(records.facts.reversed()), submissions: Array(records.submissions.reversed())))
        #expect(first.baseReport.metrics["fcf"]?.value == nil)
        #expect(first.baseReport.metrics["fcf"]?.unavailable == .missingInput)
        #expect(first.baseReport.metrics["revenue"]?.value == (try Money("100")))
        #expect(try SECFinancialReport.bytes(first) == SECFinancialReport.bytes(reversed))
    }

    @Test func shortOrUnsupportedEvidenceCannotBecomeAReport() async throws {
        let records = try secFinancialFixtureRecords()
        await #expect(throws: SECFinancialError.insufficientPeriods) {
            try await secFinancialMake((facts: records.facts.filter { $0.endDate.iso8601 <= "2024-09-30" }, submissions: records.submissions))
        }
        await #expect(throws: SECFinancialError.insufficientPeriods) { try await secFinancialMake((facts: records.facts, submissions: [])) }
    }
}
