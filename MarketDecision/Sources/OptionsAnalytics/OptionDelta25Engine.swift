import Foundation
import CoreDomain

/// A versioned, offline derivation from fully replayed local IV and unadjusted
/// spot BSM Delta. Provider Greeks and manual sigma cannot enter this path.
public enum OptionDelta25Engine {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "options.delta25.parameters", version: "OPTIONS_EVIDENCE_V1.delta25.v1",
            revisionID: UUID(uuidString: "D0250000-2026-4018-8000-000000000003")!,
            values: [
                "callDelta": .decimal(try Money("0.25")), "putDelta": .decimal(try Money("-0.25")),
                "deltaConvention": .text("local BSM signed spot Delta, not premium adjusted"),
                "strikeInterpolation": .text("adjacent signed Delta linear IV; exact equality first; no extrapolation"),
                "grid": .text("same expiry and right; shared specification, multiplier and exercise style across both sides; complete declared eligible grid; no holes; Delta strictly decreases as strike increases"),
                "targetDays": .integer(30), "yearDays": .integer(365),
                "exactSecondsTolerance": .integer(1), "bracketMaxDays": .integer(30),
                "expiryInterpolation": .text("same paired expiries for both sides; linear total variance; no extrapolation"),
                "skew": .text("put25DeltaIV-call25DeltaIV in decimal volatility units"),
                "scope": .text("offline declared chain only; no provider admission or real-world probability")
            ], state: .approved, dispositionReference: "USER_2026-10-18_OPTION_EVIDENCE_V1;PARAMETERS_V1:CALC-026")
        let model = ModelDefinition(id: "options.delta25", version: OptionDelta25Input.currentMethodVersion,
            revisionID: UUID(uuidString: "D0250000-2026-4018-8000-000000000004")!, owner: "OptionsAnalytics",
            purpose: "Offline 25-Delta call/put volatility and put-minus-call skew at 30 days",
            inputs: [.init(name: "completeFrozenDailyReport", unit: "ratio+USD+seconds", role: .required)],
            outputs: [.init(name: "call25Put25AndSkew", unit: "ratio")],
            formula: "sigma25=linear interpolation in signed local Delta at +0.25 call/-0.25 put; sigma30=sqrt(linear(sigma25^2*T)/T30); skew=put30-call30",
            formulaVersion: OptionDelta25Input.currentMethodVersion, implementationReference: "OptionsAnalytics/OptionDelta25Engine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: OptionBSM.numericPolicyVersion,
            state: .approved, dispositionReference: "USER_2026-10-18_OPTION_EVIDENCE_V1",
            knownLimitations: limitations, testFixtures: ["OptionDelta25Tests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-18T00:00:00.000Z"))
        try parameters.validate(); try model.validate()
        return (parameters, model)
    }

    public static func calculate(_ input: OptionDelta25Input) throws -> OptionDelta25Report {
        try Task.checkCancellation()
        guard input.methodVersion == OptionDelta25Input.currentMethodVersion,
              input.createdAt.timeIntervalSince1970.isFinite,
              input.createdAt >= input.daily.input.createdAt else { throw OptionDailyError.invalidInput }
        let daily = try OptionDailyEngine.replay(input.daily)
        let summaries = Dictionary(uniqueKeysWithValues: daily.contractSummaries.map { ($0.contractID, $0) })
        let grouped = Dictionary(grouping: daily.input.contracts, by: { $0.expiry.settlementAt })
        let gate = chainGate(daily)
        var expiries: [OptionDelta25ExpirySummary] = []
        for settlement in grouped.keys.sorted() {
            try Task.checkCancellation()
            let contracts = grouped[settlement] ?? []
            let basisMatches = Set(contracts.map(\.specificationVersion)).count == 1
                && Set(contracts.map(\.multiplier)).count == 1
                && Set(contracts.map { $0.exerciseStyle.rawValue }).count == 1
            let expiryGate: OptionDelta25State? = gate ?? (basisMatches ? nil : .mismatchedContractBasis)
            let call = selection(contracts: contracts.filter { $0.right == .call }, summaries: summaries, right: .call, gate: expiryGate)
            let put = selection(contracts: contracts.filter { $0.right == .put }, summaries: summaries, right: .put, gate: expiryGate)
            let state = call.state == .available ? put.state : call.state
            let skew: Double? = call.iv.flatMap { c in put.iv.map { $0 - c } }
            expiries.append(.init(settlementAt: settlement,
                timeYears: settlement.timeIntervalSince(daily.input.asOf) / 31_536_000,
                call: call, put: put, state: state, putMinusCallSkew: skew))
        }
        let combined = thirtyDay(expiries: expiries, asOf: daily.input.asOf, gate: gate)
        let (parameters, model) = try definitions()
        return .init(schemaVersion: "option-delta25-report.v1", input: input, model: model, parameters: parameters,
            expiries: expiries, call25DeltaIV: combined.call, put25DeltaIV: combined.put,
            putMinusCallSkew: combined.call.flatMap { call in combined.put.map { $0 - call } },
            selectedExpiryInstants: combined.expiries, state: combined.state,
            containsSynthetic: daily.containsSynthetic, researchOnly: true, limitations: limitations)
    }

    public static func replay(_ report: OptionDelta25Report) throws -> OptionDelta25Report {
        let recalculated = try calculate(report.input)
        guard recalculated == report else { throw OptionDailyError.incompatibleReport }
        return recalculated
    }

    private static func chainGate(_ daily: OptionDailyReport) -> OptionDelta25State? {
        if daily.input.sessionCloseAt != daily.input.asOf { return .unverifiedSessionClose }
        if daily.input.coverage != .complete { return .partialChain }
        guard let skew = daily.chainSummary.maxSkewSeconds else { return .unknownQuoteTime }
        if skew > 5 { return .quoteSkew }
        return nil
    }

    private static func selection(contracts: [OptionDailyContractInput], summaries: [String: OptionDailyContractSummary],
                                  right: OptionLabRight, gate: OptionDelta25State?) -> OptionDelta25Selection {
        if let gate { return unavailable(right: right, state: gate) }
        guard !contracts.isEmpty else { return unavailable(right: right, state: .missingSide) }
        var points: [OptionDelta25Point] = []
        for item in contracts.sorted(by: { $0.strike < $1.strike }) {
            guard let summary = summaries[item.contractID], summary.state == .available,
                  let delta = summary.canonicalDelta, let iv = summary.canonicalIV,
                  summary.localIV?.state == .available, delta.isFinite, iv.isFinite, iv > 0
            else { return unavailable(right: right, state: .missingCanonicalIV) }
            points.append(.init(contractID: item.contractID, strike: item.strike, delta: delta, iv: iv))
        }
        return select(points: points, right: right)
    }

    /// Internal numerical kernel. Public callers must pass the complete frozen
    /// daily report through calculate(), which independently regenerates points.
    static func select(points: [OptionDelta25Point], right: OptionLabRight) -> OptionDelta25Selection {
        guard !points.isEmpty else { return unavailable(right: right, state: .missingSide) }
        let target = right == .call ? 0.25 : -0.25
        let bounds = right == .call ? 0.0...1.0 : -1.0...0.0
        for point in points {
            guard point.delta.isFinite, bounds.contains(point.delta), point.iv.isFinite, point.iv > 0,
                  point.strike.amount > 0 else { return unavailable(right: right, state: .missingCanonicalIV) }
        }
        if points.count > 1 {
            for index in 1..<points.count {
                guard points[index - 1].strike < points[index].strike,
                      points[index - 1].delta > points[index].delta else {
                    return unavailable(right: right, state: .nonMonotoneDelta)
                }
            }
        }
        if let exact = points.first(where: { $0.delta == target }) {
            return .init(right: right, targetDelta: target, state: .available, points: [exact], secondPointWeight: 0, iv: exact.iv)
        }
        guard points.count > 1 else { return unavailable(right: right, state: .noDeltaBracket) }
        for index in 1..<points.count {
            let left = points[index - 1], rightPoint = points[index]
            guard left.delta > target, rightPoint.delta < target else { continue }
            let weight = (target - left.delta) / (rightPoint.delta - left.delta)
            let iv = left.iv + weight * (rightPoint.iv - left.iv)
            guard weight.isFinite, weight > 0, weight < 1, iv.isFinite, iv > 0 else {
                return unavailable(right: right, state: .numericFailure)
            }
            return .init(right: right, targetDelta: target, state: .available, points: [left, rightPoint], secondPointWeight: weight, iv: iv)
        }
        return unavailable(right: right, state: .noDeltaBracket)
    }

    private static func unavailable(right: OptionLabRight, state: OptionDelta25State) -> OptionDelta25Selection {
        .init(right: right, targetDelta: right == .call ? 0.25 : -0.25, state: state,
              points: [], secondPointWeight: nil, iv: nil)
    }

    static func thirtyDay(expiries: [OptionDelta25ExpirySummary], asOf: Date,
                          gate: OptionDelta25State?) -> (call: Double?, put: Double?, expiries: [Date], state: OptionDelta25State) {
        if let gate { return (nil, nil, [], gate) }
        let targetSeconds = 30.0 * 86_400, targetT = 30.0 / 365
        let valid = expiries.filter {
            $0.state == .available && $0.call.iv != nil && $0.put.iv != nil && $0.timeYears > 0
        }.sorted { $0.settlementAt < $1.settlementAt }
        let exact = valid.filter { abs($0.settlementAt.timeIntervalSince(asOf) - targetSeconds) <= 1 }.min {
            let a = abs($0.settlementAt.timeIntervalSince(asOf) - targetSeconds)
            let b = abs($1.settlementAt.timeIntervalSince(asOf) - targetSeconds)
            return a == b ? $0.settlementAt < $1.settlementAt : a < b
        }
        if let exact { return (exact.call.iv, exact.put.iv, [exact.settlementAt], .available) }
        guard let below = valid.last(where: { $0.timeYears < targetT }),
              let above = valid.first(where: { $0.timeYears > targetT }),
              targetSeconds - below.settlementAt.timeIntervalSince(asOf) <= targetSeconds,
              above.settlementAt.timeIntervalSince(asOf) - targetSeconds <= targetSeconds,
              let lowCall = below.call.iv, let lowPut = below.put.iv,
              let highCall = above.call.iv, let highPut = above.put.iv else { return (nil, nil, [], .noExpiryBracket) }
        let weight = (targetT - below.timeYears) / (above.timeYears - below.timeYears)
        let callVariance = (lowCall * lowCall * below.timeYears * (1 - weight) + highCall * highCall * above.timeYears * weight) / targetT
        let putVariance = (lowPut * lowPut * below.timeYears * (1 - weight) + highPut * highPut * above.timeYears * weight) / targetT
        guard callVariance.isFinite, callVariance > 0, putVariance.isFinite, putVariance > 0 else {
            return (nil, nil, [], .numericFailure)
        }
        return (sqrt(callVariance), sqrt(putVariance), [below.settlementAt, above.settlementAt], .available)
    }

    public static let limitations = [
        "离线声明范围内的完整链；COMPLETE 不等于真实市场全链，不授予供应商、PIT 或真实世界概率资格。",
        "只用同到期、本地 Mid 反解 IV 与未作权利金调整的有符号 BSM spot Delta；Call +0.25、Put -0.25。",
        "同方向 Delta 随行权价严格下降；缺规范 IV、重复或非单调值均使该方向不可用，不跳过缺口、不外推。",
        "同到期两方向须声明相同合约规格、乘数和行权方式；混合口径不参与插值。手工声明不能证明真实交割资格。",
        "方向内按相邻 Delta 线性插 IV；两方向须使用同一到期或同一组30日期限总方差插值，不混合到期。",
        "偏斜为 Put IV 减 Call IV，单位为十进制波动率；欧式连续股息参考，不含美式提前行权或离散股息。",
        "旧日摘要保持原版本；本报告另存完整父证据并重放。Float64 重放不是跨 CPU/libm 形式化证明。"
    ]
}
