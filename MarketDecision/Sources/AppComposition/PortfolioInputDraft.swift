import Foundation
import CoreDomain
import PortfolioEngine

public enum PortfolioDraftError: Error, Equatable, Sendable { case missingField, invalidNumber, invalidRows, invalidJSON }

/// Local evidence is deliberately blank by default. Labels are assertions by the
/// user, not provider admission, and the original pasted text is preserved.
public struct PortfolioEvidenceDraft: Equatable, Sendable {
    public var id = UUID().uuidString
    public var source = ""
    public var reference = ""
    public var availableAt = ""
    public var text = ""
    public var kind: PerformanceEvidenceKind = .userConfirmed
    public init() {}
    public func build() throws -> PerformanceEvidence {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              kind != .synthetic else { throw PortfolioDraftError.missingField }
        return try .init(id: id, source: source, kind: kind, availableAt: LedgerCSV.timestamp(availableAt),
                         reference: reference, rawDocument: Data(text.utf8))
    }
}
public struct PortfolioQuoteDraft: Equatable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var instrumentID = ""
    public var opensAt = ""
    public var closesAt = ""
    public var quoteAt = ""
    public var bid = ""
    public var ask = ""
    public var last = ""
    public var sessionEvidence = PortfolioEvidenceDraft()
    public var priceEvidence = PortfolioEvidenceDraft()
    public init() {}
    public func build() throws -> (PerformanceSession, PerformancePrice) {
        guard !instrumentID.isEmpty else { throw PortfolioDraftError.missingField }
        let session = try PerformanceSession(id: "session/" + id, instrumentID: instrumentID,
            opensAt: LedgerCSV.timestamp(opensAt), closesAt: LedgerCSV.timestamp(closesAt), evidence: sessionEvidence.build())
        let price = try PerformancePrice(id: "price/" + id, instrumentID: instrumentID, sessionID: session.id,
            quoteAt: LedgerCSV.timestamp(quoteAt), bid: optionalMoney(bid), ask: optionalMoney(ask), last: optionalMoney(last),
            basis: .raw, quality: [], timeliness: .endOfDay, evidence: priceEvidence.build())
        return (session, price)
    }
}
public struct PortfolioDayDraft: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var day = ""
    public var valuationAt = ""
    public var quotes: [PortfolioQuoteDraft] = []
    public init() {}
    public func build() throws -> PerformanceDayInput {
        let values = try quotes.map { try $0.build() }
        return try .init(day: day, valuationAt: LedgerCSV.timestamp(valuationAt), sessions: values.map(\.0), prices: values.map(\.1))
    }
}
public struct PortfolioRateDraft: Equatable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var source: PerformanceRateSource = .explicitUserConstant
    public var observationAt = ""
    public var validFrom = ""
    public var validThrough = ""
    public var unit: PerformanceRateUnit = .annualPercent
    /// Explicit term-years and rate per line; no guessed tenor or percent conversion.
    public var points = ""
    public var evidence = PortfolioEvidenceDraft()
    public init() {}
    public func build() throws -> PerformanceRateCurve {
        let values = try portfolioRows(points, count: 2).map { row -> PerformanceRatePoint in
            guard let years = Double(row[0]), years.isFinite, years > 0 else { throw PortfolioDraftError.invalidNumber }
            return try .init(termYears: years, annualRate: Money(row[1]), unit: unit)
        }
        guard !values.isEmpty else { throw PortfolioDraftError.missingField }
        return try .init(id: id, source: source, observationAt: LedgerCSV.timestamp(observationAt),
            validFrom: LedgerCSV.timestamp(validFrom), validThrough: LedgerCSV.timestamp(validThrough), points: values, evidence: evidence.build())
    }
}
public struct PortfolioAccrualDraft: Equatable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var kind: PerformanceAccrualKind = .dividendReceivable
    public var recognizedAt = ""
    public var amount = ""
    /// Explicit event-ID, amount per line. Empty means not yet settled.
    public var settlements = ""
    public var evidence = PortfolioEvidenceDraft()
    public init() {}
    public func build() throws -> PerformanceAccrual {
        let rows = try portfolioRows(settlements, count: 2).map { try PerformanceAccrualSettlement(ledgerEventID: $0[0], amount: Money($0[1])) }
        return try .init(id: id, kind: kind, recognizedAt: LedgerCSV.timestamp(recognizedAt), amount: Money(amount), settlements: rows, evidence: evidence.build())
    }
}
public struct PortfolioPublishedRateDraft: Equatable, Sendable {
    public var series: FREDTreasurySeries = .dgs3mo
    public var document = PortfolioEvidenceDraft()
    public var releaseJSON = "[]"
    public init() {}
    public func parse() throws -> PublishedRateImport {
        let evidence = try document.build()
        let bytes = Data(releaseJSON.utf8)
        guard bytes.count <= 2 * 1_024 * 1_024 else { throw PortfolioDraftError.invalidJSON }
        let releases = try JSONDecoder().decode([PublishedRateRelease].self, from: bytes)
        return try FREDPublishedRateImport.decode(evidence.rawDocument, series: series, document: evidence, releases: releases)
    }
}
public struct PortfolioInputDraft: Equatable, Sendable {
    public var tradingDays = ""
    public var calendarEvidence = PortfolioEvidenceDraft()
    public var days: [PortfolioDayDraft] = []
    public var rates: [PortfolioRateDraft] = []
    public var importedRateCurves: [PerformanceRateCurve] = []
    public var accruals: [PortfolioAccrualDraft] = []
    public var externalFlowsComplete = false
    public var flowEvidence = PortfolioEvidenceDraft()
    public var includeBenchmark = false
    public var benchmarkSymbol = "SPY"
    public var benchmarkIsTotalReturn = false
    public var benchmarkPoints = ""
    public var benchmarkEvidence = PortfolioEvidenceDraft()
    public init() {}
    public func build(accountID: String, calculatedAt: Date) throws -> PerformanceRequest {
        let calendar = tradingDays.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !accountID.isEmpty, !calendar.isEmpty else { throw PortfolioDraftError.missingField }
        let benchmark: PerformanceBenchmark?
        if includeBenchmark {
            let evidence = try benchmarkEvidence.build()
            let points = try portfolioRows(benchmarkPoints, count: 2).map { try PerformanceBenchmarkPoint(day: $0[0], totalReturnIndex: Money($0[1]), evidence: evidence) }
            guard !benchmarkSymbol.isEmpty, !points.isEmpty else { throw PortfolioDraftError.missingField }
            benchmark = .init(symbol: benchmarkSymbol, points: points, isTotalReturn: benchmarkIsTotalReturn)
        } else { benchmark = nil }
        return try .init(accountID: accountID, calculatedAt: calculatedAt,
            calendar: .init(tradingDays: calendar, evidence: calendarEvidence.build()), days: days.map { try $0.build() },
            accruals: accruals.map { try $0.build() }, rateCurves: try rates.map { try $0.build() } + importedRateCurves, benchmark: benchmark,
            externalFlowsComplete: externalFlowsComplete, flowCompletenessEvidence: externalFlowsComplete ? flowEvidence.build() : nil)
    }
    public static func decodeJSON(_ text: String) throws -> (PerformanceRequest, Data) {
        let raw = Data(text.utf8)
        guard !raw.isEmpty, raw.count <= 8 * 1_024 * 1_024 else { throw PortfolioDraftError.invalidJSON }
        return (try JSONDecoder().decode(PerformanceRequest.self, from: raw), raw)
    }
}
private func optionalMoney(_ text: String) throws -> Money? { text.isEmpty ? nil : try Money(text) }
private func portfolioRows(_ text: String, count: Int) throws -> [[String]] {
    try text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
        let row = $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard row.count == count, row.allSatisfy({ !$0.isEmpty }) else { throw PortfolioDraftError.invalidRows }
        return row
    }
}

/// Separate in-memory demonstration. This input never goes to PerformanceStorage
/// or borrows an ordinary account, ledger revision, source label or history.
public enum PortfolioSyntheticExample {
    public static func input() throws -> PerformanceInput {
        let account = LedgerAccount(id: "SYNTHETIC-PERFORMANCE", name: "独立合成示例")
        let calculatedAt = try LedgerCSV.timestamp("2026-01-08T12:00:00Z")
        func evidence(_ id: String, at: Date) -> PerformanceEvidence {
            .init(id: "SYNTHETIC/" + id, source: "SYNTHETIC ONLY", kind: .synthetic,
                  availableAt: at, reference: "合成教学夹具，不是真实市场历史", rawDocument: Data(("SYNTHETIC " + id).utf8))
        }
        let source = LedgerSource(sourceSystem: "SYNTHETIC", externalTransactionID: "deposit", evidence: "合成现金")
        let deposit = try LedgerEvent(id: "synthetic-deposit", accountID: account.id,
            effectiveAt: LedgerCSV.timestamp("2026-01-02T14:00:00Z"), source: source,
            payload: .cash(.init(kind: .deposit, amount: Money("1000"))))
        let buy = try LedgerEvent(id: "synthetic-buy", accountID: account.id, effectiveAt: LedgerCSV.timestamp("2026-01-02T15:00:00Z"),
            source: .init(sourceSystem: "SYNTHETIC", externalTransactionID: "buy", evidence: "合成买入"),
            payload: .trade(.init(instrument: .equity(.init(id: "DEMO", symbol: "DEMO")), side: .buy, effect: .open,
                quantity: Money("2"), unitPrice: Money("10"), fee: Money("0"), openingLotID: "synthetic-lot")))
        let dates = ["2026-01-02", "2026-01-05", "2026-01-06", "2026-01-07"]
        let prices = ["10", "11", "10.5", "12"]
        var days: [PerformanceDayInput] = []
        for (index, day) in dates.enumerated() {
            let close = try LedgerCSV.timestamp(day + "T21:00:00Z"), proof = evidence(day, at: close)
            let session = try PerformanceSession(id: "synthetic-session/" + day, instrumentID: "equity:DEMO",
                opensAt: LedgerCSV.timestamp(day + "T14:30:00Z"), closesAt: close, evidence: proof)
            let quote = try PerformancePrice(id: "synthetic-price/" + day, instrumentID: "equity:DEMO", sessionID: session.id,
                quoteAt: close, bid: Money(prices[index]), ask: Money(prices[index]), quality: [.synthetic], evidence: proof)
            days.append(.init(day: day, valuationAt: close, sessions: [session], prices: [quote]))
        }
        let proof = evidence("calendar", at: calculatedAt)
        let request = PerformanceRequest(accountID: account.id, calculatedAt: calculatedAt,
            calendar: .init(tradingDays: dates, evidence: proof), days: days, externalFlowsComplete: true, flowCompletenessEvidence: proof)
        return .init(request: request, ledgerRevision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, accounts: [account], events: [deposit, buy])
    }
}
