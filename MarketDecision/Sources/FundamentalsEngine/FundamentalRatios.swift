import Foundation
import CoreDomain
import DataContracts

public enum FundamentalCalculator {
    public static func calculate(_ input: FundamentalInput, model: ResolvedModel, executionDate: Date) throws -> FundamentalReport {
        try FundamentalModelV1.validate(model, executionDate: executionDate); try input.validate()
        guard input.normalization.asOf <= executionDate else { throw FundamentalError.incompatibleInput }
        var m: [String: FundamentalMetric] = [:]
        let revenue = try input.flow(.revenue), op = try input.flow(.operatingIncome)
        let net = try input.flow(.netIncome), common = try input.flow(.commonIncome)
        let ocf = try input.flow(.ocf), capex = try input.flow(.capex), sbc = try input.flow(.sbc)
        let fcf = try difference(ocf, nonnegative: capex)
        let exSBC = try difference(fcf, nonnegative: sbc)
        let depreciation = try input.flow(.depreciation)
        let ebitda = try addition(op, nonnegative: depreciation)
        let eps = try input.flow(.dilutedEPS)
        m["revenue"] = .init(revenue); m["operatingIncome"] = .init(op)
        m["commonIncome"] = .init(common); m["netIncome"] = .init(net)
        m["fcf"] = .init(fcf); m["fcfExSBC"] = .init(exSBC); m["ebitda"] = .init(ebitda)
        m["dilutedEPSQuarterSum"] = .init(eps, flags: ["QUARTER_SUM_NOT_ANNUAL_WEIGHTED_SHARES"])
        for (key, numerator) in [("grossMargin", try input.flow(.grossProfit)), ("operatingMargin", op),
                                  ("netMargin", net), ("fcfMargin", fcf), ("fcfExSBCMargin", exSBC), ("sbcRevenue", sbc)] {
            m[key] = try fratio(numerator, revenue)
        }
        m["fcfConversion"] = try fratio(fcf, net)
        m["currentRatio"] = try fratio(input.instant(.currentAssets), input.instant(.currentLiabilities))
        let balanceDates = [try input.quarters.suffix(4).first!.start.addingDays(-1)] + input.quarters.suffix(4).map(\.end)
        func meanBalance(_ field: FundamentalField) throws -> Money? {
            let values = balanceDates.map { input.instant(field, end: $0) }
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return try fmean(values.map { $0! })
        }
        m["roa"] = try fratio(net, meanBalance(.assets))
        m["roe"] = try fratio(common, meanBalance(.commonEquity))
        let debt = try totalDebt(input, at: input.quarters.last!.end)
        m["debt"] = .init(debt)
        let netDebt = try subtract(debt, input.instant(.cash))
        m["netDebt"] = .init(netDebt)
        m["debtEquity"] = try fratio(debt, input.instant(.totalEquity))
        m["netDebtEBITDA"] = input.financialCompany ? .init(nil, reason: .notApplicable) : try fratio(netDebt, ebitda)
        let interest = try input.flow(.interest)
        if let interest, interest.amount == 0 {
            m["interestCoverage"] = .init(nil, reason: .notApplicable, flags: ["KNOWN_ZERO_INTEREST"])
        } else { m["interestCoverage"] = try fratio(op, interest) }
        let tax = try normalizedTax(input)
        m["normalizedTax"] = tax
        var icValues: [Money] = []
        for day in balanceDates {
            if let d = try totalDebt(input, at: day), let eq = input.instant(.totalEquity, end: day),
               let cash = input.instant(.cash, end: day) {
                let ic = try d.adding(eq).subtracting(cash)
                if ic.amount > 0 { icValues.append(ic) }
            }
        }
        let leaseMean = try meanBalance(.operatingLease)
        let disclosedRate = input.instant(.leaseRate)
        let rate = try disclosedRate ?? Money("0.05")
        let rateValid = rate.amount >= 0 && rate.amount <= 1
        m["leaseRate"] = .init(rateValid ? rate : nil, flags: disclosedRate == nil ? ["LEASE_RATE_NORMALIZED"] : [])
        var nopat: Money?
        if let op, let leaseMean, leaseMean.amount >= 0, let tax = tax.value, rateValid {
            nopat = try fproduct(op.adding(fproduct(leaseMean, rate)), Money("1").subtracting(tax))
        }
        m["nopat"] = .init(nopat)
        m["roic"] = input.financialCompany ? .init(nil, reason: .notApplicable)
            : try fratio(nopat, icValues.count == 5 ? fmean(icValues) : nil)
        var cap: Money?
        let completeClasses = input.hasCompleteClasses
        if completeClasses { cap = try fsum(input.classes.map { try fproduct($0.price, $0.shares) }) }
        m["marketCap"] = .init(cap, reason: .missingClass)
        var ev: Money?
        if let cap, let debt, let preferred = input.instant(.preferred), let nci = input.instant(.nci), let cash = input.instant(.cash),
           preferred.amount >= 0, nci.amount >= 0, cash.amount >= 0 {
            ev = try cap.adding(debt).adding(preferred).adding(nci).subtracting(cash)
        }
        m["enterpriseValue"] = .init(ev, flags: ["LEASES_INCLUDED_NOT_EBITDAR"])
        for (key, numerator, denominator) in [("peMarketCap",cap,common), ("priceBook",cap,input.instant(.commonEquity)),
            ("priceSales",cap,revenue), ("priceFCF",cap,fcf), ("priceFCFExSBC",cap,exSBC), ("evEBITDA",ev,ebitda),
            ("evSales",ev,revenue), ("fcfYield",fcf,cap), ("fcfExSBCYield",exSBC,cap), ("earningsYield",common,cap)] {
            m[key] = try fratio(numerator,denominator)
        }
        // EPS is class-specific. A consolidated EPS cannot price multiple distinct share classes.
        m["peEPS"] = input.singleCompleteClass != nil ? try fratio(input.singleCompleteClass!.price, eps) : .init(nil, reason: .missingClass)
        let netBuybacks = try difference(input.flow(.buybacks), nonnegative: input.flow(.issuance))
        let shareholderCash = try addition(netBuybacks, nonnegative: input.flow(.dividends))
        m["netBuybacks"] = .init(netBuybacks); m["shareholderYield"] = try fratio(shareholderCash, cap)
        if input.quarters.count == 8 {
            let oldWindow = input.quarters.prefix(4)
            let oldFCF = try difference(input.flow(.ocf, window: oldWindow), nonnegative: input.flow(.capex, window: oldWindow))
            let currentDays = try input.quarters[4].start.days(through: input.quarters[7].end).count
            let oldDays = try input.quarters[0].start.days(through: input.quarters[3].end).count
            for (key,current,prior) in [("revenueYoY",revenue,try input.flow(.revenue, window: oldWindow)),
                ("netIncomeYoY",net,try input.flow(.netIncome, window: oldWindow)),
                ("epsYoY",eps,try input.flow(.dilutedEPS, window: oldWindow)), ("fcfYoY",fcf,oldFCF)] {
                m[key] = try growth(current, prior, comparable: abs(currentDays-oldDays) <= 7)
                m[key+"Change"] = .init(try subtract(current,prior))
            }
            m["sharesYoY"] = try growth(input.instant(.actualShares), input.instant(.actualShares, end: input.quarters[3].end),
                                         comparable: input.splitBasisEvidence?.isEmpty == false)
        } else {
            for key in ["revenueYoY","netIncomeYoY","epsYoY","fcfYoY","sharesYoY"] { m[key] = .init(nil, reason: .insufficientHistory) }
        }
        let currentRatios = try input.quarters.suffix(4).map {
            try fratio(input.instant(.currentAssets, end: $0.end), input.instant(.currentLiabilities, end: $0.end)).value
        }
        if currentRatios.allSatisfy({ $0 != nil }) {
            var slope = try Money("0")
            for (index,v) in currentRatios.enumerated() {
                slope = try slope.adding(v!.multiplied(by: ["-1.5","-0.5","0.5","1.5"][index]))
            }
            slope = try slope.divided(by: "5")
            m["liquidityTrend"] = .init(slope, flags: [slope.amount >= Decimal(string:"0.05")! ? "IMPROVING" : slope.amount <= Decimal(string:"-0.05")! ? "DETERIORATING" : "STABLE"])
        } else { m["liquidityTrend"] = .init(nil) }
        let limitations = Array(Set(input.inputLimitations + input.normalization.values.flatMap(\.limitations)
            + ["RESEARCH_ONLY_NO_ELIGIBILITY_GRANT", "FIELD_COVERAGE_IS_NOT_TAXONOMY_ACCEPTANCE"])).sorted()
        return FundamentalReport(inputSnapshot: try FundamentalInputSnapshot(input: input, executionDate: executionDate),
            model: model.definition.reference,
            parameters: model.parameters.reference, limitations: limitations, metrics: m,
            confidence: input.normalization.values.contains { $0.confidence == .low } ? .low : .medium, researchOnly: true)
    }
    private static func subtract(_ a: Money?, _ b: Money?) throws -> Money? {
        guard let a, let b else { return nil }; return try a.subtracting(b)
    }
    private static func difference(_ a: Money?, nonnegative b: Money?) throws -> Money? {
        guard let b, b.amount >= 0 else { return nil }; return try subtract(a,b)
    }
    private static func addition(_ a: Money?, nonnegative b: Money?) throws -> Money? {
        guard let a, let b, b.amount >= 0 else { return nil }; return try a.adding(b)
    }
    private static func growth(_ current: Money?, _ prior: Money?, comparable: Bool) throws -> FundamentalMetric {
        guard comparable else { return .init(nil, reason: .notComparable) }
        guard let current, let prior else { return .init(nil) }
        guard prior.amount > 0 else {
            let label = prior.amount < 0 ? (current.amount > 0 ? "LOSS_TO_PROFIT" : current.amount == 0 ? "LOSS_TO_ZERO" : "REMAINED_LOSS")
                : (current.amount > 0 ? "ZERO_TO_POSITIVE" : current.amount < 0 ? "ZERO_TO_LOSS" : "REMAINED_ZERO")
            return .init(nil, reason: .nonpositiveDenominator, flags: [label])
        }
        return try fratio(current.subtracting(prior),prior)
    }
    private static func totalDebt(_ input: FundamentalInput, at day: MarketDate) throws -> Money? {
        let slots: [FundamentalField] = [.shortDebt,.currentDebt,.longDebt,.financeLease,.operatingLease]
        let v = slots.map { input.instant($0,end:day) }
        guard v.allSatisfy({ $0 != nil && $0!.amount >= 0 }) else { return nil }
        return try fsum(v.map { $0! })
    }
    private static func normalizedTax(_ input: FundamentalInput) throws -> FundamentalMetric {
        guard !input.fiscalYears.isEmpty else { return .init(nil) }
        var rates: [Money] = []
        for year in input.fiscalYears {
            guard let pretax = input.value(.pretaxIncome, type:.annual,start:year.start,end:year.end) else { return .init(nil) }
            if pretax.amount > 0 {
                guard let tax = input.value(.tax,type:.annual,start:year.start,end:year.end) else { return .init(nil) }
                rates.append(try tax.divided(by:pretax.decimalString))
            }
        }
        if rates.isEmpty {
            guard input.fiscalYears.count == 3 else { return .init(nil) }
            return .init(try Money("0.21"),flags:["TAX_RATE_STATUTORY"])
        }
        rates.sort(); let count = rates.count
        let raw = count % 2 == 1 ? rates[count/2] : try fmean([rates[count/2-1],rates[count/2]])
        let result = min(max(raw,try Money("0")),try Money("0.35"))
        return .init(result,flags:(rates.count < 3 ? ["TAX_COVERAGE_\(rates.count)_OF_3"] : []) + (result != raw ? ["TAX_RATE_NORMALIZED"] : []))
    }
}
