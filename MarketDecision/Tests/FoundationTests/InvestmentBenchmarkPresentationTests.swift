import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
import AIInsights
@testable import AppComposition

@Suite("Share benchmark period binding and private presentation")
struct InvestmentBenchmarkPresentationTests {
    private let sourceURL = "https://fred.stlouisfed.org/series/SP500"
    private var account: LedgerAccount {
        .init(id: "private-benchmark-account", name: "Private benchmark account name")
    }

    private func reports() throws -> [InvestmentPeriodReport] {
        func event(_ id: String, kind: LedgerCashKind, amount: String) throws -> LedgerEvent {
            try .init(id: id, accountID: account.id,
                      effectiveAt: LedgerCSV.timestamp("2026-10-20T14:00:00Z"),
                      source: .init(sourceSystem: "private-benchmark-broker", externalTransactionID: id,
                                    evidence: "private-benchmark-source-evidence"),
                      payload: .cash(.init(kind: kind, amount: Money(amount))))
        }
        let events = try [event("private-benchmark-deposit", kind: .deposit, amount: "2000"),
                          event("private-benchmark-interest", kind: .interest, amount: "23"),
                          event("private-benchmark-fee", kind: .fee, amount: "7")]
        let accounts = [account]
        let ledger = try LedgerSnapshot(revision: UUID(), accounts: accounts, events: events,
                                        state: LedgerEngine.replay(accounts: accounts, events: events))
        return try InvestmentPeriodReport.generate(ledger: ledger, accountID: account.id,
                                                   at: LedgerCSV.timestamp("2026-10-23T20:30:00Z"))
    }

    private func request(_ snapshot: InvestmentShareSnapshot) throws -> AIBenchmarkRequest {
        let window = try #require(snapshot.benchmarkWindow)
        return .init(start: window.start, end: window.end, model: "synthetic-model")
    }

    /// These invented closes exercise presentation only. The URL is metadata in
    /// an offline response fixture; no request is sent to OpenAI or the source.
    private func response(_ request: AIBenchmarkRequest, startDay: String = "2026-09-23",
                          endDay: String = "2026-10-23", endClose: String = "112.5",
                          available: Bool = true, includeSource: Bool = true) throws -> AIBenchmarkResult {
        let payload: [String: Any] = [
            "status": available ? "available" : "unavailable", "index": "S&P500",
            "returnType": "PRICE_RETURN", "currency": "USD",
            "start": available ? ["day": startDay, "close": "100", "sourceURL": sourceURL] : NSNull(),
            "end": available ? ["day": endDay, "close": endClose, "sourceURL": sourceURL] : NSNull(),
            "unavailableReason": available ? NSNull() : "insufficient_evidence"
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let sources: [[String: String]] = includeSource
            ? [["type": "url", "url": sourceURL, "title": "SYNTHETIC benchmark source"]] : []
        let envelope: [String: Any] = [
            "object": "response", "status": "completed", "model": "synthetic-model",
            "output": [
                ["id": "ws_synthetic_presentation", "type": "web_search_call", "status": "completed",
                 "action": ["type": "search", "sources": sources]],
                ["type": "message", "role": "assistant", "status": "completed",
                 "content": [["type": "output_text", "text": text, "annotations": []]]]
            ]
        ]
        return try request.parseResponse(JSONSerialization.data(withJSONObject: envelope))
    }

    private func monthSnapshot() throws -> InvestmentShareSnapshot {
        let report = try #require(reports().first { $0.period == .month })
        return .init(periodReport: report)
    }

    @Test func matchingBenchmarkKeepsPublicPercentageAndMasksEveryPrivateAmount() throws {
        let snapshot = try monthSnapshot(), result = try response(request(snapshot))
        let card = snapshot.card(options: .init(), benchmark: result)
        let benchmark = try #require(card.benchmark)
        #expect(result.reference?.changePercent == (try Money("12.5")))
        #expect(benchmark.percentage == "+12.50%")
        #expect(benchmark.dates == "2026-09-23 → 2026-10-23")
        #expect(benchmark.sources.map(\.url.absoluteString) == [sourceURL])
        #expect(benchmark.qualification == "AI 联网参考 · 未独立核验")
        #expect(card.amount == "金额已隐藏")
        #expect(card.breakdown.count == 3)
        #expect(card.breakdown.allSatisfy { $0.value == "金额已隐藏" })
        #expect(card.holdings.isEmpty)
        var shown = InvestmentShareOptions(); shown.showAmounts = true
        let visible = snapshot.card(options: shown, benchmark: result)
        #expect(visible.amount == "+16.00 USD")
        #expect(visible.benchmark == benchmark)
    }

    @Test func bookedIncomeDoesNotBecomeAccountReturnOrExcessReturn() throws {
        let snapshot = try monthSnapshot(), result = try response(request(snapshot))
        var options = InvestmentShareOptions(); options.showAmounts = true; options.showReturn = true
        let before = snapshot.card(options: options), after = snapshot.card(options: options, benchmark: result)
        #expect(!snapshot.supportsReturn)
        #expect(after.returnLabel == nil && after.returnText.isEmpty)
        #expect(after.profitLabel == "已入账收益")
        #expect(after.amount == before.amount && after.breakdown == before.breakdown)
        #expect(after.scope == before.scope && after.valuationLabel == before.valuationLabel)
        #expect(after.benchmark?.percentage == "+12.50%")
        #expect(after.valuationLabel.contains("不含持仓浮盈、净值或收益率"))
    }

    @Test func changingWindowRejectsPriorReferenceIncludingSubmillisecondChanges() throws {
        let values = try reports()
        let month = InvestmentShareSnapshot(periodReport: try #require(values.first { $0.period == .month }))
        let originalRequest = try request(month), result = try response(originalRequest)
        #expect(month.card(options: .init(), benchmark: result).benchmark != nil)
        for period in [InvestmentReportPeriod.quarter, .year] {
            let snapshot = InvestmentShareSnapshot(periodReport: try #require(values.first { $0.period == period }))
            #expect(snapshot.card(options: .init(), benchmark: result).benchmark == nil)
        }
        let shifted = AIBenchmarkRequest(start: originalRequest.start.addingTimeInterval(0.0004),
                                         end: originalRequest.end, model: originalRequest.model)
        let shiftedResult = try response(shifted)
        #expect(month.card(options: .init(), benchmark: shiftedResult).benchmark == nil)
    }

    @Test func missingOrUnavailableEvidenceNeverBecomesZeroPercent() throws {
        let snapshot = try monthSnapshot(), query = try request(snapshot)
        let unavailable = try response(query, available: false, includeSource: false)
        #expect(unavailable.reference == nil && !unavailable.unavailableReason.isEmpty)
        #expect(snapshot.card(options: .init()).benchmark == nil)
        #expect(snapshot.card(options: .init(), benchmark: unavailable).benchmark == nil)
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try response(query, includeSource: false)
        }
        #expect(snapshot.card(options: .init(), benchmark: unavailable).amount == "金额已隐藏")
    }

    @Test func genuineZeroAndNegativeIndexChangesRemainDistinctFromMissing() throws {
        let snapshot = try monthSnapshot(), query = try request(snapshot)
        let unchanged = try response(query, endClose: "100"), loss = try response(query, endClose: "98")
        #expect(snapshot.card(options: .init(), benchmark: unchanged).benchmark?.percentage == "0.00%")
        #expect(snapshot.card(options: .init(), benchmark: loss).benchmark?.percentage == "-2.00%")
        #expect(snapshot.card(options: .init()).benchmark == nil)
    }

    @Test func frozenReportRetainsOwnTWRAndIndependentBenchmarkDatesAndSources() throws {
        let report = try PerformanceEngine.calculate(PortfolioSyntheticExample.input())
        let saved = SavedPerformanceReport(id: UUID(), createdAt: report.input.request.calculatedAt,
            report: report, inputHash: "private-benchmark-input-hash", reportHash: "private-benchmark-report-hash",
            ledgerRevision: report.input.ledgerRevision, isCurrentLedger: true, replayMatched: true)
        let snapshot = try InvestmentShareSnapshot(saved: saved)
        let query = try request(snapshot)
        #expect(query.start == report.daily.first?.valuationAt)
        #expect(query.end == report.daily.last?.valuationAt)
        // The index fixture deliberately uses the preceding eligible close for
        // its start; the account's period and original TWR must remain unchanged.
        let result = try response(query, startDay: "2025-12-31", endDay: "2026-01-07")
        var options = InvestmentShareOptions(); options.showAmounts = true
        let before = snapshot.card(options: options), after = snapshot.card(options: options, benchmark: result)
        #expect(snapshot.supportsReturn)
        #expect(after.returnLabel == "时间加权收益" && after.returnLabel == before.returnLabel)
        #expect(after.returnText == before.returnText)
        #expect(after.returnText == InvestmentSummary.percentText(InvestmentSummary(report: report).returnValue))
        #expect(after.amount == before.amount && after.period == "2026-01-02 → 2026-01-07")
        #expect(after.benchmark?.dates == "2025-12-31 → 2026-01-07")
        #expect(after.benchmark?.sources.map(\.url.absoluteString) == [sourceURL])
        #expect(after.benchmark?.qualification == "AI 联网参考 · 未独立核验")
        options.showReturn = false
        #expect(snapshot.card(options: options, benchmark: result).returnText == "收益率已隐藏")
    }

    @Test func benchmarkRequestCarriesOnlySnapshotDatesAndModelNeverAccountOrLedger() throws {
        let snapshot = try monthSnapshot(), query = try request(snapshot)
        let encoded = try JSONEncoder().encode(query)
        let descriptor = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(descriptor.keys) == Set(["start", "end", "model"]))
        let bodyData = try query.encodedBody()
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try #require(body["input"] as? [[String: Any]])
        let first = try #require(input.first)
        let content = try #require(first["content"] as? [[String: Any]])
        let contentFirst = try #require(content.first)
        let text = try #require(contentFirst["text"] as? String)
        let search = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(Set(search.keys) == Set(["index", "returnType", "currency", "startCutoffUTC", "endCutoffUTC", "startLatestDay", "endLatestDay"]))
        #expect(search["index"] == "S&P500" && search["returnType"] == "PRICE_RETURN")
        let all = String(decoding: encoded + bodyData, as: UTF8.self)
        for secret in [account.id, account.name, "private-benchmark-broker", "private-benchmark-source-evidence",
                       "private-benchmark-deposit", "private-benchmark-interest", "private-benchmark-fee"] {
            #expect(!all.contains(secret))
        }
    }
}
