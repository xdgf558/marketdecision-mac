import Foundation
import CoreDomain
import DataContracts

public enum FundamentalError: Error, Equatable {
    case invalidWindow, incompatibleInput, duplicateInput, unsupportedModel, missingEvidence
}

/// Semantic slots, not aliases for arbitrary XBRL tags. Unknown absence is never zero.
public enum FundamentalField: String, Sendable, Codable, CaseIterable {
    case revenue = "income.revenue", grossProfit = "income.gross-profit", operatingIncome = "income.operating-income"
    case netIncome = "income.net-income", commonIncome = "income.common-income", pretaxIncome = "income.pretax-income"
    case tax = "income.tax", interest = "income.interest", depreciation = "cash-flow.depreciation"
    case ocf = "cash-flow.operating-cash-flow", capex = "cash-flow.capex", sbc = "cash-flow.sbc"
    case buybacks = "cash-flow.common-buybacks", issuance = "cash-flow.common-issuance", dividends = "cash-flow.common-dividends"
    case assets = "balance.assets", currentAssets = "balance.current-assets", currentLiabilities = "balance.current-liabilities"
    case commonEquity = "balance.common-equity", totalEquity = "balance.total-equity-including-nci"
    case preferred = "balance.preferred-equity", nci = "balance.noncontrolling-interest", cash = "balance.cash"
    // Debt slots are mutually exclusive. No aggregate label is automatically summed with detail.
    case shortDebt = "debt.short-borrowings", currentDebt = "debt.current-excluding-leases", longDebt = "debt.noncurrent-excluding-leases"
    case financeLease = "debt.finance-lease-total", operatingLease = "debt.operating-lease-total"
    case dilutedEPS = "per-share.diluted-eps", actualShares = "shares.actual-split-adjusted"
    case leaseRate = "ratio.lease-discount-rate"
    var isInstant: Bool { rawValue.hasPrefix("balance.") || rawValue.hasPrefix("debt.") || self == .actualShares || self == .leaseRate }
    var unit: String {
        switch self { case .dilutedEPS: "USD/shares"; case .actualShares: "shares"; case .leaseRate: "pure"; default: "USD" }
    }
}

public struct FiscalYearWindow: Sendable, Codable, Equatable {
    public let start: MarketDate, end: MarketDate
    public init(start: MarketDate, end: MarketDate) throws {
        guard start <= end, (300...400).contains(try start.days(through: end).count) else { throw FundamentalError.invalidWindow }
        self.start = start; self.end = end
    }
}

public struct FiscalQuarter: Sendable, Codable, Equatable {
    public let start: MarketDate, end: MarketDate
    public init(start: MarketDate, end: MarketDate) throws {
        guard start <= end, (70...120).contains(try start.days(through: end).count) else { throw FundamentalError.invalidWindow }
        self.start = start; self.end = end
    }
}

/// One class's actual outstanding shares and contemporaneous price. Split basis and class identity
/// require explicit evidence; weighted-average diluted shares must never fill this slot.
public struct EquityClassInput: Sendable, Codable {
    public let classID: String, price: Money, shares: Money
    public let priceProvenance: Provenance, shareProvenance: Provenance
    public let shareBasisEvidence: String
    public init(classID: String, price: Money, shares: Money, priceProvenance: Provenance,
                shareProvenance: Provenance, shareBasisEvidence: String) {
        self.classID = classID; self.price = price; self.shares = shares
        self.priceProvenance = priceProvenance; self.shareProvenance = shareProvenance
        self.shareBasisEvidence = shareBasisEvidence
    }
}

/// Upstream normalization is explicit. This packet cannot grant supplier, live-analysis or backtest
/// eligibility. Recompute normalization for every historical cutoff; never reuse today's snapshot.
public struct FundamentalInput: Sendable, Codable {
    public let cik: String, normalization: FinancialNormalizationResult, quarters: [FiscalQuarter]
    public let fiscalYears: [FiscalYearWindow], priceDay: MarketDate
    public let expectedClassIDs: Set<String>, classes: [EquityClassInput]
    public let financialCompany: Bool, splitBasisEvidence: String?
    public let inputLimitations: [String]
    public init(cik: String, normalization: FinancialNormalizationResult, quarters: [FiscalQuarter],
                fiscalYears: [FiscalYearWindow] = [], priceDay: MarketDate,
                expectedClassIDs: Set<String> = [], classes: [EquityClassInput] = [],
                financialCompany: Bool = false, splitBasisEvidence: String? = nil,
                inputLimitations: [String] = []) throws {
        self.cik = cik; self.normalization = normalization; self.quarters = quarters
        self.fiscalYears = fiscalYears; self.priceDay = priceDay
        self.expectedClassIDs = expectedClassIDs; self.classes = classes
        self.financialCompany = financialCompany; self.splitBasisEvidence = splitBasisEvidence
        self.inputLimitations = inputLimitations
        try validate()
    }
    private enum CodingKeys: String, CodingKey {
        case cik, normalization, quarters, fiscalYears, priceDay, expectedClassIDs, classes
        case financialCompany, splitBasisEvidence, inputLimitations
    }
    /// Decoding uses the same validation as a new request; required context has no default fallback.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let classIDs = try c.decode([String].self, forKey: .expectedClassIDs)
        guard Set(classIDs).count == classIDs.count else { throw FundamentalError.duplicateInput }
        try self.init(cik: c.decode(String.self, forKey: .cik),
            normalization: c.decode(FinancialNormalizationResult.self, forKey: .normalization),
            quarters: c.decode([FiscalQuarter].self, forKey: .quarters),
            fiscalYears: c.decode([FiscalYearWindow].self, forKey: .fiscalYears),
            priceDay: c.decode(MarketDate.self, forKey: .priceDay), expectedClassIDs: Set(classIDs),
            classes: c.decode([EquityClassInput].self, forKey: .classes),
            financialCompany: c.decode(Bool.self, forKey: .financialCompany),
            splitBasisEvidence: c.decode(String?.self, forKey: .splitBasisEvidence),
            inputLimitations: c.decode([String].self, forKey: .inputLimitations))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cik, forKey: .cik); try c.encode(normalization, forKey: .normalization)
        try c.encode(quarters, forKey: .quarters); try c.encode(fiscalYears, forKey: .fiscalYears)
        try c.encode(priceDay, forKey: .priceDay); try c.encode(expectedClassIDs.sorted(), forKey: .expectedClassIDs)
        try c.encode(classes, forKey: .classes); try c.encode(financialCompany, forKey: .financialCompany)
        try c.encode(splitBasisEvidence, forKey: .splitBasisEvidence)
        try c.encode(inputLimitations, forKey: .inputLimitations)
    }
    /// Shared by capitalization, EPS valuation and historical price inversion.
    var hasCompleteClasses: Bool {
        !expectedClassIDs.isEmpty && classes.count == expectedClassIDs.count
            && Set(classes.map(\.classID)) == expectedClassIDs
    }
    var singleCompleteClass: EquityClassInput? {
        hasCompleteClasses && classes.count == 1 ? classes[0] : nil
    }
    func validate() throws {
        guard !cik.isEmpty, (4...8).contains(quarters.count), normalization.asOf.timeIntervalSince1970.isFinite,
              !normalization.dictionaryVersion.isEmpty else { throw FundamentalError.invalidWindow }
        for q in quarters { _ = try FiscalQuarter(start: q.start, end: q.end) }
        guard (300...400).contains(try quarters.suffix(4).first!.start.days(through: quarters.last!.end).count) else { throw FundamentalError.invalidWindow }
        for (a,b) in zip(quarters, quarters.dropFirst()) {
            guard try a.end.addingDays(1) == b.start else { throw FundamentalError.invalidWindow }
        }
        guard try priceDay.start(in: TimeZone(secondsFromGMT: 0)!) <= normalization.asOf,
              quarters.last!.end <= priceDay else { throw FundamentalError.invalidWindow }
        guard fiscalYears.count <= 3 else { throw FundamentalError.invalidWindow }
        for y in fiscalYears { _ = try FiscalYearWindow(start: y.start, end: y.end)
            guard y.end <= quarters.last!.end else { throw FundamentalError.invalidWindow }
        }
        for (a,b) in zip(fiscalYears, fiscalYears.dropFirst()) {
            guard try a.end.addingDays(1) == b.start else { throw FundamentalError.invalidWindow }
        }
        let shareDays = Set(classes.compactMap { $0.shareProvenance.observationDate })
        guard shareDays.count <= 1 else { throw FundamentalError.incompatibleInput }
        var keys: Set<String> = []
        for f in normalization.values {
            guard f.cik == cik, f.dictionaryVersion == normalization.dictionaryVersion,
                  f.availableAt.timeIntervalSince1970.isFinite, f.availableAt <= normalization.asOf,
                  !f.sourceFactIDs.isEmpty, !f.sourceVersions.isEmpty,
                  f.sourceFactIDs.allSatisfy({ !$0.isEmpty }), f.sourceVersions.allSatisfy({ !$0.isEmpty }),
                  f.periodEnd <= priceDay,
                  f.periodStart.map({ $0 <= f.periodEnd }) ?? true else { throw FundamentalError.incompatibleInput }
            if f.periodType == .quarter, f.periodEnd > quarters.last!.end { throw FundamentalError.incompatibleInput }
            if let field = FundamentalField(rawValue: f.fieldID) {
                guard field.unit == f.unit,
                      field.isInstant ? (f.periodType == .instant && f.nature == .instant) : f.periodStart != nil,
                      field != .dilutedEPS || f.nature == .perShare else { throw FundamentalError.incompatibleInput }
            }
            let key = [f.fieldID, f.periodType.rawValue, f.periodStart?.iso8601 ?? "", f.periodEnd.iso8601].joined(separator: "|")
            guard keys.insert(key).inserted else { throw FundamentalError.duplicateInput }
        }
        for rows in Dictionary(grouping: normalization.values.filter { $0.fieldID.hasPrefix("debt.") },by: \.periodEnd).values {
            let refs = rows.flatMap(\.sourceFactIDs)
            guard Set(refs).count == refs.count else { throw FundamentalError.incompatibleInput }
        }
        for rows in Dictionary(grouping: normalization.values.filter {
            [FundamentalField.netIncome.rawValue, FundamentalField.commonIncome.rawValue].contains($0.fieldID)
        }, by: { ($0.periodStart?.iso8601 ?? "") + "/" + $0.periodEnd.iso8601 + "/" + $0.periodType.rawValue }).values {
            let refs = rows.flatMap(\.sourceFactIDs)
            guard Set(refs).count == refs.count else { throw FundamentalError.incompatibleInput }
        }
        guard Set(classes.map(\.classID)).count == classes.count else { throw FundamentalError.duplicateInput }
        for item in classes {
            try item.priceProvenance.validate(); try item.shareProvenance.validate()
            guard !item.classID.isEmpty, item.price.amount > 0, item.shares.amount > 0,
                  !item.shareBasisEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.priceProvenance.observationDate == priceDay,
                  item.priceProvenance.isAvailable(asOf: normalization.asOf),
                  item.shareProvenance.isAvailable(asOf: normalization.asOf),
                  item.shareProvenance.sourceEventAt.map({ $0 <= normalization.asOf }) ?? false,
                  let shareDay = item.shareProvenance.observationDate, shareDay <= priceDay,
                  let event = item.priceProvenance.sourceEventAt, event <= normalization.asOf,
                  item.priceProvenance.versionID != nil, item.shareProvenance.versionID != nil,
                  !item.priceProvenance.feedID.isEmpty else { throw FundamentalError.missingEvidence }
        }
    }
    var sourceVersions: [String] {
        Array(Set(normalization.values.flatMap(\.sourceVersions) + classes.flatMap {
            [$0.priceProvenance.versionID!, $0.shareProvenance.versionID!]
        })).sorted()
    }
    func value(_ field: FundamentalField, type: FinancialPeriodType, start: MarketDate? = nil, end: MarketDate) -> Money? {
        let matches = normalization.values.filter { $0.fieldID == field.rawValue && $0.periodType == type
            && $0.periodEnd == end && (start == nil || $0.periodStart == start) }
        return matches.count == 1 ? matches[0].value : nil
    }
    func flow(_ field: FundamentalField, window: ArraySlice<FiscalQuarter>? = nil) throws -> Money? {
        let qs = window ?? quarters.suffix(4)
        guard qs.count == 4 else { return nil }
        if field == .dilutedEPS, splitBasisEvidence?.isEmpty != false { return nil }
        let items = qs.map { value(field, type: .quarter, start: $0.start, end: $0.end) }
        guard items.allSatisfy({ $0 != nil }) else { return nil }
        return try items.reduce(Money("0")) { try $0.adding($1!) }
    }
    func instant(_ field: FundamentalField, end: MarketDate? = nil) -> Money? {
        value(field, type: .instant, end: end ?? quarters.last!.end)
    }
}

public enum FundamentalMissing: String, Sendable, Codable { case missingInput, nonpositiveDenominator, notApplicable, notComparable, insufficientHistory, missingPrice, missingClass, missingEvidence }
public struct FundamentalMetric: Sendable, Codable, Equatable {
    public let value: Money?
    public let unavailable: FundamentalMissing?
    public let flags: [String]
    init(_ value: Money?, reason: FundamentalMissing = .missingInput, flags: [String] = []) {
        self.value = value; self.unavailable = value == nil ? reason : nil; self.flags = flags
    }
}

/// Versioned immutable copy of every input choice. Old reports without this snapshot cannot be
/// upgraded by guessing windows/classification from calculated metrics.
public struct FundamentalInputSnapshot: Sendable, Codable {
    public static let formatVersion = "fundamental-input.v1"
    public let input: FundamentalInput
    public let asOf: MillisecondInstant, executionAt: MillisecondInstant
    public let executionDate: Date
    public init(input: FundamentalInput, executionDate: Date) throws {
        try input.validate()
        self.input = input
        self.asOf = try MillisecondInstant(rounding: input.normalization.asOf)
        self.executionAt = try MillisecondInstant(rounding: executionDate)
        guard input.normalization.asOf <= executionDate else { throw FundamentalError.incompatibleInput }
        self.executionDate = executionDate
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, input, executionDate }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .formatVersion) == Self.formatVersion else {
            throw FundamentalError.incompatibleInput
        }
        try self.init(input: c.decode(FundamentalInput.self, forKey: .input), executionDate: c.decode(Date.self, forKey: .executionDate))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion); try c.encode(input, forKey: .input)
        try c.encode(executionDate, forKey: .executionDate)
    }
}

/// Local calculation result; intentionally carries no eligibility grant. Descriptive input
/// properties project the snapshot rather than storing a second, potentially conflicting copy.
public struct FundamentalReport: Sendable, Codable {
    public let inputSnapshot: FundamentalInputSnapshot
    public var executionAt: MillisecondInstant { inputSnapshot.executionAt }
    public let model: RegistryReference, parameters: RegistryReference
    public let limitations: [String]
    public let metrics: [String: FundamentalMetric]
    public let confidence: FinancialConfidence
    public let researchOnly: Bool
    public var cik: String { inputSnapshot.input.cik }
    public var asOf: MillisecondInstant { inputSnapshot.asOf }
    public var periodEnd: MarketDate { inputSnapshot.input.quarters.last!.end }
    public var priceDay: MarketDate { inputSnapshot.input.priceDay }
    public var capitalInputs: [EquityClassInput] { inputSnapshot.input.classes }
    public var expectedClassIDs: [String] { inputSnapshot.input.expectedClassIDs.sorted() }
    public var dictionaryVersion: String { inputSnapshot.input.normalization.dictionaryVersion }
    public var sourceVersions: [String] { inputSnapshot.input.sourceVersions }
    public var normalizedInputs: [NormalizedFinancialFact] { inputSnapshot.input.normalization.values }

    func replayInput(using resolved: ResolvedModel) throws -> FundamentalInput {
        guard resolved.definition.reference == model, resolved.parameters.reference == parameters else {
            throw RegistryError.referenceMismatch
        }
        try inputSnapshot.input.validate()
        return inputSnapshot.input
    }
    /// Recomputes from saved inputs and the exact resolved model; cached outputs are not inputs.
    public func recompute(using resolved: ResolvedModel) throws -> FundamentalReport {
        try FundamentalCalculator.calculate(replayInput(using: resolved), model: resolved, executionDate: inputSnapshot.executionDate)
    }
}
