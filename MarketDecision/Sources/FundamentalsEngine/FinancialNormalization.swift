import Foundation
import CoreDomain
import DataContracts

public enum FinancialNormalizationError: Error, Equatable {
    case invalidDictionary
    case ambiguousRevision
    case incompatiblePeriod
    case missingQuarter
}

public enum FinancialStatement: String, Sendable, Codable {
    case incomeStatement, balanceSheet, cashFlow, shareCount, perShare, other
}
public enum FinancialMetricNature: String, Sendable, Codable { case additiveFlow, instant, perShare, nonadditive }
public enum FinancialPeriodType: String, Sendable, Codable { case instant, quarter, yearToDate, annual, trailingTwelveMonths, unclassified }
public enum FinancialConfidence: String, Sendable, Codable { case high, medium, low }
public enum FinancialDerivation: String, Sendable, Codable { case reported, ytdDifference, annualLessYTD, fourQuarterSum }
public enum FinancialIssueSeverity: String, Sendable, Codable { case blocker, high, medium, low }

public struct FinancialMappingRule: Sendable, Codable, Equatable {
    public let taxonomy: String
    public let concept: String
    public let sourceUnit: String
    public let fieldID: String
    public let statement: FinancialStatement
    public let nature: FinancialMetricNature
    public let preferred: Bool
    public init(taxonomy: String, concept: String, sourceUnit: String, fieldID: String,
                statement: FinancialStatement, nature: FinancialMetricNature, preferred: Bool = true) throws {
        let identifier = #"^[A-Za-z_][A-Za-z0-9._\-]{0,255}\z"#
        guard taxonomy.range(of: identifier, options: .regularExpression) != nil,
              concept.range(of: identifier, options: .regularExpression) != nil,
              !sourceUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fieldID.range(of: #"^[a-z][a-z0-9._\-]{0,127}\z"#, options: .regularExpression) != nil else {
            throw FinancialNormalizationError.invalidDictionary
        }
        self.taxonomy = taxonomy; self.concept = concept; self.sourceUnit = sourceUnit
        self.fieldID = fieldID; self.statement = statement; self.nature = nature; self.preferred = preferred
    }
    public var sourceKey: String { taxonomy + ":" + concept + ":" + sourceUnit }
}

/// Immutable, exact-match XBRL dictionary. Unknown/custom tags stay unmapped until a new version
/// is reviewed; callers cannot mutate an existing version or fall back to a concept-only match.
public struct FinancialFieldDictionary: Sendable {
    public let version: String
    public let rules: [FinancialMappingRule]
    private let bySource: [String: FinancialMappingRule]
    public init(version: String, rules: [FinancialMappingRule]) throws {
        guard version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._\-]{0,127}\z"#, options: .regularExpression) != nil,
              !rules.isEmpty, Set(rules.map(\.sourceKey)).count == rules.count else {
            throw FinancialNormalizationError.invalidDictionary
        }
        for group in Dictionary(grouping: rules, by: \.fieldID).values {
            let first = group[0]
            guard group.allSatisfy({ $0.statement == first.statement && $0.nature == first.nature
                                      && $0.sourceUnit == first.sourceUnit }),
                  group.filter({ $0.preferred }).count <= 1 else {
                throw FinancialNormalizationError.invalidDictionary
            }
        }
        let canonical = rules.sorted { $0.sourceKey < $1.sourceKey }
        self.version = version; self.rules = canonical
        self.bySource = Dictionary(uniqueKeysWithValues: canonical.map { ($0.sourceKey, $0) })
    }
    public func rule(for fact: SECCompanyFactRecord) -> FinancialMappingRule? {
        // Dimension-bearing facts require an issuer/context-specific reviewed decision. The
        // foundation dictionary deliberately maps only dimensionless facts.
        guard fact.dimensions.isEmpty else { return nil }
        return bySource[fact.taxonomy + ":" + fact.concept + ":" + fact.unit]
    }

    public static func foundationV1() throws -> Self {
        try Self(version: "financial-fields.us-gaap.v1", rules: [
            .init(taxonomy: "us-gaap", concept: "RevenueFromContractWithCustomerExcludingAssessedTax", sourceUnit: "USD",
                  fieldID: "income.revenue", statement: .incomeStatement, nature: .additiveFlow),
            .init(taxonomy: "us-gaap", concept: "Revenues", sourceUnit: "USD",
                  fieldID: "income.revenue", statement: .incomeStatement, nature: .additiveFlow, preferred: false),
            .init(taxonomy: "us-gaap", concept: "NetIncomeLoss", sourceUnit: "USD",
                  fieldID: "income.net-income", statement: .incomeStatement, nature: .additiveFlow),
            .init(taxonomy: "us-gaap", concept: "Assets", sourceUnit: "USD",
                  fieldID: "balance.assets", statement: .balanceSheet, nature: .instant),
            .init(taxonomy: "us-gaap", concept: "Liabilities", sourceUnit: "USD",
                  fieldID: "balance.liabilities", statement: .balanceSheet, nature: .instant),
            .init(taxonomy: "us-gaap", concept: "StockholdersEquity", sourceUnit: "USD",
                  fieldID: "balance.stockholders-equity", statement: .balanceSheet, nature: .instant),
            .init(taxonomy: "us-gaap", concept: "NetCashProvidedByUsedInOperatingActivities", sourceUnit: "USD",
                  fieldID: "cash-flow.operating-cash-flow", statement: .cashFlow, nature: .additiveFlow),
            .init(taxonomy: "us-gaap", concept: "PaymentsToAcquirePropertyPlantAndEquipment", sourceUnit: "USD",
                  fieldID: "cash-flow.capex", statement: .cashFlow, nature: .additiveFlow),
            .init(taxonomy: "us-gaap", concept: "EarningsPerShareDiluted", sourceUnit: "USD/shares",
                  fieldID: "per-share.diluted-eps", statement: .perShare, nature: .perShare),
            .init(taxonomy: "us-gaap", concept: "WeightedAverageNumberOfDilutedSharesOutstanding", sourceUnit: "shares",
                  fieldID: "shares.weighted-average-diluted", statement: .shareCount, nature: .nonadditive)
        ])
    }
}

public struct NormalizedFinancialFact: Sendable, Codable, Equatable {
    public let id: String
    public let cik: String
    public let fieldID: String
    public let statement: FinancialStatement
    public let nature: FinancialMetricNature
    public let periodType: FinancialPeriodType
    public let periodStart: MarketDate?
    public let periodEnd: MarketDate
    public let fiscalYear: Int?
    public let fiscalPeriod: String?
    public let unit: String
    public let value: Money
    public let sourceValue: String?
    public let derivation: FinancialDerivation
    public let sourceFactIDs: [String]
    public let sourceVersions: [String]
    public let accessionNumbers: [String]
    public let dictionaryVersion: String
    public let availableAt: Date
    public let confidence: FinancialConfidence
    public let limitations: [String]
}

public struct FinancialNormalizationIssue: Sendable, Codable, Equatable {
    public let code: String
    public let severity: FinancialIssueSeverity
    public let factIDs: [String]
    public let message: String
    public init(code: String, severity: FinancialIssueSeverity, factIDs: [String], message: String) {
        self.code = code; self.severity = severity; self.factIDs = factIDs; self.message = message
    }
}

public struct FinancialNormalizationResult: Sendable, Codable, Equatable {
    public let asOf: Date
    public let dictionaryVersion: String
    public let values: [NormalizedFinancialFact]
    public let issues: [FinancialNormalizationIssue]
    public let selectedSourceFacts: [SECCompanyFactRecord]
    public let unmappedSourceFacts: [SECCompanyFactRecord]
}

public enum FinancialNormalizer {
    /// Selects each fact context as of the requested cutoff, then maps exact taxonomy/concept/unit
    /// triples. Missing, future, ambiguous and unknown facts are never converted to zero.
    public static func normalize(_ facts: [SECCompanyFactRecord], dictionary: FinancialFieldDictionary,
                                 asOf cutoff: Date) throws -> FinancialNormalizationResult {
        guard cutoff.timeIntervalSince1970.isFinite else { throw ContractError.invalidTime }
        let cutoff = try MillisecondInstant(rounding: cutoff).date
        var selected: [SECCompanyFactRecord] = [], issues: [FinancialNormalizationIssue] = []
        for factID in Set(facts.map(\.factID)).sorted() {
            let versions = facts.filter { $0.factID == factID }
            try versions.forEach { try $0.provenance.validate() }
            let eligible = versions.compactMap { fact -> (SECCompanyFactRecord, Date)? in
                guard fact.provenance.isAvailable(asOf: cutoff), let date = try? fact.provenance.availability.upperBound() else { return nil }
                return (fact, date)
            }
            guard let latest = eligible.map(\.1).max() else {
                issues.append(.init(code: "future-or-unavailable", severity: .medium, factIDs: [factID],
                                    message: "No fact version was available at the requested cutoff."))
                continue
            }
            let current = eligible.filter { $0.1 == latest }
            guard current.count == 1 else {
                issues.append(.init(code: "ambiguous-revision", severity: .blocker,
                    factIDs: current.map { $0.0.recordID }.sorted(),
                    message: "Multiple fact revisions have the same latest availability evidence."))
                continue
            }
            selected.append(current[0].0)
        }

        var mapped: [NormalizedFinancialFact] = [], unmapped: [SECCompanyFactRecord] = []
        for fact in selected.sorted(by: { $0.recordID < $1.recordID }) {
            guard let rule = dictionary.rule(for: fact) else {
                unmapped.append(fact)
                issues.append(.init(code: "unmapped-concept", severity: .medium, factIDs: [fact.recordID],
                    message: "No exact reviewed taxonomy/concept/unit mapping exists."))
                continue
            }
            let period = classify(fact, nature: rule.nature)
            let upper = try fact.provenance.availability.upperBound()
            var limitations: [String] = []
            var confidence: FinancialConfidence = .high
            switch fact.provenance.availability {
            case .instant: break
            case .dateOnly:
                limitations.append("availability-known-to-day-only")
                confidence = .medium
            case .interval:
                limitations.append("availability-known-to-interval")
                confidence = .medium
            case .unknown:
                throw UnavailableReason.pitUnavailable
            }
            if period == .unclassified { limitations.append("unclassified-period"); confidence = .low }
            else if !rule.preferred {
                limitations.append("non-preferred-alias")
                if confidence == .high { confidence = .medium }
            }
            mapped.append(NormalizedFinancialFact(id: "normalized/" + fact.recordID,
                cik: fact.cik, fieldID: rule.fieldID, statement: rule.statement, nature: rule.nature,
                periodType: period, periodStart: fact.startDate, periodEnd: fact.endDate,
                fiscalYear: fact.fiscalYear, fiscalPeriod: fact.fiscalPeriod, unit: fact.unit,
                value: fact.value, sourceValue: fact.sourceValue, derivation: .reported,
                sourceFactIDs: [fact.factID], sourceVersions: [fact.provenance.versionID!],
                accessionNumbers: [fact.accessionNumber], dictionaryVersion: dictionary.version,
                availableAt: upper, confidence: confidence, limitations: limitations))
        }
        let collisions = resolveCollisions(mapped)
        issues.append(contentsOf: collisions.issues)
        return FinancialNormalizationResult(asOf: cutoff, dictionaryVersion: dictionary.version,
                                             values: collisions.values, issues: issues,
                                             selectedSourceFacts: selected, unmappedSourceFacts: unmapped)
    }

    /// Produces the complete normalization slice: reported values, supported discrete-quarter
    /// bridges, and the latest derivable TTM per additive field. Every derived value retains all
    /// source versions and the same reviewed dictionary version.
    public static func normalizeComplete(_ facts: [SECCompanyFactRecord], dictionary: FinancialFieldDictionary,
                                         asOf cutoff: Date) throws -> FinancialNormalizationResult {
        let reported = try normalize(facts, dictionary: dictionary, asOf: cutoff)
        let quarters = try discreteQuarters(from: reported.values)
        let derivedQuarters = quarters.values.filter { $0.derivation != .reported }
        let ttm = try trailingTwelveMonths(from: quarters.values)
        return FinancialNormalizationResult(asOf: reported.asOf, dictionaryVersion: reported.dictionaryVersion,
            values: (reported.values + derivedQuarters + ttm.values).sorted(by: financialOrder),
            issues: reported.issues + quarters.issues + ttm.issues,
            selectedSourceFacts: reported.selectedSourceFacts, unmappedSourceFacts: reported.unmappedSourceFacts)
    }

    /// Builds only the explicitly supported Q2/Q3/Q4 bridges from same-basis additive facts.
    public static func discreteQuarters(from values: [NormalizedFinancialFact]) throws
        -> (values: [NormalizedFinancialFact], issues: [FinancialNormalizationIssue]) {
        var output = values.filter { $0.periodType == .quarter && $0.nature == .additiveFlow }
        var issues: [FinancialNormalizationIssue] = []
        let missingYear = values.filter {
            $0.nature == .additiveFlow && $0.fiscalYear == nil && [.yearToDate, .annual].contains($0.periodType)
        }
        if !missingYear.isEmpty {
            issues.append(.init(code: "missing-fiscal-year", severity: .high,
                factIDs: missingYear.flatMap(\.sourceFactIDs).sorted(),
                message: "A fiscal year is required before cumulative periods can be bridged."))
        }
        let groups = Dictionary(grouping: values.filter { $0.nature == .additiveFlow && $0.fiscalYear != nil }) {
            [$0.cik, $0.fieldID, $0.unit, String($0.fiscalYear!), $0.dictionaryVersion].joined(separator: "|")
        }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let q1 = unique(group, fiscalPeriod: "Q1", type: .quarter)
            let q2YTD = unique(group, fiscalPeriod: "Q2", type: .yearToDate)
            let q3YTD = unique(group, fiscalPeriod: "Q3", type: .yearToDate)
            let annual = unique(group, fiscalPeriod: "FY", type: .annual)
            let q2 = unique(group, fiscalPeriod: "Q2", type: .quarter)
            let q3 = unique(group, fiscalPeriod: "Q3", type: .quarter)
            let q4 = unique(group, fiscalPeriod: "Q4", type: .quarter)
            if q2 == nil {
                if let q1, let q2YTD { output.append(try difference(q2YTD, minus: q1, derivation: .ytdDifference)) }
                else if has(group, fiscalPeriod: "Q2", type: .yearToDate) { issues.append(missingBridge("Q2", group: group)) }
            }
            if q3 == nil {
                if let q2YTD, let q3YTD { output.append(try difference(q3YTD, minus: q2YTD, derivation: .ytdDifference)) }
                else if has(group, fiscalPeriod: "Q3", type: .yearToDate) { issues.append(missingBridge("Q3", group: group)) }
            }
            if q4 == nil {
                if let q3YTD, let annual { output.append(try difference(annual, minus: q3YTD, derivation: .annualLessYTD)) }
                else if has(group, fiscalPeriod: "FY", type: .annual) { issues.append(missingBridge("Q4", group: group)) }
            }
        }
        return (output.sorted(by: financialOrder), issues)
    }

    /// Returns the latest TTM ending at or before `endingAt`. Four explicit, contiguous additive
    /// quarters are required. Per-share, instant, YTD and partial windows are never summed.
    public static func trailingTwelveMonths(from quarters: [NormalizedFinancialFact], endingAt: MarketDate? = nil) throws
        -> (values: [NormalizedFinancialFact], issues: [FinancialNormalizationIssue]) {
        let candidates = quarters.filter { $0.periodType == .quarter && $0.nature == .additiveFlow }
        let groups = Dictionary(grouping: candidates) {
            [$0.cik, $0.fieldID, $0.unit, $0.dictionaryVersion].joined(separator: "|")
        }
        var output: [NormalizedFinancialFact] = [], issues: [FinancialNormalizationIssue] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let sorted = group.filter { endingAt == nil || $0.periodEnd <= endingAt! }.sorted(by: financialOrder)
            guard sorted.count >= 4 else {
                issues.append(.init(code: "ttm-missing-quarter", severity: .high,
                    factIDs: sorted.flatMap(\.sourceFactIDs), message: "Four reported or derived quarters are required for TTM."))
                continue
            }
            var window: [NormalizedFinancialFact]?
            for endIndex in stride(from: sorted.count - 1, through: 3, by: -1) {
                let candidate = Array(sorted[(endIndex - 3)...endIndex])
                if try contiguous(candidate) { window = candidate; break }
            }
            guard let window else {
                issues.append(.init(code: "ttm-noncontiguous", severity: .high,
                    factIDs: sorted.flatMap(\.sourceFactIDs), message: "No four-quarter contiguous TTM window exists."))
                continue
            }
            var total = try Money("0")
            for item in window { total = try total.adding(item.value) }
            output.append(derived(idPrefix: "ttm", minuend: window.last!, subtrahend: nil,
                value: total, start: window.first!.periodStart, end: window.last!.periodEnd,
                period: .trailingTwelveMonths, derivation: .fourQuarterSum, inputs: window))
        }
        return (output.sorted(by: financialOrder), issues)
    }

    private static func classify(_ fact: SECCompanyFactRecord, nature: FinancialMetricNature) -> FinancialPeriodType {
        if fact.periodKind == .instant { return nature == .instant ? .instant : .unclassified }
        guard nature != .instant, let start = fact.startDate,
              let days = try? start.days(through: fact.endDate).count else { return .unclassified }
        let fp = fact.fiscalPeriod?.uppercased()
        if fact.form.hasPrefix("10-K"), fp == "FY", (300...400).contains(days) { return .annual }
        if fp == "Q1", (70...120).contains(days) { return .quarter }
        if ["Q2", "Q3"].contains(fp), (140...300).contains(days) { return .yearToDate }
        if ["Q1", "Q2", "Q3", "Q4"].contains(fp), (70...120).contains(days) { return .quarter }
        return .unclassified
    }

    private static func unique(_ values: [NormalizedFinancialFact], fiscalPeriod: String,
                               type: FinancialPeriodType) -> NormalizedFinancialFact? {
        let matches = values.filter { $0.fiscalPeriod?.uppercased() == fiscalPeriod && $0.periodType == type }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func has(_ values: [NormalizedFinancialFact], fiscalPeriod: String,
                            type: FinancialPeriodType) -> Bool {
        values.contains { $0.fiscalPeriod?.uppercased() == fiscalPeriod && $0.periodType == type }
    }
    private static func difference(_ total: NormalizedFinancialFact, minus prior: NormalizedFinancialFact,
                                   derivation: FinancialDerivation) throws -> NormalizedFinancialFact {
        guard total.cik == prior.cik, total.fieldID == prior.fieldID, total.unit == prior.unit,
              total.dictionaryVersion == prior.dictionaryVersion, total.periodStart == prior.periodStart,
              prior.periodEnd < total.periodEnd else { throw FinancialNormalizationError.incompatiblePeriod }
        return derived(idPrefix: derivation == .annualLessYTD ? "q4" : "quarter",
            minuend: total, subtrahend: prior, value: try total.value.subtracting(prior.value),
            start: try prior.periodEnd.addingDays(1), end: total.periodEnd, period: .quarter,
            derivation: derivation, inputs: [total, prior])
    }
    private static func derived(idPrefix: String, minuend: NormalizedFinancialFact,
        subtrahend: NormalizedFinancialFact?, value: Money, start: MarketDate?, end: MarketDate,
        period: FinancialPeriodType, derivation: FinancialDerivation,
        inputs: [NormalizedFinancialFact]) -> NormalizedFinancialFact {
        let identity = [minuend.cik, minuend.fieldID, minuend.unit, minuend.dictionaryVersion,
                        start?.iso8601 ?? "instant", end.iso8601, period.rawValue]
            .joined(separator: "|") + "|" + inputs.flatMap(\.sourceVersions).sorted().joined(separator: "|")
        let inputLimitations = Array(Set(inputs.flatMap(\.limitations))).sorted()
        let derivedConfidence: FinancialConfidence = inputs.contains { $0.confidence == .low } ? .low : .medium
        return NormalizedFinancialFact(id: idPrefix + "/" + String(digest(Data(identity.utf8)).prefix(24)),
            cik: minuend.cik, fieldID: minuend.fieldID, statement: minuend.statement,
            nature: minuend.nature, periodType: period, periodStart: start, periodEnd: end,
            fiscalYear: minuend.fiscalYear, fiscalPeriod: period == .quarter ? inferredQuarter(end, inputs: inputs) : "TTM",
            unit: minuend.unit, value: value, sourceValue: nil, derivation: derivation,
            sourceFactIDs: Array(Set(inputs.flatMap(\.sourceFactIDs))).sorted(),
            sourceVersions: Array(Set(inputs.flatMap(\.sourceVersions))).sorted(),
            accessionNumbers: Array(Set(inputs.flatMap(\.accessionNumbers))).sorted(),
            dictionaryVersion: minuend.dictionaryVersion,
            availableAt: inputs.map(\.availableAt).max()!, confidence: derivedConfidence,
            limitations: Array(Set(inputLimitations + ["derived-from-explicit-periods"])).sorted())
    }
    private static func inferredQuarter(_ end: MarketDate, inputs: [NormalizedFinancialFact]) -> String? {
        if inputs.contains(where: { $0.fiscalPeriod?.uppercased() == "FY" }) { return "Q4" }
        if inputs.contains(where: { $0.fiscalPeriod?.uppercased() == "Q3" }) { return "Q3" }
        if inputs.contains(where: { $0.fiscalPeriod?.uppercased() == "Q2" }) { return "Q2" }
        return nil
    }
    private static func contiguous(_ values: [NormalizedFinancialFact]) throws -> Bool {
        guard values.count == 4, values.allSatisfy({ $0.periodStart != nil }) else { return false }
        for pair in zip(values, values.dropFirst()) {
            guard try pair.0.periodEnd.addingDays(1) == pair.1.periodStart else { return false }
        }
        return true
    }
    private static func missingBridge(_ quarter: String, group: [NormalizedFinancialFact]) -> FinancialNormalizationIssue {
        .init(code: "missing-ytd-bridge", severity: .high, factIDs: group.flatMap(\.sourceFactIDs),
              message: quarter + " cannot be derived without the required preceding cumulative period.")
    }
    private static func resolveCollisions(_ values: [NormalizedFinancialFact])
        -> (values: [NormalizedFinancialFact], issues: [FinancialNormalizationIssue]) {
        let groups = Dictionary(grouping: values) { value in
            return [value.cik, value.fieldID, value.unit, value.periodStart?.iso8601 ?? "instant", value.periodEnd.iso8601]
                .joined(separator: "|")
        }
        var output: [NormalizedFinancialFact] = [], issues: [FinancialNormalizationIssue] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            guard group.count > 1 else { output.append(group[0]); continue }
            let distinct = Set(group.map { $0.value.decimalString })
            if distinct.count > 1 {
                issues.append(.init(code: "mapping-conflict", severity: .blocker,
                    factIDs: group.flatMap(\.sourceFactIDs).sorted(),
                    message: "Conflicting source concepts map to one field and period; no canonical value was selected."))
            } else {
                let selected = group.sorted {
                    let lhsAlias = $0.limitations.contains("non-preferred-alias")
                    let rhsAlias = $1.limitations.contains("non-preferred-alias")
                    return lhsAlias == rhsAlias ? $0.id < $1.id : !lhsAlias
                }[0]
                output.append(selected)
                issues.append(.init(code: "equivalent-mapping-deduplicated", severity: .low,
                    factIDs: group.flatMap(\.sourceFactIDs).sorted(),
                    message: "Equivalent aliases mapped to one value; the reviewed preferred mapping was retained."))
            }
        }
        return (output.sorted(by: financialOrder), issues)
    }
    private static func financialOrder(_ lhs: NormalizedFinancialFact, _ rhs: NormalizedFinancialFact) -> Bool {
        lhs.periodEnd == rhs.periodEnd ? lhs.id < rhs.id : lhs.periodEnd < rhs.periodEnd
    }
}
