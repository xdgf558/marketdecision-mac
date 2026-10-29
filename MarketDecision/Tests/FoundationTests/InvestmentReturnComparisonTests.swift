import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
import AIInsights
@testable import AppComposition

/// Invented local-document fixtures, never real-account or market acceptance.
/// Ordinary evidence is authored directly; no synthetic report is relabeled.
@Suite("Investment share same-period return comparison")
struct InvestmentReturnComparisonTests {
    private let account = LedgerAccount(id: "return-test-account", name: "Local return test account")
    private let days = ["2026-01-05", "2026-01-06", "2026-01-07", "2026-02-05", "2026-02-06"]

    private func date(_ text: String) throws -> Date { try LedgerCSV.timestamp(text) }
    private func close(_ day: String) throws -> Date { try date(day + "T21:00:00Z") }
    private func evidence(synthetic: Bool = false) throws -> PerformanceEvidence {
        try .init(id: "return-test-proof", source: "Hand-authored local test record",
            kind: synthetic ? .synthetic : .localDocument, availableAt: date("2026-01-01T00:00:00Z"),
            reference: "test-only/return-input", rawDocument: Data("Invented local test facts".utf8))
    }
    private func cash(_ id: String, day: String, kind: LedgerCashKind, amount: String) throws -> LedgerEvent {
        try .init(id: id, accountID: account.id, effectiveAt: close(day).addingTimeInterval(-3600),
            source: .init(sourceSystem: "local-test-entry", externalTransactionID: id, evidence: "Explicit test-only cash receipt"),
            payload: .cash(.init(kind: kind, amount: Money(amount))))
    }
    private func report(complete: Bool = true, missingDay: String? = nil, intradayDay: String? = nil,
                        zeroReturn: Bool = false, synthetic: Bool = false) throws -> PerformanceReport {
        var events = try [cash("fund", day: days[0], kind: .deposit, amount: "100"),
                          cash("add", day: days[2], kind: .deposit, amount: "50")]
        if !zeroReturn {
            events += try [cash("gain1", day: days[1], kind: .interest, amount: "10"),
                           cash("gain2", day: days[2], kind: .interest, amount: "11"),
                           cash("gain3", day: days[3], kind: .interest, amount: "17.1"),
                           cash("fee", day: days[4], kind: .fee, amount: "18.81")]
        }
        let proof = try evidence(synthetic: synthetic)
        let definitions = try days.filter { $0 != missingDay }.map { day in
            PerformanceDayInput(day: day, valuationAt: try close(day).addingTimeInterval(day == intradayDay ? -3600 : 0),
                sessions: [], prices: [])
        }
        let request = try PerformanceRequest(accountID: account.id, calculatedAt: close(days[4]).addingTimeInterval(1800),
            calendar: .init(tradingDays: days, evidence: proof), days: definitions,
            externalFlowsComplete: complete, flowCompletenessEvidence: complete ? proof : nil)
        return try PerformanceEngine.calculate(.init(request: request, ledgerRevision: UUID(), accounts: [account], events: events))
    }
    private func saved(_ report: PerformanceReport, replayMatched: Bool = true, current: Bool = true,
                       ledgerRevision: UUID? = nil) -> SavedPerformanceReport {
        .init(id: UUID(), createdAt: report.input.request.calculatedAt, report: report,
            inputHash: "test-input-hash", reportHash: "test-report-hash",
            ledgerRevision: ledgerRevision ?? report.input.ledgerRevision, isCurrentLedger: current, replayMatched: replayMatched)
    }
    private func period(_ report: PerformanceReport) throws -> InvestmentPeriodReport {
        let input = report.input
        let ledger = try LedgerSnapshot(revision: input.ledgerRevision, accounts: input.accounts, events: input.events,
            state: LedgerEngine.replay(accounts: input.accounts, events: input.events))
        return try #require(InvestmentPeriodReport.generate(ledger: ledger, accountID: account.id,
            at: date("2026-02-07T21:30:00Z")).first { $0.period == .month })
    }
    private func snapshot(_ report: PerformanceReport) throws -> InvestmentShareSnapshot {
        let verified = saved(report)
        let returnEvidence = try InvestmentAccountReturnEvidence(saved: verified, accountID: account.id, ledgerRevision: verified.ledgerRevision)
        return try InvestmentShareSnapshot(periodReport: period(report), accountReturn: returnEvidence)
    }
    private func response(_ snapshot: InvestmentShareSnapshot, startDay: String = "2026-01-06",
                          endDay: String = "2026-02-06", endClose: String = "112.5") throws -> AIBenchmarkResult {
        let window = try #require(snapshot.benchmarkWindow)
        let request = AIBenchmarkRequest(start: window.start, end: window.end, model: "offline-test-model")
        let payload: [String: Any] = [
            "status": "available", "index": "S&P500", "returnType": "PRICE_RETURN", "currency": "USD",
            "start": ["day": startDay, "close": "100"], "end": ["day": endDay, "close": endClose],
            "unavailableReason": NSNull()
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let envelope: [String: Any] = [
            "object": "response", "status": "completed", "model": "offline-test-model",
            "output": [
                ["id": "ws_offline_return", "type": "web_search_call", "status": "completed",
                 "action": ["type": "search", "sources": [["type": "url", "url": "https://fred.stlouisfed.org/series/SP500", "title": "Offline reference fixture"]]]],
                ["type": "message", "role": "assistant", "status": "completed",
                 "content": [["type": "output_text", "text": text, "annotations": []]]]
            ]
        ]
        return try request.parseResponse(JSONSerialization.data(withJSONObject: envelope))
    }

    @Test func verifiedFullReportAndIndexUsePercentagesAndPercentagePointDifference() throws {
        let value = try report(), share = try InvestmentShareSnapshot(saved: saved(value))
        let result = try response(share, startDay: days[0])
        let card = share.card(options: .init(), benchmark: result), index = try #require(card.benchmark)
        #expect(abs(try #require(value.twr.value) - 0.1979) < 1e-12)
        #expect(card.accountReturn.isAvailable && card.accountReturn.percentage == "+19.79%")
        #expect(index.percentage == "+12.50%")
        #expect(index.accountReturn == card.accountReturn)
        #expect(index.accountReturn.difference == "+7.29 个百分点")
        #expect(index.accountReturn.dates == "2026-01-05 → 2026-02-06")
        #expect(index.accountReturn.explanation.contains("不含股息"))
    }

    @Test func actualBenchmarkDatesRecalculateSubintervalInsteadOfUsingWholeOrRollingReturn() throws {
        let value = try report(), share = try snapshot(value), result = try response(share)
        let before = share.card(options: .init()), after = share.card(options: .init(), benchmark: result)
        #expect(before.accountReturn.percentage == "-1.00%")
        #expect(before.accountReturn.dates == "2026-01-07 → 2026-02-06")
        #expect(after.accountReturn.percentage == "+8.90%")
        #expect(after.accountReturn.dates == "2026-01-06 → 2026-02-06")
        #expect(after.accountReturn.difference == "-3.60 个百分点")
        #expect(after.accountReturn.percentage != InvestmentSummary.percentText(value.twr.value))
        #expect(after.benchmark?.accountReturn == after.accountReturn)
        #expect(share.supportsReturn)
    }

    @Test func hiddenAccountReturnNeverLeaksItsRateOrDifferenceWhileIndexRemainsPublic() throws {
        let share = try snapshot(report()), result = try response(share)
        var options = InvestmentShareOptions(); options.showReturn = false
        let card = share.card(options: options, benchmark: result)
        #expect(card.accountReturn.isAvailable && card.accountReturn.percentage == "收益率已隐藏")
        #expect(card.accountReturn.difference == nil && card.benchmark?.accountReturn.difference == nil)
        #expect(card.returnText == "收益率已隐藏")
        #expect(card.benchmark?.percentage == "+12.50%")
        #expect(card.amount == "金额已隐藏" && card.breakdown.allSatisfy { $0.value == "金额已隐藏" })
    }

    @Test func intradayEndpointsMissingNAVAndIncompleteFlowsRemainUnavailable() throws {
        let values = try [report(intradayDay: days[1]), report(missingDay: days[2]), report(complete: false)]
        for value in values {
            let share = try snapshot(value), result = try response(share)
            let card = share.card(options: .init(), benchmark: result)
            #expect(!card.accountReturn.isAvailable && card.accountReturn.percentage == "待补净值")
            #expect(card.accountReturn.difference == nil && card.accountReturn.dates == nil)
            #expect(card.benchmark?.percentage == "+12.50%")
            #expect(card.benchmark?.accountReturn == card.accountReturn)
        }
    }

    @Test func actualZeroNAVReturnIsDistinctFromBookedZeroWithoutNAVProof() throws {
        let value = try report(zeroReturn: true)
        let verified = try snapshot(value), index = try response(verified, endClose: "100")
        let accepted = verified.card(options: .init(), benchmark: index)
        #expect(accepted.accountReturn.isAvailable && accepted.accountReturn.percentage == "+0.00%")
        #expect(accepted.accountReturn.difference == "+0.00 个百分点")
        let missing = try InvestmentShareSnapshot(periodReport: period(value)), otherIndex = try response(missing, endClose: "100")
        var options = InvestmentShareOptions(); options.showAmounts = true
        let absent = missing.card(options: options, benchmark: otherIndex)
        #expect(absent.amount == "0.00 USD")
        #expect(!absent.accountReturn.isAvailable && absent.accountReturn.percentage == "待补净值")
        #expect(absent.accountReturn.difference == nil && !missing.supportsReturn)
        #expect(absent.accountReturn.explanation.contains("0 不代表收益率为 0%"))
    }

    @Test func evidenceRejectsWrongAccountStaleRevisionUnverifiedAndSyntheticReports() throws {
        let value = try report(), revision = value.input.ledgerRevision
        #expect(throws: InvestmentAccountReturnError.wrongAccount) {
            try InvestmentAccountReturnEvidence(saved: saved(value), accountID: "other-account", ledgerRevision: revision)
        }
        #expect(throws: InvestmentAccountReturnError.staleReport) {
            try InvestmentAccountReturnEvidence(saved: saved(value), accountID: account.id, ledgerRevision: UUID())
        }
        #expect(throws: InvestmentAccountReturnError.staleReport) {
            try InvestmentAccountReturnEvidence(saved: saved(value, current: false), accountID: account.id, ledgerRevision: revision)
        }
        let different = UUID()
        #expect(throws: InvestmentAccountReturnError.staleReport) {
            try InvestmentAccountReturnEvidence(saved: saved(value, ledgerRevision: different), accountID: account.id, ledgerRevision: different)
        }
        #expect(throws: InvestmentAccountReturnError.unverifiedReport) {
            try InvestmentAccountReturnEvidence(saved: saved(value, replayMatched: false), accountID: account.id, ledgerRevision: revision)
        }
        let example = try report(synthetic: true)
        #expect(throws: InvestmentAccountReturnError.syntheticReport) {
            try InvestmentAccountReturnEvidence(saved: saved(example), accountID: account.id, ledgerRevision: example.input.ledgerRevision)
        }
    }

    @Test func candidateUsesNewestCoveringCurrentAccountAndLedgerCatalogOnly() throws {
        let value = try report(), share = try snapshot(value), window = try #require(share.benchmarkWindow), revision = value.input.ledgerRevision
        func item(offset: Double, accountID: String? = nil, ledgerRevision: UUID? = nil, current: Bool = true,
                  end: String = "2026-02-06", version: String = PerformanceEngine.version) -> PerformanceSummary {
            .init(id: UUID(), accountID: accountID ?? account.id, createdAt: value.input.request.calculatedAt.addingTimeInterval(offset),
                startDate: "2026-01-05", endDate: end, dayCount: 5, ledgerRevision: ledgerRevision ?? revision,
                inputHash: "local-input", reportHash: "local-report", engineVersion: version, isCurrentLedger: current)
        }
        let old = item(offset: 0), newest = item(offset: 1)
        let rejected = [item(offset: 10, accountID: "other-account"), item(offset: 11, ledgerRevision: UUID()),
                        item(offset: 12, current: false), item(offset: 13, end: "2026-01-10"), item(offset: 14, version: "unsupported")]
        #expect(InvestmentAccountReturnEvidence.candidate(from: rejected + [newest, old], accountID: account.id,
            ledgerRevision: revision, window: window)?.id == newest.id)
        #expect(InvestmentAccountReturnEvidence.candidate(from: rejected, accountID: account.id,
            ledgerRevision: revision, window: window) == nil)
    }

    @Test func benchmarkFromAnotherWindowCannotSupplyAComparisonOrDifference() throws {
        let value = try report(), share = try snapshot(value), frozen = try InvestmentShareSnapshot(saved: saved(value))
        let unrelated = try response(frozen, startDay: days[0])
        let before = share.card(options: .init()), rejected = share.card(options: .init(), benchmark: unrelated)
        #expect(rejected.benchmark == nil && rejected.accountReturn.difference == nil)
        #expect(rejected.accountReturn == before.accountReturn)
    }

    @Test func bookedSnapshotDropsReturnEvidenceFromAnotherAccountOrLedgerRevision() throws {
        let value = try report(), verified = saved(value)
        let proof = try InvestmentAccountReturnEvidence(saved: verified, accountID: account.id, ledgerRevision: verified.ledgerRevision)
        func otherPeriod(accountID: String, revision: UUID) throws -> InvestmentPeriodReport {
            let accounts = [LedgerAccount(id: accountID, name: "Other local test account")]
            let ledger = try LedgerSnapshot(revision: revision, accounts: accounts, events: [],
                state: LedgerEngine.replay(accounts: accounts, events: []))
            return try #require(InvestmentPeriodReport.generate(ledger: ledger, accountID: accountID,
                at: date("2026-02-07T21:30:00Z")).first { $0.period == .month })
        }
        let rejected = try [otherPeriod(accountID: "different-account", revision: verified.ledgerRevision),
                            otherPeriod(accountID: account.id, revision: UUID())]
        for period in rejected {
            let share = InvestmentShareSnapshot(periodReport: period, accountReturn: proof)
            let card = share.card(options: .init(), benchmark: try response(share))
            #expect(!share.supportsReturn && card.returnText.isEmpty)
            #expect(!card.accountReturn.isAvailable && card.accountReturn.percentage == "待补净值")
            #expect(card.accountReturn.difference == nil && card.benchmark?.accountReturn.difference == nil)
        }
    }
}
