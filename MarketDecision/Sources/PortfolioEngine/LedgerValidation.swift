import Foundation
import CoreDomain

enum LedgerValidation {
    static func nonnegative(_ value: Money) throws { guard value.amount >= 0 else { throw LedgerError.invalidAmount } }
    static func selections(_ values: [LedgerLotSelection]) throws {
        guard Set(values.map(\.lotID)).count == values.count else { throw LedgerError.invalidLotSelection }
        for value in values { guard ledgerText(value.lotID) else { throw LedgerError.invalidLotSelection }; try ledgerPositiveQuantity(value.quantity) }
    }
    static func evidence(_ value: String, _ confirmedBy: String? = nil) throws {
        guard ledgerText(value), confirmedBy.map(ledgerText) ?? true else { throw LedgerError.invalidEvidence }
    }
    static func quantity(_ quantity: Money, for instrument: LedgerInstrument) throws {
        if case .option = instrument { try ledgerPositiveQuantity(quantity, integral: true) }
        else { try ledgerPositiveQuantity(quantity) }
    }
    static func payload(_ value: LedgerPayload, at: Date) throws {
        switch value {
        case .cash(let cash):
            guard cash.amount.amount > 0, cash.securityID.map(ledgerText) ?? true else { throw LedgerError.invalidAmount }
        case .trade(let trade):
            try trade.instrument.validate(); try quantity(trade.quantity, for: trade.instrument)
            try nonnegative(trade.unitPrice); try nonnegative(trade.fee); try selections(trade.selections)
            guard try trade.unitPrice.rounded(to: .unitPrice) == trade.unitPrice else { throw LedgerError.invalidAmount }
            try trade.strategy?.validate()
            guard trade.effect == .open ? (trade.openingLotID.map(ledgerText) == true && trade.selections.isEmpty) : trade.openingLotID == nil else {
                throw LedgerError.invalidLotSelection
            }
            switch trade.instrument {
            case .equity:
                guard (trade.effect == .open && trade.side == .buy) || (trade.effect == .close && trade.side == .sell) else { throw LedgerError.unsupportedSettlement }
            case .option(let version):
                guard trade.effect != .open || trade.strategy != nil else { throw LedgerError.invalidContract }
                if version.isLocalManualStandard {
                    guard version.allowsLocalManualTrade(at: at) else { throw LedgerError.invalidContract }
                } else {
                    guard let effectiveFrom = version.effectiveFrom, let tradingEndsAt = version.tradingEndsAt,
                          at >= effectiveFrom, version.effectiveTo.map({ at < $0 }) ?? true,
                          at <= tradingEndsAt else { throw LedgerError.invalidContract }
                }
            }
        case .optionSettlement(let s):
            try s.contract.validate(); try ledgerPositiveQuantity(s.quantity, integral: true); try nonnegative(s.fee)
            try selections(s.optionSelections); try selections(s.equitySelections); try evidence(s.evidence)
            guard s.acquiredLotIDs.values.allSatisfy(ledgerText),
                  Set(s.acquiredLotIDs.values).count == s.acquiredLotIDs.count else {
                throw LedgerError.invalidContract
            }
            if s.contract.isLocalManualStandard {
                // A recorded zero settlement is a user-reported event. No
                // official exercise deadline or delivery schedule is inferred.
                guard s.action == .expiration, s.contract.allowsLocalManualExpiration(at: at),
                      s.equitySelections.isEmpty, s.acquiredLotIDs.isEmpty else { throw LedgerError.invalidContract }
            } else {
                guard let effectiveFrom = s.contract.effectiveFrom, let exerciseDeadline = s.contract.exerciseDeadline,
                      at >= effectiveFrom, s.contract.effectiveTo.map({ at < $0 }) ?? true else { throw LedgerError.invalidContract }
                if s.action == .expiration {
                    guard at >= exerciseDeadline, s.equitySelections.isEmpty, s.acquiredLotIDs.isEmpty else { throw LedgerError.invalidContract }
                } else {
                    guard (s.action == .assignment && s.side == .short) || (s.action == .exercise && s.side == .long),
                          at <= exerciseDeadline else { throw LedgerError.invalidContract }
                    if s.contract.exerciseStyle == .european {
                        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
                        guard calendar.isDate(at, inSameDayAs: exerciseDeadline) else { throw LedgerError.invalidContract }
                    }
                }
            }
        case .split(let s):
            guard ledgerText(s.securityID), s.ratio.amount > 0, Set(s.fractions.map(\.lotID)).count == s.fractions.count else { throw LedgerError.invalidCorporateAction }
            try evidence(s.evidence, s.confirmedBy)
            for fraction in s.fractions { try ledgerPositiveQuantity(fraction.quantityDisposed); try nonnegative(fraction.cash) }
        case .reorganization(let r):
            try evidence(r.evidence, r.confirmedBy)
            guard !r.rows.isEmpty, Set(r.rows.map(\.sourceLotID)).count == r.rows.count else { throw LedgerError.invalidCorporateAction }
            var ids = Set<String>()
            for row in r.rows {
                guard ledgerText(row.sourceLotID), !row.outputs.isEmpty || (r.kind == .merger && row.netCashConsideration != nil) else { throw LedgerError.invalidCorporateAction }
                guard (row.netCashConsideration == nil) == (row.cashBasisWeight == nil),
                      row.netCashConsideration.map({ $0.amount >= 0 }) ?? true,
                      row.cashBasisWeight.map({ $0.amount >= 0 }) ?? true else { throw LedgerError.invalidCorporateAction }
                var sum = try Money("0")
                if let cashWeight = row.cashBasisWeight { sum = cashWeight }
                for out in row.outputs {
                    guard ledgerText(out.lotID), ids.insert(out.lotID).inserted, out.basisWeight.amount >= 0 else { throw LedgerError.invalidCorporateAction }
                    try out.security.validate(); try ledgerPositiveQuantity(out.quantity); sum = try sum.adding(out.basisWeight)
                }
                guard sum == (try Money("1")) else { throw LedgerError.invalidCorporateAction }
            }
        case .returnOfCapital(let r):
            try evidence(r.evidence, r.confirmedBy)
            guard !r.allocations.isEmpty, r.allocations.keys.allSatisfy(ledgerText), r.allocations.values.allSatisfy({ $0.amount > 0 }) else { throw LedgerError.invalidCorporateAction }
        case .cashInLieu(let cash):
            try selections(cash.selections); try nonnegative(cash.cash); try nonnegative(cash.fee); try evidence(cash.evidence)
            guard !cash.selections.isEmpty, ledgerText(cash.corporateActionEventID) else { throw LedgerError.invalidCorporateAction }
        case .transferIn(let t):
            try t.instrument.validate(); try quantity(t.quantity, for: t.instrument); try nonnegative(t.eventMarketValue); try evidence(t.evidence)
            try t.strategy?.validate()
            guard ledgerText(t.lotID), ledgerDate(t.acquiredAt), t.acquiredAt <= at,
                  t.userReportedTaxBasis.map({ $0.amount >= 0 }) ?? true else { throw LedgerError.invalidEvidence }
            if case .equity = t.instrument, t.side != .long { throw LedgerError.unsupportedSettlement }
            if case .option(let option) = t.instrument {
                guard t.strategy != nil else { throw LedgerError.invalidStrategy }
                guard !option.isLocalManualStandard, let effectiveFrom = option.effectiveFrom,
                      let exerciseDeadline = option.exerciseDeadline,
                      at >= effectiveFrom, option.effectiveTo.map({ at < $0 }) ?? true,
                      at < exerciseDeadline else { throw LedgerError.invalidContract }
            }
        case .transferOut(let t):
            try t.instrument.validate(); try quantity(t.quantity, for: t.instrument)
            try selections(t.selections); try nonnegative(t.eventMarketValue); try evidence(t.evidence)
        case .contractAdjustment(let a):
            try a.previous.validate(); try a.replacement.validate(); try evidence(a.evidence, a.confirmedBy)
            guard !a.previous.isLocalManualStandard, !a.replacement.isLocalManualStandard,
                  let effectiveFrom = a.replacement.effectiveFrom,
                  a.previous.identity != a.replacement.identity, a.contractQuantityRatio.amount > 0,
                  at >= effectiveFrom, a.replacement.effectiveTo.map({ at < $0 }) ?? true else { throw LedgerError.invalidCorporateAction }
        case .reversal(let reversal):
            guard ledgerText(reversal.originalEventID), ledgerText(reversal.reason) else { throw LedgerError.invalidReversal }
        }
    }
}
