import Foundation
import CoreDomain
import DataContracts

public enum SECFinancialError: Error, Equatable {
    case insufficientPeriods, ambiguousPeriods, inconsistentEvidence, unsupportedFormat
}

/// An observed SEC SIC is retained as evidence, not a reviewed financial-industry classification.
/// This version never infers model applicability from the numeric SIC range.
public struct SECFinancialClassificationEvidence: Sendable, Codable, Equatable {
    public let sic: Int
    public let sourceReference, sourceVersion, sourceHash: String
    public init(sic: Int, sourceReference: String, sourceVersion: String, sourceHash: String) throws {
        guard (100...9999).contains(sic), !sourceReference.isEmpty, !sourceVersion.isEmpty,
              sourceHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SECFinancialError.inconsistentEvidence
        }
        self.sic = sic; self.sourceReference = sourceReference; self.sourceVersion = sourceVersion; self.sourceHash = sourceHash
    }
    func validate() throws {
        _ = try Self(sic: sic, sourceReference: sourceReference, sourceVersion: sourceVersion, sourceHash: sourceHash)
    }
}

/// Compact evidence for this report. Raw source bytes remain with the immutable parent SEC document.
/// The parent must reconstruct this selection from all of its retained records, so omitted conflicts
/// or newer incomplete periods cannot be hidden by supplying a convenient subset.
public struct SECFinancialEvidence: Sendable, Codable {
    public let cik: String
    public let cutoff: Date
    public let facts: [SECCompanyFactRecord]
    public let submissions: [SECSubmissionRecord]
    public let quarters: [FiscalQuarter]
    public let fiscalYears: [FiscalYearWindow]
    public let revenueYears: [FiscalYearWindow]
    public let classification: SECFinancialClassificationEvidence?
    public var classificationStatus: String { "unknown-not-an-applicability-grant" }
}

struct SECFinancialPrepared {
    let evidence: SECFinancialEvidence
    let input: FundamentalCompletionInput
}

/// Exact-date period adapter. Company Facts fy/fp and calendar frame labels are not geometry.
/// Full years need an annual mapped fact and a matching 10-K report date. Quarter boundaries need
/// 10-Q report dates, exact source-period support and the 70...120-day model contract. No latest
/// complete period fallback is permitted when a newer reported period is incomplete or ambiguous.
enum SECFinancialEvidenceAdapter {
    static let limitations = ["SEC_ACCOUNTING_RESEARCH_ONLY", "NO_PRICE_CAPITAL_OR_SPLIT_BASIS",
        "INDUSTRY_APPLICABILITY_UNKNOWN", "SIC_IS_OBSERVED_METADATA_NOT_MODEL_CLASSIFICATION",
        "SOURCE_FY_FP_NOT_USED_AS_PERIOD_GEOMETRY", "NO_HISTORICAL_PIT_OR_SUPPLIER_ELIGIBILITY_GRANT"]

    static func prepare(cik: String, facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord],
                        cutoff: Date, classification: SECFinancialClassificationEvidence?) throws -> SECFinancialPrepared {
        guard SECCompanyIdentityRecord.validCIK(cik), cutoff.timeIntervalSince1970.isFinite,
              facts.allSatisfy({ $0.cik == cik }), submissions.allSatisfy({ $0.cik == cik }) else {
            throw SECFinancialError.inconsistentEvidence
        }
        try classification?.validate()
        let dictionary = try FinancialFieldDictionary.fundamentalsCompletionV1()
        let usableSubmissions = submissions.filter {
            ["10-K", "10-K/A", "10-Q", "10-Q/A"].contains($0.form)
                && $0.reportDate != nil && $0.provenance.isAvailable(asOf: cutoff)
                && ((try? $0.reportDate!.start(in: TimeZone(secondsFromGMT: 0)!)) ?? .distantFuture) <= cutoff
        }.sorted { $0.recordID < $1.recordID }
        guard Set(usableSubmissions.map(\.recordID)).count == usableSubmissions.count else {
            throw SECFinancialError.inconsistentEvidence
        }
        let annualEnds = Set(usableSubmissions.filter { $0.form.hasPrefix("10-K") }.compactMap(\.reportDate))
        let quarterlyEnds = Set(usableSubmissions.filter { $0.form.hasPrefix("10-Q") }.compactMap(\.reportDate))
        guard let latestEnd = usableSubmissions.compactMap(\.reportDate).max() else { throw SECFinancialError.insufficientPeriods }
        // Keep every available version/alias in the relevant mapped range. Re-normalization must
        // retain ambiguous revision and conflicting mapping behavior instead of selecting a winner.
        let eligible = facts.filter { dictionary.rule(for: $0) != nil && $0.provenance.isAvailable(asOf: cutoff) && $0.endDate <= latestEnd }
        let reported = try FinancialNormalizer.normalize(eligible, dictionary: dictionary, asOf: cutoff)
        var yearCandidates: [MarketDate: Set<MarketDate>] = [:]
        for fact in reported.selectedSourceFacts where fact.form.hasPrefix("10-K") && annualEnds.contains(fact.endDate) {
            guard let start = fact.startDate, dictionary.rule(for: fact)?.nature == .additiveFlow,
                  (try? FiscalYearWindow(start: start, end: fact.endDate)) != nil else { continue }
            yearCandidates[fact.endDate, default: []].insert(start)
        }
        guard !yearCandidates.isEmpty else { throw SECFinancialError.insufficientPeriods }
        // Transition years or multiple incompatible annual starts cannot select arbitrary geometry.
        guard yearCandidates.values.allSatisfy({ $0.count == 1 }) else { throw SECFinancialError.ambiguousPeriods }
        let years = try yearCandidates.keys.sorted().map { try FiscalYearWindow(start: yearCandidates[$0]!.first!, end: $0) }
        var yearQuarters: [(FiscalYearWindow, [FiscalQuarter])] = []
        // Eight quarters need only the two latest complete years plus the partial year below.
        // Older annual sources remain available for the unchanged tax and growth inputs.
        for year in years.suffix(2) {
            let ends = quarterlyEnds.filter { $0 >= year.start && $0 < year.end }.sorted()
            guard ends.count <= 3 else { throw SECFinancialError.ambiguousPeriods }
            guard ends.count == 3 else { continue }
            let qs = try windows(start: year.start, ends: ends + [year.end])
            guard qs.allSatisfy({ supported($0, yearStart: year.start, reported: reported.values) }) else { continue }
            yearQuarters.append((year, qs))
        }
        var allQuarters = yearQuarters.flatMap { $0.1 }
        if let lastYear = years.last {
            let start = try lastYear.end.addingDays(1)
            let ends = quarterlyEnds.filter { $0 > lastYear.end }.sorted()
            guard ends.count <= 3 else { throw SECFinancialError.insufficientPeriods }
            if !ends.isEmpty {
                let qs = try windows(start: start, ends: ends)
                if qs.allSatisfy({ supported($0, yearStart: start, reported: reported.values) }) { allQuarters += qs }
            }
        }
        allQuarters.sort { $0.end < $1.end }
        guard allQuarters.last?.end == latestEnd else { throw SECFinancialError.insufficientPeriods }
        var trailing: [FiscalQuarter] = []
        for q in allQuarters.reversed() {
            if let next = trailing.first, try q.end.addingDays(1) != next.start { break }
            trailing.insert(q, at: 0)
            if trailing.count == 8 { break }
        }
        guard trailing.count >= 4 else { throw SECFinancialError.insufficientPeriods }
        var consecutiveYears: [FiscalYearWindow] = []
        for year in years.filter({ $0.end <= latestEnd }).reversed() {
            if let next = consecutiveYears.first, try year.end.addingDays(1) != next.start { break }
            consecutiveYears.insert(year, at: 0)
            if consecutiveYears.count == 6 { break }
        }
        let fiscalYears = Array(consecutiveYears.suffix(3))
        let lower = min(consecutiveYears.first?.start ?? trailing[0].start, try trailing[0].start.addingDays(-1))
        let compactFacts = eligible.filter { $0.endDate >= lower && ($0.startDate.map { $0 >= lower } ?? true) }
            .sorted { $0.recordID < $1.recordID }
        guard Set(compactFacts.map(\.recordID)).count == compactFacts.count else { throw SECFinancialError.inconsistentEvidence }
        let compactReported = try FinancialNormalizer.normalize(compactFacts, dictionary: dictionary, asOf: cutoff)
        let normalized = try normalize(compactReported, quarters: trailing, years: consecutiveYears, allYears: years)
        let input = try FundamentalInput(cik: cik, normalization: normalized, quarters: trailing, fiscalYears: fiscalYears,
            priceDay: latestEnd, expectedClassIDs: [], classes: [], financialCompany: true,
            splitBasisEvidence: nil, inputLimitations: limitations + ["FINANCIAL_COMPANY_BOOL_IS_CONSERVATIVE_SUPPRESSION_NOT_CLASSIFICATION"])
        let evidence = SECFinancialEvidence(cik: cik, cutoff: cutoff, facts: compactFacts, submissions: usableSubmissions,
            quarters: trailing, fiscalYears: fiscalYears, revenueYears: consecutiveYears, classification: classification)
        return SECFinancialPrepared(evidence: evidence, input: try .init(financials: input, revenueYears: consecutiveYears))
    }

    private static func windows(start: MarketDate, ends: [MarketDate]) throws -> [FiscalQuarter] {
        var previous = start
        return try ends.map { end in
            guard let quarter = try? FiscalQuarter(start: previous, end: end) else { throw SECFinancialError.ambiguousPeriods }
            previous = try end.addingDays(1)
            return quarter
        }
    }
    private static func supported(_ quarter: FiscalQuarter, yearStart: MarketDate, reported: [NormalizedFinancialFact]) -> Bool {
        reported.contains { $0.nature == .additiveFlow && $0.periodEnd == quarter.end
            && ($0.periodStart == quarter.start || $0.periodStart == yearStart) }
    }
    private static func normalize(_ reported: FinancialNormalizationResult, quarters: [FiscalQuarter],
                                  years: [FiscalYearWindow], allYears: [FiscalYearWindow]) throws -> FinancialNormalizationResult {
        let instantDays = Set(quarters.map(\.end) + [try quarters[0].start.addingDays(-1)])
        let rows = reported.values
        var output: [NormalizedFinancialFact] = []
        for row in rows {
            if row.nature == .instant && instantDays.contains(row.periodEnd) { output.append(copy(row, type: .instant)); continue }
            if years.contains(where: { $0.start == row.periodStart && $0.end == row.periodEnd }) {
                output.append(copy(row, type: .annual, fiscalPeriod: "FY")); continue
            }
            if quarters.contains(where: { $0.start == row.periodStart && $0.end == row.periodEnd }) {
                output.append(copy(row, type: .quarter)); continue
            }
        }
        let fields = Set(rows.filter { $0.nature == .additiveFlow }.map(\.fieldID))
        for q in quarters {
            let yearStart: MarketDate
            if let year = allYears.first(where: { $0.start <= q.start && q.end <= $0.end }) { yearStart = year.start }
            else if let last = allYears.last, q.start > last.end { yearStart = try last.end.addingDays(1) }
            else { continue }
            for field in fields.sorted() {
                guard !output.contains(where: { $0.fieldID == field && $0.periodType == .quarter && $0.periodStart == q.start && $0.periodEnd == q.end }) else { continue }
                let totals = rows.filter { $0.fieldID == field && $0.nature == .additiveFlow && $0.periodStart == yearStart && $0.periodEnd == q.end }
                let priors = rows.filter { $0.fieldID == field && $0.nature == .additiveFlow && $0.periodStart == yearStart && $0.periodEnd == (try? q.start.addingDays(-1)) }
                guard totals.count == 1, priors.count == 1, totals[0].unit == priors[0].unit else { continue }
                output.append(try difference(totals[0], priors[0], quarter: q,
                    annual: allYears.contains { $0.end == q.end }))
            }
        }
        return FinancialNormalizationResult(asOf: reported.asOf, dictionaryVersion: reported.dictionaryVersion,
            values: output.sorted { $0.periodEnd == $1.periodEnd ? $0.id < $1.id : $0.periodEnd < $1.periodEnd },
            issues: reported.issues, selectedSourceFacts: [], unmappedSourceFacts: [])
    }
    private static func copy(_ value: NormalizedFinancialFact, type: FinancialPeriodType,
                             fiscalPeriod: String? = nil) -> NormalizedFinancialFact {
        NormalizedFinancialFact(id: "sec-period/" + value.id, cik: value.cik, fieldID: value.fieldID, statement: value.statement,
            nature: value.nature, periodType: type, periodStart: value.periodStart, periodEnd: value.periodEnd,
            fiscalYear: nil, fiscalPeriod: fiscalPeriod, unit: value.unit, value: value.value,
            sourceValue: value.sourceValue, derivation: value.derivation, sourceFactIDs: value.sourceFactIDs,
            sourceVersions: value.sourceVersions, accessionNumbers: value.accessionNumbers,
            dictionaryVersion: value.dictionaryVersion, availableAt: value.availableAt, confidence: .medium,
            limitations: Array(Set(value.limitations.filter { $0 != "unclassified-period" } + ["SEC_EXACT_PERIOD_EVIDENCE"])).sorted())
    }
    private static func difference(_ total: NormalizedFinancialFact, _ prior: NormalizedFinancialFact,
                                   quarter: FiscalQuarter, annual: Bool) throws -> NormalizedFinancialFact {
        let refs = Array(Set(total.sourceVersions + prior.sourceVersions)).sorted()
        let id = [total.fieldID, quarter.start.iso8601, quarter.end.iso8601] + refs
        return NormalizedFinancialFact(id: "sec-quarter/" + digest(Data(id.joined(separator: "|").utf8)),
            cik: total.cik, fieldID: total.fieldID, statement: total.statement, nature: .additiveFlow,
            periodType: .quarter, periodStart: quarter.start, periodEnd: quarter.end, fiscalYear: nil, fiscalPeriod: nil,
            unit: total.unit, value: try total.value.subtracting(prior.value), sourceValue: nil,
            derivation: annual ? .annualLessYTD : .ytdDifference,
            sourceFactIDs: Array(Set(total.sourceFactIDs + prior.sourceFactIDs)).sorted(), sourceVersions: refs,
            accessionNumbers: Array(Set(total.accessionNumbers + prior.accessionNumbers)).sorted(),
            dictionaryVersion: total.dictionaryVersion, availableAt: max(total.availableAt, prior.availableAt), confidence: .medium,
            limitations: Array(Set(total.limitations.filter { $0 != "unclassified-period" } + prior.limitations.filter { $0 != "unclassified-period" }
                + ["SEC_EXACT_PERIOD_EVIDENCE", "derived-from-explicit-periods"])).sorted())
    }
}
