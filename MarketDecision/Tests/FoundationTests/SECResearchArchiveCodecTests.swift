import Foundation
import Testing
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

private let secArchiveConsent = SECLocalArchiveConsent.personalLocalBackup

private struct SECArchiveCodecFixture {
    let state: SECArchiveState
    let research: SECResearchDocument
    let report: SECFinancialReportDocument
    let supplement: SECValuationSupplementDocument
}

private func secArchiveCodecFixture() async throws -> SECArchiveCodecFixture {
    let research = try await secFinancialReportFixtureParent(filingHTML: secArchiveShareDisclosure)
    func pretty<T: Encodable>(_ value: T) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: ResearchDocument.encoded(value)),
                                   options: [.prettyPrinted, .sortedKeys])
    }
    let researchBytes = try pretty(research)
    let report = try await SECFinancialReportDocument.make(parent: research, parentBytes: researchBytes,
        executionDate: research.cutoff.addingTimeInterval(1))
    let reportBytes = try pretty(report)
    let supplement = try await SECValuationSupplementDocument.make(parent: report, parentBytes: reportBytes,
        research: research, researchBytes: researchBytes, evidence: .init(),
        executionDate: research.cutoff.addingTimeInterval(10))
    return try .init(state: .init(research: researchBytes, reports: [reportBytes], supplements: [pretty(supplement)]),
                     research: research, report: report, supplement: supplement)
}

private func secArchiveJSON(_ bytes: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
    var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    try change(&json)
    return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}

private func secArchiveChangeManifest(_ archive: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
    var files = try ResearchZIP.decode(archive)
    files["manifest.json"] = try secArchiveJSON(#require(files["manifest.json"]), change)
    return try ResearchZIP.encode(files)
}

/// Manufactured IEX response/rights for scope refusal only. No account, request or real feed.
func secArchivePrice(cutoff: Date, origin: SECReferenceCaptureOrigin) throws -> SECValuationPriceEvidence {
    let requested = cutoff.addingTimeInterval(4), received = cutoff.addingTimeInterval(5)
    let timestamp = ISO8601DateFormatter().string(from: requested)
    let sourceTime = try EquityRecord.sourceTime(timestamp)
    var marketCalendar = Calendar(identifier: .gregorian)
    marketCalendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let day = marketCalendar.dateComponents([.year, .month, .day], from: sourceTime)
    let observationDate = try MarketDate(year: #require(day.year), month: #require(day.month), day: #require(day.day))
    let raw = Data("{\"symbol\":\"AAPL\",\"quote\":{\"t\":\"\(timestamp)\",\"bp\":9,\"ap\":10,\"bs\":2,\"as\":3,\"bx\":\"V\",\"ax\":\"V\"}}".utf8)
    let source = try SECValuationSourceMaterial(reference: "local/quote-test", contentHash: digest(raw), bytes: raw)
    let quote = try EquityQuoteValues(bid: Money("9"), ask: Money("10"), bidSize: Money("2"), askSize: Money("3"),
                                    bidExchange: "V", askExchange: "V")
    let rights = try SECCapturedPriceRights(entitlementVersion: "local-rights-test.v1", evidenceReference: "local-scope-test",
        licenseReference: "local-retention-test", recordedAt: cutoff, validFrom: cutoff,
        validThrough: cutoff.addingTimeInterval(3_600), assertion: "Test assertion of local capture retention only",
        evidenceBytes: Data("Manufactured local assertion, not provider certification".utf8))
    let request = ProviderRequest(providerID: "alpaca", feedID: "iex", resourceID: "AAPL", capability: .quote, mode: .latest,
        usage: .replay, configurationVersion: "alpaca-iex-raw-daily.v1", entitlementVersion: rights.entitlementVersion,
        requestedAt: requested)
    let provenance = try Provenance(providerID: "alpaca", feedID: "iex", sourceEventAt: sourceTime,
        receivedAt: received, availableAt: nil, evidenceRef: rights.evidenceReference, origin: .provider,
        endpointDescriptor: EndpointDescriptor.quote.rawValue, requestedAt: requested, requestID: request.id,
        observationDate: observationDate,
        versionID: EquityRecord.contentVersion(symbol: "AAPL", timestamp: timestamp, quote: quote, bar: nil),
        versionKind: .localContent, availability: .unknown, rawObjectRef: source.reference, rawHash: source.contentHash,
        normalizationVersion: "equity.raw-iex.v1", licenseRef: rights.licenseReference)
    let record = try EquityRecord(symbol: "AAPL", sourceTimestamp: timestamp, quote: quote, provenance: provenance)
    return try .init(classID: "A", record: record, request: request, rawSource: source, rights: rights,
                     selectedSide: .ask, captureOrigin: origin)
}

let secArchiveShareDisclosure = "<p>SYNTHETIC TEST ONLY. All common classes: Class A, AAPL, 100 shares.</p>"

func secArchivePricedEvidence(research: SECResearchDocument, origin: SECReferenceCaptureOrigin) throws -> SECValuationInputEvidence {
    let source = try #require(research.sources.first { $0.endpoint == .filingDocument })
    func anchor(_ text: String) throws -> SECValuationSourceAnchor {
        let excerpt = Data(text.utf8), range = try #require(source.bytes.range(of: excerpt))
        return try .init(sourceReference: source.reference, sourceHash: source.contentHash,
                         byteOffset: range.lowerBound, excerpt: excerpt)
    }
    let share = try SECReviewedShareClass(classID: "A", symbol: "AAPL", outstandingShares: Money("100"),
        countAnchor: anchor("100"), identityAnchors: [anchor("Class A, AAPL")])
    let filing = try #require(research.submissions.first { $0.form == "10-K" })
    let classes = try SECShareClassReview(cik: research.identity.cik, coverDate: #require(filing.reportDate),
        accessionNumber: filing.accessionNumber, classes: [share],
        completenessAnchors: [anchor("All common classes: Class A, AAPL, 100 shares.")],
        reviewedAt: research.cutoff, rationale: "Manufactured disclosure for archive scope rejection test only")
    return try .init(shareClasses: classes, prices: [secArchivePrice(cutoff: research.cutoff, origin: origin)])
}

@Suite struct SECResearchArchiveCodecTests {
    @Test func exactOriginalEncodingsAndSourceBytesSurviveArchiveAndExplicitReplay() async throws {
        let f = try await secArchiveCodecFixture()
        #expect(try f.state.research != ResearchDocument.encoded(f.research))
        let originalReportBytes = try #require(f.state.reports.first)
        #expect(try originalReportBytes != ResearchDocument.encoded(f.report))
        let archive = try SECResearchArchiveCodec.encode(f.state, consent: secArchiveConsent)
        let opened = try SECResearchArchiveCodec.decode(archive, consent: secArchiveConsent)
        #expect(opened.documentCount == 3)
        #expect(opened.research.bytes == f.state.research)
        #expect(opened.reports.map(\.bytes) == f.state.reports)
        #expect(opened.supplements.map(\.bytes) == f.state.supplements)
        #expect(opened.research.document.sources == f.research.sources)
        let report = try #require(opened.reports.first).document
        let supplement = try #require(opened.supplements.first).document
        #expect(report.parentDocumentHash == digest(opened.research.bytes))
        let openedReportBytes = try #require(opened.reports.first).bytes
        #expect(supplement.parentFinancialReportHash == digest(openedReportBytes))
        #expect(report.financials.cacheState == "requires-explicit-recompute")
        #expect(try await report.financials.cachedReportsMatch(report.financials.recompute()))
        #expect(try await supplement.valuation.cachedReportMatches(supplement.valuation.recompute()))
        #expect(!report.mayRunValuation && !supplement.valuation.productionEligible)
        #expect(!supplement.valuation.historicalPITQualified && supplement.valuation.evidence.prices.isEmpty)
        let files = try ResearchZIP.decode(archive)
        let manifestBytes = try #require(files["manifest.json"])
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        #expect(manifest["format"] as? String == "sec-local-archive.v1")
        #expect(manifest["consent"] as? String == secArchiveConsent.rawValue)
        let entries = try #require(manifest["sources"] as? [[String: Any]])
        #expect(Set(entries.compactMap { $0["sha256"] as? String }) == Set(f.research.sources.map(\.contentHash)))
    }

    @Test func researchWithoutCalculationsIsAValidBoundedArchive() async throws {
        let parent = try await secFinancialReportFixtureParent()
        let state = try SECArchiveState(research: ResearchDocument.encoded(parent), reports: [], supplements: [])
        let decoded = try SECResearchArchiveCodec.decode(SECResearchArchiveCodec.encode(state, consent: secArchiveConsent),
                                                        consent: secArchiveConsent)
        #expect(decoded.documentCount == 1 && decoded.reports.isEmpty && decoded.supplements.isEmpty)
        #expect(decoded.research.document.id == parent.id)
    }

    @Test func syntheticAndFixedExcerptArchiveProfilesRemainMutuallyExclusive() async throws {
        let f = try await secArchiveCodecFixture()
        let archive = try SECResearchArchiveCodec.encode(f.state, consent: secArchiveConsent)
        await #expect(throws: (any Error).self) { try await ResearchArchiveCodec.decode(archive) }
        #expect(throws: (any Error).self) { try OfflineIssuerResearchArchiveCodec.decode(archive) }
        let emptyGraph = SnapshotGraph(objects: [:], roots: [:])
        let synthetic = try ResearchArchiveCodec.encode(.init(graph: emptyGraph, watchlist: [], conflicts: []))
        let excerpts = try OfflineIssuerResearchArchiveCodec.encode(.init(graph: emptyGraph))
        for other in [synthetic, excerpts] {
            #expect(throws: SnapshotError.unsupportedFormat) {
                try SECResearchArchiveCodec.decode(other, consent: secArchiveConsent)
            }
        }
    }

    @Test func duplicateAndOrphanDocumentsCannotBeSilentlyDiscarded() async throws {
        let f = try await secArchiveCodecFixture()
        let duplicateReport = SECArchiveState(research: f.state.research, reports: f.state.reports + f.state.reports,
                                             supplements: f.state.supplements)
        let duplicateSupplement = SECArchiveState(research: f.state.research, reports: f.state.reports,
                                                 supplements: f.state.supplements + f.state.supplements)
        for state in [duplicateReport, duplicateSupplement] {
            #expect(throws: SnapshotError.duplicateObject) { try state.validate() }
        }
        #expect(throws: SnapshotError.missingReference) {
            try SECArchiveState(research: f.state.research, reports: [], supplements: f.state.supplements).validate()
        }
        let foreign = try secArchiveJSON(#require(f.state.reports.first)) { $0["parentDocumentID"] = UUID().uuidString }
        #expect(throws: SnapshotError.missingReference) {
            try SECArchiveState(research: f.state.research, reports: [foreign], supplements: []).validate()
        }
    }

    @Test func semanticallyEqualReencodedParentsStillBreakExactChildBindings() async throws {
        let f = try await secArchiveCodecFixture()
        let reencodedResearch = try ResearchDocument.encoded(f.research)
        let reencodedReport = try ResearchDocument.encoded(f.report)
        #expect(reencodedResearch != f.state.research && reencodedReport != f.state.reports.first)
        #expect(throws: SECFinancialError.inconsistentEvidence) {
            try SECArchiveState(research: reencodedResearch, reports: f.state.reports, supplements: []).validate()
        }
        #expect(throws: SECFinancialError.inconsistentEvidence) {
            try SECArchiveState(research: f.state.research, reports: [reencodedReport], supplements: f.state.supplements).validate()
        }
    }

    @Test func sourcePayloadTamperIsRejectedEvenWithoutCalculationChildren() async throws {
        let parent = try await secFinancialReportFixtureParent()
        for (field, value) in [
            ("bytes", Data("damaged retained response".utf8).base64EncodedString()),
            ("providerID", "other-provider"), ("feedID", "other-feed"),
            ("licenseRef", "different-retention-evidence")
        ] {
            let changed = try secArchiveJSON(ResearchDocument.encoded(parent)) { json in
                var sources = try #require(json["sources"] as? [[String: Any]])
                let index = try #require(sources.indices.first)
                sources[index][field] = value
                json["sources"] = sources
            }
            #expect(throws: SECResearchError.invalidDocument) {
                try SECResearchArchiveCodec.encode(.init(research: changed, reports: [], supplements: []), consent: secArchiveConsent)
            }
        }
    }

    @Test(arguments: [SECReferenceCaptureOrigin.syntheticFixture, .providerCapture])
    func anyCapturedPriceRequiresSeparateRightsAndRejectsWholeArchive(origin: SECReferenceCaptureOrigin) async throws {
        let f = try await secArchiveCodecFixture()
        let priced = try await SECValuationSupplementDocument.make(parent: f.report,
            parentBytes: #require(f.state.reports.first), research: f.research, researchBytes: f.state.research,
            evidence: secArchivePricedEvidence(research: f.research, origin: origin),
            executionDate: f.research.cutoff.addingTimeInterval(10))
        try priced.validate()
        let state = try SECArchiveState(research: f.state.research, reports: f.state.reports,
            supplements: f.state.supplements + [ResearchDocument.encoded(priced)])
        #expect(throws: SECArchiveError.scopeDenied) {
            try SECResearchArchiveCodec.encode(state, consent: secArchiveConsent)
        }
        // Rebuilding the outer checksum must not turn a price-bearing state into
        // an accepted import. The price-free siblings must not be imported alone.
        let encodedState = try ResearchDocument.encoded(state)
        var files = try ResearchZIP.decode(SECResearchArchiveCodec.encode(f.state, consent: secArchiveConsent))
        files["research-state.json"] = encodedState
        files["manifest.json"] = try secArchiveJSON(#require(files["manifest.json"])) {
            $0["sha256"] = digest(encodedState); $0["size"] = encodedState.count
        }
        let incoming = try ResearchZIP.encode(files)
        #expect(throws: SECArchiveError.scopeDenied) {
            try SECResearchArchiveCodec.decode(incoming, consent: secArchiveConsent)
        }
    }

    @Test func manifestScopeHashesAndDeclarationsCannotBeRetagged() async throws {
        let f = try await secArchiveCodecFixture()
        let archive = try SECResearchArchiveCodec.encode(f.state, consent: secArchiveConsent)
        let edits: [(inout [String: Any]) throws -> Void] = [
            { $0["scope"] = "full-product-backup" }, { $0["consent"] = "implicit" },
            { $0["application"] = "Other" }, { $0["sha256"] = String(repeating: "0", count: 64) },
            { $0["size"] = -1 }, { $0["documents"] = [] }, { $0["sources"] = [] },
            { $0["credentials"] = "not-an-allowed-section" }
        ]
        for edit in edits {
            let changed = try secArchiveChangeManifest(archive, edit)
            #expect(throws: (any Error).self) { try SECResearchArchiveCodec.decode(changed, consent: secArchiveConsent) }
        }
        var files = try ResearchZIP.decode(archive)
        let changed = try secArchiveJSON(#require(files["research-state.json"])) { $0["extraRecords"] = [] }
        files["research-state.json"] = changed
        files["manifest.json"] = try secArchiveJSON(#require(files["manifest.json"])) {
            $0["sha256"] = digest(changed); $0["size"] = changed.count
        }
        let injected = try ResearchZIP.encode(files)
        #expect(throws: SECArchiveError.invalidArchive) { try SECResearchArchiveCodec.decode(injected, consent: secArchiveConsent) }
    }

    @Test func countAndEmptyPayloadLimitsRejectBeforeDocumentDecoding() throws {
        let invalid = Data("not JSON".utf8)
        for state in [
            SECArchiveState(research: invalid, reports: Array(repeating: invalid, count: SECResearchArchiveCodec.maximumReports + 1), supplements: []),
            SECArchiveState(research: invalid, reports: [], supplements: Array(repeating: invalid, count: SECResearchArchiveCodec.maximumSupplements + 1)),
            SECArchiveState(research: Data(), reports: [], supplements: []),
            SECArchiveState(research: invalid, reports: [Data()], supplements: [])
        ] {
            #expect(throws: SnapshotError.resourceLimit) { try state.validate() }
        }
    }

    @Test func structurallyRetainedCacheStillRequiresExplicitNumericalReplay() async throws {
        let f = try await secArchiveCodecFixture()
        let changed = try secArchiveJSON(#require(f.state.reports.first)) { root in
            var financials = try #require(root["financials"] as? [String: Any])
            var base = try #require(financials["baseReport"] as? [String: Any])
            var metrics = try #require(base["metrics"] as? [String: Any])
            var revenue = try #require(metrics["revenue"] as? [String: Any])
            revenue["value"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Money("999")),
                                                               options: [.fragmentsAllowed])
            metrics["revenue"] = revenue; base["metrics"] = metrics
            financials["baseReport"] = base; root["financials"] = financials
        }
        let state = SECArchiveState(research: f.state.research, reports: [changed], supplements: [])
        let opened = try SECResearchArchiveCodec.decode(SECResearchArchiveCodec.encode(state, consent: secArchiveConsent),
                                                        consent: secArchiveConsent)
        let report = try #require(opened.reports.first).document.financials
        #expect(report.cacheState == "requires-explicit-recompute")
        #expect(try await !report.cachedReportsMatch(report.recompute()))
        #expect(opened.reports.first?.bytes == changed)
    }
}
