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
    case syntheticEvidence, invalidContract, unconfirmedContract, ambiguousContract, missingExecution, duplicateExecutionID
    case invalidAccount, invalidLot, changedLot, invalidQuantity, changedLegs, inconsistentSnapshot

    public var errorDescription: String? {
        switch self {
        case .syntheticEvidence: "合成示例或带示例来源的记录不能作为实际成交入账。"
        case .invalidContract: "合约与当前记录不一致，或成交日期超出合约日期范围。日常开仓仅支持每张 100 股的标准股票／ETF 期权。"
        case .unconfirmedContract: "请先明确核对实际合约条款与依据，试算的到期假设不会自动成为成交证据。"
        case .ambiguousContract: "账户中有同一合约的不同版本，暂时不能自动选用；请在高级账本核对原记录。"
        case .missingExecution: "请补齐本次成交或到期结清的必填信息；开仓的来源、编号和记录依据可留空。"
        case .duplicateExecutionID: "已填写的各腿成交编号不能重复；开仓可留空由软件编号，不要用同一个订单编号代替。"
        case .invalidAccount: "请使用当前账本中的同一账户。"
        case .invalidLot: "请选择仍未结束的期权持仓批次。"
        case .changedLot: "持仓批次已变化，请重新选择；原草稿不会自动改用新的数量或合约。"
        case .invalidQuantity: "实际总张数与各批次平仓张数须为正整数，分配合计须一致，且不能超过各批次的剩余张数。"
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

/// A user-confirmed execution is separate from an option research snapshot.
/// Initialization imports no quote, estimated fill, fee, capital value or payoff.
/// A separate explicit action may copy manually entered reference unit prices;
/// actual execution confirmation and ledger preview/commit remain mandatory.
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
    /// Frozen compatible lots, never refreshed to a later ledger revision.
    public let closingCandidates: [LedgerLot]
    /// Keys explicitly select lots. With one selection the actual total quantity
    /// is used; with several selections each allocation must sum to that total.
    public var closingAllocations: [String: String]
    private let originalLegIDs: [String]
    private let originalLot: LedgerLot?
    private let automaticContractTerms: Bool

    public init(openingFrom draft: OptionLabInputDraft, automaticContractTerms: Bool = false) throws {
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
        self.automaticContractTerms = automaticContractTerms
        closingCandidates = []; closingAllocations = [:]
        originalLegIDs = prepared.map(\.id); originalLot = nil
    }

    /// Called only by the user's explicit "use reference price" action. Rebuild
    /// the source proposal to validate its origin and immutable contract identity;
    /// new proposal UUIDs are not used as identity comparisons. Quote-mode data,
    /// Bid/Ask, midpoints, fees and execution/source fields are never substituted.
    public mutating func applyOpeningReferencePrices(from source: OptionLabInputDraft) throws {
        guard action == .opening, legs.map(\.id) == originalLegIDs else {
            throw OptionTradeEntryError.changedLegs
        }
        let reference = try OptionTradeEntryDraft(openingFrom: source)
        guard source.usesEnteredPrices else { throw OptionTradeEntryError.missingExecution }
        guard reference.legs.count == legs.count else { throw OptionTradeEntryError.changedLegs }
        for (original, proposed) in zip(legs, reference.legs) {
            guard original.side == proposed.side,
                  original.expectedOCC == proposed.expectedOCC,
                  original.expectedSymbol == proposed.expectedSymbol,
                  original.expectedKind == proposed.expectedKind,
                  original.expectedConsideration == proposed.expectedConsideration else {
                throw OptionTradeEntryError.invalidContract
            }
        }
        let texts = [source.shortLeg.enteredPrice] + (source.hasLongLeg ? [source.longLeg.enteredPrice] : [])
        let prices = try texts.map { text -> String in
            guard let price = try? Money(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  price.amount >= 0 else { throw OptionTradeEntryError.missingExecution }
            return price.decimalString
        }
        // Validate every leg before touching the existing draft. Its IDs,
        // contract confirmation, quantities and actual evidence remain intact.
        var updated = legs
        for index in updated.indices { updated[index].form.unitPrice = prices[index] }
        legs = updated
    }

    public init(lot: LedgerLot, action: OptionTradeEntryAction, otherClosingLots: [LedgerLot] = []) throws {
        guard action == .closing || action == .expiration,
              case .option(let contract) = lot.instrument, !lot.isClosed else { throw OptionTradeEntryError.invalidLot }
        guard action == .closing || otherClosingLots.isEmpty else { throw OptionTradeEntryError.invalidLot }
        let candidates = [lot] + otherClosingLots
        guard Set(candidates.map(\.id)).count == candidates.count,
              candidates.allSatisfy({ $0.accountID == lot.accountID && $0.instrument == lot.instrument
                  && $0.side == lot.side && !$0.isClosed }) else { throw OptionTradeEntryError.invalidLot }
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
        automaticContractTerms = false
        closingCandidates = action == .closing ? candidates.sorted {
            $0.acquiredAt == $1.acquiredAt ? $0.id < $1.id : $0.acquiredAt < $1.acquiredAt
        } : []
        closingAllocations = action == .closing ? [lot.id: lot.quantityRemaining.decimalString] : [:]
        originalLegIDs = [leg.id]; originalLot = lot
    }

    /// The sole public event-building path requires the verified account ledger.
    /// Original broker execution IDs are preserved, including across CSV/manual
    /// entry paths. Opening metadata is optional: absent identifiers are local
    /// record identities, stable for this draft and leg, never broker evidence.
    /// A new draft without broker identifiers cannot identify the same real fill.
    /// Closing/expiration metadata and the ledger's source contract stay strict.
    public func events(in snapshot: LedgerSnapshot) throws -> [LedgerEvent] {
        guard legs.map(\.id) == originalLegIDs else { throw OptionTradeEntryError.changedLegs }
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }) else { throw OptionTradeEntryError.invalidAccount }
        guard try LedgerEngine.replay(accounts: snapshot.accounts, events: snapshot.events) == snapshot.state else {
            throw OptionTradeEntryError.inconsistentSnapshot
        }
        try optionTradeRejectSynthetic(account)
        let suppliedIDs = legs.count == 1 ? [externalID] : legs.map { $0.form.externalID }
        let recordedSource = action == .opening && optionTradeBlank(sourceSystem)
            ? "local-manual-option-opening.v1" : sourceSystem
        let recordedEvidence = action == .opening && optionTradeBlank(evidence)
            ? "用户手工录入开仓；未提供附加记录依据。" : evidence
        let executionIDs = suppliedIDs.enumerated().map { index, supplied in
            action == .opening && optionTradeBlank(supplied)
                ? "local-option-opening.v1:" + id.uuidString + ":" + legs[index].id : supplied
        }
        guard !optionTradeBlank(timestamp), !optionTradeBlank(recordedSource), executionIDs.allSatisfy({ !optionTradeBlank($0) }),
              !optionTradeBlank(recordedEvidence) else { throw OptionTradeEntryError.missingExecution }
        guard Set(executionIDs).count == executionIDs.count else { throw OptionTradeEntryError.duplicateExecutionID }
        try optionTradeRejectSynthetic([recordedSource, recordedEvidence, notes] + executionIDs)
        let instant = try LedgerCSV.timestamp(timestamp)
        if let originalLot {
            guard originalLot.accountID == accountID else { throw OptionTradeEntryError.invalidAccount }
            if action == .expiration {
                guard snapshot.state.lots.first(where: { $0.id == originalLot.id }) == originalLot else { throw OptionTradeEntryError.changedLot }
                try validateLotProvenance(originalLot, in: snapshot)
            }
        }
        let groupID = "option-entry-group.v1:" + optionTradeIdentity([accountID, recordedSource] + executionIDs)
        var result: [LedgerEvent] = []
        for (index, leg) in legs.enumerated() {
            let quantity = try optionTradeQuantity(leg.form.quantity)
            guard !optionTradeBlank(leg.form.fee), action == .expiration || !optionTradeBlank(leg.form.unitPrice) else {
                throw OptionTradeEntryError.missingExecution
            }
            let externalLegID = executionIDs[index]
            let eventID = "option-entry-event.v1:" + optionTradeIdentity([accountID, recordedSource, externalLegID])
            var form = leg.form
            form.id = eventID; form.timestamp = timestamp; form.sourceSystem = recordedSource
            form.externalID = externalLegID; form.evidence = recordedEvidence; form.notes = notes
            if action == .opening, optionTradeBlank(suppliedIDs[index]) {
                form.evidence += "内部记录编号由软件生成，非券商成交编号。"
            }
            form.rollGroupID = ""; form.multiLegGroupID = legs.count > 1 ? groupID : ""
            let event: LedgerEvent
            if action == .opening {
                if automaticContractTerms {
                    form.existingOption = try automaticContract(for: leg, in: snapshot)
                } else {
                    guard leg.contractConfirmed else { throw OptionTradeEntryError.unconfirmedContract }
                    if let reused = try leg.verifiedReuse() {
                        guard let matching = snapshot.state.lots.first(where: {
                            $0.accountID == accountID && $0.instrument == .option(reused)
                        }) else { throw OptionTradeEntryError.invalidContract }
                        try validateLotProvenance(matching, in: snapshot)
                    }
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
                guard let lot = originalLot,
                      case .option(let contract) = lot.instrument, form.existingOption == contract else {
                    throw OptionTradeEntryError.invalidQuantity
                }
                form.strategyEnabled = false; form.kind = .optionTrade; form.effect = .close
                form.side = lot.side == .short ? .buy : .sell; form.openingLotID = ""
                if action == .closing {
                    form.lots = try closingSelections(quantity: quantity, in: snapshot)
                    event = try form.event(accountID: accountID)
                }
                else {
                    guard quantity <= lot.quantityRemaining else { throw OptionTradeEntryError.invalidQuantity }
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

    /// Resolve against the same validated account/revision used for the preview.
    /// A first manual record declares only the standard shape already selected
    /// in the calculator. It does not turn a research timestamp into an exchange
    /// deadline, listing date, settlement instruction or verified market evidence.
    private func automaticContract(for leg: OptionTradeEntryLegDraft, in snapshot: LedgerSnapshot) throws -> LedgerOptionVersion {
        let explicitReuse = try leg.verifiedReuse()
        var candidates: [LedgerOptionVersion] = []
        for lot in snapshot.state.lots where lot.accountID == accountID {
            guard case .option(let contract) = lot.instrument, contract.occSymbol == leg.expectedOCC else { continue }
            try validateLotProvenance(lot, in: snapshot)
            try leg.validateOpeningContract(contract)
            if !candidates.contains(contract) { candidates.append(contract) }
        }
        guard candidates.count <= 1 else { throw OptionTradeEntryError.ambiguousContract }
        if let explicitReuse, candidates.first != explicitReuse { throw OptionTradeEntryError.invalidContract }
        if let existing = candidates.first { return existing }
        let security = LedgerSecurity(id: "local-standard-equity.v1:" + leg.expectedKind.rawValue + ":" + leg.expectedSymbol,
            symbol: leg.expectedSymbol, kind: leg.expectedKind)
        let contract = LedgerOptionVersion(occSymbol: leg.expectedOCC, versionID: "local-manual-standard.v1", effectiveFrom: nil,
            quoteMultiplier: try Money("100"), exerciseConsideration: leg.expectedConsideration,
            deliverables: [.init(security: security, quantity: try Money("100"), basisWeight: try Money("1"))],
            deliverableCash: try Money("0"), tradingEndsAt: nil, exerciseDeadline: nil, settlementAt: nil,
            memoReferences: ["按用户填写的股票／ETF 标准合约参数记录，每张 100 股；未核实交易所截止时间、交割安排或调整条款。"],
            termsBasis: .localManualStandard)
        try contract.validate()
        return contract
    }

    private func closingSelections(quantity: Money, in snapshot: LedgerSnapshot) throws -> [String: String] {
        guard !closingAllocations.isEmpty else { throw OptionTradeEntryError.invalidLot }
        var selections: [String: String] = [:]
        var total = try Money("0")
        for id in closingAllocations.keys.sorted() {
            guard let lot = closingCandidates.first(where: { $0.id == id }),
                  let text = closingAllocations[id] else { throw OptionTradeEntryError.invalidLot }
            guard snapshot.state.lots.first(where: { $0.id == id }) == lot else { throw OptionTradeEntryError.changedLot }
            try validateLotProvenance(lot, in: snapshot)
            let amount: Money
            if closingAllocations.count == 1 { amount = quantity }
            else { amount = try optionTradeQuantity(text) }
            guard amount <= lot.quantityRemaining else { throw OptionTradeEntryError.invalidQuantity }
            total = try total.adding(amount)
            selections[id] = amount.decimalString
        }
        guard total == quantity else { throw OptionTradeEntryError.invalidQuantity }
        return selections
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
