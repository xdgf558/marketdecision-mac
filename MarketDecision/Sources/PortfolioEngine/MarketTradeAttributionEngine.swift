import Foundation
import CoreDomain
import MarketAnalytics

/// Descriptive PERF-004 extension. It never writes to the ledger and never
/// changes the accounting, fees, economic round or N_min implementation.
public enum MarketTradeAttributionEngine {
    public static let schemaVersion = "market-trade-attribution.v1"
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "portfolio.market-attribution.parameters", version: "PARAMETERS_V1.PERF004.MARKET",
            revisionID: UUID(uuidString: "A0440000-2026-4019-8100-000000000001")!,
            values: ["grouping": .text("Explicit opening-time confirmed market label; complete market model reference separates buckets"),
                     "missing": .text("Missing, transferred, unreliable, unbounded and expired snapshots remain separate; no current-label backfill"),
                     "sessionValidity": .text("Frozen evidence declares first scheduled close after snapshot; opening must be strictly before it. Missing calendar proof is a gap."),
                     "statistics": .text("Existing economic rounds, fees and N_min policy unchanged")],
            state: .approved, dispositionReference: "ORD-05;PARAMETERS_V1:CALC-032;PERF-004")
        let model = ModelDefinition(id: "portfolio.market-attribution", version: schemaVersion,
            revisionID: UUID(uuidString: "A0440000-2026-4019-8100-000000000002")!, owner: "PortfolioEngine",
            purpose: "Offline descriptive economic round grouping by explicitly preserved opening-time market state",
            inputs: [.init(name: "frozenPerformanceAndMarketSnapshots", unit: "USD+label", role: .required)],
            outputs: [.init(name: "marketGroups", unit: "USD+count")],
            formula: "Closed eligible economic rounds grouped by confirmed opening snapshot label and exact model reference only before the frozen next scheduled close; unknown, missing calendar and expired remain separate; existing performance accounting and statistics",
            formulaVersion: schemaVersion, implementationReference: "PortfolioEngine/MarketTradeAttributionEngine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion,
            state: .approved, dispositionReference: "ORD-05;PARAMETERS_V1:CALC-032;PERF-004",
            knownLimitations: limitations, testFixtures: ["MarketTradeAttributionTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-19T00:00:00.000Z"))
        try parameters.validate(); try model.validate(); return (parameters, model)
    }
    public static func calculate(_ input: MarketTradeAttributionInput) throws -> MarketTradeAttributionReport {
        try Task.checkCancellation()
        let p = input.performance
        guard ledgerDate(input.createdAt), input.createdAt >= p.request.calculatedAt,
              p.accounts.count == 1, p.accounts.first?.id == p.request.accountID,
              p.events.allSatisfy({ $0.accountID == p.request.accountID && $0.effectiveAt <= p.request.calculatedAt })
        else { throw MarketTradeAttributionError.invalidInput }
        guard Set(input.observations.map(\.id)).count == input.observations.count,
              Set(input.observations.map(\.openingEventID)).count == input.observations.count,
              Set(input.observations.map(\.lotID)).count == input.observations.count
        else { throw MarketTradeAttributionError.duplicateObservation }
        if input.mode == .ledger, try containsSynthetic(input) { throw MarketTradeAttributionError.syntheticEvidence }
        let ledger = try LedgerEngine.replay(accounts: p.accounts, events: p.events)
        let active = Set(ledger.activeEventIDs)
        let events = Dictionary(uniqueKeysWithValues: p.events.filter { active.contains($0.id) }.map { ($0.id, $0) })
        let lots = Dictionary(uniqueKeysWithValues: ledger.lots.map { ($0.id, $0) })
        let performance = try PerformanceEngine.calculate(p)
        let roundIDs = Set(performance.rounds.map(\.roundLotID))
        var snapshots: [UUID: MarketStateReport] = [:], sources: [String: PerformanceEvidence] = [:]
        var calendarDeclarations: [String: MarketNextCloseEvidence] = [:]
        var observations: [String: MarketTradeObservation] = [:]
        for observation in input.observations {
            try Task.checkCancellation()
            guard [observation.id, observation.accountID, observation.openingEventID, observation.lotID].allSatisfy(ledgerText),
                  let event = events[observation.openingEventID], event.accountID == observation.accountID,
                  case .trade(let trade) = event.payload, trade.effect == .open,
                  trade.openingLotID == observation.lotID, roundIDs.contains(observation.lotID)
            else { throw MarketTradeAttributionError.unknownOpening }
            let source = observation.source, snapshot = observation.snapshot
            guard [observation.knownAt, source.availableAt].allSatisfy(ledgerDate),
                  snapshot.input.createdAt <= observation.knownAt,
                  snapshot.current.asOf <= observation.knownAt,
                  source.availableAt >= snapshot.input.createdAt,
                  source.availableAt <= observation.knownAt, observation.knownAt <= event.effectiveAt,
                  snapshot.current.isClosedSession else { throw MarketTradeAttributionError.invalidTiming }
            guard [source.id, source.source, source.reference].allSatisfy(ledgerText), !source.rawDocument.isEmpty
            else { throw MarketTradeAttributionError.invalidEvidence }
            if let previous = sources[source.id], previous != source { throw MarketTradeAttributionError.invalidEvidence }
            sources[source.id] = source
            if let previous = snapshots[snapshot.input.id] {
                guard previous == snapshot else { throw MarketTradeAttributionError.duplicateObservation }
            } else { snapshots[snapshot.input.id] = try MarketStateEngine.replay(snapshot) }
            if let next = observation.nextScheduledClose {
                guard ledgerDate(next.closeAt), (try? PerformanceDates.parse(next.sessionDate)) != nil,
                      PerformanceDates.marketDay(next.closeAt) == next.sessionDate,
                      next.sessionDate > snapshot.current.sessionDate,
                      next.closeAt > snapshot.current.asOf,
                      ledgerDate(next.calendar.availableAt), next.calendar.availableAt <= observation.knownAt,
                      next.calendar.availableAt <= event.effectiveAt else { throw MarketTradeAttributionError.invalidTiming }
                guard [next.calendar.id, next.calendar.source, next.calendar.reference].allSatisfy(ledgerText),
                      !next.calendar.rawDocument.isEmpty else { throw MarketTradeAttributionError.invalidEvidence }
                if let previous = sources[next.calendar.id], previous != next.calendar { throw MarketTradeAttributionError.invalidEvidence }
                // A calendar document can cover multiple sessions. Bind its next-close
                // interpretation to this snapshot, while source bytes remain global.
                let calendarKey = snapshot.input.id.uuidString + "/" + next.calendar.id
                if let previous = calendarDeclarations[calendarKey], previous != next { throw MarketTradeAttributionError.invalidEvidence }
                sources[next.calendar.id] = next.calendar; calendarDeclarations[calendarKey] = next
            }
            guard input.mode == .synthetic || (!snapshot.containsSynthetic && source.kind != .synthetic)
            else { throw MarketTradeAttributionError.syntheticEvidence }
            observations[observation.lotID] = observation
        }
        var rows: [MarketTradeAttributionRow] = []
        for round in performance.rounds {
            guard let lot = lots[round.roundLotID], let opening = events[lot.openEventID]
            else { throw MarketTradeAttributionError.invalidInput }
            let observation = observations[lot.id], snapshot = observation?.snapshot
            let label = snapshot?.current.confirmedLabel
            let gap: MarketTradeAttributionGap?
            if case .transferIn = opening.payload { gap = .transferredOpening }
            else if observation == nil { gap = .missingSnapshot }
            else if observation?.nextScheduledClose == nil { gap = .missingSessionValidity }
            else if let next = observation?.nextScheduledClose, opening.effectiveAt >= next.closeAt { gap = .staleSnapshot }
            else if label == .unreliable { gap = .unavailableMarketState }
            else { gap = nil }
            rows.append(.init(round: round, openingEventID: lot.openEventID,
                snapshotID: snapshot?.input.id, snapshotModel: snapshot?.model.reference,
                snapshotSession: snapshot?.current.sessionDate, label: gap == nil ? label?.title : nil, gap: gap))
        }
        let (parameters, model) = try definitions()
        return .init(schemaVersion: schemaVersion, input: input, model: model, parameters: parameters,
            performanceEngineVersion: performance.engineVersion, performanceParametersVersion: performance.parametersVersion,
            rows: rows, groupedStatistics: try group(rows), researchOnly: true, limitations: limitations)
    }
    public static func replay(_ report: MarketTradeAttributionReport) throws -> MarketTradeAttributionReport {
        guard report.schemaVersion == schemaVersion else { throw MarketTradeAttributionError.incompatibleReport }
        let expected = try calculate(report.input)
        guard report == expected else { throw MarketTradeAttributionError.incompatibleReport }; return expected
    }
    private static func group(_ rows: [MarketTradeAttributionRow]) throws -> [MarketTradeAttributionGroup] {
        var buckets: [String: [MarketTradeAttributionRow]] = [:]
        for row in rows {
            // Full immutable definition hash, not just a human-readable version string.
            let version = row.snapshotModel.map { $0.id + "/" + $0.version + "/" + $0.revisionID.uuidString + "/" + $0.contentHash } ?? "no-model"
            let label = row.gap.map { "gap:" + $0.rawValue } ?? row.label ?? "unknown"
            buckets[version + "/" + label, default: []].append(row)
        }
        return try buckets.keys.sorted().map { key in
            guard let rows = buckets[key], let first = rows.first else { throw MarketTradeAttributionError.invalidInput }
            let rounds = rows.map(\.round).sorted { ($0.closedAt ?? .distantFuture, $0.roundLotID) < ($1.closedAt ?? .distantFuture, $1.roundLotID) }
            let values = rounds.filter { $0.economicState == .closed && $0.accountingState == .available }.compactMap(\.netPnL)
            let total = try values.isEmpty ? nil : values.reduce(Money("0")) { try $0.adding($1) }
            let label: String
            switch first.gap {
            case .missingSnapshot: label = "缺少开仓时市场快照"
            case .missingSessionValidity: label = "缺少下一收盘会话证据"
            case .staleSnapshot: label = "开仓时市场快照已过期"
            case .unavailableMarketState: label = "开仓时暂无可靠判断"
            case .transferredOpening: label = "转入持仓，原开仓状态未知"
            case nil: label = first.label ?? "历史未知"
            }
            return .init(id: key, label: label, snapshotModel: first.snapshotModel, roundIDs: rounds.map(\.roundLotID),
                         completedNetPnL: total, statistics: try PerformanceRounds.statistics(rounds))
        }
    }
    private static func containsSynthetic(_ input: MarketTradeAttributionInput) throws -> Bool {
        func inspect(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                if object["kind"] as? String == "synthetic" || object["origin"] as? String == "synthetic" || object["containsSynthetic"] as? Bool == true { return true }
                return object.values.contains(where: inspect)
            }
            if let array = value as? [Any] { return array.contains(where: inspect) }
            if let text = value as? String { return text == "synthetic" || text.uppercased().hasPrefix("SYNTHETIC-") }
            return false
        }
        return try inspect(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)))
    }
    public static let limitations = [
        "仅按显式保存并绑定开仓事件与 lot 的完整市场快照分组；缺快照不以当前或事后重建标签回填。",
        "快照创建、可得和报告截止时刻均不得晚于开仓；这是离线声明的一致性核对，不证明真实历史发布或许可资格。",
        "须冻结该快照之后首个预定收盘会话及当时可得的日历证据；开仓达到该收盘时刻即不得沿用旧标签。缺证据或已过期单列，不以分钟数猜测有效期。",
        "预定会话是手工或合成声明；日期按纽约会话核对，但不验证真实交易所日历完整性，也不证明声明的下一收盘确为实际首个会话。",
        "同一市场模型完整引用才进入同一组；未确认的当日原始标签不能替代 confirmedLabel。",
        "费用、经济回合与样本门槛沿用既有收益引擎；N<30 不展示胜率或期望，零收益不计入亏损。",
        "冻结账本只读，归档恢复不会写入 portfolio-ledger.sqlite；结果不能推导预测力、买卖指令或真实世界概率。"
    ]
}
