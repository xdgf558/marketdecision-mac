import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
@testable import PortfolioEngine

@Suite("Portfolio Greeks ledger weighting and frozen replay")
struct PortfolioGreeksEngineTests {
    @Test func weightsLedgerLongShortAndFractionalSharesNotStrategyQuantityOrCoveredStock() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let report = try PortfolioGreeksEngine.calculate(input)
        let call = try #require(input.reports[0].pricing?.legs[0].canonicalGreeks)
        let put = try #require(input.reports[1].pricing?.legs[0].canonicalGreeks)
        let values = try #require(report.completeTotals)
        // Independent portfolio vector: +200 call shares, -100 call shares, -100 put shares,
        // +12.5 DEMO stock, +3.25 ALT stock. Source strategy has N=900 and must not be reused.
        #expect(abs(values.netDeltaDollars - ((100 * call.delta + 12.5) * 100 + (-100 * put.delta + 3.25) * 50)) < 1e-8)
        let longCallDeltaDollars: Double = 200 * call.delta * 100
        let shortCallDeltaDollars: Double = -100 * call.delta * 100
        let shortPutDeltaDollars: Double = -100 * put.delta * 50
        let expectedGrossDeltaDollars: Double = abs(longCallDeltaDollars) + abs(shortCallDeltaDollars) + abs(shortPutDeltaDollars) + 1250 + 162.5
        #expect(abs(values.grossDeltaDollars - expectedGrossDeltaDollars) < 1e-8)
        #expect(abs(values.thetaDollarsPerDay - (100 * call.thetaPerDay - 100 * put.thetaPerDay)) < 1e-10)
        #expect(abs(values.vegaDollarsPerPercentagePoint - (100 * call.vegaPerPercentagePoint - 100 * put.vegaPerPercentagePoint)) < 1e-10)
        #expect(abs(values.rhoDollarsPerPercentagePoint - (100 * call.rhoPerPercentagePoint - 100 * put.rhoPerPercentagePoint)) < 1e-10)
        #expect(report.rows.first { $0.id == "stock-long-lot" }?.values?.deltaShares == 12.5)
        #expect(report.rows.first { $0.id == "stock-alt-lot" }?.values?.deltaShares == 3.25)
        #expect(report.coverage.isComplete)
    }
    @Test func missingBindingRetainsCoveredPortionButPreventsCompleteSummary() throws {
        let report = try PortfolioGreeksEngine.calculate(PortfolioGreeksDemo.input())
        #expect(report.coverage.coveredPositions == 5)
        #expect(report.coverage.totalPositions == 6)
        #expect(report.coverage.missingPositions == 1)
        #expect(report.completeTotals == nil)
        #expect(report.coveredTotals != nil)
        #expect(report.rows.first { $0.id == "uncovered-lot" }?.gap == .missingBinding)
        #expect(report.groups.first { $0.underlyingSymbol == "GAP" }?.covered == nil)
    }
    @Test func underlyingAndExpiryGroupsDoNotExposeCrossUnderlyingRawGreeks() throws {
        let report = try PortfolioGreeksEngine.calculate(PortfolioGreeksDemo.input(includeMissing: false))
        #expect(report.groups.count == 4)
        #expect(Set(report.groups.map(\.underlyingID)).count == 2)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let totals = try #require(json["completeTotals"] as? [String: Any])
        #expect(totals["deltaShares"] == nil)
        #expect(totals["gammaSharesPerDollar"] == nil)
        let stock = try #require(report.groups.first { $0.underlyingSymbol == "DEMO" && $0.expirationDate == nil })
        #expect(stock.complete?.gammaSharesPerDollar == 0)
        #expect(stock.complete?.vegaDollarsPerPercentagePoint == 0)
    }
    @Test func duplicatesAndUnknownBindingsReject() throws {
        let input = try PortfolioGreeksDemo.input()
        #expect(throws: PortfolioGreeksError.duplicateBinding) { try PortfolioGreeksEngine.calculate(copy(input, bindings: input.bindings + [input.bindings[0]])) }
        #expect(throws: PortfolioGreeksError.duplicateReport) { try PortfolioGreeksEngine.calculate(copy(input, reports: input.reports + [input.reports[0]])) }
        let unknown = PortfolioGreeksBinding(instrumentIdentity: "equity:other", reportID: input.reports[0].input.id)
        #expect(throws: PortfolioGreeksError.unknownBinding) { try PortfolioGreeksEngine.calculate(copy(input, bindings: input.bindings + [unknown])) }
    }
    @Test func absentReportAndContractAreGapsNotZero() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        var bindings = input.bindings
        bindings[0] = .init(instrumentIdentity: bindings[0].instrumentIdentity, reportID: UUID())
        bindings[2] = .init(instrumentIdentity: bindings[2].instrumentIdentity, reportID: bindings[2].reportID, contractID: "wrong")
        let report = try PortfolioGreeksEngine.calculate(copy(input, bindings: bindings))
        #expect(report.rows.first { $0.id == "stock-long-lot" }?.gap == .missingReport)
        #expect(report.rows.first { $0.id == "call-long-lot" }?.gap == .missingContract)
        #expect(report.completeTotals == nil)
    }
    @Test func ordinaryLedgerRejectsSyntheticSourceEvidence() throws {
        let input = try PortfolioGreeksDemo.input()
        #expect(throws: PortfolioGreeksError.syntheticEvidence) { try PortfolioGreeksEngine.calculate(copy(input, mode: .ledger)) }
    }
    @Test func manualOfflineSourcesRemainResearchOnly() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let reports = try input.reports.map { report in
            let changed = try mutate(report.input) { json in rewriteOrigins(&json) }
            return try OptionLabEngine.calculate(changed)
        }
        let result = try PortfolioGreeksEngine.calculate(copy(input, mode: .ledger, reports: reports))
        #expect(result.researchOnly)
        #expect(result.completeTotals != nil)
        #expect(result.limitations.contains { $0.contains("没有原始 recordedAt") })
    }
    @Test func missingPricingDoesNotInventGreeksFromStrategyOutputs() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let source = try mutate(input.reports[0].input) { $0.removeValue(forKey: "pricing") }
        let changed = try OptionLabEngine.calculate(source)
        let report = try PortfolioGreeksEngine.calculate(copy(input, reports: [changed, input.reports[1]]))
        #expect(report.rows.first { $0.id == "call-long-lot" }?.gap == .missingPricing)
        #expect(report.rows.first { $0.id == "stock-long-lot" }?.values?.deltaShares == 12.5)
        #expect(report.completeTotals == nil)
    }
    @Test func unavailableIVDoesNotFallBackToManualSigma() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let source = try mutate(input.reports[0].input) { json in
            var leg = json["shortLeg"] as! [String: Any]
            leg["bid"] = "0.01"; leg["ask"] = "0.02"; json["shortLeg"] = leg
        }
        let changed = try OptionLabEngine.calculate(source)
        #expect(changed.pricing?.legs[0].canonicalGreeks == nil)
        let report = try PortfolioGreeksEngine.calculate(copy(input, reports: [changed, input.reports[1]]))
        #expect(report.rows.first { $0.id == "call-long-lot" }?.gap == .missingIV)
        #expect(report.completeTotals == nil)
    }
    @Test func commonAsOfRequiredAndFutureCreatedEvidenceRejected() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let shifted = copy(input, createdAt: input.createdAt.addingTimeInterval(60), asOf: input.asOf.addingTimeInterval(10))
        let report = try PortfolioGreeksEngine.calculate(shifted)
        #expect(report.coverage.coveredPositions == 0)
        #expect(report.rows.allSatisfy { $0.gap == .mismatchedAsOf })
        #expect(throws: PortfolioGreeksError.invalidInput) { try PortfolioGreeksEngine.calculate(copy(input, createdAt: input.asOf)) }
        #expect(throws: PortfolioGreeksError.invalidInput) { try PortfolioGreeksEngine.calculate(copy(input, createdAt: input.asOf.addingTimeInterval(-1))) }
    }
    @Test func independentlyTimedUnderlyingQuotesCannotMixEvenWithSameAsOf() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let original = input.reports[0]
        let changed = try mutate(original.input) { json in
            json["id"] = UUID().uuidString
            var under = json["underlying"] as! [String: Any]
            under["quotedAt"] = original.input.asOf.addingTimeInterval(-1).timeIntervalSinceReferenceDate
            json["underlying"] = under
        }
        let second = try OptionLabEngine.calculate(changed)
        var bindings = input.bindings
        bindings[0] = .init(instrumentIdentity: bindings[0].instrumentIdentity, reportID: second.input.id)
        let report = try PortfolioGreeksEngine.calculate(copy(input, reports: input.reports + [second], bindings: bindings))
        #expect(report.rows.filter { $0.underlyingSymbol == "DEMO" }.allSatisfy { $0.gap == .inconsistentUnderlying })
        #expect(report.rows.filter { $0.underlyingSymbol == "ALT" }.allSatisfy { $0.values != nil })
    }
    @Test func differentUnderlyingPricesCannotBeMixedBehindIdenticalSymbol() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let changed = try mutate(input.reports[0].input) { json in
            json["id"] = UUID().uuidString
            var under = json["underlying"] as! [String: Any]
            under["bid"] = "99.8"; under["ask"] = "100.2"; json["underlying"] = under
        }
        let second = try OptionLabEngine.calculate(changed)
        var bindings = input.bindings; bindings[0] = .init(instrumentIdentity: bindings[0].instrumentIdentity, reportID: second.input.id)
        let report = try PortfolioGreeksEngine.calculate(copy(input, reports: input.reports + [second], bindings: bindings))
        #expect(report.rows.filter { $0.underlyingSymbol == "DEMO" }.allSatisfy { $0.gap == .inconsistentUnderlying })
    }
    @Test func mismatchedContractSpecificationAndSettlementRemainExplicitGaps() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let changed = try mutate(input) { json in
            var events = json["events"] as! [[String: Any]]
            for index in [2, 3] {
                var event = events[index], payload = event["payload"] as! [String: Any]
                var tradeCase = payload["trade"] as! [String: Any], trade = tradeCase["_0"] as! [String: Any]
                var instrument = trade["instrument"] as! [String: Any], option = instrument["option"] as! [String: Any]
                var value = option["_0"] as! [String: Any]; value["versionID"] = "different-version"
                option["_0"] = value; instrument["option"] = option; trade["instrument"] = instrument
                tradeCase["_0"] = trade; payload["trade"] = tradeCase; event["payload"] = payload; events[index] = event
            }
            json["events"] = events
            var bindings = json["bindings"] as! [[String: Any]]
            bindings[2]["instrumentIdentity"] = input.bindings[2].instrumentIdentity.replacingOccurrences(of: "assumed-us-equity-standard.v1", with: "different-version")
            json["bindings"] = bindings
        }
        let report = try PortfolioGreeksEngine.calculate(changed)
        #expect(report.rows.first { $0.id == "call-long-lot" }?.gap == .mismatchedContract)
        #expect(report.rows.first { $0.id == "stock-long-lot" }?.gap == nil)
    }
    @Test func stockBindingCannotSelectOptionLeg() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        var bindings = input.bindings
        bindings[0] = .init(instrumentIdentity: bindings[0].instrumentIdentity, reportID: bindings[0].reportID, contractID: input.reports[0].input.shortLeg.contractID)
        let report = try PortfolioGreeksEngine.calculate(copy(input, bindings: bindings))
        #expect(report.rows.first { $0.id == "stock-long-lot" }?.gap == .mismatchedContract)
    }
    @Test func futureEffectiveEventsStayFrozenButDoNotEnterSelectedHoldings() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let event = try extraStock(input, id: "future", effectiveAt: input.asOf.addingTimeInterval(1), quantity: "10")
        let result = try PortfolioGreeksEngine.calculate(copy(input, events: input.events + [event]))
        #expect(result.rows.count == 5)
        #expect(result.input.events.count == 6)
        #expect(!result.ledgerState.activeEventIDs.contains("future"))
    }
    @Test func ledgerCorrectionReplayOwnsPositionQuantityAndRevisionIsFrozen() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let reversal = LedgerEvent(id: "reverse-stock", accountID: input.accountID, effectiveAt: input.asOf.addingTimeInterval(-2),
            source: .init(sourceSystem: "SYNTHETIC-PORTFOLIO-GREEKS", externalTransactionID: "reverse-stock", evidence: "correction"),
            payload: .reversal(.init(originalEventID: "stock-long", reason: "quantity corrected")))
        let corrected = try extraStock(input, id: "corrected", effectiveAt: input.asOf.addingTimeInterval(-1), quantity: "7.75")
        let revision = UUID()
        let changed = copy(input, ledgerRevision: revision, events: input.events + [reversal, corrected])
        let result = try PortfolioGreeksEngine.calculate(changed)
        #expect(result.rows.first { $0.id == "stock-long-lot" } == nil)
        #expect(result.rows.first { $0.id == "corrected-lot" }?.values?.deltaShares == 7.75)
        #expect(result.input.ledgerRevision == revision)
        #expect(result.ledgerState.reversedEventIDs == ["stock-long"])
    }
    @Test func noPositionsIsUnavailableNotCompleteZeroRisk() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let result = try PortfolioGreeksEngine.calculate(copy(input, events: [], reports: [], bindings: []))
        #expect(result.rows.isEmpty && result.groups.isEmpty)
        #expect(!result.coverage.isComplete)
        #expect(result.coveredTotals == nil && result.completeTotals == nil)
    }
    @Test func extraAccountOrForeignEventRejected() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let foreign = LedgerAccount(id: "other", name: "Other")
        #expect(throws: PortfolioGreeksError.invalidInput) { try PortfolioGreeksEngine.calculate(copy(input, accounts: input.accounts + [foreign])) }
    }
    @Test func differentSyntheticTemplatesHaveDifferentImmutableIDs() throws {
        let complete = try PortfolioGreeksDemo.input(includeMissing: false)
        let partial = try PortfolioGreeksDemo.input(includeMissing: true)
        #expect(complete.id != partial.id)
        #expect(try PortfolioGreeksDemo.input(includeMissing: false).id == complete.id)
    }
    @Test func sameLedgerSecurityIDCannotHideDifferentSymbolOrAsset() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        for field in ["symbol", "kind"] {
            let changed = try mutate(input) { json in
                var events = json["events"] as! [[String: Any]]
                var event = events[0], payload = event["payload"] as! [String: Any]
                var tradeCase = payload["trade"] as! [String: Any], trade = tradeCase["_0"] as! [String: Any]
                var instrument = trade["instrument"] as! [String: Any], equity = instrument["equity"] as! [String: Any]
                var security = equity["_0"] as! [String: Any]
                security[field] = field == "symbol" ? "OTHER" : "etf"
                equity["_0"] = security; instrument["equity"] = equity; trade["instrument"] = instrument
                tradeCase["_0"] = trade; payload["trade"] = tradeCase; event["payload"] = payload; events[0] = event; json["events"] = events
            }
            #expect(throws: LedgerError.invalidIdentity) { try PortfolioGreeksEngine.calculate(changed) }
        }
    }
    @Test func jsonRoundTripReplaysWithoutExternalLedgerOrReports() throws {
        let encoded = try JSONEncoder().encode(PortfolioGreeksEngine.calculate(PortfolioGreeksDemo.input()))
        let decoded = try JSONDecoder().decode(PortfolioGreeksReport.self, from: encoded)
        #expect(try PortfolioGreeksEngine.replay(decoded) == decoded)
        #expect(decoded.model.defaultParameters == decoded.parameters.reference)
        #expect(decoded.input.reports.count == 2)
    }
    @Test func tamperedTotalOrModelCannotPassReplay() throws {
        let report = try PortfolioGreeksEngine.calculate(PortfolioGreeksDemo.input(includeMissing: false))
        let changed = try mutate(report) { json in
            var total = json["completeTotals"] as! [String: Any]; total["netDeltaDollars"] = 0; json["completeTotals"] = total
        }
        #expect(throws: PortfolioGreeksError.incompatibleReport) { try PortfolioGreeksEngine.replay(changed) }
        let schema = try mutate(report) { $0["schemaVersion"] = "portfolio-greeks-report.future" }
        #expect(throws: PortfolioGreeksError.incompatibleReport) { try PortfolioGreeksEngine.replay(schema) }
    }
    @Test func changedSourceGreeksRequireFullSourceReplay() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let changed = try mutate(input.reports[0]) { json in
            var pricing = json["pricing"] as! [String: Any]
            var legs = pricing["legs"] as! [[String: Any]], greek = legs[0]["canonicalGreeks"] as! [String: Any]
            greek["delta"] = 0; legs[0]["canonicalGreeks"] = greek; pricing["legs"] = legs; json["pricing"] = pricing
        }
        #expect(throws: PortfolioGreeksError.incompatibleReport) { try PortfolioGreeksEngine.calculate(copy(input, reports: [changed, input.reports[1]])) }
    }
    @Test func staleSourceCannotBecomeValidByChangingPortfolioClock() throws {
        let input = try PortfolioGreeksDemo.input(includeMissing: false)
        let changed = try mutate(input.reports[0]) { json in
            var source = json["input"] as! [String: Any], under = source["underlying"] as! [String: Any]
            under["quotedAt"] = input.asOf.addingTimeInterval(-61).timeIntervalSinceReferenceDate
            source["underlying"] = under; json["input"] = source
        }
        #expect(throws: PortfolioGreeksError.incompatibleReport) { try PortfolioGreeksEngine.calculate(copy(input, reports: [changed, input.reports[1]])) }
    }
}

private func copy(_ i: PortfolioGreeksInput, createdAt: Date? = nil, asOf: Date? = nil,
                  mode: PortfolioGreeksMode? = nil, ledgerRevision: UUID? = nil, accounts: [LedgerAccount]? = nil,
                  events: [LedgerEvent]? = nil, reports: [OptionLabReport]? = nil, bindings: [PortfolioGreeksBinding]? = nil) -> PortfolioGreeksInput {
    .init(id: i.id, createdAt: createdAt ?? i.createdAt, asOf: asOf ?? i.asOf, mode: mode ?? i.mode, accountID: i.accountID,
          ledgerRevision: ledgerRevision ?? i.ledgerRevision, accounts: accounts ?? i.accounts, events: events ?? i.events,
          reports: reports ?? i.reports, bindings: bindings ?? i.bindings)
}
private func mutate<T: Codable>(_ value: T, change: (inout [String: Any]) throws -> Void) throws -> T {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    try change(&json)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
}
private func rewriteOrigins(_ json: inout [String: Any]) {
    for key in json.keys {
        if key == "origin", json[key] as? String == "synthetic" { json[key] = "manual" }
        else if var child = json[key] as? [String: Any] { rewriteOrigins(&child); json[key] = child }
        else if var children = json[key] as? [[String: Any]] { for index in children.indices { rewriteOrigins(&children[index]) }; json[key] = children }
    }
}
private func extraStock(_ i: PortfolioGreeksInput, id: String, effectiveAt: Date, quantity: String) throws -> LedgerEvent {
    .init(id: id, accountID: i.accountID, effectiveAt: effectiveAt,
        source: .init(sourceSystem: "SYNTHETIC-PORTFOLIO-GREEKS", externalTransactionID: id, evidence: "explicit synthetic update"),
        payload: .trade(.init(instrument: .equity(.init(id: "SYNTHETIC-DEMO", symbol: "DEMO")), side: .buy, effect: .open,
            quantity: try Money(quantity), unitPrice: try Money("100"), fee: try Money("0"), openingLotID: id + "-lot")))
}
