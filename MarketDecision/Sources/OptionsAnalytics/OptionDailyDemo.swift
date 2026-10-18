import Foundation
import CoreDomain
import DataContracts

/// Synthetic BSM quotes solely exercise the local pipeline. The generator cannot
/// relabel its data as manual/real or infer actual exchange sessions from weekdays.
public enum OptionDailyDemo {
    public static let defaultDate = Date(timeIntervalSince1970: 1_792_180_800) // 2026-10-16 20:00 UTC
    public static func input(id: UUID = UUID(), at: Date = defaultDate, nearDays: Int = 20, farDays: Int = 40,
                             volatility: Double = 0.25) throws -> OptionDailyInput {
        guard nearDays > 0, farDays > 0, nearDays <= 366, farDays <= 366,
              volatility.isFinite, volatility > 0, volatility <= 5 else { throw OptionDailyError.invalidInput }
        let session = day(at)
        let source = OptionLabSource(origin: .synthetic,
            reference: "SYNTHETIC-IV-DAILY; generated BSM quotes, declared bounded chain and assumed close; no real data", enteredAt: at)
        let underlying = OptionDailyUnderlying(quoteID: "SYNTHETIC-U-\(session.iso8601)", symbol: "DEMO", feedID: "SYNTHETIC-LOCAL-BSM",
            session: session, bid: try Money("99.99"), ask: try Money("100.01"), quoteTime: at, receivedAt: at, source: source)
        let rate = try Money("0.04"), q = try Money("0.01")
        var contracts: [OptionDailyContractInput] = []
        for duration in Set([nearDays, farDays]).sorted() {
            let settlement = at.addingTimeInterval(Double(duration) * 86_400)
            let expiry = OptionLabExpiry(date: day(settlement), settlementAt: settlement, source: source)
            for right in [OptionLabRight.call, .put] {
                let market = OptionBSMMarket(right: right, spot: 100, strike: 100, rate: 0.04, dividendYield: 0.01,
                    timeYears: Double(duration) / 365)
                guard let price = OptionBSM.evaluate(market, volatility: volatility).price else { throw OptionDailyError.invalidInput }
                let mid = try Money(String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), price))
                contracts.append(.init(contractID: "SYNTHETIC-\(session.iso8601)-\(duration)-\(right.rawValue)", symbol: "DEMO", feedID: underlying.feedID,
                    session: session, underlyingQuoteID: underlying.quoteID, right: right, strike: try Money("100"), expiry: expiry,
                    bid: mid, ask: mid, bidSize: 10, askSize: 10, tick: try Money("0.000000000001"), quoteTime: at, receivedAt: at,
                    activity: .init(volume: 100, volumeSession: session, openInterest: 200, openInterestAsOf: session,
                                    openInterestReleasedAt: at, openInterestLatestPublished: true, source: source), source: source))
            }
        }
        let calendar = OptionDailyCalendar(id: "SYNTHETIC-ONE-SESSION", version: "synthetic-declared-session.v1", sessions: [session], source: source)
        return .init(id: id, createdAt: at, asOf: at, session: session, symbol: "DEMO", feedID: underlying.feedID,
            coverage: .complete, declaredScope: "SYNTHETIC bounded chain: only declared expiries; one ATM strike with call and put each; no market completeness claim",
            underlying: underlying, contracts: contracts, rate: rate, dividendYield: q, source: source, calendar: calendar, sessionCloseAt: at)
    }
    static func day(_ date: Date) -> MarketDate {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        return .init(year: c.component(.year, from: date), month: c.component(.month, from: date), day: c.component(.day, from: date))
    }
}
public enum OptionVolatilityHistoryDemo {
    /// Repeated synthetic IVs (0.2, 0.3, 0.4) and current 0.45 by default.
    /// Weekdays are fixture labels only, explicitly including real-world holidays.
    public static func input(priorSessions: Int = 252, constantVolatility: Double? = nil) throws -> OptionVolatilityHistoryInput {
        guard priorSessions >= 0, priorSessions <= 520 else { throw OptionDailyError.invalidInput }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let currentAt = OptionDailyDemo.defaultDate
        var cursor = currentAt, dates: [Date] = []
        while dates.count < priorSessions {
            try Task.checkCancellation()
            guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { throw OptionDailyError.invalidTime }
            cursor = prior
            if ![1,7].contains(calendar.component(.weekday, from: cursor)) { dates.append(cursor) }
        }
        dates.reverse()
        let source = OptionLabSource(origin: .synthetic,
            reference: "SYNTHETIC-WEEKDAY-CALENDAR; weekdays only including exchange holidays; NOT an official exchange calendar or historical dataset", enteredAt: currentAt)
        let declared = OptionDailyCalendar(id: "SYNTHETIC-IV-HISTORY-WEEKDAYS", version: "synthetic-weekdays.v1",
            sessions: dates.map(OptionDailyDemo.day) + [OptionDailyDemo.day(currentAt)], source: source)
        var reports: [OptionDailyReport] = []
        for (index, date) in dates.enumerated() {
            try Task.checkCancellation()
            let input = try OptionDailyDemo.input(at: date, nearDays: 30, farDays: 30, volatility: constantVolatility ?? (0.2 + Double(index % 3) * 0.1))
            reports.append(try OptionDailyEngine.calculate(input))
        }
        let current = try OptionDailyEngine.calculate(OptionDailyDemo.input(at: currentAt, nearDays: 30, farDays: 30,
            volatility: constantVolatility ?? 0.45))
        return .init(createdAt: currentAt, current: current, history: reports, calendar: declared)
    }
}
