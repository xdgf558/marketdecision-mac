import Foundation
import Testing
import FundamentalsEngine
@testable import AppComposition

private func catalogObject(_ catalog: OfflineIssuerCatalog) throws -> [String: Any] {
    let issuers = try catalog.entries.map { entry in
        try #require(JSONSerialization.jsonObject(with: catalog.excerpt(for: entry.ticker)) as? [String: Any])
    }
    return ["format": "offline-issuer-excerpts.v1", "provenancePolicy": "Fixed manually reviewed excerpts", "issuers": issuers]
}

private func catalogBytes(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func allCatalogKeys(_ value: Any) -> [String] {
    if let object = value as? [String: Any] {
        return object.flatMap { [$0.key] + allCatalogKeys($0.value) }
    }
    if let array = value as? [Any] { return array.flatMap(allCatalogKeys) }
    return []
}

@Suite struct OfflineIssuerCatalogTests {
    @Test func runtimeExcerptsPreserveEveryReviewedInputAndContainNoTestAnswers() throws {
        let catalog = try OfflineIssuerCatalog.bundled()
        #expect(catalog.entries.map(\.ticker) == ["AAPL", "MSFT", "META", "AMZN", "NVDA", "COST", "WMT", "KO", "JPM", "BRK.B"])
        var factCount = 0
        for entry in catalog.entries {
            let original = try #require(JSONSerialization.jsonObject(with: offlineIssuerExcerpt(entry.ticker)) as? [String: Any])
            let factual = original.filter { !$0.key.hasPrefix("expected") || $0.key == "expectedClassIDs" }
            let bytes = try catalog.excerpt(for: entry.ticker)
            #expect(bytes == (try catalogBytes(factual)), "All original fact, source, time, mapping and limitation values must be retained")
            let object = try JSONSerialization.jsonObject(with: bytes)
            #expect(allCatalogKeys(object).filter { $0.hasPrefix("expected") } == ["expectedClassIDs"])
            let context = try OfflineIssuerResearchContext.decode(excerptData: bytes)
            #expect(entry.id == context.ticker && entry.cik == context.cik)
            #expect(!context.expectedClassIDs.isEmpty && !context.knownMissing.isEmpty)
            factCount += context.facts.count
        }
        #expect(factCount == 1_610)
    }

    @Test func unknownAndNonexactSymbolsNeverFallBackToAnotherIssuer() throws {
        let catalog = try OfflineIssuerCatalog.bundled()
        for ticker in ["", "DEMO", "TSLA", "msft", "MSFT ", "BRK-B"] {
            #expect(throws: OfflineIssuerCatalogError.unknownTicker) { try catalog.excerpt(for: ticker) }
        }
    }

    @Test func catalogueRequiresEveryUniqueReviewedIssuerAndValidFacts() throws {
        let source = try catalogObject(OfflineIssuerCatalog.bundled())
        let issuers = try #require(source["issuers"] as? [[String: Any]])
        let first = try #require(issuers.first)
        var duplicate = issuers; duplicate[duplicate.count - 1] = first
        var unknown = issuers; unknown[0]["ticker"] = "UNKNOWN"
        var identity = issuers; identity[0]["cik"] = "0000000000"
        var facts = try #require(first["facts"] as? [[String: Any]])
        #expect(!facts.isEmpty)
        let firstFact = try #require(facts.indices.first)
        facts[firstFact]["decimalValue"] = "1"
        var damaged = issuers; damaged[0]["facts"] = facts
        for rows in [[], Array(issuers.dropLast()), duplicate, unknown, identity, damaged] {
            var changed = source; changed["issuers"] = rows
            #expect(throws: (any Error).self) { try OfflineIssuerCatalog(data: catalogBytes(changed)) }
        }
        #expect(throws: OfflineIssuerCatalogError.invalidResource) { try OfflineIssuerCatalog(data: Data()) }
    }

    @Test func catalogueRejectsTestAnswersInRuntimeFactsAndAuxiliaryEvidence() throws {
        let source = try catalogObject(OfflineIssuerCatalog.bundled())
        let original = try #require(source["issuers"] as? [[String: Any]])
        for name in ["expectedQuarters", "expectedMetrics", "expectedGrowth", "expectedCompletion", "expectedUnavailable", "expectedCompletionMissing"] {
            var changed = source, issuers = original
            issuers[0][name] = ["revenue": "1"]; changed["issuers"] = issuers
            #expect(throws: OfflineIssuerCatalogError.invalidResource) { try OfflineIssuerCatalog(data: catalogBytes(changed)) }
        }
        var changed = source, issuers = original
        issuers[0]["auxiliaryEvidence"] = [["expectedMetrics": ["revenue": "1"]]]
        changed["issuers"] = issuers
        #expect(throws: OfflineIssuerCatalogError.invalidResource) { try OfflineIssuerCatalog(data: catalogBytes(changed)) }
    }

    @Test(arguments: ["MSFT", "WMT", "JPM"])
    func runtimeDocumentsExplicitlyReplayWithoutAdmittingCapitalOrHistoricalPIT(ticker: String) async throws {
        let catalog = try OfflineIssuerCatalog.bundled()
        let document = try await OfflineIssuerResearchDocument.make(excerptData: catalog.excerpt(for: ticker),
            asOf: Date(timeIntervalSince1970: 1_800_000_000), executionDate: Date(timeIntervalSince1970: 1_800_000_060),
            retention: OfflineIssuerResearchRetention(mayStore: true, mayBackup: false,
                evidenceReference: "BUNDLED_REVIEWED_MANUAL_EXCERPT_LOCAL_RESEARCH"))
        let replay = try await document.recompute()
        #expect(try document.cachedReportsMatch(replay))
        #expect(!document.synthetic && document.researchOnly)
        #expect(!document.historicalPITQualified && !document.providerAdmitted && !document.capitalInputsAllowed)
        #expect(document.cacheState == "requires-explicit-recompute")
        #expect(replay.base.inputSnapshot.input.classes.isEmpty)
        #expect(Set(OfflineIssuerResearchContext.requiredLimitations).isSubset(of: Set(replay.base.limitations)))
        for key in ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceFCF", "fcfYield"] {
            let metric = try #require(replay.base.metrics[key])
            #expect(metric.value == nil && metric.unavailable != nil)
        }
        if ticker == "WMT" { #expect(replay.base.inputSnapshot.input.splitBasisEvidence != nil) }
        if ticker == "JPM" { #expect(replay.base.metrics["roic"]?.unavailable == .notApplicable) }
    }
}
