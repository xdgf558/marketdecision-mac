import Foundation
import CoreDomain

/// This slice deliberately represents a single exchange, USD, unadjusted prices only.
/// Coverage and arrival do not grant analysis, consolidated NBBO, ledger or fill eligibility.
public enum EquityKind: String, Sendable, Codable { case quote, dailyBar }
public struct EquityQuoteValues: Sendable, Codable, Equatable {
    public let bid: Money, ask: Money, bidSize: Money, askSize: Money
    public let bidExchange: String, askExchange: String
    public init(bid: Money, ask: Money, bidSize: Money, askSize: Money, bidExchange: String, askExchange: String) {
        self.bid = bid; self.ask = ask; self.bidSize = bidSize; self.askSize = askSize
        self.bidExchange = bidExchange; self.askExchange = askExchange
    }
}
public struct EquityDailyBarValues: Sendable, Codable, Equatable {
    public let open: Money, high: Money, low: Money, close: Money, volume: Money
    public let vwap: Money?
    public let trades: Int?
    public init(open: Money, high: Money, low: Money, close: Money, volume: Money, vwap: Money?, trades: Int?) {
        self.open = open; self.high = high; self.low = low; self.close = close; self.volume = volume
        self.vwap = vwap; self.trades = trades
    }
}

/// Exact source timestamp text is preserved independently of the millisecond comparison clock.
/// Historical daily aggregates are not final settlement marks or historical quote/fill evidence.
public struct EquityRecord: Sendable, Codable, ProviderRecord {
    public let symbol: String
    public let kind: EquityKind
    public let sourceTimestamp: String
    public let quote: EquityQuoteValues?
    public let bar: EquityDailyBarValues?
    public let provenance: Provenance
    public var recordID: String { kind == .quote ? symbol : symbol + "/" + sourceTimestamp }
    public var currency: String { "USD" }
    public var coverage: String { "IEX single exchange; not consolidated NBBO" }
    public var adjustment: String { "raw" }
    public var timeliness: Timeliness { kind == .quote ? .realtime : .endOfDay }

    public init(symbol: String, sourceTimestamp: String, quote: EquityQuoteValues, provenance: Provenance) throws {
        self.symbol = symbol; self.sourceTimestamp = sourceTimestamp; self.quote = quote; self.bar = nil
        self.kind = .quote; self.provenance = provenance
        try validate()
    }
    public init(symbol: String, sourceTimestamp: String, bar: EquityDailyBarValues, provenance: Provenance) throws {
        self.symbol = symbol; self.sourceTimestamp = sourceTimestamp; self.quote = nil; self.bar = bar
        self.kind = .dailyBar; self.provenance = provenance
        try validate()
    }
    public static func validateSymbol(_ symbol: String) throws {
        guard symbol.range(of: #"^[A-Z][A-Z0-9.-]{0,14}\z"#, options: .regularExpression) != nil,
              !symbol.contains("..") else { throw ContractError.invalidIdentity }
    }
    public static func sourceTime(_ text: String) throws -> Date {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z\z"#, options: .regularExpression) != nil
        else { throw ContractError.invalidTime }
        let fraction = text.contains(".") ? String(text.dropFirst(20).dropLast()) : ""
        let nanos = Int(fraction + String(repeating: "0", count: 9 - fraction.count)) ?? 0
        let milliseconds = nanos / 1_000_000, remainder = nanos % 1_000_000
        let base = try MillisecondInstant(iso8601: String(text.prefix(19)) + String(format: ".%03dZ", milliseconds))
        let roundUp = remainder > 500_000 || (remainder == 500_000 && milliseconds % 2 != 0)
        return try MillisecondInstant(milliseconds: base.milliseconds + (roundUp ? 1 : 0)).date
    }
    public func validate() throws {
        try Self.validateSymbol(symbol); try provenance.validate()
        let time = try Self.sourceTime(sourceTimestamp)
        guard provenance.providerID == "alpaca", provenance.feedID == "iex", provenance.origin == .provider,
              provenance.sourceEventAt == time, time <= provenance.receivedAt,
              provenance.availability == .unknown, provenance.versionKind == .localContent,
              provenance.normalizationVersion == "equity.raw-iex.v1",
              provenance.versionID == contentVersion(),
              provenance.endpointDescriptor == (kind == .quote ? EndpointDescriptor.quote : .bars).rawValue
        else { throw ContractError.mismatchedSource }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.dateComponents([.year, .month, .day], from: time)
        guard provenance.observationDate == MarketDate(year: day.year!, month: day.month!, day: day.day!) else {
            throw ContractError.invalidTime
        }
        switch kind {
        case .quote:
            guard let quote, bar == nil, quote.bid.amount >= 0, quote.ask.amount >= 0,
                  quote.bidSize.amount >= 0, quote.askSize.amount >= 0,
                  quote.bidExchange == "V", quote.askExchange == "V" else { throw ContractError.invalidNormalization }
        case .dailyBar:
            guard quote == nil, let bar, bar.low.amount > 0, bar.low <= bar.high,
                  bar.low <= bar.open, bar.open <= bar.high, bar.low <= bar.close, bar.close <= bar.high,
                  bar.volume.amount >= 0, bar.vwap.map({ $0.amount > 0 }) ?? true,
                  bar.trades.map({ $0 >= 0 }) ?? true,
                  calendar.startOfDay(for: time) == time,
                  time < calendar.startOfDay(for: provenance.receivedAt)
            else { throw ContractError.invalidNormalization }
        }
    }
    /// Fingerprint excludes retrieval metadata; preserves source nanoseconds and exact decimals.
    public func contentVersion() -> String {
        Self.contentVersion(symbol: symbol, timestamp: sourceTimestamp, quote: quote, bar: bar)
    }
    public static func contentVersion(symbol: String, timestamp: String, quote: EquityQuoteValues?, bar: EquityDailyBarValues?) -> String {
        let values = quote.map { [$0.bid.decimalString, $0.ask.decimalString, $0.bidSize.decimalString,
                                  $0.askSize.decimalString, $0.bidExchange, $0.askExchange] }
            ?? bar.map { [$0.open.decimalString, $0.high.decimalString, $0.low.decimalString, $0.close.decimalString,
                         $0.volume.decimalString, $0.vwap?.decimalString ?? "null", $0.trades.map(String.init) ?? "null"] } ?? []
        // Alphabet-restricted symbol/timestamp and decimal fields cannot contain the delimiter.
        return digest(Data((["equity.raw-iex.v1", symbol, timestamp, quote == nil ? "bar" : "quote"] + values).joined(separator: "|").utf8))
    }
    public func quality(at now: Date) -> Set<QualityFlag> {
        var result = Set<QualityFlag>()
        if kind == .quote, let quote {
            if quote.bid.amount <= 0 || quote.ask.amount <= 0 || quote.bid > quote.ask
                || quote.bidSize.amount == 0 || quote.askSize.amount == 0 { result.insert(.invalid) }
            if let source = provenance.sourceEventAt,
               now.timeIntervalSince(source) > FreshnessPolicy.foundationV1.realtimeMaxAge { result.insert(.stale) }
        }
        return result
    }
    /// No vendor/model qualification is granted by this adapter. Consumers must explicitly qualify.
    public func displayQuote(at now: Date) throws -> Quote {
        try validate()
        guard let quote, now.timeIntervalSince1970.isFinite, now >= provenance.receivedAt else { throw ContractError.invalidTime }
        return Quote(symbol: symbol, bid: quote.bid, ask: quote.ask, provenance: provenance,
                     timeliness: timeliness, quality: quality(at: now), qualifiedUsages: [])
    }
}
