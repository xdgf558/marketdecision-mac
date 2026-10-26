import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine
import Persistence

public enum OptionLabDraftError: Error, Equatable, Sendable {
    case invalidNumber, missingField, invalidDate, incompatibleLedgerBasis, requiresFullEvidence
}

/// Optional model inputs never acquire market values from blank fields. An old
/// payoff-only snapshot remains payoff-only until this mode is explicitly enabled.
public struct OptionLabPricingDraft: Equatable, Sendable {
    public var enabled = false
    public var rate = ""
    public var dividendYield = ""
    public var volatility = ""
    public var sourceReference = ""
    public private(set) var methodVersion = "options.bsm-risk-neutral.v1"
    public init() {}
    init(_ input: OptionLabPricingInput) {
        enabled = true; rate = input.rate.decimalString; dividendYield = input.dividendYield.decimalString
        volatility = input.volatility.decimalString; sourceReference = input.source.reference; methodVersion = input.methodVersion
    }
    func build(origin: OptionLabOrigin, enteredAt: Date) throws -> OptionLabPricingInput? {
        guard enabled else { return nil }
        guard !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OptionLabDraftError.missingField }
        return try .init(rate: Money(rate), dividendYield: Money(dividendYield), volatility: Money(volatility),
            source: .init(origin: origin, reference: sourceReference, enteredAt: enteredAt), methodVersion: methodVersion)
    }
}

/// Optional instantaneous scenario axes. Percent-of-spot shocks and absolute
/// volatility percentage points have deliberately different input units.
public struct OptionLabScenarioDraft: Equatable, Sendable {
    public var enabled = false
    public var spotShocks = ""
    public var volatilityPointShocks = ""
    public var sourceReference = ""
    public private(set) var methodVersion = "options.scenario-matrix.v1"
    public init() {}
    init(_ input: OptionLabScenarioInput) {
        enabled = true
        spotShocks = input.spotShocks.map(\.decimalString).joined(separator: ", ")
        volatilityPointShocks = input.volatilityPointShocks.map(\.decimalString).joined(separator: ", ")
        sourceReference = input.source.reference; methodVersion = input.methodVersion
    }
    func build(origin: OptionLabOrigin, enteredAt: Date) throws -> OptionLabScenarioInput? {
        guard enabled else { return nil }
        guard !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OptionLabDraftError.missingField }
        func axis(_ text: String) throws -> [Money] {
            let values = text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else { throw OptionLabDraftError.missingField }
            return try values.map { try Money($0) }
        }
        return try .init(source: .init(origin: origin, reference: sourceReference, enteredAt: enteredAt),
            spotShocks: axis(spotShocks), volatilityPointShocks: axis(volatilityPointShocks), methodVersion: methodVersion)
    }
}

public struct OptionLabLegDraft: Equatable, Sendable {
    public var contractID = ""
    public var strike = ""
    public var multiplier = "100"
    public var quantity = "1"
    /// A user-entered planned or actual premium for research; never a Bid/Ask substitute.
    public var enteredPrice = ""
    public var bid = ""
    public var ask = ""
    public var bidSize = ""
    public var askSize = ""
    public var tick = ""
    public var quotedAt = ""
    public var receivedAt = ""
    public var sourceReference = ""
    private var originalQuotedAt: Date?
    private var originalReceivedAt: Date?
    public init() {}
    init(_ leg: OptionLabLeg) {
        contractID = leg.contractID; strike = leg.strike.decimalString
        multiplier = String(leg.multiplier); quantity = String(leg.quantity)
        enteredPrice = leg.enteredPrice?.decimalString ?? ""
        bid = leg.bid?.decimalString ?? ""; ask = leg.ask?.decimalString ?? ""
        bidSize = leg.bidSize.map(String.init) ?? ""; askSize = leg.askSize.map(String.init) ?? ""; tick = leg.tick?.decimalString ?? ""
        quotedAt = optionDraftTimestamp(leg.quotedAt); receivedAt = optionDraftTimestamp(leg.receivedAt)
        originalQuotedAt = leg.quotedAt; originalReceivedAt = leg.receivedAt; sourceReference = leg.source.reference
    }
    fileprivate mutating func applyManualQuoteTime(_ date: Date, reference: String) {
        if contractID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { contractID = "MANUAL-" + UUID().uuidString }
        quotedAt = optionDraftTimestamp(date); receivedAt = optionDraftTimestamp(date)
        originalQuotedAt = date; originalReceivedAt = date; sourceReference = reference
    }
    func build(symbol: String, right: OptionLabRight, expiry: MarketDate, source: OptionLabSource,
               usesEnteredPrices: Bool) throws -> OptionLabLeg {
        guard let multiplier = Int(multiplier), let quantity = Int(quantity) else {
            throw OptionLabDraftError.invalidNumber
        }
        let bid = try optionDraftOptionalMoney(self.bid), ask = try optionDraftOptionalMoney(self.ask)
        let bidSize = try optionDraftOptionalInt(self.bidSize), askSize = try optionDraftOptionalInt(self.askSize)
        guard (bid == nil) == (ask == nil), (bidSize == nil) == (askSize == nil),
              usesEnteredPrices || (bid != nil && ask != nil && bidSize != nil && askSize != nil)
        else { throw OptionLabDraftError.missingField }
        return try .init(contractID: contractID, symbol: symbol, right: right, strike: Money(strike), multiplier: multiplier,
            quantity: quantity, expirationDate: expiry, bid: bid, ask: ask, bidSize: bidSize, askSize: askSize,
            tick: optionDraftOptionalMoney(tick), quotedAt: optionDraftDate(quotedAt, original: originalQuotedAt), receivedAt: optionDraftDate(receivedAt, original: originalReceivedAt),
            source: .init(origin: source.origin, reference: sourceReference.isEmpty ? source.reference : sourceReference, enteredAt: source.enteredAt),
            enteredPrice: usesEnteredPrices ? Money(enteredPrice) : nil)
    }
}

/// Manual fields begin blank. Loading an explicit synthetic template permanently
/// retains its synthetic source until the user starts a separate manual draft.
public struct OptionLabInputDraft: Equatable, Sendable {
    public var strategy: OptionLabStrategy = .cashSecuredPut
    public private(set) var origin: OptionLabOrigin = .manual
    public var symbol = ""
    public var asset: OptionLabAsset = .stock
    public var asOf = ""
    public var expirationDate = ""
    public var settlementAt = ""
    public var sourceReference = ""
    public var expiryReference = ""
    /// A new manual calculation needs contract parameters only. Existing reports
    /// retain their evidence mode; choosing this mode never re-labels a source.
    public var usesContractParametersOnly = true
    /// New manual drafts need one current price and one premium per leg. Copying
    /// an older/chain report retains its explicit two-sided quotation mode.
    public var usesEnteredPrices = true
    public var underlyingPrice = ""
    /// Optional user-entered average share cost for covered-call comparison only.
    /// It is not substituted for the current price or written to the ledger.
    public var coveredCallCostPerShare = ""
    public var underlyingBid = ""
    public var underlyingAsk = ""
    public var underlyingQuotedAt = ""
    public var underlyingReceivedAt = ""
    public var shortLeg = OptionLabLegDraft()
    public var longLeg = OptionLabLegDraft()
    public var lambda = "0.25"
    public var openingFeePerContract = "0.65"
    public var ticketFee = "0"
    public var terminalFeeTotal = "0"
    public var cashBeforeTrade = ""
    public var committedCash = ""
    public var availableShares = ""
    public var committedShares = ""
    public var capitalReference = ""
    public var scenarioPrices = ""
    public var pricing = OptionLabPricingDraft()
    public var scenario = OptionLabScenarioDraft()
    public var risk = OptionLabRiskDraft()
    public private(set) var chainEvidence: OptionChainSelectionEvidence?
    public private(set) var ledgerBasis: OptionLabLedgerBasis?
    private var originalAsOf: Date?
    private var originalSettlementAt: Date?
    private var originalUnderlyingQuotedAt: Date?
    private var originalUnderlyingReceivedAt: Date?
    private var originalContractInput: OptionLabInput?
    public init() {}
    public var hasLongLeg: Bool { strategy == .putCreditSpread || strategy == .callCreditSpread }
    public var right: OptionLabRight { strategy == .coveredCall || strategy == .callCreditSpread ? .call : .put }

    public init(input: OptionLabInput) {
        chainEvidence = input.chainEvidence
        usesEnteredPrices = input.usesEnteredPrices
        strategy = input.strategy
        origin = input.underlying.source.origin == .synthetic || input.shortLeg.source.origin == .synthetic || input.longLeg?.source.origin == .synthetic
            || input.expiry.source.origin == .synthetic || input.capital?.origin == .synthetic
            || input.pricing?.source.origin == .synthetic || input.scenario?.source.origin == .synthetic || input.risk?.containsSyntheticInput == true ? .synthetic : .manual
        usesContractParametersOnly = input.isContractOnly && origin == .manual && input.chainEvidence == nil
        originalContractInput = usesContractParametersOnly ? input : nil
        originalAsOf = input.asOf; originalSettlementAt = input.expiry.settlementAt
        originalUnderlyingQuotedAt = input.underlying.quotedAt; originalUnderlyingReceivedAt = input.underlying.receivedAt
        symbol = input.underlying.symbol; asset = input.underlying.asset; asOf = optionDraftTimestamp(input.asOf)
        expirationDate = input.expiry.date.iso8601; settlementAt = optionDraftTimestamp(input.expiry.settlementAt)
        sourceReference = input.underlying.source.reference; expiryReference = input.expiry.source.reference
        underlyingPrice = input.underlying.enteredPrice?.decimalString ?? ""
        coveredCallCostPerShare = input.coveredCallCostPerShare?.decimalString ?? ""
        underlyingBid = input.underlying.bid?.decimalString ?? ""; underlyingAsk = input.underlying.ask?.decimalString ?? ""
        underlyingQuotedAt = optionDraftTimestamp(input.underlying.quotedAt); underlyingReceivedAt = optionDraftTimestamp(input.underlying.receivedAt)
        shortLeg = .init(input.shortLeg); longLeg = input.longLeg.map(OptionLabLegDraft.init) ?? .init()
        lambda = input.policy.lambda.decimalString; openingFeePerContract = input.policy.openingFeePerContract.decimalString
        ticketFee = input.policy.ticketFee.decimalString; terminalFeeTotal = input.policy.terminalFeeTotal.decimalString
        cashBeforeTrade = input.capital?.cashBeforeTrade.decimalString ?? ""; committedCash = input.capital?.committedCash.decimalString ?? ""
        availableShares = input.capital?.availableShares.decimalString ?? ""; committedShares = input.capital?.committedShares.decimalString ?? ""
        // A copied ledger input is a new explicit manual assumption until a fresh
        // ledger basis is selected; a reference string alone is not that basis.
        capitalReference = input.capital?.origin == .ledger ? "" : input.capital?.reference ?? ""
        scenarioPrices = input.scenarioPrices.map(\.decimalString).joined(separator: "\n")
        pricing = input.pricing.map(OptionLabPricingDraft.init) ?? .init()
        scenario = input.scenario.map(OptionLabScenarioDraft.init) ?? .init()
        risk = input.risk.map { .init($0, shortID: input.shortLeg.contractID, longID: input.longLeg?.contractID) } ?? .init()
    }
    public static func synthetic(strategy: OptionLabStrategy) throws -> Self { try .init(input: OptionLabDemo.input(strategy: strategy)) }
    /// Explicit example values only; this method cannot populate a manual draft.
    public mutating func useSyntheticPricingAssumptions() throws {
        guard origin == .synthetic else { throw OptionLabDraftError.missingField }
        pricing.enabled = true; pricing.rate = "0.05"; pricing.dividendYield = "0.01"; pricing.volatility = "0.25"
        pricing.sourceReference = "SYNTHETIC-OPTION-PRICING; r=5%, continuous q=1%, theoretical sigma=25%; not market data"
    }
    /// A single explicit example action fills all optional research assumptions.
    /// The operation is atomic for the draft and cannot relabel manual input.
    public mutating func useSyntheticRiskScenarioAssumptions() throws {
        guard origin == .synthetic else { throw OptionLabDraftError.missingField }
        var replacement = self
        try replacement.useSyntheticPricingAssumptions()
        replacement.risk.enabled = false; replacement.scenario.enabled = false
        let base = try replacement.build(createdAt: replacement.evaluationDate())
        let assumptions = try OptionLabRiskDemo.input(for: base)
        replacement.risk = .init(assumptions, shortID: base.shortLeg.contractID, longID: base.longLeg?.contractID)
        try replacement.useSyntheticScenarioAssumptions()
        self = replacement
    }
    public mutating func useSyntheticScenarioAssumptions() throws {
        guard origin == .synthetic else { throw OptionLabDraftError.missingField }
        scenario.enabled = true; scenario.spotShocks = "-0.1, 0, 0.1"; scenario.volatilityPointShocks = "-10, 0, 10"
        scenario.sourceReference = "SYNTHETIC-OPTION-SCENARIO; instantaneous spot and absolute IV-point shocks; not a forecast"
    }
    public mutating func useLedgerBasis(_ basis: OptionLabLedgerBasis) throws {
        guard let capital = basis.capital, basis.underlying.symbol == symbol, basis.asOf == (try evaluationDate()),
              (basis.underlying.kind == .stock) == (asset == .stock) else { throw OptionLabDraftError.incompatibleLedgerBasis }
        ledgerBasis = basis
        cashBeforeTrade = capital.cashBeforeTrade.decimalString; committedCash = capital.committedCash.decimalString
        availableShares = capital.availableShares.decimalString; committedShares = capital.committedShares.decimalString
        capitalReference = capital.reference
    }
    public mutating func useManualCapital() {
        ledgerBasis = nil; capitalReference = ""
    }
    /// Convenience for a user-confirmed MANUAL snapshot only. This does not
    /// establish actual market timestamps, exchange identity, tick or admission.
    public var canUseManualQuoteAssistance: Bool { origin == .manual && chainEvidence == nil }
    public mutating func applyManualQuoteAssistance(quotedAt: Date, settlementAt: Date,
                                                    quoteReference: String, expiryReference: String) throws {
        guard canUseManualQuoteAssistance else { throw OptionLabDraftError.missingField }
        let quoteSource = quoteReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let expirySource = expiryReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quoteSource.isEmpty, !expirySource.isEmpty, quoteSource.utf8.count <= 4096,
              expirySource.utf8.count <= 4096 else { throw OptionLabDraftError.missingField }
        guard quotedAt.timeIntervalSince1970.isFinite, settlementAt.timeIntervalSince1970.isFinite,
              settlementAt > quotedAt, let zone = TimeZone(identifier: "America/New_York") else { throw OptionLabDraftError.invalidDate }
        if let ledgerBasis, ledgerBasis.asOf != quotedAt { throw OptionLabDraftError.incompatibleLedgerBasis }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day], from: settlementAt)
        guard let year = components.year, let month = components.month, let day = components.day else { throw OptionLabDraftError.invalidDate }
        var replacement = self
        replacement.asOf = optionDraftTimestamp(quotedAt); replacement.originalAsOf = quotedAt
        replacement.expirationDate = MarketDate(year: year, month: month, day: day).iso8601
        replacement.settlementAt = optionDraftTimestamp(settlementAt); replacement.originalSettlementAt = settlementAt
        replacement.sourceReference = quoteSource; replacement.expiryReference = expirySource
        replacement.underlyingQuotedAt = optionDraftTimestamp(quotedAt); replacement.originalUnderlyingQuotedAt = quotedAt
        replacement.underlyingReceivedAt = optionDraftTimestamp(quotedAt); replacement.originalUnderlyingReceivedAt = quotedAt
        replacement.shortLeg.applyManualQuoteTime(quotedAt, reference: quoteSource)
        if replacement.hasLongLeg { replacement.longLeg.applyManualQuoteTime(quotedAt, reference: quoteSource) }
        self = replacement
    }
    /// Existing entered prices are drawing samples, never predicted prices or
    /// new probabilistic assumptions. Adoption is an explicit UI action.
    public func chartPricesFromEnteredInputs() throws -> [Money] {
        let strike = try Money(shortLeg.strike)
        guard strike.amount > 0 else { throw OptionLabDraftError.invalidNumber }
        var values = [strike]
        if usesEnteredPrices {
            let current = try Money(underlyingPrice)
            guard current.amount > 0 else { throw OptionLabDraftError.invalidNumber }
            values.append(current)
        } else {
            let bid = try Money(underlyingBid), ask = try Money(underlyingAsk)
            guard bid.amount > 0, ask >= bid else { throw OptionLabDraftError.invalidNumber }
            values.append(contentsOf: [bid, ask])
        }
        if hasLongLeg {
            let longStrike = try Money(longLeg.strike)
            guard longStrike.amount > 0 else { throw OptionLabDraftError.invalidNumber }
            values.append(longStrike)
        }
        return Dictionary(grouping: values, by: \.decimalString).compactMap { $0.value.first }.sorted()
    }
    public mutating func useChartPricesFromEnteredInputs() throws {
        let values = try chartPricesFromEnteredInputs()
        scenarioPrices = values.map(\.decimalString).joined(separator: "\n")
    }
    /// The page captures one calculation instant and passes it to both this
    /// builder and its checklist. Frozen report replay uses the saved input,
    /// never this draft or the current clock.
    public func buildForCalculation(createdAt: Date = Date()) throws -> OptionLabInput {
        guard usesContractParametersOnly else { return try build(createdAt: createdAt) }
        let costPerShare = try parsedCoveredCallCost()
        guard contractEvidenceIssues().isEmpty else { throw OptionLabDraftError.requiresFullEvidence }
        guard createdAt.timeIntervalSince1970.isFinite else { throw OptionLabDraftError.invalidDate }
        let (expiry, settlement) = try contractParametersExpiry()
        guard settlement > createdAt else { throw OptionLabDraftError.invalidDate }
        guard calculationChecklist(createdAt: createdAt).isEmpty else { throw OptionLabDraftError.invalidNumber }
        let source = OptionLabSource(origin: .manual,
            reference: "MANUAL-CONTRACT-PARAMETERS; user-entered prices; timestamps are local calculation/entry metadata, not market quote times",
            enteredAt: createdAt)
        let current = try Money(underlyingPrice)
        guard let quantity = Int(shortLeg.quantity) else { throw OptionLabDraftError.invalidNumber }
        func leg(_ draft: OptionLabLegDraft) throws -> OptionLabLeg {
            guard let multiplier = Int(draft.multiplier) else { throw OptionLabDraftError.invalidNumber }
            let strike = try Money(draft.strike)
            // This is a deterministic local identity, never an OCC/provider ID.
            let identity = ["MANUAL-PARAMETERS", symbol, asset.rawValue, right.rawValue,
                expiry.iso8601, strike.decimalString, String(multiplier)].joined(separator: ":")
            return try .init(contractID: identity, symbol: symbol, right: right, strike: strike,
                multiplier: multiplier, quantity: quantity, expirationDate: expiry,
                quotedAt: createdAt, receivedAt: createdAt, source: source, enteredPrice: Money(draft.enteredPrice))
        }
        let prices = try optionDraftBlank(scenarioPrices) ? chartPricesFromEnteredInputs() : contractChartPrices()
        return try .init(createdAt: createdAt, asOf: createdAt, strategy: strategy,
            shortLeg: leg(shortLeg), longLeg: hasLongLeg ? leg(longLeg) : nil,
            underlying: .init(symbol: symbol, asset: asset, quotedAt: createdAt, receivedAt: createdAt,
                source: source, enteredPrice: current), capital: nil,
            policy: .init(lambda: Money(lambda), openingFeePerContract: Money(openingFeePerContract),
                ticketFee: Money(ticketFee), terminalFeeTotal: Money(terminalFeeTotal)),
            expiry: .init(date: expiry, settlementAt: settlement,
                source: .init(origin: .manual,
                    reference: "MANUAL-CONTRACT-PARAMETERS-EXPIRY; user-selected expiration instant; not exchange calendar verification",
                    enteredAt: createdAt)), scenarioPrices: prices, entryMode: .contractParameters,
            coveredCallCostPerShare: costPerShare)
    }

    /// Only fields used by the selected calculation mode are required. A simple
    /// calculation does not acquire cash, holdings or quote evidence from blanks.
    public func calculationChecklist(createdAt: Date = Date()) -> OptionDailyChecklist {
        guard usesContractParametersOnly else { return dailyInputChecklist() }
        var grouped: [OptionDailySection: [OptionDailyIssue]] = [:]
        func issue(_ section: OptionDailySection, _ field: String, _ message: String) {
            grouped[section, default: []].append(.init(id: section.rawValue + "." + field, message: message))
        }
        for (section, field, message) in contractEvidenceIssues() { issue(section, field, message) }
        if let message = coveredCallCostIssue { issue(.underlying, "coveredCallCost", message) }
        if symbol.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}$"#, options: .regularExpression) == nil {
            issue(.underlying, "symbol", "填写有效的大写股票或 ETF 代码。")
        }
        if (try? Money(underlyingPrice).amount).map({ $0 > 0 }) != true {
            issue(.underlying, "prices", "标的当前价格必须明确填写且大于零。")
        }
        if Int(shortLeg.quantity).map({ $0 > 0 && $0 <= Int.max / 200 }) != true {
            issue(.shortLeg, "quantity", "策略张数必须是有效正整数；保护腿使用相同张数。")
        }
        let legs: [(OptionDailySection, String, OptionLabLegDraft)] = [(.shortLeg, "卖出合约", shortLeg)]
            + (hasLongLeg ? [(.longLeg, "保护合约", longLeg)] : [])
        for (section, name, leg) in legs {
            if (try? Money(leg.strike).amount).map({ $0 > 0 }) != true {
                issue(section, "strike", name + "行权价必须明确填写且大于零。")
            }
            if (try? Money(leg.enteredPrice).amount).map({ $0 >= 0 }) != true {
                issue(section, "premium", name + "每股成交权利金必须明确填写且不能为负；不会用另一腿价格代填。")
            }
            if Int(leg.multiplier) != 100 {
                issue(section, "multiplier", name + "当前仅支持标准每张 100 股的合约。")
            }
        }
        if hasLongLeg, let shortStrike = try? Money(shortLeg.strike), let longStrike = try? Money(longLeg.strike),
           (strategy == .putCreditSpread ? longStrike >= shortStrike : longStrike <= shortStrike) {
            issue(.longLeg, "strikeOrder", strategy == .putCreditSpread
                ? "看跌价差的保护腿行权价必须低于卖出腿。" : "看涨价差的保护腿行权价必须高于卖出腿。")
        }
        if let (_, settlement) = try? contractParametersExpiry(), createdAt.timeIntervalSince1970.isFinite {
            if settlement <= createdAt { issue(.timing, "expiry", "到期时刻必须晚于本次计算时刻。") }
        } else {
            issue(.timing, "expiry", "请明确填写或选择到期时刻；已有到期日须与该时刻的纽约日期一致。")
        }
        if (try? Money(lambda).amount).map({ $0 >= 0 && $0 <= Decimal(string: "0.5")! }) != true
            || ![openingFeePerContract, ticketFee, terminalFeeTotal].allSatisfy({ (try? Money($0).amount).map({ $0 >= 0 }) == true }) {
            issue(.costs, "fees", "费用须明确填写非负数值，滑点系数须在 0 至 0.5 之间；空白不会当成免费。")
        }
        if !optionDraftBlank(scenarioPrices), (try? contractChartPrices()) == nil {
            issue(.chart, "samples", "已填写的损益图采样须为 1 至 401 个互不重复的非负价格；不会忽略无效采样。")
        }
        return .init(groups: OptionDailySection.allCases.compactMap { section in
            guard let issues = grouped[section], !issues.isEmpty else { return nil }
            return .init(section: section, issues: issues)
        })
    }

    private func contractParametersExpiry() throws -> (MarketDate, Date) {
        let settlement = try optionDraftDate(settlementAt, original: originalSettlementAt)
        guard settlement.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: "America/New_York") else {
            throw OptionLabDraftError.invalidDate
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day], from: settlement)
        guard let year = components.year, let month = components.month, let day = components.day else { throw OptionLabDraftError.invalidDate }
        let date = MarketDate(year: year, month: month, day: day)
        if !optionDraftBlank(expirationDate), try MarketDate(iso8601: expirationDate) != date { throw OptionLabDraftError.invalidDate }
        return (date, settlement)
    }

    private var coveredCallCostIssue: String? {
        guard !optionDraftBlank(coveredCallCostPerShare) else { return nil }
        guard strategy == .coveredCall else { return "持股成本仅用于备兑 Call，请清空该选填值后计算其他策略。" }
        let text = coveredCallCostPerShare.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cost = try? Money(text), cost.amount >= 0 else {
            return "持股成本须为非负的每股金额；可留空，留空不会当成零或当前股价。"
        }
        return nil
    }

    private func parsedCoveredCallCost() throws -> Money? {
        guard coveredCallCostIssue == nil else { throw OptionLabDraftError.invalidNumber }
        guard !optionDraftBlank(coveredCallCostPerShare) else { return nil }
        return try Money(coveredCallCostPerShare.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func contractChartPrices() throws -> [Money] {
        let values = try scenarioPrices.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { try Money($0) }
        guard (1...401).contains(values.count), values.allSatisfy({ $0.amount >= 0 }),
              Set(values.map(\.decimalString)).count == values.count else { throw OptionLabDraftError.invalidNumber }
        return values
    }

    private func contractEvidenceIssues() -> [(OptionDailySection, String, String)] {
        var issues: [(OptionDailySection, String, String)] = []
        if origin != .manual || chainEvidence != nil || !usesEnteredPrices {
            issues.append((.underlying, "evidenceMode", "合成、采集或双边报价输入须使用完整证据模式，不能转换为普通手动录入。"))
        }
        if ledgerBasis != nil || [cashBeforeTrade, committedCash, availableShares, committedShares, capitalReference].contains(where: { !optionDraftBlank($0) }) {
            issues.append((.capital, "evidenceMode", "已填写账户或资金信息，请切换完整证据模式；简单计算保留资金未知。"))
        }
        if pricing.enabled { issues.append((.pricing, "evidenceMode", "已启用定价模型，请切换完整证据模式以保留这些假设。")) }
        if risk.enabled { issues.append((.risk, "evidenceMode", "已启用风险研究，请切换完整证据模式以保留这些资料。")) }
        if scenario.enabled { issues.append((.scenario, "evidenceMode", "已启用瞬时情景，请切换完整证据模式以保留这些输入。")) }
        if !optionDraftBlank(underlyingBid) || !optionDraftBlank(underlyingAsk) {
            issues.append((.underlying, "quoteMode", "已填写标的 Bid／Ask，请切换完整证据模式以保留报价。"))
        }
        // Auto-generated local metadata from a copied simple report can be
        // regenerated. Any manually supplied or modified evidence must survive
        // through the full builder instead of being silently discarded.
        func explicit(_ text: String, prior: String?) -> Bool { !optionDraftBlank(text) && text != prior }
        if explicit(asOf, prior: originalContractInput.map { optionDraftTimestamp($0.asOf) })
            || explicit(sourceReference, prior: originalContractInput?.underlying.source.reference)
            || explicit(expiryReference, prior: originalContractInput?.expiry.source.reference)
            || explicit(underlyingQuotedAt, prior: originalContractInput.map { optionDraftTimestamp($0.underlying.quotedAt) })
            || explicit(underlyingReceivedAt, prior: originalContractInput.map { optionDraftTimestamp($0.underlying.receivedAt) }) {
            issues.append((.timing, "quoteMode", "已填写评估、报价时刻或来源说明，请切换完整证据模式以保留证据。"))
        }
        let legs: [(OptionDailySection, OptionLabLegDraft, OptionLabLeg?)] = [(.shortLeg, shortLeg, originalContractInput?.shortLeg)]
            + (hasLongLeg ? [(.longLeg, longLeg, originalContractInput?.longLeg)] : [])
        for (section, leg, prior) in legs {
            if [leg.bid, leg.ask, leg.bidSize, leg.askSize, leg.tick].contains(where: { !optionDraftBlank($0) })
                || explicit(leg.contractID, prior: prior?.contractID)
                || explicit(leg.sourceReference, prior: prior?.source.reference)
                || explicit(leg.quotedAt, prior: prior.map { optionDraftTimestamp($0.quotedAt) })
                || explicit(leg.receivedAt, prior: prior.map { optionDraftTimestamp($0.receivedAt) }) {
                issues.append((section, "quoteMode", "已填写合约标识或高级报价资料，请切换完整证据模式以保留这些输入。"))
            }
        }
        return issues
    }
    /// Switching a copied basic calculation to the full path must not promote
    /// local record times into asserted quotation/expiry evidence by accident.
    private var needsFullEvidenceConfirmation: Bool {
        guard let original = originalContractInput else { return false }
        return sourceReference == original.underlying.source.reference
            || expiryReference == original.expiry.source.reference
            || shortLeg.sourceReference == original.shortLeg.source.reference
            || (hasLongLeg && original.longLeg.map { longLeg.sourceReference == $0.source.reference } == true)
    }
    /// Evaluate once on an explicit preparation action or calculation failure,
    /// then let the page render that value. These are editable-input hints, not a
    /// substitute for the unchanged builder, quality checks or pricing engine.
    public func dailyInputChecklist() -> OptionDailyChecklist {
        func blank(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func number(_ value: String) -> Bool { (try? Money(value)) != nil }
        func axis(_ value: String) -> Bool {
            let rows = value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return !rows.isEmpty && rows.allSatisfy { !$0.isEmpty && number($0) }
        }
        var grouped: [OptionDailySection: [OptionDailyIssue]] = [:]
        func issue(_ section: OptionDailySection, _ field: String, _ message: String) {
            grouped[section, default: []].append(.init(id: section.rawValue + "." + field, message: message))
        }
        if let message = coveredCallCostIssue { issue(.underlying, "coveredCallCost", message) }
        if blank(symbol) { issue(.underlying, "symbol", "填写标的代码。") }
        if usesEnteredPrices {
            if !number(underlyingPrice) { issue(.underlying, "prices", "填写标的当前价格。") }
            if blank(underlyingBid) != blank(underlyingAsk) || (!blank(underlyingBid) && (!number(underlyingBid) || !number(underlyingAsk))) {
                issue(.underlying, "quote", "高级报价需要成对填写有效 Bid／Ask，或同时留空。")
            }
            if chainEvidence != nil { issue(.underlying, "chain", "采集绑定保留双边报价；不能直接改成手动成交价。") }
        } else if !number(underlyingBid) || !number(underlyingAsk) {
            issue(.underlying, "prices", "补齐标的买卖价；不使用单边价格猜填。")
        }
        let legs: [(OptionDailySection, String, OptionLabLegDraft)] = [(.shortLeg, "卖出合约", shortLeg)]
            + (hasLongLeg ? [(.longLeg, "保护合约", longLeg)] : [])
        for (section, name, leg) in legs {
            let validPrice = usesEnteredPrices ? number(leg.enteredPrice) : number(leg.bid) && number(leg.ask)
            if !number(leg.strike) || Int(leg.quantity) == nil || !validPrice {
                issue(section, "trade", name + (usesEnteredPrices ? "行权价、张数与成交价未填完整或格式无效。" : "行权价、张数与买卖价未填完整或格式无效。"))
            }
            if Int(leg.multiplier) == nil { issue(section, "multiplier", name + "合约乘数必须明确填写，不能从报价推断。") }
            if usesEnteredPrices {
                if blank(leg.bid) != blank(leg.ask) || (!blank(leg.bid) && (!number(leg.bid) || !number(leg.ask))) {
                    issue(section, "quote", name + "高级 Bid／Ask 需要成对填写，或同时留空。")
                }
                if blank(leg.bidSize) != blank(leg.askSize) || (!blank(leg.bidSize) && (Int(leg.bidSize) == nil || Int(leg.askSize) == nil)) {
                    issue(section, "sizes", name + "双边深度需要成对填写整数，或同时留空。")
                }
                if !blank(leg.tick) && !number(leg.tick) { issue(section, "tick", name + "选填的 tick 格式无效。") }
            } else {
                if Int(leg.bidSize) == nil || Int(leg.askSize) == nil { issue(section, "sizes", name + "双边报价张数需要整数；未知值不会补成零。") }
                if !number(leg.tick) { issue(section, "tick", name + "最小报价单位 tick 未知或格式无效，不能猜填。") }
            }
            if blank(leg.contractID) || (try? optionDraftDate(leg.quotedAt, original: nil)) == nil || (try? optionDraftDate(leg.receivedAt, original: nil)) == nil {
                issue(.timing, section.rawValue, name + "合约标识与报价时间未完整；手工输入可显式采用共同时间。")
            }
        }
        if hasLongLeg, let shortQuantity = Int(shortLeg.quantity), let longQuantity = Int(longLeg.quantity), shortQuantity != longQuantity {
            issue(.longLeg, "quantityMatch", "保护合约与卖出合约张数不同；可手动修改，或明确选择同步保护腿张数。")
        }
        if (try? evaluationDate()) == nil || (try? MarketDate(iso8601: expirationDate)) == nil
            || (try? optionDraftDate(settlementAt, original: originalSettlementAt)) == nil
            || (try? optionDraftDate(underlyingQuotedAt, original: originalUnderlyingQuotedAt)) == nil
            || (try? optionDraftDate(underlyingReceivedAt, original: originalUnderlyingReceivedAt)) == nil
            || blank(sourceReference) || blank(expiryReference) {
            issue(.timing, "common", "评估／到期时间与依据未完整；只有明确确认后才会采用手工共同时间。")
        }
        if needsFullEvidenceConfirmation {
            issue(.timing, "recordedMetadata", "复制的简单计算只保存录入时刻；请明确填写或确认完整报价与到期来源，才能用于完整证据模式。")
        }
        if ![cashBeforeTrade, committedCash, availableShares, committedShares].allSatisfy(number) || blank(capitalReference) {
            issue(.capital, "balances", "补齐现金、已承诺额度、持股与资金说明；零也要明确填写。")
        }
        if ![lambda, openingFeePerContract, ticketFee, terminalFeeTotal].allSatisfy(number) {
            issue(.costs, "fees", "费用与滑点需要明确数值；不会把空白当成免费。")
        }
        let samples = scenarioPrices.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if samples.isEmpty || !samples.allSatisfy(number) {
            issue(.chart, "samples", "填写有效损益图采样点，或明确采用当前已填价格；采样不是预测。")
        }
        if pricing.enabled && (![pricing.rate, pricing.dividendYield, pricing.volatility].allSatisfy(number) || blank(pricing.sourceReference)) {
            issue(.pricing, "assumptions", "补齐模型利率、股息率、理论波动率与假设说明；未知值不会补成零。")
        }
        if risk.enabled && blank(risk.sourceReference) { issue(.risk, "source", "已启用风险研究，请填写风险资料来源。") }
        if risk.enabled && risk.earnings.enabled && (blank(risk.earnings.eventVersion) || blank(risk.earnings.sourceReference)
            || (try? optionDraftDate(risk.earnings.announcedAt, original: nil)) == nil
            || (try? MarketDate(iso8601: risk.earnings.eventDate)) == nil) {
            issue(.risk, "earnings", "已启用财报事件，请补齐事件版本、来源、公布时刻与事件日期。")
        }
        if risk.enabled && risk.dividend.enabled && (blank(risk.dividend.eventVersion) || blank(risk.dividend.sourceReference)
            || (try? optionDraftDate(risk.dividend.announcedAt, original: nil)) == nil
            || (try? MarketDate(iso8601: risk.dividend.exDate)) == nil) {
            issue(.risk, "dividend", "已启用除息事件，请补齐事件版本、来源、公布时刻与除息日期。")
        }
        if scenario.enabled && (!axis(scenario.spotShocks) || !axis(scenario.volatilityPointShocks) || blank(scenario.sourceReference)) {
            issue(.scenario, "axes", "补齐瞬时价格冲击、IV 百分点冲击与来源；不会自动启用或增加情景。")
        }
        return .init(groups: OptionDailySection.allCases.compactMap { section in
            guard let issues = grouped[section], !issues.isEmpty else { return nil }
            return .init(section: section, issues: issues)
        })
    }
    /// Compatibility for existing callers. New pages cache dailyInputChecklist().
    public var dailyInputIssues: [String] { dailyInputChecklist().groups.flatMap { $0.issues.map(\.message) } }
    public func evaluationDate() throws -> Date { try optionDraftDate(asOf, original: originalAsOf) }
    public func build(createdAt: Date = Date()) throws -> OptionLabInput {
        let costPerShare = try parsedCoveredCallCost()
        guard !needsFullEvidenceConfirmation else { throw OptionLabDraftError.requiresFullEvidence }
        guard !usesEnteredPrices || chainEvidence == nil else { throw OptionLabDraftError.missingField }
        let evaluation = try evaluationDate(), expiry = try MarketDate(iso8601: expirationDate)
        let source = OptionLabSource(origin: origin, reference: sourceReference, enteredAt: createdAt)
        let bid = try optionDraftOptionalMoney(underlyingBid), ask = try optionDraftOptionalMoney(underlyingAsk)
        guard (bid == nil) == (ask == nil), usesEnteredPrices || (bid != nil && ask != nil) else { throw OptionLabDraftError.missingField }
        let underlying = try OptionLabUnderlying(symbol: symbol, asset: asset, bid: bid, ask: ask,
            quotedAt: optionDraftDate(underlyingQuotedAt, original: originalUnderlyingQuotedAt), receivedAt: optionDraftDate(underlyingReceivedAt, original: originalUnderlyingReceivedAt), source: source,
            enteredPrice: usesEnteredPrices ? Money(underlyingPrice) : nil)
        let capital: OptionLabCapital
        if let basis = ledgerBasis {
            guard basis.underlying.symbol == symbol, basis.asOf == evaluation, let value = basis.capital,
                  (basis.underlying.kind == .stock) == (asset == .stock),
                  value.cashBeforeTrade.decimalString == cashBeforeTrade, value.committedCash.decimalString == committedCash,
                  value.availableShares.decimalString == availableShares, value.committedShares.decimalString == committedShares,
                  value.reference == capitalReference else { throw OptionLabDraftError.incompatibleLedgerBasis }
            capital = value
        } else {
            guard !capitalReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OptionLabDraftError.missingField }
            capital = try .init(origin: origin == .synthetic ? .synthetic : .manual, reference: capitalReference, asOf: evaluation,
                cashBeforeTrade: Money(cashBeforeTrade), committedCash: Money(committedCash),
                availableShares: Money(availableShares), committedShares: Money(committedShares))
        }
        let prices = try scenarioPrices.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { try Money($0) }
        let short = try shortLeg.build(symbol: symbol, right: right, expiry: expiry, source: source, usesEnteredPrices: usesEnteredPrices)
        let long = try hasLongLeg ? longLeg.build(symbol: symbol, right: right, expiry: expiry, source: source, usesEnteredPrices: usesEnteredPrices) : nil
        return try .init(createdAt: createdAt, asOf: evaluation, strategy: strategy,
            shortLeg: short, longLeg: long,
            underlying: underlying, capital: capital,
            policy: .init(lambda: Money(lambda), openingFeePerContract: Money(openingFeePerContract), ticketFee: Money(ticketFee), terminalFeeTotal: Money(terminalFeeTotal)),
            expiry: .init(date: expiry, settlementAt: optionDraftDate(settlementAt, original: originalSettlementAt),
                source: .init(origin: origin, reference: expiryReference, enteredAt: createdAt)), scenarioPrices: prices,
            pricing: pricing.build(origin: origin, enteredAt: createdAt),
            risk: risk.build(short: short, long: long, origin: origin, enteredAt: createdAt),
            scenario: scenario.build(origin: origin, enteredAt: createdAt), chainEvidence: chainEvidence,
            coveredCallCostPerShare: costPerShare)
    }
}
private func optionDraftBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
private func optionDraftOptionalMoney(_ text: String) throws -> Money? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return try Money(text)
}

private func optionDraftOptionalInt(_ text: String) throws -> Int? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard let value = Int(text) else { throw OptionLabDraftError.invalidNumber }
    return value
}
private func optionDraftTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func optionDraftDate(_ text: String, original: Date?) throws -> Date {
    // Formatting is for editing only. Copying an unchanged timestamp preserves
    // the exact stored Date instead of silently rounding to display milliseconds.
    if let original, text == optionDraftTimestamp(original) { return original }
    return try LedgerCSV.timestamp(text)
}
