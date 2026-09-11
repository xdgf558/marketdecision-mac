import Foundation
import CoreDomain

public enum USEquityMarket: String, Sendable, Codable, CaseIterable { case nyse = "XNYS", nasdaq = "XNAS" }
public enum MarketSessionState: String, Sendable, Codable { case regular, earlyClose, closed, unknown }
public enum CorporateEventKind: String, Sendable, Codable, CaseIterable { case earnings, exDividend }
public enum CorporateEventTiming: String, Sendable, Codable { case beforeMarket, duringMarket, afterMarket, notApplicable, unknown }
public enum CorporateEventCertainty: String, Sendable, Codable { case confirmed, estimated, unknown }

public struct MarketSessionRecord: ProviderRecord, Codable, Equatable {
    public let recordID: String
    public let market: USEquityMarket
    public let date: MarketDate
    public let state: MarketSessionState
    public let opensAt: Date?
    public let closesAt: Date?
    public let reason: String?
    public let provenance: Provenance

    public init(market: USEquityMarket, date: MarketDate, state: MarketSessionState,
                opensAt: Date?, closesAt: Date?, reason: String?, provenance: Provenance) throws {
        self.recordID = market.rawValue + "/" + date.iso8601
        self.market = market; self.date = date; self.state = state
        self.opensAt = opensAt; self.closesAt = closesAt; self.reason = reason; self.provenance = provenance
        try validate()
    }

    public func validate() throws {
        try provenance.validate()
        guard recordID == market.rawValue + "/" + date.iso8601,
              provenance.endpointDescriptor == EndpointDescriptor.marketCalendar.rawValue,
              provenance.observationDate == date else { throw ContractError.mismatchedSource }
        _ = try date.start(in: TimeZone(secondsFromGMT: 0)!)
        switch state {
        case .regular, .earlyClose:
            guard let opensAt, let closesAt, opensAt < closesAt, finite(opensAt), finite(closesAt),
                  localTime(opensAt) == (9, 30),
                  localTime(closesAt) == (state == .regular ? (16, 0) : (13, 0)),
                  marketDate(opensAt) == date, marketDate(closesAt) == date else { throw ContractError.invalidTime }
        case .closed, .unknown:
            guard opensAt == nil, closesAt == nil else { throw ContractError.invalidTime }
        }
        guard reason == nil || nonblank(reason) else { throw ContractError.invalidIdentity }
    }

    private func localTime(_ instant: Date) -> (Int, Int) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return (calendar.component(.hour, from: instant), calendar.component(.minute, from: instant))
    }
    private func marketDate(_ instant: Date) -> MarketDate {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return .init(year: calendar.component(.year, from: instant), month: calendar.component(.month, from: instant), day: calendar.component(.day, from: instant))
    }
}

public struct CorporateEventRecord: ProviderRecord, Codable, Equatable {
    public let recordID: String
    public let symbol: String
    public let kind: CorporateEventKind
    public let eventDate: MarketDate?
    public let timing: CorporateEventTiming
    public let certainty: CorporateEventCertainty
    public let declaredAmount: Money?
    public let currency: String?
    public let provenance: Provenance

    public init(recordID: String, symbol: String, kind: CorporateEventKind, eventDate: MarketDate?,
                timing: CorporateEventTiming, certainty: CorporateEventCertainty,
                declaredAmount: Money? = nil, currency: String? = nil, provenance: Provenance) throws {
        self.recordID = recordID; self.symbol = symbol; self.kind = kind; self.eventDate = eventDate
        self.timing = timing; self.certainty = certainty; self.declaredAmount = declaredAmount
        self.currency = currency; self.provenance = provenance
        try validate()
    }

    public func validate() throws {
        try provenance.validate()
        guard nonblank(recordID), symbol.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}\z"#, options: .regularExpression) != nil,
              provenance.endpointDescriptor == (kind == .earnings ? EndpointDescriptor.earningsCalendar.rawValue : EndpointDescriptor.dividends.rawValue)
        else { throw ContractError.mismatchedSource }
        if let eventDate { _ = try eventDate.start(in: TimeZone(secondsFromGMT: 0)!) }
        else {
            let expectedTiming: CorporateEventTiming = kind == .earnings ? .unknown : .notApplicable
            guard certainty == .unknown, timing == expectedTiming else { throw ContractError.invalidTime }
        }
        switch kind {
        case .earnings:
            guard declaredAmount == nil, currency == nil, timing != .notApplicable else { throw ContractError.invalidNormalization }
        case .exDividend:
            guard timing == .notApplicable, (declaredAmount == nil) == (currency == nil),
                  currency == nil || currency?.range(of: #"^[A-Z]{3}\z"#, options: .regularExpression) != nil
            else { throw ContractError.invalidNormalization }
        }
    }
}
