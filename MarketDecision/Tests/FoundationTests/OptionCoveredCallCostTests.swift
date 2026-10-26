import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import Persistence

private func ccDate(_ text: String) throws -> Date { try MillisecondInstant(iso8601: text).date }
private func ccInput(cost: String? = "50", quantity: Int = 10, quoteMode: Bool = false,
                     ticketFee: String = "0", terminalFee: String = "0", pricing: Bool = false) throws -> OptionLabInput {
    let time = try ccDate("2026-10-26T00:00:00.000Z")
    let date = MarketDate(year: 2026, month: 11, day: 20)
    let source = OptionLabSource(origin: .manual, reference: "Explicit manual covered-call fixture; not market evidence", enteredAt: time)
    return try .init(createdAt: time, asOf: time, strategy: .coveredCall,
        shortLeg: .init(contractID: "LOCAL-CC-20261120-C60", symbol: "COST", right: .call,
            strike: Money("60"), quantity: quantity, expirationDate: date,
            bid: quoteMode ? Money("0.6") : nil, ask: quoteMode ? Money("0.8") : nil,
            bidSize: quoteMode ? 100 : nil, askSize: quoteMode ? 100 : nil, tick: quoteMode ? Money("0.01") : nil,
            quotedAt: time, receivedAt: time, source: source, enteredPrice: quoteMode ? nil : Money("0.7")),
        longLeg: nil,
        underlying: .init(symbol: "COST", bid: quoteMode ? Money("44.9") : nil, ask: quoteMode ? Money("44.94") : nil,
            quotedAt: time, receivedAt: time, source: source, enteredPrice: quoteMode ? nil : Money("44.92")),
        capital: quoteMode ? .init(origin: .manual, reference: "Explicit fixture balances", asOf: time,
            cashBeforeTrade: Money("10000"), committedCash: Money("0"), availableShares: Money("2000"), committedShares: Money("0")) : nil,
        policy: .init(lambda: Money("0.25"), openingFeePerContract: Money("0.65"), ticketFee: Money(ticketFee), terminalFeeTotal: Money(terminalFee)),
        expiry: .init(date: date, settlementAt: ccDate("2026-11-20T21:00:00.000Z"), source: source),
        scenarioPrices: [Money("44.92"), Money("60"), Money("70")],
        pricing: pricing ? .init(rate: Money("0.05"), dividendYield: Money("0"), volatility: Money("0.3"), source: source) : nil,
        entryMode: quoteMode ? nil : .contractParameters, coveredCallCostPerShare: cost.map(Money.init))
}
private func ccReplacingCost(_ input: OptionLabInput, _ cost: Money?) -> OptionLabInput {
    .init(id: input.id, createdAt: input.createdAt, asOf: input.asOf, strategy: input.strategy,
        shortLeg: input.shortLeg, longLeg: input.longLeg, underlying: input.underlying,
        capital: input.capital, policy: input.policy, expiry: input.expiry, scenarioPrices: input.scenarioPrices,
        pricing: input.pricing, risk: input.risk, scenario: input.scenario, chainEvidence: input.chainEvidence,
        entryMode: input.entryMode, coveredCallCostPerShare: cost)
}
private func ccPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("covered-cost-" + UUID().uuidString + ".sqlite") }

@Suite("Optional covered-call acquisition cost stays separate from current-price economics")
struct OptionCoveredCallCostTests {
    @Test func enteredCostAddsExactSeparateOutcomeAndNeverChangesForwardResult() throws {
        let input = try ccInput(), report = try OptionLabEngine.calculate(input)
        let previous = try OptionLabEngine.calculate(ccReplacingCost(input, nil))
        let cost = try #require(report.coveredCallCostBasis), selected = cost.selectedOutcome
        #expect(report.schemaVersion == OptionLabEngine.coveredCostSchemaVersion)
        #expect(cost.schemaVersion == OptionLabEngine.coveredCostReportSchemaVersion)
        let expectedCost = try Money("50"), expectedShares = try Money("1000")
        #expect(cost.costPerShare == expectedCost && cost.coveredShares == expectedShares)
        #expect(selected.netCreditTotal == (try Money("693.5")))
        #expect(selected.maxProfit == (try Money("10693.5")))
        #expect(selected.maxLoss == (try Money("49306.5")))
        #expect(selected.breakEven == (try Money("49.3065")))
        let zero = try Money("0"), strike = try Money("60"), root = try #require(selected.breakEven)
        #expect(selected.points.first { $0.spot == zero }?.pnl == (try Money("-49306.5")))
        #expect(selected.points.first { $0.spot == strike }?.pnl == (try Money("10693.5")))
        #expect(selected.points.first { $0.spot == root }?.pnl == zero)
        #expect(report.mid == previous.mid && report.conservative == previous.conservative)
        #expect(report.selectedOutcome.maxProfit == (try Money("15773.5")))
        #expect(report.selectedOutcome.maxLoss == (try Money("44226.5")))
        #expect(report.selectedOutcome.breakEven == (try Money("44.2265")))
        #expect(report.model == previous.model && report.parameters == previous.parameters)
        #expect(report.limitations == previous.limitations)
        #expect(report.input.capital == nil && report.selectedOutcome.funding == .notAssessed)
        #expect(report.pricing == nil && report.risk == nil && report.scenario == nil)
        #expect(cost.model.defaultParameters == cost.parameterReference)
        #expect(cost.model.numericPolicyVersion == Money.numericPolicyVersion)
    }

    @Test(arguments: ["0|60693.5|0|none", "0.6935|60000|0|0", "60.6935|0|60000|60",
                      "60.7|-6.5|60006.5|none", "60.69350000000000000001|-0.00000000000000001|60000.00000000000000001|none"])
    func zeroCostZeroRootsAndAlwaysLosingPositionsKeepHonestBoundaries(_ vector: String) throws {
        let fields = vector.split(separator: "|").map(String.init)
        try #require(fields.count == 4)
        let report = try OptionLabEngine.calculate(ccInput(cost: fields[0]))
        let value = try #require(report.coveredCallCostBasis).selectedOutcome
        #expect(value.maxProfit == (try Money(fields[1])))
        #expect(value.maxLoss == (try Money(fields[2])))
        if fields[3] == "none" { #expect(value.breakEven == nil) }
        else { #expect(value.breakEven == (try Money(fields[3]))) }
        if fields[0] == "60.6935" {
            let strike = try Money("60")
            #expect(value.points.filter { $0.spot >= strike }.allSatisfy { $0.pnl.amount == 0 })
        }
        #expect(value.points.contains { $0.spot.amount == 0 })
        #expect(Set(value.points.map { $0.spot.decimalString }).count == value.points.count)
    }

    @Test func feesAndCoveredQuantityAreAppliedExactlyOnce() throws {
        let report = try OptionLabEngine.calculate(ccInput(ticketFee: "2", terminalFee: "3"))
        let cost = try #require(report.coveredCallCostBasis).selectedOutcome
        #expect(report.selectedOutcome.totalFees == (try Money("11.5")))
        #expect(cost.netCreditTotal == (try Money("688.5")))
        #expect(cost.maxProfit == (try Money("10688.5")))
        #expect(cost.maxLoss == (try Money("49311.5")))
        #expect(cost.breakEven == (try Money("49.3115")))
        let one = try #require(OptionLabEngine.calculate(ccInput(quantity: 1)).coveredCallCostBasis)
        #expect(one.coveredShares == (try Money("100")))
        #expect(one.selectedOutcome.maxProfit == (try Money("1069.35")))
        #expect(one.selectedOutcome.maxLoss == (try Money("4930.65")))
    }

    @Test func twoSidedQuotesAndPricingRetainTheirCurrentPriceBasis() throws {
        let input = try ccInput(quoteMode: true, pricing: true)
        let base = try OptionLabEngine.calculate(ccReplacingCost(input, nil)), report = try OptionLabEngine.calculate(input)
        let cost = try #require(report.coveredCallCostBasis)
        #expect(cost.mid.pricing == .mid && cost.conservative.pricing == .conservative)
        #expect(cost.selectedOutcome == cost.conservative)
        #expect(cost.mid.netCreditTotal == report.mid.netCreditTotal)
        #expect(cost.conservative.netCreditTotal == report.conservative.netCreditTotal)
        #expect(cost.mid.maxProfit != cost.conservative.maxProfit)
        #expect(report.mid == base.mid && report.conservative == base.conservative)
        #expect(report.underlyingMid == base.underlyingMid && report.pricing == base.pricing)
        #expect(report.modelReference == base.modelReference && report.parameterReference == base.parameterReference)
        #expect(report.input.capital == base.input.capital)
    }

    @Test func missingCostPreservesLegacySchemasAndDoesNotFillFromCurrentPrice() throws {
        let report = try OptionLabEngine.calculate(ccInput(cost: nil))
        #expect(report.schemaVersion == OptionLabEngine.contractSchemaVersion)
        #expect(report.coveredCallCostBasis == nil && report.input.coveredCallCostPerShare == nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["coveredCallCostBasis"] == nil)
        let inputObject = try #require(object["input"] as? [String: Any])
        #expect(inputObject["coveredCallCostPerShare"] == nil)
        // Old JSON explicitly lacks both new keys and still replays exactly.
        object.removeValue(forKey: "coveredCallCostBasis")
        let restored = try JSONDecoder().decode(OptionLabReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try OptionLabEngine.replay(restored) == report)
        for fixture in ["options-legacy-v1", "options-legacy-v2"] {
            let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "json"))
            let old = try JSONDecoder().decode(OptionLabReport.self, from: Data(contentsOf: url))
            #expect(old.coveredCallCostBasis == nil && old.input.coveredCallCostPerShare == nil)
            #expect(try OptionLabEngine.replay(old) == old)
        }
    }

    @Test(arguments: OptionLabStrategy.allCases)
    func explicitCostOnlyAcceptsCoveredCalls(_ strategy: OptionLabStrategy) throws {
        let base = try OptionLabDemo.input(strategy: strategy), input = ccReplacingCost(base, try Money("50"))
        if strategy == .coveredCall { #expect(try OptionLabEngine.calculate(input).coveredCallCostBasis != nil) }
        else { #expect(throws: OptionLabError.invalidCostBasis) { try OptionLabEngine.calculate(input) } }
    }

    @Test func negativeOrUnrepresentableCostIsRejectedWithoutPartialReport() throws {
        #expect(throws: OptionLabError.invalidCostBasis) { try OptionLabEngine.calculate(ccInput(cost: "-0.01")) }
        #expect(throws: MoneyError.precisionExceeded) {
            try OptionLabEngine.calculate(ccInput(cost: "99999999999999999999999999999999999999"))
        }
    }

    @Test func costReportJSONRoundTripBindsInputModelAndEveryOutcome() throws {
        let report = try OptionLabEngine.calculate(ccInput())
        let decoded = try JSONDecoder().decode(OptionLabReport.self, from: JSONEncoder().encode(report))
        #expect(try OptionLabEngine.replay(decoded) == report)
        #expect(decoded.coveredCallCostBasis == report.coveredCallCostBasis)
    }

    @Test(arguments: ["inputCost", "costResult", "costModel", "costParameters", "costShares", "missingCostReport", "missingInputCost"])
    func alteredInputOrCachedCostEvidenceCannotReplay(_ kind: String) throws {
        let report = try OptionLabEngine.calculate(ccInput())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var cost = try #require(object["coveredCallCostBasis"] as? [String: Any])
        switch kind {
        case "inputCost", "missingInputCost":
            var input = try #require(object["input"] as? [String: Any])
            if kind == "inputCost" { input["coveredCallCostPerShare"] = "51" }
            else { input.removeValue(forKey: "coveredCallCostPerShare") }
            object["input"] = input
        case "costResult":
            var outcome = try #require(cost["mid"] as? [String: Any]); outcome["maxProfit"] = "999"
            cost["mid"] = outcome; object["coveredCallCostBasis"] = cost
        case "costModel":
            var model = try #require(cost["model"] as? [String: Any]); model["formulaVersion"] = "changed"
            cost["model"] = model; object["coveredCallCostBasis"] = cost
        case "costParameters":
            var parameters = try #require(cost["parameters"] as? [String: Any]); parameters["version"] = "CHANGED"
            cost["parameters"] = parameters; object["coveredCallCostBasis"] = cost
        case "costShares": cost["coveredShares"] = "1"; object["coveredCallCostBasis"] = cost
        default: object.removeValue(forKey: "coveredCallCostBasis")
        }
        let tampered = try JSONDecoder().decode(OptionLabReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: OptionLabError.incompatibleReport) { try OptionLabEngine.replay(tampered) }
    }

    @Test func costInputAndBothReportsSurviveStoreReopenAndArchiveRestore() async throws {
        let sourcePath = ccPath(), restoredPath = ccPath()
        defer {
            try? FileManager.default.removeItem(at: sourcePath)
            try? FileManager.default.removeItem(at: restoredPath)
        }
        let database = try DatabaseStore(path: sourcePath.path, purpose: .optionsLab)
        let store = try OptionLabStore(database: database), input = try ccInput()
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let reopened = try OptionLabStore(path: sourcePath.path)
        #expect(try await reopened.open(id: input.id) == saved)
        #expect(saved.report.coveredCallCostBasis?.selectedOutcome.maxProfit == (try Money("10693.5")))
        let original = try database.read(OptionLabArchiveState.capture)
        let archive = try await store.makeArchiveStore().exportArchive()
        let target = try DatabaseStore(path: restoredPath.path, purpose: .optionsLab)
        let transfer = try OptionLabArchiveStore(database: target)
        let plan = try await transfer.prepareRestore(archive, mode: .replace, expectedRevision: transfer.status().revision)
        #expect(try await transfer.commit(.init(plan: plan)).counts.experiments == 1)
        #expect(try target.read(OptionLabArchiveState.capture).tables == original.tables)
        let restored = try OptionLabStore(path: restoredPath.path), opened = try await restored.open(id: input.id)
        #expect(opened == saved && opened.replayMatched)
        #expect(opened.report.input.coveredCallCostPerShare == (try Money("50")))
        #expect(try OptionLabEngine.replay(opened.report) == saved.report)
    }
}
