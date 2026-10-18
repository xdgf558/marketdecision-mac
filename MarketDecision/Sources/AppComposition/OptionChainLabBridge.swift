import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

/// No real capture is admitted to the offline laboratory by this candidate bridge.
/// Contract ticks, settlement instants, rates, capital and fees remain explicit
/// assumptions; an OCC-looking symbol is not evidence for any of those values.
public enum OptionChainLabBridge {
    public static func draft(_ capture: OptionChainCapture, strategy: OptionLabStrategy,
                             shortID: String, longID: String?, quantity: Int) throws -> OptionLabInputDraft {
        try OptionChainEvidence.validateForLab(capture)
        guard quantity > 0, let underlying = capture.snapshot.underlying,
              let short = capture.snapshot.contracts.first(where: { $0.recordID == shortID }) else { throw OptionLabDraftError.missingField }
        let spread = strategy == .putCreditSpread || strategy == .callCreditSpread
        let right: OptionChainRight = strategy == .coveredCall || strategy == .callCreditSpread ? .call : .put
        guard short.right == right, short.multiplier == 100, short.expiration > day(capture.createdAt) else { throw OptionLabError.unsupportedContract }
        var long: OptionChainContract?
        if spread {
            guard let longID, longID != shortID, let selected = capture.snapshot.contracts.first(where: { $0.recordID == longID }),
                  selected.right == right, selected.expiration == short.expiration, selected.multiplier == short.multiplier,
                  (right == .put ? selected.strike < short.strike : selected.strike > short.strike)
            else { throw OptionLabError.mismatchedLegs }
            long = selected
        } else if longID != nil { throw OptionLabError.mismatchedLegs }
        let source = OptionLabSource(origin: .synthetic, reference: OptionChainEvidence.reference(capture), enteredAt: capture.createdAt)
        func leg(_ value: OptionChainContract) throws -> OptionLabLegDraft {
            guard let time = value.quote.quoteTime else { throw OptionLabError.invalidTime }
            return .init(.init(contractID: value.recordID, symbol: capture.symbol,
                right: right == .put ? .put : .call, strike: value.strike, multiplier: value.multiplier,
                quantity: quantity, expirationDate: value.expiration, bid: value.quote.bid, ask: value.quote.ask,
                bidSize: value.quote.bidSize, askSize: value.quote.askSize, tick: nil,
                quotedAt: time, receivedAt: value.provenance.receivedAt, source: source))
        }
        // Use the existing draft's exact-date-preserving constructor for the quote
        // fields, then clear missing market/account assumptions. The approved
        // lab fee/slippage defaults remain visible, never attributed to this feed.
        guard let quoteTime = underlying.quoteTime else { throw OptionLabError.invalidTime }
        let placeholder = OptionLabInput(createdAt: capture.createdAt, asOf: capture.createdAt, strategy: strategy,
            shortLeg: try temporaryLeg(short, quantity: quantity, source: source),
            longLeg: try long.map { try temporaryLeg($0, quantity: quantity, source: source) },
            underlying: .init(symbol: capture.symbol, bid: underlying.bid, ask: underlying.ask, quotedAt: quoteTime,
                receivedAt: underlying.provenance.receivedAt, source: source),
            capital: .init(origin: .synthetic, reference: "UNSET", asOf: capture.createdAt,
                cashBeforeTrade: try Money("0"), committedCash: try Money("0"), availableShares: try Money("0"), committedShares: try Money("0")),
            policy: try .defaults(), expiry: .init(date: short.expiration, settlementAt: capture.createdAt, source: source),
            scenarioPrices: [], chainEvidence: .init(capture: capture, shortContractID: shortID, longContractID: longID))
        var result = OptionLabInputDraft(input: placeholder)
        result.shortLeg = try leg(short); result.longLeg = try long.map(leg) ?? .init()
        result.settlementAt = ""; result.expiryReference = ""
        result.cashBeforeTrade = ""; result.committedCash = ""; result.availableShares = ""; result.committedShares = ""
        result.capitalReference = ""; result.scenarioPrices = ""
        result.pricing = .init(); result.risk = .init(); result.scenario = .init()
        return result
    }

    public static func daily(_ capture: OptionChainCapture, rate: Money, dividendYield: Money,
                             settlements: [String: Date], tick: Money, assumptionReference: String,
                             declaredClose: Bool, assumptionsEnteredAt: Date = Date()) throws -> OptionDailyInput {
        try capture.validate()
        guard capture.synthetic, let underlying = capture.snapshot.underlying,
              !capture.snapshot.contracts.isEmpty,
              capture.snapshot.status == .complete || capture.snapshot.status == .partial,
              tick.amount > 0, dividendYield.amount >= 0,
              assumptionsEnteredAt.timeIntervalSince1970.isFinite, assumptionsEnteredAt >= capture.createdAt,
              !assumptionReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw OptionDailyError.invalidInput }
        let source = OptionLabSource(origin: .synthetic, reference: OptionChainEvidence.reference(capture), enteredAt: capture.createdAt)
        let assumptions = OptionLabSource(origin: .synthetic, reference: assumptionReference, enteredAt: assumptionsEnteredAt)
        let session = day(capture.createdAt), quoteID = "chain-underlying:" + capture.id.uuidString
        let expirationKeys = Set(capture.snapshot.contracts.map { $0.expiration.iso8601 })
        guard Set(settlements.keys) == expirationKeys else { throw OptionDailyError.invalidTime }
        let contracts = try capture.snapshot.contracts.map { contract -> OptionDailyContractInput in
            guard let settlement = settlements[contract.expiration.iso8601], day(settlement) == contract.expiration,
                  settlement > capture.createdAt, contract.multiplier == 100 else { throw OptionDailyError.invalidTime }
            return .init(contractID: contract.recordID, symbol: capture.symbol, feedID: capture.feedID, session: session,
                underlyingQuoteID: quoteID, right: contract.right == .call ? .call : .put, strike: contract.strike,
                expiry: .init(date: contract.expiration, settlementAt: settlement, source: assumptions),
                multiplier: contract.multiplier, specificationVersion: "explicit-offline-standard100-assumption.v1",
                bid: contract.quote.bid, ask: contract.quote.ask, bidSize: contract.quote.bidSize, askSize: contract.quote.askSize,
                tick: tick, quoteTime: contract.quote.quoteTime, receivedAt: contract.provenance.receivedAt,
                activity: .init(source: source), source: source)
        }
        return .init(createdAt: assumptionsEnteredAt, asOf: capture.createdAt, session: session, symbol: capture.symbol,
            feedID: capture.feedID, coverage: capture.snapshot.status == .complete ? .complete : .partial,
            declaredScope: OptionChainEvidence.scope(capture),
            underlying: .init(quoteID: quoteID, symbol: capture.symbol, feedID: capture.feedID, session: session,
                bid: underlying.bid, ask: underlying.ask, quoteTime: underlying.quoteTime,
                receivedAt: underlying.provenance.receivedAt, source: source),
            contracts: contracts, rate: rate, dividendYield: dividendYield, source: source,
            sessionCloseAt: declaredClose ? capture.createdAt : nil, chainEvidence: capture)
    }
    private static func temporaryLeg(_ value: OptionChainContract, quantity: Int, source: OptionLabSource) throws -> OptionLabLeg {
        guard let time = value.quote.quoteTime else { throw OptionLabError.invalidTime }
        return .init(contractID: value.recordID, symbol: value.underlyingSymbol, right: value.right == .call ? .call : .put,
            strike: value.strike, multiplier: value.multiplier, quantity: quantity, expirationDate: value.expiration,
            bid: value.quote.bid, ask: value.quote.ask, bidSize: value.quote.bidSize, askSize: value.quote.askSize,
            tick: nil, quotedAt: time, receivedAt: value.provenance.receivedAt, source: source)
    }
    private static func day(_ date: Date) -> MarketDate {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        return .init(year: c.component(.year, from: date), month: c.component(.month, from: date), day: c.component(.day, from: date))
    }
}
