import Foundation
import CoreDomain

/// Profit and purpose are independent. Assignment closes the option accounting leg,
/// while acquired shares keep its economic round open. Roll IDs are navigation only.
enum PerformanceRounds {
    static func calculate(input: PerformanceInput, state: LedgerState, activeEvents: [LedgerEvent]) throws -> [PerformanceRound] {
        let zero = try Money("0"), one = try Money("1")
        let events = activeEvents.filter { state.activeEventIDs.contains($0.id) }.sorted {
            if $0.effectiveAt != $1.effectiveAt { return $0.effectiveAt < $1.effectiveAt }
            return ($0.providerSequence ?? 0, $0.id) < ($1.providerSequence ?? 0, $1.id)
        }
        let eventMap = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let lots = state.lots.filter { $0.accountID == input.request.accountID }
        let lotMap = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0) })
        var rootLots: [String: LedgerLot] = [:], inherited: [String: String] = [:], transferred = Set<String>()
        for lot in lots {
            guard let event = eventMap[lot.openEventID] else { throw PerformanceError.invalidInput }
            switch event.payload {
            case .trade: rootLots[lot.id] = lot; inherited[lot.id] = lot.id
            case .transferIn: rootLots[lot.id] = lot; inherited[lot.id] = lot.id; transferred.insert(lot.id)
            default: break
            }
        }
        // Reorganizations move the existing economic round, not create a new trade.
        for event in events {
            if case .reorganization(let action) = event.payload {
                for row in action.rows {
                    if let root = inherited[row.sourceLotID] { for output in row.outputs { inherited[output.lotID] = root } }
                }
            }
        }
        let allocationGroups = Dictionary(grouping: input.request.roundAllocations, by: \.lotID)
        for (lotID, group) in allocationGroups {
            guard lotMap[lotID] != nil, Set(group.map(\.roundLotID)).count == group.count,
                  group.allSatisfy({ rootLots[$0.roundLotID] != nil && $0.fraction > zero }),
                  try group.reduce(zero, { try $0.adding($1.fraction) }) == one else { throw PerformanceError.invalidInput }
        }
        var ownership: [String: [(String, Money)]] = [:], missing = Set<String>()
        for lot in lots {
            if !lot.originatingOptionLotIDs.isEmpty {
                let origins = Set(lot.originatingOptionLotIDs)
                guard origins.allSatisfy({ rootLots[$0] != nil }) else { throw PerformanceError.invalidInput }
                if let explicit = allocationGroups[lot.id] {
                    guard Set(explicit.map(\.roundLotID)) == origins else { throw PerformanceError.invalidInput }
                    ownership[lot.id] = explicit.map { ($0.roundLotID, $0.fraction) }
                } else if origins.count == 1 { ownership[lot.id] = [(origins.first!, one)] }
                else { missing.formUnion(origins); ownership[lot.id] = [] }
            } else if let root = inherited[lot.id] {
                if let explicit = allocationGroups[lot.id], explicit.count != 1 || explicit[0].roundLotID != root { throw PerformanceError.invalidInput }
                ownership[lot.id] = [(root, one)]
            } else { throw PerformanceError.invalidInput }
        }
        var pnl = Dictionary(uniqueKeysWithValues: rootLots.keys.map { ($0, zero) })
        var lastAt: [String: Date] = [:]
        func add(_ amount: Money, lotID: String, event: LedgerEvent) throws {
            guard let weights = ownership[lotID] else { throw PerformanceError.invalidInput }
            if weights.isEmpty { return }
            let allocated = try RoundAmountAllocation.allocate(amount, weights: weights)
            for (root, part) in allocated {
                pnl[root] = try (pnl[root] ?? zero).adding(part)
                lastAt[root] = max(lastAt[root] ?? event.effectiveAt, event.effectiveAt)
            }
        }
        // On delivery OUT of existing shares, split only the premium/settlement fee
        // from the stock realization. On delivery IN, all premium stays in share cost.
        var stockSettlementAdjustment: [String: [String: Money]] = [:]
        var assigned = Set<String>(), acquisitionPrices: [String: [Money]] = [:]
        for event in events {
            guard case .optionSettlement(let action) = event.payload, action.action != .expiration else { continue }
            let optionRows = state.realizations.filter { row in
                guard row.eventID == event.id, row.kind == .settlement, rootLots[row.lotID] != nil, let lot = lotMap[row.lotID] else { return false }
                if case .option = lot.instrument { return true }; return false
            }
            let acquiring = (action.contract.right == .put && action.side == .short) || (action.contract.right == .call && action.side == .long)
            let optionIDs = Set(optionRows.map(\.lotID)); assigned.formUnion(optionIDs)
            if acquiring {
                for id in optionIDs {
                    for lot in lots where lot.openEventID == event.id && lot.originatingOptionLotIDs.contains(id) {
                        // Exact effective cost at acquisition, reconstructed before later disposals.
                        let prefix = try replay(input: input, events: events, through: event.id)
                        if let acquired = prefix.lots.first(where: { $0.id == lot.id }), acquired.quantityRemaining > zero {
                            acquisitionPrices[id, default: []].append(try acquired.managementCostRemaining.divided(by: acquired.quantityRemaining.decimalString))
                        }
                    }
                }
                continue
            }
            let feeParts = try RoundAmountAllocation.allocate(action.fee, weights: optionRows.map { ($0.lotID, $0.quantity) })
            var premiumTotal = zero
            for row in optionRows {
                let basis = try action.side == .short ? row.removedManagementCost : row.removedManagementCost.multiplied(by: "-1")
                let premium = try basis.subtracting(feeParts[row.lotID] ?? zero)
                try add(premium, lotID: row.lotID, event: event); premiumTotal = try premiumTotal.adding(premium)
            }
            let bySecurity = try RoundAmountAllocation.allocate(premiumTotal, weights: action.contract.deliverables.map { ($0.security.id, $0.basisWeight) })
            for delivery in action.contract.deliverables {
                let rows = state.realizations.filter { row in
                    guard row.eventID == event.id, row.kind == .settlement, let lot = lotMap[row.lotID], case .equity(let security) = lot.instrument else { return false }
                    return security.id == delivery.security.id
                }
                guard !rows.isEmpty, let premium = bySecurity[delivery.security.id] else { throw PerformanceError.invalidInput }
                let allocation = try RoundAmountAllocation.allocate(premium, weights: rows.map { ($0.lotID, $0.quantity) })
                for (lotID, part) in allocation { stockSettlementAdjustment[event.id, default: [:]][lotID] = part }
            }
        }
        for realization in state.realizations {
            guard let event = eventMap[realization.eventID] else { continue }
            let adjusted = try realization.pnl.subtracting(stockSettlementAdjustment[event.id]?[realization.lotID] ?? zero)
            try add(adjusted, lotID: realization.lotID, event: event)
        }
        // Transfers are external flows, not closed strategy outcomes. Identify the actual
        // consumed lots with before/after replay, including FIFO and partial transfers.
        for event in events {
            guard case .transferOut = event.payload else { continue }
            let after = try replay(input: input, events: events, through: event.id)
            let beforeEvents = Array(events.prefix(while: { $0.id != event.id }))
            let before = try replay(input: input, events: beforeEvents, through: nil)
            for lot in before.lots {
                if let remaining = after.lots.first(where: { $0.id == lot.id })?.quantityRemaining, remaining < lot.quantityRemaining {
                    transferred.formUnion((ownership[lot.id] ?? []).map(\.0))
                }
            }
        }
        var incomeSums: [String: Money] = [:], incomePairs = Set<String>()
        for allocation in input.request.incomeAllocations {
            guard allocation.amount > zero, rootLots[allocation.roundLotID] != nil,
                  let event = eventMap[allocation.ledgerEventID], case .cash(let cash) = event.payload,
                  [.dividend, .interest, .dividendWithholding, .interestWithholding].contains(cash.kind),
                  incomePairs.insert(allocation.ledgerEventID + "\u{0000}" + allocation.roundLotID).inserted else { throw PerformanceError.invalidInput }
            guard let root = rootLots[allocation.roundLotID], root.acquiredAt <= event.effectiveAt else { throw PerformanceError.invalidInput }
            if let security = cash.securityID {
                let relatedEquity = lots.contains { lot in
                    guard (ownership[lot.id] ?? []).contains(where: { $0.0 == allocation.roundLotID }), case .equity(let candidate) = lot.instrument else { return false }
                    return candidate.id == security && lot.acquiredAt <= event.effectiveAt
                }
                guard relatedEquity else { throw PerformanceError.invalidInput }
            }
            let amount = try allocation.amount.posted(), sum = try (incomeSums[event.id] ?? zero).adding(amount)
            guard sum <= (try cash.amount.posted()) else { throw PerformanceError.invalidInput }
            incomeSums[event.id] = sum
            let signed = try [.dividendWithholding, .interestWithholding].contains(cash.kind) ? amount.multiplied(by: "-1") : amount
            pnl[allocation.roundLotID] = try (pnl[allocation.roundLotID] ?? zero).adding(signed)
            lastAt[allocation.roundLotID] = max(lastAt[allocation.roundLotID] ?? event.effectiveAt, event.effectiveAt)
        }
        // Security-linked income cannot silently disappear from a round's total-return
        // accounting. A complete explicit allocation resolves the ambiguity.
        for event in events {
            guard case .cash(let cash) = event.payload, let security = cash.securityID,
                  [.dividend, .dividendWithholding].contains(cash.kind), incomeSums[event.id] != (try cash.amount.posted()) else { continue }
            let recognized = input.request.accruals.filter { $0.kind == .dividendReceivable && $0.settlements.contains(where: { $0.ledgerEventID == event.id }) }.map(\.recognizedAt)
            if recognized.isEmpty {
                // A payment date alone cannot identify ex-date holders. Do not silently
                // omit income merely because shares were sold before payment.
                for lot in lots where lot.acquiredAt <= event.effectiveAt {
                    if case .equity(let s) = lot.instrument, s.id == security { missing.formUnion((ownership[lot.id] ?? []).map(\.0)) }
                }
            } else {
                for at in recognized {
                    let exDateState = try replay(input: input, events: events.filter { $0.effectiveAt <= at }, through: nil)
                    for lot in exDateState.lots where !lot.isClosed {
                        if case .equity(let s) = lot.instrument, s.id == security { missing.formUnion((ownership[lot.id] ?? []).map(\.0)) }
                    }
                }
            }
        }
        guard Set(input.request.purposeEvidence.map(\.roundLotID)).count == input.request.purposeEvidence.count,
              input.request.purposeEvidence.allSatisfy({ rootLots[$0.roundLotID] != nil && ![.pending, .unverified].contains($0.outcome) }) else { throw PerformanceError.invalidInput }
        let purposes = Dictionary(uniqueKeysWithValues: input.request.purposeEvidence.map { ($0.roundLotID, $0.outcome) })
        var result: [PerformanceRound] = []
        for (id, root) in rootLots {
            let related = lots.filter { (ownership[$0.id] ?? []).contains(where: { $0.0 == id }) || $0.originatingOptionLotIDs.contains(id) }
            let economic: PerformanceEconomicState = missing.contains(id) ? .allocationRequired : (transferred.contains(id) ? .transferredUnresolved : (related.allSatisfy { $0.isClosed } ? .closed : .open))
            let value = missing.contains(id) || transferred.contains(id) ? nil : pnl[id]
            let purpose: PerformancePurposeState
            if economic != .closed { purpose = .pending }
            else if let supplied = purposes[id], root.strategy?.purpose != .acquireShares { purpose = supplied }
            else if let strategy = root.strategy {
                switch strategy.purpose {
                case .acquireShares:
                    if !assigned.contains(id) { purpose = .unassigned }
                    else if let maxPrice = strategy.maximumAcquisitionPrice, let prices = acquisitionPrices[id], !prices.isEmpty { purpose = prices.allSatisfy { $0 <= maxPrice } ? .success : .failure }
                    else { purpose = .unverified }
                case .premiumIncome: purpose = assigned.contains(id) ? .unverified : ((value?.amount ?? 0) > 0 ? .success : .failure)
                case .totalReturn, .hedgeOrManage: purpose = .unverified // User-defined goal requires its own evidence.
                }
            } else { purpose = .unverified }
            result.append(PerformanceRound(roundLotID: id, strategy: root.strategy, familyID: eventMap[root.openEventID]?.rollGroupID,
                economicState: economic, accountingState: value == nil ? .missingInput : .available, purposeState: purpose,
                netPnL: value, relatedLotIDs: related.map(\.id).sorted(), closedAt: economic == .closed ? lastAt[id] : nil,
                reason: economic == .allocationRequired ? "缺完整回合/收入分配证据" : (economic == .transferredUnresolved ? "转仓不等于经济回合完成" : "指派延续至关联股票处置；roll 只用于导航")))
        }
        return result.sorted { ($0.closedAt ?? .distantFuture, $0.roundLotID) < ($1.closedAt ?? .distantFuture, $1.roundLotID) }
    }
    private static func replay(input: PerformanceInput, events: [LedgerEvent], through: String?) throws -> LedgerState {
        var selected: [LedgerEvent] = []
        for event in events {
            selected.append(LedgerEvent(id: event.id, accountID: event.accountID, effectiveAt: event.effectiveAt, providerSequence: event.providerSequence, source: event.source, payload: event.payload, notes: event.notes))
            if event.id == through { break }
        }
        return try LedgerEngine.replay(accounts: input.accounts, events: selected)
    }
    static func wilson(successes: Int, count: Int) -> PerformanceInterval {
        guard count >= 30, successes >= 0, successes <= count else {
            return PerformanceInterval(low: nil, high: nil, status: .insufficientSample, sampleCount: count, reason: "默认 N_min=30；区间与频率使用同一合格回合集")
        }
        let z = 1.959963984540054, n = Double(count), p = Double(successes) / n
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let half = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
        return PerformanceInterval(low: max(0, center - half), high: min(1, center + half), status: .available, sampleCount: count,
            reason: "Wilson 95% 描述近似；不代表未来真实世界成功概率")
    }
    static func statistics(_ rounds: [PerformanceRound]) throws -> PerformanceTradeStatistics {
        let eligible = rounds.filter { $0.economicState == .closed && $0.accountingState == .available && $0.netPnL != nil }
        let positive = eligible.compactMap(\.netPnL).filter { $0.amount > 0 }, negative = eligible.compactMap(\.netPnL).filter { $0.amount < 0 }
        let n = eligible.count, w = positive.count, l = negative.count, z = n - w - l, zero = try Money("0")
        let sumWins = try positive.reduce(zero) { try $0.adding($1) }, sumLosses = try negative.reduce(zero) { try $0.adding($1) }
        func metric(_ numerator: Money, denominator: Int) throws -> PerformanceNumber {
            guard n >= 30 else { return PerformanceNumber(value: nil, status: .insufficientSample, reason: "默认 N_min=30；描述计数仍展示", sampleCount: n) }
            guard denominator > 0 else { return PerformanceNumber(value: nil, status: .zeroDenominator, sampleCount: n) }
            return PerformanceReturns.number(Double(try numerator.divided(by: String(denominator)).decimalString), n: n)
        }
        let success = eligible.filter { $0.purposeState == .success }.count, failure = eligible.filter { $0.purposeState == .failure }.count
        let unassigned = eligible.filter { $0.purposeState == .unassigned }.count
        let purposeN = success + failure
        let purposeRate = purposeN >= 30 ? PerformanceReturns.number(Double(success) / Double(purposeN), n: purposeN) : PerformanceNumber(value: nil, status: .insufficientSample, reason: "成功率分母为 S+F，不包含 U", sampleCount: purposeN)
        var run = 0, maximum = 0
        for round in eligible {
            if (round.netPnL?.amount ?? 0) < 0 { run += 1; maximum = max(maximum, run) } else { run = 0 }
        }
        let profitFactor: PerformanceNumber
        let infinite = n >= 30 && w > 0 && l == 0
        if n < 30 { profitFactor = PerformanceReturns.number(nil, .insufficientSample, n: n) }
        else if l == 0 { profitFactor = PerformanceReturns.number(nil, .zeroDenominator, n: n, reason: infinite ? "正收益且无亏损，Profit Factor 为 ∞；不进入排名" : "全零回合，Profit Factor 未定义") }
        else { profitFactor = PerformanceReturns.number(Double(try sumWins.divided(by: sumLosses.multiplied(by: "-1").decimalString).decimalString), n: n) }
        return PerformanceTradeStatistics(displayN: rounds.count, eligibleN: n, wins: w, losses: l, zeros: z, successes: success, failures: failure, unassigned: unassigned,
            winRate: try metric(Money(String(w)), denominator: n), lossRate: try metric(Money(String(l)), denominator: n), purposeSuccessRate: purposeRate,
            winRateInterval: wilson(successes: w, count: n), purposeSuccessInterval: wilson(successes: success, count: purposeN),
            averageWin: try metric(sumWins, denominator: w), averageLoss: try metric(sumLosses.multiplied(by: "-1"), denominator: l),
            expectancy: try metric(sumWins.adding(sumLosses), denominator: n), profitFactor: profitFactor,
            profitFactorInfinite: infinite, maximumConsecutiveLosses: maximum)
    }
}

private enum RoundAmountAllocation {
    static func allocate(_ value: Money, weights: [(String, Money)]) throws -> [String: Money] {
        guard !weights.isEmpty, Set(weights.map(\.0)).count == weights.count,
              weights.allSatisfy({ $0.1.amount >= 0 }) else { throw LedgerError.arithmeticInvariant }
        let zero = try Money("0"), sum = try weights.reduce(zero) { try $0.adding($1.1) }
        guard sum.amount > 0 else { throw LedgerError.arithmeticInvariant }
        let ordered = weights.filter { $0.1.amount > 0 }.sorted { $0.0 < $1.0 }
        var remaining = try value.posted(), result = Dictionary(uniqueKeysWithValues: weights.filter { $0.1.amount == 0 }.map { ($0.0, zero) })
        for (index, entry) in ordered.enumerated() {
            let amount = index == ordered.count - 1 ? remaining : try portion(value, numerator: entry.1, denominator: sum)
            result[entry.0] = amount; remaining = try remaining.subtracting(amount)
        }
        guard remaining == zero else { throw LedgerError.arithmeticInvariant }
        return result
    }
    static func portion(_ value: Money, numerator: Money, denominator: Money) throws -> Money {
        guard numerator.amount >= 0, denominator.amount > 0, numerator <= denominator else { throw LedgerError.arithmeticInvariant }
        func parts(_ value: Money) -> (digits: String, scale: Int) {
            let fields = value.decimalString.replacingOccurrences(of: "-", with: "").split(separator: ".")
            return (trim(fields.joined()), fields.count > 1 ? fields[1].count : 0)
        }
        let value = try value.posted(), a = parts(value), b = parts(numerator), c = parts(denominator)
        let top = multiply(a.digits, b.digits) + String(repeating: "0", count: c.scale + 2)
        let bottom = c.digits + String(repeating: "0", count: a.scale + b.scale)
        let cents = quotient(top, bottom), padded = String(repeating: "0", count: max(0, 3 - cents.count)) + cents
        let split = padded.index(padded.endIndex, offsetBy: -2)
        return try Money((value.amount < 0 && cents != "0" ? "-" : "") + padded[..<split] + "." + padded[split...])
    }
    static func trim(_ s: String) -> String { let t = s.drop(while: { $0 == "0" }); return t.isEmpty ? "0" : String(t) }
    static func compare(_ a: String, _ b: String) -> Bool { a.count == b.count ? a >= b : a.count > b.count }
    static func subtract(_ a: String, _ b: String) -> String {
        let x = Array(a.utf8.reversed()), y = Array(b.utf8.reversed()); var carry = 0, out: [UInt8] = []
        for i in x.indices {
            var d = Int(x[i] - 48) - (i < y.count ? Int(y[i] - 48) : 0) - carry
            carry = d < 0 ? 1 : 0; if d < 0 { d += 10 }; out.append(UInt8(d + 48))
        }
        return trim(String(decoding: out.reversed(), as: UTF8.self))
    }
    static func multiply(_ a: String, _ b: String) -> String {
        let x = Array(a.utf8.reversed()).map { Int($0 - 48) }, y = Array(b.utf8.reversed()).map { Int($0 - 48) }
        var result = Array(repeating: 0, count: x.count + y.count)
        for i in x.indices { for j in y.indices { result[i + j] += x[i] * y[j] } }
        for i in 0..<(result.count - 1) { result[i + 1] += result[i] / 10; result[i] %= 10 }
        return trim(result.reversed().map(String.init).joined())
    }
    static func quotient(_ a: String, _ b: String) -> String {
        let b = trim(b); var remainder = "0", result = ""
        for digit in trim(a) {
            remainder = trim(remainder + String(digit)); var n = 0
            while compare(remainder, b) { remainder = subtract(remainder, b); n += 1 }
            result += String(n)
        }
        return trim(result)
    }
}
