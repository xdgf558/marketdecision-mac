import Foundation
import CoreDomain
import DataContracts

public enum SECValuationGap: String, Sendable, Codable, CaseIterable {
    case industryMissing, industryNotApplicable, classUniverseMissing, splitBasisMissing
    case priceSourceMissing, incompleteClassPrices, historicalValuationUnavailable
    case localHumanInterpretation, capturedReferenceOnly, syntheticReferenceOnly
}
public struct SECValuationAssessment: Sendable, Codable, Equatable {
    public let industry: SECIndustryApplicability
    public let gaps: [SECValuationGap]
    public let referenceAt: Date?
    public let accountingCutoff: Date
    public let currentReferenceCapitalAvailable: Bool
    public let perShareBasisAvailable: Bool
    public let researchOnly, referenceScenarioOnly, historicalPITQualified, productionEligible: Bool
}
public struct SECValuationRecomputation: Sendable, Codable {
    public let base: FundamentalReport
    public let growth: FundamentalGrowthReport
    public let completion: FundamentalCompletionReport
    public let score: FundamentalScore?
    public let reference: SECValuationReferenceResult?
}

/// Separate local arithmetic scenario. It never enters FundamentalInput capital, historical
/// valuation, or scoring. No synthetic provenance or availability upgrade is constructed.
public struct SECValuationReferenceResult: Sendable, Codable {
    public let referenceAt, accountingCutoff: Date
    public let formulaModel, parameters: RegistryReference
    public let metrics: [String: FundamentalMetric]
    public let limitations: [String]
}

/// A new local review/scenario envelope, not an upgrade of the immutable accounting report.
/// All cached numbers remain unverified until explicit replay. Original market records keep
/// unknown availability; only local possession enters a separate captured-reference adapter.
public struct SECValuationReport: Sendable, Codable {
    public static let formatVersion = "sec-valuation-supplement.v1"
    public static let policyVersion = "sec-local-review-captured-reference.v1"
    public let format, evidencePolicy: String
    public let accounting: SECFinancialReport
    public let evidence: SECValuationInputEvidence
    public let executionDate: Date
    public let assessment: SECValuationAssessment
    public let inputSnapshot: FundamentalCompletionSnapshot
    public let results: SECValuationRecomputation
    public let cacheState: String
    public var cutoff: Date { accounting.cutoff }
    public var researchOnly: Bool { true }
    public var historicalPITQualified: Bool { false }
    public var productionEligible: Bool { false }
    public var referenceScenarioOnly: Bool { true }

    private init(accounting: SECFinancialReport, evidence: SECValuationInputEvidence, executionDate: Date,
                 prepared: Prepared, results: SECValuationRecomputation) throws {
        format = Self.formatVersion; evidencePolicy = Self.policyVersion; self.accounting = accounting
        self.evidence = evidence; self.executionDate = executionDate; assessment = prepared.assessment
        inputSnapshot = try FundamentalCompletionSnapshot(input: prepared.input, executionDate: executionDate)
        self.results = results; cacheState = "requires-explicit-recompute"
    }
    public static func make(accounting: SECFinancialReport, evidence: SECValuationInputEvidence,
                            sources: [SECValuationSourceMaterial], executionDate: Date) async throws -> Self {
        try accounting.validate(); try evidence.validateSources(sources); try Task.checkCancellation()
        let replay = try await accounting.recompute()
        guard try accounting.cachedReportsMatch(replay) else { throw SECValuationError.incompatibleAccounting }
        let prepared = try prepare(accounting: accounting, evidence: evidence, executionDate: executionDate)
        let results = try await calculate(prepared: prepared, accounting: accounting, executionDate: executionDate)
        let report = try Self(accounting: accounting, evidence: evidence, executionDate: executionDate,
                              prepared: prepared, results: results)
        try report.validate(); return report
    }
    public func validateAccounting(_ value: SECFinancialReport) throws {
        try validate()
        guard try SECFinancialReport.bytes(accounting) == SECFinancialReport.bytes(value) else {
            throw SECValuationError.incompatibleAccounting
        }
    }
    public func validateSources(_ sources: [SECValuationSourceMaterial]) throws { try evidence.validateSources(sources) }
    public func validate() throws {
        guard format == Self.formatVersion, evidencePolicy == Self.policyVersion,
              cacheState == "requires-explicit-recompute" else { throw SECValuationError.unsupportedFormat }
        try accounting.validate()
        let prepared = try Self.prepare(accounting: accounting, evidence: evidence, executionDate: executionDate)
        let snapshot = try FundamentalCompletionSnapshot(input: prepared.input, executionDate: executionDate)
        guard assessment == prepared.assessment,
              try SECFinancialReport.bytes(snapshot) == SECFinancialReport.bytes(inputSnapshot),
              try SECFinancialReport.bytes(results.base.inputSnapshot) == SECFinancialReport.bytes(snapshot.financials),
              try SECFinancialReport.bytes(results.growth.inputSnapshot) == SECFinancialReport.bytes(snapshot.financials),
              try SECFinancialReport.bytes(results.completion.inputSnapshot) == SECFinancialReport.bytes(snapshot),
              results.base.model == accounting.models[0].reference,
              results.growth.model == accounting.models[1].reference,
              results.completion.model == accounting.models[2].reference,
              [results.base.parameters, results.growth.parameters, results.completion.parameters].allSatisfy({ $0 == accounting.parameters.reference }),
              results.base.researchOnly, results.growth.researchOnly, results.completion.researchOnly,
              (results.score != nil) == (assessment.industry == .generalNonFinancial),
              inputSnapshot.financials.input.classes.isEmpty,
              inputSnapshot.financials.input.normalization.asOf == accounting.cutoff,
              (results.reference != nil) == assessment.currentReferenceCapitalAvailable
        else { throw SECValuationError.invalidEvidence }
        if let reference = results.reference {
            guard reference.referenceAt == assessment.referenceAt, reference.accountingCutoff == accounting.cutoff,
                  reference.formulaModel == accounting.models[0].reference, reference.parameters == accounting.parameters.reference else {
                throw SECValuationError.invalidEvidence
            }
        }
        if let score = results.score {
            guard score.valuation.historyInputs.isEmpty,
                  try SECFinancialReport.bytes(score.valuation.current.inputSnapshot) == SECFinancialReport.bytes(snapshot.financials),
                  score.valuation.metrics.values.allSatisfy({ $0.validDays == 0 && $0.prices.isEmpty && $0.scorePercentile == nil && $0.rangePercentile == nil })
            else { throw SECValuationError.invalidEvidence }
        }
        if assessment.industry != .generalNonFinancial {
            let reason: FundamentalMissing = assessment.industry == .unknown ? .missingEvidence : .notApplicable
            for key in ["roic", "netDebtEBITDA"] {
                guard results.base.metrics[key]?.value == nil, results.base.metrics[key]?.unavailable == reason else {
                    throw SECValuationError.invalidEvidence
                }
            }
        }
    }
    public func recompute() async throws -> SECValuationRecomputation {
        try validate(); try Task.checkCancellation()
        let original = try await accounting.recompute()
        guard try accounting.cachedReportsMatch(original) else { throw SECValuationError.incompatibleAccounting }
        return try await Self.calculate(prepared: Self.prepare(accounting: accounting, evidence: evidence, executionDate: executionDate),
                                        accounting: accounting, executionDate: executionDate)
    }
    public func cachedReportMatches(_ replay: SECValuationRecomputation) throws -> Bool {
        try SECFinancialReport.bytes(results) == SECFinancialReport.bytes(replay)
    }
    private struct ReferenceClass { let classID: String; let price, shares: Money }
    private struct Prepared {
        let input: FundamentalCompletionInput
        let assessment: SECValuationAssessment
        let referenceClasses: [ReferenceClass]
    }
    private static func prepare(accounting: SECFinancialReport, evidence: SECValuationInputEvidence,
                                executionDate: Date) throws -> Prepared {
        guard executionDate.timeIntervalSince1970.isFinite, accounting.executionDate <= executionDate else {
            throw SECValuationError.invalidEvidence
        }
        try evidence.validate(accounting: accounting, executionDate: executionDate)
        let old = accounting.inputSnapshot.financials.input
        let industry = evidence.industryReview?.applicability ?? .unknown
        var gaps: [SECValuationGap] = [.historicalValuationUnavailable]
        if industry == .unknown { gaps.append(.industryMissing) }
        else if industry != .generalNonFinancial { gaps.append(.industryNotApplicable) }
        if evidence.industryReview != nil || evidence.shareClasses != nil || evidence.splitBasis != nil { gaps.append(.localHumanInterpretation) }
        if evidence.shareClasses == nil { gaps.append(.classUniverseMissing) }
        if evidence.splitBasis == nil { gaps.append(.splitBasisMissing) }
        if evidence.prices.isEmpty { gaps.append(.priceSourceMissing) }
        let currentClasses = evidence.shareClasses?.classes ?? []
        let priceIDs = Set(evidence.prices.map(\.classID))
        let expectedIDs = Set(currentClasses.map(\.classID))
        guard priceIDs.isSubset(of: expectedIDs) else { throw SECValuationError.invalidEvidence }
        for price in evidence.prices {
            guard currentClasses.contains(where: { $0.classID == price.classID && $0.symbol == price.record.symbol }) else {
                throw SECValuationError.invalidEvidence
            }
        }
        let referenceAt = evidence.prices.map(\.capturedAt).max()
        let priceDays = Set(evidence.prices.compactMap { $0.record.provenance.observationDate })
        guard priceDays.count <= 1, Set(evidence.prices.map { $0.record.provenance.providerID + "/" + $0.record.provenance.feedID }).count <= 1,
              referenceAt.map({ $0 >= accounting.cutoff }) ?? true else { throw SECValuationError.invalidEvidence }
        if let referenceAt {
            guard evidence.prices.allSatisfy({ $0.record.quality(at: referenceAt).isEmpty }) else { throw SECValuationError.unsupportedPrice }
            gaps.append(.capturedReferenceOnly)
        }
        if evidence.prices.contains(where: { $0.captureOrigin == .syntheticFixture }) { gaps.append(.syntheticReferenceOnly) }
        if !evidence.prices.isEmpty && priceIDs != expectedIDs { gaps.append(.incompleteClassPrices) }
        let priceDay = priceDays.first ?? old.priceDay
        if !evidence.prices.isEmpty, let shareDay = evidence.shareClasses?.coverDate {
            guard shareDay <= priceDay, let split = evidence.splitBasis, split.basisDate == priceDay else {
                // Missing split proof with a real quote remains a gap; contradictory supplied proof fails.
                if evidence.splitBasis != nil { throw SECValuationError.invalidEvidence }
                return try preparedWithoutPrices(accounting: accounting, evidence: evidence, industry: industry,
                    gaps: gaps, referenceAt: referenceAt, executionDate: executionDate)
            }
        }
        let capitalReady = industry == .generalNonFinancial && !expectedIDs.isEmpty && priceIDs == expectedIDs && evidence.splitBasis != nil
        let perShareReady = evidence.splitBasis != nil && currentClasses.count == 1
        var classes: [ReferenceClass] = []
        if capitalReady {
            for share in currentClasses.sorted(by: { $0.classID < $1.classID }) {
                guard let price = evidence.prices.first(where: { $0.classID == share.classID }), price.record.symbol == share.symbol, let selectedPrice = price.selectedPrice else {
                    throw SECValuationError.invalidEvidence
                }
                classes.append(ReferenceClass(classID: share.classID, price: selectedPrice, shares: share.outstandingShares))
            }
        }
        return try assemble(accounting: accounting, evidence: evidence, industry: industry, gaps: gaps,
            referenceAt: referenceAt, priceDay: capitalReady ? priceDay : old.priceDay,
            classes: classes, perShareReady: perShareReady, executionDate: executionDate)
    }
    private static func preparedWithoutPrices(accounting: SECFinancialReport, evidence: SECValuationInputEvidence,
        industry: SECIndustryApplicability, gaps: [SECValuationGap], referenceAt: Date?, executionDate: Date) throws -> Prepared {
        try assemble(accounting: accounting, evidence: evidence, industry: industry, gaps: gaps, referenceAt: referenceAt,
            priceDay: accounting.inputSnapshot.financials.input.priceDay, classes: [], perShareReady: false, executionDate: executionDate)
    }
    private static func assemble(accounting: SECFinancialReport, evidence: SECValuationInputEvidence,
                                 industry: SECIndustryApplicability, gaps: [SECValuationGap], referenceAt: Date?,
                                 priceDay: MarketDate, classes: [ReferenceClass], perShareReady: Bool,
                                 executionDate: Date) throws -> Prepared {
        let old = accounting.inputSnapshot.financials.input
        // Preserve the original accounting cutoff and never inject market references into a
        // FundamentalInput. The separate reference result performs only scenario arithmetic.
        let normalization = old.normalization
        let removed: Set<String> = ["INDUSTRY_APPLICABILITY_UNKNOWN", "FINANCIAL_COMPANY_BOOL_IS_CONSERVATIVE_SUPPRESSION_NOT_CLASSIFICATION", "NO_PRICE_CAPITAL_OR_SPLIT_BASIS"]
        let limitations = old.inputLimitations.filter { !removed.contains($0) } + [
            "LOCAL_HUMAN_INTERPRETATION_NOT_SEC_CERTIFICATION", "FROZEN_ACCOUNTING_CUTOFF_NOT_REFRESHED",
            "NO_HISTORICAL_PIT_OR_PRODUCTION_ELIGIBILITY", "NO_HISTORICAL_PRICE_SAMPLES_SUPPLIED",
            "CAPTURED_BID_OR_ASK_REFERENCE_NOT_FAIR_VALUE", "NO_SPLIT_CONVERSION_APPLIED"]
            + (industry == .unknown ? ["INDUSTRY_APPLICABILITY_UNKNOWN"] : [])
            + (classes.isEmpty ? ["NO_REFERENCE_CAPITAL_EVIDENCE"] : [])
            + (evidence.prices.contains(where: { $0.captureOrigin == .syntheticFixture }) ? ["SYNTHETIC_REFERENCE_NOT_MARKET_DATA"] : [])
        let input = try FundamentalInput(cik: old.cik, normalization: normalization, quarters: old.quarters,
            fiscalYears: old.fiscalYears, priceDay: old.priceDay,
            expectedClassIDs: Set(evidence.shareClasses?.classes.map(\.classID) ?? []), classes: [],
            financialCompany: industry != .generalNonFinancial,
            splitBasisEvidence: perShareReady ? "as-reported-common-basis/" + digest(try SECFinancialReport.bytes(evidence.splitBasis!)) : nil,
            inputLimitations: Array(Set(limitations)).sorted())
        let assessment = SECValuationAssessment(industry: industry, gaps: Array(Set(gaps)).sorted { $0.rawValue < $1.rawValue },
            referenceAt: referenceAt, accountingCutoff: accounting.cutoff,
            currentReferenceCapitalAvailable: !classes.isEmpty, perShareBasisAvailable: perShareReady,
            researchOnly: true, referenceScenarioOnly: true, historicalPITQualified: false, productionEligible: false)
        return try .init(input: .init(financials: input, revenueYears: accounting.inputSnapshot.revenueYears), assessment: assessment, referenceClasses: classes)
    }
    private static func calculate(prepared: Prepared, accounting: SECFinancialReport, executionDate: Date) async throws -> SECValuationRecomputation {
        let registry = ModelRegistry(); try await registry.register(accounting.parameters)
        for definition in accounting.models { try await registry.register(definition) }
        let baseModel = try await registry.resolve(reference: accounting.models[0].reference, at: executionDate)
        let growthModel = try await registry.resolve(reference: accounting.models[1].reference, at: executionDate)
        let completionModel = try await registry.resolve(reference: accounting.models[2].reference, at: executionDate)
        let input = prepared.input.financials
        let raw = try FundamentalCalculator.calculate(input, model: baseModel, executionDate: executionDate)
        var metrics = raw.metrics
        if prepared.assessment.industry == .unknown {
            for key in ["roic", "netDebtEBITDA"] { metrics[key] = .init(nil, reason: .missingEvidence, flags: ["INDUSTRY_APPLICABILITY_UNKNOWN"]) }
        }
        let base = FundamentalReport(inputSnapshot: raw.inputSnapshot, model: raw.model, parameters: raw.parameters,
            limitations: raw.limitations, metrics: metrics, confidence: raw.confidence, researchOnly: true)
        try Task.checkCancellation()
        return try .init(base: base,
            growth: FundamentalGrowthCalculator.calculate(input, model: growthModel, executionDate: executionDate),
            completion: FundamentalCompletionCalculator.calculate(prepared.input, model: completionModel, executionDate: executionDate),
            score: prepared.assessment.industry == .generalNonFinancial
                ? FundamentalScoring.calculate(input, history: [], model: baseModel, executionDate: executionDate) : nil,
            reference: referenceResult(prepared: prepared, base: base, accounting: accounting))
    }
    private static func referenceResult(prepared: Prepared, base: FundamentalReport, accounting: SECFinancialReport) throws -> SECValuationReferenceResult? {
        guard !prepared.referenceClasses.isEmpty, let referenceAt = prepared.assessment.referenceAt else { return nil }
        let input = prepared.input.financials, m = base.metrics
        let cap = try fsum(prepared.referenceClasses.map { try fproduct($0.price, $0.shares) })
        var values: [String: FundamentalMetric] = ["marketCap": .init(cap)]
        var ev: Money?
        if let debt = m["debt"]?.value, let preferred = input.instant(.preferred), let nci = input.instant(.nci),
           let cash = input.instant(.cash), preferred.amount >= 0, nci.amount >= 0, cash.amount >= 0 {
            ev = try cap.adding(debt).adding(preferred).adding(nci).subtracting(cash)
        }
        values["enterpriseValue"] = .init(ev, flags: ["LEASES_INCLUDED_NOT_EBITDAR"])
        for (key, numerator, denominator) in [("peMarketCap", Optional(cap), m["commonIncome"]?.value),
            ("priceBook", Optional(cap), input.instant(.commonEquity)), ("priceSales", Optional(cap), m["revenue"]?.value),
            ("priceFCF", Optional(cap), m["fcf"]?.value), ("priceFCFExSBC", Optional(cap), m["fcfExSBC"]?.value),
            ("evEBITDA", ev, m["ebitda"]?.value), ("evSales", ev, m["revenue"]?.value),
            ("fcfYield", m["fcf"]?.value, Optional(cap)), ("fcfExSBCYield", m["fcfExSBC"]?.value, Optional(cap)),
            ("earningsYield", m["commonIncome"]?.value, Optional(cap))] {
            values[key] = try fratio(numerator, denominator)
        }
        values["peEPS"] = prepared.referenceClasses.count == 1 && prepared.assessment.perShareBasisAvailable
            ? try fratio(prepared.referenceClasses[0].price, m["dilutedEPSQuarterSum"]?.value) : .init(nil, reason: .missingClass)
        var shareholderCash: Money?
        if let netBuybacks = m["netBuybacks"]?.value, let dividends = try input.flow(.dividends), dividends.amount >= 0 {
            shareholderCash = try netBuybacks.adding(dividends)
        }
        values["shareholderYield"] = try fratio(shareholderCash, cap)
        return .init(referenceAt: referenceAt, accountingCutoff: accounting.cutoff,
            formulaModel: accounting.models[0].reference, parameters: accounting.parameters.reference, metrics: values,
            limitations: ["EXPLICIT_CAPTURED_BID_OR_ASK_SCENARIO_ONLY", "NOT_MARKET_FAIR_VALUE_OR_QUALIFIED_VALUATION",
                "ORIGINAL_MARKET_AVAILABILITY_REMAINS_UNKNOWN", "FROZEN_ACCOUNTING_CUTOFF_NOT_REFRESHED",
                "EXCLUDED_FROM_HISTORICAL_VALUATION_AND_SCORE", "LOCAL_HUMAN_CAPITAL_INTERPRETATION_NOT_CERTIFICATION"])
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, evidencePolicy, accounting, evidence, executionDate, assessment, inputSnapshot, results, cacheState
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: SECValuationCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else { throw SECValuationError.unsupportedFormat }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format); evidencePolicy = try c.decode(String.self, forKey: .evidencePolicy)
        accounting = try c.decode(SECFinancialReport.self, forKey: .accounting)
        evidence = try c.decode(SECValuationInputEvidence.self, forKey: .evidence)
        executionDate = try c.decode(Date.self, forKey: .executionDate); assessment = try c.decode(SECValuationAssessment.self, forKey: .assessment)
        inputSnapshot = try c.decode(FundamentalCompletionSnapshot.self, forKey: .inputSnapshot)
        results = try c.decode(SECValuationRecomputation.self, forKey: .results); cacheState = try c.decode(String.self, forKey: .cacheState)
        try validate()
    }
}
private struct SECValuationCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
