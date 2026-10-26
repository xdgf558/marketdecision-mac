import Foundation
import CoreDomain

/// CALC-035 instantaneous, per-leg canonical-IV sensitivity. No probabilities,
/// time roll, provider-IV substitution, American premium or executable exit quote.
public enum OptionLabScenarioEngine {
    public static let maximumAxisCount = 21 // Engineering work bound, not a market parameter.

    public static func definitions(enteredPrices: Bool = false) throws -> (ParameterSet, ModelDefinition) {
        let p = ParameterSet(id: "options.scenario-matrix.parameters", version: enteredPrices ? "PARAMETERS_V1.scenario.entered.v1" : "PARAMETERS_V1.scenario.v1",
            revisionID: UUID(uuidString: enteredPrices ? "C035AA00-2026-4025-8000-000000000007" : "C035AA00-2026-4018-8000-000000000007")!,
            values: ["spotShockUnit": .text("ratio"), "ivShockUnit": .text("absolute percentage points; divide by 100"),
                "timeAdvance": .text("none; original exact pricing T unchanged"),
                "sigmaSource": .text(enteredPrices ? "each leg's successful local entered-premium IV; no fallback" : "each leg's successful local Mid IV; no fallback"),
                "negativeSigma": .text("unavailable; no clamping"),
                "nonpositiveSpot": .text("explicit zero-spot terminal payoff boundary"),
                "fees": .text("original total fee allowance once; no invented incremental exit charge"),
                "axisValues": .text("explicit frozen user assumptions; no calibrated defaults"),
                "maximumAxisCountEngineeringLimit": .integer(maximumAxisCount)],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-035;SPEC-6.5.5;explicit offline sensitivity inputs")
        let method = enteredPrices ? "options.scenario-matrix.entered.v1" : OptionLabScenarioInput.currentMethodVersion
        let m = ModelDefinition(id: "options.scenario-matrix", version: method,
            revisionID: UUID(uuidString: enteredPrices ? "C035AA00-2026-4025-8000-000000000008" : "C035AA00-2026-4018-8000-000000000008")!,
            owner: "OptionsAnalytics", purpose: "Instantaneous offline European mark-to-model strategy sensitivity",
            inputs: [.init(name: "frozenScenarioAxesAndCanonicalPricing", unit: "USD+ratio+percentage-point", role: .required)],
            outputs: [.init(name: "instantaneousPositionValueAndPnL", unit: "USD")],
            formula: "S'=S*(1+spotShock);sigma_i'=localIV_i+pointShock/100;T,r,q unchanged;PnL=openingNetCredit+signedOptionValue+coveredStockPnL;S'<=0 uses zero-spot payoff;negative sigma unavailable",
            formulaVersion: method,
            implementationReference: "OptionsAnalytics/OptionLabScenarioEngine.v1", defaultParameters: p.reference,
            numericPolicyVersion: OptionBSM.numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1:CALC-035;SPEC-6.5.5", knownLimitations: notices(enteredPrices: enteredPrices),
            testFixtures: ["OptionScenarioTests"], introducedAt: try MillisecondInstant(iso8601: enteredPrices ? "2026-10-25T00:00:00.000Z" : "2026-10-18T00:00:00.000Z"))
        try p.validate(); try m.validate(); return (p, m)
    }

    /// Called only with the freshly calculated parent outcomes and pricing by
    /// OptionLabEngine; frozen reports must be replayed through that parent.
    static func calculate(input: OptionLabInput, assumptions: OptionLabScenarioInput,
                          pricing: OptionLabPricingReport?, underlyingMid: Money,
                          mid: OptionLabOutcome, conservative: OptionLabOutcome) throws -> OptionLabScenarioReport {
        try Task.checkCancellation()
        try validate(assumptions, createdAt: input.createdAt)
        let sources: [(OptionLabLeg, OptionLabDirection)] = [(input.shortLeg, .sell)] + (input.longLeg.map { [($0, .buy)] } ?? [])
        let t = input.expiry.settlementAt.timeIntervalSince(input.asOf) / 31_536_000
        guard t.isFinite, t >= 0, underlyingMid.amount > 0,
              input.shortLeg.quantity > 0, input.shortLeg.quantity <= Int.max / 100,
              input.shortLeg.multiplier == 100,
              mid.pricing == (input.usesEnteredPrices ? .entered : .mid),
              conservative.pricing == (input.usesEnteredPrices ? .entered : .conservative),
              !input.usesEnteredPrices || mid == conservative else {
            throw OptionLabScenarioError.incompatibleContext
        }
        if let pricing {
            let (p, m) = try OptionLabPricingEngine.definitions(enteredPrices: input.usesEnteredPrices)
            guard pricing.input == input.pricing, pricing.model == m, pricing.parameters == p,
                  pricing.timeYears == t, pricing.legs.count == sources.count else {
                throw OptionLabScenarioError.incompatibleContext
            }
            for (index, source) in sources.enumerated() {
                let result = pricing.legs[index]
                guard result.contractID == source.0.contractID, result.direction == source.1,
                      result.quoteMid == (try source.0.valuationPrice()) else {
                    throw OptionLabScenarioError.incompatibleContext
                }
            }
        }
        let units = Double(input.shortLeg.quantity * input.shortLeg.multiplier)
        let baseSpot = try finite(underlyingMid)
        let r = try pricing.map { try finite($0.input.rate) }
        let q = try pricing.map { try finite($0.input.dividendYield) }
        var cells: [OptionLabScenarioCell] = []
        for shock in assumptions.spotShocks {
            for points in assumptions.volatilityPointShocks {
                try Task.checkCancellation()
                let effectiveSpot: Money
                let boundary: Bool
                do {
                    // The sign is known before multiplying. Very large negative
                    // shocks still reach the declared boundary without overflow.
                    boundary = shock.amount <= -1
                    effectiveSpot = boundary ? try Money("0")
                        : try underlyingMid.multiplied(by: Money("1").adding(shock).decimalString)
                } catch {
                    cells.append(.init(spotShock: shock, volatilityPointShock: points, spot: nil,
                        state: .numericFailure, legs: [], mid: nil, conservative: nil)); continue
                }
                guard let pricing, let r, let q else {
                    cells.append(.init(spotShock: shock, volatilityPointShock: points, spot: effectiveSpot,
                        state: .missingPricing, legs: [], mid: nil, conservative: nil)); continue
                }
                let s = try finite(effectiveSpot), deltaSigma = try finite(points) / 100
                var legs: [OptionLabScenarioLeg] = []
                for (index, source) in sources.enumerated() {
                    let canonical = pricing.legs[index].impliedVolatility
                    guard canonical.state == .available, let sigma = canonical.volatility,
                          sigma.isFinite, sigma >= 0 else {
                        legs.append(.init(contractID: source.0.contractID, direction: source.1,
                            baseIV: nil, shockedIV: nil, theoreticalUnitPrice: nil,
                            state: .missingLegIV, ivState: canonical.state)); continue
                    }
                    let shocked = sigma + deltaSigma
                    guard shocked.isFinite, shocked >= 0 else {
                        legs.append(.init(contractID: source.0.contractID, direction: source.1, baseIV: sigma,
                            shockedIV: shocked.isFinite ? shocked : nil, theoreticalUnitPrice: nil,
                            state: shocked.isFinite ? .negativeVolatility : .numericFailure, ivState: canonical.state)); continue
                    }
                    let market = OptionBSMMarket(right: source.0.right, spot: s, strike: try finite(source.0.strike),
                        rate: r, dividendYield: q, timeYears: boundary ? 0 : t)
                    let result = OptionBSM.evaluate(market, volatility: shocked)
                    guard let value = result.price, value.isFinite, value >= 0 else {
                        legs.append(.init(contractID: source.0.contractID, direction: source.1, baseIV: sigma,
                            shockedIV: shocked, theoreticalUnitPrice: nil, state: .numericFailure, ivState: canonical.state)); continue
                    }
                    legs.append(.init(contractID: source.0.contractID, direction: source.1, baseIV: sigma,
                        shockedIV: shocked, theoreticalUnitPrice: value,
                        state: boundary ? .zeroSpotPayoffBoundary : shocked == 0 ? .zeroVolatilityBoundary : .available,
                        ivState: canonical.state))
                }
                if let failure = legs.first(where: { $0.theoreticalUnitPrice == nil }) {
                    cells.append(.init(spotShock: shock, volatilityPointShock: points, spot: effectiveSpot,
                        state: failure.state, legs: legs, mid: nil, conservative: nil)); continue
                }
                var optionValue = 0.0
                for leg in legs {
                    guard let price = leg.theoreticalUnitPrice else { throw OptionLabScenarioError.incompatibleContext }
                    optionValue += (leg.direction == .sell ? -1 : 1) * price * units
                }
                let stockValue = input.strategy == .coveredCall ? s * units : 0
                let stockPnL = input.strategy == .coveredCall ? (s - baseSpot) * units : 0
                func outcome(_ original: OptionLabOutcome) throws -> OptionLabScenarioOutcome? {
                    let pnl = try finite(original.netCreditTotal) + optionValue + stockPnL
                    let value = optionValue + stockValue
                    guard [value, stockPnL, pnl].allSatisfy(\.isFinite) else { return nil }
                    return .init(pricing: original.pricing, grossCredit: original.grossCredit,
                        totalFees: original.totalFees, netCreditTotal: original.netCreditTotal,
                        theoreticalPositionValue: value, stockPnL: stockPnL, closeoutPnL: pnl)
                }
                let midResult = try outcome(mid), conservativeResult = try outcome(conservative)
                let state: OptionLabScenarioState = midResult == nil || conservativeResult == nil ? .numericFailure
                    : boundary ? .zeroSpotPayoffBoundary
                    : legs.contains(where: { $0.state == .zeroVolatilityBoundary }) ? .zeroVolatilityBoundary : .available
                cells.append(.init(spotShock: shock, volatilityPointShock: points, spot: effectiveSpot, state: state,
                    legs: legs, mid: midResult, conservative: conservativeResult))
            }
        }
        let (p, m) = try definitions(enteredPrices: input.usesEnteredPrices)
        return .init(input: assumptions, model: m, parameters: p, valuationAt: input.asOf,
            baseSpot: underlyingMid, cells: cells, warnings: notices(enteredPrices: input.usesEnteredPrices))
    }

    static func validate(_ value: OptionLabScenarioInput, createdAt: Date) throws {
        guard value.methodVersion == OptionLabScenarioInput.currentMethodVersion,
              [value.spotShocks, value.volatilityPointShocks].allSatisfy({
                  (1...maximumAxisCount).contains($0.count) && Set($0.map(\.decimalString)).count == $0.count
              }) else { throw OptionLabScenarioError.invalidGrid }
        for number in value.spotShocks + value.volatilityPointShocks { _ = try finite(number) }
        let source = value.source
        guard !source.reference.isEmpty, source.reference == source.reference.trimmingCharacters(in: .whitespacesAndNewlines),
              source.reference.utf8.count <= 4096, source.enteredAt.timeIntervalSince1970.isFinite,
              source.enteredAt <= createdAt else { throw OptionLabScenarioError.invalidSource }
    }

    private static func finite(_ value: Money) throws -> Double {
        guard let result = Double(value.decimalString), result.isFinite else { throw OptionLabScenarioError.invalidGrid }
        return result
    }
    private static let warnings = [
        "用户指定的瞬时价格 × IV 敏感度；T、连续利率及连续股息率不变，不推进交易日或跨越到期。",
        "价格冲击为比例，IV 冲击为绝对百分点；没有默认传导、真实概率、历史校准或行情资格。",
        "逐腿使用本次成功的 Mid 本地 IV；任一腿缺失或冲击后波动率为负，整策略该格不可用，不回退手工 σ。",
        "S 冲击后不大于零时，按 CALC-035 显式使用零价格到期 payoff 边界；这不是到期前的连续股息 BSM 价格。",
        "欧式理论持仓价值与假设平仓损益，不是可成交报价或美式行权价值；未模拟提前指派、离散股息、税或融资。",
        "Mid 与保守开仓收入分别计算；原输入的全部费用预留只扣一次，不代表真实平仓费、平仓价差或结算成本。"
    ]
    private static func notices(enteredPrices: Bool) -> [String] {
        guard enteredPrices else { return warnings }
        var result = warnings
        result[2] = "逐腿使用所填权利金反解的本地 IV；任一腿缺失或冲击后波动率为负，整策略该格不可用，不回退手工 σ。"
        result[5] = "开仓收入沿用所填成交价；全部费用预留只扣一次，没有 Mid／保守双口径比较，也不代表真实平仓费、平仓价差或结算成本。"
        return result
    }
}
