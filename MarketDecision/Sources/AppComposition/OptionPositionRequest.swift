import Foundation
import CoreDomain
import PortfolioEngine
import Persistence

/// A navigation request binds the displayed position to its original ledger
/// revision. Opening another page must not silently select a newer lot or
/// replace the original quantity, direction or complete contract terms.
public struct OptionPositionRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let accountID: String
    public let lotID: String
    public let ledgerRevision: UUID
    public let action: OptionTradeEntryAction
    private let expectedLot: LedgerLot

    public init(lot: LedgerLot, action: OptionTradeEntryAction, ledgerRevision: UUID) throws {
        guard action == .closing || action == .expiration,
              case .option(let contract) = lot.instrument,
              lot.quantityRemaining.amount > 0 else { throw OptionTradeEntryError.invalidLot }
        try contract.validate()
        id = UUID(); accountID = lot.accountID; lotID = lot.id
        self.ledgerRevision = ledgerRevision; self.action = action; expectedLot = lot
    }

    /// Creates only an editable draft. Actual time, source, execution ID, price
    /// and fees remain blank; existing preview/commit and provenance validation
    /// are still required before any ledger write.
    public func draft(in snapshot: LedgerSnapshot) throws -> OptionTradeEntryDraft {
        try Task.checkCancellation()
        guard snapshot.revision == ledgerRevision else { throw OptionTradeEntryError.changedLot }
        guard snapshot.accounts.contains(where: { $0.id == accountID }) else { throw OptionTradeEntryError.invalidAccount }
        guard try LedgerEngine.replay(accounts: snapshot.accounts, events: snapshot.events) == snapshot.state else {
            throw OptionTradeEntryError.inconsistentSnapshot
        }
        try Task.checkCancellation()
        guard let lot = snapshot.state.lots.first(where: { $0.id == lotID }),
              lot.accountID == accountID, lot == expectedLot else { throw OptionTradeEntryError.changedLot }
        let others: [LedgerLot]
        if action == .closing {
            others = snapshot.state.lots.filter {
                $0.id != lotID && $0.accountID == accountID && $0.instrument == expectedLot.instrument
                    && $0.side == expectedLot.side && $0.quantityRemaining.amount > 0
            }
        } else { others = [] }
        // The existing draft exposes compatible candidates but selects only the
        // initiating lot. Adding other batches remains an explicit user choice.
        return try OptionTradeEntryDraft(lot: lot, action: action, otherClosingLots: others)
    }

    /// Status is informational. Reaching settlement time never creates an
    /// expiration, assignment or close event and never recognizes option profit.
    public static func status(for lot: LedgerLot, at instant: Date) -> String {
        if lot.isClosed { return "已结清" }
        if case .option(let contract) = lot.instrument, instant.timeIntervalSinceReferenceDate.isFinite {
            if contract.isLocalManualStandard {
                return contract.allowsLocalManualExpiration(at: instant) ? "到期日已到，待核对结果" : "持有中"
            }
            if let settlementAt = contract.settlementAt, instant >= settlementAt { return "已到期待确认" }
        }
        return "持有中"
    }
}
