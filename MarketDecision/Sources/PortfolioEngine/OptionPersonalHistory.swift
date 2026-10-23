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
        try Self.rejectSynthetic(report.input)
        guard try PerformanceEngine.recompute(report) == report else {
            throw OptionPersonalHistoryError.unverifiedReport
        }
        try Task.checkCancellation()
        let state = try LedgerEngine.replay(accounts: report.input.accounts, events: report.input.events)
        let active = Set(state.activeEventIDs)
        let accountID = report.input.request.accountID
        let cutoff = report.input.request.days.map(\.valuationAt).max() ?? report.input.request.calculatedAt
        var openings: [String: LedgerTrade] = [:]
        for event in report.input.events where active.contains(event.id)
            && event.accountID == accountID && event.effectiveAt <= cutoff {
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

    /// The ledger has no typed synthetic flag. Preserve its existing synthetic
    /// source/memo markers, in addition to the typed evidence/quality flags. This
    /// is a conservative exclusion, not proof of a real broker account or source.
    private static func rejectSynthetic(_ input: PerformanceInput) throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
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
