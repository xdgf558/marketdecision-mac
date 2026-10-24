import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine
import Persistence

public enum OptionTradeEntryAction: String, Equatable, Sendable {
    case opening, closing, expiration
}

public enum OptionTradeEntryError: Error, Equatable, LocalizedError {
    case syntheticEvidence, invalidContract, unconfirmedContract, missingExecution, duplicateExecutionID
    case invalidAccount, invalidLot, changedLot, invalidQuantity, changedLegs, inconsistentSnapshot

    public var errorDescription: String? {
        switch self {
        case .syntheticEvidence: "合成示例或带示例来源的记录不能作为实际成交入账。"
        case .invalidContract: "请核对同一标的、到期日、行权价和实际合约版本；标准合约需明确 100 股交割及有效时刻。"
        case .unconfirmedContract: "请先明确核对实际合约条款与依据，试算的到期假设不会自动成为成交证据。"
        case .missingExecution: "请填写实际成交或到期时刻、来源系统、唯一成交编号、记录依据，以及实际价格和费用。"
        case .duplicateExecutionID: "多腿成交须分别填写各腿不同的真实成交编号，不能用同一个订单编号代替。"
        case .invalidAccount: "请使用当前账本中的同一账户。"
        case .invalidLot: "请选择仍未结束的期权持仓批次。"
        case .changedLot: "持仓批次已变化，请重新选择；原草稿不会自动改用新的数量或合约。"
        case .invalidQuantity: "实际张数须为正整数，且不能超过所选批次的剩余张数。"
        case .changedLegs: "成交腿与原草稿不一致，请重新发起成交记录。"
        case .inconsistentSnapshot: "账本快照未通过重放核对，不能准备成交。"
        }
    }
}

/// Editable execution and contract fields use the existing ledger form. Fields
/// controlling identity, account, side, effect and selected lots are derived by
/// OptionTradeEntryDraft and cannot be changed by mutating this nested form.
public struct OptionTradeEntryLegDraft: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public var form: LedgerManualDraft
    public var contractConfirmed = false
    private var reusedContract: LedgerOptionVersion?
    fileprivate let side: LedgerSide
    fileprivate let expectedOCC: String
    fileprivate let expectedSymbol: String
    fileprivate let expectedKind: LedgerSecurityKind
    fileprivate let expectedConsideration: Money

    fileprivate init(label: String, form: LedgerManualDraft, side: LedgerSide,
                     expectedOCC: String, expectedSymbol: String,
                     expectedKind: LedgerSecurityKind, expectedConsideration: Money) {
        id = UUID().uuidString; self.label = label; self.form = form; self.side = side
        self.expectedOCC = expectedOCC; self.expectedSymbol = expectedSymbol
        self.expectedKind = expectedKind; self.expectedConsideration = expectedConsideration
    }

    /// Selecting a retained complete contract is explicit. The account-specific
    /// provenance is checked again against the supplied ledger at preparation.
    public mutating func reuseContract(_ contract: LedgerOptionVersion) throws {
        try contract.validate()
        try optionTradeRejectSynthetic(contract)
        try validateOpeningContract(contract)
        reusedContract = contract; form.existingOption = contract; contractConfirmed = true
    }

    public mutating func enterContractManually() {
        reusedContract = nil; form.existingOption = nil; contractConfirmed = false
    }

    fileprivate func validateOpeningContract(_ contract: LedgerOptionVersion) throws {
        guard contract.occSymbol == expectedOCC, contract.quoteMultiplier == (try Money("100")),
              contract.exerciseConsideration == expectedConsideration,
              contract.deliverableCash == (try Money("0")), contract.deliverables.count == 1,
              let delivery = contract.deliverables.first,
              delivery.security.symbol == expectedSymbol, delivery.security.kind == expectedKind,
              delivery.quantity == (try Money("100")), delivery.basisWeight == (try Money("1")) else {
            throw OptionTradeEntryError.invalidContract
        }
    }

    fileprivate func verifiedReuse() throws -> LedgerOptionVersion? {
        guard form.existingOption == reusedContract else { throw OptionTradeEntryError.unconfirmedContract }
        return reusedContract
    }
}

/// A user-confirmed execution is separate from an option research snapshot. No
/// quote, estimated fill, fee assumption, capital value or payoff is imported.
/// This draft only prepares events; LedgerStorage retains preview/commit, CAS,
/// deduplication, transactional replay and corrections as the sole write path.
public struct OptionTradeEntryDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let action: OptionTradeEntryAction
    public var accountID: String
    public var timestamp = ""
    public var sourceSystem = ""
    public var externalID = ""
    public var evidence = ""
    public var notes = ""
    public var strategyPurpose: LedgerStrategyPurpose = .premiumIncome
    public var strategySuccessDefinition = "扣除实际费用后的已实现盈亏为正"
    public var strategyMaximumAcquisitionPrice = ""
    public var strategyUnassignedCountsAsSuccess = false
    public var legs: [OptionTradeEntryLegDraft]
    private let originalLegIDs: [String]
    private let originalLot: LedgerLot?

    public init(openingFrom draft: OptionLabInputDraft) throws {
        guard draft.origin == .manual, draft.chainEvidence?.capture.synthetic != true else {
            throw OptionTradeEntryError.syntheticEvidence
        }
        try optionTradeRejectSynthetic([draft.sourceReference, draft.expiryReference,
            draft.shortLeg.sourceReference, draft.longLeg.sourceReference])
        let symbol = draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard symbol.range(of: "^[A-Z0-9]{1,6}$", options: .regularExpression) != nil else {
            throw OptionTradeEntryError.invalidContract
        }
        let expiry = try MarketDate(iso8601: draft.expirationDate)
        guard (2000...2099).contains(expiry.year) else { throw OptionTradeEntryError.invalidContract }
        let kind: LedgerSecurityKind = draft.asset == .stock ? .stock : .etf
        func leg(_ source: OptionLabLegDraft, side: LedgerSide) throws -> OptionTradeEntryLegDraft {
            guard source.multiplier == "100" else { throw OptionTradeEntryError.invalidContract }
            let strike = try Money(source.strike.trimmingCharacters(in: .whitespacesAndNewlines))
            let quantity = try optionTradeQuantity(source.quantity)
            let scaledStrike = try strike.multiplied(by: "1000")
            let digits = scaledStrike.decimalString
            guard strike.amount > 0, !digits.contains("."), digits.count <= 8 else { throw OptionTradeEntryError.invalidContract }
            let occ = symbol.padding(toLength: 6, withPad: " ", startingAt: 0)
                + String(format: "%02d%02d%02d", expiry.year - 2000, expiry.month, expiry.day)
                + (draft.right == .put ? "P" : "C") + String(repeating: "0", count: 8 - digits.count) + digits
            var form = LedgerManualDraft()
            form.kind = .optionTrade; form.side = side; form.effect = .open
            form.occSymbol = occ; form.symbol = symbol; form.securityKind = kind
            form.quantity = quantity.decimalString; form.quoteMultiplier = "100"
            form.exerciseConsideration = try strike.multiplied(by: "100").decimalString
            form.deliverableQuantity = "100"; form.deliverableCash = "0"
            form.strategyEnabled = true
            // This source form's manual defaults are intentionally blank here.
            // In particular there is no actual execution time, fee or price.
            form.sourceSystem = ""
            return try .init(label: side == .sell ? "卖出开仓" : "买入开仓", form: form, side: side,
                expectedOCC: occ, expectedSymbol: symbol, expectedKind: kind,
                expectedConsideration: strike.multiplied(by: "100"))
        }
        var prepared = [try leg(draft.shortLeg, side: .sell)]
        if draft.hasLongLeg { prepared.append(try leg(draft.longLeg, side: .buy)) }
        guard Set(prepared.map(\.expectedOCC)).count == prepared.count else { throw OptionTradeEntryError.invalidContract }
        id = UUID(); action = .opening; accountID = ""; legs = prepared
        originalLegIDs = prepared.map(\.id); originalLot = nil
    }

    public init(lot: LedgerLot, action: OptionTradeEntryAction) throws {
        guard action == .closing || action == .expiration,
              case .option(let contract) = lot.instrument, !lot.isClosed else { throw OptionTradeEntryError.invalidLot }
        try contract.validate(); try optionTradeRejectSynthetic(lot)
        var form = LedgerManualDraft()
        form.kind = action == .closing ? .optionTrade : .optionSettlement
        form.existingOption = contract; form.quantity = lot.quantityRemaining.decimalString
        form.side = lot.side == .short ? .buy : .sell; form.effect = .close
        form.positionSide = lot.side; form.settlementAction = .expiration
        form.sourceSystem = ""; form.lots = [lot.id: lot.quantityRemaining.decimalString]
        guard let delivery = contract.deliverables.first else { throw OptionTradeEntryError.invalidContract }
        var leg = OptionTradeEntryLegDraft(label: action == .closing ? "平仓" : "到期未行权", form: form,
            side: form.side, expectedOCC: contract.occSymbol, expectedSymbol: delivery.security.symbol,
            expectedKind: delivery.security.kind, expectedConsideration: contract.exerciseConsideration)
        leg.contractConfirmed = true
        id = UUID(); self.action = action; accountID = lot.accountID; legs = [leg]
        originalLegIDs = [leg.id]; originalLot = lot
    }

    /// The sole public event-building path requires the verified account ledger.
    /// Original broker execution IDs are preserved, including across CSV/manual
    /// entry paths. Each leg of a multi-leg fill supplies its own real execution
    /// ID; no synthetic suffix is appended to a broker's transaction identity.
    public func events(in snapshot: LedgerSnapshot) throws -> [LedgerEvent] {
        guard legs.map(\.id) == originalLegIDs else { throw OptionTradeEntryError.changedLegs }
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }) else { throw OptionTradeEntryError.invalidAccount }
        guard try LedgerEngine.replay(accounts: snapshot.accounts, events: snapshot.events) == snapshot.state else {
            throw OptionTradeEntryError.inconsistentSnapshot
        }
        try optionTradeRejectSynthetic(account)
        let executionIDs = legs.count == 1 ? [externalID] : legs.map { $0.form.externalID }
        guard !optionTradeBlank(timestamp), !optionTradeBlank(sourceSystem), executionIDs.allSatisfy({ !optionTradeBlank($0) }),
              !optionTradeBlank(evidence) else { throw OptionTradeEntryError.missingExecution }
        guard Set(executionIDs).count == executionIDs.count else { throw OptionTradeEntryError.duplicateExecutionID }
        try optionTradeRejectSynthetic([sourceSystem, evidence, notes] + executionIDs)
        let instant = try LedgerCSV.timestamp(timestamp)
        if let originalLot {
            guard originalLot.accountID == accountID else { throw OptionTradeEntryError.invalidAccount }
            guard snapshot.state.lots.first(where: { $0.id == originalLot.id }) == originalLot else { throw OptionTradeEntryError.changedLot }
            try validateLotProvenance(originalLot, in: snapshot)
        }
        let groupID = "option-entry-group.v1:" + optionTradeIdentity([accountID, sourceSystem] + executionIDs)
        var result: [LedgerEvent] = []
        for (index, leg) in legs.enumerated() {
            let quantity = try optionTradeQuantity(leg.form.quantity)
            guard !optionTradeBlank(leg.form.fee), action == .expiration || !optionTradeBlank(leg.form.unitPrice) else {
                throw OptionTradeEntryError.missingExecution
            }
            let externalLegID = executionIDs[index]
            let eventID = "option-entry-event.v1:" + optionTradeIdentity([accountID, sourceSystem, externalLegID])
            var form = leg.form
            form.id = eventID; form.timestamp = timestamp; form.sourceSystem = sourceSystem
            form.externalID = externalLegID; form.evidence = evidence; form.notes = notes
            form.rollGroupID = ""; form.multiLegGroupID = legs.count > 1 ? groupID : ""
            let event: LedgerEvent
            if action == .opening {
                guard leg.contractConfirmed else { throw OptionTradeEntryError.unconfirmedContract }
                if let reused = try leg.verifiedReuse() {
                    guard let matching = snapshot.state.lots.first(where: {
                        $0.accountID == accountID && $0.instrument == .option(reused)
                    }) else { throw OptionTradeEntryError.invalidContract }
                    try validateLotProvenance(matching, in: snapshot)
                }
                form.kind = .optionTrade; form.side = leg.side; form.effect = .open
                form.openingLotID = eventID + ":lot"; form.lots = [:]
                form.strategyEnabled = true; form.strategyID = groupID + ":strategy"
                form.purpose = strategyPurpose; form.successDefinition = strategySuccessDefinition
                form.maximumAcquisitionPrice = strategyMaximumAcquisitionPrice
                form.unassignedCountsAsSuccess = strategyUnassignedCountsAsSuccess
                event = try form.event(accountID: accountID)
                guard case .trade(let trade) = event.payload, case .option(let contract) = trade.instrument else {
                    throw OptionTradeEntryError.invalidContract
                }
                try leg.validateOpeningContract(contract)
                try optionTradeRejectSynthetic(contract)
            } else {
                guard let lot = originalLot, quantity <= lot.quantityRemaining,
                      case .option(let contract) = lot.instrument, form.existingOption == contract else {
                    throw OptionTradeEntryError.invalidQuantity
                }
                form.strategyEnabled = false; form.kind = .optionTrade; form.effect = .close
                form.side = lot.side == .short ? .buy : .sell; form.openingLotID = ""
                form.lots = [lot.id: quantity.decimalString]
                if action == .closing { event = try form.event(accountID: accountID) }
                else {
                    let sequence: Int?
                    if form.sequence.isEmpty { sequence = nil }
                    else {
                        guard let value = Int(form.sequence), value >= 0 else { throw LedgerError.ambiguousOrdering }
                        sequence = value
                    }
                    event = LedgerEvent(id: eventID, accountID: accountID, effectiveAt: instant, providerSequence: sequence,
                        source: .init(sourceSystem: sourceSystem, externalTransactionID: externalLegID, evidence: evidence),
                        payload: .optionSettlement(.init(contract: contract, action: .expiration, side: lot.side,
                            quantity: quantity, fee: try Money(form.fee.trimmingCharacters(in: .whitespacesAndNewlines)),
                            optionSelections: [.init(lotID: lot.id, quantity: quantity)], evidence: evidence)), notes: notes)
                    try event.validate()
                }
            }
            try optionTradeRejectSynthetic(event)
            result.append(event)
        }
        if action == .opening, result.count > 1 {
            let strategies = result.compactMap { event -> LedgerStrategy? in
                if case .trade(let trade) = event.payload { return trade.strategy }; return nil
            }
            guard strategies.count == result.count, strategies.allSatisfy({ $0 == strategies.first }) else { throw LedgerError.invalidStrategy }
        }
        return result
    }

    private func validateLotProvenance(_ lot: LedgerLot, in snapshot: LedgerSnapshot) throws {
        let ids = [lot.openEventID] + lot.adjustmentEventIDs
        for id in ids {
            guard let event = snapshot.events.first(where: { $0.id == id && $0.accountID == accountID }),
                  snapshot.state.activeEventIDs.contains(id) else { throw OptionTradeEntryError.invalidLot }
            try optionTradeRejectSynthetic(event)
        }
        try optionTradeRejectSynthetic(lot)
    }
}

private func optionTradeQuantity(_ text: String) throws -> Money {
    let quantity = try Money(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard quantity.amount > 0, !quantity.decimalString.contains(".") else { throw OptionTradeEntryError.invalidQuantity }
    return quantity
}
private func optionTradeBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
private func optionTradeFramed(_ fields: [String]) -> String { fields.map { "\($0.utf8.count):\($0)" }.joined() }
private func optionTradeIdentity(_ fields: [String]) -> String { LedgerCSV.hash(Data(optionTradeFramed(fields).utf8)) }

/// This is a conservative exclusion of declared synthetic provenance, following
/// the ledger's personal-history boundary. It does not authenticate a broker.
private func optionTradeRejectSynthetic<T: Encodable>(_ value: T) throws {
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    func containsMarker(_ value: Any) -> Bool {
        if let text = value as? String {
            return text.lowercased().contains("synthetic") || text.contains("合成")
                || text.range(of: "(^|[^a-z0-9])demo([^a-z0-9]|$)", options: [.regularExpression, .caseInsensitive]) != nil
        }
        if let values = value as? [Any] { return values.contains(where: containsMarker) }
        if let values = value as? [String: Any] { return values.values.contains(where: containsMarker) }
        return false
    }
    guard !containsMarker(json) else { throw OptionTradeEntryError.syntheticEvidence }
}
