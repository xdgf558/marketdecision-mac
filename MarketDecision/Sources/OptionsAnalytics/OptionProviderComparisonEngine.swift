import Foundation
import CoreDomain

/// Side-by-side observations only. The local report is replayed before a single
/// value is read, and provider values never enter local pricing, IV or Greeks.
public enum OptionProviderComparisonEngine {
    public static let schemaVersion = "option-provider-comparison.v1"
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "options.provider-comparison.parameters", version: "PARAMETERS_V1.comparison.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000021")!,
            values: ["ivAbsoluteDifferenceThreshold": .decimal(try Money("0.05")),
                "deltaAbsoluteDifferenceThreshold": .decimal(try Money("0.03")),
                "otherGreekThresholds": .text("not defined; differences only, no invented alert thresholds"),
                "clockRule": .text("exact valuation, option quote and underlying quote timestamps; received no later than asOf"),
                "unitRule": .text("exact closed per-share unit; no implicit conversion"),
                "difference": .text("local minus provider; strict absolute difference greater than threshold"),
                "modelRule": .text("family and assumptions reported separately; differences do not downgrade data tier")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-024;USER_2026-10-18_OPTION_EVIDENCE_V1")
        let model = ModelDefinition(id: "options.provider-comparison", version: schemaVersion,
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000022")!, owner: "OptionsAnalytics",
            purpose: "Offline comparison of local canonical results and explicit provider observations; no fallback or admission",
            inputs: [.init(name: "completeLocalReportAndProviderObservations", unit: "explicit-unit-greeks", role: .required)],
            outputs: [.init(name: "fieldDifferencesAndModelComparability", unit: "explicit-unit-greeks")],
            formula: "Replay local report; bind exact contract/feed/clocks/units; difference=local-provider; alert=abs(difference)>approvedThreshold; missing stays unavailable",
            formulaVersion: schemaVersion, implementationReference: "OptionsAnalytics/OptionProviderComparisonEngine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: OptionBSM.numericPolicyVersion,
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-024;USER_2026-10-18_OPTION_EVIDENCE_V1",
            knownLimitations: limitations, testFixtures: ["OptionProviderComparisonTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-18T00:00:00.000Z"))
        try parameters.validate(); try model.validate(); return (parameters, model)
    }

    public static func calculate(_ input: OptionProviderComparisonInput) throws -> OptionProviderComparisonReport {
        try Task.checkCancellation()
        let local = try OptionLabEngine.replay(input.localReport)
        guard input.createdAt.timeIntervalSince1970.isFinite, input.createdAt >= local.input.createdAt,
              clean(input.localFeedID), input.observations.count <= 2 else { throw OptionProviderComparisonError.invalidInput }
        if let evidence = local.input.chainEvidence, input.localFeedID != evidence.capture.feedID {
            throw OptionProviderComparisonError.mismatchedFeed
        }
        guard Set(input.observations.map(\.id)).count == input.observations.count,
              Set(input.observations.map { $0.contract.contractID }).count == input.observations.count else {
            throw OptionProviderComparisonError.duplicateObservation
        }
        let legs = [local.input.shortLeg] + (local.input.longLeg.map { [$0] } ?? [])
        for observation in input.observations {
            try Task.checkCancellation()
            guard let leg = legs.first(where: { $0.contractID == observation.contract.contractID }),
                  observation.contract == OptionProviderContract(leg: leg, expiry: local.input.expiry) else {
                throw OptionProviderComparisonError.mismatchedContract
            }
            try validate(observation, leg: leg, input: input)
        }
        let rows = try legs.map { leg -> OptionProviderComparisonLeg in
            try Task.checkCancellation()
            let observation = input.observations.first { $0.contract.contractID == leg.contractID }
            let localPricing = local.pricing?.legs.first { $0.contractID == leg.contractID }
            let comparison = modelComparison(observation?.model, local: local)
            let fields = try OptionProviderField.allCases.map { field -> OptionProviderComparisonField in
                let localValue = value(field, pricing: localPricing), providerValue = observation?.values[field]?.value
                let state: OptionProviderComparisonState
                switch (localValue, providerValue) {
                case (.some, .some): state = .compared
                case (.none, .some): state = .missingLocalValue
                case (.some, .none): state = .missingProviderValue
                case (.none, .none): state = .missingBothValues
                }
                let difference = localValue.flatMap { l in providerValue.map { l - $0 } }
                guard difference?.isFinite != false else { throw OptionProviderComparisonError.invalidValue }
                let threshold: Double? = field == .iv ? 0.05 : (field == .delta ? 0.03 : nil)
                let exceeded = comparison == .sameEuropeanReference
                    ? difference.flatMap { difference in threshold.map { abs(difference) > $0 } } : nil
                return .init(field: field, unit: field.unit, local: localValue, provider: providerValue,
                    difference: difference, state: state, absoluteThreshold: threshold, thresholdExceeded: exceeded)
            }
            var warnings = ["差值仅为对照，不替代本地 canonical IV／Greeks，也不自动降低数据层级。"]
            if comparison == .differentModel { warnings.append("模型家族不同；数值差异不能直接认定为行情错误。") }
            if comparison == .differentAssumptions { warnings.append("模型输入假设不同；差异可能来自利率、连续股息率或标的价格。") }
            if comparison == .unknownModel { warnings.append("供应商模型或完整假设未知，尚不能判断模型可比性。") }
            if local.input.pricing?.dividendYield.amount ?? 0 > 0,
               ((localPricing?.canonicalGreeks.map { abs($0.delta) > 0.7 } ?? false) || local.input.expiry.settlementAt.timeIntervalSince(local.input.asOf) > 31_536_000) {
                warnings.append("含连续股息且高绝对 Delta 或超过一年到期：欧式与美式模型差异需单独核对，不作为数据降级依据。")
            }
            return .init(contractID: leg.contractID, observationID: observation?.id, modelComparison: comparison,
                         fields: fields, warnings: warnings)
        }
        let (parameters, model) = try definitions()
        let synthetic = input.observations.contains { $0.source.origin == .synthetic }
            || legs.contains { $0.source.origin == .synthetic } || local.input.underlying.source.origin == .synthetic
            || local.input.expiry.source.origin == .synthetic || local.input.capital.origin == .synthetic
            || local.input.pricing?.source.origin == .synthetic || local.input.risk?.source.origin == .synthetic
            || local.input.chainEvidence?.capture.synthetic == true
        return .init(schemaVersion: schemaVersion, input: input, model: model, parameters: parameters,
            rows: rows, containsSynthetic: synthetic, researchOnly: true, limitations: limitations)
    }

    public static func replay(_ report: OptionProviderComparisonReport) throws -> OptionProviderComparisonReport {
        let expected = try calculate(report.input)
        guard expected == report else { throw OptionProviderComparisonError.incompatibleReport }
        return expected
    }

    private static func validate(_ item: OptionProviderObservation, leg: OptionLabLeg, input: OptionProviderComparisonInput) throws {
        guard clean(item.id), clean(item.providerID), clean(item.feedID), clean(item.source.reference),
              clean(item.model.version), clean(item.model.reference), item.source.enteredAt.timeIntervalSince1970.isFinite,
              item.source.enteredAt <= input.createdAt else { throw OptionProviderComparisonError.invalidInput }
        guard item.feedID == input.localFeedID else { throw OptionProviderComparisonError.mismatchedFeed }
        let scenario = input.localReport.input
        guard [item.valuationAt, item.quoteTime, item.underlyingQuoteTime, item.receivedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              item.valuationAt == scenario.asOf, item.quoteTime == leg.quotedAt,
              item.underlyingQuoteTime == scenario.underlying.quotedAt,
              item.receivedAt >= item.quoteTime, item.receivedAt >= item.underlyingQuoteTime,
              item.receivedAt >= item.valuationAt,
              item.receivedAt <= scenario.asOf else { throw OptionProviderComparisonError.mismatchedTime }
        for (field, observation) in item.values {
            guard observation.unit == field.unit else { throw OptionProviderComparisonError.invalidUnit }
            guard observation.value.isFinite else { throw OptionProviderComparisonError.invalidValue }
            switch field {
            case .iv, .gamma, .vega:
                guard observation.value >= 0 else { throw OptionProviderComparisonError.invalidValue }
            case .delta:
                guard (-1...1).contains(observation.value),
                      leg.right == .call ? observation.value >= 0 : observation.value <= 0 else {
                    throw OptionProviderComparisonError.invalidValue
                }
            case .theta, .rho: break
            }
        }
        guard item.model.spot?.amount ?? 1 > 0, item.model.continuousDividendYield?.amount ?? 0 >= 0,
              item.model.volatilityUsedForGreeks.map({ $0.isFinite && $0 >= 0 }) != false else {
            throw OptionProviderComparisonError.invalidValue
        }
        if let declaredSigma = item.model.volatilityUsedForGreeks, let iv = item.values[.iv]?.value,
           declaredSigma != iv { throw OptionProviderComparisonError.invalidValue }
    }

    private static func modelComparison(_ provider: OptionProviderModel?, local: OptionLabReport) -> OptionProviderModelComparison {
        guard let pricing = local.input.pricing else { return .missingLocalPricing }
        guard let provider, provider.family != .unknown else { return .unknownModel }
        guard provider.family == .europeanBSMContinuousDividend else { return .differentModel }
        guard let spot = provider.spot, let rate = provider.continuousRate, let dividend = provider.continuousDividendYield,
              provider.volatilityUsedForGreeks != nil else { return .unknownModel }
        return spot == local.underlyingMid && rate == pricing.rate && dividend == pricing.dividendYield
            ? .sameEuropeanReference : .differentAssumptions
    }
    private static func value(_ field: OptionProviderField, pricing: OptionLabLegPricing?) -> Double? {
        guard let pricing else { return nil }
        if field == .iv { return pricing.impliedVolatility.state == .available ? pricing.impliedVolatility.volatility : nil }
        guard pricing.impliedVolatility.state == .available, let greek = pricing.canonicalGreeks else { return nil }
        switch field {
        case .iv: return nil
        case .delta: return greek.delta
        case .gamma: return greek.gamma
        case .theta: return greek.thetaPerDay
        case .vega: return greek.vegaPerPercentagePoint
        case .rho: return greek.rhoPerPercentagePoint
        }
    }
    private static func clean(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let limitations = [
        "离线观察对照，仅研究用途；合成或手工字段不授予供应商、实时、PIT、历史校准或交易资格。",
        "本地数值从冻结输入完整重算；供应商字段仅并排展示，不补缺 IV、不参与 canonical Greeks 或下单。",
        "模型家族和已知假设可比时，IV 按绝对差大于 0.05、Delta 按绝对差大于 0.03 提示；其余 Greeks 只列差值。",
        "模型未知或假设不可比时仅保留数值诊断，阈值判定为空；未定义阈值或未判定不等于通过。",
        "单位与时钟须明确匹配，拒绝猜测换算；模型家族和假设差异单独展示，不据此降级数据。",
        "观察是离线声明，未核验真实供应商的模型、算法、账户许可或原始传输。"
    ]
}
