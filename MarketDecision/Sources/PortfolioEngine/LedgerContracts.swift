import Foundation
import CoreDomain
import DataContracts

public enum LedgerError: Error, Equatable, Sendable {
    case invalidAccount, invalidIdentity, invalidEvidence, invalidAmount, invalidQuantity
    case invalidContract, unsupportedSettlement, missingFee, duplicateIdentity, ambiguousOrdering
    case insufficientLots, invalidLotSelection, costBasisMethodLocked, invalidCorporateAction
    case invalidReversal, invalidRoll, invalidStrategy, arithmeticInvariant, missingAccount
}

public enum LedgerCostBasisMethod: String, Codable, Sendable { case fifo, specificLot }
public struct LedgerAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let currency: String
    public let costBasisMethod: LedgerCostBasisMethod
    public init(id: String, name: String, currency: String = "USD", costBasisMethod: LedgerCostBasisMethod = .fifo) {
        self.id = id; self.name = name; self.currency = currency; self.costBasisMethod = costBasisMethod
    }
    public func validate() throws {
        guard ledgerText(id), ledgerText(name), currency == "USD" else { throw LedgerError.invalidAccount }
    }
}

public struct LedgerSource: Codable, Equatable, Sendable {
    public let sourceSystem: String
    public let externalTransactionID: String?
    public let fileHash: String?
    public let rowIndex: Int?
    public let evidence: String
    public init(sourceSystem: String, externalTransactionID: String? = nil, fileHash: String? = nil,
                rowIndex: Int? = nil, evidence: String) {
        self.sourceSystem = sourceSystem; self.externalTransactionID = externalTransactionID
        self.fileHash = fileHash; self.rowIndex = rowIndex; self.evidence = evidence
    }
    public func validate() throws {
        guard ledgerText(sourceSystem), ledgerText(evidence), externalTransactionID.map(ledgerText) ?? true,
              (fileHash == nil) == (rowIndex == nil), rowIndex.map({ $0 >= 1 }) ?? true,
              fileHash.map({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) ?? true,
              externalTransactionID != nil || fileHash != nil else { throw LedgerError.invalidEvidence }
    }
    public func identity(accountID: String) throws -> String {
        try validate()
        let fields = externalTransactionID.map { [accountID, sourceSystem, "external", $0] }
            ?? [accountID, sourceSystem, "file", fileHash ?? "", String(rowIndex ?? 0)]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public enum LedgerSecurityKind: String, Codable, Sendable { case stock, etf }
public struct LedgerSecurity: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let symbol: String
    public let kind: LedgerSecurityKind
    public init(id: String, symbol: String, kind: LedgerSecurityKind = .stock) {
        self.id = id; self.symbol = symbol; self.kind = kind
    }
    public func validate() throws {
        guard ledgerText(id), ledgerText(symbol) else { throw LedgerError.invalidIdentity }
    }
}
public enum LedgerOptionRight: String, Codable, Sendable { case call, put }
public enum LedgerExerciseStyle: String, Codable, Sendable { case american, european }
public enum LedgerSettlementType: String, Codable, Sendable { case physicalEquity, cash, other }
public struct LedgerDeliverable: Codable, Equatable, Sendable {
    public let security: LedgerSecurity
    public let quantity: Money
    /// Confirmed fraction of the aggregate management cost / proceeds, not a tax allocation.
    public let basisWeight: Money
    public init(security: LedgerSecurity, quantity: Money, basisWeight: Money) {
        self.security = security; self.quantity = quantity; self.basisWeight = basisWeight
    }
}

public enum LedgerOptionTermsBasis: String, Codable, Sendable {
    /// User-declared standard terms for manual cash/premium bookkeeping only.
    /// This does not establish an official trading, exercise or delivery schedule.
    case localManualStandard
}

/// OCC identifies an option; a separately evidenced version defines its actual delivery.
/// Local manual terms retain the user's standard-contract declaration without
/// inventing official dates. A multiplier is never inferred from OCC spelling.
public struct LedgerOptionVersion: Codable, Equatable, Sendable {
    public let occSymbol: String
    public let versionID: String
    public let effectiveFrom: Date?
    public let effectiveTo: Date?
    public let quoteMultiplier: Money
    public let exerciseConsideration: Money
    public let deliverables: [LedgerDeliverable]
    public let deliverableCash: Money
    public let settlementType: LedgerSettlementType
    public let exerciseStyle: LedgerExerciseStyle
    public let tradingEndsAt: Date?
    public let exerciseDeadline: Date?
    public let settlementAt: Date?
    public let memoReferences: [String]
    /// Nil retains the original evidenced-contract representation. Synthesized
    /// Codable omits nil, preserving the encoded shape of existing records.
    public let termsBasis: LedgerOptionTermsBasis?
    public init(occSymbol: String, versionID: String, effectiveFrom: Date?, effectiveTo: Date? = nil,
                quoteMultiplier: Money, exerciseConsideration: Money, deliverables: [LedgerDeliverable],
                deliverableCash: Money, settlementType: LedgerSettlementType = .physicalEquity,
                exerciseStyle: LedgerExerciseStyle = .american, tradingEndsAt: Date?,
                exerciseDeadline: Date?, settlementAt: Date?, memoReferences: [String],
                termsBasis: LedgerOptionTermsBasis? = nil) {
        self.occSymbol = occSymbol; self.versionID = versionID; self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo; self.quoteMultiplier = quoteMultiplier
        self.exerciseConsideration = exerciseConsideration; self.deliverables = deliverables
        self.deliverableCash = deliverableCash; self.settlementType = settlementType
        self.exerciseStyle = exerciseStyle; self.tradingEndsAt = tradingEndsAt
        self.exerciseDeadline = exerciseDeadline; self.settlementAt = settlementAt; self.memoReferences = memoReferences
        self.termsBasis = termsBasis
    }
    public var right: LedgerOptionRight { occSymbol.dropLast(8).last == "C" ? .call : .put }
    public var identity: String { occSymbol + ":" + versionID }
    public var isLocalManualStandard: Bool { termsBasis == .localManualStandard }

    /// The OCC civil date is an identifier component, not a market calendar or
    /// an exercise deadline. Local manual date checks use New York explicitly.
    public var expirationDate: MarketDate? {
        guard occSymbol.count == 21,
              occSymbol.range(of: "^[A-Z0-9 ]{6}[0-9]{6}[CP][0-9]{8}$", options: .regularExpression) != nil else { return nil }
        let day = String(occSymbol.dropFirst(6).prefix(6))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard let yy = Int(day.prefix(2)), let mm = Int(day.dropFirst(2).prefix(2)), let dd = Int(day.suffix(2)),
              let date = calendar.date(from: DateComponents(year: 2000 + yy, month: mm, day: dd)),
              calendar.component(.year, from: date) == 2000 + yy,
              calendar.component(.month, from: date) == mm, calendar.component(.day, from: date) == dd else { return nil }
        return .init(year: 2000 + yy, month: mm, day: dd)
    }

    public func allowsLocalManualTrade(at instant: Date) -> Bool {
        guard isLocalManualStandard, let expiry = expirationDate, let day = newYorkDate(instant) else { return false }
        return day <= expiry
    }

    /// Allows only an explicitly evidenced, user-reported zero settlement;
    /// reaching this date never creates an event or closes a holding by itself.
    public func allowsLocalManualExpiration(at instant: Date) -> Bool {
        guard isLocalManualStandard, let expiry = expirationDate, let day = newYorkDate(instant) else { return false }
        return day >= expiry
    }

    private func newYorkDate(_ instant: Date) -> MarketDate? {
        guard ledgerDate(instant) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return .init(year: year, month: month, day: day)
    }

    public func validate() throws {
        guard occSymbol.count == 21,
              occSymbol.range(of: "^[A-Z0-9 ]{6}[0-9]{6}[CP][0-9]{8}$", options: .regularExpression) != nil,
              ledgerText(String(occSymbol.prefix(6))), ledgerText(versionID), expirationDate != nil,
              quoteMultiplier.amount > 0, exerciseConsideration.amount >= 0, deliverableCash.amount >= 0,
              !memoReferences.isEmpty, memoReferences.allSatisfy(ledgerText) else { throw LedgerError.invalidContract }
        if isLocalManualStandard {
            guard effectiveFrom == nil, effectiveTo == nil, tradingEndsAt == nil,
                  exerciseDeadline == nil, settlementAt == nil,
                  exerciseStyle == .american, quoteMultiplier == (try Money("100")),
                  deliverableCash.amount == 0, deliverables.count == 1,
                  let delivery = deliverables.first,
                  delivery.quantity == (try Money("100")), delivery.basisWeight == (try Money("1")),
                  delivery.security.symbol == String(occSymbol.prefix(6)).trimmingCharacters(in: .whitespaces),
                  let strikeUnits = Int(occSymbol.suffix(8)), strikeUnits > 0,
                  exerciseConsideration == (try Money(String(strikeUnits)).divided(by: "10")) else { throw LedgerError.invalidContract }
        } else {
            guard let effectiveFrom, let tradingEndsAt, let exerciseDeadline, let settlementAt,
                  ledgerDate(effectiveFrom), effectiveTo.map({ ledgerDate($0) && $0 > effectiveFrom }) ?? true,
                  ledgerDate(tradingEndsAt), ledgerDate(exerciseDeadline), ledgerDate(settlementAt),
                  tradingEndsAt <= exerciseDeadline, exerciseDeadline <= settlementAt else { throw LedgerError.invalidContract }
        }
        guard settlementType == .physicalEquity else { throw LedgerError.unsupportedSettlement }
        guard !deliverables.isEmpty, Set(deliverables.map { $0.security.id }).count == deliverables.count else {
            throw LedgerError.invalidContract
        }
        var weight = try Money("0")
        for item in deliverables {
            try item.security.validate(); try ledgerPositiveQuantity(item.quantity)
            guard item.basisWeight.amount > 0 else { throw LedgerError.invalidContract }
            weight = try weight.adding(item.basisWeight)
        }
        guard weight == (try Money("1")) else { throw LedgerError.invalidContract }
    }
}
public enum LedgerInstrument: Codable, Equatable, Sendable {
    case equity(LedgerSecurity)
    case option(LedgerOptionVersion)
    public var identity: String {
        switch self { case .equity(let s): "equity:" + s.id; case .option(let o): "option:" + o.identity }
    }
    public var label: String {
        switch self { case .equity(let s): s.symbol; case .option(let o): o.occSymbol }
    }
    public func validate() throws {
        switch self { case .equity(let s): try s.validate(); case .option(let o): try o.validate() }
    }
}
public enum LedgerStrategyPurpose: String, Codable, Sendable { case premiumIncome, acquireShares, totalReturn, hedgeOrManage }
public struct LedgerStrategy: Codable, Equatable, Sendable {
    public let id: String
    public let purpose: LedgerStrategyPurpose
    public let successDefinition: String
    public let maximumAcquisitionPrice: Money?
    public let unassignedCountsAsSuccess: Bool
    public init(id: String, purpose: LedgerStrategyPurpose, successDefinition: String,
                maximumAcquisitionPrice: Money? = nil, unassignedCountsAsSuccess: Bool = false) {
        self.id = id; self.purpose = purpose; self.successDefinition = successDefinition
        self.maximumAcquisitionPrice = maximumAcquisitionPrice; self.unassignedCountsAsSuccess = unassignedCountsAsSuccess
    }
    public func validate() throws {
        guard ledgerText(id), ledgerText(successDefinition),
              purpose != .acquireShares || (maximumAcquisitionPrice?.amount ?? 0) > 0,
              maximumAcquisitionPrice.map({ $0.amount > 0 }) ?? true else { throw LedgerError.invalidStrategy }
    }
}
public enum LedgerSide: String, Codable, Sendable { case buy, sell }
public enum LedgerPositionSide: String, Codable, Sendable { case long, short }
public enum LedgerTradeEffect: String, Codable, Sendable { case open, close }
public struct LedgerLotSelection: Codable, Equatable, Sendable {
    public let lotID: String
    public let quantity: Money
    public init(lotID: String, quantity: Money) { self.lotID = lotID; self.quantity = quantity }
}
public struct LedgerTrade: Codable, Equatable, Sendable {
    public let instrument: LedgerInstrument
    public let side: LedgerSide
    public let effect: LedgerTradeEffect
    public let quantity: Money
    public let unitPrice: Money
    public let fee: Money
    public let openingLotID: String?
    public let selections: [LedgerLotSelection]
    public let strategy: LedgerStrategy?
    public init(instrument: LedgerInstrument, side: LedgerSide, effect: LedgerTradeEffect, quantity: Money,
                unitPrice: Money, fee: Money, openingLotID: String? = nil,
                selections: [LedgerLotSelection] = [], strategy: LedgerStrategy? = nil) {
        self.instrument = instrument; self.side = side; self.effect = effect; self.quantity = quantity
        self.unitPrice = unitPrice; self.fee = fee; self.openingLotID = openingLotID
        self.selections = selections; self.strategy = strategy
    }
}
public enum LedgerCashKind: String, Codable, Sendable {
    case deposit, withdrawal, dividend, interest, fee, dividendWithholding, interestWithholding, otherTax
}
public struct LedgerCashEntry: Codable, Equatable, Sendable {
    public let kind: LedgerCashKind
    public let amount: Money
    public let securityID: String?
    public init(kind: LedgerCashKind, amount: Money, securityID: String? = nil) {
        self.kind = kind; self.amount = amount; self.securityID = securityID
    }
}
public enum LedgerSettlementAction: String, Codable, Sendable { case assignment, exercise, expiration }
public struct LedgerOptionSettlement: Codable, Equatable, Sendable {
    public let contract: LedgerOptionVersion
    public let action: LedgerSettlementAction
    public let side: LedgerPositionSide
    public let quantity: Money
    public let fee: Money
    public let optionSelections: [LedgerLotSelection]
    public let equitySelections: [LedgerLotSelection]
    /// One explicit new lot ID for every delivered security when shares are acquired.
    public let acquiredLotIDs: [String: String]
    public let evidence: String
    public init(contract: LedgerOptionVersion, action: LedgerSettlementAction, side: LedgerPositionSide,
                quantity: Money, fee: Money, optionSelections: [LedgerLotSelection] = [],
                equitySelections: [LedgerLotSelection] = [], acquiredLotIDs: [String: String] = [:], evidence: String) {
        self.contract = contract; self.action = action; self.side = side; self.quantity = quantity
        self.fee = fee; self.optionSelections = optionSelections; self.equitySelections = equitySelections
        self.acquiredLotIDs = acquiredLotIDs; self.evidence = evidence
    }
}
public struct LedgerSplitFraction: Codable, Equatable, Sendable {
    public let lotID: String
    public let quantityDisposed: Money
    public let cash: Money
    public init(lotID: String, quantityDisposed: Money, cash: Money) {
        self.lotID = lotID; self.quantityDisposed = quantityDisposed; self.cash = cash
    }
}
public struct LedgerSplit: Codable, Equatable, Sendable {
    public let securityID: String
    public let ratio: Money
    public let fractions: [LedgerSplitFraction]
    public let evidence: String
    public let confirmedBy: String
    public init(securityID: String, ratio: Money, fractions: [LedgerSplitFraction] = [], evidence: String, confirmedBy: String) {
        self.securityID = securityID; self.ratio = ratio; self.fractions = fractions
        self.evidence = evidence; self.confirmedBy = confirmedBy
    }
}
public enum LedgerReorganizationKind: String, Codable, Sendable { case spinoff, merger }
public struct LedgerReorganizationOutput: Codable, Equatable, Sendable {
    public let lotID: String
    public let security: LedgerSecurity
    public let quantity: Money
    public let basisWeight: Money
    public init(lotID: String, security: LedgerSecurity, quantity: Money, basisWeight: Money) {
        self.lotID = lotID; self.security = security; self.quantity = quantity; self.basisWeight = basisWeight
    }
}
public struct LedgerReorganizationRow: Codable, Equatable, Sendable {
    public let sourceLotID: String
    /// Entire source lot is replaced; a spinoff row explicitly includes the retained parent.
    public let outputs: [LedgerReorganizationOutput]
    /// Explicit official net cash; nil means no cash leg, never an inferred fee.
    public let netCashConsideration: Money?
    public let cashBasisWeight: Money?
    public init(sourceLotID: String, outputs: [LedgerReorganizationOutput], netCashConsideration: Money? = nil, cashBasisWeight: Money? = nil) {
        self.sourceLotID = sourceLotID; self.outputs = outputs
        self.netCashConsideration = netCashConsideration; self.cashBasisWeight = cashBasisWeight
    }
}
public struct LedgerReorganization: Codable, Equatable, Sendable {
    public let kind: LedgerReorganizationKind
    public let rows: [LedgerReorganizationRow]
    public let evidence: String
    public let confirmedBy: String
    public init(kind: LedgerReorganizationKind, rows: [LedgerReorganizationRow], evidence: String, confirmedBy: String) {
        self.kind = kind; self.rows = rows; self.evidence = evidence; self.confirmedBy = confirmedBy
    }
}
public struct LedgerReturnOfCapital: Codable, Equatable, Sendable {
    public let allocations: [String: Money]
    public let evidence: String
    public let confirmedBy: String
    public init(allocations: [String: Money], evidence: String, confirmedBy: String) {
        self.allocations = allocations; self.evidence = evidence; self.confirmedBy = confirmedBy
    }
}
public struct LedgerCashInLieu: Codable, Equatable, Sendable {
    public let selections: [LedgerLotSelection]
    public let cash: Money
    public let fee: Money
    public let corporateActionEventID: String
    public let evidence: String
    public init(selections: [LedgerLotSelection], cash: Money, fee: Money, corporateActionEventID: String, evidence: String) {
        self.selections = selections; self.cash = cash; self.fee = fee
        self.corporateActionEventID = corporateActionEventID; self.evidence = evidence
    }
}
public struct LedgerTransferIn: Codable, Equatable, Sendable {
    public let lotID: String
    public let instrument: LedgerInstrument
    public let side: LedgerPositionSide
    public let quantity: Money
    public let historicalCost: Money
    public let acquiredAt: Date
    public let eventMarketValue: Money
    public let userReportedTaxBasis: Money?
    public let strategy: LedgerStrategy?
    public let evidence: String
    public init(lotID: String, instrument: LedgerInstrument, side: LedgerPositionSide = .long, quantity: Money,
                historicalCost: Money, acquiredAt: Date, eventMarketValue: Money, userReportedTaxBasis: Money? = nil,
                strategy: LedgerStrategy? = nil, evidence: String) {
        self.lotID = lotID; self.instrument = instrument; self.side = side; self.quantity = quantity
        self.historicalCost = historicalCost; self.acquiredAt = acquiredAt; self.eventMarketValue = eventMarketValue
        self.userReportedTaxBasis = userReportedTaxBasis; self.strategy = strategy; self.evidence = evidence
    }
}
public struct LedgerTransferOut: Codable, Equatable, Sendable {
    public let instrument: LedgerInstrument
    public let side: LedgerPositionSide
    public let quantity: Money
    public let selections: [LedgerLotSelection]
    public let eventMarketValue: Money
    public let evidence: String
    public init(instrument: LedgerInstrument, side: LedgerPositionSide = .long, quantity: Money,
                selections: [LedgerLotSelection] = [], eventMarketValue: Money, evidence: String) {
        self.instrument = instrument; self.side = side; self.quantity = quantity; self.selections = selections
        self.eventMarketValue = eventMarketValue; self.evidence = evidence
    }
}
public struct LedgerContractAdjustment: Codable, Equatable, Sendable {
    public let previous: LedgerOptionVersion
    public let replacement: LedgerOptionVersion
    public let contractQuantityRatio: Money
    public let evidence: String
    public let confirmedBy: String
    public init(previous: LedgerOptionVersion, replacement: LedgerOptionVersion, contractQuantityRatio: Money,
                evidence: String, confirmedBy: String) {
        self.previous = previous; self.replacement = replacement; self.contractQuantityRatio = contractQuantityRatio
        self.evidence = evidence; self.confirmedBy = confirmedBy
    }
}
public struct LedgerReversal: Codable, Equatable, Sendable {
    public let originalEventID: String
    public let reason: String
    public init(originalEventID: String, reason: String) { self.originalEventID = originalEventID; self.reason = reason }
}
public enum LedgerPayload: Codable, Equatable, Sendable {
    case cash(LedgerCashEntry), trade(LedgerTrade), optionSettlement(LedgerOptionSettlement)
    case split(LedgerSplit), reorganization(LedgerReorganization), returnOfCapital(LedgerReturnOfCapital)
    case cashInLieu(LedgerCashInLieu), transferIn(LedgerTransferIn), transferOut(LedgerTransferOut)
    case contractAdjustment(LedgerContractAdjustment), reversal(LedgerReversal)
    public var kind: String {
        switch self {
        case .cash(let x): x.kind.rawValue
        case .trade(let x): x.side.rawValue + "_" + x.effect.rawValue
        case .optionSettlement(let x): x.action.rawValue
        case .split: "stockSplit"
        case .reorganization(let x): x.kind.rawValue
        case .returnOfCapital: "returnOfCapital"
        case .cashInLieu: "cashInLieu"
        case .transferIn: "transferIn"
        case .transferOut: "transferOut"
        case .contractAdjustment: "contractAdjustment"
        case .reversal: "reversal"
        }
    }
}
public struct LedgerEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let effectiveAt: Date
    /// Actual provider sequence for equal instants; nil is not an invented sequence.
    public let providerSequence: Int?
    public let source: LedgerSource
    public let payload: LedgerPayload
    public let rollGroupID: String?
    public let multiLegGroupID: String?
    public let notes: String
    public init(id: String, accountID: String, effectiveAt: Date, providerSequence: Int? = nil,
                source: LedgerSource, payload: LedgerPayload, rollGroupID: String? = nil,
                multiLegGroupID: String? = nil, notes: String = "") {
        self.id = id; self.accountID = accountID; self.effectiveAt = effectiveAt; self.providerSequence = providerSequence
        self.source = source; self.payload = payload; self.rollGroupID = rollGroupID
        self.multiLegGroupID = multiLegGroupID; self.notes = notes
    }
    public func validate() throws {
        guard ledgerText(id), ledgerText(accountID), ledgerDate(effectiveAt),
              providerSequence.map({ $0 >= 0 }) ?? true, rollGroupID.map(ledgerText) ?? true,
              multiLegGroupID.map(ledgerText) ?? true else { throw LedgerError.invalidIdentity }
        try source.validate(); try LedgerValidation.payload(payload, at: effectiveAt)
    }
    public var idempotencyKey: String { get throws { try source.identity(accountID: accountID) } }
}

public struct LedgerLot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public var instrument: LedgerInstrument
    public let side: LedgerPositionSide
    public let openEventID: String
    public let acquiredAt: Date
    public let quantityOpened: Money
    public var quantityRemaining: Money
    public var managementCostRemaining: Money
    public let strategy: LedgerStrategy?
    public let userReportedOriginalTaxBasis: Money?
    /// Attribution links only; no extra premium recognition and no tax basis inference.
    public var originatingOptionLotIDs: [String]
    public var adjustmentEventIDs: [String]
    public var isClosed: Bool { quantityRemaining.amount == 0 }
    public var hasNegativeEconomicBasis: Bool { managementCostRemaining.amount < 0 }
}
public enum LedgerRealizationKind: String, Codable, Sendable { case trade, expiration, settlement, cashInLieu, rocExcess }
public struct LedgerRealization: Codable, Equatable, Sendable {
    public let eventID: String
    public let lotID: String
    public let quantity: Money
    public let removedManagementCost: Money
    public let netProceedsOrCloseCost: Money
    public let pnl: Money
    public let kind: LedgerRealizationKind
}
public struct LedgerPosting: Codable, Equatable, Sendable {
    public let eventID: String
    public let accountID: String
    public let cashChange: Money
    public let externalFlow: Money
    public let transactionFee: Money
    public let grossCash: Money
    public let transferredEmbeddedGain: Money
}
public struct LedgerState: Codable, Equatable, Sendable {
    public let engineVersion: String
    public let parameterVersion: String
    public let numericPolicyVersion: String
    public var cashByAccount: [String: Money]
    public var lots: [LedgerLot]
    public var realizations: [LedgerRealization]
    public var postings: [LedgerPosting]
    public var activeEventIDs: [String]
    public var reversedEventIDs: [String]
    public var auditEventIDs: [String]
}

func ledgerText(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !s.contains("\u{0000}") }
func ledgerDate(_ d: Date) -> Bool { d.timeIntervalSinceReferenceDate.isFinite }
func ledgerPositiveQuantity(_ q: Money, integral: Bool = false) throws {
    guard q.amount > 0, try q.rounded(to: .shares) == q,
          !integral || !q.decimalString.contains(".") else { throw LedgerError.invalidQuantity }
}
