import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

// Shared with the archive integration tests. Preserve the entire factual excerpt,
// including auxiliary evidence and mapping notes, rather than re-encoding a partial DTO.
func offlineIssuerExcerpt(_ ticker: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "issuer-completion-golden", withExtension: "json"))
    let file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let issuers = try #require(file["issuers"] as? [[String: Any]])
    let issuer = try #require(issuers.first { $0["ticker"] as? String == ticker })
    return try JSONSerialization.data(withJSONObject: issuer, options: [.sortedKeys])
}

func offlineIssuerDocument(_ ticker: String = "MSFT") async throws -> OfflineIssuerResearchDocument {
    try await offlineDocument(from: offlineIssuerExcerpt(ticker))
}

private let offlineIssuerTickers = ["AAPL", "MSFT", "META", "AMZN", "NVDA", "COST", "WMT", "KO", "JPM", "BRK.B"]
private let offlineCutoff = Date(timeIntervalSince1970: 1_800_000_000)
private let offlineExecution = Date(timeIntervalSince1970: 1_800_000_060)

private func offlineDocument(from excerpt: Data, asOf: Date = offlineCutoff) async throws -> OfflineIssuerResearchDocument {
    try await .make(excerptData: excerpt, asOf: asOf, executionDate: offlineExecution,
                    retention: OfflineIssuerResearchRetention(mayStore: true, mayBackup: true,
                        evidenceReference: "USER_AUTHORIZED_OFFLINE_EXCERPT_RESEARCH_AND_BACKUP"))
}

private func editOfflineJSON(_ data: Data, _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    try edit(&json)
    return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}

private func editOfflineFact(_ data: Data, field: String = "income.revenue",
                             _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
    try editOfflineJSON(data) { json in
        var facts = try #require(json["facts"] as? [[String: Any]])
        let index = try #require(facts.firstIndex { $0["fieldID"] as? String == field })
        try edit(&facts[index]); json["facts"] = facts
    }
}

private func editOfflineInput(_ data: Data, _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
    try editOfflineJSON(data) { json in
        var snapshot = try #require(json["inputSnapshot"] as? [String: Any])
        var financials = try #require(snapshot["financials"] as? [String: Any])
        var input = try #require(financials["input"] as? [String: Any])
        try edit(&input)
        financials["input"] = input; snapshot["financials"] = financials; json["inputSnapshot"] = snapshot
    }
}

private func expectOfflineDocumentRejected(_ bytes: Data) {
    #expect(throws: (any Error).self) {
        let document = try JSONDecoder().decode(OfflineIssuerResearchDocument.self, from: bytes)
        try document.validate()
    }
}

// Oracle fields are decoded only here. The production document must calculate from
// reported facts and frozen context, never from these independently prepared answers.
private struct OfflineIssuerOracle: Decodable {
    struct Window: Decodable { let start, end: String }
    struct Fact: Decodable { let fieldID, end, periodType, sourceHash: String; let fiscalYear: Int }
    let financialCompany: Bool
    let expectedClassIDs: [String]
    let quarters: [Window]
    let facts: [Fact]
    let expectedMetrics, expectedGrowth: [String: String]
    let expectedCompletion, expectedUnavailable: [String: String]?
    let expectedCompletionMissing: [String]?
    let splitBasisEvidence: String?
}

@Suite struct OfflineIssuerDocumentTests {
    @Test(arguments: offlineIssuerTickers)
    func tenIssuerDocumentsReplayIndependentNumbersWithoutCapitalAdmission(ticker: String) async throws {
        let excerpt = try offlineIssuerExcerpt(ticker)
        let oracle = try JSONDecoder().decode(OfflineIssuerOracle.self, from: excerpt)
        let original = try await offlineIssuerDocument(ticker)
        let restored = try JSONDecoder().decode(OfflineIssuerResearchDocument.self,
                                               from: ResearchDocument.encoded(original))
        try restored.validate()
        let replay = try await restored.recompute()
        #expect(try restored.cachedReportsMatch(replay))
        #expect(restored.excerptData == excerpt && restored.excerptHash == digest(excerpt))
        let input = replay.base.inputSnapshot.input
        let lastEnd = try #require(oracle.quarters.last).end
        let year = try #require(oracle.facts.first { $0.periodType == "annual" && $0.end == lastEnd }).fiscalYear
        let latestExpected = oracle.expectedMetrics.filter { $0.key.hasPrefix("\(year)/") }
        #expect(!latestExpected.isEmpty && !oracle.expectedGrowth.isEmpty)
        for (name, expected) in latestExpected {
            let key = String(name.dropFirst(5))
            let actual: Money?
            switch key {
            case "ocf": actual = try input.flow(.ocf)
            case "capex": actual = try input.flow(.capex)
            case "sbc": actual = try input.flow(.sbc)
            case "sumQuarterDilutedEPS": actual = replay.base.metrics["dilutedEPSQuarterSum"]?.value
            default: actual = replay.base.metrics[key]?.value
            }
            #expect(try actual == Money(expected), "\(ticker) \(name)")
        }
        for (key, expected) in oracle.expectedGrowth {
            #expect(try replay.growth.metrics[key]?.value == Money(expected), "\(ticker) growth \(key)")
        }
        for (key, expected) in oracle.expectedCompletion ?? [:] {
            #expect(try replay.completion.metrics[key]?.value == Money(expected), "\(ticker) completion \(key)")
        }
        for key in oracle.expectedCompletionMissing ?? [] {
            let metric = try #require(replay.completion.metrics[key])
            #expect(metric.value == nil && metric.unavailable != nil, "\(ticker) \(key)")
        }
        for (name, _) in oracle.expectedUnavailable ?? [:] where name != "inversePrice" {
            let key = name == "sumQuarterDilutedEPS" ? "dilutedEPSQuarterSum" : name
            let metric = try #require(replay.base.metrics[key])
            #expect(metric.value == nil && metric.unavailable != nil, "\(ticker) \(key)")
        }
        for key in ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceFCF", "fcfYield", "shareholderYield"] {
            let metric = try #require(replay.base.metrics[key])
            #expect(metric.value == nil && metric.unavailable != nil, "\(ticker) missing capital \(key)")
        }
        #expect(replay.base.researchOnly && replay.growth.researchOnly && replay.completion.researchOnly)
        #expect(input.classes.isEmpty && input.expectedClassIDs == Set(oracle.expectedClassIDs))
        #expect(input.financialCompany == oracle.financialCompany)
        #expect(input.quarters.map { $0.start.iso8601 } == oracle.quarters.map(\.start))
        #expect(input.quarters.map { $0.end.iso8601 } == oracle.quarters.map(\.end))
        #expect(input.normalization.selectedSourceFacts.isEmpty && input.normalization.unmappedSourceFacts.isEmpty)
        #expect(input.normalization.values.allSatisfy { $0.accessionNumbers.isEmpty && $0.confidence == .medium })
        let sourceHashes = Set(oracle.facts.map(\.sourceHash))
        #expect(Set(replay.base.sourceVersions) == sourceHashes)
        #expect(!sourceHashes.contains(restored.excerptHash)) // Original PDF/HTML hashes are not excerpt-byte hashes.
        if oracle.financialCompany {
            #expect(replay.base.metrics["roic"]?.unavailable == .notApplicable)
        }
        if oracle.splitBasisEvidence == nil {
            for key in ["epsQuarter", "revenuePerShareQuarter", "fcfPerShareQuarter"] {
                #expect(replay.growth.metrics[key]?.value == nil)
            }
        }
    }

    @Test func displayedValuesScalesAndSignsMustAgreeWithStoredDecimals() async throws {
        let source = try offlineIssuerExcerpt("AAPL")
        let changes: [(String, String)] = [("reportedValue", "119576"), ("reportedScale", "1000"),
                                          ("decimalValue", "119575000001"), ("signConvention", "unknown-transform")]
        for (key, value) in changes {
            let changed = try editOfflineFact(source) { $0[key] = value }
            await #expect(throws: (any Error).self) { try await offlineDocument(from: changed) }
        }
        let lostOutflowSign = try editOfflineFact(source, field: "cash-flow.capex") { row in
            row["signConvention"] = "reported-signed"
        }
        await #expect(throws: (any Error).self) { try await offlineDocument(from: lostOutflowSign) }
        let wrongPercentScale = try editOfflineFact(offlineIssuerExcerpt("WMT"), field: "ratio.lease-discount-rate") {
            $0["reportedScale"] = "1"
        }
        await #expect(throws: (any Error).self) { try await offlineDocument(from: wrongPercentScale) }
    }

    @Test func sourceCellsNeedValidReferencesAndCannotBeRelabelledIntoIndependentFacts() async throws {
        let source = try offlineIssuerExcerpt("MSFT")
        for (key, value) in [("sourceHash", "not-a-sha256"), ("sourceURL", "http://example.invalid/statement"),
                             ("sourceLocator", "")] {
            let changed = try editOfflineFact(source) { $0[key] = value }
            await #expect(throws: (any Error).self) { try await offlineDocument(from: changed) }
        }
        let duplicateCell = try editOfflineJSON(source) { json in
            var facts = try #require(json["facts"] as? [[String: Any]])
            var copied = try #require(facts.first { $0["fieldID"] as? String == "income.net-income" })
            copied["fieldID"] = "income.common-income"; facts.append(copied); json["facts"] = facts
        }
        await #expect(throws: (any Error).self) { try await offlineDocument(from: duplicateCell) }
        let backdated = Date(timeIntervalSince1970: 1_767_225_600)
        await #expect(throws: (any Error).self) { try await offlineDocument(from: source, asOf: backdated) }
    }

    @Test func retrievalWithinTheSameMillisecondMustNotBeAdmittedBeforeItsExactInstant() async throws {
        let source = try editOfflineJSON(offlineIssuerExcerpt("MSFT")) { json in
            var facts = try #require(json["facts"] as? [[String: Any]])
            for index in facts.indices { facts[index]["observedAt"] = "2026-09-23T00:00:00.000400Z" }
            json["facts"] = facts
        }
        let second = try MillisecondInstant(iso8601: "2026-09-23T00:00:00.000Z").date
        let early = second.addingTimeInterval(0.0002), exact = second.addingTimeInterval(0.0004)
        await #expect(throws: (any Error).self) { try await offlineDocument(from: source, asOf: early) }
        let admitted = try await offlineDocument(from: source, asOf: exact)
        let restored = try JSONDecoder().decode(OfflineIssuerResearchDocument.self,
                                               from: ResearchDocument.encoded(admitted))
        try restored.validate()
        let input = restored.inputSnapshot.financials.input
        #expect(input.normalization.asOf == exact)
        #expect(input.normalization.values.allSatisfy { $0.availableAt == exact })
        let replay = try await restored.recompute()
        #expect(try restored.cachedReportsMatch(replay))
    }

    @Test func aDisplayDashIsZeroOnlyUnderTheExplicitPreferredEquityEvidenceRule() async throws {
        let source = try offlineIssuerExcerpt("AMZN")
        // The original excerpt spells this evidenced zero as "0"; the reviewed
        // preferred-equity rule may also preserve the statement's displayed dash.
        let original = try await offlineDocument(from: source)
        #expect(try original.inputSnapshot.financials.input.instant(.preferred) == Money("0"))
        let preferredDash = try editOfflineFact(source, field: "balance.preferred-equity") { $0["reportedValue"] = "—" }
        let admitted = try await offlineDocument(from: preferredDash)
        #expect(try admitted.inputSnapshot.financials.input.instant(.preferred) == Money("0"))
        let missingRevenue = try editOfflineFact(source) { row in
            row["reportedValue"] = "—"; row["decimalValue"] = "0"
        }
        await #expect(throws: (any Error).self) { try await offlineDocument(from: missingRevenue) }
        let relabelledRevenue = try editOfflineFact(missingRevenue) {
            $0["signConvention"] = "explicit-dash-zero-supported-by-no-preferred-issued"
        }
        await #expect(throws: (any Error).self) { try await offlineDocument(from: relabelledRevenue) }
    }

    @Test func frozenIssuerClassificationClassesAndPeriodsCannotDriftFromExcerpt() async throws {
        let document = try await offlineIssuerDocument("JPM")
        let bytes = try ResearchDocument.encoded(document)
        let wrongCIK = try editOfflineInput(bytes) { $0["cik"] = "0000789019" }
        let industrialBank = try editOfflineInput(bytes) { $0["financialCompany"] = false }
        let wrongClasses = try editOfflineInput(bytes) { $0["expectedClassIDs"] = ["A", "B"] }
        let missingQuarter = try editOfflineInput(bytes) { input in
            var quarters = try #require(input["quarters"] as? [[String: Any]])
            quarters.removeFirst(); input["quarters"] = quarters
        }
        let wrongSource = try editOfflineJSON(bytes) { $0["excerptHash"] = String(repeating: "0", count: 64) }
        for changed in [wrongCIK, industrialBank, wrongClasses, missingQuarter, wrongSource] {
            expectOfflineDocumentRejected(changed)
        }
        for key in ["historicalPITQualified", "providerAdmitted", "capitalInputsAllowed"] {
            expectOfflineDocumentRejected(try editOfflineJSON(bytes) { $0[key] = true })
        }
        expectOfflineDocumentRejected(try editOfflineJSON(bytes) { $0["researchOnly"] = false })
        expectOfflineDocumentRejected(try editOfflineJSON(bytes) { $0["cacheState"] = "verified" })
        expectOfflineDocumentRejected(try editOfflineJSON(bytes) { $0["historyInputs"] = [] })
        for key in ["baseReport", "growthReport", "completionReport"] {
            let missingWarnings = try editOfflineJSON(bytes) { json in
                var report = try #require(json[key] as? [String: Any])
                report["limitations"] = []; json[key] = report
            }
            expectOfflineDocumentRejected(missingWarnings)
        }
        let promotedConfidence = try editOfflineJSON(bytes) { json in
            var report = try #require(json["baseReport"] as? [String: Any])
            report["confidence"] = "high"; json["baseReport"] = report
        }
        expectOfflineDocumentRejected(promotedConfidence)
        let excerptPretendingToBeOriginal = try editOfflineInput(bytes) { input in
            var normalization = try #require(input["normalization"] as? [String: Any])
            var values = try #require(normalization["values"] as? [[String: Any]])
            values[0]["sourceVersions"] = [document.excerptHash]
            normalization["values"] = values; input["normalization"] = normalization
        }
        expectOfflineDocumentRejected(excerptPretendingToBeOriginal)
    }

    @Test func splitEvidenceAndLongRevenueWindowsRemainPartOfTheFrozenContext() async throws {
        let wmt = try await offlineIssuerDocument("WMT")
        #expect(wmt.inputSnapshot.financials.input.splitBasisEvidence?.isEmpty == false)
        let missingSources = try editOfflineJSON(wmt.excerptData) { $0.removeValue(forKey: "splitBasisSources") }
        await #expect(throws: (any Error).self) { try await offlineDocument(from: missingSources) }
        let removedSplit = try editOfflineInput(ResearchDocument.encoded(wmt)) { $0["splitBasisEvidence"] = NSNull() }
        expectOfflineDocumentRejected(removedSplit)
        let msft = try await offlineIssuerDocument()
        #expect(msft.inputSnapshot.revenueYears.count == 6)
        let shortened = try editOfflineJSON(ResearchDocument.encoded(msft)) { json in
            var snapshot = try #require(json["inputSnapshot"] as? [String: Any])
            var years = try #require(snapshot["revenueYears"] as? [[String: Any]])
            years.removeFirst(); snapshot["revenueYears"] = years; json["inputSnapshot"] = snapshot
        }
        expectOfflineDocumentRejected(shortened)
    }

    @Test func modelDefinitionsAndParameterReferencesAreNotReplaceableDuringReplay() async throws {
        let document = try await offlineIssuerDocument()
        #expect(document.cacheState == "requires-explicit-recompute")
        let bytes = try ResearchDocument.encoded(document)
        let wrongModel = try editOfflineJSON(bytes) { json in
            var models = try #require(json["models"] as? [[String: Any]])
            models[0]["formulaVersion"] = "unreviewed.v2"; json["models"] = models
        }
        let wrongParameters = try editOfflineJSON(bytes) { json in
            var parameters = try #require(json["parameters"] as? [String: Any])
            parameters["revisionID"] = UUID().uuidString; json["parameters"] = parameters
        }
        let futureFormat = try editOfflineJSON(bytes) { $0["format"] = "offline-issuer-research.v999" }
        for changed in [wrongModel, wrongParameters, futureFormat] { expectOfflineDocumentRejected(changed) }
    }

    @Test func cachedNumbersRequireExplicitRecalculationAndNeverFeedTheOracleBackIntoCalculations() async throws {
        let document = try await offlineIssuerDocument()
        let changed = try editOfflineJSON(ResearchDocument.encoded(document)) { json in
            var report = try #require(json["baseReport"] as? [String: Any])
            var metrics = try #require(report["metrics"] as? [String: Any])
            var revenue = try #require(metrics["revenue"] as? [String: Any])
            revenue["value"] = "1"; metrics["revenue"] = revenue; report["metrics"] = metrics; json["baseReport"] = report
        }
        let decoded = try JSONDecoder().decode(OfflineIssuerResearchDocument.self, from: changed)
        try decoded.validate() // Structural validation cannot claim that formulas were rerun.
        let replay = try await decoded.recompute()
        #expect(try !decoded.cachedReportsMatch(replay))
        #expect(decoded.cacheState == "requires-explicit-recompute")
        #expect(replay.base.metrics["revenue"] == document.baseReport.metrics["revenue"])
        let poisonedOracle = try editOfflineJSON(document.excerptData) { json in
            json["expectedMetrics"] = ["2024/revenue": "1"]
            json["expectedGrowth"] = ["revenueQuarterYoY": "999"]
            json["expectedCompletion"] = ["revenueCAGR5Y": "999"]
        }
        let independent = try await offlineDocument(from: poisonedOracle)
        #expect(independent.baseReport.metrics == document.baseReport.metrics)
        #expect(independent.growthReport.metrics == document.growthReport.metrics)
        #expect(independent.completionReport.metrics == document.completionReport.metrics)
    }

    @Test func standaloneExcerptCannotBeDecodedAsTheSyntheticResearchContract() async throws {
        let document = try await offlineIssuerDocument()
        let bytes = try ResearchDocument.encoded(document)
        await #expect(throws: (any Error).self) {
            let synthetic = try JSONDecoder().decode(ResearchDocument.self, from: bytes)
            try await synthetic.validate()
        }
    }
}
