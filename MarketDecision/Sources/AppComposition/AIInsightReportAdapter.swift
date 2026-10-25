import Foundation
import CoreDomain
import FundamentalsEngine
import Persistence
import AIInsights

public enum AIInsightReportAdapterError: Error, Equatable {
    case replayMismatch, missingMetric, invalidCutoff
    case referencePredatesFinancialEvidence
}

/// Prepares the ONLY financial data sent to the AI interpreter. The caller obtains the
/// selected document through the verified report store; this boundary then independently
/// replays its complete frozen financial inputs. A UI "verified" Boolean is not accepted.
/// Parent documents, raw SEC bytes, free-form evidence/flags and local identifiers are
/// deliberately absent from the external packet.
public enum AIInsightReportAdapter {
    public static func prepare(_ report: SECFinancialReportDocument,
                               reference: AIValuationReferenceInput? = nil) async throws -> AIInsightInput {
        try Task.checkCancellation()
        try report.validate()
        // Match the existing valuation evidence rule: accounting evidence cannot be
        // used to explain an earlier reference price. Compare original Date precision.
        if let reference, reference.referenceAt < report.cutoff {
            throw AIInsightReportAdapterError.referencePredatesFinancialEvidence
        }
        let replay = try await report.financials.recompute()
        guard try report.financials.cachedReportsMatch(replay) else {
            throw AIInsightReportAdapterError.replayMismatch
        }
        try Task.checkCancellation()

        let quarters = report.financials.inputSnapshot.financials.input.quarters
        guard let latest = quarters.last, let ttmStart = quarters.suffix(4).first else {
            throw AIInsightReportAdapterError.missingMetric
        }
        let ttm = "TTM " + ttmStart.start.iso8601 + "—" + latest.end.iso8601
        let quarter = "本季 " + latest.start.iso8601 + "—" + latest.end.iso8601
        let instant = "期末 " + latest.end.iso8601
        let previousTTM: String
        if quarters.count == 8 {
            previousTTM = "；对比 " + quarters[0].start.iso8601 + "—" + quarters[3].end.iso8601
        } else { previousTTM = "；缺少上一完整 TTM" }
        let quarterYoY = quarters.count > 4
            ? "；对比 " + quarters[quarters.count - 5].start.iso8601 + "—" + quarters[quarters.count - 5].end.iso8601
            : "；缺少上年同季"
        let prior = quarters[quarters.count - 2]
        let quarterQoQ = "；对比 " + prior.start.iso8601 + "—" + prior.end.iso8601
        let periods: [Period: String] = [.ttm: ttm, .instant: instant, .ttmYoY: ttm + previousTTM,
            .quarter: quarter, .quarterYoY: quarter + quarterYoY, .quarterQoQ: quarter + quarterQoQ]

        var metrics = try descriptors.map { descriptor -> AIInsightMetric in
            let values: [String: FundamentalMetric]
            switch descriptor.family {
            case .base: values = replay.base.metrics
            case .growth: values = replay.growth.metrics
            case .completion: values = replay.completion.metrics
            }
            guard let metric = values[descriptor.key], let period = periods[descriptor.period] else {
                throw AIInsightReportAdapterError.missingMetric
            }
            // Units are fixed by the named local formula, never inferred from magnitude.
            // "ratio" is a fraction (0.2), not a pre-multiplied percentage (20).
            return AIInsightMetric(id: descriptor.family.rawValue + "." + descriptor.key,
                label: descriptor.label + "（" + period + "）", value: metric.value?.decimalString,
                unit: descriptor.unit, unavailable: metric.unavailable?.rawValue,
                sourceIDs: ["local." + descriptor.family.rawValue])
        }
        var sources: [AIInsightSource] = [
            .init(id: "local.base", label: "本地财务计算 fundamentals.v1；完整保存输入已重算匹配；仅研究，不证明历史 PIT 或估值资格"),
            .init(id: "local.growth", label: "本地增长计算 fundamentals-growth.v1；完整保存输入已重算匹配；非 SEC 原始报表行引用"),
            .init(id: "local.completion", label: "本地补充计算 fundamentals-completion.v1；完整保存输入已重算匹配；非 SEC 原始报表行引用")
        ]
        var context: AIInsightReferenceValuationContext?
        if let reference {
            // Reuse the same already-matched replay, not a second calculation or cached values.
            metrics += try referenceMetrics(reference, commonIncome: replay.base.metrics["commonIncome"]?.value,
                revenue: replay.base.metrics["revenue"]?.value, fcf: replay.base.metrics["fcf"]?.value, ttm: ttm)
            sources.append(.init(id: AIInsightReferenceValuationContext.referenceSourceID,
                label: "用户手工参考价与单一普通股股本假设；股本未认证；倍数基于已重算财报，非行情或合理股价"))
            context = AIInsightReferenceValuationContext(referenceAt: try utcCutoff(reference.referenceAt),
                sharesAsOf: reference.sharesAsOf.iso8601)
        }
        let packet = AIInsightInput(ticker: report.ticker, companyName: report.companyName,
            periodEnd: latest.end.iso8601, cutoff: try utcCutoff(report.cutoff), metrics: metrics,
            sources: sources, referenceValuation: context)
        try packet.validate()
        return packet
    }

    /// The same cap and fratio policy as fundamentals.v1: exact price × actual shares,
    /// missing input stays missing, and zero/negative denominators never produce a multiple.
    /// This narrow internal seam also checks denial paths independently of SEC fixtures.
    static func referenceMetrics(_ reference: AIValuationReferenceInput, commonIncome: Money?,
                                 revenue: Money?, fcf: Money?, ttm: String) throws -> [AIInsightMetric] {
        let source = [AIInsightReferenceValuationContext.referenceSourceID]
        let cap = try reference.price.multiplied(by: reference.shares.decimalString)
        var values: [AIInsightMetric] = [
            .init(id: "reference.price", label: "用户手工参考股价", value: reference.price.decimalString,
                  unit: "USD/share", unavailable: nil, sourceIDs: source),
            .init(id: "reference.shares", label: "用户确认的单一普通股实际股数（未认证）", value: reference.shares.decimalString,
                  unit: "shares", unavailable: nil, sourceIDs: source),
            .init(id: "reference.marketCap", label: "参考市值（手工参考价 × 股数假设）", value: cap.decimalString,
                  unit: "USD", unavailable: nil, sourceIDs: source)
        ]
        for (key, label, denominator) in [("pe", "参考市盈率（普通股利润）", commonIncome),
                                          ("ps", "参考市销率", revenue), ("pfcf", "参考市现率（自由现金流）", fcf)] {
            let value: String?, unavailable: String?
            if let denominator {
                if denominator.amount > 0 {
                    let multiple = try cap.divided(by: denominator.decimalString)
                    // A strictly positive ratio may round to zero at Money's 18-place
                    // output boundary. That is insufficient precision, not a zero multiple.
                    if multiple.amount > 0 {
                        value = multiple.decimalString; unavailable = nil
                    } else {
                        value = nil; unavailable = "belowCalculationPrecision"
                    }
                } else {
                    value = nil; unavailable = FundamentalMissing.nonpositiveDenominator.rawValue
                }
            } else {
                value = nil; unavailable = FundamentalMissing.missingInput.rawValue
            }
            values.append(.init(id: "reference." + key, label: label + "（" + ttm + "）",
                value: value, unit: "multiple", unavailable: unavailable, sourceIDs: source))
        }
        return values
    }

    /// Preserve a Date's represented fraction instead of silently rounding the boundary
    /// to milliseconds. This is descriptive only; financial queries use the original Date.
    static func utcCutoff(_ date: Date) throws -> String {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else { throw AIInsightReportAdapterError.invalidCutoff }
        var integral = floor(seconds)
        var nanoseconds = ((seconds - integral) * 1_000_000_000).rounded()
        if nanoseconds == 1_000_000_000 { integral += 1; nanoseconds = 0 }
        guard (0..<1_000_000_000).contains(nanoseconds),
              Date(timeIntervalSinceReferenceDate: integral + nanoseconds / 1_000_000_000) == date else {
            throw AIInsightReportAdapterError.invalidCutoff
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: integral))
            + String(format: ".%09dZ", Int(nanoseconds))
    }

    private enum Family: String, Sendable { case base, growth, completion }
    private enum Period: Hashable, Sendable { case ttm, instant, ttmYoY, quarter, quarterYoY, quarterQoQ }
    private struct Descriptor: Sendable {
        let family: Family, key: String, label: String, unit: String, period: Period
        init(_ family: Family, _ key: String, _ label: String, _ unit: String, _ period: Period) {
            self.family = family; self.key = key; self.label = label; self.unit = unit; self.period = period
        }
    }

    // Default packet excludes prices, positions, scores, valuation and arbitrary metric keys.
    // Explicitly confirmed reference assumptions use only the separate closed six-key packet.
    // Missing results remain present with the calculator's closed unavailable reason.
    private static let descriptors: [Descriptor] = [
        .init(.base, "revenue", "营业收入", "USD", .ttm),
        .init(.base, "operatingIncome", "营业利润", "USD", .ttm),
        .init(.base, "netIncome", "净利润", "USD", .ttm),
        .init(.base, "fcf", "自由现金流", "USD", .ttm),
        .init(.base, "grossMargin", "毛利率", "ratio", .ttm),
        .init(.base, "operatingMargin", "营业利润率", "ratio", .ttm),
        .init(.base, "netMargin", "净利率", "ratio", .ttm),
        .init(.base, "fcfMargin", "自由现金流率", "ratio", .ttm),
        .init(.base, "fcfConversion", "自由现金流与净利润比", "ratio", .ttm),
        .init(.base, "currentRatio", "流动比率", "ratio", .instant),
        .init(.base, "debt", "债务总额（含租赁）", "USD", .instant),
        .init(.base, "netDebt", "净债务", "USD", .instant),
        .init(.base, "debtEquity", "债务权益比", "ratio", .instant),
        .init(.base, "interestCoverage", "利息覆盖倍数", "ratio", .ttm),
        .init(.base, "roa", "资产收益率", "ratio", .ttm),
        .init(.base, "roe", "普通股权益收益率", "ratio", .ttm),
        .init(.base, "roic", "投入资本回报率", "ratio", .ttm),
        .init(.base, "netDebtEBITDA", "净债务与 EBITDA 比", "ratio", .ttm),
        .init(.base, "revenueYoY", "营业收入同比", "ratio", .ttmYoY),
        .init(.base, "netIncomeYoY", "净利润同比", "ratio", .ttmYoY),
        .init(.base, "fcfYoY", "自由现金流同比", "ratio", .ttmYoY),
        .init(.growth, "revenueQuarter", "营业收入", "USD", .quarter),
        .init(.growth, "operatingIncomeQuarter", "营业利润", "USD", .quarter),
        .init(.growth, "netIncomeQuarter", "净利润", "USD", .quarter),
        .init(.growth, "fcfQuarter", "自由现金流", "USD", .quarter),
        .init(.growth, "revenueQuarterYoY", "营业收入同比", "ratio", .quarterYoY),
        .init(.growth, "revenueQuarterQoQ", "营业收入环比", "ratio", .quarterQoQ),
        .init(.growth, "fcfQuarterYoY", "自由现金流同比", "ratio", .quarterYoY),
        .init(.growth, "operatingIncomeTTMYoY", "营业利润同比", "ratio", .ttmYoY),
        .init(.completion, "cash", "现金", "USD", .instant),
        .init(.completion, "capexTTM", "资本支出（支出为正）", "USD", .ttm),
        .init(.completion, "sbcTTM", "股份薪酬（非现金）", "USD", .ttm),
        .init(.completion, "dividendsTTM", "普通股股利（支出为正）", "USD", .ttm),
        .init(.completion, "buybacksTTM", "普通股回购（支出为正）", "USD", .ttm),
        .init(.completion, "issuanceTTM", "普通股发行收入", "USD", .ttm)
    ]
}
