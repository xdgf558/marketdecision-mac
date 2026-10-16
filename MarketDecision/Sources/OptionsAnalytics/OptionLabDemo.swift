import Foundation
import CoreDomain
import DataContracts

/// Explicit synthetic template. Editing its numbers must not relabel its origin as real.
public enum OptionLabDemo {
    public static func input(strategy: OptionLabStrategy = .cashSecuredPut,
                             at: Date = Date(timeIntervalSince1970: 1_791_903_600)) throws -> OptionLabInput {
        let asOf = at
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard let expiryInstant = calendar.date(byAdding: .day, value: 30, to: asOf) else { throw OptionLabError.invalidTime }
        let date = MarketDate(year: calendar.component(.year, from: expiryInstant), month: calendar.component(.month, from: expiryInstant), day: calendar.component(.day, from: expiryInstant))
        let source = OptionLabSource(origin: .synthetic, reference: "SYNTHETIC-OPTION-LAB; assumed quote, standard contract and settlement time", enteredAt: asOf)
        let put = strategy == .cashSecuredPut || strategy == .putCreditSpread
        let short = OptionLabLeg(contractID: put ? "SYNTHETIC-P100" : "SYNTHETIC-C100", symbol: "DEMO", right: put ? .put : .call,
            strike: try Money("100"), quantity: 1, expirationDate: date, bid: try Money("2"), ask: try Money("2.4"),
            bidSize: 10, askSize: 10, tick: try Money("0.01"), quotedAt: asOf, receivedAt: asOf, source: source)
        let spread = strategy == .putCreditSpread || strategy == .callCreditSpread
        let long: OptionLabLeg? = spread ? OptionLabLeg(contractID: put ? "SYNTHETIC-P95" : "SYNTHETIC-C105", symbol: "DEMO", right: put ? .put : .call,
            strike: try Money(put ? "95" : "105"), quantity: 1, expirationDate: date, bid: try Money("0.8"), ask: try Money("1"),
            bidSize: 10, askSize: 10, tick: try Money("0.01"), quotedAt: asOf, receivedAt: asOf, source: source) : nil
        return OptionLabInput(createdAt: asOf, asOf: asOf, strategy: strategy, shortLeg: short, longLeg: long,
            underlying: OptionLabUnderlying(symbol: "DEMO", bid: try Money("99.9"), ask: try Money("100.1"), quotedAt: asOf, receivedAt: asOf, source: source),
            capital: OptionLabCapital(origin: .synthetic, reference: "SYNTHETIC-CAPITAL; no broker account", asOf: asOf,
                cashBeforeTrade: try Money("20000"), committedCash: try Money("0"), availableShares: try Money("100"), committedShares: try Money("0")),
            policy: try .defaults(), expiry: OptionLabExpiry(date: date, settlementAt: expiryInstant, source: source),
            scenarioPrices: try (0...40).map { try Money(String($0 * 5)) })
    }
}
