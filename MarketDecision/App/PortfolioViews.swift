import SwiftUI
import Charts
import AppComposition
import CoreDomain
import PortfolioEngine
import Persistence

struct PortfolioPage: View {
    let workspace: WorkspaceModel
    @State private var model: PortfolioWorkspaceModel?
    @State private var failure = false
    @State private var attempt = UUID()
    var body: some View {
        Group {
            if let model { PortfolioWorkspaceContent(model: model) }
            else if failure {
                ContentUnavailableView("组合收益暂不可用", systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("本地账本或估值库未能通过检查；不会显示缓存金融数值。"))
                Button("重新打开") { attempt = UUID() }
            } else { ProgressView("正在打开本地组合…") }
        }
        .task(id: "\(workspace.isPrepared)-\(attempt)") {
            guard workspace.isPrepared else { return }
            do {
                failure = false
                if model == nil {
                    let ready = try await workspace.makePortfolioWorkspaceModel()
                    try Task.checkCancellation(); model = ready
                }
                await model?.load()
            } catch { if !Task.isCancelled { failure = true } }
        }
    }
}
private struct PortfolioApproval: Identifiable {
    let id: UUID
    let ledger: UUID
    let performance: UUID
}
struct PortfolioWorkspaceContent: View {
    @Bindable var model: PortfolioWorkspaceModel
    @State private var section = "组合概览"
    @State private var draft = PortfolioInputDraft()
    @State private var advanced = false
    @State private var publishedRate = PortfolioPublishedRateDraft()
    @State private var rateImportMessage: String?
    @State private var rawJSON = ""
    @State private var inputError: String?
    @State private var approval: PortfolioApproval?
    @State private var confirmation = ""
    @State private var evidenceExpanded = false
    private let sections = ["组合概览", "本地证据", "收益与风险", "回合与归因", "已保存", "导出与备份"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            accountBar
            Text("本地冻结证据 · USD 管理口径 · 研究用途。这里不联网，不把当前报价补成历史；来源声明不等于供应商准入。").font(.callout).foregroundStyle(.secondary)
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("portfolioMessage") }
            Picker("组合内容", selection: $section) {
                ForEach(sections, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("portfolioSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if section == "本地证据" { editor }
                    else if section == "已保存" { history }
                    else if section == "导出与备份", let transfer = model.transfer { LedgerTransferContent(model: transfer, reportID: model.savedReport?.id) }
                    else if let report = model.report {
                        reportHeading(report)
                        if section == "组合概览" { overview(report) }
                        else if section == "收益与风险" { performance(report) }
                        else { rounds(report) }
                        previewActions
                    } else {
                        currentLedger
                        ContentUnavailableView("尚无已核对的估值", systemImage: "chart.xyaxis.line",
                            description: Text("在“本地证据”中填入交易日历、会话和价格，再显式计算。也可查看不会写入账户的独立合成示例。"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
        }.padding(24)
        .sheet(item: $approval) { confirmSheet($0) }
        .onChange(of: model.transferEpoch) { _, _ in
            approval = nil; draft = .init(); rawJSON = ""; inputError = nil; publishedRate = .init(); rateImportMessage = nil; evidenceExpanded = false
        }
        .onChange(of: draft) { _, _ in if !model.isBusy { model.draftChanged(); approval = nil } }
        .onChange(of: rawJSON) { _, _ in if !model.isBusy { model.draftChanged(); approval = nil } }
        .onChange(of: advanced) { _, _ in if !model.isBusy { model.draftChanged(); approval = nil } }
        .onChange(of: model.selectedAccountID) { _, _ in draft = .init(); rawJSON = ""; inputError = nil; approval = nil; publishedRate = .init(); rateImportMessage = nil }
        .onDisappear { approval = nil; model.disappear() }
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("组合收益").font(.system(size: 32, weight: .bold))
                Text("估值、现金流与收益各有依据").foregroundStyle(.secondary)
            }
            Spacer()
            Button("独立合成示例") { Task { await model.showSyntheticExample(); section = "组合概览" } }
                .disabled(model.isBusy).accessibilityIdentifier("portfolioDemo")
            Button("重新载入") { Task { await model.load() } }.disabled(model.isBusy).accessibilityIdentifier("portfolioReload")
        }
    }
    private var accountBar: some View {
        HStack {
            Picker("账本账户", selection: Binding(get: { model.selectedAccountID ?? "" }, set: { id in Task { await model.chooseAccount(id) } })) {
                if model.context?.ledger.accounts.isEmpty != false { Text("请先在交易账本创建账户").tag("") }
                ForEach(model.context?.ledger.accounts ?? []) { account in Text("\(account.name) · \(account.id)").tag(account.id) }
            }.disabled(model.isBusy).accessibilityIdentifier("portfolioAccount")
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }
    private var currentLedger: some View {
        GroupBox("当前账本只读对账（不是历史 NAV）") {
            VStack(alignment: .leading, spacing: 8) {
                if let context = model.context, let id = model.selectedAccountID {
                    Text("账本现金 USD \(money(context.ledger.state.cashByAccount[id]))")
                    Text("账本版本 \(context.ledger.revision.uuidString)").font(.caption).foregroundStyle(.secondary)
                    ForEach(context.ledger.state.lots.filter { $0.accountID == id && !$0.isClosed }) { lot in
                        Text("\(lot.instrument.label) · \(lot.id) · \(lot.side.rawValue) · 剩余 \(lot.quantityRemaining.decimalString) · 管理成本 \(lot.managementCostRemaining.decimalString)")
                    }
                } else { Text("账户尚未载入；不显示旧余额或猜测持仓。").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
    private func reportHeading(_ report: PerformanceReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text(originTitle).font(.headline).accessibilityIdentifier("portfolioOrigin")
                if containsSyntheticEvidence(report) && model.origin != .synthetic { Text("本报告含显式合成证据，不代表真实账户历史表现。").foregroundStyle(.orange) }
                Text("报告账户：\(report.input.request.accountID) · \(report.engineVersion) · \(report.parametersVersion)").font(.caption)
                if model.savedReport?.isCurrentLedger == false { Text("历史账本版本；当前账本已变化。").foregroundStyle(.orange) }
                Text("价格使用声明的原始未复权 EOD 会话。Last 降级明确标为 STALE；缺价导致 NAV 缺失，不能填零。").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func containsSyntheticEvidence(_ report: PerformanceReport) -> Bool {
        let request = report.input.request
        var sources = [request.calendar.evidence]
        if let source = request.flowCompletenessEvidence { sources.append(source) }
        sources += request.days.flatMap { $0.sessions.map(\.evidence) + $0.prices.map(\.evidence) }
        sources += request.accruals.map(\.evidence) + request.rateCurves.map(\.evidence)
        sources += request.benchmark?.points.map(\.evidence) ?? []
        sources += request.roundAllocations.map(\.evidence) + request.incomeAllocations.map(\.evidence) + request.purposeEvidence.map(\.evidence)
        return sources.contains { $0.kind == .synthetic }
    }
    private var originTitle: String {
        switch model.origin { case .preview: "计算预览 · 尚未冻结"; case .frozen: "冻结报告 · 已按原输入复算"; case .synthetic: "SYNTHETIC · 独立合成示例 · 不可保存"; case .none: "尚无报告" }
    }
    private func overview(_ report: PerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let last = report.daily.last {
                HStack(alignment: .top, spacing: 24) {
                    stat("截至 \(last.day) · NAV", money(last.nav), id: "portfolioNAV")
                    stat("现金", money(last.cash))
                    stat("应收 / 应付", "\(money(last.receivables)) / \(money(last.payables))")
                }
            }
            navChart(report)
            GroupBox("逐日估值与持仓") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.daily, id: \.day) { dailyRow($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            currentLedger
            frozenEvidence(report)
        }
    }
    private func dailyRow(_ day: PerformanceDailyValue) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("现金 \(money(day.cash)) · 应收 \(money(day.receivables)) · 应付 \(money(day.payables)) · 外部净流入 \(day.externalFlow.decimalString)")
                if !day.reason.isEmpty { Text(day.reason).foregroundStyle(.orange) }
                ForEach(day.positions) { positionRow($0) }
            }.font(.callout).textSelection(.enabled)
        } label: { Text("\(day.day)   NAV \(money(day.nav))   \(status(day.status))") }
    }
    private func positionRow(_ item: PerformancePosition) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(item.instrumentID) · \(item.side.rawValue) · Lot \(item.lotID) · 数量 \(item.quantity.decimalString)")
            Text("市值 \(money(item.marketValue)) · 管理成本 \(item.managementCost.decimalString) · 浮动盈亏 \(money(item.unrealizedPnL)) · \(item.priceKind.rawValue)")
            Text("会话收盘 \(timestamp(item.sessionClose)) · 报价 \(timestamp(item.quoteAt)) · 来源 \(item.sourceIDs.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            if !item.reason.isEmpty { Text(item.reason).foregroundStyle(.orange) }
        }.padding(.vertical, 4)
    }
    private struct NAVPoint: Identifiable { let id: String; let sequence: Int; let value: Double; let segment: Int }
    private func navPoints(_ report: PerformanceReport) -> [NAVPoint] {
        var segment = 0, result: [NAVPoint] = []
        for (index, day) in report.daily.enumerated() {
            if let nav = day.nav, let value = Double(nav.decimalString), value.isFinite { result.append(.init(id: day.day, sequence: index, value: value, segment: segment)) }
            else { segment += 1 }
        }
        return result
    }
    private func navChart(_ report: PerformanceReport) -> some View {
        GroupBox("NAV（USD，包含出入金影响；缺日不连线）") {
            Chart(navPoints(report)) { point in
                LineMark(x: .value("交易日序", point.sequence), y: .value("NAV", point.value), series: .value("连续段", point.segment))
                PointMark(x: .value("交易日序", point.sequence), y: .value("NAV", point.value))
            }.frame(height: 170).accessibilityLabel("NAV 示意曲线；精确金额见下方逐日估值")
        }
    }
    private func performance(_ report: PerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("收益口径") {
                VStack(alignment: .leading, spacing: 10) {
                    metric("TWR", report.twr, percent: true)
                    metric("CAGR", report.cagr, percent: true)
                    Text("XIRR：\(number(report.xirr.value, percent: true)) · \(status(report.xirr.status))")
                    Text(report.xirr.reason).font(.caption).foregroundStyle(.secondary)
                    if report.xirr.roots.count > 1 { Text("多根不自动选根：\(report.xirr.roots.map { number($0, percent: true) }.joined(separator: ", "))") }
                    ForEach(report.segments, id: \.startDay) { segment in Text("连续段 \(segment.startDay) → \(segment.endDay)：\(number(segment.cumulativeReturn, percent: true))（\(segment.returns.count) 个收益区间）") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            monthlyMatrix(report)
            GroupBox("滚动窗口（各自截止日与有效锚点）") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.rolling, id: \.calendarDays) { row in
                        metric("\(row.calendarDays) 天 · \(row.anchorDay ?? "缺少锚点") → \(row.endDay)", row.result, percent: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            risk(report.risk)
        }
    }
    private func monthlyMatrix(_ report: PerformanceReport) -> some View {
        GroupBox("月收益矩阵（截至各格标示日期，不预示月末完整）") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 12) {
                ForEach(report.monthly, id: \.month) { month in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(month.month).font(.headline)
                        Text(number(month.result.value, percent: true)).font(.title3.monospacedDigit())
                        Text("截至 \(month.endDay) · \(status(month.result.status))").font(.caption)
                        if !month.result.reason.isEmpty { Text(month.result.reason).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.accessibilityIdentifier("portfolioMonths")
        }
    }
    private func risk(_ value: PerformanceRisk) -> some View {
        GroupBox("风险指标（样本不足保持不可用）") {
            VStack(alignment: .leading, spacing: 10) {
                metric("年化波动率", value.annualizedVolatility, percent: true)
                metric("年化 TWR", value.annualizedTWR, percent: true)
                metric("年化无风险利率", value.annualizedRiskFree, percent: true)
                metric("Sharpe", value.sharpe); metric("Sortino", value.sortino); metric("Beta", value.beta); metric("Calmar", value.calmar)
                drawdown("TWR 指数最大回撤", value.drawdown)
                drawdown("NAV 回撤（受出入金影响）", value.navDrawdown)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func drawdown(_ title: String, _ value: PerformanceDrawdown?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title)：\(number(value?.value, percent: true))")
            if let value { Text("峰值 \(value.peakDay) · 谷值 \(value.troughDay) · 恢复 \(value.recoveredDay ?? "尚未恢复")").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func rounds(_ report: PerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            tradeStatistics(report.tradeStatistics)
            groupedStatistics(report.groupedStatistics)
            GroupBox("回合状态（经济、核算、策略目标分别判定）") {
                VStack(alignment: .leading, spacing: 9) {
                    if report.rounds.isEmpty { Text("没有可显示回合；不会把缺失回合计为零收益。").foregroundStyle(.secondary) }
                    ForEach(report.rounds) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(row.roundLotID) · \(money(row.netPnL))").font(.headline)
                            Text("经济：\(row.economicState.rawValue) · 核算：\(status(row.accountingState)) · 目标：\(row.purposeState.rawValue)")
                            Text(row.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let value = report.attribution { attribution(value) }
        }
    }
    private func tradeStatistics(_ value: PerformanceTradeStatistics) -> some View {
        GroupBox("已平回合统计（少于 30 个不显示推断比例）") {
            VStack(alignment: .leading, spacing: 10) {
                Text("展示 \(value.displayN) · 合格 \(value.eligibleN) · W/L/Z \(value.wins)/\(value.losses)/\(value.zeros) · S/F/U \(value.successes)/\(value.failures)/\(value.unassigned)")
                metric("胜率", value.winRate, percent: true); metric("亏损率", value.lossRate, percent: true)
                metric("策略目标成功率", value.purposeSuccessRate, percent: true)
                interval("胜率 Wilson 95%", value.winRateInterval)
                interval("目标成功率 Wilson 95%", value.purposeSuccessInterval)
                metric("平均盈利 USD", value.averageWin); metric("平均亏损 USD", value.averageLoss)
                metric("期望收益 USD", value.expectancy); metric("盈利因子", value.profitFactor)
                if value.profitFactorInfinite { Text("盈利因子：无亏损分母，标记为无穷，不当作有限值。") }
                Text("最大连续亏损：\(value.maximumConsecutiveLosses)")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func groupedStatistics(_ values: [PerformanceGroupedStatistics]) -> some View {
        GroupBox("按策略与标的分组（未平与待分配收益不作已实现总额）") {
            VStack(alignment: .leading, spacing: 9) {
                if values.isEmpty { Text("尚无可分组回合。").foregroundStyle(.secondary) }
                ForEach(values) { group in
                    DisclosureGroup {
                        tradeStatistics(group.statistics)
                        Text("回合：\(group.roundIDs.joined(separator: ", "))").font(.caption).textSelection(.enabled)
                    } label: {
                        Text("\(group.axis == .strategy ? "策略" : "标的") · \(group.label) · 已平净收益 USD \(money(group.completedNetPnL)) · 合格 N=\(group.statistics.eligibleN)")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func interval(_ title: String, _ value: PerformanceInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title)：\(number(value.low, percent: true)) — \(number(value.high, percent: true)) · \(status(value.status)) · N=\(value.sampleCount)")
            if !value.reason.isEmpty { Text(value.reason).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func attribution(_ value: PerformanceAttribution) -> some View {
        GroupBox("\(value.startDay) → \(value.endDay) 收益归因对账") {
            VStack(alignment: .leading, spacing: 7) {
                Text("已实现 \(value.realizedPnL.decimalString) · 浮盈变化 \(money(value.changeInUnrealizedPnL))")
                Text("股息 \(value.dividends.decimalString) · 利息 \(value.interest.decimalString) · 未分配费用 \(value.unallocatedFees.decimalString) · 税 \(value.taxes.decimalString)")
                Text("应计变化 \(money(value.changeInAccruals)) · 转仓内含收益 \(value.transferEmbeddedGain.decimalString)")
                Text("NAV 变化扣外部流 \(money(value.navChangeLessExternalFlows)) · 已解释 \(money(value.explainedPnL)) · 差额 \(money(value.reconciliationDifference))")
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
    private var history: some View {
        GroupBox("本地冻结版本（打开后才复算并展示金融值）") {
            VStack(alignment: .leading, spacing: 12) {
                Button("刷新报告列表") { Task { await model.reloadSaved() } }.disabled(model.isBusy)
                if let error = model.listError { Text(error).foregroundStyle(.red) }
                if model.saved.isEmpty { Text("当前账户没有可读取的冻结报告。").foregroundStyle(.secondary) }
                ForEach(model.saved) { summary in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(summary.startDate) → \(summary.endDate) · \(summary.dayCount) 个交易日")
                            Text("\(summary.id.uuidString) · \(summary.isCurrentLedger ? "当前账本版本" : "历史账本版本")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("核对后打开") { Task { await model.open(summary.id); if model.report != nil { section = "组合概览" } } }.disabled(model.isBusy)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func frozenEvidence(_ report: PerformanceReport) -> some View {
        DisclosureGroup("完整冻结输入与证据（只读）", isExpanded: $evidenceExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(report.limitations, id: \.self) { Text($0).font(.caption) }
                Text("日期 JSON 使用自 2001-01-01 UTC 起的精确秒数；不是经过显示舍入的 ISO 日期。").font(.caption).foregroundStyle(.secondary)
                if evidenceExpanded { Text(json(report.input)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }
    }
    @ViewBuilder private var previewActions: some View {
        if let preview = model.preview {
            HStack {
                Button("冻结这份报告…") {
                    confirmation = ""; approval = .init(id: preview.id, ledger: preview.ledgerRevision, performance: preview.performanceRevision)
                }.disabled(!model.canSave).accessibilityIdentifier("portfolioSavePreview")
                Button("取消预览") { Task { await model.cancelPreview() } }.disabled(model.isBusy)
                Text("\(preview.inputHash.prefix(12)) · \(preview.reportHash.prefix(12))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func confirmSheet(_ value: PortfolioApproval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("冻结本地组合报告").font(.title2.bold())
            Text("将保存完整账本、原始证据和候选结果。版本变化后计划失效；保存不授予数据资格或投资结论。")
            Text("账本 \(value.ledger.uuidString)\n估值 \(value.performance.uuidString)").font(.caption).textSelection(.enabled)
            TextField("输入“冻结”确认", text: $confirmation).accessibilityIdentifier("portfolioConfirmText").onSubmit { }
            HStack {
                Button("取消") { approval = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认冻结") {
                    approval = nil
                    Task { await model.save(id: value.id, ledgerRevision: value.ledger, performanceRevision: value.performance) }
                }.disabled(confirmation != "冻结" || !model.canSave || model.preview?.id != value.id)
                    .accessibilityIdentifier("portfolioConfirm")
            }
        }.padding(24).frame(width: 510)
    }
    private func stat(_ title: String, _ value: String, id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit()).accessibilityIdentifier(id) }
    }
    private func metric(_ title: String, _ value: PerformanceNumber, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title)：\(number(value.value, percent: percent)) · \(status(value.status)) · N=\(value.sampleCount)")
            if !value.reason.isEmpty { Text(value.reason).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("所有时间填写带时区的 RFC3339，例如 2026-01-02T21:00:00Z。开闭市时间必须来自对应标的/合约的会话证据；没有数据的交易日留缺口，不复制前一日价格。").font(.callout).foregroundStyle(.secondary)
            Toggle("高级：粘贴完整 PerformanceRequest JSON", isOn: $advanced)
            if advanced { advancedEditor } else { typedEditor }
            if let inputError { Text(inputError).foregroundStyle(.red).accessibilityIdentifier("portfolioInputError") }
            HStack {
                Button("计算本地证据预览") { prepare() }.disabled(!model.canPrepare).accessibilityIdentifier("portfolioCalculate")
                Text("仅在点击冻结并确认后写入报告。").foregroundStyle(.secondary)
            }
        }.disabled(model.isBusy)
    }
    private var advancedEditor: some View {
        GroupBox("完整输入（保留粘贴的原始 JSON 字节）") {
            VStack(alignment: .leading, spacing: 9) {
                Text("日期编码为自 2001-01-01 UTC 起的秒数。账户必须与当前选择完全相同；可表达回合分配、收入归属和目标证据。完整类型校验与存储复算仍会执行。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $rawJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 250).accessibilityIdentifier("portfolioRequestJSON")
                Button("从当前表单生成 JSON") {
                    do {
                        let value = try draft.build(accountID: model.selectedAccountID ?? "", calculatedAt: Date())
                        rawJSON = json(value); inputError = nil
                    } catch { inputError = "表单缺少必需字段或格式无效，未生成部分输入。" }
                }
            }
        }
    }
    private var typedEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("1 · 交易日历与完整性声明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("完整交易日列表，每行 YYYY-MM-DD，按时间升序；不能用自然日或仅有报价的日子冒充交易日历。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.tradingDays).frame(height: 85).accessibilityIdentifier("portfolioCalendarDays")
                    PortfolioEvidenceEditor(title: "日历来源", draft: $draft.calendarEvidence)
                    Toggle("我已核对所选区间全部外部现金流", isOn: $draft.externalFlowsComplete)
                    if draft.externalFlowsComplete { PortfolioEvidenceEditor(title: "现金流完整性依据", draft: $draft.flowEvidence) }
                }
            }
            GroupBox("2 · 逐日估值会话与原始 EOD 报价") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("现金账户可不填持仓报价。有持仓而无对应会话/价格时，NAV 保持不可用。").font(.caption).foregroundStyle(.secondary)
                    ForEach($draft.days) { $day in
                        PortfolioDayEditor(draft: $day, instruments: availableInstruments) { draft.days.removeAll { $0.id == day.id } }
                    }
                    Button("添加估值日") { draft.days.append(.init()) }.accessibilityIdentifier("portfolioAddDay")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("3 · 可选利率、基准与应计") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($draft.rates) { $rate in PortfolioRateEditor(draft: $rate) { draft.rates.removeAll { $0.id == rate.id } } }
                    Button("添加显式常率记录") { draft.rates.append(.init()) }
                    publishedRateEditor
                    benchmarkEditor
                    ForEach($draft.accruals) { $accrual in PortfolioAccrualEditor(draft: $accrual) { draft.accruals.removeAll { $0.id == accrual.id } } }
                    Button("添加应收或应付") { draft.accruals.append(.init()) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var availableInstruments: [String] {
        let lots = model.context?.ledger.state.lots.filter { $0.accountID == model.selectedAccountID } ?? []
        return Array(Set(lots.map { $0.instrument.identity })).sorted()
    }
    private var publishedRateEditor: some View {
        DisclosureGroup("离线 FRED 原始 JSON 与发布证据") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("闭合系列", selection: $publishedRate.series) {
                    Text("DGS1MO").tag(FREDTreasurySeries.dgs1mo)
                    Text("DGS3MO").tag(FREDTreasurySeries.dgs3mo)
                    Text("DGS6MO").tag(FREDTreasurySeries.dgs6mo)
                    Text("DGS1").tag(FREDTreasurySeries.dgs1)
                    Text("DGS2").tag(FREDTreasurySeries.dgs2)
                }
                Text("仅解析你粘贴的完整单页，最多 2 MiB / 2000 记录，不联网。下方来源原始文本填 FRED JSON；可得时刻填该文档收取证据时刻。realtime_start 是 vintage 日期，不是发布时间。").font(.caption).foregroundStyle(.secondary)
                PortfolioEvidenceEditor(title: "完整原始 FRED JSON 及文档元数据", draft: $publishedRate.document)
                Text("PublishedRateRelease 数组：逐版本明确 observationDay、realtimeStart、realtimeEnd、availability；Date 使用自 2001-01-01 UTC 起的秒数。[] 表示没有已核实发布时间，不会生成合格利率。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $publishedRate.releaseJSON).font(.system(.caption, design: .monospaced)).frame(height: 90)
                Button("解析并加入本地利率证据") { importRates() }
                if let rateImportMessage { Text(rateImportMessage).font(.callout).foregroundStyle(.secondary) }
                ForEach(draft.importedRateCurves) { curve in
                    HStack {
                        Text("\(curve.id) · 已保留来源版本 \(curve.sourceVersion ?? "缺失")").font(.caption)
                        Spacer()
                        Button("移除") { draft.importedRateCurves.removeAll { $0.id == curve.id } }
                    }
                }
            }.padding(.top, 4)
        }
    }
    private func importRates() {
        do {
            let value = try publishedRate.parse()
            let existing = Set(draft.importedRateCurves.map(\.id))
            guard value.curves.allSatisfy({ !existing.contains($0.id) }) else { throw PortfolioDraftError.invalidRows }
            draft.importedRateCurves.append(contentsOf: value.curves)
            rateImportMessage = "加入 \(value.curves.count) 条；原始缺值 \(value.missingValueDays.count) 条；发布时间未核实 \(value.unverifiedReleaseDays.count) 条。缺失项没有生成利率。"
        } catch { rateImportMessage = "原始 JSON、发布版本或重复标识检查失败，没有加入部分结果。" }
    }
    private var benchmarkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("输入总回报基准", isOn: $draft.includeBenchmark)
            if draft.includeBenchmark {
                TextField("基准标识", text: $draft.benchmarkSymbol)
                Toggle("确认数值为含分红再投资的总回报指数", isOn: $draft.benchmarkIsTotalReturn)
                Text("每行：YYYY-MM-DD,总回报指数。不得粘贴普通收盘价并勾选为总回报。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.benchmarkPoints).frame(height: 90)
                PortfolioEvidenceEditor(title: "基准口径及原始记录", draft: $draft.benchmarkEvidence)
            }
        }
    }
    private func prepare() {
        do {
            let request: PerformanceRequest, raw: Data?
            if advanced { (request, raw) = try PortfolioInputDraft.decodeJSON(rawJSON) }
            else { request = try draft.build(accountID: model.selectedAccountID ?? "", calculatedAt: Date()); raw = nil }
            inputError = nil
            Task { await model.prepare(request, rawRequest: raw); if model.report != nil { section = "组合概览" } }
        } catch { inputError = "输入未通过检查：请补齐来源、原始文本、明确时区与数值；不会猜测空白内容。" }
    }
}

private struct PortfolioEvidenceEditor: View {
    let title: String
    @Binding var draft: PortfolioEvidenceDraft
    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 7) {
                Picker("证据声明", selection: $draft.kind) {
                    Text("用户明确核对").tag(PerformanceEvidenceKind.userConfirmed)
                    Text("本地来源摘录").tag(PerformanceEvidenceKind.localDocument)
                }
                TextField("来源名称", text: $draft.source)
                TextField("可追溯引用 / 版本", text: $draft.reference)
                TextField("该版本可得时刻（带时区）", text: $draft.availableAt)
                Text("粘贴原始来源文本（原样冻结，不作公开上传）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.text).font(.system(.caption, design: .monospaced)).frame(height: 75)
            }.padding(.top, 4)
        }
    }
}
private struct PortfolioDayEditor: View {
    @Binding var draft: PortfolioDayDraft
    let instruments: [String]
    let remove: () -> Void
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    TextField("交易日 YYYY-MM-DD", text: $draft.day)
                    TextField("估值时刻（带时区）", text: $draft.valuationAt)
                    Button("移除估值日", action: remove)
                }
                ForEach($draft.quotes) { $quote in
                    PortfolioQuoteEditor(draft: $quote, instruments: instruments) { draft.quotes.removeAll { $0.id == quote.id } }
                }
                Button("添加标的会话与报价") { draft.quotes.append(.init()) }
            }
        }
    }
}
private struct PortfolioQuoteEditor: View {
    @Binding var draft: PortfolioQuoteDraft
    let instruments: [String]
    let remove: () -> Void
    var body: some View {
        DisclosureGroup(draft.instrumentID.isEmpty ? "未填标的会话 / 报价" : draft.instrumentID) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("账本标的身份，例如 equity:证券ID", text: $draft.instrumentID)
                    Menu("从账本选择") { ForEach(instruments, id: \.self) { id in Button(id) { draft.instrumentID = id } } }
                    Button("移除", action: remove)
                }
                HStack { TextField("会话开盘（带时区）", text: $draft.opensAt); TextField("会话收盘（带时区）", text: $draft.closesAt) }
                PortfolioEvidenceEditor(title: "官方会话依据", draft: $draft.sessionEvidence)
                TextField("报价时刻（带时区）", text: $draft.quoteAt)
                HStack { TextField("Bid（可空）", text: $draft.bid); TextField("Ask（可空）", text: $draft.ask); TextField("Last（可空）", text: $draft.last) }
                Text("这里明确声明为原始未复权 EOD 报价。延迟、indicative 或其他口径应通过高级输入如实标注，不能改名为合格值。").font(.caption).foregroundStyle(.secondary)
                PortfolioEvidenceEditor(title: "报价版本及原始值", draft: $draft.priceEvidence)
            }.padding(.top, 4)
        }
    }
}
private struct PortfolioRateEditor: View {
    @Binding var draft: PortfolioRateDraft
    let remove: () -> Void
    var body: some View {
        DisclosureGroup("利率记录 · \(draft.source.rawValue)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("来源口径", selection: $draft.source) {
                        Text("用户显式常数（近似）").tag(PerformanceRateSource.explicitUserConstant)

                    }
                    Button("移除", action: remove)
                }
                TextField("观测时刻（带时区）", text: $draft.observationAt)
                HStack { TextField("生效时刻（带时区）", text: $draft.validFrom); TextField("截止时刻（带时区）", text: $draft.validThrough) }
                Picker("原始单位", selection: $draft.unit) {
                    Text("年百分数，例如 4.25").tag(PerformanceRateUnit.annualPercent)
                    Text("年小数，例如 0.0425").tag(PerformanceRateUnit.annualDecimal)
                }
                Text("填写一行：授权最大期限年数,原始常率。例 0.25,4.25（仅格式示例，不自动填入）。有效期必须显式填写，不无限延续。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.points).frame(height: 75)
                PortfolioEvidenceEditor(title: "利率发布版本及原始值", draft: $draft.evidence)
            }.padding(.top, 4)
        }
    }
}
private struct PortfolioAccrualEditor: View {
    @Binding var draft: PortfolioAccrualDraft
    let remove: () -> Void
    var body: some View {
        DisclosureGroup("应计 · \(draft.kind.rawValue)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("类型", selection: $draft.kind) {
                        Text("股息应收").tag(PerformanceAccrualKind.dividendReceivable)
                        Text("利息应收").tag(PerformanceAccrualKind.interestReceivable)
                        Text("费用应付").tag(PerformanceAccrualKind.feePayable)
                        Text("其他应收").tag(PerformanceAccrualKind.otherReceivable)
                        Text("其他应付").tag(PerformanceAccrualKind.otherPayable)
                    }
                    Button("移除", action: remove)
                }
                HStack { TextField("确认时刻（带时区）", text: $draft.recognizedAt); TextField("原始金额 USD", text: $draft.amount) }
                Text("已结算关联，每行：账本事件ID,金额；尚未结算留空。引擎按金额/方向/事件检查，不重复计入现金。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.settlements).frame(height: 70)
                PortfolioEvidenceEditor(title: "应计依据", draft: $draft.evidence)
            }.padding(.top, 4)
        }
    }
}
private func money(_ value: Money?) -> String { value?.decimalString ?? "不可用" }
private func number(_ value: Double?, percent: Bool = false) -> String {
    guard let value, value.isFinite else { return "不可用" }
    return String(format: percent ? "%.2f%%" : "%.4f", locale: Locale(identifier: "en_US_POSIX"), value * (percent ? 100 : 1))
}
private func timestamp(_ value: Date?) -> String {
    guard let value else { return "缺失" }
    return value.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
}
private func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else { return "无法编码完整输入" }
    return string
}
private func status(_ value: PerformanceStatus) -> String {
    switch value {
    case .available: "可用"; case .missingInput: "证据缺失"; case .insufficientSample: "样本不足"; case .shortSample: "短样本"
    case .zeroDenominator: "分母为零"; case .negativeNAV: "负 NAV"; case .segmented: "已分段"; case .unresolved: "待解决"
    case .multipleRoots: "多根"; case .notApplicable: "不适用"; case .outsideRange: "超出范围"; case .invalidInput: "输入无效"
    }
}
