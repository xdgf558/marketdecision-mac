import Foundation
import CoreDomain
import DataContracts

/// Fixed, offline CALC-020/021/022 implementation. This API accepts no provider data
/// or substitutable model definition; complete selected policy and overrides are frozen.
public enum OptionLabEngine {
    public static let schemaVersion = "option-lab-report.v1"
    public static let pricingSchemaVersion = "option-lab-report.v2"
    public static let riskSchemaVersion = "option-lab-report.v3"
    public static let enteredSchemaVersion = "option-lab-report.v5.entered"
    public static let contractSchemaVersion = "option-lab-report.v6.contract-parameters"
    public static let coveredCostSchemaVersion = "option-lab-report.v7.covered-call-cost"
    public static let coveredCostReportSchemaVersion = "option-covered-call-cost.v1"
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "options.deterministic.parameters", version: "PARAMETERS_V1",
            revisionID: UUID(uuidString: "C035AA00-2026-4016-8000-000000000001")!,
            values: ["lambda": .decimal(try Money("0.25")), "lambdaMaximum": .decimal(try Money("0.5")),
                     "openingFeePerContractUSD": .decimal(try Money("0.65")), "ticketFeeUSD": .decimal(try Money("0")),
                     "terminalFeeTotalUSD": .decimal(try Money("0")), "maxQuoteSkewSeconds": .integer(5),
                     "maxQuoteAgeSeconds": .integer(60), "annDayBasis": .integer(365), "annMinimumDays": .integer(1),
                     "standardMultiplier": .integer(100), "expiryTime": .text("Explicit assumed product instant; no 16:00 fallback")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-001,020,021,022;ANN_v1")
        let model = ModelDefinition(id: "options.deterministic", version: "options.deterministic.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4016-8000-000000000002")!,
            owner: "OptionsAnalytics", purpose: "Offline terminal-payoff research; no order or provider qualification",
            inputs: [.init(name: "completeScenario", unit: "USD", role: .required)],
            outputs: [.init(name: "terminalPnL", unit: "USD"), .init(name: "simpleAnnualization", unit: "ratio")],
            formula: "CSP=c−N(K−S)+;CC=N(S−B)+c−N(S−K)+;PCS=c−N(Ks−S)++N(Kl−S)+;CCS=c−N(S−Ks)++N(S−Kl)+;B=underlyingMid;c=gross−fees;ANN_v1=yield×365/max(DTE,1)",
            formulaVersion: "options.deterministic.v1+ANN_v1", implementationReference: "OptionsAnalytics/OptionLabEngine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1", knownLimitations: limitations,
            testFixtures: ["OptionsAnalyticsTests"], introducedAt: try MillisecondInstant(iso8601: "2026-10-16T00:00:00.000Z"))
        try parameters.validate(); try model.validate()
        return (parameters, model)
    }

    /// A distinct immutable definition preserves legacy Mid/conservative replay.
    /// The payoff/fee equations are unchanged; explicit prices replace quote-derived fills.
    public static func enteredDefinitions() throws -> (ParameterSet, ModelDefinition) {
        let (parameters, _) = try definitions()
        let model = ModelDefinition(id: "options.deterministic.entered-price", version: "options.deterministic.entered-price.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4025-8000-000000000001")!,
            owner: "OptionsAnalytics", purpose: "Offline terminal-payoff research from explicit unit prices; no order or quote qualification",
            inputs: [.init(name: "completeScenario", unit: "USD", role: .required)],
            outputs: [.init(name: "terminalPnL", unit: "USD"), .init(name: "simpleAnnualization", unit: "ratio")],
            formula: "CSP=c−N(K−S)+;CC=N(S−B)+c−N(S−K)+;PCS=c−N(Ks−S)++N(Kl−S)+;CCS=c−N(S−Ks)++N(S−Kl)+;B=enteredUnderlyingPrice;c=enteredGross−fees;ANN_v1=yield×365/max(DTE,1);noQuoteSlippageOrTickRounding",
            formulaVersion: "options.deterministic.entered-price.v1+ANN_v1", implementationReference: "OptionsAnalytics/OptionLabEngine.entered-price.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion, state: .approved,
            dispositionReference: "Explicit user-selected unit prices; existing CALC-020/021/022 and ANN_v1 equations",
            knownLimitations: enteredLimitations, testFixtures: ["OptionsAnalyticsTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-25T00:00:00.000Z"))
        try model.validate()
        return (parameters, model)
    }

    /// Contract parameters determine payoff without establishing quote evidence
    /// or an account funding assessment. The pre-existing model remains immutable.
    public static func contractDefinitions() throws -> (ParameterSet, ModelDefinition) {
        let (parameters, _) = try definitions()
        let model = ModelDefinition(id: "options.deterministic.contract-parameters", version: "options.deterministic.contract-parameters.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4025-8000-000000000002")!,
            owner: "OptionsAnalytics", purpose: "Offline contract payoff from user-entered parameters; no quote or account funding qualification",
            inputs: [.init(name: "contractParameters", unit: "USD", role: .required)],
            outputs: [.init(name: "terminalPnL", unit: "USD"), .init(name: "simpleAnnualization", unit: "ratio")],
            formula: "CSP=c−N(K−S)+;CC=N(S−B)+c−N(S−K)+;PCS=c−N(Ks−S)++N(Kl−S)+;CCS=c−N(S−Ks)++N(S−Kl)+;B=enteredUnderlyingPrice;c=enteredGross−fees;ANN_v1=yield×365/max(DTE,1);missingCapital=notAssessed;recordedTimeIsNotQuoteEvidence",
            formulaVersion: "options.deterministic.contract-parameters.v1+ANN_v1", implementationReference: "OptionsAnalytics/OptionLabEngine.contract-parameters.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion, state: .approved,
            dispositionReference: "User-authorized contract-parameter calculation; existing CALC-020/021/022 and ANN_v1 equations",
            knownLimitations: contractLimitations, testFixtures: ["OptionsAnalyticsTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-25T00:00:00.000Z"))
        try model.validate()
        return (parameters, model)
    }

    /// Separate immutable comparison model; historical forward-price models,
    /// definitions and default fee policies remain unchanged.
    public static func coveredCostDefinitions() throws -> (ParameterSet, ModelDefinition) {
        let (parameters, _) = try definitions()
        let model = ModelDefinition(id: "options.covered-call-cost", version: "options.covered-call-cost.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4026-8000-000000000001")!,
            owner: "OptionsAnalytics", purpose: "Covered-share acquisition-cost terminal comparison; not a historical account return or tax basis",
            inputs: [.init(name: "coveredCallInputAndCost", unit: "USD", role: .required)],
            outputs: [.init(name: "costBasisTerminalPnL", unit: "USD")],
            formula: "PNL=(min(S,K)-C)*N+netCredit;maxProfit=(K-C)*N+netCredit;maxLoss=max(C*N-netCredit,0);breakEven=(C*N-netCredit)/N only when PNL(0)<=0<=maxProfit;netCredit includes current call fees exactly once",
            formulaVersion: "options.covered-call-cost.v1", implementationReference: "OptionsAnalytics/OptionLabEngine.covered-call-cost.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion, state: .approved,
            dispositionReference: "User-authorized optional per-share acquisition cost; existing covered-call terminal equation with explicit separate basis",
            knownLimitations: ["持股成本为用户明确填写的平均每股成本，不代表已核对账本批次或税务成本。",
                "仅覆盖本次数量与本次期权净权利金；不自动加入历史股息、其他期权收入、税费或提前指派路径。",
                "当前股价、概率及账户资金核对仍沿原口径，不因输入成本获得新的资格。"],
            testFixtures: ["OptionCoveredCallCostTests"], introducedAt: try MillisecondInstant(iso8601: "2026-10-26T00:00:00.000Z"))
        try model.validate()
        return (parameters, model)
    }

    public static func calculate(_ input: OptionLabInput) throws -> OptionLabReport {
        try Task.checkCancellation()
        try validate(input)
        try OptionChainEvidence.validate(input)
        let dte = try dayDifference(input.asOf, input.expiry.date)
        let timeYears = try Money(exactInterval(input.expiry.settlementAt.timeIntervalSince(input.asOf))).divided(by: "31536000")
        let underlyingMid = try input.underlying.valuationPrice()
        let (parameters, model) = try input.isContractOnly ? contractDefinitions() : input.usesEnteredPrices ? enteredDefinitions() : definitions()
        let mid = try outcome(input, pricing: input.usesEnteredPrices ? .entered : .mid, basis: underlyingMid, dte: dte)
        let conservative = input.usesEnteredPrices ? mid : try outcome(input, pricing: .conservative, basis: underlyingMid, dte: dte)
        var notes = input.isContractOnly ? contractLimitations : input.usesEnteredPrices ? enteredLimitations : limitations
        if dte < 7 { notes.append("DTE 小于 7：简单年化高度敏感，不代表可重复收益或组合 CAGR。") }
        if input.shortLeg.source.origin == .synthetic || input.longLeg?.source.origin == .synthetic || input.underlying.source.origin == .synthetic || input.expiry.source.origin == .synthetic || input.capital?.origin == .synthetic {
            notes.append("包含合成输入；不能转换为真实历史、行情资格或普通账户交易。")
        }
        if input.capital?.origin == .ledger { notes.append("账本仅提供冻结的本地资金参考；未同步券商，不能作为可执行风险限额。") }
        if input.capital == nil { notes.append("未提供账户现金、持股及已承诺额度，资金充足性未评估；所需担保额与所需股数不是实际可用余额。") }
        let pricing = try input.pricing.map { try OptionLabPricingEngine.calculate(input: input, assumptions: $0,
            underlyingMid: underlyingMid, mid: mid, conservative: conservative, dte: dte) }
        if pricing != nil {
            notes.removeAll { $0 == "没有 IV、Greeks、概率、历史频率、事件风险或自动下单。" }
            notes.append("独立定价模块仅提供欧式参考及风险中性研究；原确定性模型、成交及费用口径未更换。")
            if input.pricing?.source.origin == .synthetic { notes.append("定价假设含合成来源，不能据此授予真实行情或校准资格。") }
        }
        let risk = try input.risk.map { try OptionLabRiskEngine.calculate(input: input, assumptions: $0,
            pricing: pricing, underlyingMid: underlyingMid, dte: dte) }
        let scenario = try input.scenario.map { try OptionLabScenarioEngine.calculate(input: input, assumptions: $0,
            pricing: pricing, underlyingMid: underlyingMid, mid: mid, conservative: conservative) }
        if risk != nil || scenario != nil {
            notes.removeAll { $0 == "没有 IV、Greeks、概率、历史频率、事件风险或自动下单。" }
            notes.append("风险与情景为显式离线假设；不提供真实行权概率、成交保证或实盘指令。")
        }
        let costBasis = try input.coveredCallCostPerShare.map {
            try coveredCostReport(input: input, cost: $0, mid: mid, conservative: conservative)
        }
        return .init(schemaVersion: reportSchema(input), input: input, model: model, parameters: parameters,
                     dte: dte, expired: false, timeYears: timeYears, tradingDTE: nil, underlyingMid: underlyingMid,
                     mid: mid, conservative: conservative, researchOnly: true, limitations: notes, pricing: pricing, risk: risk, scenario: scenario,
                     coveredCallCostBasis: costBasis)
    }

    /// Decode alone is never verification. Refuse changed model, parameters, inputs or results.
    public static func replay(_ report: OptionLabReport) throws -> OptionLabReport {
        guard report.schemaVersion == reportSchema(report.input),
              (report.input.pricing == nil) == (report.pricing == nil),
              (report.input.risk == nil) == (report.risk == nil),
              (report.input.scenario == nil) == (report.scenario == nil),
              (report.input.coveredCallCostPerShare == nil) == (report.coveredCallCostBasis == nil) else { throw OptionLabError.incompatibleReport }
        let expected = try calculate(report.input)
        guard expected == report else { throw OptionLabError.incompatibleReport }
        return expected
    }

    private static func reportSchema(_ input: OptionLabInput) -> String {
        if input.coveredCallCostPerShare != nil { return coveredCostSchemaVersion }
        if input.isContractOnly { return contractSchemaVersion }
        if input.usesEnteredPrices { return enteredSchemaVersion }
        if input.chainEvidence != nil { return "option-lab-report.v4.chain" }
        if input.risk != nil || input.scenario != nil { return riskSchemaVersion }
        return input.pricing == nil ? schemaVersion : pricingSchemaVersion
    }

    private static let limitations = [
        "离线手动或合成情景，仅研究用途；没有实时、PIT、供应商、成交或分析资格。",
        "按 Reg T 现金担保口径计算，与你的券商实际占用可能不同。",
        "FEE_ASSUMPTION：预估费用不是券商报价，也不改写实际账本费用。",
        "Mid 是比较基准，不是可成交价格或收益上限；保守报价同样不保证成交。",
        "合约身份、标准实物交割与美式行权均为显式情景假设，未经 OCC 合约核验。",
        "仅计算持有到所填到期时刻的损益，不包含提前平仓、指派路径、股息或税务。",
        "到期时刻是显式离线假设；未接入官方产品日历，tradingDTE 不可用。",
        "没有 IV、Greeks、概率、历史频率、事件风险或自动下单。"
    ]
    private static let enteredLimitations = limitations.map {
        $0 == "Mid 是比较基准，不是可成交价格或收益上限；保守报价同样不保证成交。"
            ? "按填写的标的当前价和计划或实际单位成交价测算；未由单价推造 Bid/Ask、价差、深度或保守成交价，填写实际价格也不会自动记账。"
            : $0
    }
    private static let contractLimitations = enteredLimitations + [
        "仅按所填合约参数计算；本地合约标识、录入时间和来源标签由系统记录，不是行情身份、报价时间或时效证据。",
        "图表价格仅是到期损益绘图坐标，不是预测价格或概率样本。"
    ]

    private static func validate(_ input: OptionLabInput) throws {
        if let cost = input.coveredCallCostPerShare {
            guard input.strategy == .coveredCall, cost.amount >= 0 else { throw OptionLabError.invalidCostBasis }
        }
        let allTimes = [input.createdAt, input.asOf, input.expiry.settlementAt] + (input.capital.map { [$0.asOf] } ?? [])
        guard allTimes.allSatisfy({ $0.timeIntervalSince1970.isFinite }), input.createdAt >= input.asOf,
              input.capital.map({ $0.asOf == input.asOf }) ?? true else { throw OptionLabError.invalidTime }
        if input.isContractOnly {
            guard input.usesEnteredPrices, input.chainEvidence == nil,
                  input.underlying.source.origin == .manual, input.shortLeg.source.origin == .manual,
                  input.longLeg.map({ $0.source.origin == .manual }) ?? true,
                  input.expiry.source.origin == .manual,
                  input.capital.map({ $0.origin == .manual }) ?? true,
                  input.pricing == nil, input.risk == nil, input.scenario == nil else {
                throw OptionLabError.incompatibleReport
            }
        } else if input.capital == nil { throw OptionLabError.invalidCapital }
        let zone = TimeZone(identifier: "America/New_York")!
        _ = try input.expiry.date.start(in: zone)
        guard marketDate(input.expiry.settlementAt) == input.expiry.date else { throw OptionLabError.invalidTime }
        guard input.expiry.settlementAt > input.asOf else { throw OptionLabError.expired }
        try validate(source: input.expiry.source, createdAt: input.createdAt)
        let under = input.underlying
        guard symbol(under.symbol) else { throw OptionLabError.invalidIdentity }
        if input.usesEnteredPrices {
            guard input.chainEvidence == nil, input.shortLeg.isEnteredPrice,
                  input.longLeg.map(\.isEnteredPrice) ?? true else { throw OptionLabError.incompatibleReport }
            _ = try under.valuationPrice()
            try optionalQuote(bid: under.bid, ask: under.ask, positiveBid: true)
        } else {
            guard !input.shortLeg.isEnteredPrice, input.longLeg.map({ !$0.isEnteredPrice }) ?? true else {
                throw OptionLabError.incompatibleReport
            }
            _ = try under.valuationPrice()
        }
        try validate(source: under.source, createdAt: input.createdAt)
        if input.isContractOnly {
            try recordedTime(under.quotedAt, receivedAt: under.receivedAt, asOf: input.asOf)
            guard under.bid == nil, under.ask == nil else { throw OptionLabError.incompatibleReport }
        } else { try quoteTime(under.quotedAt, receivedAt: under.receivedAt, asOf: input.asOf) }
        let short = input.shortLeg
        try validate(leg: short, input: input)
        let isSpread = input.strategy == .putCreditSpread || input.strategy == .callCreditSpread
        let right: OptionLabRight = input.strategy == .cashSecuredPut || input.strategy == .putCreditSpread ? .put : .call
        guard short.right == right, isSpread == (input.longLeg != nil) else { throw OptionLabError.mismatchedLegs }
        if let long = input.longLeg {
            try validate(leg: long, input: input)
            guard long.contractID != short.contractID, long.right == short.right, long.quantity == short.quantity,
                  (input.strategy == .putCreditSpread ? long.strike < short.strike : long.strike > short.strike)
            else { throw OptionLabError.mismatchedLegs }
        }
        if !input.isContractOnly {
            let times = [under.quotedAt, short.quotedAt] + (input.longLeg.map { [$0.quotedAt] } ?? [])
            guard let first = times.min(), let last = times.max(), last.timeIntervalSince(first) <= 5 else { throw OptionLabError.quoteSkew }
        }
        let policy = input.policy
        guard policy.lambda.amount >= 0, policy.lambda.amount <= Decimal(string: "0.5")!,
              policy.openingFeePerContract.amount >= 0, policy.ticketFee.amount >= 0, policy.terminalFeeTotal.amount >= 0
        else { throw OptionLabError.invalidPolicy }
        if let capital = input.capital {
            guard clean(capital.reference), capital.currency == "USD",
                  [capital.cashBeforeTrade, capital.committedCash, capital.availableShares, capital.committedShares].allSatisfy({ $0.amount >= 0 }),
                  (capital.origin == .ledger ? (capital.accountID.map(clean) == true && capital.ledgerRevision != nil && capital.underlyingSymbol == input.underlying.symbol && capital.underlyingAsset == input.underlying.asset) : (capital.accountID == nil && capital.ledgerRevision == nil && capital.underlyingSymbol == nil && capital.underlyingAsset == nil))
            else { throw OptionLabError.invalidCapital }
        }
        guard (1...401).contains(input.scenarioPrices.count), input.scenarioPrices.allSatisfy({ $0.amount >= 0 }),
              Set(input.scenarioPrices.map(\.decimalString)).count == input.scenarioPrices.count else { throw OptionLabError.invalidScenarios }
    }

    private static func validate(leg: OptionLabLeg, input: OptionLabInput) throws {
        guard clean(leg.contractID), leg.contractID.utf8.count <= 128 else { throw OptionLabError.invalidIdentity }
        guard leg.symbol == input.underlying.symbol, leg.expirationDate == input.expiry.date else { throw OptionLabError.mismatchedLegs }
        guard leg.multiplier == 100, leg.exerciseStyle == .american, leg.delivery == .standardPhysical100Shares,
              leg.specificationVersion == "assumed-us-equity-standard.v1", leg.quantity > 0, leg.quantity <= Int.max / 200, leg.strike.amount > 0 else { throw OptionLabError.unsupportedContract }
        if input.usesEnteredPrices {
            guard leg.isEnteredPrice else { throw OptionLabError.invalidQuote }
            _ = try leg.valuationPrice()
            try optionalQuote(bid: leg.bid, ask: leg.ask, positiveBid: false)
            guard (leg.bidSize == nil) == (leg.askSize == nil),
                  leg.bidSize.map({ $0 >= 0 }) ?? true, leg.askSize.map({ $0 >= 0 }) ?? true else {
                throw OptionLabError.insufficientSize
            }
            if let tick = leg.tick, tick.amount <= 0 { throw OptionLabError.missingTick }
        } else {
            _ = try leg.valuationPrice()
            guard let tick = leg.tick, tick.amount > 0 else { throw OptionLabError.missingTick }
            guard let bidSize = leg.bidSize, let askSize = leg.askSize,
                  bidSize >= leg.quantity, askSize >= leg.quantity else { throw OptionLabError.insufficientSize }
        }
        if input.isContractOnly {
            try recordedTime(leg.quotedAt, receivedAt: leg.receivedAt, asOf: input.asOf)
            guard leg.bid == nil, leg.ask == nil, leg.bidSize == nil, leg.askSize == nil, leg.tick == nil else {
                throw OptionLabError.incompatibleReport
            }
        } else { try quoteTime(leg.quotedAt, receivedAt: leg.receivedAt, asOf: input.asOf) }
        try validate(source: leg.source, createdAt: input.createdAt)
    }
    private static func validate(source: OptionLabSource, createdAt: Date) throws {
        guard clean(source.reference), source.reference.utf8.count <= 4096 else { throw OptionLabError.invalidIdentity }
        guard source.enteredAt.timeIntervalSince1970.isFinite, source.enteredAt <= createdAt else { throw OptionLabError.invalidTime }
    }
    private static func optionalQuote(bid: Money?, ask: Money?, positiveBid: Bool) throws {
        guard (bid == nil) == (ask == nil) else { throw OptionLabError.invalidQuote }
        guard let bid, let ask else { return }
        guard (positiveBid ? bid.amount > 0 : bid.amount >= 0), ask.amount > 0, ask >= bid else {
            throw OptionLabError.invalidQuote
        }
    }
    private static func quoteTime(_ quotedAt: Date, receivedAt: Date, asOf: Date) throws {
        guard quotedAt.timeIntervalSince1970.isFinite, receivedAt.timeIntervalSince1970.isFinite,
              quotedAt <= receivedAt, receivedAt <= asOf else { throw OptionLabError.invalidTime }
        guard asOf.timeIntervalSince(quotedAt) <= 60 else { throw OptionLabError.staleQuote }
    }
    private static func recordedTime(_ recordedAt: Date, receivedAt: Date, asOf: Date) throws {
        guard recordedAt == asOf, receivedAt == asOf else { throw OptionLabError.invalidTime }
    }

    private static func coveredCostReport(input: OptionLabInput, cost: Money,
                                          mid: OptionLabOutcome, conservative: OptionLabOutcome) throws -> OptionCoveredCallCostReport {
        let (parameters, model) = try coveredCostDefinitions()
        let shares = try Money(String(input.shortLeg.quantity * input.shortLeg.multiplier))
        let midCost = try coveredCostOutcome(input: input, cost: cost, shares: shares, forward: mid)
        let conservativeCost = input.usesEnteredPrices ? midCost
            : try coveredCostOutcome(input: input, cost: cost, shares: shares, forward: conservative)
        return .init(schemaVersion: coveredCostReportSchemaVersion, model: model, parameters: parameters,
                     costPerShare: cost, coveredShares: shares, mid: midCost, conservative: conservativeCost)
    }

    private static func coveredCostOutcome(input: OptionLabInput, cost: Money, shares: Money,
                                           forward: OptionLabOutcome) throws -> OptionCoveredCallCostOutcome {
        let zero = try Money("0"), strike = input.shortLeg.strike, credit = forward.netCreditTotal
        let totalCost = try cost.multiplied(by: shares.decimalString)
        let maxProfit = try strike.subtracting(cost).multiplied(by: shares.decimalString).adding(credit)
        let lossAtZero = try totalCost.subtracting(credit)
        let maxLoss = max(zero, lossAtZero)
        // Check exact aggregate signs before division: rounding a small negative
        // capped payoff up to a strike-price root must not manufacture a zero.
        let breakEven: Money?
        if lossAtZero.amount >= 0 && maxProfit.amount >= 0 {
            let candidate = try lossAtZero.divided(by: shares.decimalString)
            guard candidate >= zero, candidate <= strike else { throw OptionLabError.invalidCostBasis }
            breakEven = candidate
        } else { breakEven = nil }
        var samples = forward.points.map(\.spot) + [zero, strike]
        if let breakEven { samples.append(breakEven) }
        let prices = try Set(samples.map(\.decimalString)).map(Money.init).sorted()
        let points = try prices.map { spot in
            OptionLabPayoffPoint(spot: spot,
                pnl: try min(spot, strike).subtracting(cost).multiplied(by: shares.decimalString).adding(credit))
        }
        return .init(pricing: forward.pricing, netCreditTotal: credit, maxProfit: maxProfit,
                     maxLoss: maxLoss, breakEven: breakEven, points: points)
    }

    private static func outcome(_ input: OptionLabInput, pricing: OptionLabPricing, basis: Money, dte: Int) throws -> OptionLabOutcome {
        let zero = try Money("0"), short = input.shortLeg, quantity = short.quantity
        let units = String(short.multiplier * quantity)
        let sell = try price(short, direction: .sell, pricing: pricing, lambda: input.policy.lambda)
        var fills = [OptionLabFill(contractID: short.contractID, direction: .sell, unitPrice: sell)]
        var unitCredit = sell
        if let long = input.longLeg {
            let buy = try price(long, direction: .buy, pricing: pricing, lambda: input.policy.lambda)
            unitCredit = try unitCredit.subtracting(buy)
            fills.append(.init(contractID: long.contractID, direction: .buy, unitPrice: buy))
        }
        let gross = try unitCredit.multiplied(by: units)
        let fees = try input.policy.openingFeePerContract.multiplied(by: String(quantity * fills.count))
            .adding(input.policy.ticketFee).adding(input.policy.terminalFeeTotal)
        let credit = try gross.subtracting(fees)
        let nominal = try short.strike.multiplied(by: units)
        let basisTotal = try basis.multiplied(by: units)
        let nominalRisk: Money
        if let long = input.longLeg {
            nominalRisk = try (input.strategy == .putCreditSpread ? short.strike.subtracting(long.strike) : long.strike.subtracting(short.strike)).multiplied(by: units)
        } else { nominalRisk = input.strategy == .coveredCall ? basisTotal : nominal }
        guard credit.amount > 0, credit < nominalRisk else { throw OptionLabError.invalidCredit }
        let maxLoss = try nominalRisk.subtracting(credit)
        let maxProfit = input.strategy == .coveredCall ? try nominal.subtracting(basisTotal).adding(credit) : credit
        let creditPerShare = try credit.divided(by: units)
        let potentialBreakEven = input.strategy == .callCreditSpread ? try short.strike.adding(creditPerShare) : try (input.strategy == .coveredCall ? basis : short.strike).subtracting(creditPerShare)
        let breakEven = maxProfit.amount < 0 ? nil : potentialBreakEven
        let capitalRequired = input.strategy == .coveredCall ? zero : maxLoss
        let funding: OptionLabFunding
        let cashAfterFees: Money?
        if let capital = input.capital {
            let cashFree = try capital.cashBeforeTrade.subtracting(capital.committedCash)
            let cashNetFees = try cashFree.subtracting(fees)
            let sharesFree = try capital.availableShares.subtracting(capital.committedShares)
            cashAfterFees = cashNetFees
            if input.strategy == .coveredCall, sharesFree < (try Money(units)) { funding = .insufficientShares }
            else if input.strategy == .coveredCall ? cashNetFees.amount < 0 : cashFree < capitalRequired { funding = .insufficientCash }
            else { funding = .sufficient }
        } else { cashAfterFees = nil; funding = .notAssessed }
        // cashFree >= nominal − (gross − fees) is equivalent to cashAfterFees + gross >= nominal.
        // Comparing cashAfterFees to maxLoss would incorrectly charge the same fee twice.
        let yieldBase = input.strategy == .coveredCall ? nominal : maxLoss
        let premiumYield = try credit.divided(by: yieldBase.decimalString)
        let annualized = try premiumYield.multiplied(by: "365").divided(by: String(max(dte, 1)))
        // Include every kink even when the user supplies only a sparse scenario grid.
        // Straight chart segments then represent the exact terminal piecewise payoff.
        var plotPrices = input.scenarioPrices + [zero, short.strike]
        if let long = input.longLeg { plotPrices.append(long.strike) }
        if let breakEven, breakEven.amount >= 0 { plotPrices.append(breakEven) }
        let uniquePrices = try Set(plotPrices.map(\.decimalString)).map(Money.init).sorted()
        let points = try uniquePrices.map { spot in
            OptionLabPayoffPoint(spot: spot, pnl: try payoff(input, spot: spot, credit: credit, basis: basis))
        }
        return .init(pricing: pricing, fills: fills, grossCredit: gross, totalFees: fees, netCreditTotal: credit,
                     maxProfit: maxProfit, maxLoss: maxLoss, breakEven: breakEven, capitalRequired: capitalRequired,
                     nominalAssignmentPayment: input.strategy == .cashSecuredPut || input.strategy == .putCreditSpread ? nominal : zero,
                     availableCashAfterFees: cashAfterFees, funding: funding, yieldBase: yieldBase,
                     premiumYield: premiumYield, annualizedSimple: annualized,
                     stockMarketValueYield: input.strategy == .coveredCall ? try credit.divided(by: basisTotal.decimalString) : nil,
                     returnOnRisk: maxLoss.amount > 0 ? try max(maxProfit, zero).divided(by: maxLoss.decimalString) : nil,
                     points: points)
    }
    private static func payoff(_ input: OptionLabInput, spot: Money, credit: Money, basis: Money) throws -> Money {
        let zero = try Money("0"), short = input.shortLeg, units = String(short.multiplier * short.quantity)
        func intrinsic(_ leg: OptionLabLeg) throws -> Money {
            try max(zero, leg.right == .put ? leg.strike.subtracting(spot) : spot.subtracting(leg.strike)).multiplied(by: units)
        }
        var result = try credit.subtracting(intrinsic(short))
        if let long = input.longLeg { result = try result.adding(intrinsic(long)) }
        if input.strategy == .coveredCall { result = try result.adding(spot.subtracting(basis).multiplied(by: units)) }
        return result
    }
    private static func price(_ leg: OptionLabLeg, direction: OptionLabDirection, pricing: OptionLabPricing, lambda: Money) throws -> Money {
        if pricing == .entered {
            guard leg.isEnteredPrice else { throw OptionLabError.invalidQuote }
            return try leg.valuationPrice()
        }
        guard !leg.isEnteredPrice, let bid = leg.bid, let ask = leg.ask else { throw OptionLabError.invalidQuote }
        let mid = try midpoint(bid, ask)
        guard pricing == .conservative else { return mid } // Mid is an unrounded mathematical comparison.
        let adjustment = try ask.subtracting(bid).multiplied(by: lambda.decimalString)
        let raw = direction == .buy ? try mid.adding(adjustment) : try mid.subtracting(adjustment)
        guard let tick = leg.tick else { throw OptionLabError.missingTick }
        let rounded = try OptionTick.round(raw, tick: tick, upward: direction == .buy)
        // An illegal/misdeclared tick must not manufacture a fill beyond the observed market.
        guard rounded >= bid, rounded <= ask else { throw OptionLabError.invalidQuote }
        return rounded
    }
    private static func midpoint(_ bid: Money, _ ask: Money) throws -> Money {
        // Multiplication by an exact half avoids the 18-place division output boundary.
        try bid.adding(ask).multiplied(by: "0.5")
    }
    private static func clean(_ text: String) -> Bool { !text.isEmpty && text == text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func symbol(_ text: String) -> Bool { text.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}$"#, options: .regularExpression) != nil }
    private static func marketDate(_ instant: Date) -> MarketDate {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return .init(year: calendar.component(.year, from: instant), month: calendar.component(.month, from: instant), day: calendar.component(.day, from: instant))
    }
    private static func dayDifference(_ asOf: Date, _ expiry: MarketDate) throws -> Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.dateComponents([.day], from: try marketDate(asOf).start(in: calendar.timeZone), to: try expiry.start(in: calendar.timeZone)).day ?? 0
    }
    private static func exactInterval(_ interval: TimeInterval) -> String {
        // TimeInterval is only used for elapsed seconds, never for USD. Fixed decimal
        // spelling makes subsecond time explicit; dates themselves retain original precision.
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), interval)
    }
}

/// Exact positive decimal floor/ceiling to a supplied tick. Money division's 18-place
/// rounding must not turn an amount just below a tick into a full tick.
private enum OptionTick {
    static func round(_ price: Money, tick: Money, upward: Bool) throws -> Money {
        func parts(_ value: Money) -> (String, Int) {
            let pieces = value.decimalString.split(separator: ".")
            return (String(pieces.joined()), pieces.count == 2 ? pieces[1].count : 0)
        }
        let p = parts(price), t = parts(tick)
        let numerator = trim(p.0 + String(repeating: "0", count: t.1))
        let denominator = trim(t.0 + String(repeating: "0", count: p.1))
        var remainder = "0", quotient = ""
        for character in numerator {
            remainder = trim(remainder + String(character)); var digit = 0
            while compare(remainder, denominator) >= 0 { remainder = subtract(remainder, denominator); digit += 1 }
            quotient += String(digit)
        }
        var integer = try Money(trim(quotient))
        if upward, remainder != "0" { integer = try integer.adding(Money("1")) }
        return try tick.multiplied(by: integer.decimalString)
    }
    static func trim(_ text: String) -> String { let p = text.drop(while: { $0 == "0" }); return p.isEmpty ? "0" : String(p) }
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        return lhs == rhs ? 0 : lhs < rhs ? -1 : 1
    }
    static func subtract(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs.utf8.reversed()), b = Array(rhs.utf8.reversed())
        var borrow = 0, digits: [UInt8] = []
        for i in a.indices {
            var digit = Int(a[i] - 48) - (i < b.count ? Int(b[i] - 48) : 0) - borrow
            borrow = digit < 0 ? 1 : 0; if digit < 0 { digit += 10 }; digits.append(UInt8(digit + 48))
        }
        return trim(String(decoding: digits.reversed(), as: UTF8.self))
    }
}
