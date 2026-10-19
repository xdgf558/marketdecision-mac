import Foundation
import CoreDomain

/// Fixed synthetic observations. Weekdays are a declared fixture calendar, not an
/// exchange calendar. Weekly history deliberately remains below 252 observations.
public enum MarketStateDemo {
    public static func input(sessionCount: Int = 800) throws -> MarketStateInput {
        guard (1...1400).contains(sessionCount), let end=MarketStateEngine.parseDay("2026-10-19") else { throw MarketStateError.invalidInput }
        var date=end
        var sessions:[MarketTradingSession]=[]
        while sessions.count<sessionCount {
            let weekday=MarketStateEngine.utcCalendar.component(.weekday,from:date)
            if weekday != 1 && weekday != 7 {
                sessions.append(.init(date:MarketStateEngine.dayText(date),closeAt:date.addingTimeInterval(21*3600)))
            }
            date=date.addingTimeInterval(-86400)
        }
        sessions.reverse()
        let series = try MarketSeriesKey.allCases.enumerated().map { keyIndex,key -> MarketSeries in
            let weekly = key == .naaim || key == .assetManagerNetOverOI || key == .leveragedFundsNetOverOI
            let observations = try sessions.enumerated().compactMap { index,session -> MarketObservation? in
                if weekly && index % 5 != 0 { return nil }
                let t=Double(index),phase=Double(keyIndex)*0.37
                let value:Double
                switch key {
                case .spyPrice,.qqqPrice,.iwmPrice,.rspPrice:
                    value=100+0.065*t+7*sin(t/33+phase)+2*cos(t/7+phase)
                case .spyTotalReturn,.rspTotalReturn,.iwmTotalReturn,.hygTotalReturn,.iefTotalReturn,.lqdTotalReturn:
                    value=100+0.04*t+4*sin(t/45+phase)+cos(t/13+phase)
                case .spyVolume: value=1_000_000+120_000*sin(t/17)+t*400
                case .spyRelativeSpread,.hygRelativeSpread: value=0.002+0.0007*sin(t/21+phase)
                case .advancingFraction,.aboveMA50Fraction,.aboveMA200Fraction,.advancingVolumeFraction:
                    value=0.5+0.32*sin(t/41+phase)
                case .newHighMinusLowFraction: value=0.12*sin(t/23)
                case .vix: value=20+6*sin(t/39)+2*cos(t/9)
                case .vix3m: value=22+4*sin(t/41)
                case .highYieldOAS: value=350+100*sin(t/52)+20*cos(t/7)
                case .totalPutCall,.indexPutCall,.etfPutCall,.equityPutCall: value=0.9+0.25*sin(t/27+phase)
                case .put25MinusATM30: value=0.04+0.018*sin(t/31)
                case .naaim: value=50+40*sin(t/51)
                case .assetManagerNetOverOI,.leveragedFundsNetOverOI: value=0.2*sin(t/43+phase)
                }
                let text=String(format:"%.10f",locale:Locale(identifier:"en_US_POSIX"),value)
                return .init(observationID:"SYNTHETIC-\(key.rawValue)-\(session.date)",vintageID:"SYNTHETIC-\(key.rawValue)-\(session.date)-v1",
                    observationDate:session.date,releasedAt:session.closeAt,availableAt:session.closeAt,
                    value:try Money(text),rawValue:text)
            }
            let population:String?
            switch key {
            case .totalPutCall: population="SYNTHETIC-total-options"
            case .indexPutCall: population="SYNTHETIC-index-options"
            case .etfPutCall: population="SYNTHETIC-etf-options"
            case .equityPutCall: population="SYNTHETIC-equity-options"
            case .assetManagerNetOverOI,.leveragedFundsNetOverOI: population="SYNTHETIC-equity-index-futures"
            default: population=key.requiresPopulation ? "SYNTHETIC-breadth-universe" : nil
            }
            return .init(key:key,unit:key.unit,frequency:weekly ? .weekly:.daily,origin:.synthetic,
                sourceID:"SYNTHETIC-market-source",feedID:"SYNTHETIC-market-feed",methodology:"Synthetic deterministic formula; not vendor observations. Price=split-adjusted; TR=total return; put skew=declared same-tenor 30-day put25 minus ATM.",
                population:population,basisVersion:key.unit == .totalReturnIndex ? "SYNTHETIC-TR-v1":"SYNTHETIC-split-adjusted-v1",observations:observations)
        }
        guard let last=sessions.last else { throw MarketStateError.invalidInput }
        return .init(id:UUID(uuidString:"40000000-2026-4019-8000-000000000003")!,createdAt:last.closeAt,
            asOf:last.closeAt,sessionDate:last.date,sessions:sessions,
            calendarEvidence:"SYNTHETIC-weekdays-only.v1; explicitly not an exchange calendar",series:series)
    }
}
