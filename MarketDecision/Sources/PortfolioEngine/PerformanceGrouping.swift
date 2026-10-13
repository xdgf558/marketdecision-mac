import Foundation
import CoreDomain

public enum PerformanceGroupingAxis: String, Codable, Sendable { case strategy, underlying }
public struct PerformanceGroupedStatistics: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let axis: PerformanceGroupingAxis
    public let label: String
    public let roundIDs: [String]
    /// Completed, eligible rounds only. Open or unallocated PnL is not presented
    /// as a realized group total; unallocated account fees remain in attribution.
    public let completedNetPnL: Money?
    public let statistics: PerformanceTradeStatistics
}

public enum PerformanceGrouping {
    public static func summarize(rounds: [PerformanceRound], input: PerformanceInput) throws -> [PerformanceGroupedStatistics] {
        let state = try LedgerEngine.replay(accounts: input.accounts, events: input.events)
        let activeIDs = Set(state.activeEventIDs)
        return try summarize(rounds: rounds, input: input, activeEvents: input.events.filter { activeIDs.contains($0.id) })
    }
    static func summarize(rounds: [PerformanceRound], input: PerformanceInput, activeEvents: [LedgerEvent]) throws -> [PerformanceGroupedStatistics] {
        struct Bucket {
            let label: String
            var rounds: [PerformanceRound]
        }
        let events = activeEvents.filter { $0.accountID == input.request.accountID }
        var underlyingByLot: [String: (String, String)] = [:]
        for event in events {
            let lot: String, instrument: LedgerInstrument
            switch event.payload {
            case .trade(let trade):
                guard trade.effect == .open, let id = trade.openingLotID else { continue }
                lot = id; instrument = trade.instrument
            case .transferIn(let transfer):
                lot = transfer.lotID; instrument = transfer.instrument
            default: continue
            }
            switch instrument {
            case .equity(let security): underlyingByLot[lot] = ("\(security.id.utf8.count):\(security.id)", security.symbol)
            case .option(let option):
                let securities = option.deliverables.map(\.security).sorted { $0.id < $1.id }
                let identity = securities.map { "\($0.id.utf8.count):\($0.id)" }.joined(separator: "|")
                underlyingByLot[lot] = (identity, securities.map(\.symbol).joined(separator: " / ") + (securities.count > 1 ? " (multiple deliverables)" : ""))
            }
        }
        var result: [PerformanceGroupedStatistics] = []
        for axis in [PerformanceGroupingAxis.strategy, .underlying] {
            var buckets: [String: Bucket] = [:]
            for round in rounds {
                let key: String, label: String
                switch axis {
                case .strategy:
                    key = round.strategy.map { "strategy:" + $0.id } ?? "unassigned"
                    label = round.strategy?.id ?? "未标注策略"
                case .underlying:
                    let source = underlyingByLot[round.roundLotID]
                    key = source.map { "underlying:" + $0.0 } ?? "unknown"
                    label = source?.1 ?? "未确定标的"
                }
                if buckets[key] == nil { buckets[key] = Bucket(label: label, rounds: []) }
                buckets[key]?.rounds.append(round)
            }
            for key in buckets.keys.sorted() {
                guard let bucket = buckets[key] else { throw PerformanceError.invalidInput }
                let ordered = bucket.rounds.sorted { ($0.closedAt ?? .distantFuture, $0.roundLotID) < ($1.closedAt ?? .distantFuture, $1.roundLotID) }
                let eligible = ordered.filter { $0.economicState == .closed && $0.accountingState == .available }.compactMap(\.netPnL)
                let net = try eligible.isEmpty ? nil : eligible.reduce(Money("0")) { try $0.adding($1) }
                result.append(.init(id: axis.rawValue + "/" + key, axis: axis, label: bucket.label,
                    roundIDs: ordered.map(\.roundLotID), completedNetPnL: net,
                    statistics: try PerformanceRounds.statistics(ordered)))
            }
        }
        return result
    }
}
