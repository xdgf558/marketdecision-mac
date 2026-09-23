import Foundation
import CoreDomain

/// Explicit full-year windows are separate from the original three-year tax window.
/// They select reported annual revenue, never annualized quarterly observations.
public struct FundamentalCompletionInput: Sendable, Codable {
    public let financials: FundamentalInput
    public let revenueYears: [FiscalYearWindow]
    public init(financials: FundamentalInput, revenueYears: [FiscalYearWindow] = []) throws {
        self.financials = financials; self.revenueYears = revenueYears
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case financials, revenueYears }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(financials: container.decode(FundamentalInput.self, forKey: .financials),
                      revenueYears: container.decode([FiscalYearWindow].self, forKey: .revenueYears))
    }
    func validate() throws {
        try financials.validate()
        for year in revenueYears {
            _ = try FiscalYearWindow(start: year.start, end: year.end)
            guard year.end <= financials.quarters.last!.end else { throw FundamentalError.invalidWindow }
        }
        for (a, b) in zip(revenueYears, revenueYears.dropFirst()) {
            guard try a.end.addingDays(1) == b.start else { throw FundamentalError.invalidWindow }
        }
    }
}

public struct FundamentalCompletionSnapshot: Sendable, Codable {
    public static let formatVersion = "fundamental-completion-input.v1"
    public let financials: FundamentalInputSnapshot
    public let revenueYears: [FiscalYearWindow]
    public init(input: FundamentalCompletionInput, executionDate: Date) throws {
        try input.validate()
        financials = try FundamentalInputSnapshot(input: input.financials, executionDate: executionDate)
        revenueYears = input.revenueYears
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, financials, revenueYears }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .formatVersion) == Self.formatVersion else {
            throw FundamentalError.incompatibleInput
        }
        let financials = try container.decode(FundamentalInputSnapshot.self, forKey: .financials)
        try self.init(input: FundamentalCompletionInput(financials: financials.input,
            revenueYears: container.decode([FiscalYearWindow].self, forKey: .revenueYears)), executionDate: financials.executionDate)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .formatVersion)
        try container.encode(financials, forKey: .financials); try container.encode(revenueYears, forKey: .revenueYears)
    }
}

/// New implementation identity for selected formulas, sharing the original approved
/// parameter reference. Neither existing calculator nor immutable dictionary is altered.
public enum FundamentalCompletionModelV1 {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = try FundamentalModelV1.definitions().0
        let definition = ModelDefinition(id: "fundamentals-completion", version: "fundamentals-completion.v1",
            revisionID: UUID(uuidString: "A27AC275-71C8-49B6-8000-000000000004")!,
            owner: "FundamentalsEngine", purpose: "Annual revenue growth, explicit cash allocation and paired ex-SBC research metrics",
            inputs: [.init(name: "financials", unit: "USD; USD/shares; shares", role: .required, allowsMultiple: true)],
            outputs: [.init(name: "metrics", unit: "USD; USD/shares; ratio")],
            formula: "SPEC 6.3.4: revenue CAGR=(latest complete fiscal-year revenue/base)^(1/3 or 1/5)-1; exact rational integer root, 18-place half-even. CALC-002/003/006: contiguous windows, positive-base growth, signed cash allocation; paired FCF ex-SBC and quarterly per-share metrics.",
            formulaVersion: "fundamentals-completion.v1", implementationReference: "FundamentalsEngine/FundamentalCompletion.swift",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion,
            state: .approved, dispositionReference: "PARAMETERS_V1/CALC-002/003/006; SPEC-6.3.4/6.3.5",
            knownLimitations: ["No TTM per-share aggregation policy or nondefault debt model", "Cash acquisition payments need explicit issuer mapping; no net-of-acquired-cash substitution", "Research only; no supplier or PIT eligibility"],
            testFixtures: ["FundamentalCompletionTests"], introducedAt: try MillisecondInstant(iso8601: "2026-09-22T00:00:00.000Z"))
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
        guard model.definition.reference == definition.reference, model.parameters.reference == parameters.reference else {
            throw FundamentalError.unsupportedModel
        }
    }
}

public struct FundamentalCompletionReport: Sendable, Codable {
    public let inputSnapshot: FundamentalCompletionSnapshot
    public let model: RegistryReference, parameters: RegistryReference
    public let metrics: [String: FundamentalMetric]
    public let limitations: [String]
    public let researchOnly: Bool
    public func recompute(using resolved: ResolvedModel) throws -> FundamentalCompletionReport {
        guard resolved.definition.reference == model, resolved.parameters.reference == parameters else { throw RegistryError.referenceMismatch }
        return try FundamentalCompletionCalculator.calculate(
            FundamentalCompletionInput(financials: inputSnapshot.financials.input, revenueYears: inputSnapshot.revenueYears),
            model: resolved, executionDate: inputSnapshot.financials.executionDate)
    }
}

public enum FundamentalCompletionCalculator {
    /// Cash consideration actually paid, excluding noncash consideration. A net-of-acquired-cash
    /// aggregate must not fill this field without an explicit, reproducible decomposition.
    public static let acquisitionFieldID = "cash-flow.acquisitions-cash-paid"

    public static func calculate(_ input: FundamentalCompletionInput, model: ResolvedModel,
                                 executionDate: Date) throws -> FundamentalCompletionReport {
        try FundamentalCompletionModelV1.validate(model, at: executionDate)
        let snapshot = try FundamentalCompletionSnapshot(input: input, executionDate: executionDate)
        let f = input.financials
        let fields = [("dividends", FundamentalField.dividends.rawValue), ("buybacks", FundamentalField.buybacks.rawValue),
                      ("issuance", FundamentalField.issuance.rawValue), ("capex", FundamentalField.capex.rawValue),
                      ("sbc", FundamentalField.sbc.rawValue), ("acquisitions", acquisitionFieldID)]
        let expenses = Set(fields.map(\.1))
        let flows = expenses.union([FundamentalField.ocf.rawValue, FundamentalField.netIncome.rawValue, FundamentalField.revenue.rawValue])
        for fact in f.normalization.values where fact.periodType == .quarter && flows.contains(fact.fieldID) {
            guard fact.nature == .additiveFlow, fact.unit == "USD", fact.derivation != .fourQuarterSum,
                  !expenses.contains(fact.fieldID) || fact.value.amount >= 0 else { throw FundamentalError.incompatibleInput }
        }
        func quarter(_ field: String, _ index: Int) -> FundamentalMetric {
            let q = f.quarters[index]
            let matches = f.normalization.values.filter {
                $0.fieldID == field && $0.periodType == .quarter && $0.periodStart == q.start && $0.periodEnd == q.end
            }
            return .init(matches.count == 1 ? matches[0].value : nil)
        }
        func total(_ values: ArraySlice<FundamentalMetric>) throws -> FundamentalMetric {
            guard values.count == 4 else { return .init(nil, reason: .insufficientHistory) }
            if let missing = values.first(where: { $0.value == nil }) { return .init(nil, reason: missing.unavailable ?? .missingInput) }
            return .init(try fsum(values.map { $0.value! }))
        }
        var metrics: [String: FundamentalMetric] = [:], values: [String: [FundamentalMetric]] = [:]
        for (key, field) in fields {
            values[key] = f.quarters.indices.map { quarter(field, $0) }
            metrics[key + "Quarter"] = values[key]!.last!
            metrics[key + "TTM"] = try total(values[key]!.suffix(4))
            // SBC is not cash; issuance is inflow and the other positive amounts are outflow.
            if key != "sbc" {
                for period in ["Quarter", "TTM"] {
                    let amount = metrics[key + period]!
                    metrics[key + "CashFlow" + period] = .init(try amount.value?.multiplied(by: key == "issuance" ? "1" : "-1"),
                        reason: amount.unavailable ?? .missingInput)
                }
            }
        }
        for period in ["Quarter", "TTM"] {
            let net = try difference(metrics["buybacks" + period]!, metrics["issuance" + period]!)
            metrics["netBuybacks" + period] = net
            metrics["netBuybacksCashFlow" + period] = .init(try net.value?.multiplied(by: "-1"), reason: net.unavailable ?? .missingInput)
            let dividends = metrics["dividends" + period]!
            metrics["shareholderCashReturned" + period] = try combine(dividends, net, subtract: false)
        }
        let cash = f.instant(.cash)
        guard cash == nil || cash!.amount >= 0 else { throw FundamentalError.incompatibleInput }
        metrics["cash"] = .init(cash)

        let ocf = f.quarters.indices.map { quarter(FundamentalField.ocf.rawValue, $0) }
        let standardFCF = try f.quarters.indices.map { try difference(ocf[$0], values["capex"]![$0]) }
        let exSBC = try f.quarters.indices.map { try difference(standardFCF[$0], values["sbc"]![$0]) }
        metrics["fcfExSBCQuarter"] = exSBC.last!
        metrics["fcfExSBCTTM"] = try total(exSBC.suffix(4))
        let netIncome = f.quarters.indices.map { quarter(FundamentalField.netIncome.rawValue, $0) }
        metrics["fcfExSBCConversion"] = try ratio(metrics["fcfExSBCTTM"]!, total(netIncome.suffix(4)))
        let shareKnown = f.splitBasisEvidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let perShare = try f.quarters.indices.map { index -> FundamentalMetric in
            let q = f.quarters[index]
            let shares = f.normalization.values.first {
                $0.fieldID == FundamentalGrowthCalculator.dilutedShareFieldID && $0.periodType == .quarter
                    && $0.periodStart == q.start && $0.periodEnd == q.end
            }
            guard let shares else { return .init(nil) }
            guard shareKnown, shares.nature == .nonadditive, shares.unit == "shares", shares.derivation == .reported,
                  shares.sourceFactIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return .init(nil, reason: .missingEvidence)
            }
            return try ratio(exSBC[index], .init(shares.value))
        }
        metrics["fcfExSBCPerShareQuarter"] = perShare.last!
        for (key, series) in [("fcfExSBC", exSBC), ("fcfExSBCPerShare", perShare)] {
            let latest = f.quarters.count - 1
            for (suffix, offset) in [("QuarterYoY", 4), ("QuarterQoQ", 1)] {
                let prior = latest >= offset ? series[latest - offset] : .init(nil, reason: .insufficientHistory)
                let growth = try change(series[latest], prior)
                metrics[key + suffix] = growth.rate; metrics[key + suffix + "Change"] = growth.absolute
            }
        }
        if f.quarters.count == 8 {
            let currentDays = try f.quarters[4].start.days(through: f.quarters[7].end).count
            let priorDays = try f.quarters[0].start.days(through: f.quarters[3].end).count
            let growth = try change(total(exSBC.suffix(4)), total(exSBC.prefix(4)), comparable: abs(currentDays - priorDays) <= 7)
            metrics["fcfExSBCTTMYoY"] = growth.rate; metrics["fcfExSBCTTMYoYChange"] = growth.absolute
        } else {
            metrics["fcfExSBCTTMYoY"] = .init(nil, reason: .insufficientHistory)
            metrics["fcfExSBCTTMYoYChange"] = .init(nil, reason: .insufficientHistory)
        }
        for years in [3, 5] {
            let result = try revenueCAGR(input, years: years)
            metrics["revenueCAGR\(years)Y"] = result.rate
            metrics["revenueCAGR\(years)YChange"] = result.absolute
        }
        return .init(inputSnapshot: snapshot, model: model.definition.reference, parameters: model.parameters.reference,
            metrics: metrics, limitations: Array(Set(f.inputLimitations + f.normalization.values.flatMap(\.limitations)
                + ["RESEARCH_ONLY_NO_ELIGIBILITY_GRANT", "REVENUE_CAGR_COMPLETE_FISCAL_YEARS", "NO_TTM_PER_SHARE_AGGREGATION_POLICY"])).sorted(), researchOnly: true)
    }

    private static func revenueCAGR(_ input: FundamentalCompletionInput, years: Int) throws
        -> (rate: FundamentalMetric, absolute: FundamentalMetric) {
        guard input.revenueYears.count >= years + 1 else {
            return (.init(nil, reason: .insufficientHistory), .init(nil, reason: .insufficientHistory))
        }
        let window = Array(input.revenueYears.suffix(years + 1))
        let lengths = try window.map { try $0.start.days(through: $0.end).count }
        guard zip(lengths, lengths.dropFirst()).allSatisfy({ abs($0 - $1) <= 7 }) else {
            return (.init(nil, reason: .notComparable), .init(nil, reason: .notComparable))
        }
        var revenues: [Money] = []
        for year in window {
            guard let fact = input.financials.normalization.values.first(where: {
                $0.fieldID == FundamentalField.revenue.rawValue && $0.periodType == .annual
                    && $0.periodStart == year.start && $0.periodEnd == year.end
            }) else { return (.init(nil), .init(nil)) }
            guard fact.nature == .additiveFlow, fact.unit == "USD", fact.derivation == .reported else {
                return (.init(nil, reason: .missingEvidence), .init(nil, reason: .missingEvidence))
            }
            revenues.append(fact.value)
        }
        let current = revenues.last!, prior = revenues.first!
        guard prior.amount > 0 else { return try change(.init(current), .init(prior)) }
        let absolute = try difference(.init(current), .init(prior))
        guard current.amount >= 0 else {
            return (.init(nil, reason: .notComparable, flags: ["NEGATIVE_CAGR_ENDPOINT"]), absolute)
        }
        return (.init(try FundamentalCompletionDecimal.compoundGrowth(current: current, prior: prior, years: years)), absolute)
    }
    private static func difference(_ lhs: FundamentalMetric, _ rhs: FundamentalMetric) throws -> FundamentalMetric {
        try combine(lhs, rhs, subtract: true)
    }
    private static func combine(_ lhs: FundamentalMetric, _ rhs: FundamentalMetric, subtract: Bool) throws -> FundamentalMetric {
        guard let a = lhs.value, let b = rhs.value else { return .init(nil, reason: lhs.unavailable ?? rhs.unavailable ?? .missingInput) }
        return .init(try (subtract ? a.subtracting(b) : a.adding(b)))
    }
    private static func ratio(_ lhs: FundamentalMetric, _ rhs: FundamentalMetric) throws -> FundamentalMetric {
        guard let a = lhs.value, let b = rhs.value else { return .init(nil, reason: lhs.unavailable ?? rhs.unavailable ?? .missingInput) }
        return try fratio(a, b)
    }
    private static func change(_ current: FundamentalMetric, _ prior: FundamentalMetric, comparable: Bool = true) throws
        -> (rate: FundamentalMetric, absolute: FundamentalMetric) {
        guard comparable else { return (.init(nil, reason: .notComparable), .init(nil, reason: .notComparable)) }
        let absolute = try difference(current, prior)
        guard let a = current.value, let b = prior.value else { return (absolute, absolute) }
        guard b.amount > 0 else {
            let label = b.amount < 0 ? (a.amount > 0 ? "LOSS_TO_PROFIT" : a.amount == 0 ? "LOSS_TO_ZERO" : "REMAINED_LOSS")
                : (a.amount > 0 ? "ZERO_TO_POSITIVE" : a.amount < 0 ? "ZERO_TO_LOSS" : "REMAINED_ZERO")
            return (.init(nil, reason: .nonpositiveDenominator, flags: [label]), .init(absolute.value, flags: [label]))
        }
        return (try ratio(absolute, prior), absolute)
    }
}
