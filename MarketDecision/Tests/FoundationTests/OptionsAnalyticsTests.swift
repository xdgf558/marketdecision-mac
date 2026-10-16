import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics

@Suite struct OptionsAnalyticsTests {
    @Test(arguments: OptionLabStrategy.allCases.map(\.rawValue))
    func fourIndependentTerminalPayoffVectors(_ raw: String) throws {
        let strategy = try #require(OptionLabStrategy(rawValue: raw))
        let base = try OptionLabDemo.input(strategy: strategy)
        let isSpread = base.longLeg != nil
        let short = labLeg(base.shortLeg, strike: try Money("100"), bid: try Money(isSpread ? "3.5" : "2.5"), ask: try Money(isSpread ? "3.5" : "2.5"))
        let long = base.longLeg.map { labLeg($0, strike: try! Money(strategy == .putCreditSpread ? "90" : "110"), bid: try! Money("1"), ask: try! Money("1")) }
        let input = labInput(base, short: short, long: .some(long), policy: try .init(lambda: Money("0.25"), openingFeePerContract: Money(isSpread ? "0.75" : "1.5"), ticketFee: Money("0"), terminalFeeTotal: Money("0")), scenarios: try ["0","90","100","110","130"].map(Money.init))
        let report = try OptionLabEngine.calculate(input)
        // Independently hand-calculated: 100 shares, gross 250, total fees 1.50.
        let expected: [String]
        switch strategy {
        case .cashSecuredPut, .coveredCall: expected = ["-9751.5", "-751.5", "248.5", "248.5", "248.5"]
        case .putCreditSpread: expected = ["-751.5", "-751.5", "248.5", "248.5", "248.5"]
        case .callCreditSpread: expected = ["248.5", "248.5", "248.5", "-751.5", "-751.5"]
        }
        for outcome in [report.mid, report.conservative] {
            #expect(outcome.grossCredit == (try Money("250")))
            #expect(outcome.totalFees == (try Money("1.5")))
            #expect(outcome.netCreditTotal == (try Money("248.5")))
            for (spot, pnl) in zip(input.scenarioPrices, expected) {
                #expect(outcome.points.first(where: { $0.spot == spot })?.pnl == (try Money(pnl)))
            }
        }
        #expect(report.researchOnly && report.tradingDTE == nil)
    }

    @Test func twoLegDirectionalFillAndFeesCountOnce() throws {
        let report = try OptionLabEngine.calculate(OptionLabDemo.input(strategy: .putCreditSpread))
        #expect(report.mid.fills.map(\.unitPrice) == (try ["2.2","0.9"].map(Money.init)))
        #expect(report.conservative.fills.map(\.unitPrice) == (try ["2.1","0.95"].map(Money.init)))
        #expect(report.mid.netCreditTotal == (try Money("128.7")))
        #expect(report.conservative.netCreditTotal == (try Money("113.7")))
        #expect(report.conservative.maxLoss == (try Money("386.3")))
        #expect(report.conservative.totalFees == (try Money("1.3")))
    }

    @Test func quantityTicketAndTerminalFeesAreExplicitWholePlanAmounts() throws {
        let base = try OptionLabDemo.input(strategy: .putCreditSpread)
        let short = labLeg(base.shortLeg, quantity: 3), long = try #require(base.longLeg)
        let input = labInput(base, short: short, long: .some(labLeg(long, quantity: 3)), policy: try .init(lambda: Money("0.25"), openingFeePerContract: Money("0.65"), ticketFee: Money("2"), terminalFeeTotal: Money("3")))
        let result = try OptionLabEngine.calculate(input).conservative
        #expect(result.grossCredit == (try Money("345")))
        #expect(result.totalFees == (try Money("8.9"))) // six contracts * .65 + one ticket 2 + one endpoint 3
        #expect(result.netCreditTotal == (try Money("336.1")))
    }

    @Test func conservativeTicksUseOppositeDirectionsWithoutRoundingMid() throws {
        let base = try OptionLabDemo.input(strategy: .putCreditSpread)
        let short = labLeg(base.shortLeg, bid: try Money("2.01"), ask: try Money("2.39"), tick: .some(try Money("0.05")))
        let long = labLeg(try #require(base.longLeg), bid: try Money("0.81"), ask: try Money("0.99"), tick: .some(try Money("0.05")))
        let report = try OptionLabEngine.calculate(labInput(base, short: short, long: .some(long)))
        #expect(report.mid.fills.map(\.unitPrice) == (try ["2.2","0.9"].map(Money.init)))
        #expect(report.conservative.fills.map(\.unitPrice) == (try ["2.1","0.95"].map(Money.init)))
    }

    @Test func exactTickFloorDoesNotUseRoundedEighteenDigitQuotient() throws {
        let base = try OptionLabDemo.input()
        // Raw sell=1.99999999999999999999, just below tick 2, must floor to 1.
        let short = labLeg(base.shortLeg, bid: try Money("1"), ask: try Money("2.99999999999999999998"), tick: .some(try Money("1")))
        let policy = try OptionLabPolicy(lambda: Money("0"), openingFeePerContract: Money("0"), ticketFee: Money("0"), terminalFeeTotal: Money("0"))
        let report = try OptionLabEngine.calculate(labInput(base, short: short, policy: policy))
        #expect(report.conservative.fills[0].unitPrice == (try Money("1")))
        #expect(report.mid.fills[0].unitPrice == (try Money("1.99999999999999999999")))
    }

    @Test func lambdaEndpointsAndLockedMarketRemainDeterministic() throws {
        let base = try OptionLabDemo.input(strategy: .putCreditSpread)
        let policy = try OptionLabPolicy(lambda: Money("0.5"), openingFeePerContract: Money("0.65"), ticketFee: Money("0"), terminalFeeTotal: Money("0"))
        let result = try OptionLabEngine.calculate(labInput(base, policy: policy))
        #expect(result.conservative.fills.map(\.unitPrice) == (try ["2","1"].map(Money.init)))
        let locked = labLeg(base.shortLeg, bid: try Money("2"), ask: try Money("2"))
        let single = labInput(try OptionLabDemo.input(), short: locked)
        #expect(try OptionLabEngine.calculate(single).conservative.fills[0].unitPrice == Money("2"))
    }

    @Test func fundingUsesPretradeBaselineAndDoesNotChargeFeesTwice() throws {
        let base = try OptionLabDemo.input()
        let calculated = try OptionLabEngine.calculate(base)
        let exact = calculated.conservative.capitalRequired
        let capital = labCapital(base.capital, cash: exact)
        let funded = try OptionLabEngine.calculate(labInput(base, capital: capital)).conservative
        #expect(funded.funding == .sufficient)
        #expect(funded.capitalRequired == (try Money("9790.65")))
        let insufficient = labCapital(capital, cash: try exact.subtracting(Money("0.01")))
        #expect(try OptionLabEngine.calculate(labInput(base, capital: insufficient)).conservative.funding == .insufficientCash)
    }

    @Test func existingReservationsCannotBeSpentOrCoveredTwice() throws {
        let base = try OptionLabDemo.input(strategy: .coveredCall)
        let reserved = labCapital(base.capital, committedShares: try Money("1"))
        #expect(try OptionLabEngine.calculate(labInput(base, capital: reserved)).conservative.funding == .insufficientShares)
        let put = try OptionLabDemo.input()
        let reservedCash = labCapital(put.capital, cash: try Money("10000"), committedCash: try Money("300"))
        #expect(try OptionLabEngine.calculate(labInput(put, capital: reservedCash)).conservative.funding == .insufficientCash)
    }

    @Test func coveredCallUsesCurrentMidAndTwoDistinctYieldDenominators() throws {
        let base = try OptionLabDemo.input(strategy: .coveredCall)
        let underlying = OptionLabUnderlying(symbol: "DEMO", bid: try Money("89"), ask: try Money("91"), quotedAt: base.asOf, receivedAt: base.asOf, source: base.underlying.source)
        let result = try OptionLabEngine.calculate(labInput(base, underlying: underlying)).conservative
        #expect(result.maxProfit == (try Money("1209.35")))
        #expect(result.maxLoss == (try Money("8790.65")))
        #expect(result.breakEven == (try Money("87.9065")))
        #expect(result.yieldBase == (try Money("10000")))
        #expect(result.premiumYield == (try Money("0.020935")))
        #expect(result.stockMarketValueYield == (try Money("209.35").divided(by: "9000")))
        #expect(result.capitalRequired == (try Money("0")))
    }

    @Test func coveredCallWhoseEntirePayoffIsNegativeHasNoBreakEven() throws {
        let base = try OptionLabDemo.input(strategy: .coveredCall)
        let short = labLeg(base.shortLeg, strike: try Money("90"))
        let report = try OptionLabEngine.calculate(labInput(base, short: short))
        #expect(report.conservative.maxProfit == (try Money("-790.65")))
        #expect(report.conservative.breakEven == nil)
        #expect(report.conservative.returnOnRisk == (try Money("0")))
        #expect(report.conservative.points.allSatisfy { $0.pnl.amount < 0 })
    }

    @Test func sparseChartIncludesEveryPayoffKink() throws {
        let base = try OptionLabDemo.input(strategy: .putCreditSpread)
        let report = try OptionLabEngine.calculate(labInput(base, scenarios: try ["0","200"].map(Money.init)))
        let prices = Set(report.conservative.points.map { $0.spot.decimalString })
        #expect(prices.contains("95") && prices.contains("100"))
        #expect(prices.contains(try #require(report.conservative.breakEven).decimalString))
        #expect(report.conservative.points.count == 5)
    }

    @Test func noIntermediateAccountingRoundingBeforeTerminalPayoff() throws {
        let base = try OptionLabDemo.input()
        let short = labLeg(base.shortLeg, bid: try Money("2.000001"), ask: try Money("2.000003"), tick: .some(try Money("0.000001")))
        let policy = try OptionLabPolicy(lambda: Money("0"), openingFeePerContract: Money("0.000005"), ticketFee: Money("0"), terminalFeeTotal: Money("0"))
        let result = try OptionLabEngine.calculate(labInput(base, short: short, policy: policy)).mid
        #expect(result.netCreditTotal == (try Money("200.000195")))
        #expect(result.points.first { $0.spot == (try? Money("100")) }?.pnl == (try Money("200.000195")))
    }

    @Test func zeroDTEUsesOneDayAnnualizationButPositiveContinuousTime() throws {
        let asOf = labDate("2026-10-16T14:00:00Z"), base = try OptionLabDemo.input(at: asOf)
        let expiry = OptionLabExpiry(date: .init(year: 2026, month: 10, day: 16), settlementAt: labDate("2026-10-16T20:00:00Z"), source: base.expiry.source)
        let short = labLeg(base.shortLeg, expiration: expiry.date)
        let report = try OptionLabEngine.calculate(labInput(base, short: short, expiry: expiry))
        #expect(report.dte == 0 && report.timeYears.amount > 0 && !report.expired)
        #expect(report.conservative.annualizedSimple == (try report.conservative.premiumYield.multiplied(by: "365")))
        #expect(report.limitations.contains { $0.contains("高度敏感") })
    }

    @Test func newYorkCalendarDaysSurviveSpringDSTWithoutInventingTradingDays() throws {
        let start = labDate("2027-03-13T20:00:00Z"), base = try OptionLabDemo.input(at: start)
        let expiry = OptionLabExpiry(date: .init(year: 2027, month: 3, day: 15), settlementAt: labDate("2027-03-15T19:00:00Z"), source: base.expiry.source)
        let report = try OptionLabEngine.calculate(labInput(base, short: labLeg(base.shortLeg, expiration: expiry.date), expiry: expiry))
        #expect(report.dte == 2)
        #expect(report.timeYears == (try Money("169200").divided(by: "31536000"))) // 47 actual hours
        #expect(report.tradingDTE == nil)
    }

    @Test func expirationRejectsEqualAndPastInstants() throws {
        let base = try OptionLabDemo.input()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let date = MarketDate(year: cal.component(.year, from: base.asOf), month: cal.component(.month, from: base.asOf), day: cal.component(.day, from: base.asOf))
        for seconds in [0.0, -1] {
            let expiry = OptionLabExpiry(date: date, settlementAt: base.asOf.addingTimeInterval(seconds), source: base.expiry.source)
            #expect(throws: OptionLabError.expired) { try OptionLabEngine.calculate(labInput(base, short: labLeg(base.shortLeg, expiration: date), expiry: expiry)) }
        }
    }

    @Test(arguments: ["crossed","negative","missingTick","zeroTick","size","skew","stale","future","adjusted","cashSettled","european","multiplier"])
    func rejectedQuoteAndContractBoundaries(_ kind: String) throws {
        let base = try OptionLabDemo.input()
        let short: OptionLabLeg
        let error: OptionLabError
        switch kind {
        case "crossed": short = labLeg(base.shortLeg, bid: try Money("3")); error = .invalidQuote
        case "negative": short = labLeg(base.shortLeg, bid: try Money("-1")); error = .invalidQuote
        case "missingTick": short = labLeg(base.shortLeg, tick: .some(nil)); error = .missingTick
        case "zeroTick": short = labLeg(base.shortLeg, tick: .some(try Money("0"))); error = .missingTick
        case "size": short = labLeg(base.shortLeg, bidSize: 0); error = .insufficientSize
        case "skew": short = labLeg(base.shortLeg, quoteTime: base.asOf.addingTimeInterval(-5.01)); error = .quoteSkew
        case "stale": short = labLeg(base.shortLeg, quoteTime: base.asOf.addingTimeInterval(-60.01)); error = .staleQuote
        case "future": short = labLeg(base.shortLeg, quoteTime: base.asOf.addingTimeInterval(1)); error = .invalidTime
        case "adjusted": short = labLeg(base.shortLeg, delivery: .adjusted); error = .unsupportedContract
        case "cashSettled": short = labLeg(base.shortLeg, delivery: .cashSettled); error = .unsupportedContract
        case "european": short = labLeg(base.shortLeg, style: .european); error = .unsupportedContract
        default: short = labLeg(base.shortLeg, multiplier: 10); error = .unsupportedContract
        }
        #expect(throws: error) { try OptionLabEngine.calculate(labInput(base, short: short)) }
    }

    @Test(arguments: ["missing","extra","wrongRight","wrongStrike","wrongQuantity","wrongSymbol","wrongDate","sameIdentity"])
    func rejectsIncompleteOrMismatchedStrategy(_ kind: String) throws {
        let base = try OptionLabDemo.input(strategy: .putCreditSpread), initialLong = try #require(base.longLeg)
        var short = base.shortLeg, long: OptionLabLeg? = initialLong, strategy = base.strategy
        switch kind {
        case "missing": long = nil
        case "extra": strategy = .cashSecuredPut
        case "wrongRight": long = labLeg(initialLong, right: .call)
        case "wrongStrike": long = labLeg(initialLong, strike: try Money("101"))
        case "wrongQuantity": long = labLeg(initialLong, quantity: 2)
        case "wrongSymbol": long = labLeg(initialLong, symbol: "OTHER")
        case "wrongDate": long = labLeg(initialLong, expiration: try base.expiry.date.addingDays(1))
        default: short = labLeg(short, id: initialLong.contractID)
        }
        #expect(throws: OptionLabError.mismatchedLegs) { try OptionLabEngine.calculate(labInput(base, strategy: strategy, short: short, long: .some(long))) }
    }

    @Test func creditCannotBeNonpositiveOrExceedDefinedRisk() throws {
        let base = try OptionLabDemo.input(strategy: .putCreditSpread)
        let large = labLeg(base.shortLeg, bid: try Money("10"), ask: try Money("10"))
        #expect(throws: OptionLabError.invalidCredit) { try OptionLabEngine.calculate(labInput(base, short: large)) }
        let costly = try OptionLabPolicy(lambda: Money("0.25"), openingFeePerContract: Money("1000"), ticketFee: Money("0"), terminalFeeTotal: Money("0"))
        #expect(throws: OptionLabError.invalidCredit) { try OptionLabEngine.calculate(labInput(base, policy: costly)) }
    }

    @Test func policyAndCapitalMustBeExplicitAndConsistent() throws {
        let base = try OptionLabDemo.input()
        for lambda in ["-0.01","0.5000000001"] {
            let policy = try OptionLabPolicy(lambda: Money(lambda), openingFeePerContract: Money("0"), ticketFee: Money("0"), terminalFeeTotal: Money("0"))
            #expect(throws: OptionLabError.invalidPolicy) { try OptionLabEngine.calculate(labInput(base, policy: policy)) }
        }
        let missingLedger = OptionLabCapital(origin: .ledger, reference: "reference", asOf: base.asOf, cashBeforeTrade: try Money("20000"), committedCash: try Money("0"), availableShares: try Money("100"), committedShares: try Money("0"))
        #expect(throws: OptionLabError.invalidCapital) { try OptionLabEngine.calculate(labInput(base, capital: missingLedger)) }
        let asynchronous = labCapital(base.capital, asOf: base.asOf.addingTimeInterval(-1))
        #expect(throws: OptionLabError.invalidTime) { try OptionLabEngine.calculate(labInput(base, capital: asynchronous)) }
    }

    @Test func ledgerCollateralCannotReuseAnotherSecurityOrAssetKind() throws {
        let base = try OptionLabDemo.input(strategy: .coveredCall)
        func capital(symbol: String, asset: OptionLabAsset) throws -> OptionLabCapital {
            try .init(origin: .ledger, reference: "frozen-account-revision", asOf: base.asOf,
                      cashBeforeTrade: Money("1000"), committedCash: Money("0"), availableShares: Money("100"), committedShares: Money("0"),
                      accountID: "account", ledgerRevision: UUID(), underlyingSymbol: symbol, underlyingAsset: asset)
        }
        #expect(try OptionLabEngine.calculate(labInput(base, capital: capital(symbol: "DEMO", asset: .stock))).conservative.funding == .sufficient)
        for (symbol, asset) in [("OTHER", OptionLabAsset.stock), ("DEMO", OptionLabAsset.etf)] {
            #expect(throws: OptionLabError.invalidCapital) {
                try OptionLabEngine.calculate(labInput(base, capital: capital(symbol: symbol, asset: asset)))
            }
        }
    }

    @Test func manualHistoryRemainsExplicitAssumptionAndNeverGainsPIT() throws {
        let base = try OptionLabDemo.input(), source = OptionLabSource(origin: .manual, reference: "User entered hypothetical prices; not historical evidence", enteredAt: base.createdAt.addingTimeInterval(100))
        let input = labInput(base, short: labLeg(base.shortLeg, source: source), createdAt: source.enteredAt)
        let report = try OptionLabEngine.calculate(input)
        #expect(report.researchOnly && report.input.shortLeg.source.enteredAt > report.input.asOf)
        #expect(report.limitations.contains { $0.contains("PIT") })
    }

    @Test func encodedReportReplaysAfterOriginalInputsAreDiscarded() throws {
        let encoded: Data = try {
            let input = try OptionLabDemo.input(strategy: .callCreditSpread, at: Date(timeIntervalSince1970: 1_792_162_800.0004))
            return try JSONEncoder().encode(OptionLabEngine.calculate(input))
        }()
        let restored = try JSONDecoder().decode(OptionLabReport.self, from: encoded)
        #expect(try OptionLabEngine.replay(restored) == restored)
        #expect(restored.input.asOf.timeIntervalSince1970 == 1_792_162_800.0004)
        #expect(restored.model.numericPolicyVersion == Money.numericPolicyVersion)
        #expect(restored.model.defaultParameters == restored.parameterReference)
    }

    @Test(arguments: ["result","parameters","model","input","schema"])
    func replayRejectsAlteredContextOrCachedResults(_ kind: String) throws {
        let report = try OptionLabEngine.calculate(OptionLabDemo.input())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        switch kind {
        case "result": var v = try #require(object["conservative"] as? [String: Any]); v["netCreditTotal"] = "999"; object["conservative"] = v
        case "parameters": var v = try #require(object["parameters"] as? [String: Any]); v["version"] = "PARAMETERS_V2"; object["parameters"] = v
        case "model": var v = try #require(object["model"] as? [String: Any]); v["formulaVersion"] = "changed"; object["model"] = v
        case "input": var v = try #require(object["input"] as? [String: Any]); var p = try #require(v["policy"] as? [String: Any]); p["ticketFee"] = "1"; v["policy"] = p; object["input"] = v
        default: object["schemaVersion"] = "future"
        }
        let altered = try JSONDecoder().decode(OptionLabReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: OptionLabError.incompatibleReport) { try OptionLabEngine.replay(altered) }
    }
}

private func labDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func labInput(_ b: OptionLabInput, strategy: OptionLabStrategy? = nil, short: OptionLabLeg? = nil, long: OptionLabLeg?? = nil,
                      underlying: OptionLabUnderlying? = nil, capital: OptionLabCapital? = nil, policy: OptionLabPolicy? = nil,
                      expiry: OptionLabExpiry? = nil, scenarios: [Money]? = nil, createdAt: Date? = nil) -> OptionLabInput {
    .init(id: b.id, createdAt: createdAt ?? b.createdAt, asOf: b.asOf, strategy: strategy ?? b.strategy,
          shortLeg: short ?? b.shortLeg, longLeg: long ?? b.longLeg, underlying: underlying ?? b.underlying,
          capital: capital ?? b.capital, policy: policy ?? b.policy, expiry: expiry ?? b.expiry, scenarioPrices: scenarios ?? b.scenarioPrices)
}
private func labLeg(_ b: OptionLabLeg, id: String? = nil, symbol: String? = nil, right: OptionLabRight? = nil,
                    strike: Money? = nil, quantity: Int? = nil, expiration: MarketDate? = nil, bid: Money? = nil, ask: Money? = nil,
                    bidSize: Int? = nil, tick: Money?? = nil, quoteTime: Date? = nil, source: OptionLabSource? = nil,
                    style: OptionLabExerciseStyle? = nil, delivery: OptionLabDelivery? = nil, multiplier: Int? = nil) -> OptionLabLeg {
    .init(contractID: id ?? b.contractID, symbol: symbol ?? b.symbol, right: right ?? b.right, strike: strike ?? b.strike,
          multiplier: multiplier ?? b.multiplier, exerciseStyle: style ?? b.exerciseStyle, delivery: delivery ?? b.delivery,
          specificationVersion: b.specificationVersion, quantity: quantity ?? b.quantity, expirationDate: expiration ?? b.expirationDate,
          bid: bid ?? b.bid, ask: ask ?? b.ask, bidSize: bidSize ?? b.bidSize, askSize: b.askSize, tick: tick ?? b.tick,
          quotedAt: quoteTime ?? b.quotedAt, receivedAt: b.receivedAt, source: source ?? b.source)
}
private func labCapital(_ b: OptionLabCapital, cash: Money? = nil, committedCash: Money? = nil, committedShares: Money? = nil, asOf: Date? = nil) -> OptionLabCapital {
    .init(origin: b.origin, reference: b.reference, asOf: asOf ?? b.asOf, currency: b.currency,
          cashBeforeTrade: cash ?? b.cashBeforeTrade, committedCash: committedCash ?? b.committedCash,
          availableShares: b.availableShares, committedShares: committedShares ?? b.committedShares,
          accountID: b.accountID, ledgerRevision: b.ledgerRevision, underlyingSymbol: b.underlyingSymbol, underlyingAsset: b.underlyingAsset)
}
