import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import AppComposition

private func ocbDraft(_ strategy: OptionLabStrategy = .cashSecuredPut) throws -> OptionLabInputDraft {
    let capture = try OptionChainDemo.capture()
    let suffix: String, long: String?
    switch strategy {
    case .cashSecuredPut: suffix = "P00100000"; long = nil
    case .coveredCall: suffix = "C00100000"; long = nil
    case .putCreditSpread: suffix = "P00105000"; long = "DEMO261113P00100000"
    case .callCreditSpread: suffix = "C00100000"; long = "DEMO261113C00105000"
    }
    return try OptionChainLabBridge.draft(capture, strategy: strategy, shortID: "DEMO261113" + suffix, longID: long, quantity: 1)
}
private func ocbComplete(_ original: OptionLabInputDraft) -> OptionLabInputDraft {
    var draft = original
    draft.settlementAt = "2026-11-13T21:00:00Z"; draft.expiryReference = "SYNTHETIC explicit standard100 settlement assumption"
    draft.shortLeg.tick = "0.01"; if draft.hasLongLeg { draft.longLeg.tick = "0.01" }
    draft.cashBeforeTrade = "100000"; draft.committedCash = "0"; draft.availableShares = "100"; draft.committedShares = "0"
    draft.capitalReference = "SYNTHETIC capital assumption"; draft.scenarioPrices = "90\n100\n110"
    return draft
}
private func ocbDaily(_ capture: OptionChainCapture, close: Bool = false) throws -> OptionDailyInput {
    let formatter = ISO8601DateFormatter()
    var settlements: [String: Date] = [:]
    for date in Set(capture.snapshot.contracts.map(\.expiration)) {
        settlements[date.iso8601] = try #require(formatter.date(from: date.iso8601 + "T21:00:00Z"))
    }
    return try OptionChainLabBridge.daily(capture, rate: Money("0.04"), dividendYield: Money("0.01"), settlements: settlements,
        tick: Money("0.01"), assumptionReference: "SYNTHETIC explicit settlement/tick/rate assumptions", declaredClose: close,
        assumptionsEnteredAt: capture.createdAt.addingTimeInterval(86400))
}
private func ocbChanged<T: Codable>(_ value: T, change: (inout [String: Any]) throws -> Void) throws -> T {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    try change(&object)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

@Suite struct OptionChainLabBridgeTests {
    @Test(arguments: [OptionLabStrategy.cashSecuredPut, .coveredCall, .putCreditSpread, .callCreditSpread])
    func selectedContractsNeedExplicitAssumptionsBeforeAnyCalculation(_ strategy: OptionLabStrategy) throws {
        let draft = try ocbDraft(strategy)
        #expect(draft.origin == .synthetic && draft.chainEvidence != nil)
        #expect(draft.settlementAt.isEmpty && draft.expiryReference.isEmpty && draft.shortLeg.tick.isEmpty)
        #expect(draft.cashBeforeTrade.isEmpty && draft.committedCash.isEmpty && draft.availableShares.isEmpty && draft.committedShares.isEmpty)
        #expect(draft.capitalReference.isEmpty && draft.scenarioPrices.isEmpty)
        #expect(!draft.pricing.enabled && !draft.risk.enabled && !draft.scenario.enabled)
        #expect(throws: (any Error).self) { try draft.build(createdAt: OptionChainDemo.time.addingTimeInterval(4)) }
        let complete = ocbComplete(draft), input = try complete.build(createdAt: OptionChainDemo.time.addingTimeInterval(4))
        let report = try OptionLabEngine.calculate(input)
        #expect(report.schemaVersion == "option-lab-report.v4.chain" && report.input.chainEvidence == draft.chainEvidence)
        let reopened = try JSONDecoder().decode(OptionLabReport.self, from: JSONEncoder().encode(report))
        #expect(try OptionLabEngine.replay(reopened) == report)
    }
    @Test func localPricingRiskAndScenariosRetainAllOriginalRawPages() throws {
        var draft = ocbComplete(try ocbDraft())
        try draft.useSyntheticRiskScenarioAssumptions()
        let input = try draft.build(createdAt: OptionChainDemo.time.addingTimeInterval(4))
        let report = try OptionLabEngine.calculate(input)
        #expect(report.pricing != nil && report.risk != nil && report.scenario != nil)
        #expect(report.input.chainEvidence?.capture.pages.count == 4)
        #expect(report.input.chainEvidence?.capture.pages.map(\.bytes) == draft.chainEvidence?.capture.pages.map(\.bytes))
        #expect(try OptionLabEngine.replay(JSONDecoder().decode(OptionLabReport.self, from: JSONEncoder().encode(report))) == report)
    }
    @Test func sourceQuoteEditingDoesNotSilentlyDetachOrRelabelEvidence() throws {
        var draft = ocbComplete(try ocbDraft())
        draft.shortLeg.bid = "2.70"
        let input = try draft.build(createdAt: OptionChainDemo.time.addingTimeInterval(4))
        #expect(input.chainEvidence != nil)
        #expect(throws: OptionLabError.incompatibleReport) { try OptionLabEngine.calculate(input) }
    }
    @Test func mismatchedRightsExpiryStrikeDirectionAndExtraLongAreRejected() throws {
        let capture = try OptionChainDemo.capture()
        #expect(throws: (any Error).self) { try OptionChainLabBridge.draft(capture, strategy: .cashSecuredPut,
            shortID: "DEMO261113C00100000", longID: nil, quantity: 1) }
        for id in ["DEMO261120P00100000", "DEMO261113C00100000", "DEMO261113P00105000"] {
            #expect(throws: (any Error).self) { try OptionChainLabBridge.draft(capture, strategy: .putCreditSpread,
                shortID: "DEMO261113P00100000", longID: id, quantity: 1) }
        }
        #expect(throws: (any Error).self) { try OptionChainLabBridge.draft(capture, strategy: .cashSecuredPut,
            shortID: "DEMO261113P00100000", longID: "DEMO261113P00105000", quantity: 1) }
    }
    @Test func dailyIncludesEveryObservedContractButDoesNotInventVolumeOrOIAvailability() throws {
        let capture = try OptionChainDemo.capture(), input = try ocbDaily(capture), report = try OptionDailyEngine.calculate(input)
        #expect(input.contracts.count == 8 && Set(input.contracts.map(\.contractID)) == Set(capture.snapshot.contracts.map(\.recordID)))
        #expect(capture.snapshot.contracts.allSatisfy { $0.observedVolume == 100 && $0.observedOpenInterest == 300 })
        #expect(input.contracts.allSatisfy { $0.activity.volume == nil && $0.activity.openInterest == nil })
        #expect(input.calendar == nil && input.sessionCloseAt == nil)
        #expect(report.state == .unverifiedSessionClose && report.iv30 == nil)
        #expect(report.chainSummary.totalVolume == nil && report.chainSummary.totalOpenInterest == nil)
        #expect(report.schemaVersion == "option-daily-report.v2.chain")
        #expect(try OptionDailyEngine.replay(JSONDecoder().decode(OptionDailyReport.self, from: JSONEncoder().encode(report))) == report)
    }
    @Test func dailyRequiresExactExplicitSettlementSetAndDoesNotInferCloseOrCalendar() throws {
        #expect(throws: (any Error).self) { try OptionChainLabBridge.daily(OptionChainDemo.capture(), rate: Money("0.04"),
            dividendYield: Money("0.01"), settlements: [:], tick: Money("0.01"), assumptionReference: "explicit", declaredClose: false) }
        let input = try ocbDaily(OptionChainDemo.capture(), close: true), report = try OptionDailyEngine.calculate(input)
        #expect(input.sessionCloseAt == input.asOf && input.calendar == nil)
        #expect(report.containsSynthetic && report.researchOnly && report.chainSummary.put25DeltaIV == nil)
    }
    @Test func newDailyAssumptionsAreNotBackdatedToOriginalCollection() throws {
        let capture = try OptionChainDemo.capture(), input = try ocbDaily(capture)
        #expect(input.createdAt == capture.createdAt.addingTimeInterval(86400))
        #expect(input.asOf == capture.createdAt && input.source.enteredAt == capture.createdAt)
        #expect(input.contracts.allSatisfy { $0.expiry.source.enteredAt == input.createdAt && $0.source.enteredAt == capture.createdAt })
        var dates: [String: Date] = [:]
        for contract in input.contracts { dates[contract.expiry.date.iso8601] = contract.expiry.settlementAt }
        #expect(throws: (any Error).self) {
            try OptionChainLabBridge.daily(capture, rate: input.rate, dividendYield: input.dividendYield, settlements: dates,
                tick: Money("0.01"), assumptionReference: "explicit", declaredClose: false,
                assumptionsEnteredAt: capture.createdAt.addingTimeInterval(-1))
        }
    }
    @Test func partialCaptureCannotBecomeCompleteLabOrCanonicalIV30() throws {
        let original = try OptionChainDemo.capture()
        let partial = try OptionChainCapture(id: original.id, createdAt: original.createdAt, requestedAt: original.requestedAt,
            symbol: original.symbol, environment: original.environment, timestampUnit: original.timestampUnit, synthetic: true,
            rights: original.rights, requestedExpirations: original.requestedExpirations, pages: Array(original.pages.prefix(3)))
        #expect(partial.snapshot.status == .partial)
        #expect(throws: (any Error).self) { try OptionChainLabBridge.draft(partial, strategy: .cashSecuredPut,
            shortID: "DEMO261113P00100000", longID: nil, quantity: 1) }
        let report = try OptionDailyEngine.calculate(ocbDaily(partial, close: true))
        #expect(report.state == .partialChain && report.iv30 == nil && report.input.contracts.count == 4)
    }
    @Test func dailyCannotDropContractsOrUseUnqualifiedObservedOpenInterest() throws {
        let input = try ocbDaily(OptionChainDemo.capture())
        let subset = try ocbChanged(input) { object in
            let rows = try #require(object["contracts"] as? [[String: Any]])
            object["contracts"] = Array(rows.dropLast())
        }
        #expect(throws: (any Error).self) { try OptionDailyEngine.calculate(subset) }
        let injected = try ocbChanged(input) { object in
            var rows = try #require(object["contracts"] as? [[String: Any]])
            var activity = try #require(rows[0]["activity"] as? [String: Any]); activity["openInterest"] = 300
            rows[0]["activity"] = activity; object["contracts"] = rows
        }
        #expect(throws: (any Error).self) { try OptionDailyEngine.calculate(injected) }
    }
    @Test func rawBidAndAskClockSkewCannotHideBehindTheirMinimumTimestamp() throws {
        let original = try OptionChainDemo.capture()
        let pages = try original.pages.map { page -> OptionChainRawPage in
            let old = Int(OptionChainDemo.time.timeIntervalSince1970 * 1000)
            let raw = try #require(String(data: page.bytes, encoding: .utf8))
            // All bid minima still match, but only the underlying ask is 10s later.
            let text = page.request.capability == .quote ? raw.replacingOccurrences(of: "\"ask_date\":\(old)", with: "\"ask_date\":\(old + 10_000)") : raw
            return .init(request: page.request, expiration: page.expiration, receivedAt: page.receivedAt.addingTimeInterval(20),
                         statusCode: page.statusCode, bytes: Data(text.utf8))
        }
        let skewed = try OptionChainCapture(id: original.id, createdAt: original.createdAt.addingTimeInterval(20),
            requestedAt: original.requestedAt, symbol: original.symbol, environment: original.environment,
            timestampUnit: original.timestampUnit, synthetic: true, rights: original.rights,
            requestedExpirations: original.requestedExpirations, pages: pages)
        #expect(skewed.snapshot.underlying?.quoteTime == OptionChainDemo.time)
        #expect(throws: OptionLabError.quoteSkew) { try OptionChainEvidence.validateForLab(skewed) }
        #expect(throws: OptionDailyError.invalidTime) { try OptionDailyEngine.calculate(ocbDaily(skewed)) }
    }
    @Test func forgedNormalizedProjectionCannotBeUsedEvenWithValidOuterEncoding() throws {
        let good = try OptionChainDemo.capture()
        let bad = try ocbChanged(good) { object in
            var projection = try #require(object["snapshot"] as? [String: Any]); projection["status"] = "empty"; object["snapshot"] = projection
        }
        #expect(throws: (any Error).self) { try OptionChainLabBridge.draft(bad, strategy: .cashSecuredPut,
            shortID: "DEMO261113P00100000", longID: nil, quantity: 1) }
        #expect(throws: (any Error).self) { try ocbDaily(bad) }
    }
    @Test func realCaptureCannotAcquireSyntheticLaboratoryQualification() throws {
        let synthetic = try OptionChainDemo.capture()
        let real = try OptionChainCapture(id: synthetic.id, createdAt: synthetic.createdAt, requestedAt: synthetic.requestedAt,
            symbol: synthetic.symbol, environment: synthetic.environment, timestampUnit: synthetic.timestampUnit, synthetic: false,
            rights: synthetic.rights, requestedExpirations: synthetic.requestedExpirations, pages: synthetic.pages)
        try real.validate()
        #expect(!real.snapshot.qualifiedForLiveAnalysis && !real.snapshot.qualifiedForPIT)
        #expect(throws: (any Error).self) { try OptionChainEvidence.validateForLab(real) }
        #expect(throws: (any Error).self) { try ocbDaily(real) }
    }
    @Test func rawInvalidZeroBidCannotBeTreatedAsOrdinaryLabQuote() throws {
        let original = try OptionChainDemo.capture()
        let pages = try original.pages.map { page -> OptionChainRawPage in
            let text = try #require(String(data: page.bytes, encoding: .utf8)).replacingOccurrences(of: "\"bid\":2.80", with: "\"bid\":0.00")
            return .init(request: page.request, expiration: page.expiration, receivedAt: page.receivedAt,
                         statusCode: page.statusCode, bytes: Data(text.utf8))
        }
        let invalid = try OptionChainCapture(id: original.id, createdAt: original.createdAt, requestedAt: original.requestedAt,
            symbol: original.symbol, environment: original.environment, timestampUnit: original.timestampUnit, synthetic: true,
            rights: original.rights, requestedExpirations: original.requestedExpirations, pages: pages)
        #expect(invalid.snapshot.contracts.contains { $0.quote.quality.contains(.invalid) })
        #expect(throws: OptionLabError.invalidQuote) { try OptionChainEvidence.validateForLab(invalid) }
        #expect(throws: OptionDailyError.invalidInput) { try OptionDailyEngine.calculate(ocbDaily(invalid)) }
    }
}
