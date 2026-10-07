import Foundation
import CoreDomain
import DataContracts

public struct SECFinancialRecomputation: Sendable {
    public let base: FundamentalReport
    public let growth: FundamentalGrowthReport
    public let completion: FundamentalCompletionReport
}

/// Accounting-only SEC input policy, independent of the immutable three formula definitions.
/// Industry-sensitive values are explicitly withheld pending a reviewed applicability mapping.
/// Structural validation never promotes stored numeric output to verified output.
public struct SECFinancialReport: Sendable, Codable {
    public static let formatVersion = "sec-financial-report.v1"
    public static let policyVersion = "sec-financial-evidence.v1"
    public let format, evidencePolicy: String
    public let evidence: SECFinancialEvidence
    public let inputSnapshot: FundamentalCompletionSnapshot
    public let models: [ModelDefinition]
    public let parameters: ParameterSet
    public let baseReport: FundamentalReport
    public let growthReport: FundamentalGrowthReport
    public let completionReport: FundamentalCompletionReport
    public let researchOnly: Bool
    public let historicalPITQualified: Bool
    public let capitalInputsAllowed: Bool
    public let cacheState: String
    public var cutoff: Date { evidence.cutoff }
    public var executionDate: Date { inputSnapshot.financials.executionDate }

    private init(prepared: SECFinancialPrepared, snapshot: FundamentalCompletionSnapshot,
                 models: [ModelDefinition], parameters: ParameterSet, reports: SECFinancialRecomputation) {
        format = Self.formatVersion; evidencePolicy = Self.policyVersion; evidence = prepared.evidence
        inputSnapshot = snapshot; self.models = models; self.parameters = parameters
        baseReport = reports.base; growthReport = reports.growth; completionReport = reports.completion
        researchOnly = true; historicalPITQualified = false; capitalInputsAllowed = false
        cacheState = "requires-explicit-recompute"
    }

    public static func make(cik: String, facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord],
                            cutoff: Date, executionDate: Date,
                            classification: SECFinancialClassificationEvidence? = nil) async throws -> Self {
        try Task.checkCancellation()
        let prepared = try SECFinancialEvidenceAdapter.prepare(cik: cik, facts: facts, submissions: submissions,
            cutoff: cutoff, classification: classification)
        let snapshot = try FundamentalCompletionSnapshot(input: prepared.input, executionDate: executionDate)
        let (parameters, base) = try FundamentalModelV1.definitions()
        let models = [base, try FundamentalGrowthModelV1.definitions().1, try FundamentalCompletionModelV1.definitions().1]
        let reports = try await calculate(snapshot: snapshot, models: models, parameters: parameters)
        let result = Self(prepared: prepared, snapshot: snapshot, models: models, parameters: parameters, reports: reports)
        try result.validate()
        return result
    }

    /// Reconstruct from ALL parent records: a valid-looking subset is not sufficient to establish
    /// the selected revision, latest reporting period, or absence of a conflicting alias.
    public func validateEvidence(facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord],
                                 classification: SECFinancialClassificationEvidence?) throws {
        let rebuilt = try SECFinancialEvidenceAdapter.prepare(cik: evidence.cik, facts: facts, submissions: submissions,
            cutoff: evidence.cutoff, classification: classification)
        try checkPrepared(rebuilt)
    }

    public func validate() throws {
        guard format == Self.formatVersion, evidencePolicy == Self.policyVersion, researchOnly,
              !historicalPITQualified, !capitalInputsAllowed, cacheState == "requires-explicit-recompute" else {
            throw SECFinancialError.unsupportedFormat
        }
        let rebuilt = try SECFinancialEvidenceAdapter.prepare(cik: evidence.cik, facts: evidence.facts,
            submissions: evidence.submissions, cutoff: evidence.cutoff, classification: evidence.classification)
        try checkPrepared(rebuilt)
        let (expectedParameters, base) = try FundamentalModelV1.definitions()
        let expectedModels = [base, try FundamentalGrowthModelV1.definitions().1, try FundamentalCompletionModelV1.definitions().1]
        guard parameters == expectedParameters, models.count == 3, models.map(\.reference) == expectedModels.map(\.reference),
              baseReport.model == models[0].reference, growthReport.model == models[1].reference,
              completionReport.model == models[2].reference,
              [baseReport.parameters, growthReport.parameters, completionReport.parameters].allSatisfy({ $0 == parameters.reference }),
              try Self.bytes(baseReport.inputSnapshot) == Self.bytes(inputSnapshot.financials),
              try Self.bytes(growthReport.inputSnapshot) == Self.bytes(inputSnapshot.financials),
              try Self.bytes(completionReport.inputSnapshot) == Self.bytes(inputSnapshot),
              baseReport.researchOnly, growthReport.researchOnly, completionReport.researchOnly,
              baseReport.confidence == .medium else { throw SECFinancialError.inconsistentEvidence }
        try parameters.validate(); for model in models { try model.validate() }
        let required = Set(SECFinancialEvidenceAdapter.limitations)
        for limitations in [baseReport.limitations, growthReport.limitations, completionReport.limitations] {
            guard required.isSubset(of: Set(limitations)) else { throw SECFinancialError.inconsistentEvidence }
        }
        for metrics in [baseReport.metrics, growthReport.metrics, completionReport.metrics] {
            guard !metrics.isEmpty, metrics.count <= 256, metrics.allSatisfy({ key, metric in
                !key.isEmpty && key.utf8.count <= 128 && ((metric.value == nil) == (metric.unavailable != nil))
                    && metric.flags.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
            }) else { throw SECFinancialError.inconsistentEvidence }
        }
        for key in ["roic", "netDebtEBITDA"] {
            guard baseReport.metrics[key]?.value == nil, baseReport.metrics[key]?.unavailable == .missingEvidence else {
                throw SECFinancialError.inconsistentEvidence
            }
        }
        for key in ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceBook", "priceSales", "priceFCF",
                    "priceFCFExSBC", "evEBITDA", "evSales", "fcfYield", "fcfExSBCYield", "earningsYield", "shareholderYield"] {
            guard let value = baseReport.metrics[key], value.value == nil, value.unavailable != nil else {
                throw SECFinancialError.inconsistentEvidence
            }
        }
    }

    private func checkPrepared(_ prepared: SECFinancialPrepared) throws {
        let rebuilt = try FundamentalCompletionSnapshot(input: prepared.input, executionDate: executionDate)
        guard try Self.bytes(prepared.evidence) == Self.bytes(evidence),
              try Self.bytes(rebuilt) == Self.bytes(inputSnapshot) else { throw SECFinancialError.inconsistentEvidence }
    }

    public func recompute() async throws -> SECFinancialRecomputation {
        try validate(); try Task.checkCancellation()
        return try await Self.calculate(snapshot: inputSnapshot, models: models, parameters: parameters)
    }
    public func cachedReportsMatch(_ replay: SECFinancialRecomputation) throws -> Bool {
        try Self.bytes(baseReport) == Self.bytes(replay.base) && Self.bytes(growthReport) == Self.bytes(replay.growth)
            && Self.bytes(completionReport) == Self.bytes(replay.completion)
    }
    private static func calculate(snapshot: FundamentalCompletionSnapshot, models: [ModelDefinition],
                                  parameters: ParameterSet) async throws -> SECFinancialRecomputation {
        guard models.count == 3 else { throw SECFinancialError.inconsistentEvidence }
        let registry = ModelRegistry(); try await registry.register(parameters)
        for model in models { try await registry.register(model) }
        let time = snapshot.financials.executionDate
        let baseModel = try await registry.resolve(reference: models[0].reference, at: time)
        let growthModel = try await registry.resolve(reference: models[1].reference, at: time)
        let completionModel = try await registry.resolve(reference: models[2].reference, at: time)
        let input = snapshot.financials.input
        let raw = try FundamentalCalculator.calculate(input, model: baseModel, executionDate: time)
        var metrics = raw.metrics
        // The fixed input's true flag only suppresses the old Bool-based calculator paths. It is
        // NOT evidence that this issuer is financial. The SEC policy records the actual reason.
        for key in ["roic", "netDebtEBITDA"] { metrics[key] = .init(nil, reason: .missingEvidence, flags: ["INDUSTRY_APPLICABILITY_UNKNOWN"]) }
        let base = FundamentalReport(inputSnapshot: raw.inputSnapshot, model: raw.model, parameters: raw.parameters,
            limitations: raw.limitations, metrics: metrics, confidence: raw.confidence, researchOnly: true)
        try Task.checkCancellation()
        return try .init(base: base, growth: FundamentalGrowthCalculator.calculate(input, model: growthModel, executionDate: time),
            completion: FundamentalCompletionCalculator.calculate(.init(financials: input, revenueYears: snapshot.revenueYears),
                model: completionModel, executionDate: time))
    }
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, evidencePolicy, evidence, inputSnapshot, models, parameters, baseReport, growthReport, completionReport
        case researchOnly, historicalPITQualified, capitalInputsAllowed, cacheState
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: SECFinancialCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else { throw SECFinancialError.unsupportedFormat }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format); evidencePolicy = try c.decode(String.self, forKey: .evidencePolicy)
        evidence = try c.decode(SECFinancialEvidence.self, forKey: .evidence)
        inputSnapshot = try c.decode(FundamentalCompletionSnapshot.self, forKey: .inputSnapshot)
        models = try c.decode([ModelDefinition].self, forKey: .models); parameters = try c.decode(ParameterSet.self, forKey: .parameters)
        baseReport = try c.decode(FundamentalReport.self, forKey: .baseReport)
        growthReport = try c.decode(FundamentalGrowthReport.self, forKey: .growthReport)
        completionReport = try c.decode(FundamentalCompletionReport.self, forKey: .completionReport)
        researchOnly = try c.decode(Bool.self, forKey: .researchOnly)
        historicalPITQualified = try c.decode(Bool.self, forKey: .historicalPITQualified)
        capitalInputsAllowed = try c.decode(Bool.self, forKey: .capitalInputsAllowed)
        cacheState = try c.decode(String.self, forKey: .cacheState)
        try validate()
    }
}
private struct SECFinancialCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
