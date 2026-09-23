import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine
import Persistence

// Fixed factual excerpts from issuer statements, not fabricated Company Facts responses.
// Full downloaded source documents and independent extraction/oracle scripts stay local.
private struct CompletionFixture: Decodable {
    struct Window: Decodable { let start, end: String }
    struct Fact: Decodable {
        let fieldID, statement, end, periodType, unit: String
        let start, fiscalPeriod: String?
        let fiscalYear: Int
        let nature, decimalValue, reportedValue, reportedScale, signConvention: String
        let sourceHash, sourceURL, observedAt, sourceLocator: String
    }
    struct QuarterExpectation: Decodable {
        let fieldID, start, end, decimalValue: String
        let fiscalYear, quarter: Int
    }
    struct Issuer: Decodable {
        let ticker, cik: String
        let financialCompany: Bool
        let quarters, fiscalYears: [Window]
        let revenueYears: [Window]?
        let facts: [Fact]
        let expectedQuarters: [QuarterExpectation]
        let expectedMetrics: [String: String]
        let expectedCompletion: [String: String]?
        let expectedGrowth: [String: String]
        let expectedUnavailable: [String: String]?
        let expectedCompletionMissing: [String]?
        let expectedClassIDs, knownMissing: [String]
        let splitBasisEvidence: String?

        func reported() throws -> [NormalizedFinancialFact] {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try facts.map { row in
                let nature = row.nature == "weightedAverageShares" ? FinancialMetricNature.nonadditive
                    : try #require(FinancialMetricNature(rawValue: row.nature))
                // A locator may name a whole row. Pin the reported column and unit as well.
                // Do not add fieldID: relabelling one cell cannot create independent evidence.
                let reference = [row.sourceHash, row.sourceLocator, row.start ?? "instant", row.end, row.unit].joined(separator: "/")
                return .init(id: reference, cik: cik, fieldID: row.fieldID,
                    statement: try #require(FinancialStatement(rawValue: row.statement)), nature: nature,
                    periodType: try #require(FinancialPeriodType(rawValue: row.periodType)),
                    periodStart: try row.start.map { try MarketDate(iso8601: $0) },
                    periodEnd: try MarketDate(iso8601: row.end), fiscalYear: row.fiscalYear, fiscalPeriod: row.fiscalPeriod,
                    unit: row.unit, value: try Money(row.decimalValue), sourceValue: row.reportedValue, derivation: .reported,
                    sourceFactIDs: [reference], sourceVersions: [row.sourceHash], accessionNumbers: [],
                    dictionaryVersion: "issuer-completion.manual.v1", availableAt: try #require(parser.date(from: row.observedAt)),
                    confidence: .medium, limitations: ["MANUAL_ISSUER_TABLE_MAPPING", "RETRIEVAL_ONLY_NOT_HISTORICAL_PIT"])
            }
        }
        func input(endingAt end: String? = nil) throws -> FundamentalInput {
            let end = try end ?? #require(quarters.last).end
            let qs = quarters.filter { $0.end <= end }
            let original = try reported().filter { $0.periodEnd.iso8601 <= end }
            let bridge = try FinancialNormalizer.discreteQuarters(from: original)
            let ttm = try FinancialNormalizer.trailingTwelveMonths(from: bridge.values)
            let cutoff = try #require(original.map(\.availableAt).max()).addingTimeInterval(1)
            return try .init(cik: cik, normalization: .init(asOf: cutoff, dictionaryVersion: "issuer-completion.manual.v1",
                values: original + bridge.values.filter { $0.derivation != .reported } + ttm.values,
                issues: bridge.issues + ttm.issues, selectedSourceFacts: [], unmappedSourceFacts: []),
                quarters: qs.map { try .init(start: MarketDate(iso8601: $0.start), end: MarketDate(iso8601: $0.end)) },
                fiscalYears: fiscalYears.filter { $0.end <= end }.suffix(3).map {
                    try .init(start: MarketDate(iso8601: $0.start), end: MarketDate(iso8601: $0.end))
                }, priceDay: MarketDate(iso8601: end), expectedClassIDs: Set(expectedClassIDs), classes: [],
                financialCompany: financialCompany, splitBasisEvidence: splitBasisEvidence,
                inputLimitations: knownMissing + ["OFFLINE_ISSUER_GOLDEN_NOT_PROVIDER_ADMISSION"])
        }
        func completionInput() throws -> FundamentalCompletionInput {
            try .init(financials: input(), revenueYears: (revenueYears ?? fiscalYears).map {
                try .init(start: MarketDate(iso8601: $0.start), end: MarketDate(iso8601: $0.end))
            })
        }
    }
    let schemaVersion: String
    let issuers: [Issuer]
    static func load(_ ticker: String) throws -> Issuer {
        let url = try #require(Bundle.module.url(forResource: "issuer-completion-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        #expect(fixture.schemaVersion == "issuer-completion-golden.v1")
        #expect(Set(fixture.issuers.map(\.ticker)) == Set(completionTickers))
        #expect(fixture.issuers.count == 10)
        return try #require(fixture.issuers.first { $0.ticker == ticker })
    }
    static func excerptBytes(_ ticker: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "issuer-completion-golden", withExtension: "json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let issuers = try #require(fixture["issuers"] as? [[String: Any]])
        let issuer = try #require(issuers.first { $0["ticker"] as? String == ticker })
        return try JSONSerialization.data(withJSONObject: issuer, options: [.sortedKeys])
    }
}
private let completionTickers = ["AAPL", "MSFT", "META", "AMZN", "NVDA", "COST", "WMT", "KO", "JPM", "BRK.B"]
private let completionExecution = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct IssuerCompletionGoldenTests {
    @Test(arguments: completionTickers)
    func excerptsBindQuarterNatureSourceAndRetrievalOnlyAvailability(ticker: String) throws {
        let fixture = try CompletionFixture.load(ticker)
        let input = try fixture.input()
        let reported = try fixture.reported()
        #expect(Set(reported.map(\.id)).count == reported.count)
        #expect(fixture.quarters.count == 8 && fixture.fiscalYears.count == 3)
        #expect(!fixture.expectedQuarters.isEmpty && !fixture.expectedMetrics.isEmpty && !fixture.knownMissing.isEmpty)
        for row in fixture.facts {
            #expect(row.sourceHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
            #expect(URL(string: row.sourceURL)?.scheme == "https" && !row.sourceLocator.isEmpty)
            #expect(!row.reportedValue.isEmpty && !row.signConvention.isEmpty)
            #expect(try Money(row.reportedScale).amount > 0)
            if row.fieldID == FundamentalGrowthCalculator.dilutedShareFieldID {
                #expect(row.nature == "weightedAverageShares" || row.nature == "nonadditive")
                #expect(row.unit == "shares")
            }
        }
        #expect(input.normalization.selectedSourceFacts.isEmpty) // Never pretend these were SEC API envelopes.
        #expect(input.normalization.values.allSatisfy { $0.accessionNumbers.isEmpty && $0.confidence == .medium })
        #expect(input.normalization.values.allSatisfy { $0.availableAt.timeIntervalSince1970 > 1_767_225_600 })
        let beforeRetrieval = try #require(input.normalization.values.map(\.availableAt).min()).addingTimeInterval(-1)
        #expect(throws: FundamentalError.incompatibleInput) {
            try FundamentalInput(cik: input.cik, normalization: .init(asOf: beforeRetrieval,
                dictionaryVersion: input.normalization.dictionaryVersion, values: input.normalization.values,
                issues: [], selectedSourceFacts: [], unmappedSourceFacts: []), quarters: input.quarters, priceDay: input.priceDay)
        }
    }

    @Test(arguments: completionTickers)
    func directQuartersAndCumulativeBridgesMatchIndependentOracle(ticker: String) throws {
        let fixture = try CompletionFixture.load(ticker)
        let reported = try fixture.reported()
        let result = try FinancialNormalizer.discreteQuarters(from: reported)
        for expected in fixture.expectedQuarters {
            let matches = result.values.filter { $0.fieldID == expected.fieldID && $0.periodStart?.iso8601 == expected.start
                && $0.periodEnd.iso8601 == expected.end && $0.fiscalYear == expected.fiscalYear }
            let row = try #require(matches.count == 1 ? matches.first : nil,
                "\(ticker) \(expected.fieldID) \(expected.start)...\(expected.end) matches=\(matches.count)")
            #expect(try row.value == Money(expected.decimalValue), "\(ticker) \(expected.fieldID) \(expected.end)")
            #expect(row.fiscalPeriod == "Q\(expected.quarter)" && !row.sourceVersions.isEmpty)
        }
        #expect(result.values.allSatisfy { $0.nature == .additiveFlow })
        // Annual EPS and weighted shares never acquire a made-up Q4 through subtraction.
        let nonadditive = try FinancialNormalizer.discreteQuarters(from: reported.filter { $0.nature != .additiveFlow })
        #expect(nonadditive.values.isEmpty)
        let annualOnly = try FinancialNormalizer.discreteQuarters(from: reported.filter { $0.periodType == .annual })
        #expect(annualOnly.values.isEmpty)
    }

    @Test(arguments: completionTickers)
    func fullTTMReportsMatchIndependentNumbersAndKeepMissingCapitalUnavailable(ticker: String) async throws {
        let fixture = try CompletionFixture.load(ticker)
        let model = try await FundamentalModelV1.resolve(in: ModelRegistry(), at: completionExecution)
        for quarterEnd in [fixture.quarters[3].end, fixture.quarters[7].end] {
            let input = try fixture.input(endingAt: quarterEnd)
            let year = try #require(fixture.facts.first { $0.periodType == "annual" && $0.end == quarterEnd }).fiscalYear
            let report = try FundamentalCalculator.calculate(input, model: model, executionDate: completionExecution)
            let expectations = fixture.expectedMetrics.filter { $0.key.hasPrefix("\(year)/") }
            #expect(!expectations.isEmpty)
            for (name, value) in expectations {
                let key = String(name.dropFirst(5))
                let actual: Money?
                switch key {
                case "ocf": actual = try input.flow(.ocf)
                case "capex": actual = try input.flow(.capex)
                case "sbc": actual = try input.flow(.sbc)
                case "sumQuarterDilutedEPS": actual = report.metrics["dilutedEPSQuarterSum"]?.value
                default: actual = report.metrics[key]?.value
                }
                #expect(try actual == Money(value), "\(ticker) \(name): actual=\(actual?.decimalString ?? "missing") expected=\(value)")
            }
            for key in ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceFCF", "fcfYield", "shareholderYield"] {
                #expect(report.metrics[key]?.value == nil, "\(ticker) missing qualified capital: \(key)")
            }
            for (name, reason) in fixture.expectedUnavailable ?? [:] where name != "inversePrice" {
                let key = name == "sumQuarterDilutedEPS" ? "dilutedEPSQuarterSum" : name
                let metric = try #require(report.metrics[key])
                #expect(metric.value == nil && metric.unavailable != nil, "\(ticker) \(key): \(reason)")
            }
            if fixture.financialCompany {
                #expect(report.metrics["roic"]?.unavailable == .notApplicable)
                #expect(report.metrics["netDebtEBITDA"]?.unavailable == .notApplicable)
            }
            #expect(report.researchOnly && report.capitalInputs.isEmpty)
        }
    }

    @Test(arguments: completionTickers)
    func reportsReplayFromPersistedInputsAndModelReferences(ticker: String) async throws {
        let fixture = try CompletionFixture.load(ticker)
        let registry = ModelRegistry()
        let core = try await FundamentalModelV1.resolve(in: registry, at: completionExecution)
        let growth = try await FundamentalGrowthModelV1.resolve(in: registry, at: completionExecution)
        let completion = try await FundamentalCompletionModelV1.resolve(in: registry, at: completionExecution)
        let coreBytes = try ResearchDocument.encoded(FundamentalCalculator.calculate(fixture.input(), model: core, executionDate: completionExecution))
        let coreRead = try JSONDecoder().decode(FundamentalReport.self, from: coreBytes)
        #expect(try ResearchDocument.encoded(coreRead.recompute(using: core)) == coreBytes)
        let growthBytes = try ResearchDocument.encoded(FundamentalGrowthCalculator.calculate(fixture.input(), model: growth, executionDate: completionExecution))
        let growthRead = try JSONDecoder().decode(FundamentalGrowthReport.self, from: growthBytes)
        for (key, value) in fixture.expectedGrowth {
            #expect(try growthRead.metrics[key]?.value == Money(value), "\(ticker) \(key)")
        }
        if fixture.splitBasisEvidence == nil {
            for key in ["epsQuarter", "revenuePerShareQuarter", "fcfPerShareQuarter"] {
                #expect(growthRead.metrics[key]?.value == nil, "\(ticker) missing split basis: \(key)")
            }
        }
        #expect(try ResearchDocument.encoded(growthRead.recompute(using: growth)) == growthBytes)
        let completed = try FundamentalCompletionCalculator.calculate(fixture.completionInput(), model: completion, executionDate: completionExecution)
        for (key, value) in fixture.expectedCompletion ?? [:] {
            #expect(try completed.metrics[key]?.value == Money(value), "\(ticker) \(key)")
        }
        for key in fixture.expectedCompletionMissing ?? [] {
            let metric = try #require(completed.metrics[key])
            #expect(metric.value == nil && metric.unavailable != nil, "\(ticker) missing completion input: \(key)")
        }
        let bytes = try ResearchDocument.encoded(completed)
        let decoded = try JSONDecoder().decode(FundamentalCompletionReport.self, from: bytes)
        #expect(try ResearchDocument.encoded(decoded.recompute(using: completion)) == bytes)
        #expect(decoded.parameters == core.parameters.reference)
        #expect(throws: RegistryError.referenceMismatch) { try decoded.recompute(using: growth) }
    }

    @Test(arguments: completionTickers)
    func scoringAndHistoricalRangesNeverInventMissingPriceHistory(ticker: String) async throws {
        let fixture = try CompletionFixture.load(ticker)
        let model = try await FundamentalModelV1.resolve(in: ModelRegistry(), at: completionExecution)
        let score = try FundamentalScoring.calculate(fixture.input(), model: model, executionDate: completionExecution)
        #expect(score.valuation.metrics.values.allSatisfy { $0.prices.isEmpty })
        #expect(score.valuation.metrics.values.allSatisfy { $0.scorePercentile == nil && $0.rangePercentile == nil })
        #expect(score.total == nil && score.coveredWeightOf84 < 59)
    }

    @Test(arguments: completionTickers)
    func realInputAndThreeReportsSurviveSQLiteFreezeReopenAndRestore(ticker: String) async throws {
        let fixture = try CompletionFixture.load(ticker)
        let registry = ModelRegistry()
        let core = try await FundamentalModelV1.resolve(in: registry, at: completionExecution)
        let growth = try await FundamentalGrowthModelV1.resolve(in: registry, at: completionExecution)
        let completion = try await FundamentalCompletionModelV1.resolve(in: registry, at: completionExecution)
        let input = try fixture.completionInput()
        let captured = try MillisecondInstant(rounding: completionExecution)
        let permission = RetentionPermission(mayStore: true, mayBackup: true, evidenceReference: "fixed-factual-accounting-QA-not-provider-admission")
        let excerpt = FrozenObject(identity: .init(id: "excerpt", version: "v1"), kind: .input,
            payload: .string(try CompletionFixture.excerptBytes(ticker).base64EncodedString()), references: [],
            capturedAt: captured, permission: permission, synthetic: false)
        let source = FrozenObject(identity: .init(id: "input", version: "v1"), kind: .input,
            payload: .string(try ResearchDocument.encoded(input).base64EncodedString()),
            references: [.init(role: "excerpt", target: excerpt.identity, contentHash: try excerpt.contentHash())],
            capturedAt: captured, permission: permission, synthetic: false)
        let parameters = FrozenObject(identity: .init(id: "parameters", version: "v1"), kind: .parameters,
            payload: .string(try ResearchDocument.encoded(core.parameters).base64EncodedString()), references: [],
            capturedAt: captured, permission: permission, synthetic: false)
        let models = try [core, growth, completion].enumerated().map { index, model in
            FrozenObject(identity: .init(id: "model-\(index)", version: "v1"), kind: .model,
                payload: .string(try ResearchDocument.encoded(model.definition).base64EncodedString()),
                references: [.init(role: "parameters", target: parameters.identity, contentHash: try parameters.contentHash())],
                capturedAt: captured, permission: permission, synthetic: false)
        }
        let bytes = [try ResearchDocument.encoded(FundamentalCalculator.calculate(input.financials, model: core, executionDate: completionExecution)),
                     try ResearchDocument.encoded(FundamentalGrowthCalculator.calculate(input.financials, model: growth, executionDate: completionExecution)),
                     try ResearchDocument.encoded(FundamentalCompletionCalculator.calculate(input, model: completion, executionDate: completionExecution))]
        let outputs = try bytes.enumerated().map { index, value in
            FrozenObject(identity: .init(id: "result-\(index)", version: "v1"), kind: .result, payload: .string(value.base64EncodedString()),
                references: [.init(role: "input", target: source.identity, contentHash: try source.contentHash()),
                             .init(role: "model", target: models[index].identity, contentHash: try models[index].contentHash())],
                capturedAt: captured, permission: permission, synthetic: false)
        }
        let bundle = SnapshotBundle(sourceNamespace: UUID(), objects: [excerpt, source, parameters] + models + outputs,
            roots: [try .init(identity: .init(id: ticker, version: "v1"), kind: .analysisRun, references: outputs.enumerated().map {
                .init(role: "result-\($0.offset)", target: $0.element.identity, contentHash: try $0.element.contentHash())
            })])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("original.sqlite").path
        let first = try BusinessDataStore(path: path)
        try await first.freeze(bundle, expectedRevision: first.revision())
        let reopened = try BusinessDataStore(path: path)
        for object in bundle.objects {
            #expect(try await reopened.content(at: .init(namespace: bundle.sourceNamespace, identity: object.identity),
                expectedHash: object.contentHash()) == object.contentBytes())
        }
        let inventory = try BackupInventory(entries: bundle.objects.map { object in
            let length = Int64(try object.contentBytes().count)
            return .init(identity: object.identity, path: object.identity.id + ".json", contentHash: try object.contentHash(),
                bytes: length, compressedBytes: length)
        })
        let restored = try BusinessDataStore(path: directory.appendingPathComponent("restored.sqlite").path)
        let plan = try await restored.prepareRestore(bundle, inventory: inventory, mode: .replace, expectedRevision: restored.revision())
        _ = try await restored.commit(.init(planID: plan.id, digest: plan.digest))
        for object in bundle.objects {
            let target = try #require(plan.importedAddresses[object.identity])
            #expect(try await restored.content(at: target, expectedHash: object.contentHash()) == object.contentBytes())
        }
        // Reconstruct a fresh registry from restored bytes, not the original in-memory definitions.
        func restoredPayload(_ object: FrozenObject) async throws -> Data {
            let address = try #require(plan.importedAddresses[object.identity])
            let data = try await restored.content(at: address, expectedHash: object.contentHash())
            let content = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try #require(content["payload"] as? String)
            return try #require(Data(base64Encoded: payload))
        }
        let freshRegistry = ModelRegistry()
        try await freshRegistry.register(JSONDecoder().decode(ParameterSet.self, from: restoredPayload(parameters)))
        for frozen in models {
            try await freshRegistry.register(JSONDecoder().decode(ModelDefinition.self, from: restoredPayload(frozen)))
        }
        let coreRead = try await JSONDecoder().decode(FundamentalReport.self, from: restoredPayload(outputs[0]))
        let growthRead = try await JSONDecoder().decode(FundamentalGrowthReport.self, from: restoredPayload(outputs[1]))
        let completionRead = try await JSONDecoder().decode(FundamentalCompletionReport.self, from: restoredPayload(outputs[2]))
        let coreResolved = try await freshRegistry.resolve(reference: coreRead.model, at: completionExecution)
        let growthResolved = try await freshRegistry.resolve(reference: growthRead.model, at: completionExecution)
        let completionResolved = try await freshRegistry.resolve(reference: completionRead.model, at: completionExecution)
        #expect(try ResearchDocument.encoded(coreRead.recompute(using: coreResolved)) == bytes[0])
        #expect(try ResearchDocument.encoded(growthRead.recompute(using: growthResolved)) == bytes[1])
        #expect(try ResearchDocument.encoded(completionRead.recompute(using: completionResolved)) == bytes[2])
        // Generic typed graph QA does not expand the application ZIP's synthetic-only policy.
        let transfer = ResearchTransferStore(database: try DatabaseStore(path: path))
        await #expect(throws: SnapshotError.retentionDenied) { try await transfer.exportBackup() }
    }
}
