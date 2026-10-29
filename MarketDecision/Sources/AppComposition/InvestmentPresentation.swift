import Foundation
import CoreDomain
import PortfolioEngine
import Persistence
import AIInsights

/// A presentation of the existing reconciled period result, not a new P&L model.
/// Deposits, withdrawals and transfers are never relabelled as investment profit.
public struct InvestmentSummary: Sendable, Equatable {
    public let startDay: String
    public let endDay: String
    public let netPnL: Money?
    public let realizedPnL: Money?
    public let changeInUnrealizedPnL: Money?
    public let returnValue: Double?
    public let containsSyntheticEvidence: Bool
    public let usesStalePrices: Bool
    public let unavailableReason: String?

    public init(report: PerformanceReport) {
        startDay = report.daily.first?.day ?? "未提供"
        endDay = report.daily.last?.day ?? "未提供"
        containsSyntheticEvidence = Self.isSynthetic(report)
        usesStalePrices = report.daily.contains { $0.positions.contains { $0.priceKind == .lastStale } }
        let attribution = report.attribution
        let reconciled = report.input.request.externalFlowsComplete
            && !report.daily.isEmpty && report.daily.allSatisfy { $0.nav != nil && $0.status == .available }
            && attribution?.reconciliationDifference?.amount == 0
            && attribution?.explainedPnL != nil
        netPnL = reconciled ? attribution?.navChangeLessExternalFlows : nil
        realizedPnL = attribution?.realizedPnL
        changeInUnrealizedPnL = attribution?.changeInUnrealizedPnL
        returnValue = report.twr.status == .available && report.twr.value?.isFinite == true ? report.twr.value : nil
        unavailableReason = reconciled ? nil : "估值、完整现金流或收益对账尚有缺口；不把缺失金额算成 0。"
    }

    private static func isSynthetic(_ report: PerformanceReport) -> Bool {
        let request = report.input.request
        var sources = [request.calendar.evidence]
        if let source = request.flowCompletenessEvidence { sources.append(source) }
        sources += request.days.flatMap { $0.sessions.map(\.evidence) + $0.prices.map(\.evidence) }
        sources += request.accruals.map(\.evidence) + request.rateCurves.map(\.evidence)
        sources += request.benchmark?.points.map(\.evidence) ?? []
        sources += request.roundAllocations.map(\.evidence) + request.incomeAllocations.map(\.evidence) + request.purposeEvidence.map(\.evidence)
        return sources.contains { $0.kind == .synthetic }
    }

    public static func amountText(_ value: Money?) -> String {
        guard let value, let rounded = try? value.posted() else { return "待补数据" }
        let components = rounded.decimalString.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = components.count == 2 ? String(components[1]) : ""
        return (rounded.amount > 0 ? "+" : "") + String(components[0]) + "." + fraction.padding(toLength: 2, withPad: "0", startingAt: 0)
    }

    public static func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite, (value * 100).isFinite else { return "收益率未核对" }
        return String(format: "%+.2f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }
}

public struct InvestmentShareOptions: Sendable, Equatable {
    public var showAmounts = false
    public var showReturn = true
    public var showHoldingNames = false
    public init() {}
}

public enum InvestmentShareError: Error, Equatable { case unverifiedReport, missingReconciledProfit }

/// Only the public date window may be sent to benchmark search. Never serialize
/// the share snapshot, account, booked amounts or underlying ledger into a prompt.
public struct InvestmentBenchmarkWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
}

/// Whitelisted presentation values plus a private account/revision binding for
/// local return evidence. Account identity, events, credentials, source bytes
/// and hashes cannot be rendered or encoded by this type.
public struct InvestmentShareSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let benchmarkWindow: InvestmentBenchmarkWindow?
    private struct BookedFacts: Sendable, Equatable {
        let selection: InvestmentReportPeriod
        let period: String
        let dateRange: String
        let periodBoundaryLabel: String
        let asOfLabel: String
        let amount: Money
        let realizedPnL: Money
        let cashIncome: Money
        let cashCharges: Money
        let synthetic: Bool
    }
    private enum Content: Sendable, Equatable {
        case frozen(InvestmentSummary, holdingNames: [String], historical: Bool)
        case booked(BookedFacts)
    }
    private let content: Content
    private let accountReturn: InvestmentAccountReturnEvidence?
    private let returnUnavailableReason: String
    public static let composeURL = URL(string: "https://x.com/compose/post")!

    public var periodSelection: InvestmentReportPeriod? {
        if case .booked(let facts) = content { return facts.selection }
        return nil
    }

    public var supportsReturn: Bool {
        if case .frozen = content { return true }
        return accountReturn != nil
    }
    public var supportsHoldingNames: Bool {
        if case .frozen = content { return true }
        return false
    }

    public init(saved: SavedPerformanceReport) throws {
        guard saved.replayMatched, saved.ledgerRevision == saved.report.input.ledgerRevision else {
            throw InvestmentShareError.unverifiedReport
        }
        let summary = InvestmentSummary(report: saved.report)
        guard summary.netPnL != nil else { throw InvestmentShareError.missingReconciledProfit }
        let names = Array(Set(saved.report.daily.last?.positions.map(\.instrumentID) ?? [])).sorted().map { raw in
            let singleLine = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return String(singleLine.prefix(60)) + (singleLine.count > 60 ? "…" : "")
        }
        id = UUID()
        if let start = saved.report.daily.first?.valuationAt,
           let end = saved.report.daily.last?.valuationAt, start < end {
            benchmarkWindow = .init(start: start, end: end)
        } else { benchmarkWindow = nil }
        accountReturn = try? InvestmentAccountReturnEvidence(saved: saved,
            accountID: saved.report.input.request.accountID, ledgerRevision: saved.ledgerRevision)
        returnUnavailableReason = saved.isCurrentLedger
            ? "该报告尚无可用于同期对比的净值证据；合成示例与陈旧估值不能用作真实账户收益。"
            : "该报告属于历史账本版本，请用当前记录重新核算后对比。"
        content = .frozen(summary, holdingNames: names, historical: !saved.isCurrentLedger)
    }

    /// The model must first recheck the selected account, page and ledger revision.
    /// Keep only booked presentation facts; no account identifier, cash balance,
    /// event, source text, holdings or valuation qualification crosses this boundary.
    public init(periodReport: InvestmentPeriodReport, accountReturn: InvestmentAccountReturnEvidence? = nil,
                returnUnavailableReason: String? = nil) {
        self.accountReturn = accountReturn?.matches(accountID: periodReport.accountID,
            ledgerRevision: periodReport.ledgerRevision) == true ? accountReturn : nil
        self.returnUnavailableReason = returnUnavailableReason ?? InvestmentAccountReturnEvidence.missingCopy
        id = UUID()
        benchmarkWindow = .init(start: periodReport.startDate, end: periodReport.endDate)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        // Reports are generated using America/New_York. Include the actual zone
        // and UTC offset in the card, even on a host configured in another zone.
        formatter.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS XXXXX"
        let interval = formatter.string(from: periodReport.startDate) + " → "
            + formatter.string(from: periodReport.endDate)
        let period = periodReport.title + " · " + interval + "（" + formatter.timeZone.identifier + "，含起止时刻）"
        formatter.dateFormat = "yyyy.MM.dd"
        let dateRange = formatter.string(from: periodReport.startDate) + " 至 "
            + formatter.string(from: periodReport.endDate)
        let asOfLabel = "截至 " + formatter.string(from: periodReport.endDate)
        formatter.dateFormat = "HH:mm:ss.SSS XXXXX"
        let periodBoundaryLabel = "美东 " + formatter.string(from: periodReport.startDate) + " → "
            + formatter.string(from: periodReport.endDate) + " · 含起止时刻"
        content = .booked(.init(selection: periodReport.period, period: period,
            dateRange: dateRange, periodBoundaryLabel: periodBoundaryLabel, asOfLabel: asOfLabel,
            amount: periodReport.bookedPnL, realizedPnL: periodReport.realizedPnL,
            cashIncome: periodReport.cashIncome, cashCharges: periodReport.cashCharges,
            synthetic: periodReport.containsSyntheticRecords))
    }

    public func card(options: InvestmentShareOptions, benchmark: AIBenchmarkResult? = nil) -> InvestmentShareCardContent {
        // A result from another date window can never ride along with a new image.
        let acceptedBenchmark = benchmarkWindow.flatMap { window in
            benchmark.flatMap { value in
                value.request.start == window.start && value.request.end == window.end
                    && (try? value.validate(for: value.request)) != nil ? value : nil
            }
        }
        let comparison = benchmarkWindow.flatMap { window in
            accountReturn?.presentation(window: window, benchmark: acceptedBenchmark?.reference,
                                        showReturn: options.showReturn)
        } ?? .unavailable(returnUnavailableReason)
        let benchmarkContent = benchmarkWindow.flatMap { window in
            acceptedBenchmark.flatMap { InvestmentShareBenchmarkContent(result: $0, window: window, accountReturn: comparison) }
        }
        switch content {
        case .frozen(let summary, let holdingNames, let historical):
            return .init(period: summary.startDay + " → " + summary.endDay,
                  periodTitle: "区间报告",
                  dateRange: summary.startDay.replacingOccurrences(of: "-", with: ".") + " 至 "
                    + summary.endDay.replacingOccurrences(of: "-", with: "."),
                  periodBoundaryLabel: "冻结报告 · 日终估值",
                  asOfLabel: "截至 " + summary.endDay.replacingOccurrences(of: "-", with: "."),
                  breakdown: [],
                  profitLabel: "区间净盈亏", returnLabel: "时间加权收益",
                  amount: options.showAmounts ? InvestmentSummary.amountText(summary.netPnL) + " USD" : "金额已隐藏",
                  returnText: options.showReturn ? InvestmentSummary.percentText(summary.returnValue) : "收益率已隐藏",
                  holdings: options.showHoldingNames ? holdingNames : [],
                  evidenceLabel: summary.containsSyntheticEvidence ? "SYNTHETIC · 合成数据示例，非真实账户业绩" : "本地记录 · 已按冻结输入复算",
                  valuationLabel: summary.usesStalePrices ? "含 STALE 估值，仅作账本记录" : "原始 EOD 估值 · 非实时",
                  versionLabel: historical ? "历史账本版本" : "最近核对时与账本版本一致",
                  scope: "所选账户 · 所选区间净盈亏（已扣外部资金流）",
                  footnote: "研究用途 · 个人记录，不代表未来收益", benchmark: benchmarkContent, accountReturn: comparison)
        case .booked(let facts):
            let display: (Money) -> String = { value in
                options.showAmounts ? InvestmentSummary.amountText(value) + " USD" : "金额已隐藏"
            }
            return .init(period: facts.period, periodTitle: facts.selection.title,
                  dateRange: facts.dateRange, periodBoundaryLabel: facts.periodBoundaryLabel,
                  asOfLabel: facts.asOfLabel,
                  breakdown: [.init(title: "交易盈亏", value: display(facts.realizedPnL)),
                              .init(title: "股息与利息", value: display(facts.cashIncome)),
                              .init(title: "费用与税款", value: display(facts.cashCharges))],
                  profitLabel: "已入账收益", returnLabel: accountReturn == nil ? nil : "账户收益率（TWR）",
                  amount: display(facts.amount),
                  returnText: accountReturn == nil ? "" : comparison.percentage, holdings: [],
                  evidenceLabel: facts.synthetic ? "SYNTHETIC · 合成数据示例，非真实账户业绩" : "本地记录 · 按当前有效入账记录汇总",
                  valuationLabel: "不含持仓浮盈、净值或收益率",
                  versionLabel: "生成时账本已核对 · 后续补录或冲销后需重新生成",
                  scope: "所选账户 · 已实现交易盈亏＋股息、利息－独立费用、税款；入出金不计收益",
                  footnote: "开仓权利金不直接计为利润 · 个人记录，不代表未来收益", benchmark: benchmarkContent, accountReturn: comparison)
        }
    }
}

public struct InvestmentShareBreakdownRow: Sendable, Equatable {
    public let title: String
    public let value: String
}

/// This is an AI search reference, not an admitted market-data feed or proof of
/// source accuracy/licensing. A percentage-point comparison is descriptive,
/// not a total-return benchmark or proof of investment outperformance.
public struct InvestmentShareBenchmarkContent: Sendable, Equatable {
    public let percentage: String
    public let dates: String
    public let closes: String
    public let sourceLabel: String
    public let sources: [AIBenchmarkSource]
    public let qualification = "AI 联网参考 · 未独立核验"
    public let accountReturn: InvestmentReturnComparisonContent
    public let valuationWindow: InvestmentBenchmarkWindow

    init?(result: AIBenchmarkResult, window: InvestmentBenchmarkWindow, accountReturn: InvestmentReturnComparisonContent) {
        guard result.request.start == window.start, result.request.end == window.end,
              (try? result.validate(for: result.request)) != nil,
              let reference = result.reference,
              let first = InvestmentAccountReturnEvidence.close(reference.startDay),
              let last = InvestmentAccountReturnEvidence.close(reference.endDay) else { return nil }
        self.accountReturn = accountReturn
        valuationWindow = .init(start: first, end: last)
        percentage = InvestmentSummary.amountText(reference.changePercent) + "%"
        dates = reference.startDay + " → " + reference.endDay
        closes = reference.startClose.decimalString + " → " + reference.endClose.decimalString + " 点"
        sourceLabel = reference.sourceKind == .answerCitations ? "回答引用" : "搜索来源"
        sources = reference.sources
    }
}

public struct InvestmentShareCardContent: Sendable, Equatable {
    public let period: String
    public let periodTitle: String
    public let dateRange: String
    public let periodBoundaryLabel: String
    public let asOfLabel: String
    /// Transaction fees are already included in trading P&L. The charge row
    /// contains only standalone cash fees and taxes and remains a positive cost.
    public let breakdown: [InvestmentShareBreakdownRow]
    public let profitLabel: String
    public let returnLabel: String?
    public let amount: String
    public let returnText: String
    public let holdings: [String]
    public let evidenceLabel: String
    public let valuationLabel: String
    public let versionLabel: String
    public let scope: String
    public let footnote: String
    public let benchmark: InvestmentShareBenchmarkContent?
    public let accountReturn: InvestmentReturnComparisonContent
}
