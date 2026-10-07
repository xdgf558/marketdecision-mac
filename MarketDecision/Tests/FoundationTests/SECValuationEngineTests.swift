import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

private let valuationFixtureExecution = secFinancialFixtureCutoff.addingTimeInterval(10)

private struct ValuationFixture {
    let accounting: SECFinancialReport
    let source: SECValuationSourceMaterial
    let industry: SECIndustryReview
    let shares: SECShareClassReview
    let split: SECSplitBasisReview
    let prices: [SECValuationPriceEvidence]
    var evidence: SECValuationInputEvidence {
        .init(industryReview: industry, shareClasses: shares, splitBasis: split, prices: prices)
    }
    func report(_ evidence: SECValuationInputEvidence? = nil) async throws -> SECValuationReport {
        try await .make(accounting: accounting, evidence: evidence ?? self.evidence, sources: [source], executionDate: valuationFixtureExecution)
    }
}

private func valuationFixture(twoClasses: Bool = false, rich: Bool = false, side: SECReferencePriceSide = .ask) async throws -> ValuationFixture {
    var records = try secFinancialFixtureRecords()
    if rich { try enrichValuationFixture(&records) }
    let accounting = try await SECFinancialReport.make(cik: "0000320193", facts: records.facts, submissions: records.submissions,
        cutoff: secFinancialFixtureCutoff, executionDate: secFinancialFixtureCutoff)
    let text = "SYNTHETIC retained evidence. General nonfinancial industrial operations. All common classes: A with 100 shares, B with 250 shares. Already reported on the same share basis; no conversion applies."
    let data = Data(text.utf8)
    let source = try SECValuationSourceMaterial(reference: "synthetic/retained-disclosure", contentHash: digest(data), bytes: data)
    func anchor(_ value: String) throws -> SECValuationSourceAnchor {
        let excerpt = Data(value.utf8), range = try #require(data.range(of: excerpt))
        return try .init(sourceReference: source.reference, sourceHash: source.contentHash, byteOffset: range.lowerBound, excerpt: excerpt)
    }
    let industry = try SECIndustryReview(applicability: .generalNonFinancial, reviewedAt: valuationFixtureExecution,
        rationale: "Synthetic test user's explicit interpretation", anchors: [anchor("General nonfinancial industrial operations.")])
    var classes = [try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("100"),
        countAnchor: anchor("100"), identityAnchors: [anchor("A with 100 shares")])]
    if twoClasses {
        classes.append(try SECReviewedShareClass(classID: "B", symbol: "AAPB", outstandingShares: Money("250"),
            countAnchor: anchor("250"), identityAnchors: [anchor("B with 250 shares")]))
    }
    let shares = try SECShareClassReview(cik: accounting.evidence.cik, coverDate: MarketDate(iso8601: "2025-12-31"),
        accessionNumber: "0000320193-25-000004", classes: classes,
        completenessAnchors: [anchor("All common classes: A with 100 shares, B with 250 shares.")],
        reviewedAt: valuationFixtureExecution, rationale: "Synthetic reviewed full class set for test")
    let factIDs = Array(Set(accounting.inputSnapshot.financials.input.normalization.values.filter {
        $0.unit == "USD/shares" || $0.unit == "shares"
    }.flatMap(\.sourceFactIDs))).sorted()
    let split = try SECSplitBasisReview(classIDs: classes.map(\.classID), windowStart: MarketDate(iso8601: "2024-01-01"),
        basisDate: MarketDate(iso8601: "2026-10-03"), coveredFactIDs: factIDs,
        anchors: [anchor("Already reported on the same share basis; no conversion applies.")],
        reviewedAt: valuationFixtureExecution, rationale: "Synthetic same-basis interpretation; no arithmetic adjustment")
    let prices = try classes.map { item in
        try valuationPrice(classID: item.classID, symbol: item.symbol, bid: item.classID == "A" ? "9" : "19",
                           ask: item.classID == "A" ? "10" : "20", side: side)
    }
    return .init(accounting: accounting, source: source, industry: industry, shares: shares, split: split, prices: prices)
}

private func valuationPrice(classID: String, symbol: String, bid: String, ask: String,
                            side: SECReferencePriceSide) throws -> SECValuationPriceEvidence {
    let requestTime = secFinancialFixtureCutoff.addingTimeInterval(4), received = secFinancialFixtureCutoff.addingTimeInterval(5)
    let timestamp = "2026-10-04T00:00:04Z"
    let raw = Data("{\"symbol\":\"\(symbol)\",\"quote\":{\"t\":\"\(timestamp)\",\"bp\":\(bid),\"ap\":\(ask),\"bs\":2,\"as\":3,\"bx\":\"V\",\"ax\":\"V\"}}".utf8)
    let source = try SECValuationSourceMaterial(reference: "synthetic/quote/" + symbol, contentHash: digest(raw), bytes: raw)
    let quote = try EquityQuoteValues(bid: Money(bid), ask: Money(ask), bidSize: Money("2"), askSize: Money("3"), bidExchange: "V", askExchange: "V")
    let rights = try SECCapturedPriceRights(entitlementVersion: "synthetic-rights.v1", evidenceReference: "synthetic-scope",
        licenseReference: "synthetic-only", recordedAt: secFinancialFixtureCutoff, validFrom: secFinancialFixtureCutoff,
        validThrough: secFinancialFixtureCutoff.addingTimeInterval(3_600), assertion: "SYNTHETIC rights fixture, no live entitlement",
        evidenceBytes: Data("SYNTHETIC personal local reference and retention test".utf8))
    let request = ProviderRequest(providerID: "alpaca", feedID: "iex", resourceID: symbol, capability: .quote, mode: .latest,
        usage: .replay, configurationVersion: "alpaca-iex-raw-daily.v1", entitlementVersion: rights.entitlementVersion, requestedAt: requestTime)
    let provenance = try Provenance(providerID: "alpaca", feedID: "iex", sourceEventAt: EquityRecord.sourceTime(timestamp),
        receivedAt: received, availableAt: nil, evidenceRef: rights.evidenceReference, origin: .provider,
        endpointDescriptor: EndpointDescriptor.quote.rawValue, requestedAt: requestTime, requestID: request.id,
        observationDate: MarketDate(iso8601: "2026-10-03"),
        versionID: EquityRecord.contentVersion(symbol: symbol, timestamp: timestamp, quote: quote, bar: nil), versionKind: .localContent,
        availability: .unknown, rawObjectRef: source.reference, rawHash: source.contentHash,
        normalizationVersion: "equity.raw-iex.v1", licenseRef: rights.licenseReference)
    let record = try EquityRecord(symbol: symbol, sourceTimestamp: timestamp, quote: quote, provenance: provenance)
    return try .init(classID: classID, record: record, request: request, rawSource: source, rights: rights,
                     selectedSide: side, captureOrigin: .syntheticFixture)
}

private func valuationChanged<T: Codable>(_ value: T, _ transform: (inout [String: Any]) throws -> Void) throws -> T {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    try transform(&object)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

private func enrichValuationFixture(_ records: inout (facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord])) throws {
    let flows: [(String, String)] = [("ShareBasedCompensation", "0.5"), ("InterestExpense", "1"),
        ("IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest", "5"),
        ("IncomeTaxExpenseBenefit", "1"), ("DepreciationDepletionAndAmortization", "1")]
    let instants: [(String, String)] = [("Assets", "100"), ("AssetsCurrent", "50"), ("LiabilitiesCurrent", "25"),
        ("CashAndCashEquivalentsAtCarryingValue", "10"), ("StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest", "50"),
        ("ShortTermBorrowings", "1"), ("LongTermDebtCurrent", "2"), ("LongTermDebtNoncurrent", "10"),
        ("FinanceLeaseLiability", "1"), ("OperatingLeaseLiability", "5")]
    func append(_ template: SECCompanyFactRecord, concept: String, value: String, start: MarketDate?, end: MarketDate, unit: String = "USD") throws {
        let id = concept + "/" + (start?.iso8601 ?? "instant") + "/" + end.iso8601
        let p = template.provenance
        let provenance = Provenance(providerID: p.providerID, feedID: p.feedID, sourceEventAt: p.sourceEventAt, receivedAt: p.receivedAt,
            availableAt: nil, evidenceRef: p.evidenceRef, origin: p.origin, endpointDescriptor: p.endpointDescriptor,
            requestedAt: p.requestedAt, requestID: p.requestID, observationDate: end, versionID: "rich/" + id,
            versionKind: .sourceVersion, availability: p.availability, rawObjectRef: p.rawObjectRef, rawHash: p.rawHash,
            normalizationVersion: p.normalizationVersion, licenseRef: p.licenseRef)
        records.facts.append(try SECCompanyFactRecord(recordID: id, factID: id, cik: template.cik, taxonomy: "us-gaap", concept: concept,
            label: concept, description: "Synthetic rich accounting coverage", unit: unit, sourceValue: value, value: Money(value),
            startDate: start, endDate: end, periodKind: start == nil ? .instant : .duration, accessionNumber: template.accessionNumber,
            form: template.form, filedDate: template.filedDate, fiscalYear: end.year, fiscalPeriod: start == nil ? nil : "FY",
            frame: nil, provenance: provenance))
    }
    let templates = records.facts.filter { $0.concept == "OperatingIncomeLoss" }
    for template in templates {
        let q = template.endDate.month / 3
        for (concept, scale) in flows {
            try append(template, concept: concept, value: Money(scale).multiplied(by: String(q)).decimalString,
                       start: template.startDate, end: template.endDate)
        }
        for (concept, value) in instants { try append(template, concept: concept, value: value, start: nil, end: template.endDate) }
        let start = try MarketDate(iso8601: "\(template.endDate.year)-" + ["01-01", "04-01", "07-01", "10-01"][q - 1])
        try append(template, concept: "EarningsPerShareDiluted", value: "1", start: start, end: template.endDate, unit: "USD/shares")
    }
    let boundary = try MarketDate(iso8601: "2023-12-31"), template = try #require(templates.first)
    for (concept, value) in instants { try append(template, concept: concept, value: value, start: nil, end: boundary) }
}

@Suite struct SECValuationEngineTests {
    @Test func emptyEvidenceKeepsUnknownIndustryAndAllValuationGaps() async throws {
        let fixture = try await valuationFixture(), report = try await fixture.report(.init())
        #expect(report.assessment.industry == .unknown)
        #expect(report.results.score == nil && report.results.reference == nil)
        #expect(report.results.base.metrics["roic"]?.unavailable == .missingEvidence)
        #expect(report.assessment.gaps.contains(.priceSourceMissing))
        #expect(report.assessment.gaps.contains(.historicalValuationUnavailable))
        #expect(!report.historicalPITQualified && !report.productionEligible)
    }
    @Test(arguments: [SECIndustryApplicability.financial, .reit, .specialized])
    func excludedIndustriesNeverGetGeneralScore(industry: SECIndustryApplicability) async throws {
        let fixture = try await valuationFixture()
        let review = try SECIndustryReview(applicability: industry, reviewedAt: valuationFixtureExecution,
            rationale: "Explicit synthetic specialized issuer review", anchors: fixture.industry.anchors)
        let report = try await fixture.report(.init(industryReview: review))
        #expect(report.results.score == nil && report.results.reference == nil)
        #expect(report.results.base.metrics["roic"]?.unavailable == .notApplicable)
        #expect(report.results.base.metrics["netDebtEBITDA"]?.unavailable == .notApplicable)
    }
    @Test func twoClassReferenceUsesEachOwnSelectedPriceAndNeverUpgradesMarketPIT() async throws {
        let fixture = try await valuationFixture(twoClasses: true), report = try await fixture.report()
        #expect(report.results.reference?.metrics["marketCap"]?.value == (try Money("6000"))) // 100*10 + 250*20
        #expect(report.results.reference?.metrics["priceSales"]?.value == (try Money("60")))
        #expect(report.results.reference?.metrics["priceFCF"]?.value == (try Money("300")))
        #expect(report.results.reference?.metrics["peEPS"]?.unavailable == .missingClass)
        #expect(report.results.base.metrics["marketCap"]?.value == nil)
        #expect(report.inputSnapshot.financials.input.classes.isEmpty)
        #expect(report.inputSnapshot.financials.input.normalization.asOf == fixture.accounting.cutoff)
        #expect(report.evidence.prices.allSatisfy { $0.record.provenance.availability == .unknown && $0.record.provenance.versionKind == .localContent })
        #expect(report.results.score?.valuation.historyInputs.isEmpty == true)
        #expect(report.results.score?.valuation.metrics.values.allSatisfy { $0.prices.isEmpty && $0.validDays == 0 } == true)
        #expect(report.assessment.referenceScenarioOnly && !report.assessment.historicalPITQualified && !report.assessment.productionEligible)
    }
    @Test func explicitBidChoiceChangesOnlyReferenceScenario() async throws {
        let ask = try await valuationFixture(), bid = try await valuationFixture(side: .bid)
        let a = try await ask.report(), b = try await bid.report()
        #expect(a.results.reference?.metrics["marketCap"]?.value == (try Money("1000")))
        #expect(b.results.reference?.metrics["marketCap"]?.value == (try Money("900")))
        #expect(try SECFinancialReport.bytes(a.results.score) == SECFinancialReport.bytes(b.results.score))
    }
    @Test func incompleteClassPricesRemainMissingRatherThanApproximating() async throws {
        let f = try await valuationFixture(twoClasses: true)
        let report = try await f.report(.init(industryReview: f.industry, shareClasses: f.shares, splitBasis: f.split, prices: [f.prices[0]]))
        #expect(report.results.reference == nil)
        #expect(report.assessment.gaps.contains(.incompleteClassPrices))
        #expect(!report.assessment.currentReferenceCapitalAvailable)
    }
    @Test func missingSplitBasisPreservesEvidenceButRefusesCapitalReference() async throws {
        let f = try await valuationFixture()
        let report = try await f.report(.init(industryReview: f.industry, shareClasses: f.shares, prices: f.prices))
        #expect(report.results.reference == nil && !report.assessment.perShareBasisAvailable)
        #expect(report.assessment.gaps.contains(.splitBasisMissing))
    }
    @Test func literalShareCountsCannotBeFractionalOrUnbound() async throws {
        let f = try await valuationFixture(), item = f.shares.classes[0]
        #expect(throws: SECValuationError.invalidEvidence) {
            try SECReviewedShareClass(classID: item.classID, symbol: item.symbol, outstandingShares: Money("100.5"),
                countAnchor: item.countAnchor, identityAnchors: item.identityAnchors)
        }
        #expect(throws: SECValuationError.invalidEvidence) {
            try SECReviewedShareClass(classID: item.classID, symbol: item.symbol, outstandingShares: Money("101"),
                countAnchor: item.countAnchor, identityAnchors: item.identityAnchors)
        }
    }
    @Test func sourceExcerptHashAndOffsetAreValidatedAgainstImmutableBytes() async throws {
        let f = try await valuationFixture()
        let bad = try SECValuationSourceAnchor(sourceReference: f.source.reference, sourceHash: f.source.contentHash,
            byteOffset: 0, excerpt: Data("fabricated industry declaration".utf8))
        let review = try SECIndustryReview(applicability: .generalNonFinancial, reviewedAt: valuationFixtureExecution,
            rationale: "Deliberately wrong synthetic excerpt", anchors: [bad])
        await #expect(throws: SECValuationError.sourceMismatch) { try await f.report(.init(industryReview: review)) }
    }
    @Test func capturedPriceRawValueMismatchCannotBeHiddenByAValidRecordHash() async throws {
        let f = try await valuationFixture(), price = f.prices[0]
        let bytes = Data(String(decoding: price.rawSource.bytes, as: UTF8.self).replacingOccurrences(of: "\"ap\":10", with: "\"ap\":11").utf8)
        let raw = try SECValuationSourceMaterial(reference: price.rawSource.reference, contentHash: digest(bytes), bytes: bytes)
        let altered = try valuationChanged(price) { object in
            object["rawSource"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw))
            var record = try #require(object["record"] as? [String: Any]), p = try #require(record["provenance"] as? [String: Any])
            p["rawHash"] = raw.contentHash; record["provenance"] = p; object["record"] = record
        }
        #expect(throws: SECValuationError.sourceMismatch) { try altered.validate(executionDate: valuationFixtureExecution) }
    }
    @Test func syntheticRightsCannotClaimProviderCaptureAndUnknownCannotBecomePIT() async throws {
        let f = try await valuationFixture()
        let changed = try valuationChanged(f.prices[0]) { $0["captureOrigin"] = "providerCapture" }
        #expect(throws: SECValuationError.unsupportedPrice) { try changed.validate(executionDate: valuationFixtureExecution) }
        let counterfeit = try valuationChanged(f.prices[0]) { object in
            var record = try #require(object["record"] as? [String: Any]), p = try #require(record["provenance"] as? [String: Any])
            p["availability"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AvailabilityEvidence.instant(secFinancialFixtureCutoff, evidence: "counterfeit receipt PIT")))
            record["provenance"] = p; object["record"] = record
        }
        #expect(throws: (any Error).self) { try counterfeit.validate(executionDate: valuationFixtureExecution) }
    }
    @Test func mismatchedRequestRightsAndStaleSourceAreRejected() async throws {
        let f = try await valuationFixture()
        let wrongRequest = try valuationChanged(f.prices[0]) { object in
            var request = try #require(object["request"] as? [String: Any]); request["resourceID"] = "MSFT"; object["request"] = request
        }
        #expect(throws: SECValuationError.unsupportedPrice) { try wrongRequest.validate(executionDate: valuationFixtureExecution) }
        let expired = try valuationChanged(f.prices[0]) { object in
            var rights = try #require(object["rights"] as? [String: Any]); rights["validThrough"] = secFinancialFixtureCutoff.timeIntervalSinceReferenceDate; object["rights"] = rights
        }
        #expect(throws: SECValuationError.unsupportedPrice) { try expired.validate(executionDate: valuationFixtureExecution) }
        let stale = try valuationChanged(f.prices[0]) { object in
            var record = try #require(object["record"] as? [String: Any]), p = try #require(record["provenance"] as? [String: Any])
            p["receivedAt"] = secFinancialFixtureCutoff.addingTimeInterval(100).timeIntervalSinceReferenceDate
            record["provenance"] = p; object["record"] = record
        }
        #expect(throws: SECValuationError.unsupportedPrice) { try stale.validate(executionDate: secFinancialFixtureCutoff.addingTimeInterval(200)) }
    }
    @Test func ordinaryIndustryCanMeetOriginalScoreCoverageWithoutMarketPrices() async throws {
        let f = try await valuationFixture(rich: true)
        let report = try await f.report(.init(industryReview: f.industry, shareClasses: f.shares, splitBasis: f.split))
        let score = try #require(report.results.score)
        #expect(score.total != nil)
        #expect(score.coveredWeightOf84 == 60)
        #expect(score.dimensions["valuation"]?.value == nil)
        #expect(score.dimensions["capitalAllocation"]?.value == nil)
        #expect(report.results.reference == nil && report.assessment.gaps.contains(.priceSourceMissing))
        #expect(score.confidence == .medium)
        #expect(score.limitations.contains("UNCALIBRATED_HEURISTIC"))
    }
    @Test func roundTripReplaysAndDetectsTamperedReferenceCache() async throws {
        let f = try await valuationFixture(), original = try await f.report()
        let saved = try JSONDecoder().decode(SECValuationReport.self, from: JSONEncoder().encode(original))
        try saved.validateSources([f.source]); try saved.validateAccounting(f.accounting)
        #expect(try await saved.cachedReportMatches(saved.recompute()))
        let changed = try valuationChanged(saved) { object in
            var results = try #require(object["results"] as? [String: Any]), reference = try #require(results["reference"] as? [String: Any])
            var metrics = try #require(reference["metrics"] as? [String: Any]), cap = try #require(metrics["marketCap"] as? [String: Any])
            cap["value"] = "999"; metrics["marketCap"] = cap; reference["metrics"] = metrics; results["reference"] = reference; object["results"] = results
        }
        #expect(try await !changed.cachedReportMatches(changed.recompute()))
    }
    @Test func wrongSplitPolicyCoverageAndShareIssuerReject() async throws {
        let f = try await valuationFixture(rich: true)
        #expect(throws: SECValuationError.invalidEvidence) {
            try valuationChanged(f.split) { $0["policy"] = "apply-split-factor-again.v1" }
        }
        #expect(throws: SECValuationError.unsupportedFormat) {
            try valuationChanged(f.split) { $0["adjustmentFactor"] = "2" }
        }
        let missingFact = try valuationChanged(f.split) { $0["coveredFactIDs"] = [] }
        await #expect(throws: SECValuationError.invalidEvidence) {
            try await f.report(.init(industryReview: f.industry, shareClasses: f.shares, splitBasis: missingFact))
        }
        let wrongIssuer = try valuationChanged(f.shares) { $0["cik"] = "0000789019" }
        await #expect(throws: SECValuationError.invalidEvidence) {
            try await f.report(.init(industryReview: f.industry, shareClasses: wrongIssuer))
        }
    }
}
