import Foundation
import Testing
import CoreDomain
@testable import OptionsAnalytics

@Suite struct OptionScenarioTests {
    @Test(arguments: OptionLabStrategy.allCases)
    func unchangedMarketLosesOnlyDeclaredFeesUnderMid(_ strategy: OptionLabStrategy) throws {
        let parent = try context(strategy)
        let output = try matrix(parent)
        let cell = try #require(output.cells.first), mid = try #require(cell.mid)
        let conservative = try #require(cell.conservative)
        #expect(cell.state == .available)
        #expect(try abs(mid.closeoutPnL + number(parent.mid.totalFees)) < 0.0001)
        #expect(try abs((mid.closeoutPnL - conservative.closeoutPnL)
            - number(parent.mid.netCreditTotal.subtracting(parent.conservative.netCreditTotal))) < 1e-10)
        #expect(mid.totalFees == parent.mid.totalFees && conservative.totalFees == parent.conservative.totalFees)
        #expect(mid.stockPnL == 0)
        #expect(output.valuationAt == parent.input.asOf)
    }

    @Test func absoluteIVPointsApplyToEachLegAndLeaveTimeUnchanged() throws {
        let parent = try context(.putCreditSpread, rate: "-0.03")
        let output = try matrix(parent, spots: ["0.1", "-0.1"], points: ["10", "0"])
        #expect(output.cells.count == 4)
        #expect(output.cells.map(\.spotShock.decimalString) == ["0.1", "0.1", "-0.1", "-0.1"])
        let cell = output.cells[0], pricing = try #require(parent.pricing)
        #expect(cell.spot == (try Money("110")))
        #expect(pricing.legs[0].impliedVolatility.volatility != pricing.legs[1].impliedVolatility.volatility)
        for index in cell.legs.indices {
            let leg = cell.legs[index], original = pricing.legs[index]
            #expect(abs(try #require(leg.shockedIV) - #require(original.impliedVolatility.volatility) - 0.1) < 1e-15)
            let contract = index == 0 ? parent.input.shortLeg : try #require(parent.input.longLeg)
            let expected = OptionBSM.evaluate(.init(right: contract.right, spot: 110,
                strike: try number(contract.strike), rate: -0.03, dividendYield: 0,
                timeYears: parent.input.expiry.settlementAt.timeIntervalSince(parent.input.asOf)/31_536_000),
                volatility: try #require(leg.shockedIV))
            #expect(leg.theoreticalUnitPrice == expected.price)
        }
    }

    @Test func changingManualTheorySigmaCannotChangeScenarioValues() throws {
        let low = try context(.callCreditSpread, manualSigma: "0.1")
        let high = try context(.callCreditSpread, manualSigma: "0.9")
        let first = try matrix(low, spots: ["-0.1", "0", "0.1"], points: ["-10", "0", "10"])
        let second = try matrix(high, spots: ["-0.1", "0", "0.1"], points: ["-10", "0", "10"])
        #expect(first == second)
        #expect(low.pricing?.legs.first?.theoreticalPrice != high.pricing?.legs.first?.theoreticalPrice)
    }

    @Test func noPricingAndFailedSingleLegNeverProducePartialStrategyResults() throws {
        let plain = try OptionLabEngine.calculate(OptionLabDemo.input(strategy: .cashSecuredPut))
        let missing = try matrix(plain)
        #expect(missing.cells[0].state == .missingPricing && missing.cells[0].mid == nil)
        let parent = try context(.putCreditSpread), pricing = try #require(parent.pricing)
        let bad = replacingIV(pricing, at: 1, with: .init(state: .ivNotBracketed, volatility: nil,
            iterations: 0, residual: nil, bracketLower: nil, bracketUpper: nil, sigmaTolerance: nil, priceTolerance: nil))
        let output = try matrix(parent, pricing: bad)
        let cell = output.cells[0]
        #expect(cell.legs[0].theoreticalUnitPrice != nil)
        #expect(cell.legs[1].state == .missingLegIV && cell.legs[1].ivState == .ivNotBracketed)
        #expect(cell.state == .missingLegIV && cell.mid == nil && cell.conservative == nil)
    }

    @Test func negativeShockedSigmaIsUnavailableWithoutClamping() throws {
        let parent = try context(.cashSecuredPut)
        let output = try matrix(parent, points: ["-100", "0"])
        #expect(output.cells[0].state == .negativeVolatility)
        #expect(try #require(output.cells[0].legs[0].shockedIV) < 0)
        #expect(output.cells[0].mid == nil && output.cells[0].conservative == nil)
        #expect(output.cells[1].state == .available && output.cells[1].mid != nil)
    }

    @Test func zeroSigmaUsesDeterministicDiscountedBoundaryAndPreservesNegativeRates() throws {
        let parent = try context(.cashSecuredPut, rate: "-0.03")
        let pricing = replacingIV(try #require(parent.pricing), at: 0, with: .init(state: .available, volatility: 0.25,
            iterations: 1, residual: 0, bracketLower: 0.25, bracketUpper: 0.25, sigmaTolerance: 1e-8, priceTolerance: 1e-8))
        let cell = try matrix(parent, points: ["-25"], pricing: pricing).cells[0]
        let t = parent.input.expiry.settlementAt.timeIntervalSince(parent.input.asOf)/31_536_000
        let expected = 100 * exp(0.03 * t) - 100
        #expect(cell.state == .zeroVolatilityBoundary && cell.legs[0].shockedIV == 0)
        #expect(abs(try #require(cell.legs[0].theoreticalUnitPrice) - expected) < 1e-12)
        #expect(cell.mid != nil)
    }

    @Test(arguments: OptionLabStrategy.allCases)
    func nonpositiveSpotExplicitlyMatchesDeterministicZeroPayoff(_ strategy: OptionLabStrategy) throws {
        let parent = try context(strategy)
        let output = try matrix(parent, spots: ["-1", "-2"])
        let expected = try #require(parent.mid.points.first(where: { $0.spot.amount == 0 }))
        for cell in output.cells {
            #expect(cell.spot?.amount == 0 && cell.state == .zeroSpotPayoffBoundary)
            #expect(abs(try #require(cell.mid).closeoutPnL - number(expected.pnl)) < 1e-10)
        }
        #expect(output.cells[0].spotShock != output.cells[1].spotShock)
    }

    @Test func coveredStockValueAndPnLAreCountedExactlyOnce() throws {
        let parent = try context(.coveredCall)
        let cell = try matrix(parent, spots: ["0.1"]).cells[0]
        let result = try #require(cell.mid), option = try #require(cell.legs[0].theoreticalUnitPrice)
        #expect(result.stockPnL == 1000)
        #expect(abs(result.theoreticalPositionValue - (11000 - 100 * option)) < 1e-10)
        #expect(abs(result.closeoutPnL - (try number(parent.mid.netCreditTotal) + 1000 - 100 * option)) < 1e-10)
    }

    @Test func allDeclaredFeesAreRetainedOnceForBothOpeningConventions() throws {
        let parent = try context(.putCreditSpread, fee: "1.25", ticket: "2.5", terminal: "3.5")
        let cell = try matrix(parent).cells[0], result = try #require(cell.mid)
        #expect(result.totalFees == (try Money("8.5")))
        #expect(abs(result.closeoutPnL + 8.5) < 0.0001)
        #expect(cell.conservative?.totalFees == result.totalFees)
    }

    @Test func gridsRejectDuplicatesEmptyOversizedAndFutureMethodWithoutDefaults() throws {
        let parent = try context(.cashSecuredPut)
        for (spots, points) in [([String](), ["0"]), (["0"], []), (["0", "0.0"], ["0"]),
                               (["0"], ["10", "10.0"]), ((0...21).map(String.init), ["0"])] {
            #expect(throws: OptionLabScenarioError.invalidGrid) { try matrix(parent, spots: spots, points: points) }
        }
        let axes = try OptionLabScenarioInput(source: source(parent), spotShocks: [Money("0")],
            volatilityPointShocks: [Money("0")], methodVersion: "future")
        #expect(throws: OptionLabScenarioError.invalidGrid) { try calculate(parent, assumptions: axes, pricing: parent.pricing) }
        // Money's wire boundary also rejects non-finite scenario numbers.
        for invalid in ["NaN", "Infinity", "-Infinity"] {
            #expect(throws: MoneyError.invalidDecimal) { try Money(invalid) }
        }
    }

    @Test func invalidSourceAndForeignPricingContextAreRejected() throws {
        let parent = try context(.cashSecuredPut), pricing = try #require(parent.pricing)
        for badSource in [OptionLabSource(origin: .manual, reference: " ", enteredAt: parent.input.createdAt),
            .init(origin: .manual, reference: "Future entry", enteredAt: parent.input.createdAt.addingTimeInterval(1)),
            .init(origin: .manual, reference: "Nonfinite entry", enteredAt: Date(timeIntervalSince1970: .nan))] {
            let axes = try OptionLabScenarioInput(source: badSource, spotShocks: [Money("0")], volatilityPointShocks: [Money("0")])
            #expect(throws: OptionLabScenarioError.invalidSource) { try calculate(parent, assumptions: axes, pricing: pricing) }
        }
        let other = try context(.coveredCall)
        #expect(throws: OptionLabScenarioError.incompatibleContext) { try matrix(parent, pricing: other.pricing) }
    }

    @Test func boundedFullGridAndOverflowKeepPerCellFailureExplicit() throws {
        let parent = try context(.cashSecuredPut)
        let spots = try (-10...10).map { try Money(String($0)).divided(by: "100").decimalString }
        let full = try matrix(parent, spots: spots, points: (-10...10).map(String.init))
        #expect(full.cells.count == 441 && full.cells.allSatisfy { $0.mid != nil && $0.conservative != nil })
        let huge = "1" + String(repeating: "0", count: 127)
        let partial = try matrix(parent, spots: [huge, "-" + huge, "0"])
        #expect(partial.cells[0].state == .numericFailure && partial.cells[0].spot == nil && partial.cells[0].mid == nil)
        #expect(partial.cells[1].state == .zeroSpotPayoffBoundary && partial.cells[1].spot?.amount == 0)
        #expect(partial.cells[2].state == .available && partial.cells[2].mid != nil)
    }

    @Test func definitionsAndCompleteScenarioJSONRemainStableWithoutChangingOldModels() throws {
        let old = try OptionLabEngine.definitions(), prior = try OptionLabPricingEngine.definitions()
        let parent = try context(.putCreditSpread)
        let output = try matrix(parent, spots: ["-0.1", "0", "0.1"], points: ["-10", "0", "10"])
        let bytes = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(OptionLabScenarioReport.self, from: bytes)
        #expect(decoded == output)
        #expect(try calculate(parent, assumptions: decoded.input, pricing: parent.pricing) == decoded)
        let definitions = try OptionLabScenarioEngine.definitions()
        #expect(output.modelReference == definitions.1.reference && output.parameterReference == definitions.0.reference)
        #expect(try OptionLabEngine.definitions().1.reference == old.1.reference)
        #expect(try OptionLabPricingEngine.definitions().1.reference == prior.1.reference)
        #expect(output.modelReference != old.1.reference && output.modelReference != prior.1.reference)
    }

    @Test func cancelledMatrixDoesNotPublishPartialGrid() async throws {
        let parent = try context(.cashSecuredPut)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try matrix(parent)
        }
        do { _ = try await task.value; Issue.record("Cancelled scenario matrix returned") }
        catch is CancellationError { }
    }
}

private func context(_ strategy: OptionLabStrategy, rate: String = "0.03", manualSigma: String = "0.25",
                     fee: String = "0.65", ticket: String = "0", terminal: String = "0") throws -> OptionLabReport {
    let base = try OptionLabDemo.input(strategy: strategy)
    let input = try OptionLabInput(id: base.id, createdAt: base.createdAt, asOf: base.asOf, strategy: base.strategy,
        shortLeg: base.shortLeg, longLeg: base.longLeg, underlying: base.underlying, capital: base.capital,
        policy: .init(lambda: Money("0.25"), openingFeePerContract: Money(fee), ticketFee: Money(ticket), terminalFeeTotal: Money(terminal)),
        expiry: base.expiry, scenarioPrices: base.scenarioPrices,
        pricing: .init(rate: Money(rate), dividendYield: Money("0"), volatility: Money(manualSigma), source: base.expiry.source))
    return try OptionLabEngine.calculate(input)
}
private func source(_ parent: OptionLabReport) -> OptionLabSource {
    .init(origin: .synthetic, reference: "SYNTHETIC user-defined instantaneous sensitivity, not probability", enteredAt: parent.input.createdAt)
}
private func matrix(_ parent: OptionLabReport, spots: [String] = ["0"], points: [String] = ["0"],
                    pricing: OptionLabPricingReport? = nil) throws -> OptionLabScenarioReport {
    let input = try OptionLabScenarioInput(source: source(parent), spotShocks: spots.map(Money.init),
        volatilityPointShocks: points.map(Money.init))
    return try calculate(parent, assumptions: input, pricing: pricing ?? parent.pricing)
}
private func calculate(_ parent: OptionLabReport, assumptions: OptionLabScenarioInput,
                       pricing: OptionLabPricingReport?) throws -> OptionLabScenarioReport {
    try OptionLabScenarioEngine.calculate(input: parent.input, assumptions: assumptions, pricing: pricing,
        underlyingMid: parent.underlyingMid, mid: parent.mid, conservative: parent.conservative)
}
private func number(_ value: Money) throws -> Double { try #require(Double(value.decimalString)) }
private func replacingIV(_ report: OptionLabPricingReport, at index: Int, with iv: OptionLabIVResult) -> OptionLabPricingReport {
    let legs = report.legs.enumerated().map { i, value in
        i != index ? value : OptionLabLegPricing(contractID: value.contractID, direction: value.direction,
            quoteMid: value.quoteMid, theoreticalPrice: value.theoreticalPrice, theoryState: value.theoryState,
            expiryIntrinsicValue: value.expiryIntrinsicValue, impliedVolatility: iv, canonicalGreeks: value.canonicalGreeks,
            itmProbability: value.itmProbability, absoluteDelta: value.absoluteDelta, itmDeltaDifference: value.itmDeltaDifference,
            warnings: value.warnings)
    }
    return .init(input: report.input, model: report.model, parameters: report.parameters, numericPolicyVersion: report.numericPolicyVersion,
        timeYears: report.timeYears, legs: legs, aggregateGreeks: report.aggregateGreeks, aggregateState: report.aggregateState,
        distribution: report.distribution, distributionState: report.distributionState,
        longLegSensitivity: report.longLegSensitivity, longLegSensitivityState: report.longLegSensitivityState, warnings: report.warnings)
}
