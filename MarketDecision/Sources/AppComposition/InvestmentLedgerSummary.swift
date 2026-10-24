import Foundation
import CoreDomain
import PortfolioEngine
import Persistence

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
        realizedPnL = try ledger.state.realizations.filter { accountEventIDs.contains($0.eventID) }
            .reduce(Money("0")) { try $0.adding($1.pnl) }
        openLots = ledger.state.lots.filter { $0.accountID == accountID && !$0.isClosed }
            .sorted {
                if $0.instrument.label != $1.instrument.label { return $0.instrument.label < $1.instrument.label }
                if $0.acquiredAt != $1.acquiredAt { return $0.acquiredAt < $1.acquiredAt }
                return $0.id < $1.id
            }
    }
}
