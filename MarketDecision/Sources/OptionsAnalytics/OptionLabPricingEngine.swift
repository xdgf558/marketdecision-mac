import Foundation
import CoreDomain

/// An additive model; deterministic v1 definitions and their stored fingerprints
/// remain unchanged. No external model, solver settings or provider IV are accepted.
public enum OptionLabPricingEngine {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let p = ParameterSet(id: "options.bsm-risk-neutral.parameters", version: "PARAMETERS_V1.pricing.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4016-8000-000000000003")!,
            values: ["ivLower": .decimal(try Money("0.000001")), "ivInitialUpper": .decimal(try Money("5")),
                "ivExpandedUpper1": .decimal(try Money("10")), "ivExpandedUpper2": .decimal(try Money("20")),
                "ivMaximumIterations": .integer(200), "ivAbsoluteTolerance": .decimal(try Money("0.00000001")),
                "ivRelativeTolerance": .decimal(try Money("0.000000000001")),
                "ivPriceAbsoluteTolerance": .decimal(try Money("0.00000001")), "ivPriceRelativeTolerance": .decimal(try Money("0.00000001")),
                "ivMinimumSeconds": .integer(60), "greeksThetaDayBasis": .integer(365), "vegaRhoPoint": .decimal(try Money("0.01")),
                "distributionVersion": .text("option-risk-neutral.CVAR_DRAFT_2.v1"), "confidence95": .decimal(try Money("0.95")),
                "alpha": .decimal(try Money("0.05")), "absoluteUSD": .decimal(try Money("0.00000001")),
                "relative": .decimal(try Money("0.00000001")), "maximumSubintervals": .integer(10000),
                "expectedPnL": .text("undiscounted analytic truncated lognormal moments"),
                "tailIntegration": .text("adaptive GK15 over adverse quantile mass, constant atoms exact partial mass"),
                "probability": .text("strict P(PnL>0)"), "sigmaSource": .text("local IV of sourceContractID; canonical short, long sensitivity separate"),
                "PV": .text("not requested/nil"), "manualSigma": .text("independent theoretical price only; never an IV fallback"),
                "nearExpiryDTE": .integer(7), "deepITMFactor": .decimal(try Money("1.10")),
                "longDTE": .integer(60), "highRate": .decimal(try Money("0.05"))],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-023,024,025,028;SPEC-6.5.4")
        let m = ModelDefinition(id: "options.bsm-risk-neutral", version: OptionLabPricingInput.currentMethodVersion,
            revisionID: UUID(uuidString: "C035AA00-2026-4016-8000-000000000004")!,
            owner: "OptionsAnalytics", purpose: "European continuous-dividend reference; offline risk-neutral research only",
            inputs: [.init(name: "frozenScenarioAndPricingAssumptions", unit: "USD+ratio", role: .required)],
            outputs: [.init(name: "theoreticalUnitPrice", unit: "USD"), .init(name: "localIVAndGreeks", unit: "explicit-unit-greeks"),
                      .init(name: "riskNeutralTerminalDistribution", unit: "USD+probability")],
            formula: "BSM erfc CDF; Brent-Dekker Mid inversion; per-share local-IV Greeks; signed units aggregation plus covered stock Delta; strict positive terminal PnL lognormal integration; signed lower-tail mean",
            formulaVersion: OptionLabPricingInput.currentMethodVersion,
            implementationReference: "OptionsAnalytics/OptionBSM+OptionLabDistribution.v1", defaultParameters: p.reference,
            numericPolicyVersion: OptionBSM.numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1", knownLimitations: warnings,
            testFixtures: ["OptionPricingTests", "OptionRiskNeutralTests"], introducedAt: try MillisecondInstant(iso8601: "2026-10-16T00:00:00.000Z"))
        try p.validate(); try m.validate(); return (p,m)
    }

    static func validate(_ input: OptionLabPricingInput, createdAt: Date) throws {
        guard input.methodVersion == OptionLabPricingInput.currentMethodVersion,
              input.dividendYield.amount >= 0, input.volatility.amount >= 0,
              !input.source.reference.isEmpty, input.source.reference == input.source.reference.trimmingCharacters(in: .whitespacesAndNewlines),
              input.source.reference.utf8.count <= 4096, input.source.enteredAt.timeIntervalSince1970.isFinite,
              input.source.enteredAt <= createdAt else { throw OptionLabError.invalidPricingInput }
        _ = try number(input.rate); _ = try number(input.dividendYield); _ = try number(input.volatility)
    }
    static func calculate(input: OptionLabInput, assumptions: OptionLabPricingInput,
                          underlyingMid: Money, mid: OptionLabOutcome, conservative: OptionLabOutcome,
                          dte: Int) throws -> OptionLabPricingReport {
        try Task.checkCancellation(); try validate(assumptions, createdAt: input.createdAt)
        let s = try number(underlyingMid), r = try number(assumptions.rate), q = try number(assumptions.dividendYield)
        let manualSigma = try number(assumptions.volatility)
        let seconds = input.expiry.settlementAt.timeIntervalSince(input.asOf), t = seconds / 31_536_000
        guard seconds.isFinite, t.isFinite, t >= 0 else { throw OptionLabError.invalidPricingInput }
        let sources: [(OptionLabLeg, OptionLabDirection)] = [(input.shortLeg, .sell)] + (input.longLeg.map { [($0, .buy)] } ?? [])
        var legs: [OptionLabLegPricing] = []
        for (leg, direction) in sources {
            try Task.checkCancellation()
            let k = try number(leg.strike), quoteMid = try leg.bid.adding(leg.ask).multiplied(by: "0.5")
            let market = OptionBSMMarket(right: leg.right, spot: s, strike: k, rate: r, dividendYield: q, timeYears: t)
            let intrinsic = max(0, leg.right == .call ? s - k : k - s)
            let theory = seconds < 60 ? OptionBSMResult(state: .tooNearExpiry, price: nil, greeks: nil, itmProbability: nil) : OptionBSM.evaluate(market, volatility: manualSigma)
            let iv = try OptionIVSolver.solve(market, price: number(quoteMid))
            let canonical = iv.volatility.map { OptionBSM.evaluate(market, volatility: $0) }
            let greeks = canonical?.state == .available ? canonical?.greeks : nil
            let probability = canonical?.state == .available ? canonical?.itmProbability : nil
            let absoluteDelta = greeks.map { abs($0.delta) }
            var notices: [String] = []
            let deep = leg.right == .put ? k / s >= 1.10 : s / k >= 1.10
            if dte <= 7 { notices.append("DTE≤7：临近到期，提前行权与模型敏感性需另行核对。") }
            if deep || dte > 60 || r >= 0.05 { notices.append("深度价内、较长期限或较高利率：欧式近似不保证美式价格误差。") }
            if leg.right == .put, direction == .sell, try number(quoteMid) - intrinsic < k * max(r,0) * t {
                notices.append("短 Put 外在价值低于 K×max(r,0)×T：启发式提前行权风险提示，不是指派概率。")
            }
            if leg.right == .call {
                notices.append("未提供已确认离散股息与除息窗口，不能完成短 Call 除息行权判据；连续股息率不代替离散股息证据。")
            }
            legs.append(.init(contractID: leg.contractID, direction: direction, quoteMid: quoteMid,
                theoreticalPrice: theory.price, theoryState: theory.state, expiryIntrinsicValue: intrinsic,
                impliedVolatility: iv, canonicalGreeks: greeks, itmProbability: probability,
                absoluteDelta: absoluteDelta, itmDeltaDifference: absoluteDelta.flatMap { d in probability.map { d - $0 } }, warnings: notices))
        }
        var aggregate: OptionLabGreeks?, aggregateState: OptionLabPricingState = .missingLegIV
        let allGreeksAvailable = legs.allSatisfy { $0.canonicalGreeks != nil }
        if allGreeksAvailable { aggregateState = .numericFailure }
        if allGreeksAvailable, let units = Double(exactly: input.shortLeg.multiplier * input.shortLeg.quantity) {
            var values = [Double](repeating: 0, count: 5)
            if input.strategy == .coveredCall { values[0] = units }
            for leg in legs {
                guard let greek = leg.canonicalGreeks else { continue }
                let factor = leg.direction == .sell ? -units : units
                for index in values.indices { values[index] += greek.values[index] * factor }
            }
            if values.allSatisfy(\.isFinite) {
                aggregate = .init(delta: values[0], gamma: values[1], thetaPerDay: values[2], vegaPerPercentagePoint: values[3], rhoPerPercentagePoint: values[4]); aggregateState = .available
            } else { aggregateState = .numericFailure }
        }
        func distribution(_ leg: OptionLabLegPricing?) throws -> (OptionLabDistributionReport?, OptionLabPricingState) {
            guard let leg else { return (nil, .notApplicable) }
            guard let sigma = leg.impliedVolatility.volatility, leg.impliedVolatility.state == .available else { return (nil, leg.impliedVolatility.state) }
            do {
                return (try OptionLabDistribution.analyze(input: input, mid: mid, conservative: conservative,
                    underlyingMid: underlyingMid, assumptions: assumptions, volatility: sigma,
                    volatilitySourceContractID: leg.contractID), .available)
            } catch is CancellationError { throw CancellationError() }
            catch { return (nil, .numericFailure) }
        }
        let primary = try distribution(legs.first), sensitivity = try distribution(legs.count > 1 ? legs[1] : nil)
        let (parameters, model) = try definitions()
        return .init(input: assumptions, model: model, parameters: parameters, numericPolicyVersion: OptionBSM.numericPolicyVersion,
            timeYears: t, legs: legs, aggregateGreeks: aggregate, aggregateState: aggregateState,
            distribution: primary.0, distributionState: primary.1, longLegSensitivity: sensitivity.0, longLegSensitivityState: sensitivity.1,
            warnings: warnings)
    }
    private static func number(_ value: Money) throws -> Double {
        guard let result = Double(value.decimalString), result.isFinite else { throw OptionLabError.invalidPricingInput }
        return result
    }
    private static let warnings = [
        "欧式 BSM 连续股息参考模型；美式提前行权、离散股息、CRR 和波动率曲面未实现。",
        "理论价仅使用明确的手工 σ；canonical Greeks 使用逐腿 Mid 本地反解 IV，失败不回退手工或供应商值。",
        "RISK_NEUTRAL：盈利概率、EV 与尾部指标来自风险中性模型，不是真实世界胜率、预测或历史校准。",
        "主分布使用短腿 local IV；长腿 local IV 的整策略重算仅为敏感度对照，不参与主排序。",
        "到期价内概率与 |Delta| 分开展示；Delta 不是获利概率。",
        "盈利事件严格 PnL>0，费用已计入原确定性损益；零平台不计获利，尾部均值保留正负号。",
        "Greeks 聚合仅限本次策略，按方向×乘数×张数；备兑股票仅加入持股 Delta，不代表全账户风险。",
        "没有真实世界 Bootstrap、供应商准入、历史校准或下单能力。"
    ]
}
