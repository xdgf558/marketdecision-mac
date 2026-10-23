import Foundation
import CoreDomain

public enum OptionPersonalHistoryError: Error, Equatable, Sendable {
    case unverifiedReport, syntheticEvidence, invalidOpening
}

/// A read-only projection of one frozen, replayed performance report. It does not
/// concatenate reports or introduce a new win-rate, fee, closure or sample policy.
public struct OptionPersonalHistory: Sendable, Equatable {
    public let statistics: PerformanceTradeStatistics
    public let rounds: [PerformanceRound]
    public let excludedRoundCount: Int
    public let asOf: Date
    public static let statisticsScope = "该冻结账本截至估值时刻的卖期权经济回合；包含报告期初前的历史，不是当前合约或同策略的预测胜率。"

    public init(report: PerformanceReport) throws {
        try Task.checkCancellation()
        // Keep the original complete frozen input for integrity and replay.
        // Source eligibility below must not turn this into a sliced report.
        guard try PerformanceEngine.recompute(report) == report else {
            throw OptionPersonalHistoryError.unverifiedReport
        }
        try Task.checkCancellation()
        let state = try LedgerEngine.replay(accounts: report.input.accounts, events: report.input.events)
        let active = Set(state.activeEventIDs)
        let accountID = report.input.request.accountID
        let cutoff = report.input.request.days.map(\.valuationAt).max() ?? report.input.request.calculatedAt
        guard let account = report.input.accounts.first(where: { $0.id == accountID }) else {
            throw OptionPersonalHistoryError.unverifiedReport
        }
        let accountEvents = report.input.events.filter {
            active.contains($0.id) && $0.accountID == accountID && $0.effectiveAt <= cutoff
        }
        // Corrections restate historical facts even when the reversal itself is
        // dated after the cutoff. Its source still controls the selected history.
        let cutoffIDs = Set(report.input.events.filter {
            $0.accountID == accountID && $0.effectiveAt <= cutoff
        }.map(\.id))
        let corrections = report.input.events.filter { event in
            guard event.accountID == accountID, case .reversal(let reversal) = event.payload else { return false }
            return cutoffIDs.contains(reversal.originalEventID)
        }
        try Self.rejectSynthetic(account: account, events: accountEvents, corrections: corrections, request: report.input.request)
        var openings: [String: LedgerTrade] = [:]
        for event in accountEvents {
            guard case .trade(let trade) = event.payload, trade.effect == .open,
                  let lotID = trade.openingLotID else { continue }
            guard openings.updateValue(trade, forKey: lotID) == nil else {
                throw OptionPersonalHistoryError.invalidOpening
            }
        }
        var selected: [PerformanceRound] = []
        for round in report.rounds {
            try Task.checkCancellation()
            // Transfer-in roots and stock/long-option roots are not a sold-option
            // sample. An assigned short option retains its entire economic round.
            guard let trade = openings[round.roundLotID], trade.side == .sell,
                  case .option = trade.instrument else { continue }
            selected.append(round)
        }
        rounds = selected
        statistics = try PerformanceRounds.statistics(selected)
        excludedRoundCount = report.rounds.count - selected.count
        asOf = cutoff
    }

    private struct SourceScope: Encodable {
        let account: LedgerAccount
        let events: [LedgerEvent]
        let corrections: [LedgerEvent]
        let request: PerformanceRequest
    }

    /// Freeze/replay still covers every account, but personal eligibility uses
    /// only the selected account and its effective activity at the round cutoff.
    /// Other accounts, reversed records and later ordinary activity cannot label
    /// these rounds synthetic. Reversals that control this history remain in
    /// scope. All evidence in this account-specific request remains
    /// conservatively checked, including allocation/purpose and typed sources.
    /// Text markers are an exclusion, not broker/source authentication.
    private static func rejectSynthetic(account: LedgerAccount, events: [LedgerEvent], corrections: [LedgerEvent], request: PerformanceRequest) throws {
        let scope = SourceScope(account: account, events: events, corrections: corrections, request: request)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope))
        func containsMarker(_ value: Any) -> Bool {
            if let text = value as? String {
                return text.lowercased().contains("synthetic") || text.contains("合成")
            }
            if let values = value as? [Any] { return values.contains(where: containsMarker) }
            if let values = value as? [String: Any] { return values.values.contains(where: containsMarker) }
            return false
        }
        guard !containsMarker(json) else { throw OptionPersonalHistoryError.syntheticEvidence }
    }
}
