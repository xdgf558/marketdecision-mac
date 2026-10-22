import FundamentalsEngine

/// A display-only projection of a report the workspace has already generated or replayed.
/// It neither recomputes values nor promotes an unverified report to display eligibility.
public enum SECFinancialOverview {
    public struct Row: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let unit: String
        public let metric: FundamentalMetric?
        public let percentage: Bool

        public var displayValue: String {
            if let value = metric?.value {
                if percentage, let scaled = try? value.multiplied(by: "100"),
                   let text = try? scaled.fixedString() { return text + "%" }
                return value.decimalString
            }
            switch metric?.unavailable {
            case .missingClass: return "股类数据不完整"
            case .missingPrice: return "缺少合格价格"
            case .insufficientHistory: return "历史期间不足"
            case .nonpositiveDenominator: return "分母非正"
            case .notApplicable: return "不适用"
            case .notComparable: return "口径不可比"
            case .missingEvidence: return "缺少核定证据"
            default: return "缺少输入"
            }
        }
    }

    public static func rows(for report: SECFinancialReport) -> [Row] {
        let base = report.baseReport.metrics
        let completion = report.completionReport.metrics
        return [
            .init(id: "revenue", title: "收入", unit: "USD · TTM", metric: base["revenue"], percentage: false),
            .init(id: "netIncome", title: "净利润", unit: "USD · TTM", metric: base["netIncome"], percentage: false),
            .init(id: "fcf", title: "自由现金流", unit: "USD · TTM", metric: base["fcf"], percentage: false),
            .init(id: "cash", title: "现金", unit: "USD", metric: completion["cash"], percentage: false),
            .init(id: "debt", title: "债务（含租赁）", unit: "USD", metric: base["debt"], percentage: false),
            .init(id: "revenueCAGR3Y", title: "三年收入增长", unit: "年复合增长率", metric: completion["revenueCAGR3Y"], percentage: true)
        ]
    }
}
