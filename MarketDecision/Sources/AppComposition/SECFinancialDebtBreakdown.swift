import CoreDomain
import FundamentalsEngine

/// Display-only explanations from the report's frozen inputs, after the caller has verified it.
/// A disclosed borrowing is not a substitute for the five mutually exclusive calculation slots.
public struct SECFinancialDebtBreakdown: Sendable {
    public struct Row: Identifiable, Sendable {
        public let id, title, explanation: String
        public let value: Money?
        public let sourceConcepts: [String]
    }
    public let period: String
    public let components: [Row]
    public let disclosures: [Row]
    public let usesLegacyEvidence: Bool
    public var missingCount: Int { components.filter { $0.value == nil }.count }
    public var summary: String {
        missingCount == 0 ? "五项计算输入已齐全" : "\(missingCount) 项债务输入待补充或核对"
    }
    public var missingTitles: String {
        components.filter { $0.value == nil }.map(\.title).joined(separator: "、")
    }

    public init(report: SECFinancialReport) {
        let input = report.inputSnapshot.financials.input
        let day = report.baseReport.periodEnd
        period = day.iso8601
        usesLegacyEvidence = report.evidencePolicy == SECFinancialReport.legacyPolicyVersion
        let definitions: [(FundamentalField, String, String)] = [
            (.shortDebt, "短期借款", "ShortTermBorrowings"),
            (.currentDebt, "长债流动部分", "LongTermDebtCurrent"),
            (.longDebt, "长债非流动部分", "LongTermDebtNoncurrent"),
            (.financeLease, "融资租赁", "FinanceLeaseLiability"),
            (.operatingLease, "经营租赁", "OperatingLeaseLiability")
        ]
        func row(field: String, title: String, concepts: [String], disclosure: Bool = false) -> Row {
            let values = input.normalization.values.filter {
                $0.fieldID == field && $0.periodEnd == day && $0.periodType == .instant && $0.unit == "USD"
            }
            let raw = report.evidence.facts.filter {
                $0.taxonomy == "us-gaap" && concepts.contains($0.concept) && $0.endDate == day
            }
            let factIDs = Set(raw.flatMap { [$0.factID, $0.recordID] })
            let issues = input.normalization.issues.filter { !factIDs.isDisjoint(with: Set($0.factIDs)) }
            let conflict = issues.contains { $0.severity == .blocker }
            var value: Money?
            let explanation: String
            if values.count == 1, let candidate = values.first, candidate.value.amount >= 0 {
                value = candidate.value
                if disclosure {
                    explanation = "披露额含流动与非流动部分，未拆分期限；不替代完整债务总额，也不与期限分项重复相加。"
                } else {
                    explanation = candidate.derivation == .leaseComponentsSum
                        ? "由同一申报及来源的流动、非流动负债相加；两项来源均保留。"
                        : "已识别本期披露。"
                }
            } else if values.contains(where: { $0.value.amount < 0 }) {
                explanation = "原始负债为负值，需要核对；未用于债务合计。"
            } else if conflict || values.count > 1 {
                explanation = "同一期末的来源或合计、分项存在冲突，未选择任意金额。"
            } else if issues.contains(where: { $0.code == "lease-components-incomplete" }) {
                explanation = "租赁仅有部分分项，流动与非流动负债未齐全；缺项不补零。"
            } else if issues.contains(where: { $0.code == "lease-components-incompatible" }) {
                explanation = "租赁分项的申报版本、来源或数值条件不一致，不能拼接成总额。"
            } else if !raw.isEmpty {
                explanation = "本期有相关原始字段，但未满足该报告的映射与来源校验条件。"
            } else {
                explanation = "本报告没有可用的同期期末输入；这不代表该项为零或公司没有此类负债。"
            }
            let sourceIDs = Set(values.flatMap(\.sourceFactIDs))
            let mappedConcepts = report.evidence.facts.filter { sourceIDs.contains($0.factID) }
                .map { $0.taxonomy + ":" + $0.concept }
            return Row(id: field, title: title, explanation: explanation, value: value,
                       sourceConcepts: Array(Set(mappedConcepts.isEmpty ? concepts.map { "us-gaap:" + $0 } : mappedConcepts)).sorted())
        }
        components = definitions.map { field, title, concept in
            let concepts = field == .financeLease || field == .operatingLease
                ? [concept, concept + "Current", concept + "Noncurrent"] : [concept]
            return row(field: field.rawValue, title: title, concepts: concepts)
        }
        // Keep this separate from the five calculation components: LineOfCredit covers both
        // maturities and can overlap the issuer's LongTermDebt disclosure.
        let creditField = "debt-disclosures.line-of-credit-total"
        disclosures = input.normalization.values.contains { $0.fieldID == creditField && $0.periodEnd == day }
            ? [row(field: creditField, title: "已披露融资借款（授信项下）", concepts: ["LineOfCredit"], disclosure: true)] : []
    }
}
