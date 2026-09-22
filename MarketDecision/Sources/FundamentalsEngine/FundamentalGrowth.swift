import Foundation
import CoreDomain

/// An additive calculator for already selected CALC-002/003/006 rules. The original
/// fundamentals.v1 definition and its frozen reports retain their exact behavior.
public enum FundamentalGrowthModelV1 {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = try FundamentalModelV1.definitions().0
        let definition = ModelDefinition(id: "fundamentals-growth", version: "fundamentals-growth.v1",
            revisionID: UUID(uuidString: "A27AC275-71C8-49B6-8000-000000000003")!,
            owner: "FundamentalsEngine", purpose: "Reproducible quarterly growth; no eligibility grant",
            inputs: [.init(name: "quarters", unit: "USD; USD/shares; shares", role: .required, allowsMultiple: true)],
            outputs: [.init(name: "growth", unit: "ratio"), .init(name: "quarterlyPerShare", unit: "USD/shares")],
            formula: "CALC-003: fiscal-quarter YoY/QoQ; positive-base growth and signed changes; reported quarterly diluted shares for revenue/FCF per share. CALC-002: TTM operating-income YoY with annual-span comparability. CALC-006: positive cash expenditures.",
            formulaVersion: "fundamentals-growth.v1", implementationReference: "FundamentalsEngine/FundamentalGrowth.swift",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion,
            state: .approved, dispositionReference: "PARAMETERS_V1/CALC-002/003/006",
            knownLimitations: ["No TTM per-share aggregation policy", "No CAGR or nondefault debt model", "Research only; no supplier or investment eligibility"],
            testFixtures: ["FundamentalGrowthTests"], introducedAt: try MillisecondInstant(iso8601: "2026-09-22T00:00:00.000Z"))
        return (parameters, definition)
    }

    public static func resolve(in registry: ModelRegistry, at executionDate: Date) async throws -> ResolvedModel {
        let (parameters, definition) = try definitions()
        do { try await registry.register(parameters) }
        catch RegistryError.duplicateVersion { _ = try await registry.parameterSet(reference: parameters.reference) }
        do { try await registry.register(definition) }
        catch RegistryError.duplicateVersion {
            guard try await registry.definition(id: definition.id, version: definition.version).reference == definition.reference else {
                throw RegistryError.referenceMismatch
            }
        }
        return try await registry.resolve(reference: definition.reference, at: executionDate)
    }

    static func validate(_ model: ResolvedModel, at executionDate: Date) throws {
        try model.validateForCalculation(at: executionDate)
        let (parameters, definition) = try definitions()
        guard model.parameters.reference == parameters.reference, model.definition.reference == definition.reference else {
            throw FundamentalError.unsupportedModel
        }
    }
}

public struct FundamentalGrowthReport: Sendable, Codable {
    public let inputSnapshot: FundamentalInputSnapshot
    public let model: RegistryReference, parameters: RegistryReference
    public let metrics: [String: FundamentalMetric]
    public let limitations: [String]
    public let researchOnly: Bool

    public func recompute(using resolved: ResolvedModel) throws -> FundamentalGrowthReport {
        guard resolved.definition.reference == model, resolved.parameters.reference == parameters else {
            throw RegistryError.referenceMismatch
        }
        return try FundamentalGrowthCalculator.calculate(inputSnapshot.input, model: resolved,
            executionDate: inputSnapshot.executionDate)
    }
}

public enum FundamentalGrowthCalculator {
    // This existing dictionary field is deliberately not added to FundamentalField: doing so
    // would also change input validation for old fundamentals.v1 reports.
    public static let dilutedShareFieldID = "shares.weighted-average-diluted"

    public static func calculate(_ input: FundamentalInput, model: ResolvedModel,
                                 executionDate: Date) throws -> FundamentalGrowthReport {
        try FundamentalGrowthModelV1.validate(model, at: executionDate)
        let snapshot = try FundamentalInputSnapshot(input: input, executionDate: executionDate)
        let splitKnown = input.splitBasisEvidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let flowFields: Set<String> = Set([FundamentalField.revenue, .operatingIncome, .netIncome, .ocf, .capex,
            .sbc, .buybacks, .issuance, .dividends].map(\.rawValue))
        let expenseFields: Set<String> = Set([FundamentalField.capex, .sbc, .buybacks, .issuance, .dividends].map(\.rawValue))
        for fact in input.normalization.values where fact.periodType == .quarter {
            if flowFields.contains(fact.fieldID) {
                guard fact.nature == .additiveFlow, fact.unit == "USD", fact.derivation != .fourQuarterSum else {
                    throw FundamentalError.incompatibleInput
                }
            }
            if expenseFields.contains(fact.fieldID), fact.value.amount < 0 { throw FundamentalError.incompatibleInput }
        }

        func quarter(_ fieldID: String, at index: Int) -> FundamentalMetric {
            guard input.quarters.indices.contains(index) else { return .init(nil, reason: .insufficientHistory) }
            let period = input.quarters[index]
            guard let fact = input.normalization.values.first(where: {
                $0.fieldID == fieldID && $0.periodType == .quarter && $0.periodStart == period.start && $0.periodEnd == period.end
            }) else { return .init(nil) }
            if fieldID == FundamentalField.dilutedEPS.rawValue || fieldID == dilutedShareFieldID {
                let shares = fieldID == dilutedShareFieldID
                guard splitKnown, fact.derivation == .reported,
                      fact.nature == (shares ? .nonadditive : .perShare), fact.unit == (shares ? "shares" : "USD/shares"),
                      fact.sourceFactIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    return .init(nil, reason: .missingEvidence)
                }
                if shares && fact.value.amount <= 0 { return .init(nil, reason: .nonpositiveDenominator) }
            }
            return .init(fact.value)
        }
        func fcf(at index: Int) throws -> FundamentalMetric {
            let ocf = quarter(FundamentalField.ocf.rawValue, at: index)
            let capex = quarter(FundamentalField.capex.rawValue, at: index)
            guard let a = ocf.value, let b = capex.value else {
                return .init(nil, reason: ocf.unavailable ?? capex.unavailable ?? .missingInput)
            }
            return .init(try a.subtracting(b))
        }
        func perShare(_ numerator: FundamentalMetric, at index: Int) throws -> FundamentalMetric {
            let shares = quarter(dilutedShareFieldID, at: index)
            guard let a = numerator.value, let b = shares.value else {
                return .init(nil, reason: numerator.unavailable ?? shares.unavailable ?? .missingInput)
            }
            return try fratio(a, b)
        }
        var series: [String: [FundamentalMetric]] = [:]
        for (key, field) in [("revenue", FundamentalField.revenue), ("operatingIncome", .operatingIncome),
                             ("netIncome", .netIncome), ("eps", .dilutedEPS)] {
            series[key] = input.quarters.indices.map { quarter(field.rawValue, at: $0) }
        }
        series["fcf"] = try input.quarters.indices.map { try fcf(at: $0) }
        for (key, base) in [("revenuePerShare", "revenue"), ("fcfPerShare", "fcf")] {
            series[key] = try input.quarters.indices.map { try perShare(series[base]![$0], at: $0) }
        }
        var metrics: [String: FundamentalMetric] = [:]
        let latest = input.quarters.count - 1
        for (key, values) in series {
            metrics[key + "Quarter"] = values[latest]
            // CALC-003 compares fiscal-quarter positions. No unapproved day-count adjustment
            // or quarterly day-difference tolerance is added here.
            for (suffix, offset) in [("QuarterYoY", 4), ("QuarterQoQ", 1)] {
                let prior = latest >= offset ? values[latest - offset] : .init(nil, reason: .insufficientHistory)
                let result = try growth(values[latest], prior)
                metrics[key + suffix] = result.rate
                metrics[key + suffix + "Change"] = result.change
            }
        }
        if input.quarters.count == 8 {
            let values = series["operatingIncome"]!
            func sum(_ window: ArraySlice<FundamentalMetric>) throws -> FundamentalMetric {
                guard window.allSatisfy({ $0.value != nil }) else { return .init(nil) }
                return .init(try fsum(window.map { $0.value! }))
            }
            let currentDays = try input.quarters[4].start.days(through: input.quarters[7].end).count
            let priorDays = try input.quarters[0].start.days(through: input.quarters[3].end).count
            let result = try growth(sum(values.suffix(4)), sum(values.prefix(4)), comparable: abs(currentDays - priorDays) <= 7)
            metrics["operatingIncomeTTMYoY"] = result.rate
            metrics["operatingIncomeTTMYoYChange"] = result.change
        } else {
            metrics["operatingIncomeTTMYoY"] = .init(nil, reason: .insufficientHistory)
            metrics["operatingIncomeTTMYoYChange"] = .init(nil, reason: .insufficientHistory)
        }
        return .init(inputSnapshot: snapshot, model: model.definition.reference, parameters: model.parameters.reference,
            metrics: metrics, limitations: Array(Set(input.inputLimitations + input.normalization.values.flatMap(\.limitations)
                + ["RESEARCH_ONLY_NO_ELIGIBILITY_GRANT", "QUARTERLY_PER_SHARE_ONLY_NO_TTM_AGGREGATION"])).sorted(), researchOnly: true)
    }

    private static func growth(_ current: FundamentalMetric, _ prior: FundamentalMetric, comparable: Bool = true) throws
        -> (rate: FundamentalMetric, change: FundamentalMetric) {
        guard comparable else { return (.init(nil, reason: .notComparable), .init(nil, reason: .notComparable)) }
        guard let a = current.value, let b = prior.value else {
            let missing = FundamentalMetric(nil, reason: current.unavailable ?? prior.unavailable ?? .missingInput)
            return (missing, missing)
        }
        let change = try a.subtracting(b)
        guard b.amount > 0 else {
            let label = b.amount < 0 ? (a.amount > 0 ? "LOSS_TO_PROFIT" : a.amount == 0 ? "LOSS_TO_ZERO" : "REMAINED_LOSS")
                : (a.amount > 0 ? "ZERO_TO_POSITIVE" : a.amount < 0 ? "ZERO_TO_LOSS" : "REMAINED_ZERO")
            return (.init(nil, reason: .nonpositiveDenominator, flags: [label]), .init(change, flags: [label]))
        }
        return (try fratio(change, b), .init(change))
    }
}
