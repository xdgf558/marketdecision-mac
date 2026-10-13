import Foundation
import CoreDomain

/// Replays immutable facts; does not price positions, calculate NAV/returns or infer tax treatment.
public enum LedgerEngine {
    public static let version = "portfolio-ledger.v1"
    public static let policyVersion = "ledger-management.PARAMETERS_V1.v1"
    public static func replay(accounts: [LedgerAccount], events: [LedgerEvent]) throws -> LedgerState {
        var runner = try LedgerReplay(accounts: accounts)
        return try runner.run(events)
    }
}

private struct LedgerConsumed {
    let lot: LedgerLot
    let quantity: Money
    let cost: Money
}
private struct LedgerReplay {
    let zero: Money
    let accounts: [String: LedgerAccount]
    var state: LedgerState
    var instruments: [String: LedgerInstrument] = [:]
    var securities: [String: LedgerSecurity] = [:]
    var strategies: [String: LedgerStrategy] = [:]
    var corporateEvents: Set<String> = []

    init(accounts: [LedgerAccount]) throws {
        let initialZero = try Money("0")
        zero = initialZero
        guard Set(accounts.map(\.id)).count == accounts.count else { throw LedgerError.duplicateIdentity }
        for account in accounts { try account.validate() }
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        state = LedgerState(engineVersion: LedgerEngine.version, parameterVersion: "PARAMETERS_V1", numericPolicyVersion: Money.numericPolicyVersion, cashByAccount: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, initialZero) }),
                            lots: [], realizations: [], postings: [], activeEventIDs: [], reversedEventIDs: [], auditEventIDs: [])
    }
    mutating func run(_ events: [LedgerEvent]) throws -> LedgerState {
        var seen: [String: LedgerEvent] = [:], identities = Set<String>(), reversed = Set<String>()
        // Input order is append order, not effective order. A reversal cannot reach forward.
        for event in events {
            try event.validate()
            guard accounts[event.accountID] != nil else { throw LedgerError.missingAccount }
            guard seen[event.id] == nil, identities.insert(try event.idempotencyKey).inserted else { throw LedgerError.duplicateIdentity }
            if case .reversal(let r) = event.payload {
                guard let original = seen[r.originalEventID], original.accountID == event.accountID,
                      reversed.insert(original.id).inserted else { throw LedgerError.invalidReversal }
                if case .reversal = original.payload { throw LedgerError.invalidReversal }
            }
            seen[event.id] = event
        }
        let active = events.filter {
            if case .reversal = $0.payload { return false }
            return !reversed.contains($0.id)
        }.sorted(by: Self.precedes)
        try validateOrdering(active); try validateRolls(active)
        for event in active {
            try apply(event)
            state.activeEventIDs.append(event.id)
        }
        state.lots.sort { $0.id < $1.id }
        state.reversedEventIDs = reversed.sorted(); state.auditEventIDs = events.map(\.id)
        return state
    }
    static func precedes(_ a: LedgerEvent, _ b: LedgerEvent) -> Bool {
        if a.effectiveAt != b.effectiveAt { return a.effectiveAt < b.effectiveAt }
        if a.providerSequence != b.providerSequence { return (a.providerSequence ?? Int.max) < (b.providerSequence ?? Int.max) }
        return a.id < b.id
    }
    func touched(_ event: LedgerEvent) -> Set<String> {
        func keys(_ instrument: LedgerInstrument) -> Set<String> {
            switch instrument {
            case .equity(let s): [s.id]
            case .option(let o): Set(o.deliverables.map { $0.security.id }).union([o.occSymbol])
            }
        }
        switch event.payload {
        case .trade(let t): return keys(t.instrument)
        case .optionSettlement(let s): return keys(.option(s.contract))
        case .split(let s): return [s.securityID]
        case .contractAdjustment(let a): return keys(.option(a.previous)).union(keys(.option(a.replacement)))
        case .transferIn(let t): return keys(t.instrument)
        case .transferOut(let t): return keys(t.instrument)
        case .reorganization(let r): return Set(r.rows.flatMap { [$0.sourceLotID] + $0.outputs.map { $0.security.id } }).union(["all-lots"])
        case .returnOfCapital, .cashInLieu: return ["all-lots"]
        case .cash(let c): return c.securityID.map { [$0] } ?? []
        case .reversal: return []
        }
    }
    func validateOrdering(_ events: [LedgerEvent]) throws {
        var sameInstant: [LedgerEvent] = []
        for event in events {
            if sameInstant.first?.effectiveAt != event.effectiveAt { sameInstant = [] }
            for prior in sameInstant where prior.accountID == event.accountID {
                // Independent acquisitions commute. Their FIFO order is acquisition instant + lot ID.
                func independentOpening(_ value: LedgerPayload) -> Bool {
                    switch value { case .trade(let t): return t.effect == .open; case .transferIn: return true; default: return false }
                }
                if independentOpening(prior.payload) && independentOpening(event.payload) { continue }
                let a = touched(prior), b = touched(event)
                let conflicts = !a.isDisjoint(with: b) || (a.contains("all-lots") && !b.isEmpty) || (b.contains("all-lots") && !a.isEmpty)
                if conflicts && (prior.source.sourceSystem != event.source.sourceSystem || prior.providerSequence == nil || event.providerSequence == nil || prior.providerSequence == event.providerSequence) {
                    throw LedgerError.ambiguousOrdering
                }
            }
            sameInstant.append(event)
        }
    }
    func validateRolls(_ events: [LedgerEvent]) throws {
        for group in Dictionary(grouping: events.filter { $0.rollGroupID != nil }, by: { $0.rollGroupID! }).values {
            guard Set(group.map(\.accountID)).count == 1 else { throw LedgerError.invalidRoll }
            var closes = 0, opens = 0
            for event in group {
                guard case .trade(let trade) = event.payload, case .option = trade.instrument else { throw LedgerError.invalidRoll }
                if trade.effect == .close { closes += 1 } else { opens += 1 }
            }
            guard closes > 0, opens > 0 else { throw LedgerError.invalidRoll }
            // The group is navigation only. Old PnL is never carried into a new lot.
        }
        for group in Dictionary(grouping: events.filter { $0.multiLegGroupID != nil }, by: { $0.multiLegGroupID! }).values {
            guard group.count >= 2, Set(group.map(\.accountID)).count == 1,
                  group.allSatisfy({ if case .trade = $0.payload { return true }; return false }) else { throw LedgerError.invalidStrategy }
        }
    }
    mutating func register(_ instrument: LedgerInstrument) throws {
        if let prior = instruments[instrument.identity], prior != instrument { throw LedgerError.invalidIdentity }
        instruments[instrument.identity] = instrument
        let entries: [LedgerSecurity]
        switch instrument { case .equity(let s): entries = [s]; case .option(let o): entries = o.deliverables.map(\.security) }
        for security in entries {
            if let prior = securities[security.id], prior != security { throw LedgerError.invalidIdentity }
            securities[security.id] = security
        }
    }
    mutating func createLot(id: String, event: LedgerEvent, instrument: LedgerInstrument, side: LedgerPositionSide,
                            quantity: Money, cost: Money, acquiredAt: Date? = nil, strategy: LedgerStrategy? = nil,
                            taxBasis: Money? = nil, origins: [String] = [], adjustments: [String] = []) throws {
        guard !state.lots.contains(where: { $0.id == id }) else { throw LedgerError.duplicateIdentity }
        try register(instrument)
        if let strategy {
            if let prior = strategies[strategy.id], prior != strategy { throw LedgerError.invalidStrategy }
            strategies[strategy.id] = strategy
        }
        state.lots.append(LedgerLot(id: id, accountID: event.accountID, instrument: instrument, side: side,
                                   openEventID: event.id, acquiredAt: acquiredAt ?? event.effectiveAt,
                                   quantityOpened: quantity, quantityRemaining: quantity, managementCostRemaining: try cost.posted(),
                                   strategy: strategy, userReportedOriginalTaxBasis: taxBasis,
                                   originatingOptionLotIDs: origins, adjustmentEventIDs: adjustments))
    }
    mutating func post(_ event: LedgerEvent, cash: Money, gross: Money, fee: Money? = nil,
                       external: Money? = nil, embedded: Money? = nil) throws {
        let cash = try cash.posted()
        state.cashByAccount[event.accountID] = try (state.cashByAccount[event.accountID] ?? zero).adding(cash)
        state.postings.append(LedgerPosting(eventID: event.id, accountID: event.accountID, cashChange: cash,
            externalFlow: try (external ?? zero).posted(), transactionFee: try (fee ?? zero).posted(), grossCash: try gross.posted(),
            transferredEmbeddedGain: try (embedded ?? zero).posted()))
    }
    func selectedIndices(accountID: String, instrument: LedgerInstrument, side: LedgerPositionSide, quantity: Money,
                         selections: [LedgerLotSelection]) throws -> [(Int, Money)] {
        guard let account = accounts[accountID] else { throw LedgerError.missingAccount }
        let candidates = state.lots.indices.filter { state.lots[$0].accountID == accountID && state.lots[$0].instrument == instrument && state.lots[$0].side == side && !state.lots[$0].isClosed }
        var result: [(Int, Money)] = []
        if !selections.isEmpty {
            var total = zero
            for selection in selections {
                guard let i = candidates.first(where: { state.lots[$0].id == selection.lotID }), selection.quantity <= state.lots[i].quantityRemaining else { throw LedgerError.invalidLotSelection }
                try LedgerValidation.quantity(selection.quantity, for: instrument)
                result.append((i, selection.quantity)); total = try total.adding(selection.quantity)
            }
            guard total == quantity else { throw LedgerError.invalidLotSelection }
        } else {
            guard account.costBasisMethod == .fifo else { throw LedgerError.invalidLotSelection }
            let sorted = candidates.sorted { a, b in
                state.lots[a].acquiredAt == state.lots[b].acquiredAt ? state.lots[a].id < state.lots[b].id : state.lots[a].acquiredAt < state.lots[b].acquiredAt
            }
            var remaining = quantity
            for i in sorted where remaining.amount > 0 {
                let q = min(remaining, state.lots[i].quantityRemaining); result.append((i, q)); remaining = try remaining.subtracting(q)
            }
            guard remaining == zero else { throw LedgerError.insufficientLots }
        }
        return result.sorted { state.lots[$0.0].id < state.lots[$1.0].id }
    }
    mutating func consume(accountID: String, instrument: LedgerInstrument, side: LedgerPositionSide,
                          quantity: Money, selections: [LedgerLotSelection]) throws -> [LedgerConsumed] {
        try register(instrument)
        let choices = try selectedIndices(accountID: accountID, instrument: instrument, side: side, quantity: quantity, selections: selections)
        var removed: [LedgerConsumed] = []
        for (index, q) in choices {
            let lot = state.lots[index]
            let cost = q == lot.quantityRemaining ? lot.managementCostRemaining : try LedgerAllocation.portion(lot.managementCostRemaining, numerator: q, denominator: lot.quantityRemaining)
            state.lots[index].quantityRemaining = try lot.quantityRemaining.subtracting(q)
            state.lots[index].managementCostRemaining = try lot.managementCostRemaining.subtracting(cost)
            removed.append(LedgerConsumed(lot: lot, quantity: q, cost: cost))
        }
        return removed
    }
    mutating func realize(_ event: LedgerEvent, consumed: [LedgerConsumed], total: Money, side: LedgerPositionSide,
                          kind: LedgerRealizationKind, forceZero: Bool = false) throws {
        let allocations = try LedgerAllocation.allocate(total, weights: consumed.map { ($0.lot.id, $0.quantity) })
        for item in consumed {
            guard let amount = allocations[item.lot.id] else { throw LedgerError.arithmeticInvariant }
            let pnl = forceZero ? zero : try (side == .long ? amount.subtracting(item.cost) : item.cost.subtracting(amount))
            state.realizations.append(LedgerRealization(eventID: event.id, lotID: item.lot.id, quantity: item.quantity,
                removedManagementCost: item.cost, netProceedsOrCloseCost: amount, pnl: pnl, kind: kind))
        }
    }
    mutating func apply(_ event: LedgerEvent) throws {
        switch event.payload {
        case .cash(let cash):
            let positive = [.deposit, .dividend, .interest].contains(cash.kind)
            let amount = try cash.amount.posted(), delta = try positive ? amount : amount.multiplied(by: "-1")
            try post(event, cash: delta, gross: delta, external: [.deposit, .withdrawal].contains(cash.kind) ? delta : zero)
        case .trade(let trade):
            try register(trade.instrument)
            let multiplier: Money
            if case .option(let option) = trade.instrument { multiplier = option.quoteMultiplier } else { multiplier = try Money("1") }
            let gross = try trade.unitPrice.multiplied(by: trade.quantity.decimalString).multiplied(by: multiplier.decimalString).posted()
            let fee = try trade.fee.posted(), buying = trade.side == .buy
            let total = try buying ? gross.adding(fee) : gross.subtracting(fee)
            let cash = try buying ? total.multiplied(by: "-1") : total
            if trade.effect == .open {
                guard let id = trade.openingLotID else { throw LedgerError.invalidLotSelection }
                try createLot(id: id, event: event, instrument: trade.instrument, side: buying ? .long : .short,
                              quantity: trade.quantity, cost: total, strategy: trade.strategy)
            } else {
                let side: LedgerPositionSide = buying ? .short : .long
                let consumed = try consume(accountID: event.accountID, instrument: trade.instrument, side: side,
                                           quantity: trade.quantity, selections: trade.selections)
                try realize(event, consumed: consumed, total: total, side: side, kind: .trade)
            }
            try post(event, cash: cash, gross: buying ? gross.multiplied(by: "-1") : gross, fee: fee)
        case .optionSettlement(let s): try settle(event, s)
        case .split(let s): try split(event, s)
        case .reorganization(let r): try reorganize(event, r)
        case .returnOfCapital(let r):
            var total = zero
            for id in r.allocations.keys.sorted() {
                guard let value = r.allocations[id], let index = state.lots.firstIndex(where: { $0.id == id && $0.accountID == event.accountID && !$0.isClosed }),
                      case .equity = state.lots[index].instrument, state.lots[index].side == .long else { throw LedgerError.invalidCorporateAction }
                let amount = try value.posted(), cost = state.lots[index].managementCostRemaining
                let applied = min(amount, max(zero, cost)), excess = try amount.subtracting(applied)
                state.lots[index].managementCostRemaining = try cost.subtracting(applied)
                state.lots[index].adjustmentEventIDs.append(event.id); total = try total.adding(amount)
                if excess.amount > 0 {
                    state.realizations.append(LedgerRealization(eventID: event.id, lotID: id, quantity: zero,
                        removedManagementCost: zero, netProceedsOrCloseCost: excess, pnl: excess, kind: .rocExcess))
                }
            }
            try post(event, cash: total, gross: total); corporateEvents.insert(event.id)
        case .cashInLieu(let c):
            guard corporateEvents.contains(c.corporateActionEventID) else { throw LedgerError.invalidCorporateAction }
            let fee = try c.fee.posted(), net = try c.cash.posted().subtracting(fee)
            var consumed: [LedgerConsumed] = []
            for selection in c.selections {
                guard let lot = state.lots.first(where: { $0.id == selection.lotID && $0.accountID == event.accountID }),
                      lot.side == .long, case .equity = lot.instrument,
                      lot.adjustmentEventIDs.contains(c.corporateActionEventID) else { throw LedgerError.invalidCorporateAction }
                consumed += try consume(accountID: event.accountID, instrument: lot.instrument, side: .long, quantity: selection.quantity, selections: [selection])
            }
            try realize(event, consumed: consumed, total: net, side: .long, kind: .cashInLieu)
            try post(event, cash: net, gross: c.cash, fee: fee)
        case .transferIn(let t):
            try createLot(id: t.lotID, event: event, instrument: t.instrument, side: t.side, quantity: t.quantity,
                          cost: t.historicalCost, acquiredAt: t.acquiredAt, strategy: t.strategy, taxBasis: t.userReportedTaxBasis)
            let market = try t.eventMarketValue.posted(), cost = try t.historicalCost.posted()
            let external = try t.side == .long ? market : market.multiplied(by: "-1")
            let gain = try t.side == .long ? market.subtracting(cost) : cost.subtracting(market)
            try post(event, cash: zero, gross: zero, external: external, embedded: gain)
        case .transferOut(let t):
            let consumed = try consume(accountID: event.accountID, instrument: t.instrument, side: t.side, quantity: t.quantity, selections: t.selections)
            let cost = try consumed.reduce(zero) { try $0.adding($1.cost) }, market = try t.eventMarketValue.posted()
            let external = try t.side == .long ? market.multiplied(by: "-1") : market
            let gain = try t.side == .long ? cost.subtracting(market) : market.subtracting(cost)
            try post(event, cash: zero, gross: zero, external: external, embedded: gain)
        case .contractAdjustment(let a):
            try register(.option(a.previous)); try register(.option(a.replacement))
            let indices = state.lots.indices.filter { state.lots[$0].accountID == event.accountID && state.lots[$0].instrument == .option(a.previous) && !state.lots[$0].isClosed }
            guard !indices.isEmpty else { throw LedgerError.invalidCorporateAction }
            for index in indices {
                let q = try state.lots[index].quantityRemaining.multiplied(by: a.contractQuantityRatio.decimalString)
                try ledgerPositiveQuantity(q, integral: true)
                state.lots[index].instrument = .option(a.replacement); state.lots[index].quantityRemaining = q
                state.lots[index].adjustmentEventIDs.append(event.id)
            }
            try post(event, cash: zero, gross: zero); corporateEvents.insert(event.id)
        case .reversal: throw LedgerError.invalidReversal
        }
    }

    mutating func settle(_ event: LedgerEvent, _ s: LedgerOptionSettlement) throws {
        let consumed = try consume(accountID: event.accountID, instrument: .option(s.contract), side: s.side, quantity: s.quantity, selections: s.optionSelections)
        let optionBasis = try consumed.reduce(zero) { try $0.adding($1.cost) }, fee = try s.fee.posted()
        if s.action == .expiration {
            // Long expiration loses paid premium and any fee. Short expiration realizes net credit less this fee.
            let total = s.side == .long ? try fee.multiplied(by: "-1") : fee
            try realize(event, consumed: consumed, total: total, side: s.side, kind: .expiration)
            try post(event, cash: fee.multiplied(by: "-1"), gross: zero, fee: fee)
            return
        }
        let acquiring = (s.contract.right == .call && s.side == .long) || (s.contract.right == .put && s.side == .short)
        let gross = try s.contract.exerciseConsideration.subtracting(s.contract.deliverableCash).multiplied(by: s.quantity.decimalString).posted()
        let basisEffect = try s.side == .long ? optionBasis : optionBasis.multiplied(by: "-1")
        let aggregate = acquiring ? try gross.adding(basisEffect).adding(fee) : try gross.subtracting(basisEffect).subtracting(fee)
        // Bridge the already-booked option amount exactly once. Option realization is zero.
        try realize(event, consumed: consumed, total: optionBasis, side: s.side, kind: .settlement, forceZero: true)
        let allocations = try LedgerAllocation.allocate(aggregate, weights: s.contract.deliverables.map { ($0.security.id, $0.basisWeight) })
        if acquiring {
            guard s.equitySelections.isEmpty, Set(s.acquiredLotIDs.keys) == Set(s.contract.deliverables.map { $0.security.id }) else { throw LedgerError.invalidLotSelection }
            for delivery in s.contract.deliverables {
                guard let id = s.acquiredLotIDs[delivery.security.id], let cost = allocations[delivery.security.id] else { throw LedgerError.invalidLotSelection }
                let quantity = try delivery.quantity.multiplied(by: s.quantity.decimalString)
                try ledgerPositiveQuantity(quantity)
                let strategies = consumed.compactMap { $0.lot.strategy }
                // A mixed-strategy bridge needs an explicit allocation; do not silently combine purposes.
                guard Set(strategies.map(\.id)).count <= 1 else { throw LedgerError.invalidStrategy }
                try createLot(id: id, event: event, instrument: .equity(delivery.security), side: .long,
                              quantity: quantity, cost: cost, strategy: strategies.first, origins: consumed.map { $0.lot.id }, adjustments: [event.id])
            }
        } else {
            guard s.acquiredLotIDs.isEmpty else { throw LedgerError.invalidLotSelection }
            var used = Set<String>()
            for delivery in s.contract.deliverables {
                guard let proceeds = allocations[delivery.security.id] else { throw LedgerError.arithmeticInvariant }
                let quantity = try delivery.quantity.multiplied(by: s.quantity.decimalString)
                let selections = s.equitySelections.filter { choice in
                    state.lots.contains { $0.id == choice.lotID && $0.instrument == .equity(delivery.security) }
                }
                used.formUnion(selections.map(\.lotID))
                let stocks = try consume(accountID: event.accountID, instrument: .equity(delivery.security), side: .long, quantity: quantity, selections: selections)
                try realize(event, consumed: stocks, total: proceeds, side: .long, kind: .settlement)
            }
            guard used == Set(s.equitySelections.map(\.lotID)) else { throw LedgerError.invalidLotSelection }
        }
        let cash = acquiring ? try gross.adding(fee).multiplied(by: "-1") : try gross.subtracting(fee)
        try post(event, cash: cash, gross: acquiring ? gross.multiplied(by: "-1") : gross, fee: fee)
    }

    mutating func split(_ event: LedgerEvent, _ split: LedgerSplit) throws {
        try LedgerValidation.evidence(split.evidence, split.confirmedBy)
        let indices = state.lots.indices.filter {
            guard state.lots[$0].accountID == event.accountID, !state.lots[$0].isClosed,
                  case .equity(let s) = state.lots[$0].instrument else { return false }
            return s.id == split.securityID
        }
        guard !indices.isEmpty else { throw LedgerError.invalidCorporateAction }
        var fractions = Dictionary(uniqueKeysWithValues: split.fractions.map { ($0.lotID, $0) }), cash = zero
        for index in indices {
            let old = state.lots[index], adjusted = try old.quantityRemaining.multiplied(by: split.ratio.decimalString)
            try ledgerPositiveQuantity(adjusted)
            state.lots[index].quantityRemaining = adjusted; state.lots[index].adjustmentEventIDs.append(event.id)
            if let fraction = fractions.removeValue(forKey: old.id) {
                guard fraction.quantityDisposed < (try Money("1")), fraction.quantityDisposed <= adjusted else { throw LedgerError.invalidCorporateAction }
                let disposed = try consume(accountID: event.accountID, instrument: old.instrument, side: old.side,
                                           quantity: fraction.quantityDisposed, selections: [LedgerLotSelection(lotID: old.id, quantity: fraction.quantityDisposed)])
                try realize(event, consumed: disposed, total: fraction.cash, side: old.side, kind: .cashInLieu)
                cash = try cash.adding(fraction.cash.posted())
            }
        }
        guard fractions.isEmpty else { throw LedgerError.invalidCorporateAction }
        try post(event, cash: cash, gross: cash); corporateEvents.insert(event.id)
    }
    mutating func reorganize(_ event: LedgerEvent, _ reorganization: LedgerReorganization) throws {
        var totalCash = zero
        for row in reorganization.rows {
            guard let index = state.lots.firstIndex(where: { $0.id == row.sourceLotID && $0.accountID == event.accountID && !$0.isClosed }),
                  case .equity = state.lots[index].instrument, state.lots[index].side == .long else { throw LedgerError.invalidCorporateAction }
            let old = state.lots[index]
            // The confirmed cash component follows ascending lot IDs and receives the final cent remainder.
            let cashKey = "\u{10FFFF}cash"
            guard !row.outputs.contains(where: { $0.lotID == cashKey }) else { throw LedgerError.invalidCorporateAction }
            var weights = row.outputs.map { ($0.lotID, $0.basisWeight) }
            if let cashWeight = row.cashBasisWeight { weights.append((cashKey, cashWeight)) }
            let allocation = try LedgerAllocation.allocate(old.managementCostRemaining, weights: weights)
            if let cash = row.netCashConsideration {
                guard let cost = allocation[cashKey] else { throw LedgerError.arithmeticInvariant }
                let net = try cash.posted(); totalCash = try totalCash.adding(net)
                state.realizations.append(LedgerRealization(eventID: event.id, lotID: old.id, quantity: old.quantityRemaining,
                    removedManagementCost: cost, netProceedsOrCloseCost: net, pnl: try net.subtracting(cost), kind: .settlement))
            }
            state.lots[index].quantityRemaining = zero; state.lots[index].managementCostRemaining = zero
            for output in row.outputs {
                guard let cost = allocation[output.lotID] else { throw LedgerError.arithmeticInvariant }
                try createLot(id: output.lotID, event: event, instrument: .equity(output.security), side: .long,
                              quantity: output.quantity, cost: cost, acquiredAt: old.acquiredAt, strategy: old.strategy,
                              origins: old.originatingOptionLotIDs, adjustments: old.adjustmentEventIDs + [event.id])
            }
        }
        try post(event, cash: totalCash, gross: totalCash); corporateEvents.insert(event.id)
    }
}

/// Exact rational allocation in cents. Earlier ascending IDs truncate toward zero;
/// the last receives the remainder. Partial disposal retains remainder in the open lot.
private enum LedgerAllocation {
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
