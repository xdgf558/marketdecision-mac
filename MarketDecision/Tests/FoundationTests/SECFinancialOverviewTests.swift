import Foundation
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
        #expect(growth.periodLabel == "完整财年历史不足（需要连续 4 个年度）")
        #expect(cash.metric?.value == nil && cash.metric?.unavailable == .missingInput)
        #expect(cash.displayValue == "缺少输入")
    }

    @Test func latestQuarterIsDefaultAndTTMSelectsItsOwnCalculatedMetrics() async throws {
        let parent = try await secFinancialReportFixtureParent(includeOverviewMetrics: true)
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        let report = document.financials
        #expect(try await report.cachedReportsMatch(report.recompute()))
        let quarter = SECFinancialOverview.rows(for: report)
        let ttm = SECFinancialOverview.rows(for: report, period: .ttm)

        for id in ["revenue", "netIncome", "fcf"] {
            let single = try #require(quarter.first { $0.id == id })
            let annual = try #require(ttm.first { $0.id == id })
            #expect(single.metric == report.growthReport.metrics[id + "Quarter"])
            #expect(annual.metric == report.baseReport.metrics[id])
            #expect(single.metric?.value != nil && annual.metric?.value != nil)
            #expect(single.metric?.value != annual.metric?.value)
            #expect(single.periodLabel == "单季度")
            #expect(annual.periodLabel == "最近四季合计")
            #expect(single.basis == annual.basis)
        }
        #expect(quarter.first { $0.id == "revenue" }?.metric?.value == (try Money("800")))
        #expect(ttm.first { $0.id == "revenue" }?.metric?.value == (try Money("3200")))
        #expect(quarter.first { $0.id == "netIncome" }?.basis == "财报净利润（未作调整）")
        #expect(quarter.first { $0.id == "fcf" }?.basis == "经营现金流 − 资本支出")
    }

    @Test func periodsComeFromFrozenWindowsAndBalanceAndGrowthDoNotSwitch() async throws {
        let parent = try await secFinancialReportFixtureParent(includeOverviewMetrics: true)
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        let report = document.financials
        let quarter = SECFinancialOverview.rows(for: report)
        let ttm = SECFinancialOverview.rows(for: report, period: .ttm)
        // The source cutoff is in 2026; reporting geometry remains the frozen 2024 windows.
        #expect(SECFinancialOverview.periodSummary(for: report) == "单季度：2024-10-01 至 2024-12-31")
        #expect(SECFinancialOverview.periodSummary(for: report, period: .ttm)
            == "最近四季合计：2024-01-01 至 2024-12-31")
        for id in ["cash", "debt", "revenueCAGR3Y"] {
            let single = try #require(quarter.first { $0.id == id })
            let annual = try #require(ttm.first { $0.id == id })
            #expect(single.metric == annual.metric)
            #expect(single.periodLabel == annual.periodLabel && single.basis == annual.basis)
        }
        #expect(quarter.first { $0.id == "cash" }?.periodLabel == "截至 2024-12-31")
        #expect(quarter.first { $0.id == "debt" }?.periodLabel == "截至 2024-12-31")
        #expect(quarter.first { $0.id == "cash" }?.basis == "不含短期投资")
        #expect(quarter.first { $0.id == "debt" }?.basis == "借款与租赁，不等于总负债")
        #expect(quarter.first { $0.id == "revenueCAGR3Y" }?.periodLabel
            == "财年期末 2021-12-31 → 2024-12-31")
        #expect(quarter.first { $0.id == "revenueCAGR3Y" }?.basis == "完整年度收入 · 3 年年复合增长率")
    }

    @Test func missingQuarterMetricNeverBorrowsTTMOrInventsZero() async throws {
        let parent = try await secFinancialReportFixtureParent(includeOverviewMetrics: true)
        let document = try await SECFinancialReportDocument.make(parent: parent,
            parentBytes: ResearchDocument.encoded(parent), executionDate: parent.cutoff.addingTimeInterval(1))
        // Deliberately remove one cached quarter key to exercise the projection's no-fallback
        // contract in isolation. This fixture is not a replay-qualified production report;
        // the workspace must still reject a cache that differs from recomputation.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document.financials)) as? [String: Any])
        var growth = try #require(object["growthReport"] as? [String: Any])
        var metrics = try #require(growth["metrics"] as? [String: Any])
        metrics.removeValue(forKey: "netIncomeQuarter")
        growth["metrics"] = metrics
        object["growthReport"] = growth
        let report = try JSONDecoder().decode(SECFinancialReport.self,
            from: JSONSerialization.data(withJSONObject: object))
        let cacheMatches = try await report.cachedReportsMatch(report.recompute())
        #expect(!cacheMatches)

        let quarter = try #require(SECFinancialOverview.rows(for: report).first { $0.id == "netIncome" })
        let ttm = try #require(SECFinancialOverview.rows(for: report, period: .ttm).first { $0.id == "netIncome" })
        #expect(quarter.metric == nil)
        #expect(quarter.displayValue == "缺少输入")
        #expect(quarter.displayValue != "0")
        #expect(ttm.metric?.value == (try Money("40")))
    }
}
