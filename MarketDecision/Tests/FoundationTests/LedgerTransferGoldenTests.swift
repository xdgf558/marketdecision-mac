import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
@testable import Persistence

/// Synthetic accounting oracle with literal cash/return expectations. This does
/// not qualify a real broker format, prices, provider or production file panel.
@Suite("Ledger archive complete accounting replay")
struct LedgerTransferGoldenTests {
    @Test func csvWheelSplitCashFlowReportAndArchiveReplayRemainConsistent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let f = LedgerEngineTests()
        let database = try DatabaseStore(path: folder.appendingPathComponent("original.sqlite").path, purpose: .portfolioLedger)
        let ledger = try LedgerStore(database: database)
        let initial = try await ledger.snapshot()
        let account = try await ledger.createAccount(f.account, expectedRevision: initial.revision)
        let csv = Data("timestamp,type,symbol,quantity,unit_price,fee,amount,external_id\r\n2023-11-13T12:00:00Z,DEPOSIT,,,,,20000,qa-deposit\r\n".utf8)
        let importPlan = try await ledger.previewCSV(data: csv, accountID: f.account.id,
            sourceSystem: "synthetic-archive-qa", mapping: .standard, excludedRows: [], expectedRevision: account.revision)
        #expect(importPlan.canCommit)
        let deposited = try await ledger.commit(planID: importPlan.id, expectedRevision: account.revision)

        var events = try PerformanceRoundTests().wheel()
        events += [
            try f.stockBuy("qa-buy", 10, quantity: "3", price: "100", fee: "1"),
            f.event("qa-split", 11, .split(.init(securityID: f.stock.id, ratio: try Money("2"),
                evidence: "SYNTHETIC 2:1 split", confirmedBy: "fixture"))),
            try f.stockSell("qa-sale-1", 12, quantity: "3", price: "60", fee: "1"),
            try f.stockSell("qa-sale-2", 13, quantity: "3", price: "60", fee: "1"),
            f.event("qa-dividend", 14, .cash(.init(kind: .dividend, amount: try Money("6"), securityID: f.stock.id))),
            f.event("qa-next-deposit", 86_400, .cash(.init(kind: .deposit, amount: try Money("500"))))
        ]
        let transactionPlan = try await ledger.previewManual(events: events, expectedRevision: deposited.revision)
        #expect(transactionPlan.canCommit)
        let snapshot = try await ledger.commit(planID: transactionPlan.id, expectedRevision: deposited.revision)
        // 20,000 + Wheel 641 + split-lot sale gain 57 + dividend 6 + deposit 500.
        #expect(snapshot.state.cashByAccount[f.account.id] == (try Money("21204")))
        #expect(snapshot.state.lots.allSatisfy { $0.isClosed })

        let evidence = PerformanceEvidence(id: "qa-calendar-flows", source: "synthetic local oracle", kind: .synthetic,
            availableAt: try LedgerCSV.timestamp("2023-11-13T00:00:00Z"), reference: "fixed accounting calendar/flows",
            rawDocument: Data("SYNTHETIC: calendar and complete external flow attestation".utf8))
        let days = ["2023-11-13", "2023-11-14", "2023-11-15"]
        let request = PerformanceRequest(accountID: f.account.id,
            calculatedAt: try LedgerCSV.timestamp("2023-11-16T00:00:00.0004Z"),
            calendar: .init(tradingDays: days, evidence: evidence),
            days: try days.map { .init(day: $0, valuationAt: try LedgerCSV.timestamp($0 + "T23:00:00Z"), sessions: [], prices: []) },
            externalFlowsComplete: true, flowCompletenessEvidence: evidence,
            incomeAllocations: [.init(ledgerEventID: "qa-dividend", roundLotID: "qa-buy-lot", amount: try Money("6"), evidence: evidence)])
        let performance = try await ledger.makePerformanceStore()
        let context = try await performance.context()
        let preview = try await performance.prepare(request: request, expectedLedgerRevision: context.ledger.revision,
            expectedPerformanceRevision: context.revision)
        #expect(preview.report.daily.map { $0.nav?.decimalString } == ["20000", "20704", "21204"])
        #expect(abs(try #require(preview.report.twr.value) - 0.0352) < 1e-12)
        #expect(preview.report.rounds.first { $0.id == "put1" }?.netPnL == (try Money("147")))
        #expect(preview.report.rounds.first { $0.id == "put2" }?.netPnL == (try Money("297")))
        #expect(preview.report.rounds.first { $0.id == "call" }?.netPnL == (try Money("197")))
        #expect(preview.report.rounds.first { $0.id == "qa-buy-lot" }?.netPnL == (try Money("63")))
        let saved = try await performance.commit(planID: preview.id, expectedLedgerRevision: preview.ledgerRevision,
            expectedPerformanceRevision: preview.performanceRevision)
        let generatedAt = request.calculatedAt
        let exports = try PortfolioExports.performance(saved.report, generatedAt: generatedAt)
        let transactionExports = try PortfolioExports.ledger(accounts: snapshot.accounts, events: snapshot.events,
            revision: snapshot.revision, generatedAt: generatedAt)
        #expect(String(decoding: exports.daily.data, as: UTF8.self).contains("21204"))
        #expect(String(decoding: transactionExports.transactions.data, as: UTF8.self).contains("qa-split"))

        let archive = try await ledger.makeArchiveStore()
        let bytes = try await archive.exportArchive()
        let destination = folder.appendingPathComponent("restored.sqlite")
        let targetLedger = try LedgerStore(path: destination.path)
        let target = try await targetLedger.makeArchiveStore()
        let status = try await target.status()
        let restore = try await target.prepareRestore(bytes, mode: .replace,
            expectedLedgerRevision: status.ledgerRevision, expectedPerformanceRevision: status.performanceRevision)
        #expect(restore.result.reports == 1)
        _ = try await target.commit(.init(plan: restore))

        // New connection after restore must validate exact source bytes and replay
        // the old report's complete input; cached numerical fields are insufficient.
        let reopenedDatabase = try DatabaseStore(path: destination.path, purpose: .portfolioLedger)
        let reopenedLedger = try LedgerStore(database: reopenedDatabase)
        let after = try await reopenedLedger.snapshot()
        #expect(after.accounts == snapshot.accounts && after.events == snapshot.events)
        #expect(after.state == snapshot.state)
        #expect(after.revision != snapshot.revision)
        #expect(try reopenedDatabase.read { try Data.fetchAll($0, sql: "SELECT raw_bytes FROM ledger_sources") }.contains(csv))
        let reopenedPerformance = try await reopenedLedger.makePerformanceStore()
        let report = try await reopenedPerformance.open(id: saved.id)
        #expect(report.replayMatched && !report.isCurrentLedger)
        #expect(report.report == saved.report)
        let replayExports = try PortfolioExports.performance(report.report, generatedAt: generatedAt)
        #expect(replayExports.daily == exports.daily)
        #expect(replayExports.monthlyCSV == exports.monthlyCSV)
        #expect(replayExports.monthlyMarkdown == exports.monthlyMarkdown)

        // Re-importing the exact retained CSV cannot count the deposit twice.
        let duplicate = try await reopenedLedger.previewCSV(data: csv, accountID: f.account.id,
            sourceSystem: "synthetic-archive-qa", mapping: .standard, excludedRows: [], expectedRevision: after.revision)
        #expect(duplicate.rows.allSatisfy { $0.disposition == .duplicate })
        let deduplicated = try await reopenedLedger.commit(planID: duplicate.id, expectedRevision: after.revision)
        #expect(deduplicated.state.cashByAccount[f.account.id] == (try Money("21204")))
        #expect(deduplicated.events.count == snapshot.events.count)
    }
}
