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
    private let accent = Color(red: 0.0, green: 0.43, blue: 0.42)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = model.message, model.hasError { Text(message).foregroundStyle(.red).accessibilityIdentifier("investmentsMessage") }
                if let error = model.listError { Text(error).foregroundStyle(.red).accessibilityIdentifier("investmentsListError") }
                if let shareError { Text(shareError).foregroundStyle(.red) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        profit.frame(minWidth: 330, maxWidth: .infinity)
                        Divider()
                        holdings.frame(minWidth: 350, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) { profit; Divider(); holdings }
                }
                Divider()
                periodReport
                Divider()
                recentRecords
                HStack {
                    Text("本地记录 · USD · 缺失数据保留空缺").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("交易账本") { showDetail(.ledger("现金与批次")) }.accessibilityIdentifier("pageLedger")
                        Button("收益、估值证据与历史报告") { showDetail(.portfolio) }.accessibilityIdentifier("pagePortfolio")
                        Button("账本导出与备份") { showDetail(.ledger("导出与备份")) }
                    } label: { Label("高级详情", systemImage: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("investmentAdvanced")
                }
            }.frame(maxWidth: 1280, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这笔投资，赚了多少？").font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Picker("账户", selection: Binding(get: { model.selectedAccountID ?? "" }, set: { id in
                    requestReload(account: id)
                })) {
                    if model.context?.ledger.accounts.isEmpty != false { Text("尚未创建账户").tag("") }
                    ForEach(model.context?.ledger.accounts ?? []) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 260).disabled(model.isBusy).accessibilityIdentifier("investmentAccount")
                Text("USD").foregroundStyle(.secondary)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button { requestReload(account: model.selectedAccountID) } label: { Image(systemName: "arrow.clockwise") }.help("重新读取本地账本与报告").disabled(model.isBusy)
            }
            HStack(spacing: 14) {
                Button(model.context?.ledger.accounts.isEmpty == true ? "建立账户" : "其他记账") { showDetail(.ledger("手工录入")) }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.regular).disabled(model.isBusy).accessibilityIdentifier("investmentRecord")
                Button("导入交易") { showDetail(.ledger("CSV 导入")) }.buttonStyle(.plain).foregroundStyle(accent).disabled(model.isBusy).accessibilityIdentifier("investmentImport")
                Button("补齐数据并核算") { showCalculation() }.disabled(!model.canPrepare)
                    .accessibilityIdentifier("investmentStartCalculation")
                Spacer()
            }
            Text("期权成交在“期权交易”中确认，持仓与已实现盈亏自动汇总到这里，无需重复填写。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var profit: some View {
        let current = ledgerSummary
        return VStack(alignment: .leading, spacing: 8) {
            Text("累计已实现盈亏").font(.title2.weight(.semibold))
            Text(InvestmentSummary.amountText(current?.realizedPnL))
                .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                .foregroundStyle((current?.realizedPnL.amount ?? 0) < 0 ? Color.red : accent)
                .accessibilityIdentifier("investmentRealizedPnL")
            if let current {
                Text("当前账户 · 全部已入账记录 · USD").font(.callout).foregroundStyle(.secondary)
                if current.containsSyntheticRecords { Text("含合成记录 · 非真实账户业绩").foregroundStyle(.orange) }
                Text("平仓、到期等已入账结果，相关交易费用已计入。期权页记账后自动汇总，无需重复录入。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("开仓收取的权利金不是已实现利润；未平仓估值、股息、利息和独立现金收支未计入此金额。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !current.openLots.isEmpty {
                    Text("仍有未平仓持仓；浮动盈亏待估值，不能据此视为总盈亏。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if model.context?.ledger.accounts.isEmpty == true {
                Text("建立账户后，已确认的交易会在这里自动汇总。").foregroundStyle(.secondary)
            } else {
                Text("账本尚未完成读取与校验，暂不显示盈亏金额。").foregroundStyle(.secondary)
            }
        }
    }

    private var periodReport: some View {
        let summary = reportSummary
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("冻结区间报告").font(.title2.weight(.semibold))
                Spacer()
                Button { prepareShare() } label: { Label("分享区间报告", systemImage: "square.and.arrow.up") }
                    .disabled(model.isBusy || model.savedReport == nil || summary?.netPnL == nil).accessibilityIdentifier("investmentShare")
            }
            if let summary {
                if summary.containsSyntheticEvidence { Text("合成示例 · 非真实账户业绩").foregroundStyle(.orange) }
                HStack {
                    Text("\(summary.startDay) → \(summary.endDay)").foregroundStyle(.secondary)
                    Spacer()
                    Text("区间净盈亏")
                    Text(InvestmentSummary.amountText(summary.netPnL)).monospacedDigit()
                        .foregroundStyle((summary.netPnL?.amount ?? 0) < 0 ? Color.red : accent)
                        .accessibilityIdentifier("investmentNetPnL")
                    Text("USD").foregroundStyle(.secondary)
                }
                if let reason = summary.unavailableReason { Text(reason).font(.callout).foregroundStyle(.orange) }
                if summary.usesStalePrices { Text("含 STALE 价格，仅用于账本估值。").foregroundStyle(.orange).font(.caption) }
                DisclosureGroup("查看区间数据") {
                    reportDetails(summary)
                }
                if model.savedReport?.isCurrentLedger == false {
                    Text("这是历史账本报告；新记账已更新上方汇总，尚未计入这份冻结报告。")
                        .foregroundStyle(.orange).font(.callout)
                    Button("复用资料，核算新账本") { showCalculation() }.disabled(!model.canPrepare)
                }
            } else {
                Text("如需区间净盈亏和浮动盈亏，请补齐估值与现金流资料并核算；不影响上方已实现盈亏和当前持仓。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("补齐数据并核算") { showCalculation() }.foregroundStyle(accent).disabled(!model.canPrepare).accessibilityIdentifier("investmentPrepareReturn")
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

    private var holdings: some View {
        let current = ledgerSummary
        return VStack(alignment: .leading, spacing: 10) {
            Text("当前持仓").font(.title2.weight(.semibold))
            HStack { Text("标的 / 数量"); Spacer(); Text("市值 / 浮动盈亏") }.font(.caption).foregroundStyle(.secondary)
            Divider()
            if let current {
                if current.openLots.isEmpty { Text("当前账户没有未平仓持仓。").foregroundStyle(.secondary) }
                ForEach(current.openLots) { lot in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lot.instrument.label).font(.headline)
                            Text(lotQuantity(lot)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("待估值").foregroundStyle(.secondary)
                    }
                    Divider()
                }
                HStack { Text("账本现金（不是利润）"); Spacer(); Text(InvestmentSummary.amountText(current.cash)).monospacedDigit() }
            } else {
                Text(model.context?.ledger.accounts.isEmpty == true ? "建立账户后显示持仓。" : "持仓待读取与校验。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lotQuantity(_ lot: LedgerLot) -> String {
        let unit: String
        switch lot.instrument { case .equity: unit = " 股"; case .option: unit = " 张期权" }
        return lot.quantityRemaining.decimalString + unit + (lot.side == .long ? " · 多头" : " · 空头")
    }

    private var recentRecords: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("最近记录").font(.title2.weight(.semibold)); Spacer(); Button("查看全部 ›") { showDetail(.ledger("来源与审计")) }.buttonStyle(.plain).foregroundStyle(accent) }
            if events.isEmpty { Text("交易、费用与出入金会出现在这里。").foregroundStyle(.secondary) }
            ForEach(events) { event in
                HStack(spacing: 14) {
                    Text(event.effectiveAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Text(eventTitle(event)).frame(maxWidth: .infinity, alignment: .leading)
                    if model.context?.ledger.state.reversedEventIDs.contains(event.id) == true { Text("已冲销").font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
            }
        }
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
