import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics

@Suite struct OptionPricingTests {
    @Test func fixedAnalyticPricesAndPutCallParity() throws {
        let call = OptionBSM.evaluate(market(.call), volatility: 0.2)
        let put = OptionBSM.evaluate(market(.put), volatility: 0.2)
        #expect(call.state == .available && put.state == .available)
        #expect(abs(try #require(call.price) - 10.450583572185565) < 1e-10)
        #expect(abs(try #require(put.price) - 5.573526022256971) < 1e-10)
        #expect(abs(try #require(call.price) - #require(put.price) - (100 - 100 * exp(-0.05))) < 1e-12)
    }

    @Test func finiteDifferencesVerifyGreekSignAndPercentagePointUnits() throws {
        for right in [OptionLabRight.call, .put] {
            let m = market(right, rate: -0.01, q: 0.03), sigma = 0.27
            let result = OptionBSM.evaluate(m, volatility: sigma), g = try #require(result.greeks), h = 0.001
            func price(_ s: Double = 100, _ r: Double = -0.01, _ t: Double = 1, _ v: Double = 0.27) throws -> Double {
                try #require(OptionBSM.evaluate(market(right, spot: s, rate: r, q: 0.03, t: t), volatility: v).price)
            }
            let delta = try (price(100+h)-price(100-h))/(2*h)
            let gamma = try (price(100+h)-2*price()+price(100-h))/(h*h)
            let theta = try -(price(100,-0.01,1+1e-5)-price(100,-0.01,1-1e-5))/(2e-5)/365
            let vega = try (price(100,-0.01,1,sigma+1e-5)-price(100,-0.01,1,sigma-1e-5))/(2e-5)/100
            let rho = try (price(100,-0.01+1e-5)-price(100,-0.01-1e-5))/(2e-5)/100
            #expect(abs(g.delta-delta)<1e-8)
            #expect(abs(g.gamma-gamma)<1e-7)
            #expect(abs(g.thetaPerDay-theta)<1e-8)
            #expect(abs(g.vegaPerPercentagePoint-vega)<1e-8)
            #expect(abs(g.rhoPerPercentagePoint-rho)<1e-8)
        }
    }

    @Test func riskNeutralITMIsNotDelta() throws {
        let result = OptionBSM.evaluate(market(.call, q: 0.04), volatility: 0.6)
        let probability = try #require(result.itmProbability), greek = try #require(result.greeks)
        let d2 = (log(100.0/100) + (0.05 - 0.04 - 0.5*0.6*0.6))/0.6
        #expect(abs(probability - 0.5*erfc(-d2/sqrt(2)))<1e-14)
        #expect(abs(abs(greek.delta)-probability)>0.1)
    }

    @Test func zeroVolatilitySpotAndExpiryHaveExplicitBoundaryStates() throws {
        let deterministic = OptionBSM.evaluate(market(.call, q: 0.02), volatility: 0)
        #expect(deterministic.state == .zeroVolatilityBoundary && deterministic.greeks == nil)
        #expect(abs(try #require(deterministic.price) - (100*exp(-0.02)-100*exp(-0.05)))<1e-12)
        let zeroSpot = OptionBSM.evaluate(market(.put, spot: 0, rate: -0.01), volatility: 0.2)
        #expect(zeroSpot.state == .zeroSpotBoundary && zeroSpot.greeks == nil && zeroSpot.itmProbability == 1)
        #expect(abs(try #require(zeroSpot.price)-100*exp(0.01))<1e-12)
        let expiry = OptionBSM.evaluate(market(.call, spot: 123, t: 0), volatility: 0.2)
        #expect(expiry.state == .expiryBoundary && expiry.price == 23 && expiry.greeks == nil)
        let atStrikeZero = OptionBSM.evaluate(market(.put, rate: 0), volatility: 0)
        #expect(atStrikeZero.price == 0 && atStrikeZero.itmProbability == 0)
    }

    @Test(arguments: ["negativeSpot","zeroStrike","negativeT","negativeQ","nonfinite","negativeSigma","overflow"])
    func rejectsInvalidAndUnsafeNumericInputs(_ kind: String) {
        let m: OptionBSMMarket, sigma: Double
        switch kind {
        case "negativeSpot": m=market(.call,spot:-1); sigma=0.2
        case "zeroStrike": m=market(.call,strike:0); sigma=0.2
        case "negativeT": m=market(.call,t:-1); sigma=0.2
        case "negativeQ": m=market(.call,q:-0.01); sigma=0.2
        case "nonfinite": m=market(.call,rate:.nan); sigma=0.2
        case "negativeSigma": m=market(.call); sigma = -0.1
        default: m=market(.put,rate:-1000); sigma=0.2
        }
        let value=OptionBSM.evaluate(m,volatility:sigma)
        #expect(value.price == nil && value.greeks == nil && value.itmProbability == nil)
        #expect(value.state == (kind == "overflow" ? .numericFailure : .invalidInput))
    }

    @Test(arguments: ["0.0005","0.2","1","5.5","12"])
    func brentRecoversIndependentPriceAndMeetsBothStops(_ text: String) throws {
        let sigma = try #require(Double(text)), m = market(.call, rate: 0, t: 0.02)
        // ATM, zero rates: C = S*(2 Phi(sigma sqrt(T)/2)-1), independent closed form.
        let target = 100 * erf(sigma * sqrt(0.02) / (2 * sqrt(2)))
        let result = try OptionIVSolver.solve(m, price: target)
        #expect(result.state == .available)
        #expect(abs(try #require(result.volatility)-sigma)<2e-8)
        let width = try #require(result.bracketUpper)-#require(result.bracketLower)
        #expect(width <= (try #require(result.sigmaTolerance)))
        #expect(try #require(result.residual) <= #require(result.priceTolerance))
        #expect(result.iterations > 0 && result.iterations <= 200)
    }

    @Test func iVBoundsNearExpiryAndUnbracketedDoNotClampOrFallback() throws {
        #expect(try OptionIVSolver.solve(market(.call,t:59.9/31_536_000),price:1).state == .tooNearExpiry)
        #expect(try OptionIVSolver.solve(market(.call,spot:0),price:1).state == .zeroSpotBoundary)
        let m = market(.call,rate:0,t:0.02)
        #expect(try OptionIVSolver.solve(m,price:101).state == .arbitrageViolation)
        #expect(try OptionIVSolver.solve(m,price:0).state == .boundaryPrice)
        #expect(try OptionIVSolver.solve(m,price:100).state == .boundaryPrice)
        let highTarget = 100*erf(25*sqrt(0.02)/(2*sqrt(2)))
        #expect(try OptionIVSolver.solve(m,price:highTarget).state == .ivNotBracketed)
        let tinyTarget = 100*erf(0.0000005*sqrt(0.02)/(2*sqrt(2)))
        #expect(try OptionIVSolver.solve(m,price:tinyTarget).state == .ivNotBracketed)
        let exactly60 = market(.call,rate:0,t:60/31_536_000)
        let price = try #require(OptionBSM.evaluate(exactly60,volatility:0.2).price)
        #expect(try OptionIVSolver.solve(exactly60,price:price).state == .available)
    }

    @Test func putIVAndNegativeRateRecoverWithoutAssumingPositiveRate() throws {
        let m = market(.put, rate:-0.03, q:0.02,t:0.75)
        let target = try #require(OptionBSM.evaluate(m,volatility:0.4).price)
        let result = try OptionIVSolver.solve(m,price:target)
        #expect(result.state == .available)
        #expect(abs(try #require(result.volatility)-0.4)<1e-8)
    }

    @Test func canonicalGreeksUseLocalIVAndCoveredStockDelta() throws {
        let input = try pricingInput(strategy:.coveredCall), report = try OptionLabEngine.calculate(input)
        let pricing = try #require(report.pricing), leg = try #require(pricing.legs.first), greek = try #require(leg.canonicalGreeks)
        let aggregate = try #require(pricing.aggregateGreeks)
        #expect(abs(aggregate.delta-(100-100*greek.delta))<1e-12)
        #expect(abs(aggregate.gamma+100*greek.gamma)<1e-12)
        #expect(abs(aggregate.thetaPerDay+100*greek.thetaPerDay)<1e-12)
        #expect(pricing.aggregateState == .available)
        #expect(leg.itmProbability != leg.absoluteDelta)
        #expect(leg.itmDeltaDifference == (try #require(leg.absoluteDelta)-#require(leg.itmProbability)))
        #expect(pricing.distribution?.volatility == leg.impliedVolatility.volatility)
        #expect(pricing.distribution?.volatilitySourceContractID == input.shortLeg.contractID)
        #expect(pricing.longLegSensitivity == nil && pricing.longLegSensitivityState == .notApplicable)
    }

    @Test func manualSigmaChangesTheoryButNotCanonicalIVGreeksOrDistribution() throws {
        let initial = try pricingInput(strategy:.putCreditSpread)
        let one = try #require(OptionLabEngine.calculate(initial).pricing)
        let assumptions = try #require(initial.pricing)
        let modified = optionPricingCopy(initial, pricing: .init(rate: assumptions.rate, dividendYield: assumptions.dividendYield,
            volatility: try Money("0.9"), source: assumptions.source))
        let two = try #require(OptionLabEngine.calculate(modified).pricing)
        #expect(one.legs[0].theoreticalPrice != two.legs[0].theoreticalPrice)
        #expect(one.legs.map(\.impliedVolatility) == two.legs.map(\.impliedVolatility))
        #expect(one.aggregateGreeks == two.aggregateGreeks)
        #expect(one.distribution == two.distribution)
        #expect(one.longLegSensitivity == two.longLegSensitivity)
        #expect(one.distribution?.volatilitySourceContractID == initial.shortLeg.contractID)
        #expect(one.longLegSensitivity?.volatilitySourceContractID == initial.longLeg?.contractID)
    }

    @Test func shortIVFailureDoesNotInventGreeksOrProbabilityFromManualSigma() throws {
        let base = try pricingInput(strategy:.cashSecuredPut), leg = base.shortLeg
        let short = OptionLabLeg(contractID:leg.contractID,symbol:leg.symbol,right:leg.right,strike:try Money("150"),quantity:leg.quantity,
            expirationDate:leg.expirationDate,bid:leg.bid,ask:leg.ask,bidSize:leg.bidSize,askSize:leg.askSize,tick:leg.tick,quotedAt:leg.quotedAt,receivedAt:leg.receivedAt,source:leg.source)
        let report = try OptionLabEngine.calculate(optionPricingCopy(base,short:short))
        let pricing = try #require(report.pricing), output=try #require(pricing.legs.first)
        #expect(output.theoreticalPrice != nil)
        #expect(output.impliedVolatility.state == .arbitrageViolation && output.impliedVolatility.volatility == nil)
        #expect(output.canonicalGreeks == nil && output.itmProbability == nil && pricing.aggregateGreeks == nil)
        #expect(pricing.distribution == nil && pricing.distributionState == .arbitrageViolation)
        #expect(report.conservative.netCreditTotal.amount > 0) // independent deterministic result remains available
    }

    @Test func oneLongLegFailureDoesNotEraseValidShortDistributionOrInventAggregate() throws {
        let base = try pricingInput(strategy: .putCreditSpread)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let settlement = base.asOf.addingTimeInterval(60)
        let date = MarketDate(year: calendar.component(.year, from: settlement), month: calendar.component(.month, from: settlement), day: calendar.component(.day, from: settlement))
        func leg(_ id: String, _ strike: String, _ bid: String, _ ask: String) throws -> OptionLabLeg {
            try .init(contractID: id, symbol: base.shortLeg.symbol, right: .put, strike: Money(strike), quantity: 1,
                expirationDate: date, bid: Money(bid), ask: Money(ask), bidSize: 10, askSize: 10, tick: Money("0.01"),
                quotedAt: base.asOf, receivedAt: base.asOf, source: base.shortLeg.source)
        }
        // With exactly 60 seconds remaining, the ATM short solves normally but a
        // 90-strike Put at 0.015 is above the price attainable even at sigma = 20.
        let input = try OptionLabInput(id: base.id, createdAt: base.createdAt, asOf: base.asOf, strategy: base.strategy,
            shortLeg: leg("SHORT-60S", "100", "0.04", "0.06"), longLeg: leg("LONG-60S", "90", "0.01", "0.02"),
            underlying: base.underlying, capital: base.capital,
            policy: .init(lambda: Money("0.25"), openingFeePerContract: Money("0"), ticketFee: Money("0"), terminalFeeTotal: Money("0")),
            expiry: .init(date: date, settlementAt: settlement, source: base.expiry.source),
            scenarioPrices: base.scenarioPrices, pricing: base.pricing)
        let p = try #require(OptionLabEngine.calculate(input).pricing)
        #expect(p.legs[0].impliedVolatility.state == .available)
        #expect(p.legs[1].impliedVolatility.state == .ivNotBracketed)
        #expect(p.aggregateGreeks == nil && p.longLegSensitivity == nil)
        #expect(p.distribution != nil && p.distributionState == .available)
    }

    @Test func nonExactPositionUnitsAreNumericFailureRatherThanMissingIV() throws {
        let base = try pricingInput(), leg = base.shortLeg
        // 100*n sits between adjacent Float64 values above 2^55, but remains
        // within the exact Money and Int input budgets.
        let quantity = 360_287_970_189_641
        #expect(Double(exactly: 100 * quantity) == nil)
        let short = OptionLabLeg(contractID: leg.contractID, symbol: leg.symbol, right: leg.right,
            strike: leg.strike, quantity: quantity, expirationDate: leg.expirationDate, bid: leg.bid, ask: leg.ask,
            bidSize: quantity, askSize: quantity, tick: leg.tick, quotedAt: leg.quotedAt, receivedAt: leg.receivedAt, source: leg.source)
        let p = try #require(OptionLabEngine.calculate(optionPricingCopy(base, short: short)).pricing)
        #expect(p.legs[0].impliedVolatility.state == .available && p.legs[0].canonicalGreeks != nil)
        #expect(p.aggregateGreeks == nil && p.aggregateState == .numericFailure)
        #expect(p.distribution == nil && p.distributionState == .numericFailure)
    }

    @Test func pricingSnapshotsKeepOldModelBindingAndRefuseTampering() throws {
        let old = try OptionLabEngine.calculate(OptionLabDemo.input())
        let report = try OptionLabEngine.calculate(pricingInput())
        #expect(old.schemaVersion == "option-lab-report.v1" && old.pricing == nil)
        #expect(report.schemaVersion == "option-lab-report.v2" && report.pricing != nil)
        #expect(old.modelReference == report.modelReference && old.parameterReference == report.parameterReference)
        let bytes=try JSONEncoder().encode(report), decoded=try JSONDecoder().decode(OptionLabReport.self,from:bytes)
        #expect(try OptionLabEngine.replay(decoded) == decoded)
        var object=try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        var pricing=try #require(object["pricing"] as? [String:Any]), parameters=try #require(pricing["parameters"] as? [String:Any])
        parameters["version"]="altered";pricing["parameters"]=parameters;object["pricing"]=pricing
        let tampered=try JSONDecoder().decode(OptionLabReport.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(throws:OptionLabError.incompatibleReport){try OptionLabEngine.replay(tampered)}
    }

    @Test func invalidPricingVersionAndNegativeDividendDoNotGetDefaults() throws {
        let base=try pricingInput(), p=try #require(base.pricing)
        let wrong=OptionLabPricingInput(rate:p.rate,dividendYield:p.dividendYield,volatility:p.volatility,source:p.source,methodVersion:"future")
        #expect(throws:OptionLabError.invalidPricingInput){try OptionLabEngine.calculate(optionPricingCopy(base,pricing:wrong))}
        let negative=OptionLabPricingInput(rate:p.rate,dividendYield:try Money("-0.01"),volatility:p.volatility,source:p.source)
        #expect(throws:OptionLabError.invalidPricingInput){try OptionLabEngine.calculate(optionPricingCopy(base,pricing:negative))}
    }

    @Test func cancelledSolverCannotPublishAResult() async {
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OptionIVSolver.solve(market(.call),price:10)
        }
        do { _=try await task.value; Issue.record("Cancelled solver returned a result") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected cancellation error type") }
    }
}

private func market(_ right:OptionLabRight,spot:Double=100,strike:Double=100,rate:Double=0.05,q:Double=0,t:Double=1)->OptionBSMMarket {
    .init(right:right,spot:spot,strike:strike,rate:rate,dividendYield:q,timeYears:t)
}
private func pricingInput(strategy:OptionLabStrategy = .cashSecuredPut)throws->OptionLabInput {
    let base=try OptionLabDemo.input(strategy:strategy)
    let assumptions=try OptionLabPricingInput(rate:Money("0.05"),dividendYield:Money("0.01"),volatility:Money("0.25"),
        source:.init(origin:.synthetic,reference:"Synthetic continuous-rate and independent theory sigma assumptions",enteredAt:base.createdAt))
    return optionPricingCopy(base,pricing:assumptions)
}
private func optionPricingCopy(_ base:OptionLabInput,short:OptionLabLeg?=nil,long:OptionLabLeg??=nil,pricing:OptionLabPricingInput?=nil)->OptionLabInput {
    .init(id:base.id,createdAt:base.createdAt,asOf:base.asOf,strategy:base.strategy,shortLeg:short ?? base.shortLeg,longLeg:long ?? base.longLeg,
        underlying:base.underlying,capital:base.capital,policy:base.policy,expiry:base.expiry,scenarioPrices:base.scenarioPrices,pricing:pricing ?? base.pricing)
}
