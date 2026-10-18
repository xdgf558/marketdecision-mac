import Foundation
import CoreDomain
import DataContracts

/// A clearly synthetic evidence template. Weekdays below are fabricated fixture
/// sessions, never an official calendar or a source of production trading dates.
public enum OptionLabRiskDemo {
    public static func input(for input: OptionLabInput) throws -> OptionLabRiskInput {
        let source = OptionLabSource(origin: .synthetic,
            reference: "SYNTHETIC-OPTION-RISK; fabricated calendar, OI, volume, neighbors and corporate events; not official",
            enteredAt: input.createdAt)
        let legs = [input.shortLeg] + (input.longLeg.map { [$0] } ?? [])
        let evidence = try legs.map { leg -> OptionLabLiquidityInput in
            let mid = try leg.bid.adding(leg.ask).multiplied(by: "0.5")
            let lowValue = try mid.multiplied(by: "0.5"), highValue = try mid.multiplied(by: "1.5")
            func neighbor(_ suffix: String, factor: String, price: Money) throws -> OptionLabLeg {
                .init(contractID: "SYNTHETIC-NEIGHBOR-" + leg.contractID + suffix,
                    symbol: leg.symbol, right: leg.right, strike: try leg.strike.multiplied(by: factor),
                    multiplier: leg.multiplier, exerciseStyle: leg.exerciseStyle, delivery: leg.delivery,
                    specificationVersion: leg.specificationVersion, quantity: leg.quantity,
                    expirationDate: leg.expirationDate, bid: price, ask: price, bidSize: 20, askSize: 20,
                    tick: leg.tick, quotedAt: input.asOf, receivedAt: input.asOf, source: source)
            }
            return .init(contractID: leg.contractID, openInterest: 1500, oiSessionsAgo: 1, oiIsLatestPublished: true,
                volume: 200, volumeBasis: .fullSession,
                neighbors: [try neighbor("-LOW", factor: "0.9", price: leg.right == .put ? lowValue : highValue),
                            try neighbor("-HIGH", factor: "1.1", price: leg.right == .put ? highValue : lowValue)], neighborsComplete: true)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.startOfDay(for: input.asOf)
        func instant(_ offset: Int, hour: Int, minute: Int = 0) throws -> Date {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start),
                  let result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { throw OptionLabRiskError.invalidCalendar }
            return result
        }
        func marketDate(_ date: Date) -> MarketDate {
            .init(year: calendar.component(.year, from: date), month: calendar.component(.month, from: date), day: calendar.component(.day, from: date))
        }
        let sessions = try (-7...40).map { offset -> OptionLabRiskSession in
            let date = try instant(offset, hour: 12), weekday = calendar.component(.weekday, from: date)
            if weekday == 1 || weekday == 7 { return .init(date: marketDate(date), state: .closed) }
            return try .init(date: marketDate(date), state: .regular, opensAt: instant(offset,hour:9,minute:30), closesAt: instant(offset,hour:16))
        }
        let c = OptionLabRiskCalendar(version: "SYNTHETIC-WEEKDAY-CALENDAR.v1", source: source,
            from: marketDate(try instant(-7,hour:12)), through: marketDate(try instant(40,hour:12)), sessions: sessions)
        let future = sessions.filter { $0.date > marketDate(input.asOf) && $0.closesAt != nil }
        guard future.count >= 3 else { throw OptionLabRiskError.invalidCalendar }
        let event = future[2], ex = future[0]
        let earnings = OptionLabEarningsInput(eventVersion: "SYNTHETIC-EARNINGS.v1", source: source, announcedAt: input.asOf,
            eventDate: event.date, timing: .beforeMarket, certainty: .confirmed, calendar: c,
            allowsHoldingAcrossEvent: nil, straddles: [], straddleCoverageComplete: false)
        let dividend = OptionLabDividendInput(eventVersion: "SYNTHETIC-DIVIDEND.v1", source: source, announcedAt: input.asOf,
            exDate: ex.date, paymentAt: try instant(20,hour:12), amountPerShare: try Money("1"), certainty: .confirmed, calendar: c)
        return .init(source: source, liquidity: evidence, earnings: earnings, dividend: dividend)
    }
}
