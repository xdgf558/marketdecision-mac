import Foundation
import CoreDomain
import PortfolioEngine
import Persistence

public enum InvestmentReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case year, quarter, month
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .year: "近1年"
        case .quarter: "近1季度"
        case .month: "近1个月"
        }
    }
    fileprivate var months: Int {
        switch self { case .year: 12; case .quarter: 3; case .month: 1 }
    }
}

public enum InvestmentPeriodReportError: Error, Equatable, Sendable { case invalidDate }

/// A read-only summary of booked facts, not a frozen valuation report. It has
/// no price, NAV, return-rate, calendar-completeness or cash-flow-completeness
/// assertion. Corrections restate history using the current validated ledger,
/// following the existing performance engine's management-accounting policy.
public struct InvestmentPeriodReport: Identifiable, Equatable, Sendable {
    public var id: String { period.rawValue }
    public var title: String { period.title }
    public let period: InvestmentReportPeriod
    public let accountID: String
    public let ledgerRevision: UUID
    public let generatedAt: Date
    /// Rolling New York calendar months, including both displayed endpoints.
    public let startDate: Date
    public let endDate: Date
    /// The ledger engine has already included allocated opening/closing fees.
    public let realizedPnL: Money
    public let realizedEventCount: Int
    /// Booked dividends and interest, excluding deposits and sale proceeds.
    public let cashIncome: Money
    /// Standalone fees and withholding/tax debits, expressed as positive amounts.
    /// Transaction fees are deliberately not charged again here.
    public let cashCharges: Money
    public let deposits: Money
    public let withdrawals: Money
    public let openingCash: Money
    public let closingCash: Money
    /// Realized trading P&L + cash income - standalone cash charges. This is not
    /// total investment performance and excludes unpriced/unrealized holdings.
    public let bookedPnL: Money
    public let timeline: [InvestmentRealizedPoint]
    public let contributions: [InvestmentRealizedContribution]
    public let containsSyntheticRecords: Bool

    /// Generates all three windows from one immutable, fully validated snapshot.
    /// The caller must still bind publication to its page/account/revision session.
    public static func generate(ledger: LedgerSnapshot, accountID: String,
                                at cutoff: Date) throws -> [Self] {
        try Task.checkCancellation()
        guard cutoff.timeIntervalSinceReferenceDate.isFinite,
              let timeZone = TimeZone(identifier: "America/New_York") else {
            throw InvestmentPeriodReportError.invalidDate
        }
        guard ledger.accounts.contains(where: { $0.id == accountID }) else { throw LedgerError.missingAccount }
        // Validate complete append history, corrections and multi-leg/roll
        // membership before deriving a time cut. Never replay only period events:
        // their opening lots and cost basis may precede the reporting window.
        let complete = try LedgerEngine.replay(accounts: ledger.accounts, events: ledger.events)
        guard complete == ledger.state else { throw LedgerError.arithmeticInvariant }
        try Task.checkCancellation()
        let activeIDs = Set(complete.activeEventIDs)
        let cut = ledger.events.filter {
            $0.accountID == accountID && activeIDs.contains($0.id) && $0.effectiveAt <= cutoff
        }.map {
            // These groups are navigation only and were validated above. A cut
            // may lie between their legs, exactly as in PerformanceContext.
            LedgerEvent(id: $0.id, accountID: $0.accountID, effectiveAt: $0.effectiveAt,
                        providerSequence: $0.providerSequence, source: $0.source,
                        payload: $0.payload, notes: $0.notes)
        }
        let state = try LedgerEngine.replay(accounts: ledger.accounts, events: cut)
        guard let closingCash = state.cashByAccount[accountID] else { throw LedgerError.missingAccount }
        let events = Dictionary(uniqueKeysWithValues: cut.map { ($0.id, $0) })
        let lots = Dictionary(uniqueKeysWithValues: state.lots.map { ($0.id, $0) })
        let containsSynthetic = cut.contains { event in
            [event.source.sourceSystem, event.source.evidence].contains {
                $0.lowercased().contains("synthetic") || $0.contains("合成")
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return try InvestmentReportPeriod.allCases.map { period in
            try Task.checkCancellation()
            guard let start = calendar.date(byAdding: .month, value: -period.months, to: cutoff),
                  start < cutoff else { throw InvestmentPeriodReportError.invalidDate }
            let zero = try Money("0")
            var eventPnL: [String: Money] = [:], symbolPnL: [String: Money] = [:]
            for realization in state.realizations {
                guard let event = events[realization.eventID], let lot = lots[realization.lotID],
                      event.accountID == accountID, lot.accountID == accountID else {
                    throw LedgerError.arithmeticInvariant
                }
                guard event.effectiveAt >= start else { continue }
                eventPnL[event.id] = try (eventPnL[event.id] ?? zero).adding(realization.pnl)
                let symbol = contributionSymbol(event: event, lot: lot)
                symbolPnL[symbol] = try (symbolPnL[symbol] ?? zero).adding(realization.pnl)
            }
            var realized = zero
            let timeline = try cut.filter { eventPnL[$0.id] != nil }.sorted(by: precedes).map { event in
                guard let amount = eventPnL[event.id] else { throw LedgerError.arithmeticInvariant }
                realized = try realized.adding(amount)
                return InvestmentRealizedPoint(id: event.id, date: event.effectiveAt,
                                               eventPnL: amount, cumulativePnL: realized)
            }
            var contributions: [InvestmentRealizedContribution] = []
            for (symbol, amount) in symbolPnL {
                contributions.append(InvestmentRealizedContribution(symbol: symbol, amount: amount))
            }
            contributions.sort { left, right in
                if left.amount == right.amount { return left.symbol < right.symbol }
                return left.amount > right.amount
            }
            var openingCash = zero, cashIncome = zero, cashCharges = zero
            var deposits = zero, withdrawals = zero
            for posting in state.postings {
                guard posting.accountID == accountID, let event = events[posting.eventID] else {
                    throw LedgerError.arithmeticInvariant
                }
                if event.effectiveAt < start {
                    openingCash = try openingCash.adding(posting.cashChange)
                    continue
                }
                // Use engine-posted cents and signs rather than recalculate raw
                // amounts. Trade proceeds and embedded assignment cash stay out.
                guard case .cash(let cash) = event.payload else { continue }
                switch cash.kind {
                case .deposit: deposits = try deposits.adding(posting.externalFlow)
                case .withdrawal: withdrawals = try withdrawals.subtracting(posting.externalFlow)
                case .dividend, .interest: cashIncome = try cashIncome.adding(posting.cashChange)
                case .fee, .dividendWithholding, .interestWithholding, .otherTax:
                    cashCharges = try cashCharges.subtracting(posting.cashChange)
                }
            }
            let booked = try realized.adding(cashIncome).subtracting(cashCharges)
            return Self(period: period, accountID: accountID, ledgerRevision: ledger.revision,
                        generatedAt: cutoff, startDate: start, endDate: cutoff,
                        realizedPnL: realized, realizedEventCount: eventPnL.count,
                        cashIncome: cashIncome, cashCharges: cashCharges,
                        deposits: deposits, withdrawals: withdrawals,
                        openingCash: openingCash, closingCash: closingCash, bookedPnL: booked,
                        timeline: timeline, contributions: contributions,
                        containsSyntheticRecords: containsSynthetic)
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
            if contract.deliverables.count == 1, let delivery = contract.deliverables.first {
                return delivery.security.symbol
            }
            return "调整合约 · " + contract.occSymbol.trimmingCharacters(in: .whitespaces)
        }
    }
}
