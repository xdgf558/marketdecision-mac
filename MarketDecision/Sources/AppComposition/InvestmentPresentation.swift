import Foundation
import CoreDomain
import PortfolioEngine
import Persistence

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

/// Only whitelisted presentation values are retained. Account names/IDs, events,
/// credentials, source bytes and hashes cannot be rendered or encoded by this type.
public struct InvestmentShareSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    private let summary: InvestmentSummary
    private let holdingNames: [String]
    private let historical: Bool
    public static let composeURL = URL(string: "https://x.com/compose/post")!

    public init(saved: SavedPerformanceReport) throws {
        guard saved.replayMatched, saved.ledgerRevision == saved.report.input.ledgerRevision else {
            throw InvestmentShareError.unverifiedReport
        }
        let summary = InvestmentSummary(report: saved.report)
        guard summary.netPnL != nil else { throw InvestmentShareError.missingReconciledProfit }
        id = UUID(); self.summary = summary
        historical = !saved.isCurrentLedger
        holdingNames = Array(Set(saved.report.daily.last?.positions.map(\.instrumentID) ?? [])).sorted().map { raw in
            let singleLine = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return String(singleLine.prefix(60)) + (singleLine.count > 60 ? "…" : "")
        }
    }

    public func card(options: InvestmentShareOptions) -> InvestmentShareCardContent {
        .init(period: summary.startDay + " → " + summary.endDay,
              amount: options.showAmounts ? InvestmentSummary.amountText(summary.netPnL) + " USD" : "金额已隐藏",
              returnText: options.showReturn ? InvestmentSummary.percentText(summary.returnValue) : "收益率已隐藏",
              holdings: options.showHoldingNames ? holdingNames : [],
              evidenceLabel: summary.containsSyntheticEvidence ? "SYNTHETIC · 合成数据示例，非真实账户业绩" : "本地记录 · 已按冻结输入复算",
              valuationLabel: summary.usesStalePrices ? "含 STALE 估值，仅作账本记录" : "原始 EOD 估值 · 非实时",
              versionLabel: historical ? "历史账本版本" : "最近核对时与账本版本一致",
              scope: "所选账户 · 所选区间净盈亏（已扣外部资金流）",
              footnote: "研究用途 · 个人记录，不代表未来收益")
    }
}

public struct InvestmentShareCardContent: Sendable, Equatable {
    public let period: String
    public let amount: String
    public let returnText: String
    public let holdings: [String]
    public let evidenceLabel: String
    public let valuationLabel: String
    public let versionLabel: String
    public let scope: String
    public let footnote: String
}
