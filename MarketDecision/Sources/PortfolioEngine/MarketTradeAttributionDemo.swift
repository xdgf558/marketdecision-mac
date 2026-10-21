import Foundation
import CoreDomain
import MarketAnalytics

/// A separate synthetic account; no existing account or ledger service is opened.
public enum MarketTradeAttributionDemo {
    public static func input(snapshot supplied: MarketStateReport? = nil, includeMissing: Bool = true) throws -> MarketTradeAttributionInput {
        let snapshot = try supplied ?? MarketStateEngine.calculate(MarketStateDemo.input())
        let accountID = "SYNTHETIC-MARKET-ATTRIBUTION"
        let openingAt = max(snapshot.input.createdAt, snapshot.current.asOf).addingTimeInterval(1)
        let closingAt = openingAt.addingTimeInterval(60)
        let security = LedgerSecurity(id: "SYNTHETIC-MARKET-SECURITY", symbol: "DEMO", kind: .etf)
        let source = PerformanceEvidence(id: "SYNTHETIC-MARKET-SNAPSHOT", source: "SYNTHETIC-LOCAL", kind: .synthetic,
            availableAt: snapshot.input.createdAt, reference: "Declared synthetic opening snapshot, not market evidence",
            rawDocument: Data("SYNTHETIC-MARKET-ATTRIBUTION".utf8))
        let validity = try nextClose(after: snapshot)
        var events: [LedgerEvent] = [], observations: [MarketTradeObservation] = []
        for index in 0..<(includeMissing ? 2 : 1) {
            let lot = "lot-\(index)", openID = "open-\(index)"
            events.append(.init(id: openID, accountID: accountID, effectiveAt: openingAt, providerSequence: index,
                source: .init(sourceSystem: "SYNTHETIC-LOCAL", externalTransactionID: openID, evidence: "Synthetic purchase"),
                payload: .trade(.init(instrument: .equity(security), side: .buy, effect: .open,
                    quantity: try Money("10"), unitPrice: try Money("100"), fee: try Money("1"), openingLotID: lot))))
            events.append(.init(id: "close-\(index)", accountID: accountID, effectiveAt: closingAt, providerSequence: index,
                source: .init(sourceSystem: "SYNTHETIC-LOCAL", externalTransactionID: "close-\(index)", evidence: "Synthetic sale"),
                payload: .trade(.init(instrument: .equity(security), side: .sell, effect: .close,
                    quantity: try Money("10"), unitPrice: try Money(index == 0 ? "102" : "98"), fee: try Money("1"),
                    selections: [.init(lotID: lot, quantity: try Money("10"))]))))
            if index == 0 {
                observations.append(.init(id: "SYNTHETIC-OPENING-STATE", accountID: accountID, openingEventID: openID,
                    lotID: lot, knownAt: snapshot.input.createdAt, source: source, snapshot: snapshot, nextScheduledClose: validity))
            }
        }
        events.sort { ($0.effectiveAt, $0.providerSequence ?? 0, $0.id) < ($1.effectiveAt, $1.providerSequence ?? 0, $1.id) }
        let calculatedAt = closingAt.addingTimeInterval(1)
        let calendarSource = PerformanceEvidence(id: "SYNTHETIC-MARKET-TRADE-CALENDAR", source: "SYNTHETIC-LOCAL", kind: .synthetic,
            availableAt: snapshot.input.createdAt, reference: "Synthetic session only", rawDocument: Data("SYNTHETIC-CALENDAR".utf8))
        let request = PerformanceRequest(accountID: accountID, calculatedAt: calculatedAt,
            calendar: .init(tradingDays: [PerformanceDates.marketDay(openingAt)], evidence: calendarSource), days: [])
        return .init(createdAt: calculatedAt, mode: .synthetic,
            performance: .init(request: request, ledgerRevision: UUID(uuidString: "A0440000-2026-4019-8100-000000000003")!,
                accounts: [.init(id: accountID, name: "合成市场归因示例")], events: events), observations: observations)
    }
    private static func nextClose(after snapshot: MarketStateReport) throws -> MarketNextCloseEvidence {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "America/New_York") else { throw MarketTradeAttributionError.invalidInput }
        calendar.timeZone = zone
        let parts = snapshot.current.sessionDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 16)),
              var next = calendar.date(byAdding: .day, value: 1, to: start) else { throw MarketTradeAttributionError.invalidInput }
        while [1, 7].contains(calendar.component(.weekday, from: next)) {
            guard let later = calendar.date(byAdding: .day, value: 1, to: next) else { throw MarketTradeAttributionError.invalidInput }; next = later
        }
        let date = PerformanceDates.marketDay(next)
        let evidence = PerformanceEvidence(id: "SYNTHETIC-NEXT-MARKET-CLOSE", source: "SYNTHETIC-LOCAL", kind: .synthetic,
            availableAt: snapshot.input.createdAt, reference: "Synthetic next weekday at 16:00 New York; not an exchange calendar",
            rawDocument: Data("SYNTHETIC-NEXT-CLOSE|\(date)|\(next.timeIntervalSinceReferenceDate)".utf8))
        return .init(sessionDate: date, closeAt: next, calendar: evidence)
    }
}
