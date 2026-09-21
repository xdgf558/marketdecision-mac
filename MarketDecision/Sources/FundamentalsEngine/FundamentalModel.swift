import Foundation
import CoreDomain

/// Selected PARAMETERS_V1 policy. Metadata approval is not empirical calibration or supplier admission.
public enum FundamentalModelV1 {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let p = ParameterSet(id: "fundamentals.parameters", version: "PARAMETERS_V1",
            revisionID: UUID(uuidString: "A27AC275-71C8-49B6-8000-000000000001")!,
            values: ["includeOperatingLease": .boolean(true), "includeShortTermInvestment": .boolean(false),
                     "taxFallback": .decimal(try Money("0.21")), "leaseFallback": .decimal(try Money("0.05")),
                     "historyMinimumDays": .integer(504), "scoreHistoryMinimumDays": .integer(252),
                     "scoreMinimumCoveragePercent": .integer(70)],
            state: .approved, dispositionReference: "PARAMETERS_V1")
        let m = ModelDefinition(id: "fundamentals", version: "fundamentals.v1", revisionID: UUID(uuidString: "A27AC275-71C8-49B6-8000-000000000002")!,
            owner: "FundamentalsEngine", purpose: "Reproducible research calculations; not trading advice",
            inputs: [.init(name: "financials", unit: "USD", role: .required, allowsMultiple: true)],
            outputs: [.init(name: "ratios", unit: "ratio"), .init(name: "scores", unit: "points")],
            formula: "CALC-002...009; FND seven equal dimensions; PIT nearest-rank valuation; positive-denominator ratios",
            formulaVersion: "fundamentals.v1", implementationReference: "FundamentalsEngine/fundamentals.v1",
            defaultParameters: p.reference, numericPolicyVersion: Money.numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1", knownLimitations: ["Uncalibrated heuristic; coverage is not probability", "EV includes operating leases; EBITDA is not EBITDAR", "No provider or analysis eligibility grant"],
            testFixtures: ["FundamentalRatioTests", "FundamentalScoringTests", "HistoricalValuationTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-09-09T00:00:00.000Z"))
        return (p,m)
    }
    public static func resolve(in registry: ModelRegistry, at executionDate: Date) async throws -> ResolvedModel {
        let (p,m) = try definitions()
        // Concurrent callers may race to register the same immutable pair. Only duplicate version
        // is recoverable, and only after verifying exact content references. All other errors propagate.
        do { try await registry.register(p) }
        catch RegistryError.duplicateVersion { _ = try await registry.parameterSet(reference: p.reference) }
        do { try await registry.register(m) }
        catch RegistryError.duplicateVersion {
            let existing = try await registry.definition(id: m.id, version: m.version)
            guard existing.reference == m.reference else { throw RegistryError.referenceMismatch }
        }
        return try await registry.resolve(reference: m.reference, at: executionDate)
    }
    static func validate(_ model: ResolvedModel, executionDate: Date) throws {
        try model.validateForCalculation(at: executionDate)
        let (p,m) = try definitions()
        guard model.definition.reference == m.reference, model.parameters.reference == p.reference else {
            throw FundamentalError.unsupportedModel
        }
    }
}

func fsum(_ values: [Money]) throws -> Money { try values.reduce(Money("0")) { try $0.adding($1) } }
func fmean(_ values: [Money]) throws -> Money { try fsum(values).divided(by: String(values.count)) }
func fproduct(_ a: Money, _ b: Money) throws -> Money { try a.multiplied(by: b.decimalString) }
func fratio(_ numerator: Money?, _ denominator: Money?) throws -> FundamentalMetric {
    guard let numerator, let denominator else { return .init(nil) }
    guard denominator.amount > 0 else { return .init(nil, reason: .nonpositiveDenominator) }
    return .init(try numerator.divided(by: denominator.decimalString))
}
