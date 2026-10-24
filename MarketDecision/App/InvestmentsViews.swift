import SwiftUI
import Charts
import AppComposition
import CoreDomain
import PortfolioEngine
import Persistence

/// The everyday portfolio entry. Detailed evidence and import confirmations keep
/// their existing storage contracts on secondary pages.
struct InvestmentsPage: View {
    let workspace: WorkspaceModel
    @State private var model: PortfolioWorkspaceModel?
    @State private var failed = false
    @State private var attempt = UUID()
    var body: some View {
        Group {
            if let model { InvestmentsContent(workspace: workspace, model: model) }
            else if failed {
                ContentUnavailableView("投资记录暂不可用", systemImage: "book.closed", description: Text("本地账本未通过读取检查，已有数据保留。"))
                Button("重试") { attempt = UUID() }
            } else { ProgressView("正在打开我的投资…") }
        }
        .task(id: "\(workspace.isPrepared)-\(attempt)") {
            guard workspace.isPrepared else { return }
            do {
                failed = false
                let ready = try await workspace.makePortfolioWorkspaceModel()
                try Task.checkCancellation(); model = ready
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private enum InvestmentDetail: Identifiable {
    case ledger(String), portfolio, calculation
    var id: String {
        switch self { case .ledger(let section): "ledger-" + section; case .portfolio: "portfolio"; case .calculation: "calculation" }
    }
}

private struct InvestmentsContent: View {
    let workspace: WorkspaceModel
    @Bindable var model: PortfolioWorkspaceModel
    @State private var detail: InvestmentDetail?
    @State private var detailAccountID: String?
    @State private var share: InvestmentShareSnapshot?
    @State private var reloadID = UUID()
    @State private var requestedAccountID: String?
    @State private var preferredReportID: UUID?
    @State private var continueToCalculation = false
    @State private var shareError: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var contributionPeriod = "全部"
    @State private var showsPeriodReport = false
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.38, green: 0.78, blue: 0.72)
            : Color(red: 0.06, green: 0.36, blue: 0.33)
    }
    private var lossColor: Color { Color(red: 0.72, green: 0.22, blue: 0.14) }
    private var reportSummary: InvestmentSummary? { model.report.map(InvestmentSummary.init) }
    private var ledgerSummary: InvestmentLedgerSummary? {
        guard let ledger = model.context?.ledger, let account = model.selectedAccountID else { return nil }
        return try? InvestmentLedgerSummary(ledger: ledger, accountID: account)
    }
    private var events: [LedgerEvent] { Array((model.context?.ledger.events.filter { $0.accountID == model.selectedAccountID } ?? []).sorted { $0.effectiveAt > $1.effectiveAt }.prefix(5)) }

    var body: some View {
        Group {
            if let detail {
                detailShell {
                    switch detail {
                    case .ledger(let section): LedgerPage(workspace: workspace, initialSection: section, initialAccountID: detailAccountID,
                        onContinueToCalculation: { account in
                            continueToCalculation = true; self.detail = nil; requestReload(account: account)
                        })
                    case .portfolio: PortfolioPage(workspace: workspace, initialAccountID: detailAccountID)
                    case .calculation: InvestmentCalculationView(model: model) { id in
                        preferredReportID = id; self.detail = nil; requestReload(account: detailAccountID)
                    }
                    }
                }
            } else { dashboard }
        }
        .sheet(item: $share) { InvestmentShareSheet(snapshot: $0) }
        .task(id: "\(detail?.id ?? "overview")-\(reloadID)") {
            guard detail == nil else { return }
            let requested = requestedAccountID ?? model.selectedAccountID
            await model.load()
            guard !Task.isCancelled, model.context != nil else { return }
            if let requested, model.selectedAccountID != requested { await model.chooseAccount(requested) }
            guard !Task.isCancelled, model.context != nil else { return }
            let account = model.selectedAccountID
            if let preferred = preferredReportID {
                preferredReportID = nil
                await model.open(preferred)
            } else if let newest = model.saved.filter({ $0.accountID == account }).max(by: { $0.createdAt < $1.createdAt }) {
                await model.open(newest.id)
            }
            guard !Task.isCancelled, detail == nil else { return }
            if continueToCalculation {
                continueToCalculation = false
                if model.preparationBaseline != nil { showCalculation() }
            }
        }
        .onDisappear { model.disappear(); shareError = nil; share = nil }
    }

    private var dashboard: some View {
        let current = ledgerSummary
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(current)
                if let message = model.message, model.hasError { Text(message).foregroundStyle(.red).accessibilityIdentifier("investmentsMessage") }
                if let error = model.listError { Text(error).foregroundStyle(.red).accessibilityIdentifier("investmentsListError") }
                if let shareError { Text(shareError).foregroundStyle(.red) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        profit(current).frame(minWidth: 310, maxWidth: 450)
                        contributions(current).frame(minWidth: 400, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) { profit(current); contributions(current) }
                }
                Divider()
                holdings(current)
                Divider()
                recentRecords(current)
                periodReport
                footer
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ current: InvestmentLedgerSummary?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("投资概览").font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
                if current?.containsSyntheticRecords == true {
                    Text("含合成记录 · 非真实账户业绩")
                        .font(.caption.weight(.medium)).foregroundStyle(accent)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(accent.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 8)
                Button("生成区间报告") { showCalculation() }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.regular)
                    .disabled(!model.canPrepare).accessibilityIdentifier("investmentGenerateReport")
                Button { requestReload(account: model.selectedAccountID) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered).tint(accent).help("重新读取本地账本与报告")
                .disabled(model.isBusy).accessibilityLabel("刷新投资概览")
            }
            HStack(spacing: 12) {
                Picker("账户", selection: Binding(get: { model.selectedAccountID ?? "" }, set: { id in
                    requestReload(account: id)
                })) {
                    if model.context?.ledger.accounts.isEmpty != false { Text("尚未创建账户").tag("") }
                    ForEach(model.context?.ledger.accounts ?? []) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 210).tint(accent)
                .disabled(model.isBusy).accessibilityLabel("账户").accessibilityIdentifier("investmentAccount")
                Text("USD").foregroundStyle(.secondary)
                Divider().frame(height: 14)
                if let date = current?.latestActivityAt {
                    Text("最近生效日期 " + date.formatted(date: .numeric, time: .omitted)).foregroundStyle(.secondary)
                } else { Text("本地账本").foregroundStyle(.secondary) }
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if model.context?.ledger.accounts.isEmpty == true {
                    Button("建立账户") { showDetail(.ledger("手工录入")) }
                        .buttonStyle(.bordered).tint(accent).disabled(model.isBusy).accessibilityIdentifier("investmentRecord")
                }
            }.font(.callout)
        }
    }

    private func profit(_ current: InvestmentLedgerSummary?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("累计已实现盈亏").font(.headline)
            Text(investmentCurrency(current?.realizedPnL))
                .font(.system(size: 42, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle((current?.realizedPnL.amount ?? 0) < 0 ? lossColor : accent)
                .accessibilityIdentifier("investmentRealizedPnL")
            Text("全部已入账记录 · 含相关交易费用").font(.caption).foregroundStyle(.secondary)
            InvestmentRealizedChart(points: current?.realizedTimeline ?? [], accent: accent)
            Divider().padding(.vertical, 3)
            HStack {
                Text("未实现盈亏").foregroundStyle(.secondary)
                Spacer()
                Text(current == nil ? "待读取" : current?.openLots.isEmpty == true ? "无未平仓持仓" : "待估值")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack {
                Text("账本现金").foregroundStyle(.secondary)
                Spacer()
                Text(investmentCurrency(current?.cash, signed: false)).font(.headline).monospacedDigit()
            }
            if current == nil {
                Text(model.context?.ledger.accounts.isEmpty == true ? "建立账户，在期权交易中确认成交后自动汇总。" : "账本待读取与校验，暂不显示金额。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(colorScheme == .dark ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private func contributions(_ current: InvestmentLedgerSummary?) -> some View {
        let timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: Date())
        let rows: [InvestmentRealizedContribution]?
        if contributionPeriod == "全部" { rows = current?.realizedContributions }
        else if let current { rows = try? current.realizedContributions(inYear: year, timeZone: timeZone) }
        else { rows = nil }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("已实现盈亏贡献").font(.system(size: 20, weight: .semibold))
                Picker("贡献期间", selection: $contributionPeriod) {
                    Text("全部").tag("全部")
                    Text("本年").tag("本年")
                }.labelsHidden().pickerStyle(.menu).frame(width: 86).tint(accent)
                    .accessibilityLabel("贡献期间").accessibilityIdentifier("investmentContributionPeriod")
                Spacer(minLength: 0)
            }
            InvestmentContributionChart(rows: rows ?? [], available: current != nil && rows != nil, accent: accent, lossColor: lossColor)
            Text(contributionPeriod == "全部" ? "按标的汇总已入账平仓、到期等结果 · USD" : "\(year) 年 · 美东时间 · 按标的汇总已实现结果 · USD")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("期权实际成交自动汇总 · 权利金收入不等于已实现利润")
                Text("现金不是利润；缺少价格时，市值与浮动盈亏保留空缺。")
            }.font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Menu {
                if model.context?.ledger.accounts.isEmpty == false {
                    Button("其他记账") { showDetail(.ledger("手工录入")) }
                        .disabled(model.isBusy).accessibilityIdentifier("investmentRecord")
                }
                Button("导入交易") { showDetail(.ledger("CSV 导入")) }
                    .disabled(model.isBusy).accessibilityIdentifier("investmentImport")
                Button("补齐数据并核算") { showCalculation() }.disabled(!model.canPrepare)
                    .accessibilityIdentifier("investmentStartCalculation")
                Divider()
                Button("交易账本") { showDetail(.ledger("现金与批次")) }.accessibilityIdentifier("pageLedger")
                Button("收益、估值证据与历史报告") { showDetail(.portfolio) }.accessibilityIdentifier("pagePortfolio")
                Button("账本导出与备份") { showDetail(.ledger("导出与备份")) }
            } label: { Label("高级详情", systemImage: "slider.horizontal.3") }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(accent).accessibilityIdentifier("investmentAdvanced")
        }
    }

    private var periodReport: some View {
        let summary = reportSummary
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                DisclosureGroup(isExpanded: $showsPeriodReport) {
                    if let summary {
                        if let reason = summary.unavailableReason { Text(reason).font(.callout).foregroundStyle(.orange) }
                        reportDetails(summary)
                    } else {
                        Text("尚无区间报告。已实现盈亏与持仓已自动汇总；区间净盈亏仍需估值与完整现金流证据。")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("冻结区间报告").font(.callout.weight(.medium))
                        if let summary {
                            Text("\(summary.startDay) → \(summary.endDay)").font(.caption).foregroundStyle(.secondary)
                            Text(InvestmentSummary.amountText(summary.netPnL) + " USD")
                                .font(.callout.weight(.medium)).monospacedDigit()
                                .foregroundStyle((summary.netPnL?.amount ?? 0) < 0 ? lossColor : accent)
                                .accessibilityIdentifier("investmentNetPnL")
                        }
                    }
                }.accessibilityIdentifier("investmentPeriodReport")
                Spacer(minLength: 0)
                Button { prepareShare() } label: { Label("分享区间报告", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.plain).foregroundStyle(accent)
                    .disabled(model.isBusy || model.savedReport == nil || summary?.netPnL == nil).accessibilityIdentifier("investmentShare")
            }
            if let summary, summary.containsSyntheticEvidence || summary.usesStalePrices {
                HStack(spacing: 12) {
                    if summary.containsSyntheticEvidence { Text("合成示例 · 非真实账户业绩") }
                    if summary.usesStalePrices { Text("含 STALE 价格 · 仅作账本估值") }
                }.font(.caption).foregroundStyle(.orange)
            }
            if model.savedReport?.isCurrentLedger == false {
                Text("历史账本报告，未包含新入账记录。").foregroundStyle(.orange).font(.caption)
            }
        }
    }

    private func reportDetails(_ summary: InvestmentSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                metric("区间已实现", value: summary.realizedPnL)
                Divider().frame(height: 38)
                metric("区间浮动变化", value: summary.changeInUnrealizedPnL)
            }
            Text("已扣外部资金流；总额另含股息、利息、费用、税款及应计变化。").font(.caption).foregroundStyle(.secondary)
            if let report = model.report { navChart(report) }
        }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, value: Money?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(InvestmentSummary.amountText(value)).font(.title2.weight(.semibold)).monospacedDigit()
        }
    }

    private func holdings(_ current: InvestmentLedgerSummary?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前持仓").font(.system(size: 20, weight: .semibold))
                Spacer()
                Text("持仓市值").font(.callout).foregroundStyle(.secondary)
                Text(current == nil ? "待读取" : current?.openLots.isEmpty == true ? "无持仓" : "待估值")
                    .font(.headline).foregroundStyle(.secondary)
            }
            HStack {
                Text("标的").frame(maxWidth: .infinity, alignment: .leading)
                Text("数量 / 方向").frame(width: 150, alignment: .leading)
                Text("市值").frame(width: 120, alignment: .trailing)
                Text("浮动盈亏").frame(width: 120, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            if let current {
                if current.openLots.isEmpty { Text("当前没有未平仓持仓。").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(current.openLots.prefix(5))) { lot in
                    HStack(spacing: 8) {
                        Text(lot.instrument.label).font(.callout.weight(.medium))
                            .lineLimit(1).help(lot.instrument.label).frame(maxWidth: .infinity, alignment: .leading)
                        Text(lotQuantity(lot)).font(.callout).frame(width: 150, alignment: .leading)
                        Text("待估值").frame(width: 120, alignment: .trailing)
                        Text("待估值").frame(width: 120, alignment: .trailing)
                    }.foregroundStyle(.primary).padding(.vertical, 2)
                    Divider()
                }
                if !current.openLots.isEmpty {
                    HStack {
                        Text("按开仓批次展示 · 市值需要另行核对价格").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if current.openLots.count > 5 {
                            Button("查看全部 \(current.openLots.count) 个批次 ›") { showDetail(.ledger("现金与批次")) }
                                .buttonStyle(.plain).foregroundStyle(accent)
                        }
                    }
                }
            } else {
                Text(model.context?.ledger.accounts.isEmpty == true ? "建立账户后显示持仓。" : "持仓待读取与校验。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func lotQuantity(_ lot: LedgerLot) -> String {
        let unit: String
        switch lot.instrument { case .equity: unit = " 股"; case .option: unit = " 张" }
        return lot.quantityRemaining.decimalString + unit + (lot.side == .long ? " · 多头" : " · 空头")
    }

    private func recentRecords(_ current: InvestmentLedgerSummary?) -> some View {
        HStack(spacing: 18) {
            Text("最近记录").font(.headline)
            if let event = events.first {
                Text(event.effectiveAt.formatted(date: .numeric, time: .omitted)).font(.callout).foregroundStyle(.secondary)
                Text(eventTitle(event)).font(.callout).lineLimit(1).help(eventTitle(event))
                if model.context?.ledger.state.reversedEventIDs.contains(event.id) == true {
                    Text("已冲销").font(.caption).foregroundStyle(.secondary)
                } else if let point = current?.realizedTimeline.first(where: { $0.id == event.id }) {
                    Text(investmentCurrency(point.eventPnL)).font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(point.eventPnL.amount < 0 ? lossColor : accent)
                }
            } else { Text("确认实际成交后自动显示").font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Button("查看全部 ›") { showDetail(.ledger("来源与审计")) }.buttonStyle(.plain).foregroundStyle(accent)
        }.padding(.vertical, 2)
    }

    private func eventTitle(_ event: LedgerEvent) -> String {
        switch event.payload {
        case .cash(let cash):
            let title: String
            switch cash.kind {
            case .deposit: title = "入金（不计利润）"
            case .withdrawal: title = "出金（不计亏损）"
            case .dividend: title = "现金股息"
            case .interest: title = "利息"
            case .fee: title = "费用"
            case .dividendWithholding, .interestWithholding, .otherTax: title = "税费"
            }
            return title + " · " + cash.amount.decimalString + " USD"
        case .trade(let trade): return trade.instrument.label + (trade.side == .buy ? " · 买入 " : " · 卖出 ") + trade.quantity.decimalString + " · " + trade.unitPrice.decimalString + " USD"
        case .optionSettlement(let item): return item.contract.occSymbol + " · " + item.action.rawValue
        case .reversal: return "冲销记录"
        default: return "公司行动 / 转仓 · " + event.payload.kind
        }
    }

    private struct Point: Identifiable { let id: String; let order: Int; let amount: Double; let segment: Int }
    private func navChart(_ report: PerformanceReport) -> some View {
        var points: [Point] = [], segment = 0
        for (index, day) in report.daily.enumerated() {
            if let amount = day.nav.flatMap({ Double($0.decimalString) }), amount.isFinite { points.append(.init(id: day.day, order: index, amount: amount, segment: segment)) }
            else { segment += 1 }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Chart(points) { point in LineMark(x: .value("估值日", point.order), y: .value("净资产", point.amount), series: .value("连续段", point.segment)).foregroundStyle(accent) }
                .chartXAxis(.hidden).frame(height: 95).accessibilityLabel("净资产走势，包含出入金影响；不是盈亏曲线")
            Text("净资产走势 · 包含出入金影响，非盈亏曲线").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detailShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { detail = nil; requestReload(account: detailAccountID) } label: { Label("返回我的投资", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(accent).accessibilityIdentifier("investmentBack")
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 10)
            content()
        }
    }
    private func showDetail(_ value: InvestmentDetail) {
        detailAccountID = model.selectedAccountID
        model.disappear(); share = nil; detail = value
    }
    private func showCalculation() {
        guard model.preparationBaseline != nil else { return }
        detailAccountID = model.selectedAccountID
        share = nil; shareError = nil; detail = .calculation
    }
    private func requestReload(account: String?) {
        model.disappear(); share = nil; shareError = nil
        requestedAccountID = account; reloadID = UUID()
    }
    private func prepareShare() {
        guard model.origin == .frozen, let saved = model.savedReport, saved.report == model.report,
              saved.report.input.request.accountID == model.selectedAccountID else { return }
        do { share = try InvestmentShareSnapshot(saved: saved); shareError = nil }
        catch { shareError = "只有已复算且盈亏对账完整的冻结报告可以生成分享卡片。" }
    }
}

/// Money remains exact in the summary; Double is used only for chart coordinates.
private struct InvestmentRealizedChart: View {
    let points: [InvestmentRealizedPoint]
    let accent: Color
    private struct PlotPoint: Identifiable { let id: String; let date: Date; let value: Double }

    var body: some View {
        let plot = chartPoints
        Group {
            if plot.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "chart.xyaxis.line").font(.title2)
                    Text("平仓或到期入账后显示走势").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                Chart(plot) { point in
                    AreaMark(x: .value("日期", point.date), y: .value("累计已实现盈亏", point.value))
                        .interpolationMethod(.stepEnd).foregroundStyle(accent.opacity(0.08))
                    LineMark(x: .value("日期", point.date), y: .value("累计已实现盈亏", point.value))
                        .interpolationMethod(.stepEnd).lineStyle(StrokeStyle(lineWidth: 1.5)).foregroundStyle(accent)
                    if plot.count < 20 {
                        PointMark(x: .value("日期", point.date), y: .value("累计已实现盈亏", point.value))
                            .symbolSize(16).foregroundStyle(accent)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .accessibilityLabel("全部已入账记录的累计已实现盈亏走势，不含未平仓估值")
            }
        }.frame(height: 112).padding(.vertical, 4)
    }

    private var chartPoints: [PlotPoint] {
        var result: [PlotPoint] = []
        for point in points {
            guard let value = Double(point.cumulativePnL.decimalString), value.isFinite else { continue }
            let plotted = PlotPoint(id: point.id, date: point.date, value: value)
            // Equal timestamps have no visible elapsed interval. Keep the final
            // cumulative total instead of plotting an arbitrary intrainstant spike.
            if result.last?.date == point.date { result[result.count - 1] = plotted }
            else { result.append(plotted) }
        }
        return result
    }
}

private struct InvestmentContributionChart: View {
    let rows: [InvestmentRealizedContribution]
    let available: Bool
    let accent: Color
    let lossColor: Color
    private struct PlotRow: Identifiable { let id: String; let symbol: String; let value: Double; let amount: Money }

    var body: some View {
        let plot = rows.compactMap { row -> PlotRow? in
            guard let value = Double(row.amount.decimalString), value.isFinite else { return nil }
            return .init(id: row.id, symbol: row.symbol, value: value, amount: row.amount)
        }
        let low = min(plot.map(\.value).min() ?? 0, 0)
        let high = max(plot.map(\.value).max() ?? 0, 0)
        let margin = max(high - low, 1) * 0.25
        Group {
            if plot.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title2)
                    Text(available ? "所选期间暂无已实现记录" : "账本待读取与校验").font(.callout)
                    Text("确认实际成交后自动汇总，不使用示例金额。").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    Chart {
                        ForEach(plot) { row in
                            BarMark(xStart: .value("零", 0), xEnd: .value("已实现盈亏", row.value), y: .value("标的", row.symbol), height: .ratio(0.52))
                                .foregroundStyle(row.value < 0 ? lossColor.opacity(0.80) : accent.opacity(0.78))
                                .annotation(position: row.value < 0 ? .leading : .trailing, spacing: 6) {
                                    Text(investmentCurrency(row.amount)).font(.caption.weight(.medium)).monospacedDigit()
                                        .foregroundStyle(row.value < 0 ? lossColor : accent)
                                }
                        }
                        RuleMark(x: .value("零", 0)).foregroundStyle(.secondary.opacity(0.35))
                    }
                    .chartXScale(domain: (low - margin)...(high + margin))
                    .chartYScale(domain: plot.map(\.symbol))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            AxisValueLabel()
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisValueLabel {
                                if let symbol = value.as(String.self) { Text(symbol).lineLimit(1).help(symbol) }
                            }
                        }
                    }
                    .frame(height: max(202, CGFloat(plot.count) * 36))
                    .padding(.top, 2)
                    .accessibilityLabel("所选期间按标的汇总的已实现盈亏贡献，USD")
                }
            }
        }.frame(height: 220).accessibilityIdentifier("investmentContributionChart")
    }
}

/// Decimal rounding is shared with the ledger; grouping never converts Money to Double.
private func investmentCurrency(_ value: Money?, signed: Bool = true) -> String {
    guard let value, let posted = try? value.posted(), let fixed = try? posted.fixedString() else { return "—" }
    let magnitude = fixed.hasPrefix("-") ? String(fixed.dropFirst()) : fixed
    let parts = magnitude.split(separator: ".", omittingEmptySubsequences: false)
    let digits = Array(parts[0])
    let groups = stride(from: digits.count, to: 0, by: -3).map { end in
        String(digits[max(0, end - 3)..<end])
    }.reversed().joined(separator: ",")
    let fraction = parts.count > 1 ? "." + String(parts[1]) : ".00"
    let sign = posted.amount < 0 ? "-" : (signed && posted.amount > 0 ? "+" : "")
    return sign + "$" + groups + fraction
}
