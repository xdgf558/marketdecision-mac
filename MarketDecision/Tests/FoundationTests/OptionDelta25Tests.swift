import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import OptionsAnalytics

@Suite struct OptionDelta25Tests {
    @Test func syntheticWideGridIsDeterministicAndKeepsOldDailyFieldsUnavailable() throws {
        let first = try OptionDelta25Demo.input()
        let second = try OptionDelta25Demo.input()
        #expect(first == second)
        #expect(first.daily.input.contracts.count == 36)
        #expect(first.daily.containsSynthetic)
        #expect(first.daily.chainSummary.call25DeltaIV == nil)
        #expect(first.daily.chainSummary.put25DeltaIV == nil)
        #expect(first.daily.contractSummaries.allSatisfy { $0.state == .available })
        let replayed = try OptionDailyEngine.replay(first.daily)
        #expect(replayed == first.daily)
    }

    @Test func wrapperEncodingRetainsEntireParentEvidenceAndReferences() throws {
        let input = try OptionDelta25Demo.input()
        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(OptionDelta25Input.self, from: encoded)
        #expect(decoded == input)
        #expect(decoded.daily.modelReference == input.daily.modelReference)
        #expect(decoded.daily.parameterReference == input.daily.parameterReference)
        #expect(decoded.daily.pricingModel.reference == input.daily.pricingModel.reference)
        #expect(decoded.daily.pricingParameters.reference == input.daily.pricingParameters.reference)
        #expect(decoded.daily.input.contracts == input.daily.input.contracts)
        #expect(decoded.daily.input.underlying == input.daily.input.underlying)
    }

    @Test func frozenLocalQuotesProduceIndependentConstantVolatilityOracle() throws {
        let report = try OptionDelta25Engine.calculate(OptionDelta25Demo.input())
        #expect(report.state == .available)
        #expect(report.selectedExpiryInstants.count == 2)
        #expect(abs(try #require(report.call25DeltaIV) - 0.25) < 1e-7)
        #expect(abs(try #require(report.put25DeltaIV) - 0.35) < 1e-7)
        #expect(abs(try #require(report.putMinusCallSkew) - 0.10) < 1e-7)
        #expect(report.expiries.allSatisfy { $0.call.points.count == 2 && $0.put.points.count == 2 })
        #expect(report.containsSynthetic && report.researchOnly)
    }

    @Test func exactSignedTargetsDoNotInterpolateOrUseAbsoluteDelta() throws {
        let call = OptionDelta25Engine.select(points: [try point("C", 100, 0.25, 0.2)], right: .call)
        let put = OptionDelta25Engine.select(points: [try point("P", 100, -0.25, 0.3)], right: .put)
        #expect(call.iv == 0.2 && put.iv == 0.3)
        #expect(call.secondPointWeight == 0 && put.secondPointWeight == 0)
        #expect(call.targetDelta == 0.25 && put.targetDelta == -0.25)
        let wrongSign = OptionDelta25Engine.select(points: [try point("P", 100, 0.25, 0.3)], right: .put)
        #expect(wrongSign.iv == nil && wrongSign.state == .missingCanonicalIV)
    }

    @Test func adjacentSignedDeltaInterpolatesIVWithIndependentWeights() throws {
        let callPoints = [try point("C90", 90, 0.4, 0.2), try point("C100", 100, 0.1, 0.4)]
        let putPoints = [try point("P90", 90, -0.1, 0.3), try point("P100", 100, -0.4, 0.6)]
        let call = OptionDelta25Engine.select(points: callPoints, right: .call)
        let put = OptionDelta25Engine.select(points: putPoints, right: .put)
        #expect(abs(try #require(call.iv) - 0.3) < 1e-14)
        #expect(abs(try #require(put.iv) - 0.45) < 1e-14)
        #expect(abs(try #require(call.secondPointWeight) - 0.5) < 1e-14)
        #expect(call.points.map(\.contractID) == ["C90", "C100"])
        #expect(put.points.map(\.delta) == [-0.1, -0.4])
    }

    @Test func interpolationSelectsOnlyAdjacentBracketingContracts() throws {
        let points = [try point("C80", 80, 0.9, 0.8), try point("C90", 90, 0.4, 0.2),
                      try point("C100", 100, 0.1, 0.4), try point("C110", 110, 0.01, 0.9)]
        let result = OptionDelta25Engine.select(points: points, right: .call)
        #expect(result.points.map(\.contractID) == ["C90", "C100"])
        #expect(abs(try #require(result.iv) - 0.3) < 1e-14)
    }

    @Test(arguments: [0.25, 0.3])
    func duplicateOrNonMonotoneDeltaRejectsEvenWithExactTarget(_ secondDelta: Double) throws {
        let points = [try point("C90", 90, 0.25, 0.2), try point("C100", 100, secondDelta, 0.3)]
        let result = OptionDelta25Engine.select(points: points, right: .call)
        #expect(result.state == .nonMonotoneDelta)
        #expect(result.iv == nil && result.points.isEmpty)
    }

    @Test func targetOutsideObservedDeltaNeverExtrapolates() throws {
        let high = [try point("C90", 90, 0.8, 0.2), try point("C100", 100, 0.6, 0.3)]
        let low = [try point("C90", 90, 0.2, 0.2), try point("C100", 100, 0.1, 0.3)]
        #expect(OptionDelta25Engine.select(points: high, right: .call).state == .noDeltaBracket)
        #expect(OptionDelta25Engine.select(points: low, right: .call).state == .noDeltaBracket)
    }

    @Test func invalidInteriorQuoteCannotBeSkippedAcrossGridHole() throws {
        let input = try OptionDelta25Demo.input(nearDays: 30, farDays: 30)
        let changed = try replacingDaily(input) { json in
            var contracts = try #require(json["contracts"] as? [[String: Any]])
            let index = try #require(contracts.firstIndex { $0["right"] as? String == "call" && $0["strike"] as? String == "100" })
            contracts[index].removeValue(forKey: "tick")
            json["contracts"] = contracts
        }
        let report = try OptionDelta25Engine.calculate(changed)
        #expect(report.expiries.first?.call.state == .missingCanonicalIV)
        #expect(report.expiries.first?.put.state == .available)
        #expect(report.call25DeltaIV == nil && report.put25DeltaIV == nil && report.putMinusCallSkew == nil)
    }

    @Test(arguments: ["partial", "close", "unknown", "skew"])
    func incompleteOrUnalignedDailyEvidenceCannotProduceValues(_ kind: String) throws {
        let input = try OptionDelta25Demo.input()
        let changed = try replacingDaily(input) { json in
            switch kind {
            case "partial": json["coverage"] = "partial"
            case "close": json.removeValue(forKey: "sessionCloseAt")
            default:
                var underlying = try #require(json["underlying"] as? [String: Any])
                if kind == "unknown" { underlying.removeValue(forKey: "quoteTime") }
                else { underlying["quoteTime"] = input.daily.input.asOf.addingTimeInterval(-6).timeIntervalSinceReferenceDate }
                json["underlying"] = underlying
            }
        }
        let report = try OptionDelta25Engine.calculate(changed)
        let expected: OptionDelta25State
        switch kind { case "partial": expected = .partialChain; case "close": expected = .unverifiedSessionClose
        case "unknown": expected = .unknownQuoteTime; default: expected = .quoteSkew }
        #expect(report.state == expected)
        #expect(report.call25DeltaIV == nil && report.put25DeltaIV == nil)
        #expect(report.expiries.allSatisfy { $0.call.iv == nil && $0.put.iv == nil })
    }

    @Test func missingPutNeverUsesCallOrDifferentExpiryAsProxy() throws {
        let input = try OptionDelta25Demo.input(nearDays: 30, farDays: 30)
        let changed = try replacingDaily(input) { json in
            let contracts = try #require(json["contracts"] as? [[String: Any]])
            json["contracts"] = contracts.filter { $0["right"] as? String == "call" }
        }
        let report = try OptionDelta25Engine.calculate(changed)
        #expect(report.expiries.first?.call.state == .available)
        #expect(report.expiries.first?.put.state == .missingSide)
        #expect(report.state == .noExpiryBracket && report.putMinusCallSkew == nil)
    }

    @Test(arguments: ["specificationVersion", "exerciseStyle"])
    func mixedContractBasisIsRejectedAcrossStrikesAndRights(_ field: String) throws {
        let input = try OptionDelta25Demo.input(nearDays: 30, farDays: 30)
        let changed = try replacingDaily(input) { json in
            var contracts = try #require(json["contracts"] as? [[String: Any]])
            let index = try #require(contracts.firstIndex { $0["right"] as? String == "put" })
            contracts[index][field] = field == "exerciseStyle" ? "european" : "adjusted-contract.v1"
            json["contracts"] = contracts
        }
        let report = try OptionDelta25Engine.calculate(changed)
        #expect(report.expiries.first?.state == .mismatchedContractBasis)
        #expect(report.call25DeltaIV == nil && report.put25DeltaIV == nil)
    }

    @Test func nonstandardMultiplierIsRejectedByParentBeforeDerivation() throws {
        let input = try OptionDelta25Demo.input()
        #expect(throws: OptionDailyError.invalidInput) {
            _ = try replacingDaily(input) { json in
                var contracts = try #require(json["contracts"] as? [[String: Any]])
                contracts[0]["multiplier"] = 150; json["contracts"] = contracts
            }
        }
    }

    @Test func existingATMOnlyDailyReportDoesNotInventDelta25() throws {
        let daily = try OptionDailyEngine.calculate(OptionDailyDemo.input())
        let input = OptionDelta25Input(createdAt: daily.input.createdAt, daily: daily)
        let report = try OptionDelta25Engine.calculate(input)
        #expect(daily.iv30 != nil)
        #expect(report.call25DeltaIV == nil && report.put25DeltaIV == nil)
        #expect(report.expiries.allSatisfy { $0.call.state == .noDeltaBracket && $0.put.state == .noDeltaBracket })
    }

    @Test func thirtyDayInterpolatesEachSideVarianceBeforeTakingSkew() throws {
        let near = try expiry(days: 20, call: 0.2, put: 0.4)
        let far = try expiry(days: 40, call: 0.3, put: 0.5)
        let result = OptionDelta25Engine.thirtyDay(expiries: [far, near], asOf: OptionDailyDemo.defaultDate, gate: nil)
        let expectedCall = sqrt((0.2 * 0.2 * 20 + 0.3 * 0.3 * 40) / 60)
        let expectedPut = sqrt((0.4 * 0.4 * 20 + 0.5 * 0.5 * 40) / 60)
        let call = try #require(result.call), put = try #require(result.put)
        #expect(result.state == .available)
        #expect(abs(call - expectedCall) < 1e-14)
        #expect(abs(put - expectedPut) < 1e-14)
        #expect(abs((put - call) - 0.2) > 1e-4)
        #expect(result.expiries == [near.settlementAt, far.settlementAt])
    }

    @Test(arguments: [-1.0, 0, 1.0])
    func exactThirtyDayUsesExistingOneSecondTolerance(_ offset: Double) throws {
        let only = try expiry(days: 30 + offset / 86_400, call: 0.2, put: 0.3)
        let result = OptionDelta25Engine.thirtyDay(expiries: [only], asOf: OptionDailyDemo.defaultDate, gate: nil)
        #expect(result.call == 0.2 && result.put == 0.3)
        #expect(result.expiries == [only.settlementAt])
    }

    @Test func exactExpiryTieIsDeterministicallyEarlierAndDoesNotUseInputOrder() throws {
        let before = try expiry(days: 30 - 1.0 / 86_400, call: 0.2, put: 0.3)
        let after = try expiry(days: 30 + 1.0 / 86_400, call: 0.4, put: 0.5)
        let result = OptionDelta25Engine.thirtyDay(expiries: [after, before], asOf: OptionDailyDemo.defaultDate, gate: nil)
        #expect(result.expiries == [before.settlementAt])
        #expect(result.call == 0.2 && result.put == 0.3)
    }

    @Test(arguments: ["sameSide", "single", "distant"])
    func missingOrTooDistantTermBracketsRemainUnavailable(_ kind: String) throws {
        let near = try expiry(days: kind == "sameSide" ? 10 : 20, call: 0.2, put: 0.3)
        let farDays = kind == "sameSide" ? 20.0 : 60 + 1.0 / 86_400
        let far = try expiry(days: farDays, call: 0.3, put: 0.4)
        let items = kind == "single" ? [near] : [near, far]
        let result = OptionDelta25Engine.thirtyDay(expiries: items, asOf: OptionDailyDemo.defaultDate, gate: nil)
        #expect(result.state == .noExpiryBracket)
        #expect(result.call == nil && result.put == nil && result.expiries.isEmpty)
    }

    @Test func callAndPutCannotUseIndependentTermPairs() throws {
        let first = try expiry(days: 20, call: 0.2, put: nil)
        let middle = try expiry(days: 25, call: nil, put: 0.3)
        let last = try expiry(days: 40, call: 0.4, put: 0.5)
        let result = OptionDelta25Engine.thirtyDay(expiries: [first, middle, last], asOf: OptionDailyDemo.defaultDate, gate: nil)
        #expect(result.state == .noExpiryBracket && result.call == nil && result.put == nil)
    }

    @Test func fullReportEncodingReplaysAfterOriginalInputIsDiscarded() throws {
        let bytes = try JSONEncoder().encode(OptionDelta25Engine.calculate(OptionDelta25Demo.input()))
        let frozen = try JSONDecoder().decode(OptionDelta25Report.self, from: bytes)
        let replayed = try OptionDelta25Engine.replay(frozen)
        #expect(replayed == frozen)
        #expect(frozen.model.state == .approved && frozen.parameters.state == .approved)
        #expect(frozen.model.defaultParameters == frozen.parameterReference)
    }

    @Test(arguments: ["cachedDelta", "aggregate", "parameter"])
    func forgedParentOrNewReportCannotPassReplay(_ kind: String) throws {
        let original = try OptionDelta25Engine.calculate(OptionDelta25Demo.input())
        let forged: OptionDelta25Report = try changed(original) { json in
            if kind == "cachedDelta" {
                var input = try #require(json["input"] as? [String: Any])
                var daily = try #require(input["daily"] as? [String: Any])
                var rows = try #require(daily["contractSummaries"] as? [[String: Any]])
                rows[0]["canonicalDelta"] = 0.25
                daily["contractSummaries"] = rows; input["daily"] = daily; json["input"] = input
            } else if kind == "aggregate" { json["call25DeltaIV"] = 0.99 }
            else {
                var parameters = try #require(json["parameters"] as? [String: Any])
                parameters["version"] = "OTHER"; json["parameters"] = parameters
            }
        }
        #expect(throws: OptionDailyError.incompatibleReport) { try OptionDelta25Engine.replay(forged) }
    }

    @Test func unknownMethodAndCreationBeforeParentAreRejected() throws {
        let input = try OptionDelta25Demo.input()
        let wrong = OptionDelta25Input(createdAt: input.createdAt, daily: input.daily, methodVersion: "options.delta25.future")
        let early = OptionDelta25Input(createdAt: input.createdAt.addingTimeInterval(-1), daily: input.daily)
        #expect(throws: OptionDailyError.invalidInput) { try OptionDelta25Engine.calculate(wrong) }
        #expect(throws: OptionDailyError.invalidInput) { try OptionDelta25Engine.calculate(early) }
    }

    private func point(_ id: String, _ strike: Int, _ delta: Double, _ iv: Double) throws -> OptionDelta25Point {
        .init(contractID: id, strike: try Money(String(strike)), delta: delta, iv: iv)
    }

    private func expiry(days: Double, call: Double?, put: Double?) throws -> OptionDelta25ExpirySummary {
        let callValue = OptionDelta25Selection(right: .call, targetDelta: 0.25,
            state: call == nil ? .missingCanonicalIV : .available, points: [], secondPointWeight: 0, iv: call)
        let putValue = OptionDelta25Selection(right: .put, targetDelta: -0.25,
            state: put == nil ? .missingCanonicalIV : .available, points: [], secondPointWeight: 0, iv: put)
        return .init(settlementAt: OptionDailyDemo.defaultDate.addingTimeInterval(days * 86_400), timeYears: days / 365,
            call: callValue, put: putValue, state: call == nil || put == nil ? .missingCanonicalIV : .available,
            putMinusCallSkew: call.flatMap { c in put.map { $0 - c } })
    }

    private func replacingDaily(_ input: OptionDelta25Input, edit: (inout [String: Any]) throws -> Void) throws -> OptionDelta25Input {
        let dailyInput = try changed(input.daily.input, edit: edit)
        let daily = try OptionDailyEngine.calculate(dailyInput)
        return .init(id: input.id, createdAt: input.createdAt, daily: daily)
    }

    private func changed<T: Codable>(_ value: T, edit: (inout [String: Any]) throws -> Void) throws -> T {
        let data = try JSONEncoder().encode(value)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try edit(&json)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
