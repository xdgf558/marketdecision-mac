import Foundation
import CryptoKit
import CoreDomain

extension MarketStateEngine {
    struct Atom {
        let id: String
        let formula: Formula
        let percentile: Bool
        let reverse: Bool
        init(_ id: String, _ formula: Formula, percentile: Bool = true, reverse: Bool = false) {
            self.id = id; self.formula = formula; self.percentile = percentile; self.reverse = reverse
        }
    }
    struct Component {
        let kind: MarketScoreKind
        let id: String
        let title: String
        let weight: Int
        let atoms: [Atom]
    }
    enum Formula {
        case direct(MarketSeriesKey)
        case trend(MarketSeriesKey, Int)
        case momentum(MarketSeriesKey, Int)
        case relativeMomentum(MarketSeriesKey, MarketSeriesKey, Int)
        case volumeRatio
        case ratio(MarketSeriesKey, MarketSeriesKey)
        case realizedVolatility(Int)
        case realizedVolatilityRatio
        case drawdown
        case negativeReturn(Int)
    }
    static var components: [Component] {
        let trend = [MarketSeriesKey.spyPrice,.qqqPrice,.iwmPrice].flatMap { key in
            [20,50,200].map { Atom("trend.\(key.rawValue).\($0)", .trend(key, $0)) }
        }
        let momentum = [MarketSeriesKey.spyPrice,.qqqPrice,.iwmPrice,.rspPrice].flatMap { key in
            [21,63,126].map { Atom("momentum.\(key.rawValue).\($0)", .momentum(key, $0)) }
        }
        return [
            .init(kind: .heat, id: "heat.trend", title: "趋势", weight: 3000, atoms: trend),
            .init(kind: .heat, id: "heat.breadth", title: "广度", weight: 2500, atoms: [
                .init("breadth.advancing", .direct(.advancingFraction), percentile: false),
                .init("breadth.ma50", .direct(.aboveMA50Fraction), percentile: false),
                .init("breadth.ma200", .direct(.aboveMA200Fraction), percentile: false),
                .init("breadth.highLow", .direct(.newHighMinusLowFraction))]),
            .init(kind: .heat, id: "heat.momentum", title: "动量", weight: 1500, atoms: momentum),
            .init(kind: .heat, id: "heat.riskAppetite", title: "风险偏好", weight: 1500, atoms: [
                .init("appetite.rspSpy63", .relativeMomentum(.rspTotalReturn,.spyTotalReturn,63)),
                .init("appetite.iwmSpy63", .relativeMomentum(.iwmTotalReturn,.spyTotalReturn,63)),
                .init("appetite.hygIef63", .relativeMomentum(.hygTotalReturn,.iefTotalReturn,63))]),
            .init(kind: .heat, id: "heat.liquidity", title: "成交与流动性", weight: 1500, atoms: [
                .init("liquidity.volume", .volumeRatio),
                .init("liquidity.spread", .direct(.spyRelativeSpread), reverse: true),
                .init("liquidity.upVolume", .direct(.advancingVolumeFraction), percentile: false)]),
            .init(kind: .stress, id: "stress.implied", title: "隐含波动", weight: 3000, atoms: [.init("stress.vix",.direct(.vix))]),
            .init(kind: .stress, id: "stress.term", title: "期限结构", weight: 2000, atoms: [.init("stress.termRatio",.ratio(.vix,.vix3m))]),
            .init(kind: .stress, id: "stress.realized", title: "实现波动冲击", weight: 1500, atoms: [
                .init("stress.rvRatio",.realizedVolatilityRatio), .init("stress.rv20",.realizedVolatility(20))]),
            .init(kind: .stress, id: "stress.drawdown", title: "回撤与下跌", weight: 1500, atoms: [
                .init("stress.drawdown252",.drawdown), .init("stress.down5",.negativeReturn(5)), .init("stress.down20",.negativeReturn(20))]),
            .init(kind: .stress, id: "stress.credit", title: "信用", weight: 2000, atoms: [
                .init("credit.oas",.direct(.highYieldOAS)),
                .init("credit.hygLqd63",.relativeMomentum(.hygTotalReturn,.lqdTotalReturn,63),reverse:true),
                .init("credit.spread",.direct(.hygRelativeSpread))]),
            .init(kind: .sentiment, id: "sentiment.putCall", title: "Put/Call", weight: 3000, atoms: [
                .init("pcr.total",.direct(.totalPutCall),reverse:true), .init("pcr.index",.direct(.indexPutCall),reverse:true),
                .init("pcr.etf",.direct(.etfPutCall),reverse:true), .init("pcr.equity",.direct(.equityPutCall),reverse:true)]),
            .init(kind: .sentiment, id: "sentiment.skew", title: "30日期权偏斜", weight: 2000,
                atoms:[.init("sentiment.put25MinusATM30",.direct(.put25MinusATM30),reverse:true)]),
            .init(kind: .sentiment, id: "sentiment.exposure", title: "主动管理人暴露", weight: 1500,
                atoms:[.init("sentiment.naaim",.direct(.naaim))]),
            .init(kind: .sentiment, id: "sentiment.positioning", title: "期货持仓", weight: 1500, atoms:[
                .init("tff.assetManager",.direct(.assetManagerNetOverOI)),.init("tff.leveragedFunds",.direct(.leveragedFundsNetOverOI))]),
            .init(kind: .sentiment, id: "sentiment.internal", title: "市场内部结构", weight: 2000, atoms:[
                .init("internal.rspSpy21",.relativeMomentum(.rspTotalReturn,.spyTotalReturn,21)),
                .init("internal.upVolume",.direct(.advancingVolumeFraction),percentile:false),
                .init("internal.iwmSpy21",.relativeMomentum(.iwmTotalReturn,.spyTotalReturn,21))])
        ]
    }
    struct Raw {
        let value: Double?
        let identity: String
        let references: [String]
        let reason: MarketMissingReason?
        let windows: [MarketObservationWindow]
        init(value: Double?, identity: String, references: [String], reason: MarketMissingReason?, windows: [MarketObservationWindow] = []) {
            self.value=value;self.identity=identity;self.references=references;self.reason=reason;self.windows=windows
        }
        static func missing(_ reason: MarketMissingReason) -> Raw { .init(value:nil,identity:"",references:[],reason:reason) }
    }

    /// The index groups exact source dates and versions once. Rolling windows read
    /// the version available at the formula's cutoff, not the last row in storage.
    final class Reader {
        let input: MarketStateInput
        let series: [MarketSeriesKey: MarketSeries]
        let dates: [MarketSeriesKey: [String]]
        let rows: [MarketSeriesKey: [String: [MarketObservation]]]
        let sessionIndex: [String: Int]
        init(_ input: MarketStateInput) {
            self.input = input
            self.series = Dictionary(uniqueKeysWithValues: input.series.map { ($0.key,$0) })
            self.rows = Dictionary(uniqueKeysWithValues: input.series.map { item in
                (item.key, Dictionary(grouping: item.observations,by: \.observationDate).mapValues { $0.sorted { $0.availableAt < $1.availableAt } })
            })
            self.dates = Dictionary(uniqueKeysWithValues: input.series.map { ($0.key,Array(Set($0.observations.map(\.observationDate))).sorted()) })
            self.sessionIndex = Dictionary(uniqueKeysWithValues: input.sessions.enumerated().map { ($0.element.date,$0.offset) })
        }
        func exact(_ key: MarketSeriesKey, _ index: Int, _ cutoff: Date) -> MarketObservation? {
            guard index >= 0, index < input.sessions.count else { return nil }
            return selected(key,date: input.sessions[index].date,cutoff: cutoff)
        }
        func selected(_ key: MarketSeriesKey, date: String, cutoff: Date) -> MarketObservation? {
            rows[key]?[date]?.last { $0.availableAt <= cutoff && $0.releasedAt <= cutoff }
        }
        func direct(_ key: MarketSeriesKey, index: Int, cutoff: Date) -> Raw {
            guard let source = series[key] else { return .missing(.missingSeries) }
            let target = input.sessions[index].date
            guard let days = dates[key] else { return .missing(.unavailableVintage) }
            // Binary search the right edge before walking unavailable future revisions.
            var lower = 0, upper = days.count
            while lower < upper { let mid = (lower+upper)/2; if days[mid] <= target { lower=mid+1 } else { upper=mid } }
            guard lower > 0 else { return .missing(.unavailableVintage) }
            for i in stride(from:lower-1,through:0,by:-1) {
                guard let observation = selected(key,date:days[i],cutoff:cutoff) else { continue }
                let stale: Bool
                switch source.frequency {
                case .daily:
                    guard let observedIndex = sessionIndex[observation.observationDate], observedIndex <= index else {
                        return .missing(.insufficientWindow)
                    }
                    stale = index - observedIndex > 3
                case .weekly:
                    guard let observedDay = MarketStateEngine.parseDay(observation.observationDate), let targetDay = MarketStateEngine.parseDay(target) else { return .missing(.unavailableVintage) }
                    stale = targetDay.timeIntervalSince(observedDay) > 10*86400
                case .releaseCycle:
                    stale = observation.validUntil.map { cutoff > $0 } ?? true
                }
                if stale { return .missing(.stale) }
                return raw(observation,key:key)
            }
            return .missing(.unavailableVintage)
        }
        func raw(_ observation: MarketObservation, key: MarketSeriesKey) -> Raw {
            let identity = key.rawValue + ":" + String(observation.observationID.utf8.count) + ":" + observation.observationID
            return .init(value:NSDecimalNumber(decimal:observation.value.amount).doubleValue, identity:identity,
                references:[key.rawValue + ":" + observation.observationID + "@" + observation.vintageID], reason:nil)
        }
        func window(_ key: MarketSeriesKey, index: Int, count: Int, cutoff: Date) -> [MarketObservation]? {
            guard index+1 >= count else { return nil }
            let values = ((index-count+1)...index).compactMap { exact(key,$0,cutoff) }
            return values.count == count ? values : nil
        }
        func number(_ item: MarketObservation) -> Double { NSDecimalNumber(decimal:item.value.amount).doubleValue }
        func consumed(_ key: MarketSeriesKey, _ points: [MarketObservation]) -> MarketObservationWindow {
            var bytes=Data()
            for point in points {
                for field in [key.rawValue,point.observationID,point.vintageID,point.observationDate] {
                    let data=Data(field.utf8); bytes.append(Data("\(data.count):".utf8));bytes.append(data)
                }
            }
            let digest=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
            return .init(series:key,firstDate:points.first?.observationDate ?? "",lastDate:points.last?.observationDate ?? "",sessionCount:points.count,memberIdentitySHA256:digest)
        }
        func result(_ value: Double, _ observations: [(MarketSeriesKey,MarketObservation)], windows: [MarketObservationWindow] = []) -> Raw {
            guard value.isFinite else { return .missing(.nonFinite) }
            let roots = observations.map { raw($0.1,key:$0.0) }
            return .init(value:value,identity:roots.map { String($0.identity.utf8.count)+":"+$0.identity }.joined(),
                references:Array(Set(roots.flatMap(\.references))).sorted(),reason:nil,windows:windows)
        }
        func evaluate(_ formula: Formula, index: Int, cutoff: Date) -> Raw {
            switch formula {
            case let .direct(key): return direct(key,index:index,cutoff:cutoff)
            case let .trend(key,length):
                guard let points = window(key,index:index,count:length,cutoff:cutoff), let last=points.last else { return .missing(.insufficientWindow) }
                let mean=points.reduce(0) { $0+number($1) }/Double(length)
                guard mean>0 else { return .missing(.invalidDenominator) }
                return result(number(last)/mean-1,[(key,last)],windows:[consumed(key,points)])
            case let .momentum(key,length): return momentum(key,index:index,length:length,cutoff:cutoff)
            case let .relativeMomentum(a,b,length):
                guard let sa=series[a],let sb=series[b] else { return .missing(.missingSeries) }
                guard sa.basisVersion==sb.basisVersion, sa.unit == .totalReturnIndex, sb.unit == .totalReturnIndex else { return .missing(.incompatibleBasis) }
                guard let aw=window(a,index:index,count:length+1,cutoff:cutoff),let bw=window(b,index:index,count:length+1,cutoff:cutoff),
                      let a0=aw.first,let at=aw.last,let b0=bw.first,let bt=bw.last else { return .missing(.insufficientWindow) }
                return result((number(at)/number(bt))/(number(a0)/number(b0))-1,[(a,at),(b,bt)],windows:[consumed(a,aw),consumed(b,bw)])
            case .volumeRatio:
                guard let values=window(.spyVolume,index:index,count:20,cutoff:cutoff),let last=values.last else { return .missing(.insufficientWindow) }
                let mean=values.reduce(0) { $0+number($1) }/20
                guard mean>0 else { return .missing(.invalidDenominator) }
                return result(number(last)/mean,[(.spyVolume,last)],windows:[consumed(.spyVolume,values)])
            case let .ratio(a,b):
                let ra=direct(a,index:index,cutoff:cutoff),rb=direct(b,index:index,cutoff:cutoff)
                guard let av=ra.value,let bv=rb.value else { return .missing(ra.reason ?? rb.reason ?? .unavailableVintage) }
                guard bv>0 else { return .missing(.invalidDenominator) }
                // VIX and VIX3M must have one observation date, never a current/old mixture.
                guard let oa=exact(a,index,cutoff),let ob=exact(b,index,cutoff) else { return .missing(.insufficientWindow) }
                return result(av/bv,[(a,oa),(b,ob)])
            case let .realizedVolatility(length): return realizedVolatility(index:index,length:length,cutoff:cutoff)
            case .realizedVolatilityRatio:
                let a=realizedVolatility(index:index,length:5,cutoff:cutoff), b=realizedVolatility(index:index,length:20,cutoff:cutoff)
                guard let av=a.value,let bv=b.value else { return .missing(a.reason ?? b.reason ?? .insufficientWindow) }
                guard bv>0 else { return .missing(.invalidDenominator) }
                return .init(value:av/bv,identity:a.identity,references:a.references,reason:nil,windows:b.windows)
            case .drawdown:
                guard let prices=window(.spyPrice,index:index,count:252,cutoff:cutoff), let last=prices.last,
                      let high=prices.map(number).max(),high>0 else { return .missing(.insufficientWindow) }
                return result(1-number(last)/high,[(.spyPrice,last)],windows:[consumed(.spyPrice,prices)])
            case let .negativeReturn(length):
                let value=momentum(.spyPrice,index:index,length:length,cutoff:cutoff)
                return .init(value:value.value.map { -$0 },identity:value.identity,references:value.references,reason:value.reason,windows:value.windows)
            }
        }
        func momentum(_ key: MarketSeriesKey,index:Int,length:Int,cutoff:Date) -> Raw {
            guard let prices=window(key,index:index,count:length+1,cutoff:cutoff),let first=prices.first,let last=prices.last else { return .missing(.insufficientWindow) }
            guard number(first)>0 else { return .missing(.invalidDenominator) }
            return result(number(last)/number(first)-1,[(key,last)],windows:[consumed(key,prices)])
        }
        func realizedVolatility(index:Int,length:Int,cutoff:Date) -> Raw {
            guard let prices=window(.spyPrice,index:index,count:length+1,cutoff:cutoff),let last=prices.last else { return .missing(.insufficientWindow) }
            let values=prices.map(number)
            let logs=zip(values.dropFirst(),values).map { log($0.0/$0.1) }
            let mean=logs.reduce(0,+)/Double(logs.count)
            let variance=logs.reduce(0) { $0+($1-mean)*($1-mean) }/Double(logs.count-1)
            return result(sqrt(variance)*sqrt(252),[(.spyPrice,last)],windows:[consumed(.spyPrice,prices)])
        }
    }
}
