import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

/// Isolated, already-closed synthetic rounds. No events are persisted to the user's ledger.
public enum TradeOptionAttributionDemo {
    public static let accountID = "SYNTHETIC-TRADE-OPTION-ATTRIBUTION"
    public static func input(includeMissing: Bool = true, at: Date = OptionDailyDemo.defaultDate) throws -> TradeOptionAttributionInput {
        let positions = try PortfolioGreeksDemo.input(includeMissing: false, at: at)
        let openingAt = at.addingTimeInterval(2), closingAt = at.addingTimeInterval(3600)
        let source = PerformanceEvidence(id: "SYNTHETIC-TRADE-CALENDAR", source: "SYNTHETIC-LOCAL",
            kind: .synthetic, availableAt: at, reference: "Declared synthetic session, not an official historical calendar",
            rawDocument: Data("SYNTHETIC-TRADE-OPTION-ATTRIBUTION calendar fixture".utf8))
        var events: [LedgerEvent] = [], observations: [TradeOptionObservation] = []
        let bindings = Dictionary(uniqueKeysWithValues: positions.bindings.map { ($0.instrumentIdentity, $0) })
        let reports = Dictionary(uniqueKeysWithValues: positions.reports.map { ($0.input.id, $0) })
        let day = PerformanceDates.marketDay(at)
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 3 else { throw TradeOptionAttributionError.invalidInput }
        let session = MarketDate(year: dayParts[0], month: dayParts[1], day: dayParts[2])
        func event(_ id: String, at: Date, trade: LedgerTrade) -> LedgerEvent {
            .init(id: id, accountID: accountID, effectiveAt: at,
                source: .init(sourceSystem: "SYNTHETIC-TRADE-OPTION-ATTRIBUTION", externalTransactionID: id,
                              evidence: "Synthetic completed round; no brokerage transaction"), payload: .trade(trade))
        }
        for original in positions.events {
            guard case .trade(let trade) = original.payload, case .option = trade.instrument,
                  let lotID = trade.openingLotID, let binding = bindings[trade.instrument.identity],
                  let report = reports[binding.reportID], let contractID = binding.contractID else { continue }
            let fee = try Money(original.id == "put-short" ? "0" : "1")
            events.append(event(original.id, at: openingAt, trade: .init(instrument: trade.instrument, side: trade.side,
                effect: .open, quantity: trade.quantity, unitPrice: trade.unitPrice, fee: fee,
                openingLotID: lotID, strategy: trade.strategy)))
            events.append(event(original.id + "-close", at: closingAt, trade: .init(instrument: trade.instrument,
                side: trade.side == .buy ? .sell : .buy, effect: .close, quantity: trade.quantity,
                unitPrice: try Money(original.id == "put-short" ? "2.2" : "2.7"), fee: fee,
                selections: [.init(lotID: lotID, quantity: trade.quantity)])))
            let observedSource = PerformanceEvidence(id: "SYNTHETIC-OBS-" + original.id, source: "SYNTHETIC-LOCAL",
                kind: .synthetic, availableAt: report.input.createdAt,
                reference: "Synthetic saved opening observation; not real historical evidence",
                rawDocument: Data(("SYNTHETIC-TRADE-OPTION-ATTRIBUTION " + original.id).utf8))
            let rank = original.id == "put-short" ? nil : TradeOptionIVRankObservation(value: 62.5,
                symbol: report.input.underlying.symbol, feedID: "SYNTHETIC-LOCAL", session: session,
                observedAt: at, knownAt: report.input.createdAt, methodReference: "synthetic-recorded-rank.fixture.v1",
                source: observedSource)
            observations.append(.init(id: "OBS-" + original.id, accountID: accountID, openingEventID: original.id,
                lotID: lotID, instrumentIdentity: trade.instrument.identity, contractID: contractID,
                feedID: "SYNTHETIC-LOCAL", session: session, observedAt: at, knownAt: report.input.createdAt,
                source: observedSource, report: report, ivRank: rank))
        }
        if includeMissing, let first = positions.events.first(where: { if case .trade(let t) = $0.payload, case .option = t.instrument { return true }; return false }), case .trade(let trade) = first.payload {
            events.append(event("unknown", at: openingAt, trade: .init(instrument: trade.instrument, side: .buy,
                effect: .open, quantity: try Money("1"), unitPrice: try Money("2.2"), fee: try Money("0"), openingLotID: "unknown-lot", strategy: trade.strategy)))
            events.append(event("unknown-close", at: closingAt, trade: .init(instrument: trade.instrument, side: .sell,
                effect: .close, quantity: try Money("1"), unitPrice: try Money("2.7"), fee: try Money("0"),
                selections: [.init(lotID: "unknown-lot", quantity: try Money("1"))])))
        }
        // Freeze chronological append order; explicit close lot selections avoid FIFO ambiguity.
        events.sort { ($0.effectiveAt, $0.id) < ($1.effectiveAt, $1.id) }
        events = events.enumerated().map { index, event in
            LedgerEvent(id: event.id, accountID: event.accountID, effectiveAt: event.effectiveAt,
                        providerSequence: index, source: event.source, payload: event.payload)
        }
        let calculatedAt = closingAt.addingTimeInterval(1)
        let request = PerformanceRequest(accountID: accountID, calculatedAt: calculatedAt,
            calendar: .init(tradingDays: [day], evidence: source), days: [])
        return .init(id: UUID(), createdAt: calculatedAt, mode: .synthetic,
            performance: .init(request: request, ledgerRevision: UUID(uuidString: "C035AA00-2026-4018-8100-000000000003")!,
                accounts: [.init(id: accountID, name: "合成交易归因示例")], events: events), observations: observations)
    }
}
