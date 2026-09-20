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
public struct FundamentalInput: Sendable {
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

/// Local calculation result; intentionally carries no eligibility grant.
public struct FundamentalReport: Sendable, Codable {
    public let cik: String, asOf: MillisecondInstant, periodEnd: MarketDate
    public let executionAt: MillisecondInstant, priceDay: MarketDate
    public let capitalInputs: [EquityClassInput], expectedClassIDs: [String]
    public let model: RegistryReference, parameters: RegistryReference, dictionaryVersion: String
    public let sourceVersions: [String], limitations: [String]
    public let normalizedInputs: [NormalizedFinancialFact]
    public let metrics: [String: FundamentalMetric]
    public let confidence: FinancialConfidence
    public let researchOnly: Bool
}
