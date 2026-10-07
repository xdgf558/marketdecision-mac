import Foundation
import Testing
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

@Suite struct SECFinancialReportDocumentTests {
    @Test func observedIndustryMetadataBindsExactSourceWithoutGrantingApplicability() async throws {
        let parent = try await secFinancialReportFixtureParent()
        let bytes = try ResearchDocument.encoded(parent)
        let report = try await SECFinancialReportDocument.make(parent: parent, parentBytes: bytes,
            executionDate: parent.cutoff.addingTimeInterval(1))
        let observed = try #require(report.financials.evidence.classification)
        let root = try #require(parent.sources.first { $0.endpoint == .submissions && $0.request.pageToken == nil })
        #expect(observed.sic == 7372)
        #expect(observed.sourceReference == root.reference)
        #expect(observed.sourceVersion == "sha256:" + root.contentHash)
        #expect(observed.sourceHash == digest(root.bytes))
        #expect(report.financials.baseReport.metrics["roic"]?.unavailable == .missingEvidence)
        #expect(report.financials.baseReport.metrics["netDebtEBITDA"]?.unavailable == .missingEvidence)
        #expect(!report.mayRunValuation)
        #expect(report.financials.baseReport.metrics["revenue"]?.value == (try Money("400")))
        #expect(report.financials.baseReport.metrics["fcf"]?.value == (try Money("80")))
        try report.validate(parent: parent, parentBytes: bytes)
        let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.prettyPrinted, .sortedKeys])
        #expect(pretty != bytes)
        #expect(throws: SECFinancialError.inconsistentEvidence) { try report.validate(parent: parent, parentBytes: pretty) }
    }

    @Test func absentOrInvalidIndustryMetadataStaysUnknownWithoutBlockingOtherFinancials() async throws {
        for value: String? in [nil, "0", "not-a-code", "7372.5"] {
            let parent = try await secFinancialReportFixtureParent(sic: value)
            let report = try await SECFinancialReportDocument.make(parent: parent, parentBytes: ResearchDocument.encoded(parent),
                executionDate: parent.cutoff.addingTimeInterval(1))
            #expect(report.financials.evidence.classification == nil)
            #expect(report.financials.baseReport.metrics["revenue"]?.value == (try Money("400")))
            #expect(report.financials.baseReport.metrics["roic"]?.unavailable == .missingEvidence)
        }
    }
}
