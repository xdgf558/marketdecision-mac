import Foundation
import CoreDomain
import PortfolioEngine
import OptionsAnalytics

public enum OptionLabLedgerBasisError: Error, Equatable, Sendable {
    case inconsistentSnapshot, missingAccount, invalidAsOf, invalidUnderlying
}
public enum OptionLabLedgerGap: String, Codable, Equatable, Sendable {
    case noAccountHistory, completenessNotConfirmed, shortEquityNeedsMarginEvidence
    case uncoveredExistingCall, existingCashCommitmentsExceedBalance, negativeCash
}

/// This is a frozen, read-only management-ledger basis. It is not broker buying
/// power, a reservation in the ledger, or permission to execute an option trade.
public struct OptionLabLedgerBasis: Codable, Equatable, Sendable {
    public let version: String
    public let account: LedgerAccount
    public let ledgerRevision: UUID
    public let asOf: Date
    public let underlying: LedgerSecurity
    public let events: [LedgerEvent]
    public let completenessEvidence: String?
    public let cashBeforeTrade: Money
    public let committedCash: Money
    public let heldShares: Money
    public let committedShares: Money
    public let committedSharesBySecurity: [String: Money]
    public let gaps: [OptionLabLedgerGap]
    public let reference: String
    public var isUsableForOfflineLab: Bool { gaps.isEmpty }

    /// A nil result is an explicit gap, never an inferred zero balance. The
    /// caller may instead enter a separate, clearly labelled manual assumption.
    public var capital: OptionLabCapital? {
        guard isUsableForOfflineLab else { return nil }
        return OptionLabCapital(origin: .ledger, reference: reference, asOf: asOf, currency: account.currency,
            cashBeforeTrade: cashBeforeTrade, committedCash: committedCash,
            availableShares: heldShares, committedShares: committedShares,
            accountID: account.id, ledgerRevision: ledgerRevision,
            underlyingSymbol: underlying.symbol, underlyingAsset: underlying.kind == .stock ? .stock : .etf)
    }
}

public enum OptionLabLedgerBridge {
    public static let version = "option-lab-ledger-basis.v1"

    /// Validate a retained historical basis using its own events, never a newer
    /// account revision. This does not assert that the account is current now.
    public static func replay(_ basis: OptionLabLedgerBasis) throws -> OptionLabLedgerBasis {
        let state = try LedgerEngine.replay(accounts: [basis.account], events: basis.events)
        let snapshot = LedgerSnapshot(revision: basis.ledgerRevision, accounts: [basis.account], events: basis.events, state: state)
        let rebuilt = try inspect(snapshot: snapshot, accountID: basis.account.id, underlying: basis.underlying,
            asOf: basis.asOf, completenessEvidence: basis.completenessEvidence)
        guard rebuilt == basis else { throw OptionLabLedgerBasisError.inconsistentSnapshot }
        return rebuilt
    }

    /// The supplied snapshot must come from the verified ledger store. Replay is
    /// repeated here so a manually assembled inconsistent state cannot become a
    /// capital basis. Missing transactions outside that ledger are not detectable;
    /// an explicit completeness statement is therefore required, even for cash.
    public static func inspect(snapshot: LedgerSnapshot, accountID: String, underlying: LedgerSecurity,
                               asOf: Date, completenessEvidence: String?) throws -> OptionLabLedgerBasis {
        guard asOf.timeIntervalSinceReferenceDate.isFinite else { throw OptionLabLedgerBasisError.invalidAsOf }
        try underlying.validate()
        let replay = try LedgerEngine.replay(accounts: snapshot.accounts, events: snapshot.events)
        guard replay == snapshot.state else { throw OptionLabLedgerBasisError.inconsistentSnapshot }
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }),
              let cash = replay.cashByAccount[accountID] else { throw OptionLabLedgerBasisError.missingAccount }
        let events = snapshot.events.filter { $0.accountID == accountID }
        // This bridge describes the complete current ledger, not a guessed
        // historical cut. It cannot relabel later transactions as earlier facts.
        guard events.allSatisfy({ $0.effectiveAt <= asOf }) else { throw OptionLabLedgerBasisError.invalidAsOf }
        let evidence = completenessEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard evidence.map({ !$0.contains("\u{0000}") && $0.utf8.count <= 8_192 }) ?? true else {
            throw OptionLabLedgerBasisError.inconsistentSnapshot
        }
        let completeness = evidence.flatMap { $0.isEmpty ? nil : $0 }
        let zero = try Money("0")
        var cashCommitted = zero, holdings: [String: Money] = [:], reservations: [String: Money] = [:]
        var gaps: [OptionLabLedgerGap] = []
        if events.isEmpty { gaps.append(.noAccountHistory) }
        if completeness == nil { gaps.append(.completenessNotConfirmed) }
        if cash < zero { gaps.append(.negativeCash) }
        for lot in replay.lots where lot.accountID == accountID && !lot.isClosed {
            switch lot.instrument {
            case .equity(let security):
                if security.id == underlying.id && security != underlying { throw OptionLabLedgerBasisError.invalidUnderlying }
                if lot.side == .short {
                    if !gaps.contains(.shortEquityNeedsMarginEvidence) { gaps.append(.shortEquityNeedsMarginEvidence) }
                } else {
                    holdings[security.id] = try (holdings[security.id] ?? zero).adding(lot.quantityRemaining)
                }
            case .option(let contract):
                guard lot.side == .short else { continue }
                // No inferred spread offset or reuse of a long option as cash.
                // Unsettled expired positions retain obligations until an explicit
                // ledger settlement/expiration removes their open quantity.
                if contract.right == .put {
                    cashCommitted = try cashCommitted.adding(contract.exerciseConsideration.multiplied(by: lot.quantityRemaining.decimalString))
                } else {
                    cashCommitted = try cashCommitted.adding(contract.deliverableCash.multiplied(by: lot.quantityRemaining.decimalString))
                    for deliverable in contract.deliverables {
                        let security = deliverable.security
                        if security.id == underlying.id && security != underlying { throw OptionLabLedgerBasisError.invalidUnderlying }
                        let quantity = try deliverable.quantity.multiplied(by: lot.quantityRemaining.decimalString)
                        reservations[security.id] = try (reservations[security.id] ?? zero).adding(quantity)
                    }
                }
            }
        }
        if reservations.contains(where: { $0.value > (holdings[$0.key] ?? zero) }) { gaps.append(.uncoveredExistingCall) }
        if cashCommitted > cash { gaps.append(.existingCashCommitmentsExceedBalance) }
        let proof = Proof(version: version, account: account, ledgerRevision: snapshot.revision,
            asOf: asOf, underlying: underlying, events: events, completenessEvidence: completeness)
        let reference = version + ":" + LedgerCSV.hash(try encode(proof))
        return OptionLabLedgerBasis(version: version, account: account, ledgerRevision: snapshot.revision,
            asOf: asOf, underlying: underlying, events: events, completenessEvidence: completeness,
            cashBeforeTrade: cash, committedCash: cashCommitted, heldShares: holdings[underlying.id] ?? zero,
            committedShares: reservations[underlying.id] ?? zero, committedSharesBySecurity: reservations,
            gaps: gaps, reference: reference)
    }

    private struct Proof: Codable {
        let version: String
        let account: LedgerAccount
        let ledgerRevision: UUID
        let asOf: Date
        let underlying: LedgerSecurity
        let events: [LedgerEvent]
        let completenessEvidence: String?
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
