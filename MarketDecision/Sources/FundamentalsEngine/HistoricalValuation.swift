import Foundation
import CoreDomain
import DataContracts

public struct HistoricalFundamentalSample: Sendable, Codable {
    public let input: FundamentalInput, session: MarketSessionRecord
    public init(input: FundamentalInput, session: MarketSessionRecord) { self.input = input; self.session = session }
}
public struct ValuationPricePoint: Sendable, Codable, Equatable {
    public let percentile: Int, multiple: Money, price: Money
}
public struct HistoricalValuationMetric: Sendable, Codable {
    public let validDays: Int
    public let scorePercentile: Money?
    public let rangePercentile: Money?
    public let prices: [ValuationPricePoint]
    public let unavailable: FundamentalMissing?
    public let position: String?
}
public struct HistoricalValuationResult: Sendable, Codable {
    public let current: FundamentalReport
    public let historyInputs: [HistoricalFundamentalSample]
    public let metrics: [String: HistoricalValuationMetric]
    public let excluded: [String: String]
    public let sourceVersions: [String]
    public let limitations: [String]
    public func recompute(using model: ResolvedModel) throws -> HistoricalValuationResult {
        try HistoricalValuation.calculate(current: current.replayInput(using: model), history: historyInputs,
                                          model: model, executionDate: current.inputSnapshot.executionDate)
    }
}

public enum HistoricalValuation {
    static let metricIDs = ["peMarketCap", "evEBITDA", "priceFCF", "fcfYield"]
    /// Each day is recomputed using its own as-of normalization and same-session close. A receipt
    /// timestamp or unknown availability is insufficient; current raw IEX records cannot qualify.
    public static func calculate(current: FundamentalInput, history: [HistoricalFundamentalSample],
                                 model: ResolvedModel, executionDate: Date) throws -> HistoricalValuationResult {
        let currentReport = try FundamentalCalculator.calculate(current, model:model, executionDate:executionDate)
        var seen: Set<MarketDate> = [], excluded: [String:String] = [:]
        var series: [String:[(MarketDate,Money)]] = [:], sources = current.sourceVersions
        let zone = TimeZone(identifier:"America/New_York")!
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
        let today = try current.priceDay.start(in:zone)
        let first = calendar.date(byAdding:.year,value:-5,to:today)!
        var feed: String?
        let currentFeeds = Set(current.classes.map { $0.priceProvenance.providerID + "/" + $0.priceProvenance.feedID })
        guard currentFeeds.count <= 1 else { throw FundamentalError.incompatibleInput }
        feed = currentFeeds.first
        for sample in history.sorted(by: { $0.input.priceDay < $1.input.priceDay }) {
            let input = sample.input, day = input.priceDay, key = day.iso8601
            guard seen.insert(day).inserted else { throw FundamentalError.duplicateInput }
            guard input.cik == current.cik, input.expectedClassIDs == current.expectedClassIDs,
                  input.financialCompany == current.financialCompany,
                  input.normalization.dictionaryVersion == current.normalization.dictionaryVersion else { throw FundamentalError.incompatibleInput }
            let date = try day.start(in:zone)
            guard day < current.priceDay, date >= first else { excluded[key] = "OUTSIDE_PRIOR_FIVE_YEARS"; continue }
            try sample.session.validate()
            guard sample.session.date == day, [.regular,.earlyClose].contains(sample.session.state),
                  let close = sample.session.closesAt,
                  sample.session.provenance.isAvailable(asOf:close),
                  input.normalization.asOf == close,
                  input.classes.allSatisfy({ $0.priceProvenance.sourceEventAt == close }) else {
                excluded[key] = "SESSION_OR_CLOSE_CUTOFF_UNPROVEN"; continue
            }
            let feeds = Set(input.classes.map { $0.priceProvenance.providerID + "/" + $0.priceProvenance.feedID })
            guard !feeds.isEmpty, feeds.count == 1, feeds.first == feed else {
                excluded[key] = "FEED_MISMATCH_OR_MISSING"; continue
            }
            let report = try FundamentalCalculator.calculate(input,model:model,executionDate:executionDate)
            for id in metricIDs { if let value = report.metrics[id]?.value { series[id,default:[]].append((day,value)) } }
            sources += input.sourceVersions
            if let v = sample.session.provenance.versionID { sources.append(v) }
        }
        var results: [String:HistoricalValuationMetric] = [:]
        for id in metricIDs {
            let values = series[id,default:[]], sorted = values.map(\.1).sorted()
            let v = currentReport.metrics[id]?.value
            let p = try v.map { value in
                try Money(String(sorted.filter { $0 < value }.count)).multiplied(by:"100").divided(by:String(max(1,sorted.count)))
            }
            let twoYears = values.first.flatMap { pair -> Date? in
                guard let start = try? pair.0.start(in:zone) else { return nil }
                return calendar.date(byAdding:.year,value:2,to:start)
            }
            let end = try values.last?.0.start(in:zone)
            let rangeReady = sorted.count >= 504 && twoYears != nil && end != nil && end! >= twoYears!
            var points: [ValuationPricePoint] = []
            var reason: FundamentalMissing? = rangeReady ? nil : .insufficientHistory
            if rangeReady {
                if current.singleCompleteClass == nil { reason = .missingClass }
                else {
                    for rank in [20,50,80] {
                        let multiple = sorted[(rank * sorted.count + 99)/100 - 1]
                        if let price = try inverse(id,multiple:multiple,input:current,report:currentReport), price.amount > 0 {
                            points.append(.init(percentile:rank,multiple:multiple,price:price))
                        }
                    }
                    if points.count != 3 { points = []; reason = .nonpositiveDenominator }
                }
            }
            points.sort { $0.price == $1.price ? $0.percentile < $1.percentile : $0.price < $1.price }
            var position: String?
            if points.count == 3, let price = current.classes.first?.price {
                position = price < points[0].price ? "BELOW_LOW" : price < points[1].price ? "LOW_TO_MIDDLE" : price <= points[2].price ? "MIDDLE_TO_HIGH" : "ABOVE_HIGH"
            }
            results[id] = .init(validDays:sorted.count, scorePercentile:sorted.count >= 252 ? p : nil,
                                rangePercentile:rangeReady ? p : nil, prices:points, unavailable:reason,position:position)
        }
        return .init(current:currentReport,historyInputs:history,metrics:results,excluded:excluded,sourceVersions:Array(Set(sources)).sorted(),
                     limitations:["STRICT_LESS_PERCENTILE; NEAREST_RANK_20_50_80", "NO_MULTICLASS_PRICE_INVERSION_WITHOUT_RATIO_EVIDENCE", "RESEARCH_ONLY_NO_ELIGIBILITY_GRANT"])
    }
    private static func inverse(_ id:String,multiple:Money,input:FundamentalInput,report:FundamentalReport) throws -> Money? {
        guard let shares = input.singleCompleteClass?.shares, report.metrics["marketCap"]?.value != nil else { return nil }
        let m = report.metrics
        switch id {
        case "peMarketCap", "priceFCF":
            guard multiple.amount > 0, let denominator = m[id == "peMarketCap" ? "commonIncome" : "fcf"]?.value,
                  denominator.amount > 0 else { return nil }
            return try fproduct(multiple,denominator).divided(by:shares.decimalString)
        case "evEBITDA":
            guard multiple.amount > 0, let ebitda=m["ebitda"]?.value, ebitda.amount > 0,
                  let ev=m["enterpriseValue"]?.value, let cap=m["marketCap"]?.value else { return nil }
            return try fproduct(multiple,ebitda).subtracting(ev.subtracting(cap)).divided(by:shares.decimalString)
        case "fcfYield":
            guard multiple.amount > 0, let fcf=m["fcf"]?.value, fcf.amount > 0 else { return nil }
            return try fcf.divided(by:fproduct(multiple,shares).decimalString)
        default: return nil
        }
    }
}
