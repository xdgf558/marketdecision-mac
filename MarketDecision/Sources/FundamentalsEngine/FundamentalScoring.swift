import Foundation
import CoreDomain

public struct FundamentalDimensionScore: Sendable, Codable {
    public let value: Money?
    public let leaves: [String:FundamentalMetric]
}
public struct FundamentalScore: Sendable, Codable {
    public let valuation: HistoricalValuationResult
    public let dimensions: [String:FundamentalDimensionScore]
    public let total: Money?
    public let coveredWeightOf84: Int
    public let confidence: FinancialConfidence
    public let limitations: [String]
}
public enum FundamentalScoring {
    public static func calculate(_ input:FundamentalInput, history:[HistoricalFundamentalSample] = [],
                                 model:ResolvedModel, executionDate:Date) throws -> FundamentalScore {
        let valuation = try HistoricalValuation.calculate(current:input,history:history,model:model,executionDate:executionDate)
        let report = valuation.current, m = report.metrics
        var dimensions: [String:FundamentalDimensionScore] = [:]
        var covered = 0
        func dimension(_ name:String,_ leaves:[String:FundamentalMetric]) throws {
            let available = leaves.values.compactMap(\.value)
            covered += available.count * (12 / leaves.count)
            dimensions[name] = .init(value: available.count * 100 >= leaves.count * 70 ? try fmean(available) : nil,leaves:leaves)
        }
        func linear(_ key:String,_ low:String,_ high:String,_ inverse:Bool = false) throws -> FundamentalMetric {
            guard let value = m[key]?.value else { return .init(nil,reason:m[key]?.unavailable ?? .missingInput) }
            return .init(try scale(value,low:low,high:high,inverse:inverse))
        }
        try dimension("growth",["revenue":linear("revenueYoY","-0.10","0.20"),"eps":linear("epsYoY","-0.20","0.30"),"fcf":linear("fcfYoY","-0.20","0.30")])
        try dimension("profitability",["margin":linear("operatingMargin","0","0.30"),"roic":linear("roic","0","0.20"),"roa":linear("roa","0","0.15")])
        let coverage:FundamentalMetric = m["interestCoverage"]?.flags.contains("KNOWN_ZERO_INTEREST") == true
            ? .init(try Money("100"),flags:["KNOWN_ZERO_INTEREST"]) : try linear("interestCoverage","1","8")
        try dimension("balanceSheet",["currentRatio":linear("currentRatio","0.5","2"),"leverage":linear("netDebtEBITDA","0","4",true),"interest":coverage])
        try dimension("cashFlowQuality",["conversion":linear("fcfConversion","0","1"),"margin":linear("fcfMargin","0","0.20"),"sbc":linear("sbcRevenue","0","0.15",true)])
        try dimension("capitalAllocation",["yield":linear("shareholderYield","-0.05","0.08"),"dilution":linear("sharesYoY","-0.02","0.10",true)])
        var valuationLeaves:[String:FundamentalMetric] = [:]
        for id in HistoricalValuation.metricIDs {
            if let percentile = valuation.metrics[id]?.scorePercentile {
                valuationLeaves[id] = .init(id == "fcfYield" ? percentile : try Money("100").subtracting(percentile))
            } else { valuationLeaves[id] = .init(nil,reason:.insufficientHistory) }
        }
        try dimension("valuation",valuationLeaves)
        var positive:Money?, stability:Money?
        if input.quarters.count == 8 {
            let profits = input.quarters.map { input.value(.operatingIncome,type:.quarter,start:$0.start,end:$0.end) }
            let revenues = input.quarters.map { input.value(.revenue,type:.quarter,start:$0.start,end:$0.end) }
            if profits.allSatisfy({$0 != nil}), revenues.allSatisfy({$0 != nil && $0!.amount > 0}) {
                positive = try Money(String(profits.filter {$0!.amount > 0}.count)).multiplied(by:"100").divided(by:"8")
                let margins = try zip(profits,revenues).map { try $0!.divided(by:$1!.decimalString) }
                let mean = try fmean(margins)
                let variance = try fmean(margins.map { value in let delta = try value.subtracting(mean); return try fproduct(delta,delta) })
                stability = try scale(squareRoot(variance),low:"0",high:"0.15",inverse:true)
            }
        }
        try dimension("earningsStability",["positiveQuarters":.init(positive,reason:.insufficientHistory),"marginDeviation":.init(stability,reason:.insufficientHistory)])
        let values = dimensions.values.compactMap(\.value)
        let total = values.count >= 5 && covered * 100 >= 84 * 70 ? try fmean(values) : nil
        let proxy = !input.inputLimitations.isEmpty || report.metrics.values.contains {
            $0.flags.contains("LEASE_RATE_NORMALIZED") || $0.flags.contains("TAX_RATE_STATUTORY") || $0.flags.contains("TAX_RATE_NORMALIZED")
        } || input.normalization.values.contains { $0.confidence != .high }
        let confidence:FinancialConfidence = covered * 100 >= 84 * 90 && !proxy ? .high : covered * 100 >= 84 * 70 ? .medium : .low
        return .init(valuation:valuation,dimensions:dimensions,total:total,coveredWeightOf84:covered,confidence:confidence,
                     limitations:["UNCALIBRATED_HEURISTIC", "COVERAGE_NOT_PROBABILITY", "RESEARCH_ONLY_NO_ELIGIBILITY_GRANT"])
    }
    static func scale(_ x:Money,low:String,high:String,inverse:Bool = false) throws -> Money {
        let lo = try Money(low), hi = try Money(high)
        let bounded = min(max(x,lo),hi)
        let score = try bounded.subtracting(lo).multiplied(by:"100").divided(by:hi.subtracting(lo).decimalString)
        return inverse ? try Money("100").subtracting(score) : score
    }
    /// Population standard deviation. Decimal Newton iteration, explicit 18-place convergence.
    /// Large values/overflow propagate as errors instead of switching silently to Double.
    static func squareRoot(_ value:Money) throws -> Money {
        guard value.amount >= 0 else { throw FundamentalError.incompatibleInput }
        if value.amount == 0 { return value }
        var x = max(value,try Money("1"))
        let tolerance = try Money("0.000000000000000001")
        for _ in 0..<512 {
            let next = try x.adding(value.divided(by:x.decimalString)).divided(by:"2")
            let difference = try next.subtracting(x)
            if difference >= (try tolerance.multiplied(by:"-1")) && difference <= tolerance { return next }
            x = next
        }
        throw FundamentalError.incompatibleInput
    }
}
