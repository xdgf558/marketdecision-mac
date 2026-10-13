import Foundation
import CryptoKit
import CoreDomain

public enum PortfolioExportError: Error, Equatable, Sendable {
    case incompatibleReport, invalidText, nonFiniteNumber
}
/// Human-readable report bytes, deliberately distinct from transaction import and
/// workspace archives. Exporting does not create a restorable backup or data admission.
public struct PortfolioExportDocument: Equatable, Sendable {
    public let schema: String
    public let suggestedFilename: String
    public let contentType: String
    public let data: Data
}
public struct PortfolioLedgerExports: Sendable {
    public let transactions: PortfolioExportDocument
    public let positions: PortfolioExportDocument
    public let realizations: PortfolioExportDocument
    public let cashBalances: PortfolioExportDocument
}
public struct PortfolioPerformanceExports: Sendable {
    public let daily: PortfolioExportDocument
    public let positions: PortfolioExportDocument
    public let sources: PortfolioExportDocument
    public let metrics: PortfolioExportDocument
    public let monthlyCSV: PortfolioExportDocument
    public let monthlyMarkdown: PortfolioExportDocument
}

public enum PortfolioExports {
    public static let purpose = "REPORT_ONLY_NOT_IMPORT_OR_BACKUP"
    public static let ledgerSchema = "portfolio-ledger-export.v1"
    public static let performanceSchema = "portfolio-performance-export.v1"

    public static func ledger(accounts: [LedgerAccount], events: [LedgerEvent], revision: UUID, generatedAt: Date = Date()) throws -> PortfolioLedgerExports {
        guard ledgerDate(generatedAt) else { throw PortfolioExportError.nonFiniteNumber }
        let state = try LedgerEngine.replay(accounts: accounts, events: events)
        let meta = ExportMetadata(schema: ledgerSchema, revision: revision, engine: state.engineVersion,
                                  parameters: state.parameterVersion, numeric: state.numericPolicyVersion, generatedAt: generatedAt, cutoff: events.map(\.effectiveAt).max(), inputHash: ExportText.hash(Data(try ExportText.json(LedgerExportFrozenInput(accounts: accounts, events: events)).utf8)))
        return try ledgerDocuments(accounts: accounts, events: events, state: state, meta: meta)
    }
    public static func performance(_ report: PerformanceReport, generatedAt: Date = Date()) throws -> PortfolioPerformanceExports {
        guard ledgerDate(generatedAt) else { throw PortfolioExportError.nonFiniteNumber }
        // Never turn an unverified cached summary into a financial export. Recompute
        // only with the existing bound engine; the renderer contains no accounting.
        guard try PerformanceEngine.recompute(report) == report, report.researchOnly else { throw PortfolioExportError.incompatibleReport }
        let meta = ExportMetadata(schema: performanceSchema, revision: report.input.ledgerRevision,
            engine: report.engineVersion, parameters: report.parametersVersion, numeric: report.numericPolicyVersion, generatedAt: generatedAt, cutoff: report.input.request.days.map(\.valuationAt).max(), inputHash: ExportText.hash(Data(try ExportText.json(report.input).utf8)))
        return try performanceDocuments(report, meta: meta)
    }
}

private struct LedgerExportFrozenInput: Codable {
    let accounts: [LedgerAccount]
    let events: [LedgerEvent]
}
private enum ExportCell {
    case text(String), decimal(Money?), number(Double?), integer(Int?), bool(Bool), absent
    var value: String { get throws {
        switch self {
        case .text(let value): return try ExportText.spreadsheetText(value)
        case .decimal(let value): return value?.decimalString ?? ""
        case .number(let value):
            guard let value else { return "" }; guard value.isFinite else { throw PortfolioExportError.nonFiniteNumber }; return String(value)
        case .integer(let value): return value.map(String.init) ?? ""
        case .bool(let value): return value ? "true" : "false"
        case .absent: return ""
        }
    } }
}
private enum ExportText {
    static func validate(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) else { throw PortfolioExportError.invalidText }
    }
    static func spreadsheetText(_ value: String) throws -> String {
        try validate(value)
        let significant = value.unicodeScalars.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .format })
        if let first = significant.first, ["=", "+", "-", "@"].contains(String(first)) { return "'" + value }
        return value
    }
    static func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func markdown(_ value: String) throws -> String {
        try validate(value)
        var text = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for c in ["\\", "`", "*", "_", "[", "]", "|", "#", "!"] { text = text.replacingOccurrences(of: c, with: "\\" + c) }
        return text.replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\r", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
    }
    static func date(_ value: Date?) -> String {
        guard let value else { return "" }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate // Preserve the exact Foundation instant, not millisecond formatting.
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
private struct ExportMetadata {
    let schema: String
    let revision: UUID
    let engine: String
    let parameters: String
    let numeric: String
    let generatedAt: Date
    let cutoff: Date?
    let inputHash: String
    static let columns = ["export_schema", "export_purpose", "ledger_revision", "engine_version", "parameters_version", "numeric_policy_version", "currency", "record_type", "generated_at_utc_display", "generated_at_reference_seconds", "data_cutoff_utc_display", "data_cutoff_reference_seconds", "assumptions", "missing_value_policy", "risk_notice", "frozen_input_sha256"]
    func cells(_ recordType: String) -> [ExportCell] {
        [.text(schema), .text(PortfolioExports.purpose), .text(revision.uuidString.lowercased()), .text(engine), .text(parameters), .text(numeric), .text("USD"), .text(recordType), .text(ExportText.date(generatedAt)), .number(generatedAt.timeIntervalSinceReferenceDate), .text(ExportText.date(cutoff)), .number(cutoff?.timeIntervalSinceReferenceDate), .text("FROZEN_LOCAL_INPUT;EXISTING_BOUND_ENGINE;NO_NEW_ACCOUNTING;FEE_INPUT_AND_POSTED_SAME_COST_DO_NOT_ADD"), .text("EMPTY_IS_MISSING_NOT_ZERO;SEE_STATUS_AND_REASON"), .text("LOCAL_RESEARCH_ONLY;NOT_TAX;NO_DATA_REDISTRIBUTION_GRANT;NOT_PIT_ADMISSION"), .text(inputHash)]
    }
    func document(name: String, columns: [String], rows: [(String, [ExportCell])]) throws -> PortfolioExportDocument {
        var lines = [(Self.columns + columns).map(ExportText.csv).joined(separator: ",")]
        // Even an empty ledger retains its schema and version boundaries inside the file.
        let entries = [("metadata", Array(repeating: ExportCell.absent, count: columns.count))] + rows
        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard entry.1.count == columns.count else { throw PortfolioExportError.incompatibleReport }
            let fields = try (cells(entry.0) + entry.1).map { ExportText.csv(try $0.value) }
            lines.append(fields.joined(separator: ","))
        }
        return PortfolioExportDocument(schema: schema, suggestedFilename: name + ".csv", contentType: "text/csv; charset=utf-8",
            data: Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
    }
}

private extension PortfolioExports {
    static func ledgerDocuments(accounts: [LedgerAccount], events: [LedgerEvent], state: LedgerState, meta: ExportMetadata) throws -> PortfolioLedgerExports {
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let eventMap = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let postingMap = Dictionary(uniqueKeysWithValues: state.postings.map { ($0.eventID, $0) })
        let active = Set(state.activeEventIDs), reversed = Set(state.reversedEventIDs)
        var audit: [(String, [ExportCell])] = []
        // Append order is the audit order, including reversals; economic ordering is
        // represented separately by the precise instant and actual provider sequence.
        for (index, event) in events.enumerated() {
            let fields = LedgerExportFields(event.payload), posting = postingMap[event.id]
            let status = active.contains(event.id) ? "active" : (reversed.contains(event.id) ? "reversed" : "reversal")
            audit.append(("event", [
                .integer(index), .text(event.id), .text(event.accountID), .text(accountMap[event.accountID]?.name ?? ""),
                .text(ExportText.date(event.effectiveAt)), .number(event.effectiveAt.timeIntervalSinceReferenceDate), .integer(event.providerSequence),
                .text(status), .text(event.payload.kind), .text(fields.instrument?.identity ?? ""), .text(fields.instrument?.label ?? ""),
                .text(fields.side ?? ""), .text(fields.effect ?? ""), .decimal(fields.quantity), .decimal(fields.unitPrice), .decimal(fields.inputFee),
                .decimal(posting?.cashChange), .decimal(posting?.externalFlow), .decimal(posting?.grossCash), .decimal(posting?.transactionFee), .decimal(posting?.transferredEmbeddedGain),
                .text(fields.openingLotID ?? ""), .text(event.rollGroupID ?? ""), .text(event.multiLegGroupID ?? ""), .text(fields.reverses ?? ""),
                .text(event.source.sourceSystem), .text(event.source.externalTransactionID ?? ""), .text(event.source.fileHash ?? ""), .integer(event.source.rowIndex),
                .text(event.source.evidence), .text(event.notes), .text(try ExportText.json(event.payload))]))
        }
        let transactionDocument = try meta.document(name: "portfolio-ledger-audit", columns: [
            "audit_index", "event_id", "account_id", "account_name", "effective_at_utc_display", "effective_at_reference_seconds", "provider_sequence",
            "event_status", "event_kind", "instrument_id", "instrument_label", "side", "trade_effect", "quantity", "unit_price", "fee_input",
            "cash_change", "external_flow", "gross_cash", "transaction_fee_posted", "transfer_embedded_gain", "opening_lot_id", "roll_family_id", "multi_leg_group_id", "reverses_event_id",
            "source_system", "external_transaction_id", "source_file_sha256", "source_row_index", "source_evidence", "notes", "payload_json"], rows: audit)
        let lots = try state.lots.sorted { ($0.accountID, $0.acquiredAt, $0.id) < ($1.accountID, $1.acquiredAt, $1.id) }.map { lot -> (String, [ExportCell]) in
            let source = eventMap[lot.openEventID]?.source
            return ("lot", [.text(lot.accountID), .text(accountMap[lot.accountID]?.name ?? ""), .text(lot.id), .text(lot.openEventID),
                .text(lot.instrument.identity), .text(lot.instrument.label), .text(lot.side.rawValue), .text(ExportText.date(lot.acquiredAt)), .number(lot.acquiredAt.timeIntervalSinceReferenceDate),
                .decimal(lot.quantityOpened), .decimal(lot.quantityRemaining), .decimal(lot.managementCostRemaining), .bool(lot.isClosed), .bool(lot.hasNegativeEconomicBasis),
                .decimal(lot.userReportedOriginalTaxBasis), .text(lot.strategy?.id ?? ""), .text(lot.strategy?.purpose.rawValue ?? ""), .text(lot.strategy?.successDefinition ?? ""),
                .text(try ExportText.json(lot.originatingOptionLotIDs.sorted())), .text(try ExportText.json(lot.adjustmentEventIDs)),
                .text(source?.sourceSystem ?? ""), .text(source?.evidence ?? ""), .text(try ExportText.json(lot.instrument)), .text(try lot.strategy.map(ExportText.json) ?? "")])
        }
        let positions = try meta.document(name: "portfolio-ledger-lots", columns: ["account_id", "account_name", "lot_id", "opening_event_id", "instrument_id", "instrument_label", "side",
            "acquired_at_utc_display", "acquired_at_reference_seconds", "quantity_opened_as_recorded", "quantity_remaining_current_units", "management_cost_remaining", "is_closed", "negative_economic_basis",
            "user_reported_original_tax_basis", "strategy_id", "strategy_purpose", "success_definition", "origin_option_lot_ids_json", "adjustment_event_ids_json", "opening_source_system", "opening_source_evidence", "instrument_json", "strategy_json"], rows: lots)
        let realizationRows = state.realizations.enumerated().map { index, item -> (String, [ExportCell]) in
            ("realization", [.integer(index), .text(item.eventID), .text(eventMap[item.eventID]?.accountID ?? ""), .text(item.lotID), .text(item.kind.rawValue),
                .decimal(item.quantity), .decimal(item.removedManagementCost), .decimal(item.netProceedsOrCloseCost), .decimal(item.pnl)])
        }
        let realizations = try meta.document(name: "portfolio-ledger-realizations", columns: ["realization_index", "event_id", "account_id", "lot_id", "kind", "quantity", "removed_management_cost", "net_proceeds_or_close_cost", "realized_pnl"], rows: realizationRows)
        let balances = accounts.sorted { $0.id < $1.id }.map { account in
            ("cash_balance", [ExportCell.text(account.id), .text(account.name), .text(account.costBasisMethod.rawValue), .decimal(state.cashByAccount[account.id])])
        }
        return PortfolioLedgerExports(transactions: transactionDocument, positions: positions, realizations: realizations,
            cashBalances: try meta.document(name: "portfolio-ledger-cash", columns: ["account_id", "account_name", "cost_basis_method", "cash_balance"], rows: balances))
    }
}
private struct LedgerExportFields {
    var instrument: LedgerInstrument?
    var side: String?
    var effect: String?
    var quantity: Money?
    var unitPrice: Money?
    var inputFee: Money?
    var openingLotID: String?
    var reverses: String?
    init(_ payload: LedgerPayload) {
        switch payload {
        case .trade(let x): instrument = x.instrument; side = x.side.rawValue; effect = x.effect.rawValue; quantity = x.quantity; unitPrice = x.unitPrice; inputFee = x.fee; openingLotID = x.openingLotID
        case .optionSettlement(let x): instrument = .option(x.contract); side = x.side.rawValue; effect = x.action.rawValue; quantity = x.quantity; inputFee = x.fee
        case .transferIn(let x): instrument = x.instrument; side = x.side.rawValue; quantity = x.quantity; openingLotID = x.lotID
        case .transferOut(let x): instrument = x.instrument; side = x.side.rawValue; quantity = x.quantity
        case .cashInLieu(let x): inputFee = x.fee
        case .reversal(let x): reverses = x.originalEventID
        default: break // Full typed payload below retains every corporate-action/delivery field.
        }
    }
}

private extension PortfolioExports {
    static func performanceDocuments(_ report: PerformanceReport, meta: ExportMetadata) throws -> PortfolioPerformanceExports {
        let request = report.input.request
        let commonColumns = ["account_id", "calculated_at_utc_display", "calculated_at_reference_seconds", "research_only"]
        let common: [ExportCell] = [.text(request.accountID), .text(ExportText.date(request.calculatedAt)), .number(request.calculatedAt.timeIntervalSinceReferenceDate), .bool(report.researchOnly)]
        var returnByDay: [String: (Int, PerformanceDailyReturn)] = [:]
        for (index, segment) in report.segments.enumerated() { for value in segment.returns { returnByDay[value.day] = (index, value) } }
        let dailyRows = report.daily.sorted { $0.day < $1.day }.map { day -> (String, [ExportCell]) in
            let r = returnByDay[day.day]
            return ("daily_value", common + [.text(day.day), .text(ExportText.date(day.valuationAt)), .number(day.valuationAt?.timeIntervalSinceReferenceDate),
                .decimal(day.cash), .decimal(day.receivables), .decimal(day.payables), .decimal(day.nav), .decimal(day.externalFlow),
                .text(day.status.rawValue), .text(day.reason), .integer(r?.0), .text(r?.1.startDay ?? ""), .number(r?.1.value), .number(r?.1.index),
                .text(r == nil ? "missingInput" : "available"), .text(r == nil ? "无已验证的相邻日收益；起点/缺日/现金流不足等情形不填零" : "")])
        }
        let daily = try meta.document(name: "portfolio-performance-daily", columns: commonColumns + ["day", "valuation_at_utc_display", "valuation_at_reference_seconds", "cash", "receivables", "payables", "nav", "external_flow", "nav_status", "nav_reason", "segment_index", "return_start_day", "daily_twr_decimal", "segment_index_value", "return_status", "return_reason"], rows: dailyRows)
        var positionRows: [(String, [ExportCell])] = []
        for day in report.daily.sorted(by: { $0.day < $1.day }) {
            for position in day.positions.sorted(by: { $0.lotID < $1.lotID }) {
                positionRows.append(("daily_position", common + [.text(day.day), .text(position.lotID), .text(position.instrumentID), .text(position.side.rawValue),
                    .decimal(position.quantity), .decimal(position.managementCost), .decimal(position.marketValue), .decimal(position.unrealizedPnL), .decimal(position.price),
                    .text(position.priceKind.rawValue), .text(ExportText.date(position.sessionClose)), .number(position.sessionClose?.timeIntervalSinceReferenceDate),
                    .text(ExportText.date(position.quoteAt)), .number(position.quoteAt?.timeIntervalSinceReferenceDate), .text(try ExportText.json(position.sourceIDs.sorted())), .text(position.reason)]))
            }
        }
        let positions = try meta.document(name: "portfolio-performance-positions", columns: commonColumns + ["day", "lot_id", "instrument_id", "side", "quantity", "management_cost", "market_value", "unrealized_pnl", "mark_price", "mark_kind", "session_close_utc_display", "session_close_reference_seconds", "quote_at_utc_display", "quote_at_reference_seconds", "source_ids_json", "reason"], rows: positionRows)
        let sources = try sourceDocument(report, meta: meta, common: common, columns: commonColumns)
        let metrics = try metricDocument(report, meta: meta, common: common, columns: commonColumns)
        let markdown = try markdownDocument(report, sources: sources, meta: meta)
        let monthlyCSV = try meta.document(name: "portfolio-performance-monthly", columns: commonColumns + ["month", "through_day", "return_decimal", "status", "reason", "sample_count", "source_ids_json"],
            rows: report.monthly.sorted { $0.month < $1.month }.map { ("monthly_return", common + [.text($0.month), .text($0.endDay), .number($0.result.value), .text($0.result.status.rawValue), .text($0.result.reason), .integer($0.result.sampleCount), .text(try ExportText.json($0.result.evidenceIDs.sorted()))]) })
        return PortfolioPerformanceExports(daily: daily, positions: positions, sources: sources, metrics: metrics, monthlyCSV: monthlyCSV, monthlyMarkdown: markdown)
    }
    static func sourceDocument(_ report: PerformanceReport, meta: ExportMetadata, common: [ExportCell], columns: [String]) throws -> PortfolioExportDocument {
        var entries: [(key: String, cells: [ExportCell])] = []
        func append(_ source: PerformanceEvidence, role: String, context: String, details: [String: String] = [:]) throws {
            entries.append((role + "\u{0000}" + context + "\u{0000}" + source.id, common + [.text(role), .text(context), .text(source.id), .text(source.source), .text(source.kind.rawValue),
                .text(ExportText.date(source.availableAt)), .number(source.availableAt.timeIntervalSinceReferenceDate), .text(source.reference),
                .text(ExportText.hash(source.rawDocument)), .integer(source.rawDocument.count), .text(try ExportText.json(details))]))
        }
        let request = report.input.request
        try append(request.calendar.evidence, role: "calendar", context: request.accountID, details: ["trading_days": try ExportText.json(request.calendar.tradingDays)])
        if let source = request.flowCompletenessEvidence { try append(source, role: "flow_completeness", context: request.accountID, details: ["complete": String(request.externalFlowsComplete)]) }
        for day in request.days {
            for session in day.sessions {
                try append(session.evidence, role: "session", context: day.day + "/" + session.id, details: ["instrument_id": session.instrumentID, "opens_reference_seconds": String(session.opensAt.timeIntervalSinceReferenceDate), "closes_reference_seconds": String(session.closesAt.timeIntervalSinceReferenceDate)])
            }
            for price in day.prices {
                try append(price.evidence, role: "price", context: day.day + "/" + price.id, details: ["instrument_id": price.instrumentID, "session_id": price.sessionID,
                    "quote_reference_seconds": String(price.quoteAt.timeIntervalSinceReferenceDate), "basis": price.basis.rawValue, "timeliness": price.timeliness.rawValue,
                    "quality_flags": try ExportText.json(price.quality.map(\.rawValue).sorted()), "bid": price.bid?.decimalString ?? "MISSING", "ask": price.ask?.decimalString ?? "MISSING", "last": price.last?.decimalString ?? "MISSING"])
            }
        }
        for accrual in request.accruals { try append(accrual.evidence, role: "accrual", context: accrual.id, details: ["kind": accrual.kind.rawValue, "recognized_reference_seconds": String(accrual.recognizedAt.timeIntervalSinceReferenceDate), "amount": accrual.amount.decimalString, "settlements_json": try ExportText.json(accrual.settlements)]) }
        for curve in request.rateCurves { try append(curve.evidence, role: "rate_curve", context: curve.id, details: ["rate_source": curve.source.rawValue, "observation_reference_seconds": String(curve.observationAt.timeIntervalSinceReferenceDate), "valid_from_reference_seconds": String(curve.validFrom.timeIntervalSinceReferenceDate), "valid_through_reference_seconds": String(curve.validThrough.timeIntervalSinceReferenceDate), "points_json": try ExportText.json(curve.points), "source_version": curve.sourceVersion ?? "", "full_source_input_sha256": curve.sourceInput.map(ExportText.hash) ?? ""]) }
        if let benchmark = request.benchmark {
            for point in benchmark.points { try append(point.evidence, role: "benchmark", context: benchmark.symbol + "/" + point.day, details: ["total_return_index": point.totalReturnIndex.decimalString, "is_total_return": String(benchmark.isTotalReturn), "source_version": benchmark.sourceVersion ?? "", "full_source_input_sha256": benchmark.sourceInput.map(ExportText.hash) ?? ""]) }
        }
        for value in request.roundAllocations { try append(value.evidence, role: "round_allocation", context: value.lotID + "/" + value.roundLotID, details: ["fraction": value.fraction.decimalString]) }
        for value in request.incomeAllocations { try append(value.evidence, role: "income_allocation", context: value.ledgerEventID + "/" + value.roundLotID, details: ["amount": value.amount.decimalString]) }
        for value in request.purposeEvidence { try append(value.evidence, role: "purpose", context: value.roundLotID, details: ["outcome": value.outcome.rawValue]) }
        // Ledger evidence is source metadata, not a claim that the original CSV bytes
        // are contained in this human-readable export.
        for event in report.input.events where event.accountID == request.accountID {
            let bytes = Data(try ExportText.json(event.source).utf8)
            let source = event.source
            entries.append(("ledger_event\u{0000}" + event.id, common + [.text("ledger_event"), .text(event.id), .text(event.id), .text(source.sourceSystem), .text("ledger_source_metadata"),
                .absent, .absent, .text(source.evidence), .text(ExportText.hash(bytes)), .integer(bytes.count),
                .text(try ExportText.json(["external_transaction_id": source.externalTransactionID ?? "", "original_file_sha256": source.fileHash ?? "", "original_row_index": source.rowIndex.map(String.init) ?? "", "effective_reference_seconds": String(event.effectiveAt.timeIntervalSinceReferenceDate)]))]))
        }
        return try meta.document(name: "portfolio-performance-sources", columns: columns + ["source_role", "context", "evidence_id", "source_name", "source_kind", "available_at_utc_display", "available_at_reference_seconds", "reference", "evidence_bytes_sha256", "evidence_byte_count", "details_json"], rows: entries.sorted { $0.key < $1.key }.map { ("source_reference", $0.cells) })
    }
}

private extension PortfolioExports {
    static func metricDocument(_ report: PerformanceReport, meta: ExportMetadata, common: [ExportCell], columns: [String]) throws -> PortfolioExportDocument {
        var rows: [(String, [ExportCell])] = []
        func metric(_ scope: String, _ key: String, _ name: String, _ value: PerformanceNumber, unit: String = "dimensionless") throws {
            rows.append(("metric", common + [.text(scope), .text(key), .text(name), .number(value.value), .text(unit), .text(value.status.rawValue), .text(value.reason), .integer(value.sampleCount), .text(try ExportText.json(value.evidenceIDs.sorted())), .absent, .absent, .absent]))
        }
        func money(_ name: String, _ value: Money?) {
            rows.append(("metric", common + [.text("attribution"), .text("period"), .text(name), .decimal(value), .text("USD"), .text(value == nil ? "missingInput" : "available"), .text(value == nil ? "绑定报告缺该项，未补零" : ""), .absent, .absent, .absent, .absent, .absent]))
        }
        func stats(_ stats: PerformanceTradeStatistics, scope: String, key: String) throws {
            for (name, count) in [("display_n", stats.displayN), ("eligible_n", stats.eligibleN), ("wins", stats.wins), ("losses", stats.losses), ("zeros", stats.zeros), ("successes", stats.successes), ("failures", stats.failures), ("unassigned", stats.unassigned), ("maximum_consecutive_losses", stats.maximumConsecutiveLosses)] {
                rows.append(("metric", common + [.text(scope), .text(key), .text(name), .integer(count), .text("count"), .text("available"), .absent, .integer(stats.eligibleN), .absent, .absent, .absent, .absent]))
            }
            for (name, value) in [("win_rate", stats.winRate), ("loss_rate", stats.lossRate), ("purpose_success_rate", stats.purposeSuccessRate), ("average_win", stats.averageWin), ("average_loss", stats.averageLoss), ("expectancy", stats.expectancy), ("profit_factor", stats.profitFactor)] {
                try metric(scope, key, name, value, unit: ["average_win", "average_loss", "expectancy"].contains(name) ? "USD" : "dimensionless")
            }
            rows.append(("metric", common + [.text(scope), .text(key), .text("profit_factor_infinite"), .bool(stats.profitFactorInfinite), .text("boolean"), .text("available"), .text("无亏有赢的 infinity 单列，不替换为有限数字"), .integer(stats.eligibleN), .absent, .absent, .absent, .absent]))
            for (name, interval) in [("win_rate_wilson95", stats.winRateInterval), ("purpose_success_wilson95", stats.purposeSuccessInterval)] {
                rows.append(("metric", common + [.text(scope), .text(key), .text(name), .absent, .text("dimensionless_interval"), .text(interval.status.rawValue), .text(interval.reason), .integer(interval.sampleCount), .absent, .number(interval.low), .number(interval.high), .absent]))
            }
        }
        try metric("portfolio", "period", "twr", report.twr)
        try metric("portfolio", "period", "cagr", report.cagr)
        rows.append(("metric", common + [.text("portfolio"), .text("period"), .text("xirr"), .number(report.xirr.value), .text("annual_decimal"), .text(report.xirr.status.rawValue), .text(report.xirr.reason), .absent, .absent, .absent, .absent,
            .text(try ExportText.json(["roots": report.xirr.roots, "residuals": report.xirr.residuals, "search_range": [report.xirr.searchLower, report.xirr.searchUpper]]))]))
        for (name, value) in [("annualized_volatility", report.risk.annualizedVolatility), ("annualized_twr", report.risk.annualizedTWR), ("annualized_risk_free", report.risk.annualizedRiskFree), ("sharpe", report.risk.sharpe), ("sortino", report.risk.sortino), ("beta", report.risk.beta), ("calmar", report.risk.calmar)] { try metric("risk", "period", name, value) }
        for (name, dd) in [("twr_drawdown", report.risk.drawdown), ("cashflow_affected_nav_drawdown", report.risk.navDrawdown)] {
            rows.append(("metric", common + [.text("risk"), .text("period"), .text(name), .number(dd?.value), .text("decimal"), .text(dd == nil ? "missingInput" : "available"), .text(dd == nil ? "绑定报告缺回撤序列" : "峰谷按绑定报告；NAV 回撤受现金流影响"), .absent, .absent, .absent, .absent,
                .text(try ExportText.json(["peak_day": dd?.peakDay ?? "", "trough_day": dd?.troughDay ?? "", "recovered_day": dd?.recoveredDay ?? ""]))]))
        }
        for value in report.rolling.sorted(by: { $0.calendarDays < $1.calendarDays }) { try metric("rolling", String(value.calendarDays), "twr", value.result) }
        for value in report.monthly.sorted(by: { $0.month < $1.month }) { try metric("monthly", value.month, "twr", value.result) }
        try stats(report.tradeStatistics, scope: "round_statistics", key: "all")
        for group in report.groupedStatistics.sorted(by: { $0.id < $1.id }) { try stats(group.statistics, scope: "group_" + group.axis.rawValue, key: group.id) }
        for round in report.rounds.sorted(by: { $0.roundLotID < $1.roundLotID }) {
            rows.append(("metric", common + [.text("economic_round"), .text(round.roundLotID), .text("net_pnl"), .decimal(round.netPnL), .text("USD"), .text(round.accountingState.rawValue), .text(round.reason), .absent, .absent, .absent, .absent,
                .text(try ExportText.json(["economic_state": round.economicState.rawValue, "purpose_state": round.purposeState.rawValue, "strategy_id": round.strategy?.id ?? "", "family_id": round.familyID ?? "", "related_lot_ids": try ExportText.json(round.relatedLotIDs), "closed_at_reference_seconds": round.closedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? ""]))]))
        }
        if let x = report.attribution {
            for (name, value) in [("realized_pnl", Optional(x.realizedPnL)), ("change_in_unrealized_pnl", x.changeInUnrealizedPnL), ("dividends", Optional(x.dividends)), ("interest", Optional(x.interest)), ("unallocated_fees", Optional(x.unallocatedFees)), ("taxes", Optional(x.taxes)), ("change_in_accruals", x.changeInAccruals), ("transfer_embedded_gain", Optional(x.transferEmbeddedGain)), ("nav_change_less_external_flows", x.navChangeLessExternalFlows), ("explained_pnl", x.explainedPnL), ("reconciliation_difference", x.reconciliationDifference)] { money(name, value) }
        } else { money("reconciliation_difference", nil) }
        return try meta.document(name: "portfolio-performance-metrics", columns: columns + ["scope", "scope_key", "metric", "value", "unit", "status", "reason", "sample_count", "source_ids_json", "interval_low", "interval_high", "context_json"], rows: rows)
    }
    static func markdownDocument(_ report: PerformanceReport, sources: PortfolioExportDocument, meta: ExportMetadata) throws -> PortfolioExportDocument {
        let request = report.input.request
        func t(_ text: String) throws -> String { try ExportText.markdown(text) }
        func n(_ number: PerformanceNumber) throws -> String {
            let value = try ExportCell.number(number.value).value
            return try t((value.isEmpty ? "缺失" : value) + " · " + number.status.rawValue + (number.reason.isEmpty ? "" : " · " + number.reason))
        }
        func m(_ money: Money?) -> String { money?.decimalString ?? "缺失" }
        var out = ["# 本地组合月度与收益报告", "", "仅个人本地研究与账务对照；不是投资指令、税务报告、导入文件或可恢复备份。导出不授予来源数据的再分发权。", "",
            "- 导出格式：\(meta.schema)；用途：\(purpose)",
            "- 生成时刻：\(ExportText.date(meta.generatedAt))；精确 Foundation reference 秒：\(meta.generatedAt.timeIntervalSinceReferenceDate)",
            "- 数据截止：\(ExportText.date(meta.cutoff).isEmpty ? "缺失" : ExportText.date(meta.cutoff))；精确 reference 秒：\(meta.cutoff.map { String($0.timeIntervalSinceReferenceDate) } ?? "缺失")（账本末事件／请求估值时点，不代表 PIT 准入）",
            "- 报告计算时刻：\(ExportText.date(request.calculatedAt))；精确 reference 秒：\(request.calculatedAt.timeIntervalSinceReferenceDate)",
            "- 账户：\(try t(request.accountID))；冻结账本修订：\(meta.revision.uuidString.lowercased())",
            "- 模型：\(try t(meta.engine))；参数：\(try t(meta.parameters))；数值策略：\(try t(meta.numeric))",
            "- 完整冻结输入 SHA-256：\(meta.inputHash)（仅摘要，不代替恢复包）",
            "- 单位：USD；收益率保留小数（1.0 表示 100%）；缺失不写成 0。",
            "- 只展示既有引擎核对后的输出，费用已含在原结果中，不把输入费用与已入账费用再相加。", "", "## 月度结果", "",
            "月份按实际末日标注，不承诺整月；缺锚点或跨缺口时不给连乘结果。", "", "| 月份 | 截至 | 收益小数／状态／原因 |", "| --- | --- | --- |"]
        for month in report.monthly.sorted(by: { $0.month < $1.month }) { out.append("| \(try t(month.month)) | \(try t(month.endDay)) | \(try n(month.result)) |") }
        out += ["", "## 收益与风险", "", "| 项目 | 结果／状态／原因 |", "| --- | --- |", "| TWR | \(try n(report.twr)) |", "| CAGR | \(try n(report.cagr)) |",
            "| XIRR | \(try t((report.xirr.value.map { String($0) } ?? "缺失") + " · " + report.xirr.status.rawValue + " · " + report.xirr.reason)) |",
            "| XIRR 范围内候选根 | \(try t(ExportText.json(report.xirr.roots))) |"]
        for (label, value) in [("年化波动率", report.risk.annualizedVolatility), ("年化 TWR", report.risk.annualizedTWR), ("同期年化无风险率", report.risk.annualizedRiskFree), ("Sharpe", report.risk.sharpe), ("Sortino", report.risk.sortino), ("SPY Beta", report.risk.beta), ("Calmar", report.risk.calmar)] { out.append("| \(label) | \(try n(value)) |") }
        out += ["", "## 每日现金与 NAV", "", "| 日期 | 现金 | 应收 | 应付 | NAV | 外部流 | 状态／缺口 |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for day in report.daily.sorted(by: { $0.day < $1.day }) {
            out.append("| \(try t(day.day)) | \(m(day.cash)) | \(m(day.receivables)) | \(m(day.payables)) | \(m(day.nav)) | \(m(day.externalFlow)) | \(try t(day.status.rawValue + " · " + day.reason)) |")
        }
        let stats = report.tradeStatistics
        out += ["", "## 经济回合", "", "描述回合 \(stats.displayN)，完整合格回合 \(stats.eligibleN)；盈利 \(stats.wins)，亏损 \(stats.losses)，零回合 \(stats.zeros)。目的成功 \(stats.successes)，失败 \(stats.failures)，未指派 U \(stats.unassigned)。", "",
            "盈利频率：\(try n(stats.winRate))；目的成功率：\(try n(stats.purposeSuccessRate))。Profit Factor：\(stats.profitFactorInfinite ? "∞（不参与排名）" : try n(stats.profitFactor))。", "",
            "| 回合 | 策略 | 经济状态 | 目的状态 | 净损益 USD | 说明 |", "| --- | --- | --- | --- | --- | --- |"]
        for round in report.rounds.sorted(by: { $0.roundLotID < $1.roundLotID }) {
            out.append("| \(try t(round.roundLotID)) | \(try t(round.strategy?.id ?? "未标注")) | \(try t(round.economicState.rawValue)) | \(try t(round.purposeState.rawValue)) | \(m(round.netPnL)) | \(try t(round.reason)) |")
        }
        out += ["", "## 来源与可用性", "", "来源 CSV：\(sources.suggestedFilename)，SHA-256：\(ExportText.hash(sources.data))。其字节摘要仅用于对照，不表示已包含全部原始文件或获得数据许可。", "",
            "| 证据 ID | 类别／来源 | 可得时刻 UTC | 原始证据 SHA-256 | 引用 |", "| --- | --- | --- | --- | --- |"]
        var evidence = [request.calendar.evidence]
        if let flow = request.flowCompletenessEvidence { evidence.append(flow) }
        for day in request.days { evidence += day.sessions.map(\.evidence) + day.prices.map(\.evidence) }
        evidence += request.accruals.map(\.evidence) + request.rateCurves.map(\.evidence) + (request.benchmark?.points.map(\.evidence) ?? [])
        evidence += request.roundAllocations.map(\.evidence) + request.incomeAllocations.map(\.evidence) + request.purposeEvidence.map(\.evidence)
        var emitted = Set<String>()
        for item in evidence.sorted(by: { $0.id < $1.id }) where emitted.insert(item.id).inserted {
            out.append("| \(try t(item.id)) | \(try t(item.kind.rawValue + " / " + item.source)) | \(ExportText.date(item.availableAt)) | \(ExportText.hash(item.rawDocument)) | \(try t(item.reference)) |")
        }
        out += ["", "## 假设、缺口与风险", "", "来源文字由输入材料提供；本导出不读取 Keychain 或配置，也不声称已对用户材料完成秘密扫描。以下限制与已绑定报告一起保留。", ""]
        for limitation in report.limitations { out.append("- " + (try t(limitation))) }
        out.append("")
        return PortfolioExportDocument(schema: performanceSchema, suggestedFilename: "portfolio-performance-monthly.md", contentType: "text/markdown; charset=utf-8", data: Data(out.joined(separator: "\n").utf8))
    }
}
