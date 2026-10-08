import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

private func shareCountSource(_ literal: String) throws -> (SECValuationSourceMaterial, SECValuationSourceAnchor) {
    // Entirely invented evidence. This fixture is not copied from an issuer filing.
    let bytes = Data(("SYNTHETIC common class A has " + literal + " unscaled shares.").utf8)
    let source = try SECValuationSourceMaterial(reference: "synthetic/count-excerpt", contentHash: digest(bytes), bytes: bytes)
    let excerpt = Data(literal.utf8), range = try #require(bytes.range(of: excerpt))
    let anchor = try SECValuationSourceAnchor(sourceReference: source.reference, sourceHash: source.contentHash,
                                            byteOffset: range.lowerBound, excerpt: excerpt)
    return (source, anchor)
}

@Suite struct SECUnscaledShareCountEvidenceTests {
    @Test func groupedUnscaledCountRetainsExactSourceBytes() throws {
        let (source, anchor) = try shareCountSource("1,234,567")
        let share = try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234567"),
                                              countAnchor: anchor, identityAnchors: [anchor])
        try share.validate()
        try share.countAnchor.validate(source: source)
        #expect(share.outstandingShares == (try Money("1234567")))
        #expect(share.countAnchor.excerpt == Data("1,234,567".utf8))
        #expect(share.countParsingPolicy == "unscaled-ascii-comma-groups.v1")
    }

    @Test func legacyPlainDigitsKeepTheOriginalFiveFieldEncoding() throws {
        let (_, anchor) = try shareCountSource("1234567")
        let share = try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234567"),
                                              countAnchor: anchor, identityAnchors: [anchor])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Recreate the pre-change five-field payload independently of the struct's encoder.
        let fields: [String: Any] = ["classID": "A", "symbol": "AAPL", "outstandingShares": "1234567",
            "countAnchor": try JSONSerialization.jsonObject(with: encoder.encode(anchor)),
            "identityAnchors": [try JSONSerialization.jsonObject(with: encoder.encode(anchor))]]
        let original = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(SECReviewedShareClass.self, from: original)
        try decoded.validate()
        #expect(try encoder.encode(decoded) == original)
        #expect(try encoder.encode(share) == original)
    }

    @Test func sharedParserPreservesExactLargeIntegersWithoutRounding() throws {
        #expect(try SECUnscaledShareCountExcerpt.parse("1234567") == Money("1234567"))
        #expect(try SECUnscaledShareCountExcerpt.parse("1,234,567") == Money("1234567"))
        #expect(try SECUnscaledShareCountExcerpt.parse("12,345") == Money("12345"))
        #expect(try SECUnscaledShareCountExcerpt.parse("123,456") == Money("123456"))
        #expect(try SECUnscaledShareCountExcerpt.parse("12,345,678,901,234,567,890,123,456,789,012,345,678")
                == Money("12345678901234567890123456789012345678"))
        #expect(throws: SECValuationError.invalidEvidence) {
            try SECUnscaledShareCountExcerpt.parse("123,456,789,012,345,678,901,234,567,890,123,456,789")
        }
    }

    @Test func legacyLeadingZerosWereAlreadyRejectedByTheUnchangedMoneyContract() throws {
        // The old class used both ^[0-9]+$ AND Money(raw). Passing that regex alone was never
        // enough: Money has always rejected leading zeros, so no valid legacy record is lost.
        let literal = "00123"
        #expect(literal.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil)
        #expect(throws: MoneyError.invalidDecimal) { try Money(literal) }
        let (_, anchor) = try shareCountSource(literal)
        let encoder = JSONEncoder()
        let legacy: [String: Any] = ["classID": "A", "symbol": "AAPL", "outstandingShares": "123",
            "countAnchor": try JSONSerialization.jsonObject(with: encoder.encode(anchor)),
            "identityAnchors": [try JSONSerialization.jsonObject(with: encoder.encode(anchor))]]
        #expect(throws: SECValuationError.invalidEvidence) {
            try JSONDecoder().decode(SECReviewedShareClass.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
    }

    @Test(arguments: ["", "0", "0,000", "01", "01,234", "1234,567", "1,23", "1,2345", "1,,234", ",123",
                      "123,", "1,234.0", "1234.5", "+1234", "-1234", "1e3", "1E+3", "1 234", "1_234",
                      " 1234", "1234 ", "1234\n", "１２３４", "1，234", "1\u{00a0}234", "1,234 shares",
                      "1,234 million", "1,234×1000", "<b>1234</b>", "1&#44;234"])
    func malformedOrScaledExcerptsCannotAcquireCountMeaning(_ literal: String) throws {
        #expect(throws: SECValuationError.invalidEvidence) { try SECUnscaledShareCountExcerpt.parse(literal) }
    }

    @Test func groupedEncodingRequiresItsPolicyAndRejectsUnsupportedInterpretations() throws {
        let (_, anchor) = try shareCountSource("1,234,567")
        let share = try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234567"),
                                              countAnchor: anchor, identityAnchors: [anchor])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(share)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["countParsingPolicy"] as? String == "unscaled-ascii-comma-groups.v1")
        #expect(try encoder.encode(JSONDecoder().decode(SECReviewedShareClass.self, from: encoded)) == encoded)
        func decode(_ changed: [String: Any]) throws -> SECReviewedShareClass {
            try JSONDecoder().decode(SECReviewedShareClass.self, from: JSONSerialization.data(withJSONObject: changed))
        }
        var changed = fields; changed.removeValue(forKey: "countParsingPolicy")
        #expect(throws: SECValuationError.invalidEvidence) { try decode(changed) }
        changed = fields; changed["countParsingPolicy"] = "scaled-millions.v1"
        #expect(throws: SECValuationError.unsupportedFormat) { try decode(changed) }
        changed = fields; changed["countParsingPolicy"] = NSNull()
        #expect(throws: (any Error).self) { try decode(changed) }
        changed = fields; changed["scale"] = 6
        #expect(throws: SECValuationError.unsupportedFormat) { try decode(changed) }
        changed = fields; changed["multiplier"] = "1000"
        #expect(throws: SECValuationError.unsupportedFormat) { try decode(changed) }
        changed = fields; changed["outstandingShares"] = "1234567000"
        #expect(throws: SECValuationError.invalidEvidence) { try decode(changed) }
    }

    @Test func groupedCountCannotChangeTheAnchoredValueOrBypassSourceBytes() throws {
        let (source, anchor) = try shareCountSource("1,234,567")
        #expect(throws: SECValuationError.invalidEvidence) {
            try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234568"),
                                      countAnchor: anchor, identityAnchors: [anchor])
        }
        #expect(throws: SECValuationError.invalidEvidence) {
            try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234567.5"),
                                      countAnchor: anchor, identityAnchors: [anchor])
        }
        let ungroupedAnchor = try SECValuationSourceAnchor(sourceReference: source.reference, sourceHash: source.contentHash,
            byteOffset: anchor.byteOffset, excerpt: Data("1234567".utf8))
        let validNumberWrongBytes = try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234567"),
            countAnchor: ungroupedAnchor, identityAnchors: [anchor])
        #expect(throws: SECValuationError.sourceMismatch) { try validNumberWrongBytes.countAnchor.validate(source: source) }
    }

    @Test func groupedEvidenceRoundTripReplaysWithoutFillingIndustrySplitOrPriceGaps() async throws {
        let records = try secFinancialFixtureRecords()
        let accounting = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts, submissions: records.submissions,
            cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
        let originalAccountingBytes = try SECFinancialReport.bytes(accounting)
        let (source, anchor) = try shareCountSource("1,234,567")
        let share = try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("1234567"),
                                              countAnchor: anchor, identityAnchors: [anchor])
        let execution = secFinancialFixtureCutoff.addingTimeInterval(10)
        let classes = try SECShareClassReview(cik: accounting.evidence.cik, coverDate: MarketDate(iso8601: "2025-12-31"),
            accessionNumber: "0000320193-25-000004", classes: [share], completenessAnchors: [anchor], reviewedAt: execution,
            rationale: "Synthetic local interpretation; no real issuer or source admission")
        let report = try await SECValuationReport.make(accounting: accounting, evidence: .init(shareClasses: classes),
                                                      sources: [source], executionDate: execution)
        let encoded = try SECFinancialReport.bytes(report)
        let decoded = try JSONDecoder().decode(SECValuationReport.self, from: encoded)
        try decoded.validate(); try decoded.validateSources([source])
        let replay = try await decoded.recompute()
        #expect(try decoded.cachedReportMatches(replay))
        #expect(try SECFinancialReport.bytes(decoded.accounting) == originalAccountingBytes)
        #expect(try SECFinancialReport.bytes(decoded) == encoded)
        #expect(decoded.evidence.shareClasses?.classes.first?.countAnchor.excerpt == Data("1,234,567".utf8))
        #expect(decoded.assessment.gaps.contains(.industryMissing))
        #expect(decoded.assessment.gaps.contains(.splitBasisMissing))
        #expect(decoded.assessment.gaps.contains(.priceSourceMissing))
        #expect(decoded.results.reference == nil && decoded.results.score == nil)
        #expect(decoded.results.base.metrics["roic"]?.unavailable == .missingEvidence)
        #expect(decoded.results.base.metrics["netDebtEBITDA"]?.unavailable == .missingEvidence)
        #expect(!decoded.productionEligible && !decoded.historicalPITQualified)
    }
}
