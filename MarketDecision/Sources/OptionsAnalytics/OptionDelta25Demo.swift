import Foundation
import CoreDomain
import DataContracts

/// Deterministic synthetic quotes. Wider strikes demonstrate both signed Delta
/// targets; they are not imported provider data or an official full market chain.
public enum OptionDelta25Demo {
    public static func input(
        id: UUID = UUID(uuidString: "D0250000-2026-4018-8000-000000000001")!,
        dailyID: UUID = UUID(uuidString: "D0250000-2026-4018-8000-000000000002")!,
        at: Date = OptionDailyDemo.defaultDate,
        nearDays: Int = 20, farDays: Int = 40,
        callVolatility: Double = 0.25, putVolatility: Double = 0.35
    ) throws -> OptionDelta25Input {
        guard nearDays > 0, farDays > 0, nearDays <= 366, farDays <= 366,
              callVolatility.isFinite, callVolatility > 0, callVolatility <= 5,
              putVolatility.isFinite, putVolatility > 0, putVolatility <= 5
        else { throw OptionDailyError.invalidInput }
        let session = OptionDailyDemo.day(at)
        let source = OptionLabSource(origin: .synthetic,
            reference: "SYNTHETIC-DELTA25; generated BSM grid, declared expiries and strikes, assumed close; no provider observations",
            enteredAt: at)
        let underlying = OptionDailyUnderlying(quoteID: "SYNTHETIC-DELTA25-U", symbol: "DEMO",
            feedID: "SYNTHETIC-LOCAL-BSM", session: session, bid: try Money("99.99"), ask: try Money("100.01"),
            quoteTime: at, receivedAt: at, source: source)
        var contracts: [OptionDailyContractInput] = []
        for days in Set([nearDays, farDays]).sorted() {
            let settlement = at.addingTimeInterval(Double(days) * 86_400)
            let expiry = OptionLabExpiry(date: OptionDailyDemo.day(settlement), settlementAt: settlement, source: source)
            for right in [OptionLabRight.call, .put] {
                for strike in stride(from: 80, through: 120, by: 5) {
                    let market = OptionBSMMarket(right: right, spot: 100, strike: Double(strike), rate: 0.04,
                        dividendYield: 0.01, timeYears: Double(days) / 365)
                    let sigma = right == .call ? callVolatility : putVolatility
                    guard let price = OptionBSM.evaluate(market, volatility: sigma).price else {
                        throw OptionDailyError.invalidInput
                    }
                    let mid = try Money(String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), price))
                    let activity = OptionDailyActivity(volume: 100, volumeSession: session, openInterest: 200,
                        openInterestAsOf: session, openInterestReleasedAt: at, openInterestLatestPublished: true, source: source)
                    contracts.append(.init(contractID: "SYNTHETIC-DELTA25-\(days)-\(right.rawValue)-\(strike)",
                        symbol: "DEMO", feedID: underlying.feedID, session: session, underlyingQuoteID: underlying.quoteID,
                        right: right, strike: try Money(String(strike)), expiry: expiry, bid: mid, ask: mid,
                        bidSize: 10, askSize: 10, tick: try Money("0.000000000001"), quoteTime: at, receivedAt: at,
                        activity: activity, source: source))
                }
            }
        }
        let calendar = OptionDailyCalendar(id: "SYNTHETIC-DELTA25-SESSION", version: "synthetic-declared-session.v1",
            sessions: [session], source: source)
        let dailyInput = OptionDailyInput(id: dailyID, createdAt: at, asOf: at, session: session, symbol: "DEMO",
            feedID: underlying.feedID, coverage: .complete,
            declaredScope: "SYNTHETIC only: declared expiries, strikes 80 through 120 in steps of 5, both rights; not a market-wide chain",
            underlying: underlying, contracts: contracts, rate: try Money("0.04"), dividendYield: try Money("0.01"),
            source: source, calendar: calendar, sessionCloseAt: at)
        let daily = try OptionDailyEngine.calculate(dailyInput)
        return .init(id: id, createdAt: at, daily: daily)
    }
}
