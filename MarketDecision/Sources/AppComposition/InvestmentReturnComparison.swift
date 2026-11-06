import Foundation
import CoreDomain
import PortfolioEngine
import Persistence
import AIInsights

public enum InvestmentAccountReturnError: Error, Equatable {
    case unverifiedReport, wrongAccount, staleReport, syntheticReport
}

/// A small local projection of an already replayed NAV report. Its private
/// account/revision binding cannot be rendered or encoded into an AI request;
/// transactions and raw evidence are discarded.
public struct InvestmentAccountReturnEvidence: Sendable, Equatable {
    private let series: PerformanceReturnSeries
    private let accountID: String
    private let ledgerRevision: UUID

    public init(saved: SavedPerformanceReport, accountID: String, ledgerRevision: UUID) throws {
        guard saved.replayMatched else { throw InvestmentAccountReturnError.unverifiedReport }
        guard saved.report.input.request.accountID == accountID else { throw InvestmentAccountReturnError.wrongAccount }
        guard saved.isCurrentLedger, saved.ledgerRevision == ledgerRevision,
              saved.report.input.ledgerRevision == ledgerRevision else { throw InvestmentAccountReturnError.staleReport }
        guard !InvestmentSummary(report: saved.report).containsSyntheticEvidence else {
            throw InvestmentAccountReturnError.syntheticReport
        }
        self.accountID = accountID; self.ledgerRevision = ledgerRevision
        series = PerformanceReturnSeries(report: saved.report)
    }

    func matches(accountID: String, ledgerRevision: UUID) -> Bool {
        self.accountID == accountID && self.ledgerRevision == ledgerRevision
    }

    /// Choose one recent, current-ledger candidate by catalog metadata only.
    /// Its body must still pass open()/replay and the checks above. A failure is
    /// not permission to silently fall back to a different or stale report.
    public static func candidate(from summaries: [PerformanceSummary], accountID: String,
                                 ledgerRevision: UUID, window: InvestmentBenchmarkWindow) -> PerformanceSummary? {
        let start = day(window.start), earliestEnd = day(window.end.addingTimeInterval(-7 * 86_400))
        return summaries.filter {
            $0.accountID == accountID && $0.ledgerRevision == ledgerRevision && $0.isCurrentLedger
                && $0.engineVersion == PerformanceEngine.version && $0.startDate <= start
                && $0.endDate >= earliestEnd && $0.startDate < $0.endDate
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }.first
    }

    static let missingCopy = "缺少同期净值报告：请补齐期初资金、持仓估值与完整出入金，再核算保存。已入账收益为 0 不代表收益率为 0%。"

    func presentation(window: InvestmentBenchmarkWindow, benchmark: AIBenchmarkReference?,
                      showReturn: Bool) -> InvestmentReturnComparisonContent {
        let start: Date?, end: Date?
        if let benchmark {
            // Match the benchmark's existing conservative 16:00 New York close
            // convention. No nearest NAV, intraday value or early-close guess.
            start = Self.close(benchmark.startDay); end = Self.close(benchmark.endDay)
        } else {
            start = series.latestValuation(onOrBefore: window.start,
                                          notBefore: window.start.addingTimeInterval(-7 * 86_400))
            end = series.latestValuation(onOrBefore: window.end,
                                        notBefore: window.end.addingTimeInterval(-7 * 86_400))
        }
        guard let start, let end, start < end else {
            return .unavailable("缺少所选期间的起止净值；不会用入账金额或开仓权利金代替收益率。")
        }
        let result = series.timeWeightedReturn(from: start, to: end)
        guard result.status == .available, let value = result.value, value.isFinite else {
            return .unavailable("同期净值尚不完整：需起止收盘时刻净值、连续持仓估值及完整出入金；不使用盘中或过期估值替代。")
        }
        let difference = benchmark.flatMap { reference -> String? in
            guard showReturn, let indexPercent = Double(reference.changePercent.decimalString), indexPercent.isFinite else { return nil }
            let points = value * 100 - indexPercent
            guard points.isFinite else { return nil }
            return String(format: "%+.2f 个百分点", locale: Locale(identifier: "en_US_POSIX"), points)
        }
        return .init(percentage: showReturn ? InvestmentSummary.percentText(value) : "收益率已隐藏",
                     difference: difference, dates: Self.day(start) + " → " + Self.day(end),
                     explanation: benchmark == nil
                        ? "时间加权收益率（TWR）· 含已入账费用及股息，剔除出入金影响。"
                        : "同收盘日期区间 · 账户 TWR 含费用及股息；标普为不含股息的价格涨跌幅，差值仅作参考。",
                     isAvailable: true)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func close(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter.date(from: day + " 16:00:00")
    }
}

public struct InvestmentReturnComparisonContent: Sendable, Equatable {
    public let percentage: String
    public let difference: String?
    public let dates: String?
    public let explanation: String
    public let isAvailable: Bool

    static func unavailable(_ reason: String) -> Self {
        .init(percentage: "待补净值", difference: nil, dates: nil, explanation: reason, isAvailable: false)
    }
}
