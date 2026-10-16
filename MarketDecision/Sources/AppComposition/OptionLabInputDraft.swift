import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine
import Persistence

public enum OptionLabDraftError: Error, Equatable, Sendable {
    case invalidNumber, missingField, invalidDate, incompatibleLedgerBasis
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

public struct OptionLabLegDraft: Equatable, Sendable {
    public var contractID = ""
    public var strike = ""
    public var multiplier = "100"
    public var quantity = "1"
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
        bid = leg.bid.decimalString; ask = leg.ask.decimalString
        bidSize = String(leg.bidSize); askSize = String(leg.askSize); tick = leg.tick?.decimalString ?? ""
        quotedAt = optionDraftTimestamp(leg.quotedAt); receivedAt = optionDraftTimestamp(leg.receivedAt)
        originalQuotedAt = leg.quotedAt; originalReceivedAt = leg.receivedAt; sourceReference = leg.source.reference
    }
    func build(symbol: String, right: OptionLabRight, expiry: MarketDate, source: OptionLabSource) throws -> OptionLabLeg {
        guard let multiplier = Int(multiplier), let quantity = Int(quantity), let bidSize = Int(bidSize), let askSize = Int(askSize) else {
            throw OptionLabDraftError.invalidNumber
        }
        return try .init(contractID: contractID, symbol: symbol, right: right, strike: Money(strike), multiplier: multiplier,
            quantity: quantity, expirationDate: expiry, bid: Money(bid), ask: Money(ask), bidSize: bidSize, askSize: askSize,
            tick: tick.isEmpty ? nil : Money(tick), quotedAt: optionDraftDate(quotedAt, original: originalQuotedAt), receivedAt: optionDraftDate(receivedAt, original: originalReceivedAt),
            source: .init(origin: source.origin, reference: sourceReference.isEmpty ? source.reference : sourceReference, enteredAt: source.enteredAt))
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
    public private(set) var ledgerBasis: OptionLabLedgerBasis?
    private var originalAsOf: Date?
    private var originalSettlementAt: Date?
    private var originalUnderlyingQuotedAt: Date?
    private var originalUnderlyingReceivedAt: Date?
    public init() {}
    public var hasLongLeg: Bool { strategy == .putCreditSpread || strategy == .callCreditSpread }
    public var right: OptionLabRight { strategy == .coveredCall || strategy == .callCreditSpread ? .call : .put }

    public init(input: OptionLabInput) {
        strategy = input.strategy
        origin = input.underlying.source.origin == .synthetic || input.shortLeg.source.origin == .synthetic || input.longLeg?.source.origin == .synthetic
            || input.expiry.source.origin == .synthetic || input.capital.origin == .synthetic
            || input.pricing?.source.origin == .synthetic ? .synthetic : .manual
        originalAsOf = input.asOf; originalSettlementAt = input.expiry.settlementAt
        originalUnderlyingQuotedAt = input.underlying.quotedAt; originalUnderlyingReceivedAt = input.underlying.receivedAt
        symbol = input.underlying.symbol; asset = input.underlying.asset; asOf = optionDraftTimestamp(input.asOf)
        expirationDate = input.expiry.date.iso8601; settlementAt = optionDraftTimestamp(input.expiry.settlementAt)
        sourceReference = input.underlying.source.reference; expiryReference = input.expiry.source.reference
        underlyingBid = input.underlying.bid.decimalString; underlyingAsk = input.underlying.ask.decimalString
        underlyingQuotedAt = optionDraftTimestamp(input.underlying.quotedAt); underlyingReceivedAt = optionDraftTimestamp(input.underlying.receivedAt)
        shortLeg = .init(input.shortLeg); longLeg = input.longLeg.map(OptionLabLegDraft.init) ?? .init()
        lambda = input.policy.lambda.decimalString; openingFeePerContract = input.policy.openingFeePerContract.decimalString
        ticketFee = input.policy.ticketFee.decimalString; terminalFeeTotal = input.policy.terminalFeeTotal.decimalString
        cashBeforeTrade = input.capital.cashBeforeTrade.decimalString; committedCash = input.capital.committedCash.decimalString
        availableShares = input.capital.availableShares.decimalString; committedShares = input.capital.committedShares.decimalString
        // A copied ledger input is a new explicit manual assumption until a fresh
        // ledger basis is selected; a reference string alone is not that basis.
        capitalReference = input.capital.origin == .ledger ? "" : input.capital.reference
        scenarioPrices = input.scenarioPrices.map(\.decimalString).joined(separator: "\n")
        pricing = input.pricing.map(OptionLabPricingDraft.init) ?? .init()
    }
    public static func synthetic(strategy: OptionLabStrategy) throws -> Self { try .init(input: OptionLabDemo.input(strategy: strategy)) }
    /// Explicit example values only; this method cannot populate a manual draft.
    public mutating func useSyntheticPricingAssumptions() throws {
        guard origin == .synthetic else { throw OptionLabDraftError.missingField }
        pricing.enabled = true; pricing.rate = "0.05"; pricing.dividendYield = "0.01"; pricing.volatility = "0.25"
        pricing.sourceReference = "SYNTHETIC-OPTION-PRICING; r=5%, continuous q=1%, theoretical sigma=25%; not market data"
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
    public func evaluationDate() throws -> Date { try optionDraftDate(asOf, original: originalAsOf) }
    public func build(createdAt: Date = Date()) throws -> OptionLabInput {
        let evaluation = try evaluationDate(), expiry = try MarketDate(iso8601: expirationDate)
        let source = OptionLabSource(origin: origin, reference: sourceReference, enteredAt: createdAt)
        let underlying = try OptionLabUnderlying(symbol: symbol, asset: asset, bid: Money(underlyingBid), ask: Money(underlyingAsk),
            quotedAt: optionDraftDate(underlyingQuotedAt, original: originalUnderlyingQuotedAt), receivedAt: optionDraftDate(underlyingReceivedAt, original: originalUnderlyingReceivedAt), source: source)
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
        return try .init(createdAt: createdAt, asOf: evaluation, strategy: strategy,
            shortLeg: shortLeg.build(symbol: symbol, right: right, expiry: expiry, source: source),
            longLeg: hasLongLeg ? longLeg.build(symbol: symbol, right: right, expiry: expiry, source: source) : nil,
            underlying: underlying, capital: capital,
            policy: .init(lambda: Money(lambda), openingFeePerContract: Money(openingFeePerContract), ticketFee: Money(ticketFee), terminalFeeTotal: Money(terminalFeeTotal)),
            expiry: .init(date: expiry, settlementAt: optionDraftDate(settlementAt, original: originalSettlementAt),
                source: .init(origin: origin, reference: expiryReference, enteredAt: createdAt)), scenarioPrices: prices,
            pricing: pricing.build(origin: origin, enteredAt: createdAt))
    }
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
