import Foundation
import Testing
import CoreDomain
import AIInsights
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

@Suite struct AIInsightReportAdapterTests {
    @Test func fullReplayProducesExactValuesUnitsAndExplicitPeriods() async throws {
        let report = try await makeAIAdapterReport()
        let input = try await AIInsightReportAdapter.prepare(report)
        try input.validate()
        #expect(input.ticker == "AAPL")
        #expect(input.companyName == "Synthetic Report Company")
        #expect(input.periodEnd == "2024-12-31")
        let revenue = try #require(input.metrics.first { $0.id == "base.revenue" })
        #expect(revenue.value == "400")
        #expect(revenue.unit == "USD")
        #expect(revenue.label == "营业收入（TTM 2024-01-01—2024-12-31）")
        let margin = try #require(input.metrics.first { $0.id == "base.operatingMargin" })
        #expect(margin.value == "0.2")
        #expect(margin.unit == "ratio")
        let quarter = try #require(input.metrics.first { $0.id == "growth.revenueQuarter" })
        #expect(quarter.value == "100")
        #expect(quarter.label == "营业收入（本季 2024-10-01—2024-12-31）")
        let growth = try #require(input.metrics.first { $0.id == "growth.revenueQuarterYoY" })
        #expect(growth.label.contains("对比 2023-10-01—2023-12-31"))
        #expect(input.metrics.count == 35)
    }

    @Test func missingApplicabilityStaysMissingWhileKnownZeroRemainsZero() async throws {
        let input = try await AIInsightReportAdapter.prepare(makeAIAdapterReport())
        let roic = try #require(input.metrics.first { $0.id == "base.roic" })
        #expect(roic.value == nil)
        #expect(roic.unavailable == "missingEvidence")
        let cash = try #require(input.metrics.first { $0.id == "completion.cash" })
        #expect(cash.value == nil)
        #expect(cash.unavailable == "missingInput")
        let growth = try #require(input.metrics.first { $0.id == "base.revenueYoY" })
        #expect(growth.value == "0")
        #expect(growth.unavailable == nil)
        #expect(input.metrics.allSatisfy { ($0.value == nil) == ($0.unavailable != nil) })
    }

    @Test func structurallyValidButAlteredCachedMetricCannotBeSent() async throws {
        let report = try await makeAIAdapterReport()
        let changed = try alteredAIAdapterMetric(report)
        try changed.validate() // structural checks deliberately do not verify output numbers
        await #expect(throws: AIInsightReportAdapterError.replayMismatch) {
            try await AIInsightReportAdapter.prepare(changed)
        }
    }

    @Test func externalPacketContainsOnlyWhitelistedFieldsAndLocalCalculationReferences() async throws {
        let marker = "SECRET-NOT-FOR-AI:/Users/private/account:Bearer-example"
        let parent = try await secFinancialReportFixtureParent(filingHTML: "<p>" + marker + "</p>")
        let parentBytes = try ResearchDocument.encoded(parent)
        #expect(String(decoding: parent.sources.flatMap { Array($0.bytes) }, as: UTF8.self).contains(marker))
        let report = try await SECFinancialReportDocument.make(parent: parent, parentBytes: parentBytes,
            executionDate: parent.cutoff.addingTimeInterval(1))
        let input = try await AIInsightReportAdapter.prepare(report)
        let encoded = try input.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == Set(["format", "ticker", "companyName", "periodEnd", "cutoff", "metrics", "sources"]))
        for forbidden in [marker, "synthetic@example.invalid", report.id.uuidString,
                          parent.id.uuidString, report.parentDocumentHash, "inputSnapshot", "provenance",
                          "classification", "sourceValue", "rawObjectRef", "sourceVersions", "marketCap", "peEPS"] {
            #expect(!text.contains(forbidden))
        }
        #expect(input.sources.map(\.id) == ["local.base", "local.growth", "local.completion"])
        let sourceIDs = Set(input.sources.map(\.id))
        #expect(input.metrics.allSatisfy { Set($0.sourceIDs).isSubset(of: sourceIDs) && !$0.sourceIDs.isEmpty })
        #expect(input.sources.allSatisfy { $0.label.contains("本地") && $0.label.contains("重算匹配") })
        #expect(input.metrics.allSatisfy { ["USD", "ratio"].contains($0.unit) })
    }

    @Test func cutoffDescriptionRetainsRepresentedSubmillisecondBoundary() throws {
        let whole = Date(timeIntervalSince1970: 1_791_072_000)
        let precise = whole.addingTimeInterval(0.0002)
        let text = try AIInsightReportAdapter.utcCutoff(precise)
        let parts = text.split(separator: ".")
        let fraction = try #require(parts.last).dropLast()
        let nanoseconds = try #require(Int(fraction))
        #expect(fraction.count == 9)
        #expect(nanoseconds > 0 && nanoseconds < 1_000_000)
        let reconstructed = whole.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
        #expect(reconstructed == precise)
        #expect(try AIInsightReportAdapter.utcCutoff(whole).hasSuffix(".000000000Z"))
    }
}

private func makeAIAdapterReport() async throws -> SECFinancialReportDocument {
    let parent = try await secFinancialReportFixtureParent()
    return try await SECFinancialReportDocument.make(parent: parent, parentBytes: ResearchDocument.encoded(parent),
        executionDate: parent.cutoff.addingTimeInterval(1))
}

private func alteredAIAdapterMetric(_ report: SECFinancialReportDocument) throws -> SECFinancialReportDocument {
    var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(report)) as? [String: Any])
    var financials = try #require(object["financials"] as? [String: Any])
    var base = try #require(financials["baseReport"] as? [String: Any])
    var metrics = try #require(base["metrics"] as? [String: Any])
    var revenue = try #require(metrics["revenue"] as? [String: Any])
    revenue["value"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Money("999")), options: [.fragmentsAllowed])
    metrics["revenue"] = revenue; base["metrics"] = metrics
    financials["baseReport"] = base; object["financials"] = financials
    return try JSONDecoder().decode(SECFinancialReportDocument.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}
