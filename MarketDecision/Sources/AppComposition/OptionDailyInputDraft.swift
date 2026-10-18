import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

public struct OptionDailyExpiryDraft: Equatable, Sendable {
    public var date = ""
    public var settlementAt = ""
    public var strike = ""
    public var callBid = ""
    public var callAsk = ""
    public var putBid = ""
    public var putAsk = ""
    public init() {}
}
/// A compact declaration of exactly two expiries and one common strike per expiry.
/// Shared quote times/size/tick are explicit input assumptions for all four contracts.
public struct OptionDailyInputDraft: Equatable, Sendable {
    public private(set) var origin: OptionLabOrigin = .manual
    public var symbol = ""
    public var session = ""
    public var asOf = ""
    public var sourceReference = ""
    public var declaredScope = "所填两组到期、各一档行权价的 Call / Put；不代表供应商完整期权链"
    public var partial = false
    public var declaredClose = false
    public var underlyingBid = ""
    public var underlyingAsk = ""
    public var quotedAt = ""
    public var receivedAt = ""
    public var rate = ""
    public var dividendYield = ""
    public var bidSize = ""
    public var askSize = ""
    public var tick = ""
    public var near = OptionDailyExpiryDraft()
    public var far = OptionDailyExpiryDraft()
    public init() {}
    public static func synthetic() throws -> Self { Self(generated: try OptionDailyDemo.input()) }
    private init(generated input: OptionDailyInput) {
        origin = .synthetic; symbol = input.symbol; session = input.session.iso8601
        asOf = dailyDraftTimestamp(input.asOf); sourceReference = input.source.reference; declaredScope = input.declaredScope
        declaredClose = input.sessionCloseAt == input.asOf
        partial = input.coverage == .partial; underlyingBid = input.underlying.bid.decimalString; underlyingAsk = input.underlying.ask.decimalString
        quotedAt = input.underlying.quoteTime.map(dailyDraftTimestamp) ?? ""
        receivedAt = input.underlying.receivedAt.map(dailyDraftTimestamp) ?? ""
        rate = input.rate.decimalString; dividendYield = input.dividendYield.decimalString
        if let first = input.contracts.first {
            bidSize = String(first.bidSize); askSize = String(first.askSize); tick = first.tick?.decimalString ?? ""
        }
        let expiries = Array(Set(input.contracts.map(\.expiry.settlementAt))).sorted()
        func draft(_ date: Date) -> OptionDailyExpiryDraft {
            var result = OptionDailyExpiryDraft()
            let contracts = input.contracts.filter { $0.expiry.settlementAt == date }
            if let first = contracts.first { result.date = first.expiry.date.iso8601; result.settlementAt = dailyDraftTimestamp(date); result.strike = first.strike.decimalString }
            if let call = contracts.first(where: { $0.right == .call }) { result.callBid = call.bid.decimalString; result.callAsk = call.ask.decimalString }
            if let put = contracts.first(where: { $0.right == .put }) { result.putBid = put.bid.decimalString; result.putAsk = put.ask.decimalString }
            return result
        }
        if let first = expiries.first { near = draft(first) }
        if expiries.count > 1 { far = draft(expiries[1]) }
    }
    public func build() throws -> OptionDailyInput {
        func date(_ text: String) throws -> Date {
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = format.date(from: text) { return value }
            format.formatOptions = [.withInternetDateTime]
            guard let value = format.date(from: text) else { throw OptionLabDraftError.invalidDate }
            return value
        }
        func optionalDate(_ text: String) throws -> Date? { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try date(text) }
        let code = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let buySize = Int(bidSize), let sellSize = Int(askSize) else { throw OptionLabDraftError.missingField }
        let instant = try date(asOf), day = try MarketDate(iso8601: session), enteredAt = Date()
        let source = OptionLabSource(origin: origin, reference: sourceReference, enteredAt: enteredAt)
        let quoteTime = try optionalDate(quotedAt), received = try optionalDate(receivedAt)
        let feed = origin == .synthetic ? "synthetic-offline" : "manual-offline"
        let quoteID = UUID().uuidString
        func contracts(_ draft: OptionDailyExpiryDraft, prefix: String) throws -> [OptionDailyContractInput] {
            let expiry = try OptionLabExpiry(date: MarketDate(iso8601: draft.date), settlementAt: date(draft.settlementAt), source: source)
            return try [OptionLabRight.call, .put].map { right in
                try .init(contractID: "\(code)-\(prefix)-\(right.rawValue)", symbol: code, feedID: feed, session: day,
                    underlyingQuoteID: quoteID, right: right, strike: Money(draft.strike), expiry: expiry,
                    bid: Money(right == .call ? draft.callBid : draft.putBid), ask: Money(right == .call ? draft.callAsk : draft.putAsk),
                    bidSize: buySize, askSize: sellSize, tick: tick.isEmpty ? nil : Money(tick), quoteTime: quoteTime, receivedAt: received,
                    activity: .init(source: source), source: source)
            }
        }
        return try .init(createdAt: enteredAt, asOf: instant, session: day, symbol: code, feedID: feed,
            coverage: partial ? .partial : .complete, declaredScope: declaredScope,
            underlying: .init(quoteID: quoteID, symbol: code, feedID: feed, session: day, bid: Money(underlyingBid), ask: Money(underlyingAsk),
                              quoteTime: quoteTime, receivedAt: received, source: source),
            contracts: contracts(near, prefix: "near") + contracts(far, prefix: "far"), rate: Money(rate), dividendYield: Money(dividendYield), source: source, sessionCloseAt: declaredClose ? instant : nil)
    }
}

private func dailyDraftTimestamp(_ date: Date) -> String {
    let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.string(from: date)
}
