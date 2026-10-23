import Foundation
import Testing
import CoreDomain
@testable import PortfolioEngine

/// Local mathematical vectors only; labels are deliberately varied to exercise
/// rejection of synthetic markers. They are not real-account evidence.
struct OptionPersonalHistoryFixture {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let ledgerRevision = UUID(uuidString: "30FD50E1-A130-4AE2-943F-C3394F210001")!
    func option() throws -> LedgerOptionVersion {
        try .init(occSymbol: "ABC   231117P00100000", versionID: "v1", effectiveFrom: base.addingTimeInterval(-100),
              quoteMultiplier: Money("100"), exerciseConsideration: Money("10000"),
              deliverables: [.init(security: .init(id: "ABC", symbol: "ABC"), quantity: Money("100"), basisWeight: Money("1"))],
              deliverableCash: Money("0"), tradingEndsAt: base.addingTimeInterval(10000),
              exerciseDeadline: base.addingTimeInterval(11000), settlementAt: base.addingTimeInterval(12000),
              memoReferences: ["explicit local contract record"])
    }
    func event(_ id: String, at: Double, accountID: String, payload: LedgerPayload, synthetic: Bool = false) -> LedgerEvent {
        .init(id: id, accountID: accountID, effectiveAt: base.addingTimeInterval(at),
              source: .init(sourceSystem: synthetic ? "synthetic-manual" : "user-record", externalTransactionID: id,
                            evidence: "explicit local statement"), payload: payload)
    }
    func report(count: Int, zero: Bool = false, otherRoots: Bool = false, synthetic: Bool = false,
                typedSynthetic: Bool = false, accountID: String = "personal", ledgerRevision: UUID? = nil) throws -> PerformanceReport {
        let option = try option(), account = LedgerAccount(id: accountID, name: "Local account " + accountID)
        // Every option opening requires a strategy. Total return deliberately
        // stays purpose-unverified without separate outcome evidence; it must
        // not manufacture a purpose success from a positive or zero P&L.
        let strategy = LedgerStrategy(id: "history-total-return", purpose: .totalReturn,
            successDefinition: "Completed economic return with separately evidenced purpose outcome")
        var events = [try event("deposit", at: 0, accountID: accountID,
            payload: .cash(.init(kind: .deposit, amount: Money("1000000"))))]
        for index in 0..<count {
            events.append(try event("short-\(index)", at: Double(index * 2 + 1), accountID: accountID,
                payload: .trade(.init(instrument: .option(option), side: .sell, effect: .open,
                    quantity: Money("1"), unitPrice: Money("2"), fee: Money(zero ? "0" : "1"),
                    openingLotID: "short-\(index)", strategy: strategy)), synthetic: synthetic))
            events.append(try event("close-\(index)", at: Double(index * 2 + 2), accountID: accountID,
                payload: .trade(.init(instrument: .option(option), side: .buy, effect: .close,
                    quantity: Money("1"), unitPrice: Money(zero ? "2" : (index.isMultiple(of: 2) ? "1" : "3")), fee: Money(zero ? "0" : "1")))))
        }
        if otherRoots {
            let stock = LedgerInstrument.equity(.init(id: "ABC", symbol: "ABC"))
            events += [
                try event("stock-open", at: 1001, accountID: accountID, payload: .trade(.init(instrument: stock,
                    side: .buy, effect: .open, quantity: Money("1"), unitPrice: Money("10"), fee: Money("0"), openingLotID: "stock"))),
                try event("stock-close", at: 1002, accountID: accountID, payload: .trade(.init(instrument: stock,
                    side: .sell, effect: .close, quantity: Money("1"), unitPrice: Money("12"), fee: Money("0")))),
                try event("long-open", at: 1003, accountID: accountID, payload: .trade(.init(instrument: .option(option),
                    side: .buy, effect: .open, quantity: Money("1"), unitPrice: Money("2"), fee: Money("0"),
                    openingLotID: "long", strategy: strategy))),
                try event("long-close", at: 1004, accountID: accountID, payload: .trade(.init(instrument: .option(option),
                    side: .sell, effect: .close, quantity: Money("1"), unitPrice: Money("3"), fee: Money("0"))))]
        }
        let evidence = PerformanceEvidence(id: "calendar", source: "user declaration", kind: typedSynthetic ? .synthetic : .userConfirmed,
            availableAt: base.addingTimeInterval(-1), reference: "explicit observation date", rawDocument: Data("local fixture bytes".utf8))
        let request = PerformanceRequest(accountID: accountID, calculatedAt: base.addingTimeInterval(6000),
            calendar: .init(tradingDays: ["2023-11-14"], evidence: evidence),
            days: [.init(day: "2023-11-14", valuationAt: base.addingTimeInterval(5000), sessions: [], prices: [])])
        return try PerformanceEngine.calculate(.init(request: request, ledgerRevision: ledgerRevision ?? self.ledgerRevision,
                                                      accounts: [account], events: events))
    }
}

@Suite("Personal sold-option history projection")
struct OptionPersonalHistoryTests {
    @Test(arguments: [0, 29, 30]) func existingSampleThresholdAndWilsonAreUnchanged(_ count: Int) throws {
        let report = try OptionPersonalHistoryFixture().report(count: count)
        let projection = try OptionPersonalHistory(report: report)
        #expect(projection.statistics == (try PerformanceRounds.statistics(report.rounds)))
        #expect(projection.statistics.eligibleN == count)
        #expect((projection.statistics.winRate.value != nil) == (count >= 30))
        #expect((projection.statistics.winRateInterval.low != nil) == (count >= 30))
        if count == 30 {
            #expect(projection.statistics.winRate.value == 0.5)
            #expect(abs(try #require(projection.statistics.winRateInterval.low) - 0.3315412564053376) < 1e-12)
        }
    }

    @Test func zeroPnLAndUnknownPurposeDoNotBecomeLossOrSuccess() throws {
        let projection = try OptionPersonalHistory(report: OptionPersonalHistoryFixture().report(count: 30, zero: true))
        #expect(projection.statistics.zeros == 30)
        #expect(projection.statistics.wins == 0 && projection.statistics.losses == 0)
        #expect(projection.statistics.winRate.value == 0)
        #expect(projection.statistics.purposeSuccessRate.value == nil)
        #expect(projection.statistics.purposeSuccessRate.sampleCount == 0)
        #expect(projection.rounds.allSatisfy { $0.purposeState == .unverified })
    }

    @Test func onlySoldOptionRootsKeepExistingNetFees() throws {
        let projection = try OptionPersonalHistory(report: OptionPersonalHistoryFixture().report(count: 1, otherRoots: true))
        #expect(projection.excludedRoundCount == 2)
        #expect(projection.rounds.map(\.roundLotID) == ["short-0"])
        #expect(projection.rounds[0].netPnL == (try Money("98")))
        #expect(projection.statistics.eligibleN == 1)
    }

    @Test func syntheticTypedEvidenceAndLedgerMarkersAreRejected() throws {
        let f = OptionPersonalHistoryFixture()
        #expect(throws: OptionPersonalHistoryError.syntheticEvidence) {
            try OptionPersonalHistory(report: f.report(count: 1, synthetic: true))
        }
        #expect(throws: OptionPersonalHistoryError.syntheticEvidence) {
            try OptionPersonalHistory(report: f.report(count: 1, typedSynthetic: true))
        }
    }

    @Test func incompleteEconomicRoundRemainsExcludedFromFrequency() throws {
        let f = OptionPersonalHistoryFixture(), base = try f.report(count: 1), option = try f.option()
        let events = Array(base.input.events.prefix(2)) + [try f.event("assign", at: 2, accountID: "personal",
            payload: .optionSettlement(.init(contract: option, action: .assignment, side: .short,
                quantity: Money("1"), fee: Money("0"), acquiredLotIDs: ["ABC": "assigned-shares"], evidence: "explicit assignment")))]
        let report = try PerformanceEngine.calculate(.init(request: base.input.request, ledgerRevision: base.input.ledgerRevision,
                                                           accounts: base.input.accounts, events: events))
        let projection = try OptionPersonalHistory(report: report)
        #expect(projection.statistics.displayN == 1 && projection.statistics.eligibleN == 0)
        #expect(projection.rounds.first?.economicState == .open)
        #expect(projection.statistics.winRate.value == nil)
    }

    @Test func cachedRoundAmountCannotBypassFrozenInputReplay() throws {
        let report = try OptionPersonalHistoryFixture().report(count: 1)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var rounds = try #require(json["rounds"] as? [[String: Any]])
        try #require(rounds.count == 1)
        rounds[0]["netPnL"] = "9999"; json["rounds"] = rounds
        let changed = try JSONDecoder().decode(PerformanceReport.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: OptionPersonalHistoryError.unverifiedReport) { try OptionPersonalHistory(report: changed) }
    }

    @Test func reportStartDoesNotSilentlyRedefineExistingCumulativeSample() throws {
        let f = OptionPersonalHistoryFixture(), old = try f.report(count: 1)
        let cutoff = old.input.request.calculatedAt.addingTimeInterval(86400)
        let request = PerformanceRequest(accountID: old.input.request.accountID, calculatedAt: cutoff,
            calendar: .init(tradingDays: ["2023-11-15"], evidence: old.input.request.calendar.evidence),
            days: [.init(day: "2023-11-15", valuationAt: cutoff, sessions: [], prices: [])])
        let report = try PerformanceEngine.calculate(.init(request: request, ledgerRevision: old.input.ledgerRevision,
                                                           accounts: old.input.accounts, events: old.input.events))
        let projection = try OptionPersonalHistory(report: report)
        #expect(projection.statistics.eligibleN == 1)
        #expect(projection.asOf == cutoff)
        #expect(OptionPersonalHistory.statisticsScope.contains("报告期初前"))
    }
}
