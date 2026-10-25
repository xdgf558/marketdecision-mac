import Foundation
import CoreDomain
import PortfolioEngine
import Persistence

/// One confirmed event can realize several lots. The dashboard plots their
/// exact net sum once, without reallocating fees or creating intervening values.
public struct InvestmentRealizedPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let eventPnL: Money
    public let cumulativePnL: Money
}

public struct InvestmentRealizedContribution: Identifiable, Equatable, Sendable {
    public var id: String { symbol }
    public let symbol: String
    public let amount: Money
}

private struct InvestmentRealizedEntry: Equatable, Sendable {
    let date: Date
    let symbol: String
    let amount: Money
}

/// Current account facts from the storage-validated, fully replayed ledger.
/// This is deliberately independent of frozen period reports and price evidence.
/// Opening cash credits are not profit; all fees and assignment cost bridges stay
/// in the engine's realization amounts rather than being calculated again here.
public struct InvestmentLedgerSummary: Equatable, Sendable {
    public let accountID: String
    public let ledgerRevision: UUID
    public let realizedPnL: Money
    public let cash: Money
    public let openLots: [LedgerLot]
    public let realizedTimeline: [InvestmentRealizedPoint]
    public let realizedContributions: [InvestmentRealizedContribution]
    /// Latest effective event timestamp, including corrections. This is not the
    /// current time, an import timestamp, or a quote/valuation cutoff.
    public let latestActivityAt: Date?
    private let realizedEntries: [InvestmentRealizedEntry]
    /// Recognizes explicit existing template markers; absence never establishes
    /// real-data provenance or permission to use the result for analysis.
    public let containsSyntheticRecords: Bool

    public init(ledger: LedgerSnapshot, accountID: String) throws {
        guard ledger.accounts.contains(where: { $0.id == accountID }),
              let cash = ledger.state.cashByAccount[accountID] else { throw LedgerError.missingAccount }
        self.accountID = accountID
        ledgerRevision = ledger.revision
        self.cash = cash
        let activeEventIDs = Set(ledger.state.activeEventIDs)
        containsSyntheticRecords = ledger.events.contains { event in
            guard event.accountID == accountID, activeEventIDs.contains(event.id) else { return false }
            return [event.source.sourceSystem, event.source.evidence].contains {
                $0.lowercased().contains("synthetic") || $0.contains("合成")
            }
        }
        // A realization has no account field. Every realized event has a posting;
        // use its account identity, never an instrument or the currently open lots.
        let accountEventIDs = Set(ledger.state.postings.filter { $0.accountID == accountID }.map(\.eventID))
        let realizations = ledger.state.realizations.filter {
            accountEventIDs.contains($0.eventID) && activeEventIDs.contains($0.eventID)
        }
        let zero = try Money("0")
        realizedPnL = try realizations.reduce(zero) { try $0.adding($1.pnl) }
        let accountEvents = ledger.events.filter { $0.accountID == accountID }
        latestActivityAt = accountEvents.map(\.effectiveAt).max()

        var eventsByID: [String: LedgerEvent] = [:]
        for event in accountEvents {
            guard eventsByID.updateValue(event, forKey: event.id) == nil else { throw LedgerError.duplicateIdentity }
        }
        var lotsByID: [String: LedgerLot] = [:]
        for lot in ledger.state.lots where lot.accountID == accountID {
            guard lotsByID.updateValue(lot, forKey: lot.id) == nil else { throw LedgerError.duplicateIdentity }
        }
        var eventAmounts: [String: Money] = [:]
        var entries: [InvestmentRealizedEntry] = []
        for realization in realizations {
            guard let event = eventsByID[realization.eventID], let lot = lotsByID[realization.lotID] else {
                throw LedgerError.arithmeticInvariant
            }
            eventAmounts[event.id] = try (eventAmounts[event.id] ?? zero).adding(realization.pnl)
            entries.append(.init(date: event.effectiveAt, symbol: Self.contributionSymbol(event: event, lot: lot),
                                 amount: realization.pnl))
        }
        var cumulative = zero
        var timeline: [InvestmentRealizedPoint] = []
        let realizedEvents = accountEvents.filter { eventAmounts[$0.id] != nil }.sorted(by: Self.precedes)
        for event in realizedEvents {
            guard let amount = eventAmounts[event.id] else { throw LedgerError.arithmeticInvariant }
            cumulative = try cumulative.adding(amount)
            timeline.append(.init(id: event.id, date: event.effectiveAt, eventPnL: amount, cumulativePnL: cumulative))
        }
        realizedTimeline = timeline
        realizedEntries = entries
        realizedContributions = try Self.contributions(entries)
        openLots = ledger.state.lots.filter { $0.accountID == accountID && !$0.isClosed }
            .sorted {
                if $0.instrument.label != $1.instrument.label { return $0.instrument.label < $1.instrument.label }
                if $0.acquiredAt != $1.acquiredAt { return $0.acquiredAt < $1.acquiredAt }
                return $0.id < $1.id
            }
    }

    /// The caller supplies the calendar zone explicitly. Changing this display
    /// filter never changes the all-time total or the underlying ledger.
    public func realizedContributions(inYear year: Int, timeZone: TimeZone) throws -> [InvestmentRealizedContribution] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return try Self.contributions(realizedEntries.filter { calendar.component(.year, from: $0.date) == year })
    }

    private static func contributions(_ entries: [InvestmentRealizedEntry]) throws -> [InvestmentRealizedContribution] {
        let zero = try Money("0")
        var amounts: [String: Money] = [:]
        for entry in entries { amounts[entry.symbol] = try (amounts[entry.symbol] ?? zero).adding(entry.amount) }
        return amounts.map { InvestmentRealizedContribution(symbol: $0.key, amount: $0.value) }.sorted {
            $0.amount == $1.amount ? $0.symbol < $1.symbol : $0.amount > $1.amount
        }
    }

    private static func precedes(_ lhs: LedgerEvent, _ rhs: LedgerEvent) -> Bool {
        if lhs.effectiveAt != rhs.effectiveAt { return lhs.effectiveAt < rhs.effectiveAt }
        if lhs.providerSequence != rhs.providerSequence {
            return (lhs.providerSequence ?? Int.max) < (rhs.providerSequence ?? Int.max)
        }
        return lhs.id < rhs.id
    }

    private static func contributionSymbol(event: LedgerEvent, lot: LedgerLot) -> String {
        // A later contract adjustment can mutate the remaining lot's instrument.
        // Closing trades/option settlements retain the version actually realized.
        let instrument: LedgerInstrument
        switch event.payload {
        case .trade(let trade): instrument = trade.instrument
        case .optionSettlement(let settlement):
            if case .option = lot.instrument { instrument = .option(settlement.contract) }
            else { instrument = lot.instrument }
        default: instrument = lot.instrument
        }
        switch instrument {
        case .equity(let security): return security.symbol
        case .option(let contract):
            // An adjusted basket is not attributed to an invented single stock.
            if contract.deliverables.count == 1, let delivery = contract.deliverables.first {
                return delivery.security.symbol
            }
            return "调整合约 · " + contract.occSymbol.trimmingCharacters(in: .whitespaces)
        }
    }
}
