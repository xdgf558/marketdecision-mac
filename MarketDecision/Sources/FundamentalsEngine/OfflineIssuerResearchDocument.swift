import Foundation
import CoreDomain
import DataContracts

public struct OfflineIssuerResearchRecomputation: Sendable {
    public let base: FundamentalReport
    public let growth: FundamentalGrowthReport
    public let completion: FundamentalCompletionReport
}

/// Independent manual-excerpt format. It cannot be decoded as research-demo.v1 or used
/// to authorize a provider, capital input, historical price study or original-document backup.
/// Cache validation is structural; a reader must explicitly call recompute for mathematical verification.
public struct OfflineIssuerResearchDocument: Sendable, Codable, Identifiable {
    public static let formatVersion = "offline-issuer-research.v1"
    public let format: String
    public let id: UUID
    public let ticker, cik: String
    public let excerptProfile: String
    public let excerptData: Data
    public let excerptHash: String
    public let inputSnapshot: FundamentalCompletionSnapshot
    public let models: [ModelDefinition]
    public let parameters: ParameterSet
    public let baseReport: FundamentalReport
    public let growthReport: FundamentalGrowthReport
    public let completionReport: FundamentalCompletionReport
    public let retention: OfflineIssuerResearchRetention
    public let researchOnly: Bool
    public let historicalPITQualified: Bool
    public let providerAdmitted: Bool
    public let capitalInputsAllowed: Bool
    public let cacheState: String
    public var synthetic: Bool { false }

    private init(id: UUID, context: OfflineIssuerResearchContext, excerptData: Data,
                 inputSnapshot: FundamentalCompletionSnapshot, models: [ModelDefinition], parameters: ParameterSet,
                 reports: OfflineIssuerResearchRecomputation, retention: OfflineIssuerResearchRetention) {
        format = Self.formatVersion; self.id = id; ticker = context.ticker; cik = context.cik
        excerptProfile = OfflineIssuerResearchContext.mappingVersion
        self.excerptData = excerptData; excerptHash = digest(excerptData); self.inputSnapshot = inputSnapshot
        self.models = models; self.parameters = parameters
        baseReport = reports.base; growthReport = reports.growth; completionReport = reports.completion
        self.retention = retention; researchOnly = true; historicalPITQualified = false
        providerAdmitted = false; capitalInputsAllowed = false; cacheState = "requires-explicit-recompute"
    }

    public static func make(excerptData: Data, asOf: Date, executionDate: Date,
                            retention: OfflineIssuerResearchRetention, id: UUID = UUID()) async throws -> Self {
        try retention.validate()
        let context = try OfflineIssuerResearchContext.decode(excerptData: excerptData)
        let input = try context.input(asOf: asOf)
        let snapshot = try FundamentalCompletionSnapshot(input: input, executionDate: executionDate)
        let (parameters, baseModel) = try FundamentalModelV1.definitions()
        let models = [baseModel, try FundamentalGrowthModelV1.definitions().1, try FundamentalCompletionModelV1.definitions().1]
        let reports = try await calculate(snapshot: snapshot, models: models, parameters: parameters)
        let document = Self(id: id, context: context, excerptData: excerptData, inputSnapshot: snapshot,
                            models: models, parameters: parameters, reports: reports, retention: retention)
        try document.validate()
        return document
    }

    public func context() throws -> OfflineIssuerResearchContext {
        guard digest(excerptData) == excerptHash else { throw OfflineIssuerResearchError.inconsistentEvidence }
        return try OfflineIssuerResearchContext.decode(excerptData: excerptData)
    }

    /// Checks byte identity, the closed excerpt profile, reconstructed complete inputs and exact
    /// model bindings. It does not run formulas or upgrade the imported cache to verified results.
    public func validate() throws {
        guard format == Self.formatVersion, excerptProfile == OfflineIssuerResearchContext.mappingVersion else {
            throw OfflineIssuerResearchError.unsupportedFormat
        }
        guard researchOnly, !historicalPITQualified, !providerAdmitted, !capitalInputsAllowed,
              cacheState == "requires-explicit-recompute" else { throw OfflineIssuerResearchError.invalidDocument }
        try retention.validate()
        let context = try context()
        guard ticker == context.ticker, cik == context.cik else { throw OfflineIssuerResearchError.inconsistentEvidence }
        let snapshot = inputSnapshot.financials
        let rebuilt = try context.input(asOf: snapshot.input.normalization.asOf)
        let expectedSnapshot = try FundamentalCompletionSnapshot(input: rebuilt, executionDate: snapshot.executionDate)
        let requiredLimitations = Set(context.knownMissing + OfflineIssuerResearchContext.requiredLimitations)
        guard try Self.bytes(expectedSnapshot) == Self.bytes(inputSnapshot),
              try Self.bytes(baseReport.inputSnapshot) == Self.bytes(snapshot),
              try Self.bytes(growthReport.inputSnapshot) == Self.bytes(snapshot),
              try Self.bytes(completionReport.inputSnapshot) == Self.bytes(inputSnapshot),
              snapshot.input.classes.isEmpty,
              snapshot.input.normalization.selectedSourceFacts.isEmpty,
              snapshot.input.normalization.unmappedSourceFacts.isEmpty,
              Set(OfflineIssuerResearchContext.requiredLimitations).isSubset(of: Set(snapshot.input.inputLimitations)),
              [baseReport.limitations, growthReport.limitations, completionReport.limitations].allSatisfy({
                  requiredLimitations.isSubset(of: Set($0))
              }),
              baseReport.confidence == .medium,
              baseReport.sourceVersions == rebuilt.financials.sourceVersions,
              baseReport.researchOnly, growthReport.researchOnly, completionReport.researchOnly else {
            throw OfflineIssuerResearchError.inconsistentEvidence
        }
        let (expectedParameters, baseModel) = try FundamentalModelV1.definitions()
        let expectedModels = [baseModel, try FundamentalGrowthModelV1.definitions().1, try FundamentalCompletionModelV1.definitions().1]
        guard parameters == expectedParameters, models.count == 3,
              models.map(\.reference) == expectedModels.map(\.reference),
              baseReport.model == models[0].reference, growthReport.model == models[1].reference,
              completionReport.model == models[2].reference,
              [baseReport.parameters, growthReport.parameters, completionReport.parameters].allSatisfy({ $0 == parameters.reference })
        else { throw OfflineIssuerResearchError.inconsistentEvidence }
        try parameters.validate()
        for model in models { try model.validate() }
        for metrics in [baseReport.metrics, growthReport.metrics, completionReport.metrics] {
            guard !metrics.isEmpty, metrics.count <= 256, metrics.allSatisfy({ key, value in
                issuerText(key, maximum: 128) && ((value.value == nil) == (value.unavailable != nil))
                    && value.flags.allSatisfy({ issuerText($0, maximum: 512) })
            }) else { throw OfflineIssuerResearchError.invalidDocument }
        }
        // Imported cached output must not claim price-derived analysis even before the explicit replay.
        for key in ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceBook", "priceSales", "priceFCF",
                    "priceFCFExSBC", "evEBITDA", "evSales", "fcfYield", "fcfExSBCYield", "earningsYield", "shareholderYield"] {
            guard let metric = baseReport.metrics[key], metric.value == nil, metric.unavailable != nil else {
                throw OfflineIssuerResearchError.invalidDocument
            }
        }
    }

    /// Explicit replay with a fresh registry built solely from the frozen, exact definitions.
    /// Cached numbers and the excerpt's expected* test-oracle fields are never inputs.
    public func recompute() async throws -> OfflineIssuerResearchRecomputation {
        try validate()
        return try await Self.calculate(snapshot: inputSnapshot, models: models, parameters: parameters)
    }

    public func cachedReportsMatch(_ replay: OfflineIssuerResearchRecomputation) throws -> Bool {
        try Self.bytes(baseReport) == Self.bytes(replay.base)
            && Self.bytes(growthReport) == Self.bytes(replay.growth)
            && Self.bytes(completionReport) == Self.bytes(replay.completion)
    }

    private static func calculate(snapshot: FundamentalCompletionSnapshot, models: [ModelDefinition],
                                  parameters: ParameterSet) async throws -> OfflineIssuerResearchRecomputation {
        guard models.count == 3 else { throw OfflineIssuerResearchError.invalidDocument }
        let registry = ModelRegistry()
        try await registry.register(parameters)
        for model in models { try await registry.register(model) }
        let time = snapshot.financials.executionDate
        let base = try await registry.resolve(reference: models[0].reference, at: time)
        let growth = try await registry.resolve(reference: models[1].reference, at: time)
        let completion = try await registry.resolve(reference: models[2].reference, at: time)
        let input = snapshot.financials.input
        return try .init(base: FundamentalCalculator.calculate(input, model: base, executionDate: time),
            growth: FundamentalGrowthCalculator.calculate(input, model: growth, executionDate: time),
            completion: FundamentalCompletionCalculator.calculate(.init(financials: input, revenueYears: snapshot.revenueYears),
                model: completion, executionDate: time))
    }

    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, id, ticker, cik, excerptProfile, excerptData, excerptHash, inputSnapshot, models, parameters
        case baseReport, growthReport, completionReport, retention, researchOnly, historicalPITQualified
        case providerAdmitted, capitalInputsAllowed, cacheState
    }
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: IssuerDocumentKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OfflineIssuerResearchError.unsupportedFormat
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format); id = try c.decode(UUID.self, forKey: .id)
        ticker = try c.decode(String.self, forKey: .ticker); cik = try c.decode(String.self, forKey: .cik)
        excerptProfile = try c.decode(String.self, forKey: .excerptProfile)
        excerptData = try c.decode(Data.self, forKey: .excerptData); excerptHash = try c.decode(String.self, forKey: .excerptHash)
        inputSnapshot = try c.decode(FundamentalCompletionSnapshot.self, forKey: .inputSnapshot)
        models = try c.decode([ModelDefinition].self, forKey: .models); parameters = try c.decode(ParameterSet.self, forKey: .parameters)
        baseReport = try c.decode(FundamentalReport.self, forKey: .baseReport)
        growthReport = try c.decode(FundamentalGrowthReport.self, forKey: .growthReport)
        completionReport = try c.decode(FundamentalCompletionReport.self, forKey: .completionReport)
        retention = try c.decode(OfflineIssuerResearchRetention.self, forKey: .retention)
        researchOnly = try c.decode(Bool.self, forKey: .researchOnly)
        historicalPITQualified = try c.decode(Bool.self, forKey: .historicalPITQualified)
        providerAdmitted = try c.decode(Bool.self, forKey: .providerAdmitted)
        capitalInputsAllowed = try c.decode(Bool.self, forKey: .capitalInputsAllowed)
        cacheState = try c.decode(String.self, forKey: .cacheState)
        try validate()
    }
}

private struct IssuerDocumentKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
