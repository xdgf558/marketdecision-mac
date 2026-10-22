import Testing
import CoreDomain
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

@Suite struct SECFinancialOverviewTests {
    @Test func completeAnnualEvidenceDisplaysCashAndCAGRFromCalculatedCompletionReport() async throws {
        let parent = try await secFinancialReportFixtureParent(includeOverviewMetrics: true)
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        let report = document.financials
        #expect(try await report.cachedReportsMatch(report.recompute()))
        #expect(report.inputSnapshot.revenueYears.count == 4)
        let completionCash = try #require(report.completionReport.metrics["cash"])
        let completionGrowth = try #require(report.completionReport.metrics["revenueCAGR3Y"])
        #expect(completionCash.value == (try Money("50")))
        #expect(completionGrowth.value == (try Money("1")))
        #expect(report.baseReport.metrics["cash"] == nil)
        #expect(report.growthReport.metrics["revenueCAGR3Y"] == nil)

        let rows = SECFinancialOverview.rows(for: report)
        #expect(rows.map(\.id) == ["revenue", "netIncome", "fcf", "cash", "debt", "revenueCAGR3Y"])
        let cash = try #require(rows.first { $0.id == "cash" })
        let growth = try #require(rows.first { $0.id == "revenueCAGR3Y" })
        #expect(cash.metric == completionCash && cash.displayValue == "50")
        #expect(growth.metric == completionGrowth && growth.displayValue == "100.00%")
    }

    @Test func missingAnnualHistoryPreservesTheCalculatedUnavailableReason() async throws {
        let parent = try await secFinancialReportFixtureParent()
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        let report = document.financials
        #expect(report.inputSnapshot.revenueYears.count == 2)
        #expect(report.completionReport.metrics["revenueCAGR3Y"]?.unavailable == .insufficientHistory)
        #expect(report.completionReport.metrics["cash"]?.unavailable == .missingInput)

        let rows = SECFinancialOverview.rows(for: report)
        let growth = try #require(rows.first { $0.id == "revenueCAGR3Y" })
        let cash = try #require(rows.first { $0.id == "cash" })
        #expect(growth.metric?.value == nil && growth.metric?.unavailable == .insufficientHistory)
        #expect(growth.displayValue == "历史期间不足")
        #expect(cash.metric?.value == nil && cash.metric?.unavailable == .missingInput)
        #expect(cash.displayValue == "缺少输入")
    }
}
