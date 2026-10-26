import Foundation
import CoreDomain

public enum PerformanceEngine {
    public static let version = "portfolio-performance.v1"
    public static let parametersVersion = "PARAMETERS_V1"
    public static func calculate(_ input: PerformanceInput) throws -> PerformanceReport {
        try PerformanceValidation.validate(input)
        let completeLedger = try LedgerEngine.replay(accounts: input.accounts, events: input.events)
        let activeIDs = Set(completeLedger.activeEventIDs)
        // Explicit corrections restate historical economic facts. Append history remains frozen in input.
        let active = input.events.filter { activeIDs.contains($0.id) && $0.accountID == input.request.accountID }
        let context = PerformanceContext(input: input, activeEvents: active)
        let daily = try context.dailyValues()
        let returns = try PerformanceReturns.calculate(daily: daily, input: input, activeEvents: active)
        let lastState = try context.ledger(at: input.request.days.map(\.valuationAt).max() ?? input.request.calculatedAt)
        let rounds = try PerformanceRounds.calculate(input: input, state: lastState, activeEvents: active)
        return PerformanceReport(engineVersion: version, parametersVersion: parametersVersion,
            numericPolicyVersion: Money.numericPolicyVersion, input: input, daily: daily, segments: returns.segments,
            twr: returns.twr, xirr: returns.xirr, cagr: returns.cagr, risk: returns.risk, rolling: returns.rolling,
            monthly: returns.monthly, attribution: try context.attribution(daily: daily), rounds: rounds,
            tradeStatistics: try PerformanceRounds.statistics(rounds), groupedStatistics: try PerformanceGrouping.summarize(rounds: rounds, input: input, activeEvents: active), researchOnly: true,
            limitations: ["个人本地账本估值及研究；来源材料不授予供应商、实时行情或历史策略资格。",
                          "更正按冻结账本的当前活动事件重述历史；原始事件和冲销链保存在完整输入中。",
                          "日历完整性、现金流完整性与本地来源由明确输入负责；缺失不会填零或跨日沿用价格。",
                          "XIRR 扫描只报告指定范围内找到的根，不证明全域唯一。",
                          "账本及此报告尚未纳入旧研究备份；金额为管理口径，不是税务申报结果。"])
    }
    public static func recompute(_ report: PerformanceReport) throws -> PerformanceReport {
        guard report.engineVersion == version, report.parametersVersion == parametersVersion,
              report.numericPolicyVersion == Money.numericPolicyVersion else { throw PerformanceError.incompatibleVersion }
        return try calculate(report.input)
    }
}

enum PerformanceDates {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    static func parse(_ text: String) throws -> Date {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { throw PerformanceError.invalidCalendar }
        let n = text.split(separator: "-").compactMap { Int($0) }
        guard n.count == 3, n[0] >= 1,
              let date = calendar.date(from: DateComponents(year: n[0], month: n[1], day: n[2])),
              calendar.component(.year, from: date) == n[0], calendar.component(.month, from: date) == n[1], calendar.component(.day, from: date) == n[2] else { throw PerformanceError.invalidCalendar }
        return date
    }
    static func marketDay(_ date: Date) -> String {
        var c = calendar; c.timeZone = TimeZone(identifier: "America/New_York")!
        let p = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
    static func difference(_ from: String, _ to: String) throws -> Int {
        guard let days = calendar.dateComponents([.day], from: try parse(from), to: try parse(to)).day else { throw PerformanceError.invalidCalendar }
        return days
    }
    static func text(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}

enum PerformanceValidation {
    static func evidence(_ evidence: PerformanceEvidence, at: Date) throws {
        guard ledgerText(evidence.id), ledgerText(evidence.source), ledgerText(evidence.reference),
              ledgerDate(evidence.availableAt), evidence.availableAt <= at, !evidence.rawDocument.isEmpty else { throw PerformanceError.invalidEvidence }
    }
    static func validate(_ input: PerformanceInput) throws {
        let request = input.request
        guard ledgerDate(request.calculatedAt), input.accounts.contains(where: { $0.id == request.accountID }) else { throw PerformanceError.invalidInput }
        let calendar = request.calendar.tradingDays
        guard !calendar.isEmpty, calendar == calendar.sorted(), Set(calendar).count == calendar.count,
              Set(request.days.map(\.day)).count == request.days.count else { throw PerformanceError.invalidCalendar }
        for day in calendar { _ = try PerformanceDates.parse(day) }
        try evidence(request.calendar.evidence, at: request.calculatedAt)
        if request.externalFlowsComplete {
            guard let source = request.flowCompletenessEvidence else { throw PerformanceError.invalidEvidence }
            try evidence(source, at: request.calculatedAt)
        }
        var evidenceByID: [String: PerformanceEvidence] = [:]
        func remember(_ source: PerformanceEvidence) throws {
            try evidence(source, at: request.calculatedAt)
            if let old = evidenceByID[source.id], old != source { throw PerformanceError.duplicateIdentity }
            evidenceByID[source.id] = source
        }
        try remember(request.calendar.evidence)
        if let source = request.flowCompletenessEvidence { try remember(source) }
        for day in request.days {
            guard calendar.contains(day.day), ledgerDate(day.valuationAt), day.valuationAt <= request.calculatedAt,
                  PerformanceDates.marketDay(day.valuationAt) == day.day,
                  Set(day.sessions.map(\.id)).count == day.sessions.count,
                  Set(day.sessions.map(\.instrumentID)).count == day.sessions.count,
                  Set(day.prices.map(\.id)).count == day.prices.count else { throw PerformanceError.invalidInput }
            for session in day.sessions {
                guard ledgerText(session.id), ledgerText(session.instrumentID), ledgerDate(session.opensAt), ledgerDate(session.closesAt),
                      session.opensAt < session.closesAt, session.closesAt <= day.valuationAt,
                      PerformanceDates.marketDay(session.closesAt) == day.day else { throw PerformanceError.invalidCalendar }
                try remember(session.evidence)
            }
            for price in day.prices {
                guard ledgerText(price.id), ledgerText(price.instrumentID), ledgerText(price.sessionID), ledgerDate(price.quoteAt),
                      price.quality.count == Set(price.quality).count else { throw PerformanceError.invalidInput }
                try remember(price.evidence)
                if price.quality.contains(.synthetic), price.evidence.kind != .synthetic { throw PerformanceError.invalidEvidence }
            }
        }
        guard Set(request.accruals.map(\.id)).count == request.accruals.count,
              Set(request.rateCurves.map(\.id)).count == request.rateCurves.count else { throw PerformanceError.duplicateIdentity }
        for accrual in request.accruals {
            guard ledgerText(accrual.id), ledgerDate(accrual.recognizedAt), accrual.amount.amount > 0,
                  Set(accrual.settlements.map(\.ledgerEventID)).count == accrual.settlements.count else { throw PerformanceError.invalidAccrual }
            try remember(accrual.evidence)
            for settlement in accrual.settlements where !ledgerText(settlement.ledgerEventID) || settlement.amount.amount <= 0 { throw PerformanceError.invalidAccrual }
        }
        for curve in request.rateCurves { try PortfolioRates.validate(curve); try remember(curve.evidence) }
        if let benchmark = request.benchmark {
            try PortfolioBenchmarkSource.validate(benchmark)
            guard ledgerText(benchmark.symbol), Set(benchmark.points.map(\.day)).count == benchmark.points.count else { throw PerformanceError.invalidInput }
            for point in benchmark.points { _ = try PerformanceDates.parse(point.day); try remember(point.evidence) }
        }
        for allocation in request.roundAllocations { try remember(allocation.evidence) }
        for allocation in request.incomeAllocations { try remember(allocation.evidence) }
        for purpose in request.purposeEvidence { try remember(purpose.evidence) }
    }
}

private struct PerformanceContext {
    let input: PerformanceInput
    let activeEvents: [LedgerEvent]
    var request: PerformanceRequest { input.request }
    func ledger(at: Date) throws -> LedgerState {
        // The complete frozen ledger already checked roll/multi-leg membership. A daily
        // cut can lie between legs; remove only navigation grouping from this derived replay.
        let events = activeEvents.filter { $0.effectiveAt <= at }.map { event in
            LedgerEvent(id: event.id, accountID: event.accountID, effectiveAt: event.effectiveAt,
                providerSequence: event.providerSequence, source: event.source, payload: event.payload, notes: event.notes)
        }
        return try LedgerEngine.replay(accounts: input.accounts, events: events)
    }
    func validatedAccruals() throws -> [PerformanceAccrual] {
        var allocated: [String: Money] = [:]
        let zero = try Money("0")
        for accrual in request.accruals {
            var total = zero
            for settlement in accrual.settlements {
                guard let event = activeEvents.first(where: { $0.id == settlement.ledgerEventID }),
                      event.effectiveAt >= accrual.recognizedAt, case .cash(let cash) = event.payload else { throw PerformanceError.invalidAccrual }
                let matches: Bool
                switch accrual.kind {
                case .dividendReceivable: matches = cash.kind == .dividend
                case .interestReceivable: matches = cash.kind == .interest
                case .feePayable: matches = cash.kind == .fee
                case .otherReceivable: matches = cash.kind == .dividend || cash.kind == .interest
                case .otherPayable: matches = [.fee, .dividendWithholding, .interestWithholding, .otherTax].contains(cash.kind)
                }
                guard matches else { throw PerformanceError.invalidAccrual }
                let amount = try settlement.amount.posted(); total = try total.adding(amount)
                let aggregate = try (allocated[event.id] ?? zero).adding(amount)
                guard aggregate <= (try cash.amount.posted()) else { throw PerformanceError.invalidAccrual }
                allocated[event.id] = aggregate
            }
            guard total <= (try accrual.amount.posted()) else { throw PerformanceError.invalidAccrual }
        }
        return request.accruals
    }
    func accrualAmounts(at: Date, accruals: [PerformanceAccrual]) throws -> (Money, Money) {
        var receivable = try Money("0"), payable = try Money("0")
        for accrual in accruals where accrual.recognizedAt <= at {
            var amount = try accrual.amount.posted()
            for settlement in accrual.settlements {
                if let event = activeEvents.first(where: { $0.id == settlement.ledgerEventID }), event.effectiveAt <= at {
                    amount = try amount.subtracting(settlement.amount.posted())
                }
            }
            switch accrual.kind {
            case .dividendReceivable, .interestReceivable, .otherReceivable: receivable = try receivable.adding(amount)
            case .feePayable, .otherPayable: payable = try payable.adding(amount)
            }
        }
        return (receivable, payable)
    }
    func dailyValues() throws -> [PerformanceDailyValue] {
        let accruals = try validatedAccruals(), zero = try Money("0")
        let definitions = Dictionary(uniqueKeysWithValues: request.days.map { ($0.day, $0) })
        var result: [PerformanceDailyValue] = [], priorAt: Date?
        for day in request.calendar.tradingDays {
            try Task.checkCancellation()
            guard let definition = definitions[day] else {
                result.append(PerformanceDailyValue(day: day, valuationAt: nil, cash: nil, positions: [], receivables: nil,
                    payables: nil, nav: nil, externalFlow: zero, status: .missingInput, reason: "缺该交易日的明确估值时点"))
                continue
            }
            let state = try ledger(at: definition.valuationAt)
            let positions = try state.lots.filter { $0.accountID == request.accountID && !$0.isClosed }.map { try value($0, day: definition) }
            let (receivable, payable) = try accrualAmounts(at: definition.valuationAt, accruals: accruals)
            guard let cash = state.cashByAccount[request.accountID] else { throw PerformanceError.invalidInput }
            let eventsByID = Dictionary(uniqueKeysWithValues: activeEvents.map { ($0.id, $0) })
            let external = try state.postings.reduce(zero) { sum, posting in
                guard let event = eventsByID[posting.eventID], priorAt.map({ event.effectiveAt > $0 }) ?? (PerformanceDates.marketDay(event.effectiveAt) == day) else { return sum }
                return try sum.adding(posting.externalFlow)
            }
            var nav: Money? = try cash.adding(receivable).subtracting(payable)
            for position in positions {
                guard let market = position.marketValue, let current = nav else { nav = nil; continue }
                nav = try current.adding(market)
            }
            result.append(PerformanceDailyValue(day: day, valuationAt: definition.valuationAt, cash: cash, positions: positions,
                receivables: receivable, payables: payable, nav: nav, externalFlow: external,
                status: nav == nil ? .missingInput : .available, reason: nav == nil ? "至少一个持仓缺合格同会话原始价格" : ""))
            priorAt = definition.valuationAt
        }
        return result
    }
    func value(_ lot: LedgerLot, day: PerformanceDayInput) throws -> PerformancePosition {
        let instrument = lot.instrument.identity, zero = try Money("0")
        func missing(_ reason: String, session: PerformanceSession? = nil) -> PerformancePosition {
            PerformancePosition(lotID: lot.id, instrumentID: instrument, side: lot.side, quantity: lot.quantityRemaining,
                managementCost: lot.managementCostRemaining, marketValue: nil, unrealizedPnL: nil, price: nil, priceKind: .missing,
                sessionClose: session?.closesAt, quoteAt: nil, sourceIDs: [], reason: reason)
        }
        if case .option(let contract) = lot.instrument, contract.isLocalManualStandard {
            return missing("本地手工合约未核实官方条款与时刻，不能用于持仓估值")
        }
        guard let session = day.sessions.first(where: { $0.instrumentID == instrument }) else { return missing("缺证券官方会话时点") }
        if case .option(let contract) = lot.instrument {
            guard let effectiveFrom = contract.effectiveFrom, let tradingEndsAt = contract.tradingEndsAt,
                  session.closesAt >= effectiveFrom, session.closesAt <= tradingEndsAt,
                  contract.effectiveTo.map({ session.closesAt < $0 }) ?? true else {
                return missing("估值会话超出期权交割版本或最后交易时点；需处理真实调整/结算事件", session: session)
            }
        }
        let prices = day.prices.filter { $0.instrumentID == instrument && $0.sessionID == session.id && $0.quoteAt >= session.opensAt && $0.quoteAt <= session.closesAt }
            .filter { $0.basis == .raw && $0.timeliness != .unknown && !$0.quality.contains(.invalid) && !$0.quality.contains(.indicative) && !$0.quality.contains(.missing) }
            .sorted { $0.quoteAt == $1.quoteAt ? $0.id < $1.id : $0.quoteAt > $1.quoteAt }
        for observations in Dictionary(grouping: prices, by: \.quoteAt).values where observations.count > 1 {
            let first = observations[0]
            if observations.contains(where: { $0.bid != first.bid || $0.ask != first.ask || $0.last != first.last || $0.quality != first.quality || $0.timeliness != first.timeliness }) {
                return missing("同一会话同一时点存在冲突价格，不能按 ID 挑选", session: session)
            }
        }
        var chosen: (PerformancePrice, Money, PerformancePriceKind)?
        for p in prices where session.closesAt.timeIntervalSince(p.quoteAt) <= 300 && !p.quality.contains(.stale) {
            if let bid = p.bid, let ask = p.ask, bid > zero, ask >= bid {
                chosen = (p, try bid.adding(ask).divided(by: "2"), .mid); break
            }
        }
        if chosen == nil {
            for p in prices where session.closesAt.timeIntervalSince(p.quoteAt) <= 1800 {
                if let last = p.last, last > zero { chosen = (p, last, .lastStale); break }
            }
        }
        guard let (observation, price, kind) = chosen else { return missing("无有效 Mid≤300秒 或 Last≤1800秒；不跨会话沿用", session: session) }
        let multiplier: Money
        if case .option(let option) = lot.instrument { multiplier = option.quoteMultiplier } else { multiplier = try Money("1") }
        let unsigned = try price.multiplied(by: lot.quantityRemaining.decimalString).multiplied(by: multiplier.decimalString).posted()
        let market = try lot.side == .long ? unsigned : unsigned.multiplied(by: "-1")
        let pnl = try lot.side == .long ? market.subtracting(lot.managementCostRemaining) : market.adding(lot.managementCostRemaining)
        return PerformancePosition(lotID: lot.id, instrumentID: instrument, side: lot.side, quantity: lot.quantityRemaining,
            managementCost: lot.managementCostRemaining, marketValue: market, unrealizedPnL: pnl, price: price, priceKind: kind,
            sessionClose: session.closesAt, quoteAt: observation.quoteAt, sourceIDs: [observation.evidence.id, session.evidence.id],
            reason: kind == .lastStale ? "同会话 Last 替代，STALE，仅账本估值" : "同会话 Mid，仅账本估值")
    }
    func attribution(daily: [PerformanceDailyValue]) throws -> PerformanceAttribution? {
        guard let first = daily.first, let last = daily.last, let start = first.valuationAt, let end = last.valuationAt, end > start else { return nil }
        let a = try ledger(at: start), b = try ledger(at: end), zero = try Money("0")
        let realizedA = try a.realizations.reduce(zero) { try $0.adding($1.pnl) }, realizedB = try b.realizations.reduce(zero) { try $0.adding($1.pnl) }
        let realized = try realizedB.subtracting(realizedA)
        var dividends = zero, interest = zero, fees = zero, taxes = zero
        let period = activeEvents.filter { $0.effectiveAt > start && $0.effectiveAt <= end }
        for event in period {
            guard case .cash(let cash) = event.payload else { continue }
            switch cash.kind {
            case .dividend: dividends = try dividends.adding(cash.amount.posted())
            case .interest: interest = try interest.adding(cash.amount.posted())
            case .fee: fees = try fees.adding(cash.amount.posted())
            case .dividendWithholding, .interestWithholding, .otherTax: taxes = try taxes.adding(cash.amount.posted())
            case .deposit, .withdrawal: break
            }
        }
        let periodIDs = Set(period.map(\.id))
        let postings = b.postings.filter { periodIDs.contains($0.eventID) }
        let external = try postings.reduce(zero) { try $0.adding($1.externalFlow) }
        let bridge = try postings.reduce(zero) { try $0.adding($1.transferredEmbeddedGain) }
        let uA = first.positions.allSatisfy { $0.unrealizedPnL != nil } ? try first.positions.reduce(zero) { try $0.adding($1.unrealizedPnL ?? zero) } : nil
        let uB = last.positions.allSatisfy { $0.unrealizedPnL != nil } ? try last.positions.reduce(zero) { try $0.adding($1.unrealizedPnL ?? zero) } : nil
        let change = try uA.flatMap { old in try uB.map { try $0.subtracting(old) } }
        let accrualChange: Money?
        if let ar = first.receivables, let ap = first.payables, let br = last.receivables, let bp = last.payables {
            accrualChange = try br.subtracting(bp).subtracting(ar.subtracting(ap))
        } else { accrualChange = nil }
        let actual = try first.nav.flatMap { old in try last.nav.map { try $0.subtracting(old).subtracting(external) } }
        let explained: Money?
        if let change, let accrualChange {
            explained = try realized.adding(change).adding(dividends).adding(interest).subtracting(fees).subtracting(taxes).adding(accrualChange).subtracting(bridge)
        } else { explained = nil }
        let difference = try actual.flatMap { value in try explained.map { try value.subtracting($0) } }
        return PerformanceAttribution(startDay: first.day, endDay: last.day, realizedPnL: realized, changeInUnrealizedPnL: change,
            dividends: dividends, interest: interest, unallocatedFees: fees, taxes: taxes, changeInAccruals: accrualChange,
            transferEmbeddedGain: bridge, navChangeLessExternalFlows: actual, explainedPnL: explained, reconciliationDifference: difference)
    }
}
