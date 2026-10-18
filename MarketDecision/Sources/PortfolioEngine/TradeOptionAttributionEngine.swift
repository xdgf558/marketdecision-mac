import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

/// A separate PERF-004 report. It never mutates a historical PerformanceReport or ledger event.
public enum TradeOptionAttributionEngine {
    public static let schemaVersion = "trade-option-attribution.v1"
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "portfolio.trade-option-attribution.parameters", version: "OPTION_EVIDENCE_V1.PERF004",
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8100-000000000001")!,
            values: ["absoluteDeltaBins": .text("[0,.25),[.25,.5),[.5,.75),[.75,1]; unknown separate"),
                     "ivRankPercentBins": .text("<0,[0,25),[25,50),[50,75),[75,100],>100; unknown separate"),
                     "ivRankEvidence": .text("Recorded-unverified and replayed-history buckets separate; never current-value backfill"),
                     "deltaMaximumAgeSeconds": .integer(60),
                     "rounds": .text("Existing PerformanceRounds economic closure, attribution, N_min and Wilson policy unchanged")],
            state: .approved, dispositionReference: "USER_2026-10-18_OPTION_EVIDENCE_V1;PARAMETERS_V1:PERF-004")
        let model = ModelDefinition(id: "portfolio.trade-option-attribution", version: schemaVersion,
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8100-000000000002")!, owner: "PortfolioEngine",
            purpose: "Offline description of complete option-opening economic rounds by explicitly recorded trade-time observations",
            inputs: [.init(name: "frozenPerformanceInputAndOpeningEvidence", unit: "USD+ratio+percent", role: .required)],
            outputs: [.init(name: "descriptiveOpeningBuckets", unit: "USD+count")],
            formula: "One option opening lot per economic round; canonical long-option absDelta bucket; declared trade-time IVRank bucket with evidence basis separate; unknown is not zero; completedPnL/statistics reuse PerformanceRounds",
            formulaVersion: schemaVersion, implementationReference: "PortfolioEngine/TradeOptionAttributionEngine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: Money.numericPolicyVersion + "+" + OptionBSM.numericPolicyVersion,
            state: .approved, dispositionReference: "USER_2026-10-18_OPTION_EVIDENCE_V1", knownLimitations: limitations,
            testFixtures: ["TradeOptionAttributionTests"], introducedAt: try MillisecondInstant(iso8601: "2026-10-18T00:00:00.000Z"))
        try parameters.validate(); try model.validate(); return (parameters, model)
    }
    public static func calculate(_ input: TradeOptionAttributionInput) throws -> TradeOptionAttributionReport {
        try Task.checkCancellation()
        let performance = input.performance
        guard ledgerDate(input.createdAt), input.createdAt >= performance.request.calculatedAt,
              performance.accounts.count == 1, performance.accounts[0].id == performance.request.accountID,
              performance.events.allSatisfy({ $0.accountID == performance.request.accountID && $0.effectiveAt <= performance.request.calculatedAt })
        else { throw TradeOptionAttributionError.invalidInput }
        guard Set(input.observations.map(\.id)).count == input.observations.count,
              Set(input.observations.map(\.openingEventID)).count == input.observations.count,
              Set(input.observations.map(\.lotID)).count == input.observations.count else { throw TradeOptionAttributionError.duplicateObservation }
        if input.mode == .ledger, try containsSynthetic(input) { throw TradeOptionAttributionError.syntheticEvidence }
        let ledger = try LedgerEngine.replay(accounts: performance.accounts, events: performance.events)
        let active = Set(ledger.activeEventIDs)
        let events = Dictionary(uniqueKeysWithValues: performance.events.filter { active.contains($0.id) }.map { ($0.id, $0) })
        let result = try PerformanceEngine.calculate(performance)
        let lots = Dictionary(uniqueKeysWithValues: ledger.lots.map { ($0.id, $0) })
        let eligibleRoundIDs = Set(result.rounds.map(\.roundLotID))
        var observations: [String: TradeOptionObservation] = [:]
        var reportsByID: [UUID: OptionLabReport] = [:], sourcesByID: [String: PerformanceEvidence] = [:]
        for observation in input.observations {
            try Task.checkCancellation()
            if let existing = reportsByID[observation.report.input.id], existing != observation.report { throw TradeOptionAttributionError.duplicateObservation }
            reportsByID[observation.report.input.id] = observation.report
            for source in [observation.source] + (observation.ivRank.map { [$0.source] } ?? []) {
                if let existing = sourcesByID[source.id], existing != source { throw TradeOptionAttributionError.invalidEvidence }
                sourcesByID[source.id] = source
            }
            guard let event = events[observation.openingEventID], observation.accountID == performance.request.accountID,
                  event.accountID == observation.accountID, case .trade(let trade) = event.payload,
                  trade.effect == .open, trade.openingLotID == observation.lotID,
                  eligibleRoundIDs.contains(observation.lotID), case .option(let option) = trade.instrument,
                  trade.instrument.identity == observation.instrumentIdentity else { throw TradeOptionAttributionError.unknownOpening }
            try validate(observation, option: option, event: event, mode: input.mode)
            observations[observation.lotID] = observation
        }
        var rows: [TradeOptionAttributionRow] = [], excluded: [String] = []
        for round in result.rounds {
            try Task.checkCancellation()
            guard let lot = lots[round.roundLotID] else { throw TradeOptionAttributionError.invalidInput }
            guard case .option = lot.instrument else { excluded.append(round.roundLotID); continue }
            let observation = observations[round.roundLotID]
            let pricing = observation?.report.pricing?.legs.first { $0.contractID == observation?.contractID }
            let delta = pricing?.impliedVolatility.state == .available ? pricing?.canonicalGreeks?.delta : nil
            let iv = delta == nil ? nil : pricing?.impliedVolatility.volatility
            let missing: TradeOptionAttributionGap = events[lot.openEventID].map {
                if case .transferIn = $0.payload { return .transferredOpening }; return .missingObservation
            } ?? .missingObservation
            rows.append(.init(round: round, openingEventID: lot.openEventID, instrument: lot.instrument, observationID: observation?.id,
                delta: delta, impliedVolatility: iv, ivRank: observation?.ivRank?.value, ivRankBasis: observation?.ivRank?.basis,
                deltaGap: delta == nil ? (observation == nil ? missing : .missingCanonicalIV) : nil,
                ivRankGap: observation?.ivRank == nil ? (observation == nil ? missing : .missingIVRank) : nil))
        }
        let (parameters, model) = try definitions()
        return .init(schemaVersion: schemaVersion, input: input, model: model, parameters: parameters,
            performanceEngineVersion: result.engineVersion, performanceParametersVersion: result.parametersVersion,
            rows: rows, groupedStatistics: try group(rows), excludedNonOptionRoundIDs: excluded.sorted(), researchOnly: true, limitations: limitations)
    }
    public static func replay(_ report: TradeOptionAttributionReport) throws -> TradeOptionAttributionReport {
        guard report.schemaVersion == schemaVersion else { throw TradeOptionAttributionError.incompatibleReport }
        let expected = try calculate(report.input)
        guard report == expected else { throw TradeOptionAttributionError.incompatibleReport }; return expected
    }
    private static func validate(_ value: TradeOptionObservation, option: LedgerOptionVersion,
                                 event: LedgerEvent, mode: TradeOptionAttributionMode) throws {
        guard [value.id, value.accountID, value.openingEventID, value.lotID, value.instrumentIdentity, value.contractID, value.feedID].allSatisfy(ledgerText)
        else { throw TradeOptionAttributionError.invalidEvidence }
        try evidence(value.source, observedAt: value.observedAt, knownAt: value.knownAt, tradeAt: event.effectiveAt)
        guard event.effectiveAt.timeIntervalSince(value.observedAt) <= 60,
              value.report.input.asOf == value.observedAt, value.report.input.createdAt <= value.knownAt,
              day(value.observedAt) == value.session, day(event.effectiveAt) == value.session else { throw TradeOptionAttributionError.invalidTiming }
        let report = try OptionLabEngine.replay(value.report)
        let legs = [report.input.shortLeg] + (report.input.longLeg.map { [$0] } ?? [])
        guard let leg = legs.first(where: { $0.contractID == value.contractID }),
              option.deliverables.count == 1, option.deliverableCash.amount == 0,
              option.deliverables[0].quantity == (try Money("100")), option.deliverables[0].basisWeight == (try Money("1")),
              option.quoteMultiplier == (try Money("100")), option.settlementType == .physicalEquity,
              leg.contractID.replacingOccurrences(of: " ", with: "") == option.occSymbol.replacingOccurrences(of: " ", with: ""),
              leg.expirationDate == occExpiry(option.occSymbol), leg.strike == (try occStrike(option.occSymbol)),
              leg.specificationVersion == option.versionID, leg.multiplier == 100, leg.delivery == .standardPhysical100Shares,
              leg.symbol == option.deliverables[0].security.symbol, report.input.underlying.symbol == leg.symbol,
              (option.deliverables[0].security.kind == .stock ? OptionLabAsset.stock : .etf) == report.input.underlying.asset,
              (leg.right == .call ? LedgerOptionRight.call : .put) == option.right,
              (leg.exerciseStyle == .american ? LedgerExerciseStyle.american : .european) == option.exerciseStyle,
              report.input.expiry.settlementAt == option.settlementAt,
              option.exerciseConsideration == (try leg.strike.multiplied(by: "100")),
              option.effectiveFrom <= event.effectiveAt, option.effectiveTo.map({ event.effectiveAt < $0 }) ?? true,
              event.effectiveAt < option.tradingEndsAt else { throw TradeOptionAttributionError.mismatchedContract }
        if let capture = report.input.chainEvidence?.capture, capture.feedID != value.feedID { throw TradeOptionAttributionError.mismatchedContract }
        let sources = legs.map(\.source) + [report.input.underlying.source, report.input.expiry.source] + (report.input.pricing.map { [$0.source] } ?? [])
        guard sources.allSatisfy({ $0.enteredAt <= value.knownAt }),
              legs.allSatisfy({ $0.receivedAt <= value.observedAt && event.effectiveAt.timeIntervalSince($0.quotedAt) <= 60 }),
              report.input.underlying.receivedAt <= value.observedAt,
              event.effectiveAt.timeIntervalSince(report.input.underlying.quotedAt) <= 60 else { throw TradeOptionAttributionError.invalidTiming }
        if let pricing = report.pricing?.legs.first(where: { $0.contractID == leg.contractID }), let delta = pricing.canonicalGreeks?.delta {
            guard delta.isFinite, abs(delta) <= 1 else { throw TradeOptionAttributionError.invalidEvidence }
        }
        if let rank = value.ivRank {
            try evidence(rank.source, observedAt: rank.observedAt, knownAt: rank.knownAt, tradeAt: event.effectiveAt)
            guard rank.value.isFinite, ledgerText(rank.methodReference), rank.symbol == leg.symbol,
                  rank.feedID == value.feedID, rank.session == value.session, day(rank.observedAt) == rank.session
            else { throw TradeOptionAttributionError.mismatchedContract }
            if let history = rank.history {
                let replayed = try OptionVolatilityHistoryEngine.replay(history)
                guard replayed.ivRank == rank.value, replayed.input.current.input.symbol == rank.symbol,
                      replayed.input.current.input.feedID == rank.feedID, replayed.input.current.input.session == rank.session,
                      replayed.input.current.input.asOf == rank.observedAt, replayed.input.createdAt <= rank.knownAt,
                      rank.methodReference == replayed.model.formulaVersion,
                      replayed.input.calendar.source.enteredAt <= rank.knownAt,
                      ([replayed.input.current] + replayed.input.history).allSatisfy({ $0.input.createdAt <= rank.knownAt && dailyKnown($0.input, at: rank.knownAt) }),
                      mode == .synthetic || !replayed.containsSynthetic else { throw TradeOptionAttributionError.invalidEvidence }
            }
        }
    }
    private static func evidence(_ value: PerformanceEvidence, observedAt: Date, knownAt: Date, tradeAt: Date) throws {
        guard [observedAt, knownAt, value.availableAt].allSatisfy(ledgerDate), observedAt <= knownAt,
              value.availableAt >= observedAt, value.availableAt <= knownAt, knownAt <= tradeAt else { throw TradeOptionAttributionError.invalidTiming }
        guard [value.id, value.source, value.reference].allSatisfy(ledgerText), !value.rawDocument.isEmpty else { throw TradeOptionAttributionError.invalidEvidence }
    }
    private static func dailyKnown(_ input: OptionDailyInput, at: Date) -> Bool {
        let sources = [input.source, input.underlying.source] + input.contracts.flatMap { [$0.source, $0.expiry.source, $0.activity.source] }
        return sources.allSatisfy { $0.enteredAt <= at } && (input.calendar.map { $0.source.enteredAt <= at } ?? true)
    }
    private static func day(_ date: Date) -> MarketDate {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        return .init(year: c.component(.year, from: date), month: c.component(.month, from: date), day: c.component(.day, from: date))
    }
    private static func occExpiry(_ occ: String) -> MarketDate? {
        let text = String(occ.dropFirst(6).prefix(6))
        guard let year = Int(text.prefix(2)), let month = Int(text.dropFirst(2).prefix(2)), let day = Int(text.suffix(2)) else { return nil }
        return .init(year: 2000 + year, month: month, day: day)
    }
    private static func occStrike(_ occ: String) throws -> Money {
        guard let value = Int(occ.suffix(8)) else { throw TradeOptionAttributionError.mismatchedContract }
        return try Money(String(value)).divided(by: "1000")
    }
    /// Internal deterministic boundaries are directly tested without manufacturing canonical Greeks.
    static func bucket(_ value: Double?, axis: TradeOptionAttributionAxis) -> (String, String) {
        guard let value else { return ("unknown", "历史未知") }
        switch axis {
        case .absoluteDelta:
            let value = abs(value)
            if value < 0.25 { return ("0", "|Delta| [0, 0.25)") }
            if value < 0.5 { return ("1", "|Delta| [0.25, 0.5)") }
            if value < 0.75 { return ("2", "|Delta| [0.5, 0.75)") }
            return ("3", "|Delta| [0.75, 1]")
        case .ivRank:
            if value < 0 { return ("0", "IV Rank < 0%") }
            if value < 25 { return ("1", "IV Rank [0%, 25%)") }
            if value < 50 { return ("2", "IV Rank [25%, 50%)") }
            if value < 75 { return ("3", "IV Rank [50%, 75%)") }
            if value <= 100 { return ("4", "IV Rank [75%, 100%]") }
            return ("5", "IV Rank > 100%")
        }
    }
    private static func group(_ rows: [TradeOptionAttributionRow]) throws -> [TradeOptionAttributionGroup] {
        var result: [TradeOptionAttributionGroup] = []
        for axis in [TradeOptionAttributionAxis.absoluteDelta, .ivRank] {
            var grouped: [String: [TradeOptionAttributionRow]] = [:]
            for row in rows {
                let selection = bucket(axis == .absoluteDelta ? row.delta : row.ivRank, axis: axis)
                let basis = axis == .ivRank ? row.ivRankBasis?.rawValue ?? "unknown" : "canonicalLocal"
                grouped[basis + "/" + selection.0, default: []].append(row)
            }
            for key in grouped.keys.sorted() {
                guard let same = grouped[key], let first = same.first else { throw TradeOptionAttributionError.invalidInput }
                let rounds = same.map(\.round).sorted { ($0.closedAt ?? .distantFuture, $0.roundLotID) < ($1.closedAt ?? .distantFuture, $1.roundLotID) }
                let eligible = rounds.filter { $0.economicState == .closed && $0.accountingState == .available }.compactMap(\.netPnL)
                let net = try eligible.isEmpty ? nil : eligible.reduce(Money("0")) { try $0.adding($1) }
                result.append(.init(id: axis.rawValue + "/" + key, axis: axis,
                    label: bucket(axis == .absoluteDelta ? first.delta : first.ivRank, axis: axis).1,
                    ivRankBasis: axis == .ivRank ? first.ivRankBasis : nil, roundIDs: rounds.map(\.roundLotID), completedNetPnL: net,
                    statistics: try PerformanceRounds.statistics(rounds)))
            }
        }
        return result
    }
    private static func containsSynthetic(_ input: TradeOptionAttributionInput) throws -> Bool {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        func inspect(_ node: Any) -> Bool {
            if let d = node as? [String: Any] {
                if d["origin"] as? String == "synthetic" || d["kind"] as? String == "synthetic" { return true }
                return d.values.contains(where: inspect)
            }
            if let a = node as? [Any] { return a.contains(where: inspect) }; return false
        }
        return inspect(json)
    }
    public static let limitations = [
        "仅按开仓时明确保存的观察做离线描述统计；没有观察就进历史未知组，不使用当前 Delta、IV、IV Rank 回填。",
        "Delta 仅取冻结报告重放后的本地 Mid 反解 IV 对应长权每股 Greeks；绝对值分组不受买卖方向、张数影响。",
        "观察、来源可得及报告创建时间必须不晚于开仓；Delta 报价须在开仓前 60 秒内。这些是声明的一致性检查，不证明真实历史 PIT。",
        "IV Rank 为百分数，不裁剪区间外值；有完整历史才标本地重放，只有保存值则标记录值、方法未核对，两类统计分开。",
        "一个活动期权开仓 lot 对应一个经济回合；指派延续到关联股份，收益与统计沿用既有回合规则，非期权起始回合另列排除。",
        "费用和归属沿用冻结 PerformanceInput；未完成、转仓或分配不完整不计为已完成收益；N<30 不展示频率和期望。",
        "完整冻结账本含后来更正，effectiveAt 不是 recordedAt；不授予真实历史、供应商、校准、预测或交易资格。"
    ]
}
