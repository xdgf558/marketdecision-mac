import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine

/// Missing declarations stay missing. In particular, blank OI is not zero and
/// blank calendars are never expanded into guessed weekday sessions.
public struct OptionLabLiquidityDraft: Equatable, Sendable {
    public var openInterest = ""
    public var oiSessionsAgo = ""
    public var oiIsLatestPublished = false
    public var volume = ""
    public var volumeBasis: OptionLabVolumeBasis = .unverified
    public var neighbors = ""
    public var neighborsComplete = false
    private var original: OptionLabLiquidityInput?
    public init() {}
    init(_ input: OptionLabLiquidityInput) {
        original = input; openInterest = input.openInterest.map(String.init) ?? ""
        oiSessionsAgo = input.oiSessionsAgo.map(String.init) ?? ""; oiIsLatestPublished = input.oiIsLatestPublished
        volume = input.volume.map(String.init) ?? ""; volumeBasis = input.volumeBasis
        neighbors = Self.neighborText(input.neighbors); neighborsComplete = input.neighborsComplete
    }
    private static func neighborRow(_ value: OptionLabLeg) -> String {
        [value.contractID, value.strike.decimalString, value.bid.decimalString, value.ask.decimalString,
         String(value.bidSize), String(value.askSize), value.tick?.decimalString ?? "", riskTimestamp(value.quotedAt), riskTimestamp(value.receivedAt)].joined(separator: "|")
    }
    private static func neighborText(_ values: [OptionLabLeg]) -> String { values.map(neighborRow).joined(separator: "\n") }
    func build(leg: OptionLabLeg, source: OptionLabSource) throws -> OptionLabLiquidityInput {
        let values: [OptionLabLeg]
        if let original, neighbors == Self.neighborText(original.neighbors) { values = original.neighbors }
        else {
            let originalByID = Dictionary(grouping: original?.neighbors ?? [], by: \.contractID)
            values = try riskRows(neighbors).map { row in
                let fields = try riskColumns(row, count: 9)
                let prior = try riskUniqueMatch(originalByID[fields[0]] ?? [])
                if let prior, fields.joined(separator: "|") == Self.neighborRow(prior) { return prior }
                guard let bidSize = Int(fields[4]), let askSize = Int(fields[5]) else { throw OptionLabDraftError.invalidNumber }
                return try OptionLabLeg(contractID: fields[0], symbol: prior?.symbol ?? leg.symbol, right: prior?.right ?? leg.right,
                    strike: Money(fields[1]), multiplier: prior?.multiplier ?? leg.multiplier,
                    exerciseStyle: prior?.exerciseStyle ?? leg.exerciseStyle, delivery: prior?.delivery ?? leg.delivery,
                    specificationVersion: prior?.specificationVersion ?? leg.specificationVersion,
                    quantity: prior?.quantity ?? 1, expirationDate: prior?.expirationDate ?? leg.expirationDate,
                    bid: Money(fields[2]), ask: Money(fields[3]), bidSize: bidSize, askSize: askSize,
                    tick: fields[6].isEmpty ? nil : Money(fields[6]), quotedAt: riskDate(fields[7], original: prior?.quotedAt),
                    receivedAt: riskDate(fields[8], original: prior?.receivedAt), source: riskEditedSource(source, original: prior?.source))
            }
        }
        return try .init(contractID: leg.contractID, openInterest: riskOptionalInt(openInterest), oiSessionsAgo: riskOptionalInt(oiSessionsAgo),
            oiIsLatestPublished: oiIsLatestPublished, volume: riskOptionalInt(volume), volumeBasis: volumeBasis,
            neighbors: values, neighborsComplete: neighborsComplete)
    }
}

public struct OptionLabCalendarDraft: Equatable, Sendable {
    public var enabled = false
    public var version = ""
    public var sourceReference = ""
    public var from = ""
    public var through = ""
    public var sessions = ""
    private var original: OptionLabRiskCalendar?
    public init() {}
    init(_ value: OptionLabRiskCalendar) {
        original = value; enabled = true; version = value.version; sourceReference = value.source.reference
        from = value.from.iso8601; through = value.through.iso8601; sessions = Self.sessionText(value.sessions)
    }
    private static func sessionRow(_ value: OptionLabRiskSession) -> String {
        [value.date.iso8601, value.state.rawValue, value.opensAt.map(riskTimestamp) ?? "", value.closesAt.map(riskTimestamp) ?? ""].joined(separator: "|")
    }
    private static func sessionText(_ values: [OptionLabRiskSession]) -> String { values.map(sessionRow).joined(separator: "\n") }
    func build(origin: OptionLabOrigin, enteredAt: Date) throws -> OptionLabRiskCalendar? {
        guard enabled else { return nil }
        let source = try riskSource(origin: origin, reference: sourceReference, enteredAt: enteredAt, original: original?.source)
        let values: [OptionLabRiskSession]
        if let original, sessions == Self.sessionText(original.sessions) { values = original.sessions }
        else {
            let originalByDate = Dictionary(grouping: original?.sessions ?? [], by: { $0.date.iso8601 })
            values = try riskRows(sessions).map { row in
                let fields = try riskColumns(row, count: 4)
                let date = try MarketDate(iso8601: fields[0])
                let prior = try riskUniqueMatch(originalByDate[date.iso8601] ?? [])
                if let prior, fields.joined(separator: "|") == Self.sessionRow(prior) { return prior }
                guard let state = MarketSessionState(rawValue: fields[1]) else { throw OptionLabDraftError.missingField }
                return try .init(date: date, state: state,
                    opensAt: fields[2].isEmpty ? nil : riskDate(fields[2], original: prior?.opensAt),
                    closesAt: fields[3].isEmpty ? nil : riskDate(fields[3], original: prior?.closesAt))
            }
        }
        return try .init(version: version, source: source, from: MarketDate(iso8601: from), through: MarketDate(iso8601: through), sessions: values)
    }
}

public struct OptionLabEarningsDraft: Equatable, Sendable {
    public var enabled = false
    public var eventVersion = ""
    public var sourceReference = ""
    public var announcedAt = ""
    public var eventDate = ""
    public var timing: CorporateEventTiming = .unknown
    public var certainty: CorporateEventCertainty = .unknown
    /// Empty is unknown, not consent to hold through the event.
    public var holdingChoice = ""
    public var calendar = OptionLabCalendarDraft()
    public var straddles = ""
    public var straddleCoverageComplete = false
    private var original: OptionLabEarningsInput?
    public init() {}
    init(_ input: OptionLabEarningsInput) {
        original = input; enabled = true; eventVersion = input.eventVersion; sourceReference = input.source.reference
        announcedAt = riskTimestamp(input.announcedAt); eventDate = input.eventDate.iso8601
        timing = input.timing; certainty = input.certainty
        holdingChoice = input.allowsHoldingAcrossEvent.map { $0 ? "allow" : "deny" } ?? ""
        calendar = input.calendar.map(OptionLabCalendarDraft.init) ?? .init()
        straddles = Self.straddleText(input.straddles); straddleCoverageComplete = input.straddleCoverageComplete
    }
    private static func straddleRow(_ value: OptionLabStraddleQuote) -> String {
        [value.strike.decimalString, riskTimestamp(value.settlementAt), value.callBid.decimalString, value.callAsk.decimalString,
         value.putBid.decimalString, value.putAsk.decimalString, riskTimestamp(value.quotedAt)].joined(separator: "|")
    }
    private static func straddleText(_ values: [OptionLabStraddleQuote]) -> String { values.map(straddleRow).joined(separator: "\n") }
    func build(origin: OptionLabOrigin, enteredAt: Date) throws -> OptionLabEarningsInput? {
        guard enabled else { return nil }
        let source = try riskSource(origin: origin, reference: sourceReference, enteredAt: enteredAt, original: original?.source)
        let values: [OptionLabStraddleQuote]
        if let original, straddles == Self.straddleText(original.straddles) { values = original.straddles }
        else {
            let originalByIdentity = Dictionary(grouping: original?.straddles ?? [], by: {
                $0.strike.decimalString + "|" + riskTimestamp($0.settlementAt)
            })
            values = try riskRows(straddles).map { row in
                let fields = try riskColumns(row, count: 7)
                let strike = try Money(fields[0])
                // The displayed expiry is deliberately not a unique identifier by
                // itself: two exact expiries can share its millisecond display.
                // Refuse such an ambiguous edit instead of choosing by row order.
                let prior = try riskUniqueMatch(originalByIdentity[strike.decimalString + "|" + fields[1]] ?? [])
                if let prior, fields.joined(separator: "|") == Self.straddleRow(prior) { return prior }
                return try .init(strike: strike, settlementAt: riskDate(fields[1], original: prior?.settlementAt), callBid: Money(fields[2]),
                    callAsk: Money(fields[3]), putBid: Money(fields[4]), putAsk: Money(fields[5]),
                    quotedAt: riskDate(fields[6], original: prior?.quotedAt), source: riskEditedSource(source, original: prior?.source))
            }
        }
        guard ["", "allow", "deny"].contains(holdingChoice) else { throw OptionLabDraftError.missingField }
        return try .init(eventVersion: eventVersion, source: source,
            announcedAt: riskDate(announcedAt, original: original?.announcedAt), eventDate: MarketDate(iso8601: eventDate),
            timing: timing, certainty: certainty, calendar: calendar.build(origin: origin, enteredAt: enteredAt),
            allowsHoldingAcrossEvent: holdingChoice.isEmpty ? nil : holdingChoice == "allow",
            straddles: values, straddleCoverageComplete: straddleCoverageComplete)
    }
}

public struct OptionLabDividendDraft: Equatable, Sendable {
    public var enabled = false
    public var eventVersion = ""
    public var sourceReference = ""
    public var announcedAt = ""
    public var exDate = ""
    public var paymentAt = ""
    public var amountPerShare = ""
    public var currency = "USD"
    public var certainty: CorporateEventCertainty = .unknown
    public var calendar = OptionLabCalendarDraft()
    private var original: OptionLabDividendInput?
    public init() {}
    init(_ input: OptionLabDividendInput) {
        original = input; enabled = true; eventVersion = input.eventVersion; sourceReference = input.source.reference
        announcedAt = riskTimestamp(input.announcedAt); exDate = input.exDate.iso8601
        paymentAt = input.paymentAt.map(riskTimestamp) ?? ""; amountPerShare = input.amountPerShare?.decimalString ?? ""
        currency = input.currency; certainty = input.certainty; calendar = input.calendar.map(OptionLabCalendarDraft.init) ?? .init()
    }
    func build(origin: OptionLabOrigin, enteredAt: Date) throws -> OptionLabDividendInput? {
        guard enabled else { return nil }
        return try .init(eventVersion: eventVersion,
            source: riskSource(origin: origin, reference: sourceReference, enteredAt: enteredAt, original: original?.source),
            announcedAt: riskDate(announcedAt, original: original?.announcedAt), exDate: MarketDate(iso8601: exDate),
            paymentAt: paymentAt.isEmpty ? nil : riskDate(paymentAt, original: original?.paymentAt),
            amountPerShare: amountPerShare.isEmpty ? nil : Money(amountPerShare), currency: currency, certainty: certainty,
            calendar: calendar.build(origin: origin, enteredAt: enteredAt))
    }
}

public struct OptionLabRiskDraft: Equatable, Sendable {
    public var enabled = false
    public var sourceReference = ""
    public var shortLeg = OptionLabLiquidityDraft()
    public var longLeg = OptionLabLiquidityDraft()
    public var earnings = OptionLabEarningsDraft()
    public var dividend = OptionLabDividendDraft()
    public private(set) var methodVersion = OptionLabRiskInput.currentMethodVersion
    private var original: OptionLabRiskInput?
    private var originalShortID: String?
    private var originalLongID: String?
    public init() {}
    init(_ input: OptionLabRiskInput, shortID: String, longID: String?) {
        original = input; originalShortID = shortID; originalLongID = longID
        enabled = true; sourceReference = input.source.reference; methodVersion = input.methodVersion
        shortLeg = input.liquidity.first(where: { $0.contractID == shortID }).map(OptionLabLiquidityDraft.init) ?? .init()
        longLeg = input.liquidity.first(where: { $0.contractID == longID }).map(OptionLabLiquidityDraft.init) ?? .init()
        earnings = input.earnings.map(OptionLabEarningsDraft.init) ?? .init()
        dividend = input.dividend.map(OptionLabDividendDraft.init) ?? .init()
    }
    func build(short: OptionLabLeg, long: OptionLabLeg?, origin: OptionLabOrigin, enteredAt: Date) throws -> OptionLabRiskInput? {
        guard enabled else { return nil }
        if let original, originalShortID == short.contractID, originalLongID == long?.contractID,
           self == Self(original, shortID: short.contractID, longID: long?.contractID) { return original }
        let source = try riskSource(origin: origin, reference: sourceReference, enteredAt: enteredAt, original: original?.source)
        var liquidity = [try shortLeg.build(leg: short, source: source)]
        if let long { liquidity.append(try longLeg.build(leg: long, source: source)) }
        return try .init(source: source, liquidity: liquidity,
            earnings: earnings.build(origin: origin, enteredAt: enteredAt), dividend: dividend.build(origin: origin, enteredAt: enteredAt),
            methodVersion: methodVersion)
    }
}

/// Editing one row must not re-parse the rounded display of other rows. Match
/// only stable identities, with explicit failure on ambiguous original identities.
private func riskUniqueMatch<Value>(_ values: [Value]) throws -> Value? {
    guard values.count <= 1 else { throw OptionLabDraftError.missingField }
    return values.first
}
private func riskEditedSource(_ source: OptionLabSource, original: OptionLabSource?) -> OptionLabSource {
    guard original?.origin == .synthetic, source.origin != .synthetic else { return source }
    return .init(origin: .synthetic, reference: source.reference, enteredAt: source.enteredAt)
}

private func riskRows(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}
private func riskColumns(_ text: String, count: Int) throws -> [String] {
    let fields = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard fields.count == count else { throw OptionLabDraftError.missingField }
    return fields
}
private func riskOptionalInt(_ text: String) throws -> Int? {
    guard !text.isEmpty else { return nil }
    guard let value = Int(text) else { throw OptionLabDraftError.invalidNumber }
    return value
}
private func riskTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
private func riskDate(_ text: String, original: Date? = nil) throws -> Date {
    if let original, text == riskTimestamp(original) { return original }
    return try LedgerCSV.timestamp(text)
}
private func riskSource(origin: OptionLabOrigin, reference: String, enteredAt: Date, original: OptionLabSource?) throws -> OptionLabSource {
    guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OptionLabDraftError.missingField }
    if let original, reference == original.reference { return original }
    return .init(origin: origin, reference: reference, enteredAt: enteredAt)
}
