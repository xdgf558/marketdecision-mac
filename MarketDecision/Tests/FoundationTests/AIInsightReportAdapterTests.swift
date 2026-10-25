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
        #expect(input.referenceValuation == nil)
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
        let reference = try confirmedAIReferenceDraft().validated(now: aiReferenceNow)
        await #expect(throws: AIInsightReportAdapterError.replayMismatch) {
            try await AIInsightReportAdapter.prepare(changed, reference: reference)
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

    @Test func manualReferenceRequiresConsentWholeSharesAndNonfutureDates() throws {
        let blank = AIValuationReferenceDraft(now: aiReferenceNow)
        #expect(blank.price.isEmpty && blank.shares.isEmpty && blank.sharesAsOf.isEmpty)
        #expect(!blank.confirmedSingleClassSameBasis && !blank.maySendReferenceData)
        #expect(blank.referenceAt == aiReferenceNow)
        var draft = confirmedAIReferenceDraft()
        draft.confirmedSingleClassSameBasis = false
        #expect(throws: AIValuationReferenceError.unconfirmedShareBasis) { try draft.validated(now: aiReferenceNow) }
        draft.confirmedSingleClassSameBasis = true; draft.maySendReferenceData = false
        #expect(throws: AIValuationReferenceError.sendingNotAllowed) { try draft.validated(now: aiReferenceNow) }
        for invalid in ["", "0", "-1", "1e3", "Bearer-SECRET"] {
            var value = confirmedAIReferenceDraft(); value.price = invalid
            #expect(throws: AIValuationReferenceError.invalidPrice) { try value.validated(now: aiReferenceNow) }
        }
        for invalid in ["", "0", "-1", "0.5", "100.1", "1e3"] {
            var value = confirmedAIReferenceDraft(); value.shares = invalid
            #expect(throws: AIValuationReferenceError.invalidShares) { try value.validated(now: aiReferenceNow) }
        }
        for invalid in ["2026-02-30", "2026-1-01", "2027-01-01", "not-a-date"] {
            var value = confirmedAIReferenceDraft(); value.sharesAsOf = invalid
            #expect(throws: AIValuationReferenceError.invalidSharesDate) { try value.validated(now: aiReferenceNow) }
        }
        var future = confirmedAIReferenceDraft(); future.referenceAt = aiReferenceNow.addingTimeInterval(1)
        #expect(throws: AIValuationReferenceError.invalidReferenceDate) { try future.validated(now: aiReferenceNow) }
        var invalidInstant = confirmedAIReferenceDraft(); invalidInstant.referenceAt = Date(timeIntervalSince1970: .infinity)
        #expect(throws: AIValuationReferenceError.invalidReferenceDate) { try invalidInstant.validated(now: aiReferenceNow) }
        var laterShares = confirmedAIReferenceDraft()
        laterShares.referenceAt = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        laterShares.sharesAsOf = "2025-01-02"
        #expect(throws: AIValuationReferenceError.invalidSharesDate) { try laterShares.validated(now: aiReferenceNow) }
        var integer = confirmedAIReferenceDraft(); integer.shares = "100.0"
        #expect(try integer.validated(now: aiReferenceNow).shares.decimalString == "100")
    }

    @Test func confirmedReferenceAddsOnlySixMetricsFromTheMatchedReplay() async throws {
        let report = try await makeAIAdapterReport()
        let reference = try confirmedAIReferenceDraft().validated(now: aiReferenceNow)
        let plain = try await AIInsightReportAdapter.prepare(report)
        let input = try await AIInsightReportAdapter.prepare(report, reference: reference)
        try input.validate()
        #expect(Array(input.metrics.prefix(plain.metrics.count)) == plain.metrics)
        #expect(Array(input.sources.prefix(plain.sources.count)) == plain.sources)
        #expect(input.metrics.count == 41 && input.sources.count == 4)
        let metrics = Dictionary(uniqueKeysWithValues: input.metrics.map { ($0.id, $0) })
        #expect(metrics["reference.price"]?.value == "10")
        #expect(metrics["reference.shares"]?.value == "100")
        #expect(metrics["reference.marketCap"]?.value == "1000")
        #expect(metrics["reference.ps"]?.value == "2.5")
        #expect(metrics["reference.pfcf"]?.value == "12.5")
        // NetIncomeLoss exists in this fixture, but common-income does not; no substitution.
        #expect(metrics["reference.pe"]?.value == nil)
        #expect(metrics["reference.pe"]?.unavailable == "missingInput")
        #expect(metrics["reference.ps"]?.label.contains("TTM 2024-01-01—2024-12-31") == true)
        let context = try #require(input.referenceValuation)
        #expect(context.referenceAt == (try AIInsightReportAdapter.utcCutoff(reference.referenceAt)))
        #expect(context.sharesAsOf == "2024-12-31")
        #expect(input.sources.last?.id == "local.userReference")
        #expect(input.sources.last?.label.contains("股本未认证") == true)
        #expect(try input.digest() != plain.digest())
    }

    @Test func referenceBeforeFinancialCutoffIsRejectedAtOriginalPrecision() async throws {
        let report = try await makeAIAdapterReport()
        var past = confirmedAIReferenceDraft()
        past.referenceAt = report.cutoff.addingTimeInterval(-0.0002)
        let reference = try past.validated(now: aiReferenceNow)
        await #expect(throws: AIInsightReportAdapterError.referencePredatesFinancialEvidence) {
            try await AIInsightReportAdapter.prepare(report, reference: reference)
        }
        var equal = confirmedAIReferenceDraft(); equal.referenceAt = report.cutoff
        let allowed = try await AIInsightReportAdapter.prepare(report,
            reference: equal.validated(now: aiReferenceNow))
        #expect(allowed.referenceValuation?.referenceAt == (try AIInsightReportAdapter.utcCutoff(report.cutoff)))
        // Reference assumptions remain optional; rejecting a past reference does not
        // prevent the same report from providing a financial-only interpretation.
        let financialOnly = try await AIInsightReportAdapter.prepare(report)
        #expect(financialOnly.referenceValuation == nil)
    }

    @Test func referenceMultiplesUseExactDecimalsAndRefuseMissingOrNonpositiveDenominators() throws {
        var draft = confirmedAIReferenceDraft(); draft.price = "10.125"; draft.shares = "100"
        let reference = try draft.validated(now: aiReferenceNow)
        let full = try AIInsightReportAdapter.referenceMetrics(reference, commonIncome: Money("100"),
            revenue: Money("400"), fcf: Money("80"), ttm: "TTM 2024-01-01—2024-12-31")
        let values = Dictionary(uniqueKeysWithValues: full.map { ($0.id, $0) })
        #expect(values["reference.marketCap"]?.value == "1012.5")
        #expect(values["reference.pe"]?.value == "10.125")
        #expect(values["reference.ps"]?.value == "2.53125")
        #expect(values["reference.pfcf"]?.value == "12.65625")
        let denominators: [Money?] = [nil, try Money("0"), try Money("-10")]
        for denominator in denominators {
            let rows = try AIInsightReportAdapter.referenceMetrics(reference, commonIncome: denominator,
                revenue: denominator, fcf: denominator, ttm: "TTM 2024-01-01—2024-12-31")
            let multiples = rows.filter { ["reference.pe", "reference.ps", "reference.pfcf"].contains($0.id) }
            #expect(multiples.count == 3)
            #expect(multiples.allSatisfy { $0.value == nil && $0.unavailable == (denominator == nil ? "missingInput" : "nonpositiveDenominator") })
            #expect(rows.first { $0.id == "reference.marketCap" }?.value == "1012.5")
        }
    }

    @Test func subprecisionReferenceMultipleIsUnavailableWithoutInvalidatingFinancialSummary() async throws {
        var draft = confirmedAIReferenceDraft(); draft.price = "0.000000000000000001"; draft.shares = "1"
        let reference = try draft.validated(now: aiReferenceNow)
        let tinyRows = try AIInsightReportAdapter.referenceMetrics(reference, commonIncome: Money("2"),
            revenue: Money("400"), fcf: Money("80"), ttm: "TTM 2024-01-01—2024-12-31")
        let tinyMultiples = tinyRows.filter { ["reference.pe", "reference.ps", "reference.pfcf"].contains($0.id) }
        #expect(tinyMultiples.count == 3)
        #expect(tinyMultiples.allSatisfy { $0.value == nil && $0.unavailable == "belowCalculationPrecision" })
        let boundary = try AIInsightReportAdapter.referenceMetrics(reference, commonIncome: Money("1"),
            revenue: Money("1"), fcf: Money("1"), ttm: "TTM 2024-01-01—2024-12-31")
        #expect(boundary.filter { $0.unit == "multiple" }.allSatisfy {
            $0.value == "0.000000000000000001" && $0.unavailable == nil
        })
        let input = try await AIInsightReportAdapter.prepare(makeAIAdapterReport(), reference: reference)
        try input.validate()
        _ = try input.encoded()
        #expect(input.metrics.first { $0.id == "base.revenue" }?.value == "400")
        #expect(input.metrics.first { $0.id == "reference.marketCap" }?.value == "0.000000000000000001")
        #expect(input.metrics.first { $0.id == "reference.pe" }?.unavailable == "missingInput")
        for key in ["reference.ps", "reference.pfcf"] {
            let value = try #require(input.metrics.first { $0.id == key })
            #expect(value.value == nil && value.unavailable == "belowCalculationPrecision")
        }
    }

    @Test func referencePacketKeepsManualAssumptionsSeparateAndExcludesPrivateEvidence() async throws {
        let marker = "SECRET-NOT-FOR-AI:/Users/private/account:Bearer-example"
        let parent = try await secFinancialReportFixtureParent(filingHTML: "<p>" + marker + "</p>")
        let report = try await SECFinancialReportDocument.make(parent: parent, parentBytes: ResearchDocument.encoded(parent),
            executionDate: parent.cutoff.addingTimeInterval(1))
        let reference = try confirmedAIReferenceDraft().validated(now: aiReferenceNow)
        let input = try await AIInsightReportAdapter.prepare(report, reference: reference)
        let bytes = try input.encoded(), text = String(decoding: bytes, as: UTF8.self)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == Set(["format", "ticker", "companyName", "periodEnd", "cutoff", "metrics", "sources", "referenceValuation"]))
        for forbidden in [marker, "synthetic@example.invalid", parent.id.uuidString, report.id.uuidString,
                          report.parentDocumentHash, "inputSnapshot", "licenseRef", "evidenceRef", "sourceValue",
                          "weightedAverage", "alpaca", "portfolio", "holding", "apiKey"] {
            #expect(!text.contains(forbidden))
        }
        let rows = input.metrics.filter { $0.id.hasPrefix("reference.") }
        #expect(Set(rows.map(\.id)) == Set(["reference.price", "reference.shares", "reference.marketCap", "reference.pe", "reference.ps", "reference.pfcf"]))
        #expect(rows.allSatisfy { $0.sourceIDs == ["local.userReference"] })
        #expect(input.referenceValuation?.origin == AIInsightReferenceValuationContext.authorizedOrigin)
    }
}

private let aiReferenceNow = Date(timeIntervalSince1970: 1_791_072_000)

private func confirmedAIReferenceDraft() -> AIValuationReferenceDraft {
    var value = AIValuationReferenceDraft(now: aiReferenceNow)
    value.price = "10"; value.shares = "100"; value.sharesAsOf = "2024-12-31"
    value.confirmedSingleClassSameBasis = true; value.maySendReferenceData = true
    return value
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
