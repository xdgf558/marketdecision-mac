import Foundation
import Testing
import FundamentalsEngine
@testable import Persistence

@Suite struct SECValuationSupplementDocumentTests {
    @Test func bindingUsesRetainedParentEncodingsAndRejectsEquivalentReencoding() async throws {
        let (_, _, research, report, draft) = try await secValuationStorageFixture()
        let reportBytes = try ResearchDocument.encoded(report), researchBytes = try ResearchDocument.encoded(research)
        let prettyReport = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: reportBytes), options: [.prettyPrinted, .sortedKeys])
        let prettyResearch = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: researchBytes), options: [.prettyPrinted, .sortedKeys])
        #expect(prettyReport != reportBytes && prettyResearch != researchBytes)
        try draft.document.validate(parent: report, parentBytes: reportBytes, research: research, researchBytes: researchBytes)
        #expect(throws: SECFinancialError.inconsistentEvidence) {
            try draft.document.validate(parent: report, parentBytes: prettyReport, research: research, researchBytes: researchBytes)
        }
        #expect(throws: SECFinancialError.inconsistentEvidence) {
            try draft.document.validate(parent: report, parentBytes: reportBytes, research: research, researchBytes: prettyResearch)
        }
        #expect(!report.mayRunValuation && !research.mayRunValuation)
    }

    @Test func changedDocumentTimeOrIdentityCannotDetachValuationFromItsParents() async throws {
        let (_, _, research, report, draft) = try await secValuationStorageFixture()
        let bytes = try ResearchDocument.encoded(draft.document)
        for key in ["createdAt", "ticker", "parentFinancialReportID", "parentResearchID"] {
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            if key == "createdAt" { object[key] = draft.document.createdAt.addingTimeInterval(1).timeIntervalSinceReferenceDate }
            else if key == "ticker" { object[key] = "MSFT" }
            else { object[key] = UUID().uuidString }
            let changed = try JSONDecoder().decode(SECValuationSupplementDocument.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: SECFinancialError.inconsistentEvidence) {
                try changed.validate(parent: report, parentBytes: ResearchDocument.encoded(report),
                    research: research, researchBytes: ResearchDocument.encoded(research))
            }
        }
    }
}
