import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics

@Suite struct OptionDailyTests {
    @Test func independentATMVectorInterpolatesTotalVarianceNotIV() throws {
        let report = try OptionDailyEngine.calculate(dailyVector())
        let expected = sqrt((0.2 * 0.2 * 20 + 0.4 * 0.4 * 40) / 60)
        #expect(abs(try #require(report.iv30) - expected) < 1e-8)
        #expect(abs(try #require(report.iv30) - 0.3) > 0.04)
        #expect(report.state == .available && report.contractSummaries.count == 4)
        #expect(report.iv30ExpiryInstants.count == 2 && report.researchOnly && report.containsSynthetic)
        #expect(report.chainSummary.put25DeltaIV == nil && report.chainSummary.call25DeltaIV == nil)
        #expect(report.contractSummaries.allSatisfy { $0.canonicalDelta != nil && $0.localIV?.state == .available })
    }
    @Test(arguments: [-1.0, 0, 1.0])
    func exactThirtyDayToleranceAcceptsOneSecond(_ offset: Double) throws {
        let input = try dailyVector(near: 30 + offset / 86_400, far: nil, low: 0.3)
        let report = try OptionDailyEngine.calculate(input)
        #expect(report.state == .available && report.iv30ExpiryInstants.count == 1)
        #expect(abs(try #require(report.iv30) - 0.3) < 1e-8)
    }
    @Test(arguments: [29.0,31.0,30 + 2.0 / 86_400])
    func singleExpiryOutsideToleranceNeverBecomesProxy(_ days: Double) throws {
        let report = try OptionDailyEngine.calculate(dailyVector(near: days, far: nil))
        #expect(report.iv30 == nil && report.state == .noBracket)
    }
    @Test func sameStrikeCallAndPutLocalIVAreAveraged() throws {
        let input = try dailyVector(near:30,far:nil,low:0.2)
        let putPrice = String(format:"%.12f",locale:Locale(identifier:"en_US_POSIX"),100 * erf(0.4 * sqrt(30.0/365) / (2 * sqrt(2))))
        let differing = try changed(input) { dict in
            var contracts = dict["contracts"] as! [[String:Any]]
            let index = contracts.firstIndex { $0["right"] as? String == "put" }!
            contracts[index]["bid"] = putPrice; contracts[index]["ask"] = putPrice; dict["contracts"] = contracts
        }
        let report = try OptionDailyEngine.calculate(differing)
        #expect(abs(try #require(report.iv30) - 0.3) < 1e-8)
        #expect(abs(try #require(report.expiries.first?.callIV) - 0.2) < 1e-8)
        #expect(abs(try #require(report.expiries.first?.putIV) - 0.4) < 1e-8)
    }
    @Test func noExtrapolationOrTooDistantUpperExpiry() throws {
        let sameSide = try OptionDailyEngine.calculate(dailyVector(near: 10, far: 20))
        let distant = try OptionDailyEngine.calculate(dailyVector(near: 20, far: 60 + 1.0/86_400))
        #expect(sameSide.iv30 == nil && distant.iv30 == nil)
    }
    @Test func partialOrUndeclaredClosePreservesContractsWithoutIV30() throws {
        let input = try dailyVector()
        let partial = try changed(input) { $0["coverage"] = "partial" }
        let intraday = try changed(input) { $0.removeValue(forKey: "sessionCloseAt") }
        let p = try OptionDailyEngine.calculate(partial), i = try OptionDailyEngine.calculate(intraday)
        #expect(p.iv30 == nil && p.state == .partialChain && p.contractSummaries.count == 4)
        #expect(i.iv30 == nil && i.state == .unverifiedSessionClose)
        #expect(p.contractSummaries.allSatisfy { $0.canonicalIV != nil })
    }
    @Test func closestStrikeMissingPutDoesNotSkipToFartherPair() throws {
        let input = try dailyVector(near:30, far:nil)
        let one = try changed(input) { dict in
            var contracts = dict["contracts"] as! [[String:Any]]
            contracts.removeAll { $0["right"] as? String == "put" }
            dict["contracts"] = contracts
        }
        let result = try OptionDailyEngine.calculate(one)
        #expect(result.iv30 == nil && result.expiries.first?.state == .missingATMCallOrPut)
    }
    @Test func symmetricMoneynessChoosesLowerStrikeAndDoesNotAverageStrikes() throws {
        let input = try dailyVector(near:30,far:nil)
        let custom = try changed(input) { dict in
            let original = dict["contracts"] as! [[String:Any]]
            var contracts: [[String:Any]] = []
            for strike in ["80","125"] {
                for var contract in original {
                    contract["strike"] = strike
                    contract["contractID"] = "\(strike)-\(contract["right"]!)"
                    // Bounds-valid values; this test asserts strike selection independent of solver result.
                    contract["bid"] = "30"; contract["ask"] = "30"
                    contracts.append(contract)
                }
            }
            dict["contracts"] = contracts
        }
        let result = try OptionDailyEngine.calculate(custom)
        #expect(result.expiries.first?.strike == (try Money("80")))
        #expect(result.expiries.first?.callContractID == "80-call")
        #expect(result.expiries.first?.putContractID == "80-put")
    }
    @Test(arguments: ["contractID","feedID","session","underlyingQuoteID"])
    func duplicateAndSourceMismatchRejectBeforeCalculation(_ field: String) throws {
        let input = try dailyVector()
        let bad = try changed(input) { dict in
            var contracts = dict["contracts"] as! [[String:Any]]
            if field == "contractID" { contracts[1][field] = contracts[0][field] }
            else if field == "session" { contracts[0][field] = ["year":2026,"month":10,"day":15] }
            else { contracts[0][field] = "ANOTHER" }
            dict["contracts"] = contracts
        }
        #expect(throws: (any Error).self) { try OptionDailyEngine.calculate(bad) }
    }
    @Test(arguments: ["missingTime","lateReceived","skew","stale","tick","offTick","zeroSize","arbitrage"])
    func missingOrBadQuoteCannotSupplyCanonicalIV(_ kind: String) throws {
        let input = try dailyVector(near:30,far:nil)
        let bad = try changed(input) { dict in
            var contracts = dict["contracts"] as! [[String:Any]]
            switch kind {
            case "missingTime": contracts[0].removeValue(forKey: "quoteTime")
            case "lateReceived":
                dict["createdAt"] = input.createdAt.addingTimeInterval(1).timeIntervalSinceReferenceDate
                contracts[0]["receivedAt"] = input.asOf.addingTimeInterval(1).timeIntervalSinceReferenceDate
            case "skew": contracts[0]["quoteTime"] = input.asOf.addingTimeInterval(-6).timeIntervalSinceReferenceDate
            case "stale": contracts[0]["quoteTime"] = input.asOf.addingTimeInterval(-61).timeIntervalSinceReferenceDate
            case "tick": contracts[0].removeValue(forKey: "tick")
            case "offTick": contracts[0]["tick"] = "1"
            case "zeroSize": contracts[0]["bidSize"] = 0
            default: contracts[0]["bid"] = "101"; contracts[0]["ask"] = "101"
            }
            dict["contracts"] = contracts
        }
        let report = try OptionDailyEngine.calculate(bad)
        #expect(report.iv30 == nil)
        #expect(report.contractSummaries.contains { $0.canonicalIV == nil })
        if kind == "missingTime" { #expect(report.chainSummary.maxSkewSeconds == nil) }
    }
    @Test func oiReleaseAndCalendarStayIndependentFromQuoteClock() throws {
        let input = try OptionDailyDemo.input()
        let result = try OptionDailyEngine.calculate(input)
        #expect(result.chainSummary.totalOpenInterest == 800 && result.chainSummary.totalVolume == 400)
        let missing = try changed(input) { dict in
            var contracts = dict["contracts"] as! [[String:Any]]
            var activity = contracts[0]["activity"] as! [String:Any]
            activity.removeValue(forKey: "openInterestReleasedAt")
            contracts[0]["activity"] = activity; dict["contracts"] = contracts
        }
        let unknown = try OptionDailyEngine.calculate(missing)
        #expect(unknown.chainSummary.totalOpenInterest == nil && unknown.chainSummary.totalVolume == 400)
        #expect(unknown.iv30 != nil)
        let noCalendar = try changed(input) { $0.removeValue(forKey: "calendar") }
        #expect(try OptionDailyEngine.calculate(noCalendar).chainSummary.totalOpenInterest == nil)
        let notLatest = try changed(input) { dict in
            var contracts = dict["contracts"] as! [[String:Any]]
            for index in contracts.indices {
                var activity = contracts[index]["activity"] as! [String:Any]
                activity.removeValue(forKey: "openInterestLatestPublished")
                contracts[index]["activity"] = activity
            }
            dict["contracts"] = contracts
        }
        #expect(try OptionDailyEngine.calculate(notLatest).chainSummary.totalOpenInterest == nil)
    }
    @Test func replayRoundTripRequiresCompleteModelAndSummaryIdentity() throws {
        let report = try OptionDailyEngine.calculate(dailyVector())
        let decoded = try JSONDecoder().decode(OptionDailyReport.self, from: JSONEncoder().encode(report))
        #expect(try OptionDailyEngine.replay(decoded) == report)
        let bad = try changed(report) { $0["iv30"] = 0.99 }
        #expect(throws: OptionDailyError.incompatibleReport) { try OptionDailyEngine.replay(bad) }
    }
}

private func dailyVector(near: Double = 20, far: Double? = 40, low: Double = 0.2, high: Double = 0.4) throws -> OptionDailyInput {
    let base = try OptionDailyDemo.input(nearDays:30,farDays:30)
    var contracts: [OptionDailyContractInput] = []
    let pairs: [(Double,Double)] = [(near,low)] + (far.map { [($0,high)] } ?? [])
    for (days,sigma) in pairs {
        let time = base.asOf.addingTimeInterval(days * 86_400)
        var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"America/New_York")!
        let day = MarketDate(year:c.component(.year,from:time),month:c.component(.month,from:time),day:c.component(.day,from:time))
        // Independent ATM zero-rate formula, deliberately not OptionBSM.evaluate.
        let price = try Money(String(format:"%.12f",locale:Locale(identifier:"en_US_POSIX"),100 * erf(sigma * sqrt(days / 365) / (2 * sqrt(2)))))
        for right in [OptionLabRight.call,.put] {
            contracts.append(.init(contractID:"VECTOR-\(days)-\(right.rawValue)",symbol:base.symbol,feedID:base.feedID,
                session:base.session,underlyingQuoteID:base.underlying.quoteID,right:right,strike:try Money("100"),
                expiry:.init(date:day,settlementAt:time,source:base.source),bid:price,ask:price,bidSize:10,askSize:10,
                tick:try Money("0.000000000001"),quoteTime:base.asOf,receivedAt:base.asOf,
                activity:.init(source:base.source),source:base.source))
        }
    }
    return .init(createdAt:base.createdAt,asOf:base.asOf,session:base.session,symbol:base.symbol,feedID:base.feedID,
        coverage:.complete,declaredScope:"SYNTHETIC bounded independent ATM analytical vector",underlying:base.underlying,
        contracts:contracts,rate:try Money("0"),dividendYield:try Money("0"),source:base.source,sessionCloseAt:base.asOf)
}
private func changed<T:Codable>(_ value:T,_ mutation:(inout [String:Any])->Void)throws->T {
    var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
    mutation(&object)
    return try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]))
}
