import Foundation
import CoreDomain
import AIInsights

public enum AIValuationScenarioCalculationError: Error, Equatable, Sendable {
    case invalidInput, unrepresentablePrice
}

public enum AIValuationScenario: String, CaseIterable, Equatable, Sendable {
    case conservative, base, optimistic
}

public struct AIValuationScenarioPrice: Equatable, Sendable {
    public let scenario: AIValuationScenario
    public let targetMultiple: Money
    public let price: Money

    fileprivate init(scenario: AIValuationScenario, targetMultiple: Money, price: Money) {
        self.scenario = scenario; self.targetMultiple = targetMultiple; self.price = price
    }
}

/// A confirmed-assumption scenario, not a market quote or independently established fair value.
/// The workspace invokes this calculator only after consuming an explicit, current proposal
/// confirmation. It does not persist an approval or send another AI request.
public struct AIValuationScenarioCalculation: Equatable, Sendable {
    public static let method = "confirmed-ai-ps-scenarios.v1"
    public let inputDigest: String
    public let proposal: AIPriceSalesScenarioProposal
    public let ttmRevenue: Money
    public let shares: Money
    public let referencePrice: Money
    public let periodEnd: String
    public let referenceAt: String
    public let sharesAsOf: String
    public let rows: [AIValuationScenarioPrice]

    private init(inputDigest: String, proposal: AIPriceSalesScenarioProposal,
                 ttmRevenue: Money, shares: Money, referencePrice: Money,
                 periodEnd: String, referenceAt: String, sharesAsOf: String,
                 rows: [AIValuationScenarioPrice]) {
        self.inputDigest = inputDigest; self.proposal = proposal
        self.ttmRevenue = ttmRevenue; self.shares = shares; self.referencePrice = referencePrice
        self.periodEnd = periodEnd; self.referenceAt = referenceAt; self.sharesAsOf = sharesAsOf
        self.rows = rows
    }

    public static func calculate(input: AIInsightInput,
                                 proposal: AIPriceSalesScenarioProposal) throws -> Self {
        let revenue: Money, shares: Money, referencePrice: Money
        let context: AIInsightReferenceValuationContext, digest: String
        do {
            try input.validate()
            try proposal.validate(for: input)
            guard input.supportsPriceSalesScenarios, let reference = input.referenceValuation,
                  let revenueText = input.metrics.first(where: { $0.id == "base.revenue" })?.value,
                  let sharesText = input.metrics.first(where: { $0.id == "reference.shares" })?.value,
                  let priceText = input.metrics.first(where: { $0.id == "reference.price" })?.value else {
                throw AIValuationScenarioCalculationError.invalidInput
            }
            revenue = try Money(revenueText); shares = try Money(sharesText)
            referencePrice = try Money(priceText)
            guard revenue.amount > 0, shares.amount > 0, referencePrice.amount > 0,
                  !shares.decimalString.contains(".") else {
                throw AIValuationScenarioCalculationError.invalidInput
            }
            context = reference; digest = try input.digest()
        } catch {
            // Neither arbitrary generated text nor a raw numeric failure is exposed.
            throw AIValuationScenarioCalculationError.invalidInput
        }

        let assumptions: [(AIValuationScenario, AIPriceSalesScenarioAssumption)] = [
            (.conservative, proposal.conservative), (.base, proposal.base),
            (.optimistic, proposal.optimistic)
        ]
        let rows: [AIValuationScenarioPrice]
        do {
            rows = try assumptions.map { scenario, assumption in
                let multiple = try Money(assumption.multiple)
                // Multiply before dividing: do not first round revenue per share or
                // recover revenue from the current price-to-sales ratio. The only
                // arithmetic rounding is Money's existing 18-place half-even division.
                let price = try revenue.multiplied(by: multiple.decimalString)
                    .divided(by: shares.decimalString)
                guard price.amount > 0 else {
                    throw AIValuationScenarioCalculationError.unrepresentablePrice
                }
                return AIValuationScenarioPrice(scenario: scenario, targetMultiple: multiple, price: price)
            }
        } catch {
            // No partial set of scenario prices and no zero fallback is published.
            throw AIValuationScenarioCalculationError.unrepresentablePrice
        }
        return Self(inputDigest: digest, proposal: proposal, ttmRevenue: revenue,
                    shares: shares, referencePrice: referencePrice, periodEnd: input.periodEnd,
                    referenceAt: context.referenceAt, sharesAsOf: context.sharesAsOf, rows: rows)
    }
}
