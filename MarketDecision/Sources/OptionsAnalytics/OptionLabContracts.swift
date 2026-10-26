import Foundation
import CoreDomain
import DataContracts

public enum OptionLabStrategy: String, Sendable, Codable, CaseIterable {
    case cashSecuredPut, coveredCall, putCreditSpread, callCreditSpread
}
public enum OptionLabRight: String, Sendable, Codable, CaseIterable { case put, call }
public enum OptionLabOrigin: String, Sendable, Codable, CaseIterable { case manual, synthetic }
public enum OptionLabCapitalOrigin: String, Sendable, Codable { case manual, ledger, synthetic }
public enum OptionLabAsset: String, Sendable, Codable, CaseIterable { case stock, etf }
public enum OptionLabExerciseStyle: String, Sendable, Codable { case american, european }
public enum OptionLabDelivery: String, Sendable, Codable { case standardPhysical100Shares, adjusted, cashSettled }
public enum OptionLabDirection: String, Sendable, Codable { case buy, sell }
public enum OptionLabPricing: String, Sendable, Codable { case mid, conservative, entered }
public enum OptionLabFunding: String, Sendable, Codable { case sufficient, insufficientCash, insufficientShares, notAssessed }
/// Nil on legacy inputs preserves their complete quote/capital evidence requirements.
public enum OptionLabEntryMode: String, Sendable, Codable { case contractParameters }

/// An offline assumption, never a provider quote or a retrospective availability claim.
public struct OptionLabSource: Sendable, Codable, Equatable {
    public let origin: OptionLabOrigin
    public let reference: String
    public let enteredAt: Date
    public init(origin: OptionLabOrigin, reference: String, enteredAt: Date) {
        self.origin = origin; self.reference = reference; self.enteredAt = enteredAt
    }
}

/// First release accepts standard physical delivery of 100 shares only. Adjusted
/// deliverables and index/cash settlement cannot be represented as supported contracts.
public struct OptionLabLeg: Sendable, Codable, Equatable {
    public let contractID: String
    public let symbol: String
    public let right: OptionLabRight
    public let strike: Money
    public let multiplier: Int
    public let exerciseStyle: OptionLabExerciseStyle
    public let delivery: OptionLabDelivery
    public let specificationVersion: String
    public let quantity: Int
    public let expirationDate: MarketDate
    public let bid: Money?
    public let ask: Money?
    public let bidSize: Int?
    public let askSize: Int?
    public let tick: Money?
    /// Explicit planned or recorded unit price. This is not a two-sided market quote.
    public let enteredPrice: Money?
    /// Legacy storage names. In contractParameters mode these are the recorded
    /// calculation instant, never evidence of a market quote or its freshness.
    public let quotedAt: Date
    public let receivedAt: Date
    public let source: OptionLabSource
    public init(contractID: String, symbol: String, right: OptionLabRight, strike: Money,
                multiplier: Int = 100, exerciseStyle: OptionLabExerciseStyle = .american,
                delivery: OptionLabDelivery = .standardPhysical100Shares,
                specificationVersion: String = "assumed-us-equity-standard.v1", quantity: Int, expirationDate: MarketDate,
                bid: Money? = nil, ask: Money? = nil, bidSize: Int? = nil, askSize: Int? = nil, tick: Money? = nil,
                quotedAt: Date, receivedAt: Date, source: OptionLabSource, enteredPrice: Money? = nil) {
        self.contractID = contractID; self.symbol = symbol; self.right = right; self.strike = strike
        self.multiplier = multiplier; self.exerciseStyle = exerciseStyle; self.delivery = delivery
        self.specificationVersion = specificationVersion; self.quantity = quantity; self.expirationDate = expirationDate
        self.bid = bid; self.ask = ask; self.bidSize = bidSize; self.askSize = askSize; self.tick = tick
        self.enteredPrice = enteredPrice
        self.quotedAt = quotedAt; self.receivedAt = receivedAt; self.source = source
    }
    public var isEnteredPrice: Bool { enteredPrice != nil }
    /// The chosen pricing basis, with no fabricated spread or available depth.
    public func valuationPrice() throws -> Money {
        if let enteredPrice {
            guard enteredPrice.amount >= 0 else { throw OptionLabError.invalidQuote }
            return enteredPrice
        }
        guard let bid, let ask, bid.amount >= 0, ask.amount > 0, ask >= bid else { throw OptionLabError.invalidQuote }
        return try bid.adding(ask).multiplied(by: "0.5")
    }
}

public struct OptionLabUnderlying: Sendable, Codable, Equatable {
    public let symbol: String
    public let asset: OptionLabAsset
    public let bid: Money?
    public let ask: Money?
    /// User-entered current price, independent of optional two-sided quote evidence.
    public let enteredPrice: Money?
    /// In contractParameters mode both values record the calculation instant;
    /// no quote availability or freshness is asserted.
    public let quotedAt: Date
    public let receivedAt: Date
    public let source: OptionLabSource
    public init(symbol: String, asset: OptionLabAsset = .stock, bid: Money? = nil, ask: Money? = nil,
                quotedAt: Date, receivedAt: Date, source: OptionLabSource, enteredPrice: Money? = nil) {
        self.symbol = symbol; self.asset = asset; self.bid = bid; self.ask = ask
        self.enteredPrice = enteredPrice
        self.quotedAt = quotedAt; self.receivedAt = receivedAt; self.source = source
    }
    public var isEnteredPrice: Bool { enteredPrice != nil }
    public func valuationPrice() throws -> Money {
        if let enteredPrice {
            guard enteredPrice.amount > 0 else { throw OptionLabError.invalidQuote }
            return enteredPrice
        }
        guard let bid, let ask, bid.amount > 0, ask >= bid else { throw OptionLabError.invalidQuote }
        return try bid.adding(ask).multiplied(by: "0.5")
    }
}

/// Settlement time is explicitly assumed. A weekday or 16:00 fallback is never fabricated.
/// This batch has no official expiry/calendar admission and therefore no tradingDTE output.
public struct OptionLabExpiry: Sendable, Codable, Equatable {
    public let date: MarketDate
    public let settlementAt: Date
    public let source: OptionLabSource
    public init(date: MarketDate, settlementAt: Date, source: OptionLabSource) {
        self.date = date; self.settlementAt = settlementAt; self.source = source
    }
}

/// Cash and shares are gross PRE-TRADE amounts; committed amounts are deducted once.
/// availableShares is the held long-share amount before committedShares are deducted.
/// A ledger bridge must establish obligation completeness before constructing this value.
public struct OptionLabCapital: Sendable, Codable, Equatable {
    public let origin: OptionLabCapitalOrigin
    public let reference: String
    public let asOf: Date
    public let currency: String
    public let cashBeforeTrade: Money
    public let committedCash: Money
    public let availableShares: Money
    public let committedShares: Money
    public let accountID: String?
    public let ledgerRevision: UUID?
    public let underlyingSymbol: String?
    public let underlyingAsset: OptionLabAsset?
    public init(origin: OptionLabCapitalOrigin, reference: String, asOf: Date, currency: String = "USD",
                cashBeforeTrade: Money, committedCash: Money, availableShares: Money, committedShares: Money,
                accountID: String? = nil, ledgerRevision: UUID? = nil,
                underlyingSymbol: String? = nil, underlyingAsset: OptionLabAsset? = nil) {
        self.origin = origin; self.reference = reference; self.asOf = asOf; self.currency = currency
        self.cashBeforeTrade = cashBeforeTrade; self.committedCash = committedCash
        self.availableShares = availableShares; self.committedShares = committedShares
        self.accountID = accountID; self.ledgerRevision = ledgerRevision
        self.underlyingSymbol = underlyingSymbol; self.underlyingAsset = underlyingAsset
    }
}

/// Effective assumptions are frozen in every input. They do not replace actual ledger fees.
/// ticketFee is once per complete strategy; terminalFeeTotal is once per entire terminal event.
public struct OptionLabPolicy: Sendable, Codable, Equatable {
    public let lambda: Money
    public let openingFeePerContract: Money
    public let ticketFee: Money
    public let terminalFeeTotal: Money
    public init(lambda: Money, openingFeePerContract: Money, ticketFee: Money, terminalFeeTotal: Money) {
        self.lambda = lambda; self.openingFeePerContract = openingFeePerContract
        self.ticketFee = ticketFee; self.terminalFeeTotal = terminalFeeTotal
    }
    public static func defaults() throws -> Self {
        try .init(lambda: Money("0.25"), openingFeePerContract: Money("0.65"), ticketFee: Money("0"), terminalFeeTotal: Money("0"))
    }
}

public struct OptionLabInput: Sendable, Codable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let asOf: Date
    public let strategy: OptionLabStrategy
    public let shortLeg: OptionLabLeg
    public let longLeg: OptionLabLeg?
    public let underlying: OptionLabUnderlying
    /// Absent only for an explicit contract-only calculation. Unknown balances
    /// are never replaced by zero or inferred from the required collateral.
    public let capital: OptionLabCapital?
    public let policy: OptionLabPolicy
    public let expiry: OptionLabExpiry
    public let scenarioPrices: [Money]
    public let pricing: OptionLabPricingInput?
    public let risk: OptionLabRiskInput?
    public let scenario: OptionLabScenarioInput?
    public let chainEvidence: OptionChainSelectionEvidence?
    public let entryMode: OptionLabEntryMode?
    /// Explicit average USD acquisition cost per share for this covered quantity.
    /// This separate comparison does not replace current price, account evidence,
    /// actual lot basis or the ledger. Nil means cost was not supplied.
    public let coveredCallCostPerShare: Money?
    public var usesEnteredPrices: Bool { underlying.isEnteredPrice }
    public var isContractOnly: Bool { entryMode == .contractParameters }
    public init(id: UUID = UUID(), createdAt: Date, asOf: Date, strategy: OptionLabStrategy,
                shortLeg: OptionLabLeg, longLeg: OptionLabLeg?, underlying: OptionLabUnderlying,
                capital: OptionLabCapital?, policy: OptionLabPolicy, expiry: OptionLabExpiry, scenarioPrices: [Money],
                pricing: OptionLabPricingInput? = nil, risk: OptionLabRiskInput? = nil, scenario: OptionLabScenarioInput? = nil,
                chainEvidence: OptionChainSelectionEvidence? = nil, entryMode: OptionLabEntryMode? = nil,
                coveredCallCostPerShare: Money? = nil) {
        self.id = id; self.createdAt = createdAt; self.asOf = asOf; self.strategy = strategy
        self.shortLeg = shortLeg; self.longLeg = longLeg; self.underlying = underlying
        self.capital = capital; self.policy = policy; self.expiry = expiry; self.scenarioPrices = scenarioPrices; self.pricing = pricing
        self.risk = risk; self.scenario = scenario; self.chainEvidence = chainEvidence; self.entryMode = entryMode
        self.coveredCallCostPerShare = coveredCallCostPerShare
    }
}

public struct OptionLabFill: Sendable, Codable, Equatable {
    public let contractID: String
    public let direction: OptionLabDirection
    public let unitPrice: Money
}
public struct OptionLabPayoffPoint: Sendable, Codable, Equatable {
    public let spot: Money
    public let pnl: Money
}
public struct OptionLabOutcome: Sendable, Codable, Equatable {
    public let pricing: OptionLabPricing
    public let fills: [OptionLabFill]
    public let grossCredit: Money
    public let totalFees: Money
    /// Net USD total for all contracts, after each declared fee is charged once.
    public let netCreditTotal: Money
    public var netCredit: Money { netCreditTotal }
    public let maxProfit: Money
    public let maxLoss: Money
    /// Nil when the terminal payoff has no zero (e.g. an underwater covered call).
    public let breakEven: Money?
    /// Net pre-trade cash requirement, already includes fees. Do not subtract fees a second time.
    public let capitalRequired: Money
    public let nominalAssignmentPayment: Money
    /// Nil when the account's cash and existing commitments have not been supplied.
    public let availableCashAfterFees: Money?
    public let funding: OptionLabFunding
    public var canFund: Bool { funding == .sufficient }
    public let yieldBase: Money
    public let premiumYield: Money
    public let annualizedSimple: Money
    public let stockMarketValueYield: Money?
    public let returnOnRisk: Money?
    public let points: [OptionLabPayoffPoint]
}

/// Cost-basis terminal arithmetic for the covered shares and this call only.
/// It contains no funding, probability or return-rate qualification.
public struct OptionCoveredCallCostOutcome: Sendable, Codable, Equatable {
    public let pricing: OptionLabPricing
    public let netCreditTotal: Money
    /// May be negative when every terminal outcome loses against the supplied cost.
    public let maxProfit: Money
    /// Nonnegative loss at zero stock price; zero when every outcome is profitable.
    public let maxLoss: Money
    /// Nil when no nonnegative terminal price has zero PnL. K is the start of a
    /// zero-PnL plateau when the capped maximum is exactly zero.
    public let breakEven: Money?
    public let points: [OptionLabPayoffPoint]
}

public struct OptionCoveredCallCostReport: Sendable, Codable, Equatable {
    public let schemaVersion: String
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let costPerShare: Money
    public let coveredShares: Money
    public let mid: OptionCoveredCallCostOutcome
    public let conservative: OptionCoveredCallCostOutcome
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
    public var selectedOutcome: OptionCoveredCallCostOutcome { mid.pricing == .entered ? mid : conservative }
}

public struct OptionLabReport: Sendable, Codable, Equatable {
    public let schemaVersion: String
    public let input: OptionLabInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
    public let dte: Int
    public let expired: Bool
    public let timeYears: Money
    public let tradingDTE: Int?
    /// Retained storage key: quote midpoint for legacy reports, entered current
    /// underlying price for reports whose `usesEnteredPrices` is true.
    public let underlyingMid: Money
    /// Legacy storage names are retained for backward decoding. In entered-price
    /// reports both slots contain the same `.entered` result, never an inferred
    /// market midpoint or a claimed conservative executable price.
    public let mid: OptionLabOutcome
    public let conservative: OptionLabOutcome
    public var usesEnteredPrices: Bool { input.usesEnteredPrices }
    public var selectedOutcome: OptionLabOutcome { usesEnteredPrices ? mid : conservative }
    public let researchOnly: Bool
    public let limitations: [String]
    public let pricing: OptionLabPricingReport?
    public let risk: OptionLabRiskReport?
    public let scenario: OptionLabScenarioReport?
    /// Optional independent acquisition-cost comparison. Legacy reports decode nil.
    public let coveredCallCostBasis: OptionCoveredCallCostReport?
}

public enum OptionLabError: Error, Equatable, LocalizedError {
    case invalidIdentity, invalidTime, invalidQuote, missingTick, insufficientSize, quoteSkew
    case staleQuote, unsupportedContract, mismatchedLegs, invalidPolicy, invalidCapital
    case expired, invalidCredit, invalidScenarios, incompatibleReport, invalidPricingInput, invalidCostBasis
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "请补齐标的、合约及来源说明。"
        case .invalidTime: "请检查输入时刻、报价时刻和明确的纽约到期时刻。"
        case .invalidQuote: "标的当前价须大于零，权利金不能为负；若补充 Bid/Ask，须同时填写、Ask 大于零且 Bid 不高于 Ask。"
        case .missingTick: "须提供正的合法报价步长，不会默认最小 tick。"
        case .insufficientSize: "双边报价张数必须覆盖拟研究张数。"
        case .quoteSkew: "标的与各腿的报价时差不能超过 5 秒。"
        case .staleQuote: "离线情景的报价时刻须在所选评估时刻之前 60 秒内。"
        case .unsupportedContract: "仅支持股票或 ETF 的标准 100 股实物交割合约。"
        case .mismatchedLegs: "价差两腿须同标的、同到期、同数量，且行权价方向正确。"
        case .invalidPolicy: "滑点系数须在 0 至 0.5 之间，费用假设不能为负。"
        case .invalidCapital: "资金必须是同一评估快照的成交前 USD 现金与持股，并列明已承诺额度。"
        case .invalidCostBasis: "持股成本仅适用于备兑 Call，须为非负的每股 USD 成本；未填写时不会用现价代填。"
        case .expired: "合约已到所填到期时刻，不能作为新的前瞻策略计算。"
        case .invalidCredit: "净收入须为正，且不能达到或超过担保名义额或价差宽度金额。"
        case .invalidScenarios: "须提供 1 至 401 个互不重复的非负到期价格。"
        case .invalidPricingInput: "定价模型或连续率假设无效：股息率和理论波动率须非负，并须保留输入来源。"
        case .incompatibleReport: "报告与固定模型或完整输入重算不一致，不能展示为已核对结果。"
        }
    }
}
