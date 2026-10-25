import FundamentalsEngine

/// A display-only projection of a report the workspace has already generated or replayed.
/// It neither recomputes values nor promotes an unverified report to display eligibility.
public enum SECFinancialOverview {
    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case quarter, ttm

        public var id: String { rawValue }
        public var title: String { self == .quarter ? "单季度" : "TTM" }
        public var label: String { self == .quarter ? "单季度" : "最近四季合计" }
    }

    public struct Row: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let unit: String
        public let metric: FundamentalMetric?
        public let percentage: Bool
        public let periodLabel: String
        public let basis: String

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

    public static func rows(for report: SECFinancialReport, period: Period = .quarter) -> [Row] {
        let base = report.baseReport.metrics
        let quarter = report.growthReport.metrics
        let completion = report.completionReport.metrics
        let end = report.inputSnapshot.financials.input.quarters.last?.end.iso8601
        let balancePeriod = end.map { "截至 " + $0 } ?? "期末日期缺失"
        // Display selection never substitutes another period for a missing selected-period value.
        func flow(_ key: String) -> FundamentalMetric? {
            period == .quarter ? quarter[key + "Quarter"] : base[key]
        }
        return [
            .init(id: "revenue", title: "收入", unit: "USD", metric: flow("revenue"), percentage: false,
                  periodLabel: period.label, basis: "财报收入"),
            .init(id: "netIncome", title: "净利润", unit: "USD", metric: flow("netIncome"), percentage: false,
                  periodLabel: period.label, basis: "财报净利润（未作调整）"),
            .init(id: "fcf", title: "自由现金流", unit: "USD", metric: flow("fcf"), percentage: false,
                  periodLabel: period.label, basis: "经营现金流 − 资本支出"),
            .init(id: "cash", title: "现金及等价物", unit: "USD", metric: completion["cash"], percentage: false,
                  periodLabel: balancePeriod, basis: "不含短期投资"),
            .init(id: "debt", title: "债务（含租赁）", unit: "USD", metric: base["debt"], percentage: false,
                  periodLabel: balancePeriod, basis: "借款与租赁，不等于总负债"),
            .init(id: "revenueCAGR3Y", title: "三年收入增长", unit: "年复合增长率", metric: completion["revenueCAGR3Y"], percentage: true,
                  periodLabel: revenueGrowthPeriod(for: report), basis: "完整年度收入 · 3 年年复合增长率")
        ]
    }

    public static func periodSummary(for report: SECFinancialReport, period: Period = .quarter) -> String {
        let quarters = report.inputSnapshot.financials.input.quarters
        switch period {
        case .quarter:
            guard let latest = quarters.last else { return "单季度：期间缺失" }
            return "单季度：" + latest.start.iso8601 + " 至 " + latest.end.iso8601
        case .ttm:
            let trailing = quarters.suffix(4)
            guard trailing.count == 4, let first = trailing.first, let last = trailing.last else {
                return "最近四季合计：历史期间不足"
            }
            return "最近四季合计：" + first.start.iso8601 + " 至 " + last.end.iso8601
        }
    }

    private static func revenueGrowthPeriod(for report: SECFinancialReport) -> String {
        let years = report.inputSnapshot.revenueYears.suffix(4)
        guard years.count == 4, let first = years.first, let last = years.last else {
            return "完整财年历史不足（需要连续 4 个年度）"
        }
        return "财年期末 " + first.end.iso8601 + " → " + last.end.iso8601
    }
}
