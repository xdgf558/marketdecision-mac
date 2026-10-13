import Foundation
import Testing
import CoreDomain
import PortfolioEngine

@Suite("Portfolio report exports and fixed accounting cases")
struct PortfolioExportTests {
    let ledger = LedgerEngineTests()
    let perf = PerformanceVectors()
    let revision = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let generatedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.0004)
    func table(_ document: PortfolioExportDocument) throws -> [[String: String]] {
        // Existing input CSV lexer is an independent decoder, not an import mapping.
        let parsed = try LedgerCSV.parse(document.data)
        return parsed.rows.map { Dictionary(uniqueKeysWithValues: zip(parsed.headers, $0)) }
    }
    func export(_ events: [LedgerEvent]) throws -> PortfolioLedgerExports {
        try PortfolioExports.ledger(accounts: [ledger.account], events: events, revision: revision, generatedAt: generatedAt)
    }
    @Test func emptyLedgerRetainsMetadataAndCannotUseStandardImportMapping() throws {
        let documents = try export([])
        for document in [documents.transactions, documents.positions, documents.realizations, documents.cashBalances] {
            let parsed = try LedgerCSV.parse(document.data)
            let rows = try table(document)
            #expect(rows[0]["record_type"] == "metadata")
            #expect(rows[0]["export_schema"] == "portfolio-ledger-export.v1")
            #expect(rows[0]["export_purpose"] == "REPORT_ONLY_NOT_IMPORT_OR_BACKUP")
            #expect(rows[0]["data_cutoff_reference_seconds"] == "")
            #expect(rows[0]["generated_at_reference_seconds"] == String(generatedAt.timeIntervalSinceReferenceDate))
            #expect(throws: LedgerCSVError.invalidMapping) { try LedgerCSVMapping.standard.validate(headers: parsed.headers) }
        }
        #expect(try table(documents.cashBalances).last?["cash_balance"] == "0")
    }
    @Test func quotedUnicodeMultilineTextAndSpreadsheetFormulasRemainLiteral() throws {
        let name = "=HYPERLINK(\"https://example.invalid\",\"账户,一\")"
        let source = " \t@SUM(1,2)\r\n原文\"证据\""
        let notes = "\u{feff}  -cmd\n第二行,注释"
        let account = LedgerAccount(id: ledger.account.id, name: name)
        let event = LedgerEvent(id: "event", accountID: account.id, effectiveAt: generatedAt,
            source: .init(sourceSystem: "+SUM(1,1)", externalTransactionID: "-external", evidence: source),
            payload: .cash(.init(kind: .deposit, amount: try Money("123456789012345.67"))), notes: notes)
        let result = try PortfolioExports.ledger(accounts: [account], events: [event], revision: revision, generatedAt: generatedAt)
        let rows = try table(result.transactions), record = try #require(rows.first { $0["record_type"] == "event" })
        #expect(rows.count == 2)
        #expect(record["account_name"] == "'" + name)
        #expect(record["source_evidence"] == "'" + source)
        #expect(record["notes"] == "'" + notes)
        #expect(record["source_system"] == "'+SUM(1,1)")
        #expect(record["external_transaction_id"] == "'-external")
        #expect(record["cash_change"] == "123456789012345.67")
        #expect(result.transactions.data.starts(with: Data("\"export_schema\"".utf8)))
    }
    @Test func negativeNumericCellsAreNotConvertedToFormulaGuardedText() throws {
        let events = [ledger.event("withdraw", 0, .cash(.init(kind: .withdrawal, amount: try Money("10.01"))))]
        let rows = try table(export(events).transactions)
        let event = try #require(rows.first { $0["event_id"] == "withdraw" })
        #expect(event["cash_change"] == "-10.01")
        #expect(event["external_flow"] == "-10.01")
        #expect(event["unit_price"] == "")
        #expect(event["fee_input"] == "")
        #expect(event["transaction_fee_posted"] == "0")
    }
    @Test func sourceIdentityAndSubmillisecondInstantAreRetained() throws {
        let at = Date(timeIntervalSinceReferenceDate: 823_456_789.0004)
        let event = LedgerEvent(id: "row", accountID: ledger.account.id, effectiveAt: at,
            source: .init(sourceSystem: "localCSV", fileHash: String(repeating: "a", count: 64), rowIndex: 7, evidence: "literal source bytes stored separately"),
            payload: .cash(.init(kind: .deposit, amount: try Money("1"))))
        let record = try #require(table(export([event]).transactions).first { $0["event_id"] == "row" })
        #expect(record["source_file_sha256"] == String(repeating: "a", count: 64))
        #expect(record["source_row_index"] == "7")
        let encodedReference = try #require(record["effective_at_reference_seconds"])
        let reference = try #require(Double(encodedReference))
        #expect(Date(timeIntervalSinceReferenceDate: reference) == at)
        #expect(record["data_cutoff_reference_seconds"] == String(at.timeIntervalSinceReferenceDate))
    }
    @Test func reversedAuditRetainsOriginalInputButNeverInventsActivePostings() throws {
        let original = ledger.event("old", 0, .cash(.init(kind: .deposit, amount: try Money("100"))))
        let reversal = ledger.event("void", 1, .reversal(.init(originalEventID: "old", reason: "wrong amount")))
        let replacement = ledger.event("new", 0, .cash(.init(kind: .deposit, amount: try Money("80"))))
        let result = try export([original, reversal, replacement]), rows = try table(result.transactions)
        #expect(rows.filter { $0["record_type"] == "event" }.compactMap { $0["event_id"] } == ["old", "void", "new"])
        let old = try #require(rows.first { $0["event_id"] == "old" }), rev = try #require(rows.first { $0["event_id"] == "void" })
        #expect(old["event_status"] == "reversed" && old["cash_change"] == "")
        #expect(rev["reverses_event_id"] == "old" && rev["cash_change"] == "")
        #expect(try table(result.cashBalances).last?["cash_balance"] == "80")
    }
    @Test func companyActionExportPreservesCostCashAndFullPayload() throws {
        let events = [ledger.event("fund", 0, .cash(.init(kind: .deposit, amount: try Money("100")))),
            try ledger.stockBuy("buy", 1, quantity: "3", price: "10", fee: "1"),
            ledger.event("split", 2, .split(.init(securityID: ledger.stock.id, ratio: try Money("2"), evidence: "official synthetic 2-for-1", confirmedBy: "test"))),
            try ledger.stockSell("sale", 3, quantity: "2", price: "6", fee: "1"),
            ledger.event("roc", 4, .returnOfCapital(.init(allocations: ["buy-lot": try Money("5")], evidence: "official synthetic ROC", confirmedBy: "test")))]
        let result = try export(events)
        let lot = try #require(table(result.positions).first { $0["lot_id"] == "buy-lot" })
        #expect(lot["quantity_opened_as_recorded"] == "3")
        #expect(lot["quantity_remaining_current_units"] == "4")
        #expect(lot["management_cost_remaining"] == "15.67")
        #expect(try table(result.cashBalances).last?["cash_balance"] == "85")
        #expect(try table(result.realizations).last?["realized_pnl"] == "0.67")
        let action = try #require(table(result.transactions).first { $0["event_id"] == "split" })
        let bytes = Data(try #require(action["payload_json"]).utf8)
        #expect(try JSONDecoder().decode(LedgerPayload.self, from: bytes) == events[2].payload)
        #expect(action["fee_input"] == "")
    }
    @Test func wheelAuditAndRealizationsPreservePremiumBridgeAndFees() throws {
        let events = try PerformanceRoundTests().wheel()
        let result = try export(events), lots = try table(result.positions), rows = try table(result.transactions)
        #expect(try table(result.cashBalances).last?["cash_balance"] == "641")
        let call = try #require(rows.first { $0["event_id"] == "assignCall" })
        #expect(call["transaction_fee_posted"] == "1")
        #expect(call["cash_change"] == "9999")
        #expect(call["roll_family_id"] == "")
        let shares = try #require(lots.first { $0["lot_id"] == "shares" })
        #expect(shares["origin_option_lot_ids_json"] == "[\"put2\"]")
        #expect(shares["quantity_remaining_current_units"] == "0")
        let realized = try table(result.realizations).filter { $0["record_type"] == "realization" }
        #expect(realized.first { $0["lot_id"] == "shares" }?["removed_management_cost"] == "9703")
        #expect(realized.first { $0["lot_id"] == "shares" }?["net_proceeds_or_close_cost"] == "10197")
        #expect(realized.filter { $0["lot_id"] == "put2" || $0["lot_id"] == "call" }.allSatisfy { $0["realized_pnl"] == "0" })
    }
    @Test func repeatedExportWithInjectedTimeIsByteIdentical() throws {
        let events = [try ledger.stockBuy("z", 1, quantity: "1", price: "1"), try ledger.stockBuy("a", 2, quantity: "1", price: "2")]
        let a = try export(events), b = try export(events)
        #expect(a.transactions == b.transactions && a.positions == b.positions && a.realizations == b.realizations && a.cashBalances == b.cashBalances)
        let report = try PerformanceEngine.calculate(perf.valuedInput(age: 301))
        let x = try PortfolioExports.performance(report, generatedAt: generatedAt), y = try PortfolioExports.performance(report, generatedAt: generatedAt)
        #expect(x.daily == y.daily && x.sources == y.sources && x.monthlyCSV == y.monthlyCSV && x.monthlyMarkdown == y.monthlyMarkdown)
    }
    @Test func missingNAVAndUndefinedRatesAreEmptyWithReasonsNotZero() throws {
        let report = try PerformanceEngine.calculate(perf.valuedInput(age: 1801))
        let result = try PortfolioExports.performance(report, generatedAt: generatedAt)
        let day = try #require(table(result.daily).first { $0["record_type"] == "daily_value" })
        #expect(day["nav"] == "")
        #expect(day["nav_status"] == "missingInput")
        #expect(!(day["nav_reason"] ?? "").isEmpty)
        #expect(day["daily_twr_decimal"] == "")
        #expect(day["cash"] == "83")
        let position = try #require(table(result.positions).first { $0["record_type"] == "daily_position" })
        #expect(position["market_value"] == "" && position["mark_kind"] == "missing")
        let month = try #require(table(result.monthlyCSV).first { $0["record_type"] == "monthly_return" })
        #expect(month["return_decimal"] == "" && month["status"] == "missingInput")
        #expect(String(decoding: result.monthlyMarkdown.data, as: UTF8.self).contains("缺失"))
    }
    @Test func cashFlowsAndReturnsExportExistingBoundResultsWithoutSecondFeeCalculation() throws {
        let days = ["2026-01-05", "2026-01-06", "2026-01-07"]
        let events = [try perf.cash("fund", days[0], .deposit, "100"), try perf.cash("income", days[1], .interest, "10"),
                      try perf.cash("deposit", days[1], .deposit, "50"), try perf.cash("withdraw", days[2], .withdrawal, "20"), try perf.cash("fee", days[2], .fee, "16")]
        let report = try PerformanceEngine.calculate(perf.input(days, events: events))
        let result = try PortfolioExports.performance(report, generatedAt: generatedAt)
        let rows = try table(result.daily).filter { $0["record_type"] == "daily_value" }
        #expect(rows.compactMap { $0["nav"] } == ["100", "160", "124"])
        #expect(rows.compactMap { $0["external_flow"] } == ["100", "50", "-20"])
        #expect(rows.compactMap { $0["daily_twr_decimal"] } == ["", "0.1", "-0.1"])
        let metrics = try table(result.metrics)
        #expect(metrics.first { $0["metric"] == "unallocated_fees" }?["value"] == "16")
        #expect(metrics.first { $0["metric"] == "reconciliation_difference" }?["value"] == "0")
        #expect(metrics.first { $0["metric"] == "twr" && $0["scope"] == "portfolio" }?["value"] == String(try #require(report.twr.value)))
    }
    @Test func priceSourceFlagsAndRawByteDigestSurviveExport() throws {
        let report = try PerformanceEngine.calculate(perf.valuedInput(age: 301))
        let result = try PortfolioExports.performance(report, generatedAt: generatedAt)
        let source = try #require(table(result.sources).first { $0["source_role"] == "price" })
        #expect(source["source_kind"] == "synthetic")
        #expect(source["evidence_bytes_sha256"] == LedgerCSV.hash(Data("fixture".utf8)))
        let details = try JSONDecoder().decode([String: String].self, from: Data(try #require(source["details_json"]).utf8))
        #expect(details["basis"] == "raw" && details["timeliness"] == "endOfDay")
        #expect(details["bid"] == "9" && details["ask"] == "11" && details["last"] == "12")
        let position = try #require(table(result.positions).first { $0["record_type"] == "daily_position" })
        #expect(position["mark_kind"] == "lastStale")
        #expect((position["reason"] ?? "").contains("STALE"))
    }
    @Test func markdownEscapesUserHTMLLinksAndTableSeparators() throws {
        let id = "account|<script>bad()</script>\n[open](javascript:bad)"
        let source = PerformanceEvidence(id: "source", source: "local", kind: .userConfirmed, availableAt: perf.close("2026-01-04"),
            reference: "<img src=x onerror=bad> | [open](javascript:bad)", rawDocument: Data("literal evidence".utf8))
        let request = PerformanceRequest(accountID: id, calculatedAt: perf.close("2026-01-05"), calendar: .init(tradingDays: ["2026-01-05"], evidence: source), days: [perf.day("2026-01-05")])
        let input = PerformanceInput(request: request, ledgerRevision: revision, accounts: [.init(id: id, name: "Local")], events: [])
        let report = try PerformanceEngine.calculate(input)
        let document = try PortfolioExports.performance(report, generatedAt: generatedAt).monthlyMarkdown
        let text = String(decoding: document.data, as: UTF8.self)
        #expect(!text.contains("<script>") && !text.contains("<img"))
        #expect(text.contains("&lt;script&gt;"))
        #expect(text.contains("account\\|"))
        #expect(!text.contains("[open](javascript:bad)"))
        #expect(text.contains("不声称已对用户材料完成秘密扫描"))
    }
    @Test func tamperedCachedNAVIsRejectedBeforeRendering() throws {
        let report = try PerformanceEngine.calculate(perf.valuedInput(age: 0))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var daily = try #require(object["daily"] as? [[String: Any]])
        daily[0]["nav"] = "999999"; object["daily"] = daily
        let corrupted = try JSONDecoder().decode(PerformanceReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: PortfolioExportError.incompatibleReport) { try PortfolioExports.performance(corrupted, generatedAt: generatedAt) }
    }
    @Test func controlBytesAndNonFiniteGeneratedTimeAreRejected() throws {
        let event = LedgerEvent(id: "event", accountID: ledger.account.id, effectiveAt: ledger.base,
            source: .init(sourceSystem: "synthetic", externalTransactionID: "event", evidence: "evidence"),
            payload: .cash(.init(kind: .deposit, amount: try Money("1"))), notes: "line\u{0001}unsafe")
        #expect(throws: PortfolioExportError.invalidText) { try export([event]) }
        #expect(throws: PortfolioExportError.nonFiniteNumber) { try PortfolioExports.ledger(accounts: [], events: [], revision: revision, generatedAt: Date(timeIntervalSinceReferenceDate: .infinity)) }
    }
}
