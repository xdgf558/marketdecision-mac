import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine
import Persistence

// Factual excerpts, never a fabricated SEC API response. Raw issuer pages and the
// independent Decimal extraction/check scripts are retained in local QA evidence.
private struct IssuerQuarterFixture: Decodable {
    struct Fact: Decodable {
        let id, fieldID, statement, concept, start, end, fiscalPeriod, periodType, unit: String
        let fiscalYear: Int
        let decimalValue, reportedValue, reportedScale, signConvention: String
        let sourceHash, sourceURL, observedAt, sourceLocator: String
    }
    struct ExpectedQuarter: Decodable {
        let fieldID, decimalValue: String
        let fiscalYear, quarter: Int
    }
    let schemaVersion, cik, ticker, provenancePolicy: String
    let facts: [Fact]
    let expectedQuarters: [ExpectedQuarter]
    let expectedMetrics: [String:String]
    let expectedGrowth: [String:String]
    let limitations: [String]
    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource:"msft-quarter-golden",withExtension:"json"))
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
    }
    func reported() throws -> [NormalizedFinancialFact] {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return try facts.map { row in
            let instant = try #require(parser.date(from:row.observedAt))
            return .init(id:row.id,cik:cik,fieldID:row.fieldID,
                statement:try #require(FinancialStatement(rawValue:row.statement)),nature:.additiveFlow,
                periodType:try #require(FinancialPeriodType(rawValue:row.periodType)),
                periodStart:try MarketDate(iso8601:row.start),periodEnd:try MarketDate(iso8601:row.end),
                fiscalYear:row.fiscalYear,fiscalPeriod:row.fiscalPeriod,unit:row.unit,
                value:try Money(row.decimalValue),sourceValue:row.reportedValue,derivation:.reported,
                sourceFactIDs:[row.sourceHash+"/"+row.id],sourceVersions:[row.sourceHash],accessionNumbers:[],
                dictionaryVersion:"issuer-golden.manual.v1",availableAt:instant,confidence:.medium,
                limitations:["MANUAL_ISSUER_TABLE_MAPPING","RETRIEVAL_ONLY_NOT_HISTORICAL_PIT"])
        }
    }
    func input(year: Int = 2024) throws -> FundamentalInput {
        let original = try reported().filter { ($0.fiscalYear ?? Int.max) <= year }
        let derived = try FinancialNormalizer.discreteQuarters(from:original)
        let ttm = try FinancialNormalizer.trailingTwelveMonths(from:derived.values)
        let cutoff = try #require(original.map(\.availableAt).max()).addingTimeInterval(1)
        var quarters: [FiscalQuarter] = []
        for fiscalYear in (year == 2024 ? [2023,2024] : [2023]) {
            for (a,b) in [("\(fiscalYear-1)-07-01","\(fiscalYear-1)-09-30"),("\(fiscalYear-1)-10-01","\(fiscalYear-1)-12-31"),
                          ("\(fiscalYear)-01-01","\(fiscalYear)-03-31"),("\(fiscalYear)-04-01","\(fiscalYear)-06-30")] {
                quarters.append(try .init(start:MarketDate(iso8601:a),end:MarketDate(iso8601:b)))
            }
        }
        return try .init(cik:cik,normalization:.init(asOf:cutoff,dictionaryVersion:"issuer-golden.manual.v1",
            values:original + derived.values.filter { $0.derivation != .reported } + ttm.values,
            issues:derived.issues + ttm.issues,selectedSourceFacts:[],unmappedSourceFacts:[]),
            quarters:quarters,priceDay:MarketDate(iso8601:"\(year)-06-30"),expectedClassIDs:[],classes:[],
            inputLimitations:limitations+["OFFLINE_ISSUER_GOLDEN_NOT_PROVIDER_ADMISSION"])
    }
}
private let issuerExecution = Date(timeIntervalSince1970:1_800_000_000)
private func issuerModel() async throws -> ResolvedModel {
    try await FundamentalModelV1.resolve(in:ModelRegistry(),at:issuerExecution)
}
private func issuerReport() async throws -> FundamentalReport {
    try await FundamentalCalculator.calculate(IssuerQuarterFixture.load().input(),model:issuerModel(),executionDate:issuerExecution)
}

@Suite struct IssuerQuarterGoldenTests {
    @Test func officialTableExcerptsBindUnitsSignsPeriodsAndSources() throws {
        let f = try IssuerQuarterFixture.load()
        #expect(f.schemaVersion == "issuer-quarter-golden.v1" && f.cik == "0000789019")
        #expect(f.facts.count == 56 && Set(f.facts.map(\.id)).count == 56)
        #expect(Set(f.facts.map(\.sourceHash)).count == 8)
        for row in f.facts {
            #expect(row.unit == "USD" && row.reportedScale == "1000000")
            #expect(row.sourceHash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil)
            #expect(URL(string:row.sourceURL)?.host == "www.microsoft.com" && !row.sourceLocator.isEmpty)
            let text = row.reportedValue.replacingOccurrences(of:"$",with:"").replacingOccurrences(of:",",with:"")
                .replacingOccurrences(of:"(",with:"-").replacingOccurrences(of:")",with:"").trimmingCharacters(in:.whitespaces)
            let displayed = try Money(text), sign = row.fieldID == "cash-flow.capex" ? "-1":"1"
            #expect(try displayed.multiplied(by:sign).multiplied(by:row.reportedScale) == Money(row.decimalValue))
            if row.fieldID == "cash-flow.capex" { #expect(displayed.amount < 0) }
        }
        // No invented filing accession, original acceptance time, or current market quote.
        #expect(try f.reported().allSatisfy { $0.accessionNumbers.isEmpty && $0.confidence == .medium })
    }
    @Test func realQuarterAndYTDColumnsReconcileWithoutDividingAnnualTotals() throws {
        let fixture = try IssuerQuarterFixture.load()
        let result = try FinancialNormalizer.discreteQuarters(from:fixture.reported())
        #expect(result.issues.isEmpty && result.values.count == 56)
        for e in fixture.expectedQuarters {
            let row = try #require(result.values.first { $0.fieldID == e.fieldID && $0.fiscalYear == e.fiscalYear && $0.fiscalPeriod == "Q\(e.quarter)" })
            #expect(try row.value == Money(e.decimalValue))
            #expect(row.sourceVersions.count >= 1)
        }
        let q4 = try #require(result.values.first { $0.fieldID == "cash-flow.operating-cash-flow" && $0.fiscalYear == 2024 && $0.fiscalPeriod == "Q4" })
        #expect(q4.derivation == .annualLessYTD && q4.sourceVersions.count == 2)
        #expect(try q4.value == Money("37195000000"))
    }
    @Test func realAnnualOnlyAndMissingBridgesCannotBecomeCompleteQuarterHistory() throws {
        let rows = try IssuerQuarterFixture.load().reported()
        let annual = try FinancialNormalizer.discreteQuarters(from:rows.filter { $0.periodType == .annual })
        #expect(annual.values.isEmpty && !annual.issues.isEmpty)
        let missing = try FinancialNormalizer.discreteQuarters(from:rows.filter { $0.fiscalPeriod != "Q2" })
        #expect(!missing.values.contains { $0.fiscalPeriod == "Q2" || $0.fiscalPeriod == "Q3" })
        let ttm = try FinancialNormalizer.trailingTwelveMonths(from:missing.values)
        #expect(ttm.values.isEmpty && !ttm.issues.isEmpty)
    }
    @Test func realTTMRatiosMatchIndependentAnnualOracleAndMissingValuationStaysEmpty() async throws {
        let fixture = try IssuerQuarterFixture.load(), report = try await issuerReport()
        for (key,expected) in fixture.expectedMetrics where key.hasPrefix("2024/") {
            let metric = String(key.dropFirst(5))
            #expect(try report.metrics[metric]?.value == Money(expected))
        }
        for key in ["marketCap","enterpriseValue","roic","peEPS","peMarketCap","priceFCF","fcfYield"] { #expect(report.metrics[key]?.value == nil) }
        #expect(report.researchOnly && report.capitalInputs.isEmpty)
        let score = try await FundamentalScoring.calculate(fixture.input(),model:issuerModel(),executionDate:issuerExecution)
        #expect(score.total == nil && score.coveredWeightOf84 < 59)
        #expect(score.valuation.metrics.values.allSatisfy { $0.prices.isEmpty })
    }
    @Test func priorYearColumnUsesRetrievalCutoffWithoutBackdatingAvailability() async throws {
        let fixture = try IssuerQuarterFixture.load()
        let input = try fixture.input(year:2023)
        let report = try await FundamentalCalculator.calculate(input,model:issuerModel(),executionDate:issuerExecution)
        for (key,expected) in fixture.expectedMetrics where key.hasPrefix("2023/") {
            #expect(try report.metrics[String(key.dropFirst(5))]?.value == Money(expected))
        }
        #expect(input.normalization.values.allSatisfy { $0.availableAt.timeIntervalSince1970 > 1_767_225_600 })
    }
    @Test func realQuarterFlowsValidateNewGrowthWithoutInventedEPSOrShareCounts() async throws {
        let fixture = try IssuerQuarterFixture.load()
        let resolved = try await FundamentalGrowthModelV1.resolve(in:ModelRegistry(),at:issuerExecution)
        let report = try FundamentalGrowthCalculator.calculate(fixture.input(),model:resolved,executionDate:issuerExecution)
        for (key,expected) in fixture.expectedGrowth { #expect(try report.metrics[key]?.value == Money(expected)) }
        for key in ["epsQuarter","revenuePerShareQuarter","fcfPerShareQuarter"] { #expect(report.metrics[key]?.value == nil) }
        let bytes = try ResearchDocument.encoded(report)
        let decoded = try JSONDecoder().decode(FundamentalGrowthReport.self,from:bytes)
        #expect(try ResearchDocument.encoded(decoded.recompute(using:resolved)) == bytes)
    }
    @Test func retrievedIssuerFactsCannotAcquireEarlierPITAvailability() throws {
        let original = try IssuerQuarterFixture.load().input()
        let tooEarly = try #require(original.normalization.values.map(\.availableAt).min()).addingTimeInterval(-1)
        #expect(throws:FundamentalError.incompatibleInput) {
            try FundamentalInput(cik:original.cik,normalization:.init(asOf:tooEarly,dictionaryVersion:original.normalization.dictionaryVersion,
                values:original.normalization.values,issues:[],selectedSourceFacts:[],unmappedSourceFacts:[]),
                quarters:original.quarters,priceDay:original.priceDay)
        }
    }
    @Test func realInputReportSurvivesEncodingAndIndependentReconstruction() async throws {
        let bytes = try await ResearchDocument.encoded(issuerReport())
        let decoded = try JSONDecoder().decode(FundamentalReport.self,from:bytes)
        let resolved = try await issuerModel()
        let replay = try decoded.recompute(using:resolved)
        #expect(try ResearchDocument.encoded(replay) == bytes)
        #expect(replay.sourceVersions.count == 8)
    }
    @Test func realExcerptAndReportFreezeReopenAndRestoreWithOriginalHashes() async throws {
        let report = try await issuerReport(), bytes = try ResearchDocument.encoded(report)
        let source = try Data(contentsOf:#require(Bundle.module.url(forResource:"msft-quarter-golden",withExtension:"json")))
        let instant = try MillisecondInstant(rounding:issuerExecution)
        let permission = RetentionPermission(mayStore:true,mayBackup:true,evidenceReference:"local-factual-QA-excerpt-not-provider-license")
        let input = FrozenObject(identity:.init(id:"issuer-excerpt",version:"v1"),kind:.input,payload:.string(source.base64EncodedString()),
            references:[],capturedAt:instant,permission:permission,synthetic:false)
        let result = FrozenObject(identity:.init(id:"issuer-result",version:"v1"),kind:.result,payload:.string(bytes.base64EncodedString()),
            references:[.init(role:"facts",target:input.identity,contentHash:try input.contentHash())],capturedAt:instant,permission:permission,synthetic:false)
        let bundle = SnapshotBundle(sourceNamespace:UUID(),objects:[input,result],roots:[.init(identity:.init(id:"qa-run",version:"v1"),kind:.analysisRun,
            references:[.init(role:"result",target:result.identity,contentHash:try result.contentHash())])])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("qa.sqlite").path
        let store = try BusinessDataStore(path:path)
        try await store.freeze(bundle,expectedRevision:store.revision())
        let reopened = try BusinessDataStore(path:path)
        for object in bundle.objects {
            #expect(try await reopened.content(at:.init(namespace:bundle.sourceNamespace,identity:object.identity),expectedHash:object.contentHash()) == object.contentBytes())
        }
        let decodedBundle = try JSONDecoder().decode(SnapshotBundle.self,from:ResearchDocument.encoded(bundle))
        let inventory = try BackupInventory(entries:decodedBundle.objects.map { object in
            let size = Int64(try object.contentBytes().count)
            return .init(identity:object.identity,path:object.identity.id+".json",contentHash:try object.contentHash(),bytes:size,compressedBytes:size)
        })
        let restored = try BusinessDataStore(path:directory.appendingPathComponent("restored.sqlite").path)
        let plan = try await restored.prepareRestore(decodedBundle,inventory:inventory,mode:.replace,expectedRevision:restored.revision())
        _ = try await restored.commit(.init(planID:plan.id,digest:plan.digest))
        for object in decodedBundle.objects {
            let target = try #require(plan.importedAddresses[object.identity])
            #expect(try await restored.content(at:target,expectedHash:object.contentHash()) == object.contentBytes())
        }
        // The application ZIP format remains synthetic-only. Generic graph recovery is not its admission path.
        let db = try DatabaseStore(path:path), transfer = ResearchTransferStore(database:db)
        await #expect(throws:SnapshotError.retentionDenied) { try await transfer.exportBackup() }
    }
}
