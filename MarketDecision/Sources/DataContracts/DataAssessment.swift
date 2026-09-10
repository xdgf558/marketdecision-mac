import Foundation
import CoreDomain

public struct FreshnessPolicy: Sendable {
    public let version: String
    public let realtimeMaxAge: TimeInterval, chainMaxSkew: TimeInterval
    // Selected foundation policy. Historical fills require a distinct sampling policy.
    public static let foundationV1 = FreshnessPolicy(version: "freshness.v1", realtimeMaxAge: 60, chainMaxSkew: 5)
}
public struct UsageAssessment: Sendable {
    public let usage: Usage
    public let evaluatedAt: Date
    public let policyRef: String
    public let reasons: Set<UnavailableReason>
    public var allowed: Bool { reasons.isEmpty }
    public init(usage: Usage, evaluatedAt: Date, policyRef: String, reasons: Set<UnavailableReason>) {
        self.usage = usage; self.evaluatedAt = evaluatedAt; self.policyRef = policyRef; self.reasons = reasons
    }
}
public enum DependencyRole: Sendable {
    case required, comparison, excludedOptional(reason: String, policyRef: String)
}
public struct DependencyInput: Sendable {
    public let id: String
    public let role: DependencyRole
    public let origin: OriginKind
    public let isMarketPrice: Bool
    public let timeliness: Timeliness
    public let quality: Set<QualityFlag>
    public let assessment: UsageAssessment
    public init(id: String, role: DependencyRole, origin: OriginKind, isMarketPrice: Bool, timeliness: Timeliness,
                quality: Set<QualityFlag>, assessment: UsageAssessment) {
        self.id = id; self.role = role; self.origin = origin; self.isMarketPrice = isMarketPrice
        self.timeliness = timeliness; self.quality = quality; self.assessment = assessment
    }
}
/// Immutable assessment snapshot. Re-assessment creates a new value, never alters frozen history.
public struct DerivedAssessment: Sendable {
    public let inputs: [DependencyInput]
    public let usage: Usage, evaluatedAt: Date, policyRef: String
    public let marketTimeliness: Timeliness // Applies only to price dependencies, not the entire output.
    public let origins: Set<OriginKind>, quality: Set<QualityFlag>, reasons: Set<UnavailableReason>
    public let consumedCount: Int, excludedCount: Int
    public var allowed: Bool { reasons.isEmpty }
    public init(inputs: [DependencyInput], usage: Usage, evaluatedAt: Date, policyRef: String) throws {
        guard finite(evaluatedAt), nonblank(policyRef), inputs.allSatisfy({ nonblank($0.id) }),
              Set(inputs.map(\.id)).count == inputs.count else { throw ContractError.invalidIdentity }
        var consumed: [DependencyInput] = []; var excluded = 0
        for input in inputs {
            switch input.role {
            case .comparison: break
            case let .excludedOptional(reason, policy):
                guard nonblank(reason), nonblank(policy) else { throw ContractError.invalidIdentity }; excluded += 1
            case .required: consumed.append(input)
            }
        }
        var reasons: Set<UnavailableReason> = consumed.isEmpty ? [.missingDependency] : []
        var quality: Set<QualityFlag> = []
        for input in consumed {
            quality.formUnion(input.quality); reasons.formUnion(input.assessment.reasons)
            guard input.assessment.usage == usage, nonblank(input.assessment.policyRef),
                  input.assessment.evaluatedAt == evaluatedAt else { reasons.insert(.unqualifiedUsage); continue }
            if input.quality.contains(.synthetic) { reasons.insert(.syntheticData) }
            if !input.quality.isDisjoint(with: [.missing, .invalid]) { reasons.insert(.missingDependency) }
            if usage == .liveAnalysis && input.isMarketPrice {
                if input.timeliness != .realtime || input.quality.contains(.indicative) { reasons.insert(.unsuitableTier) }
                if input.quality.contains(.stale) { reasons.insert(.staleQuote) }
            }
        }
        let prices = consumed.filter(\.isMarketPrice).map(\.timeliness)
        if prices.isEmpty { marketTimeliness = .notApplicable }
        else if prices.contains(.unknown) || prices.contains(.notApplicable) { marketTimeliness = .unknown }
        else if prices.contains(.endOfDay) { marketTimeliness = .endOfDay }
        else if prices.contains(.delayed) { marketTimeliness = .delayed }
        else { marketTimeliness = .realtime }
        self.inputs = inputs; self.usage = usage; self.evaluatedAt = evaluatedAt; self.policyRef = policyRef
        self.origins = Set(consumed.map(\.origin)); self.quality = quality; self.reasons = reasons
        self.consumedCount = consumed.count; self.excludedCount = excluded
    }
}

public enum ValueState: String, Sendable, Codable { case available, partial, missing, invalid, blockedBySpec, incompatible, notApplicable }
public enum ValueUnit: String, Sendable, Codable { case usd, usdPerShare, usdPerContract, shares, contracts, ratio, percentPoints, indexPoints, basisPoints }
public struct CalculationInputReference: Sendable {
    public let role: String
    public let unit: ValueUnit
    public let recordID: String
    public let provenance: Provenance
    public init(role: String, unit: ValueUnit, recordID: String, provenance: Provenance) {
        self.unit = unit; self.role = role; self.recordID = recordID; self.provenance = provenance
    }
}
/// Complete registry binding plus exact input versions. No caller-supplied loose model strings.
/// Does not prove that a formula ran, source data is eligible or a result is economically valid.
public struct CalculationContext: Sendable {
    public let calculatedAt: Date
    public let model: ResolvedModel
    public var formulaVersion: String { model.definition.formulaVersion }
    public var modelVersion: String { model.definition.version }
    public var parameterVersion: String { model.parameters.version }
    public let inputs: [CalculationInputReference]
    public init(calculatedAt: Date, model: ResolvedModel, inputs: [CalculationInputReference]) throws {
        try model.validateForCalculation(at: calculatedAt)
        try model.validateInputs(inputs.map(\.role))
        var seen = Set<[String]>()
        for input in inputs {
            guard nonblank(input.recordID) else { throw ContractError.invalidIdentity }
            guard model.definition.inputs.first(where: { $0.name == input.role })?.unit == input.unit.rawValue else {
                throw RegistryError.invalidInputs
            }
            try input.provenance.validate()
            guard input.provenance.receivedAt <= calculatedAt else { throw ContractError.invalidTime }
            let identity = [input.role, input.recordID, input.provenance.providerID, input.provenance.feedID,
                            input.provenance.versionID ?? ""]
            guard seen.insert(identity).inserted else { throw RegistryError.invalidInputs }
        }
        self.calculatedAt = calculatedAt; self.model = model; self.inputs = inputs
    }
}
/// This foundation value accepts identity normalization only: rawValue is the source decimal
/// in the same unit/currency as value. Formatting may differ; numerical values must be equal.
/// Source documents and their original units remain at rawObjectRef. Unit/scale conversions
/// need a separately defined transformation contract, not an arbitrary normalizationVersion.
/// Derived values may omit rawValue because their exact inputs are in CalculationContext.
public struct NumericObservation: ProviderRecord, Sendable {
    public let recordID: String
    public let provenance: Provenance
    public let rawValue: String?
    public let value: Money?
    public let state: ValueState
    public let unit: ValueUnit
    public let currency: String?
    public let numericPolicyRef: String
    public let reasons: [String]
    public let calculation: CalculationContext?
    public let calculationOutput: String?
    public init(recordID: String, provenance: Provenance, rawValue: String?, value: Money?, state: ValueState,
                unit: ValueUnit, currency: String?, numericPolicyRef: String, reasons: [String] = [],
                calculation: CalculationContext? = nil, calculationOutput: String? = nil) throws {
        guard nonblank(recordID), nonblank(numericPolicyRef) else { throw ContractError.invalidIdentity }
        try provenance.validate()
        let monetary = [ValueUnit.usd, .usdPerShare, .usdPerContract].contains(unit)
        guard monetary ? currency == "USD" : currency == nil else { throw ContractError.invalidIdentity }
        switch state {
        case .available: guard value != nil else { throw ContractError.invalidCoverage }
        case .partial: throw UnavailableReason.specializedPolicyRequired // No generic partial-number semantics.
        default: guard value == nil, !reasons.isEmpty, reasons.allSatisfy(nonblank) else { throw ContractError.invalidCoverage }
        }
        if state == .available {
            if let rawValue {
                guard try Money(rawValue) == value else { throw ContractError.invalidNormalization }
            } else if provenance.origin != .derived { throw ContractError.invalidNormalization }
        }
        if state == .available && provenance.origin == .derived && calculation == nil { throw ContractError.invalidIdentity }
        if let calculation {
            guard provenance.origin == .derived, calculation.calculatedAt <= provenance.receivedAt else { throw ContractError.invalidTime }
            guard numericPolicyRef == calculation.model.definition.numericPolicyVersion,
                  calculation.model.definition.outputs.contains(where: { $0.name == calculationOutput && $0.unit == unit.rawValue }) else {
                throw ContractError.invalidNormalization
            }
        } else if calculationOutput != nil {
            throw ContractError.invalidIdentity
        }
        self.recordID = recordID; self.provenance = provenance; self.rawValue = rawValue; self.value = value; self.state = state
        self.unit = unit; self.currency = currency; self.numericPolicyRef = numericPolicyRef; self.reasons = reasons
        self.calculation = calculation; self.calculationOutput = calculationOutput
    }
}
/// Structural contract only; a complete request cycle does not establish contemporaneous quotes.
public protocol OptionChainRecord: ProviderRecord {
    var underlyingQuote: Quote { get }
    var contractProvenances: [Provenance] { get }
}
public extension OptionChainRecord {
    var contractQuoteTimes: [Date?] { contractProvenances.map(\.sourceEventAt) }
    func maximumQuoteSkew() -> TimeInterval? {
        guard let underlying = underlyingQuote.provenance.sourceEventAt, finite(underlying),
              !contractQuoteTimes.isEmpty, contractQuoteTimes.allSatisfy({ $0.map(finite) == true }) else { return nil }
        return contractQuoteTimes.compactMap { $0 }.map { abs($0.timeIntervalSince(underlying)) }.max()
    }
    func validateRequestCycle() throws {
        try provenance.validate(); try underlyingQuote.provenance.validate()
        guard provenance.requestID == underlyingQuote.provenance.requestID,
              provenance.providerID == underlyingQuote.provenance.providerID,
              provenance.feedID == underlyingQuote.provenance.feedID,
              provenance.requestedAt == underlyingQuote.provenance.requestedAt,
              underlyingQuote.provenance.receivedAt <= provenance.receivedAt else { throw ContractError.mismatchedSource }
        for contract in contractProvenances {
            try contract.validate()
            guard contract.requestID == provenance.requestID, contract.requestedAt == provenance.requestedAt,
                  contract.providerID == provenance.providerID, contract.feedID == provenance.feedID,
                  contract.receivedAt <= provenance.receivedAt else { throw ContractError.mismatchedSource }
        }
    }
    func meetsLiveSkewPolicy() -> Bool {
        guard (try? validateRequestCycle()) != nil, let skew = maximumQuoteSkew() else { return false }
        return skew <= FreshnessPolicy.foundationV1.chainMaxSkew
    }
}
