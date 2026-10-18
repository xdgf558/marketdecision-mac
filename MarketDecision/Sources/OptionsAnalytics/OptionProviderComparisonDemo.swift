import Foundation
import CoreDomain

public enum OptionProviderComparisonDemo {
    public static func input(id: UUID = UUID(), at: Date = OptionDailyDemo.defaultDate) throws -> OptionProviderComparisonInput {
        let base = try OptionLabDemo.input(at: at)
        let source = OptionLabSource(origin: .synthetic,
            reference: "SYNTHETIC-PROVIDER-COMPARISON; generated local and fictional provider observations, no account or network", enteredAt: at)
        let pricing = OptionLabPricingInput(rate: try Money("0.04"), dividendYield: try Money("0.01"), volatility: try Money("0.25"), source: source)
        let localInput = OptionLabInput(id: base.id, createdAt: at, asOf: at, strategy: base.strategy,
            shortLeg: base.shortLeg, longLeg: base.longLeg, underlying: base.underlying, capital: base.capital,
            policy: base.policy, expiry: base.expiry, scenarioPrices: base.scenarioPrices, pricing: pricing)
        let local = try OptionLabEngine.calculate(localInput)
        guard let localSigma = local.pricing?.legs.first?.impliedVolatility.volatility else { throw OptionProviderComparisonError.invalidInput }
        // Deliberately different synthetic sigma illustrates an absolute-IV discrepancy.
        let providerSigma = localSigma + 0.06
        let market = OptionBSMMarket(right: base.shortLeg.right, spot: 100, strike: 100, rate: 0.04, dividendYield: 0.01,
            timeYears: base.expiry.settlementAt.timeIntervalSince(at) / 31_536_000)
        guard let greeks = OptionBSM.evaluate(market, volatility: providerSigma).greeks else { throw OptionProviderComparisonError.invalidInput }
        let model = OptionProviderModel(family: .europeanBSMContinuousDividend, version: "SYNTHETIC-PROVIDER-BSM.v1",
            spot: try Money("100"), continuousRate: pricing.rate, continuousDividendYield: pricing.dividendYield,
            volatilityUsedForGreeks: providerSigma, reference: "SYNTHETIC declared BSM model; not provider verification")
        let values: [OptionProviderField: OptionProviderValue] = [
            .iv: .init(value: providerSigma, unit: .annualVolatilityDecimal),
            .delta: .init(value: greeks.delta, unit: .perShareDelta),
            .gamma: .init(value: greeks.gamma, unit: .perShareGammaPerUSD),
            .theta: .init(value: greeks.thetaPerDay, unit: .perShareThetaPerCalendarDay),
            .vega: .init(value: greeks.vegaPerPercentagePoint, unit: .perShareVegaPerPercentagePoint),
            .rho: .init(value: greeks.rhoPerPercentagePoint, unit: .perShareRhoPerPercentagePoint)]
        let feed = "SYNTHETIC-OFFLINE-COMPARISON"
        let observation = OptionProviderObservation(id: "SYNTHETIC-PROVIDER-OBSERVATION", providerID: "SYNTHETIC-PROVIDER",
            feedID: feed, contract: .init(leg: base.shortLeg, expiry: base.expiry), valuationAt: at,
            quoteTime: base.shortLeg.quotedAt, underlyingQuoteTime: base.underlying.quotedAt, receivedAt: at,
            source: source, model: model, values: values)
        return .init(id: id, createdAt: at, localReport: local, localFeedID: feed, observations: [observation])
    }
}
