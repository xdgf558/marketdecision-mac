import SwiftUI
import Charts
import AppComposition
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine
import Persistence

struct OptionLabPage: View {
    let workspace: WorkspaceModel
    @State private var model: OptionLabWorkspaceModel?
    @State private var failed = false
    @State private var attempt = UUID()
    var body: some View {
        Group {
            if let model { OptionLabContent(model: model, workspace: workspace) }
            else if failed {
                ContentUnavailableView("期权交易暂不可用", systemImage: "chart.xyaxis.line", description: Text("本地快照库未能打开，不显示旧计算结果。"))
                Button("重新打开") { attempt = UUID() }
            } else { ProgressView("正在打开期权交易工作区…") }
        }
        .task(id: "\(workspace.isPrepared)-\(attempt)") {
            guard workspace.isPrepared else { return }
            do {
                failed = false
                if model == nil {
                    let ready = try await workspace.makeOptionLabWorkspaceModel()
                    try Task.checkCancellation(); model = ready
                }
                await model?.load()
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct OptionTradePresentation: Identifiable {
    let id = UUID()
    let opening: OptionLabInputDraft?
}

/// Presentation identity and its authorization baseline travel together. A bool
/// popover must not capture separate, initially nil State values on first open.
private struct OptionExpiryPresentation: Identifiable {
    let id = UUID()
    let draft: OptionLabInputDraft
    let session: UUID
    let navigation: UUID
    let initialDate: Date
}

struct OptionLabContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: OptionLabWorkspaceModel
    let workspace: WorkspaceModel
    @State private var tradePresentation: OptionTradePresentation?
    @State private var draft = OptionLabInputDraft()
    @State private var section = "输入"
    @State private var inputError: String?
    @State private var ledgerAccount = ""
    @State private var ledgerSecurityID = ""
    @State private var completeness = ""
    @State private var ledgerCandidate: OptionLabLedgerBasis?
    @State private var preparingLedger = false
    @State private var visibleSession = UUID()
    @State private var navigationEpoch = UUID()
    @State private var advancedToolsExpanded = false
    @State private var quoteDetailsExpanded = false
    @State private var pricingExpanded = false
    @State private var chartDetailsExpanded = false
    @State private var advancedAssumptionsExpanded = false
    @State private var manualQuoteAt = Date()
    @State private var manualSettlementAt = Date()
    @State private var manualQuoteReference = ""
    @State private var manualExpiryReference = ""
    @State private var manualCommonTimeConfirmed = false
    @State private var manualAssistanceMessage: String?
    @State private var checklist: OptionDailyChecklist?
    @State private var checkedDraft: OptionLabInputDraft?
    @State private var synchronizeProtectionQuantity = false
    @State private var useEnteredChartPrices = false
    @State private var ledgerExpanded = false
    @State private var inputTarget = ""
    @State private var inputFocusRequest = UUID()
    // Bind the editable form to the exact report produced from it. History opens
    // stay read-only until the user explicitly copies the frozen input to edit.
    @State private var calculatedDraft: OptionLabInputDraft?
    @State private var calculatedReportID: UUID?
    @State private var expiryPresentation: OptionExpiryPresentation?
    private var accent: Color { colorScheme == .dark ? Color(red: 0.48, green: 0.77, blue: 0.68) : Color(red: 0.10, green: 0.34, blue: 0.31) }
    private let advancedSections = ["期权链", "模型分析", "风险与情景", "数据对照", "组合风险", "波动率历史", "期权归档"]
    private var blocked: Bool { model.isBusy || preparingLedger }
    private var currentDraftReport: OptionLabReport? {
        guard calculatedDraft == draft, let report = model.report,
              report.input.id == calculatedReportID else { return nil }
        return report
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            header
                            if section == "输入" {
                                referenceWorkspace(wide: geometry.size.width >= 880)
                            } else {
                                if model.message != nil || inputError != nil { statusMessages }
                                sectionContent
                                advancedNavigation
                            }
                        }
                        .frame(maxWidth: 1400, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }.id(section)
                    .onChange(of: inputFocusRequest) { _, _ in
                        withAnimation { proxy.scrollTo(inputTarget, anchor: .top) }
                    }
                    if section == "输入" {
                        // Keep submission actions reachable even when an error,
                        // advanced input or a smaller window needs scrolling.
                        referenceActions
                            .frame(maxWidth: 1400, alignment: .leading)
                            .padding(.horizontal, 20).padding(.bottom, 8)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }.tint(accent)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
        .sheet(item: $tradePresentation) { presentation in
            OptionTradeSheet(workspace: workspace, opening: presentation.opening)
        }
        .onAppear { model.personalHistory?.appear() }
        .onChange(of: draft) { _, _ in
            calculatedDraft = nil; calculatedReportID = nil; expiryPresentation = nil
            model.draftChanged(); inputError = nil
            if checkedDraft != draft { checklist = nil; checkedDraft = nil }
            if ledgerCandidate?.capital != draft.ledgerBasis?.capital { ledgerCandidate = nil }
        }
        .onChange(of: section) { _, _ in navigationEpoch = UUID(); expiryPresentation = nil }
        .onChange(of: blocked) { _, busy in if busy { expiryPresentation = nil } }
        .onChange(of: model.ledgerSnapshot?.revision) { _, _ in
            ledgerCandidate = nil
            if model.ledgerSnapshot?.accounts.contains(where: { $0.id == ledgerAccount }) != true { ledgerAccount = "" }
        }
        .onChange(of: ledgerAccount) { _, _ in ledgerCandidate = nil }
        .onChange(of: ledgerSecurityID) { _, _ in ledgerCandidate = nil }
        .onChange(of: completeness) { _, _ in ledgerCandidate = nil }
        .onDisappear { visibleSession = UUID(); expiryPresentation = nil; preparingLedger = false; tradePresentation = nil; model.disappear() }
    }
    @ViewBuilder private var sectionContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if section == "数据对照", let evidence = model.evidence { OptionEvidenceContent(model: evidence) }
            else if section == "组合风险", let portfolio = model.portfolioGreeks { PortfolioGreeksContent(model: portfolio) }
            else if section == "期权链", let chain = model.chain {
                OptionChainContent(model: chain, history: model.history) { imported, stillCurrent in
                    let session = visibleSession, navigation = navigationEpoch
                    guard section == "期权链", stillCurrent(), !Task.isCancelled else { throw CancellationError() }
                    try await model.prepareChainDraft(imported)
                    guard visibleSession == session, navigationEpoch == navigation,
                          section == "期权链", stillCurrent(), !Task.isCancelled else { return }
                    draft = imported; ledgerCandidate = nil
                    inputError = nil; section = "输入"
                }
            }
            else if section == "波动率历史", let history = model.history { OptionHistoryContent(model: history) }
            else if section == "期权归档", let transfer = model.transfer { OptionArchiveTransferContent(model: transfer) }
            else if section == "已保存" { history }
            else if section == "结果" { dailyResults }
            else if let report = model.report {
                if section == "模型分析" { pricingAnalysis(report) }
                else if section == "风险与情景" { riskAndScenarioAnalysis(report) }
                else { result(report) }
            }
            else {
                ContentUnavailableView("尚无已核对计算", systemImage: "chart.xyaxis.line",
                    description: Text("填写完整输入并计算，或显式载入合成模板。修改输入后，旧结果立即失效。"))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("期权交易").font(.system(size: 22, weight: .bold)).fixedSize()
            dailyNavigation
            if blocked { ProgressView().controlSize(.small) }
            Button("我的持仓 · 平仓/到期") { tradePresentation = .init(opening: nil) }
                .buttonStyle(OptionReferenceButtonStyle(.outline)).disabled(blocked)
                .accessibilityIdentifier("optionTradePositions")
            Button("载入示例") { loadExample() }
                .buttonStyle(OptionReferenceButtonStyle(.subtle))
                .disabled(blocked).accessibilityIdentifier("optionLabTemplate")
            Label(saveStatus, systemImage: displayedReport != nil && model.savedID != nil ? "checkmark.circle" : "circle.dashed")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                .accessibilityIdentifier("optionReferenceSaveStatus")
        }
    }
    private var displayedReport: OptionLabReport? { section == "输入" ? currentDraftReport : model.report }
    private var saveStatus: String {
        guard displayedReport != nil else { return "待计算" }
        return model.savedID == nil ? "测算未保存" : "测算已保存 · 未入账"
    }
    private var statusMessages: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.message {
                Text(message).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("optionLabMessage")
            }
            if let inputError { Text(inputError).foregroundStyle(.red).accessibilityIdentifier("optionLabInputError") }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    private func loadExample() {
        guard !blocked else { return }
        do {
            let example = try OptionLabInputDraft.synthetic(strategy: draft.strategy)
            calculatedDraft = nil; calculatedReportID = nil
            model.draftChanged(); draft = example; ledgerCandidate = nil
            section = "输入"; quoteDetailsExpanded = false; pricingExpanded = false
            checklist = nil; checkedDraft = nil
            manualAssistanceMessage = nil; manualCommonTimeConfirmed = false
        } catch { inputError = "合成模板未能建立，没有填入替代值。" }
    }
    private func resetDraft() {
        guard !blocked else { return }
        calculatedDraft = nil; calculatedReportID = nil
        model.draftChanged(); draft = .init(); ledgerCandidate = nil
        section = "输入"; quoteDetailsExpanded = false; pricingExpanded = false
        manualAssistanceMessage = nil; manualCommonTimeConfirmed = false
        checklist = nil; checkedDraft = nil
        synchronizeProtectionQuantity = false; useEnteredChartPrices = false
    }
    private func referenceWorkspace(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("填合约测算 → 确认实际开仓 → 平仓/到期结清")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("optionDailyTradeFlow")
            referenceSummary(wide: wide).id("option-reference-summary")
            Divider()
            compactContract(wide: wide)
            if quoteDetailsExpanded { editor }
            if model.message != nil || inputError != nil { statusMessages }
            advancedNavigation
        }
    }
    private func referenceSummary(wide: Bool) -> some View {
        let report = currentDraftReport
        let outcome = report?.selectedOutcome
        let isPut = draft.strategy == .cashSecuredPut
        let isCoveredCall = draft.strategy == .coveredCall
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("测算结果").font(.system(size: 17, weight: .semibold))
                Text(draft.origin == .synthetic ? "示例数据" : "手工假设")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(accent.opacity(0.08), in: Capsule())
                    .accessibilityIdentifier("optionLabOrigin")
                if isCoveredCall {
                    Text("现价口径 · 股票＋本次期权")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("optionLabForwardBasis")
                }
                Spacer(minLength: 8)
                if isCoveredCall {
                    Text("净权利金").font(.caption).foregroundStyle(.secondary)
                    Text(displayMoney(outcome?.netCreditTotal)).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent).monospacedDigit().accessibilityIdentifier("optionLabSummaryNetPremium")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: wide ? 4 : 2),
                      alignment: .leading, spacing: 8) {
                OptionReferenceMetric(title: "最大收益", value: displayMoney(outcome?.maxProfit),
                    tone: outcome.map { $0.maxProfit.amount < 0 } == true ? .negative : .positive,
                    accessibilityIdentifier: "optionLabMaxProfit")
                referenceMetric(title: "最大亏损", value: displayMoney(outcome?.maxLoss),
                    footnote: report == nil ? nil : "到期口径 · 已计费用", tone: .negative,
                    identifier: "optionLabMaxLoss", divider: true, wide: wide)
                referenceMetric(title: "盈亏平衡价", value: outcome.map { $0.breakEven == nil ? "不存在" : displayMoney($0.breakEven) } ?? "—",
                    footnote: nil, identifier: "optionLabBreakEven", divider: wide, wide: wide)
                referenceMetric(title: isCoveredCall ? "需覆盖正股" : (isPut ? "担保资金" : "净资金需求"),
                    value: isCoveredCall ? report.map { requiredCoveredShares($0) + " 股" } ?? "—"
                        : displayMoney(isPut ? outcome?.nominalAssignmentPayment : outcome?.capitalRequired),
                    footnote: isCoveredCall ? "账户实际持股另行核对" : (isPut ? "指派名义付款；净需求见详情" : "已计费用的净需求"),
                    identifier: "optionLabCapital", divider: true, wide: wide)
            }
            if let report { coveredCallCostSummary(report, compact: wide) }
            VStack(alignment: .leading, spacing: 3) {
                if let report {
                    HStack(spacing: 12) {
                        Text((report.usesEnteredPrices ? "所填成交价测算" : "保守成交口径") + " · 费用 " + displayMoney(report.selectedOutcome.totalFees) + " · 未记账")
                        if report.selectedOutcome.funding == .notAssessed {
                            Text("资金、实际持股未核对")
                                .accessibilityIdentifier("optionLabFundingNotAssessed")
                                .help("上方显示策略所需资金或股数，不代表账户可用额度或已核对持仓。")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if report.selectedOutcome.funding != .notAssessed && (!report.conservative.canFund || !report.mid.canFund) {
                        Label("资金或覆盖持股不足，结果不表示这笔交易可执行。", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).accessibilityIdentifier("optionLabFundingGap")
                    }
                    if report.expired { Text("合约已到期，仅供历史研究。").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("填好下方合约参数即可计算。输入变更后，旧结果立即失效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func coveredCallCostSummary(_ report: OptionLabReport, compact: Bool = false) -> some View {
        if let cost = report.coveredCallCostBasis {
            let value = report.usesEnteredPrices ? cost.mid : cost.conservative
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: compact
                    ? Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: 4)
                    : [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("按持股成本测算").font(.system(size: 13, weight: .semibold))
                            .accessibilityIdentifier("optionLabCostBasisTitle")
                        Text("每股成本 " + displayMoney(cost.costPerShare)).font(.caption).foregroundStyle(.secondary)
                    }
                    costMetric(value.maxProfit.amount < 0 ? "到期最好结果（仍亏损）" : "到期最大收益",
                        value: displayMoney(value.maxProfit), negative: value.maxProfit.amount < 0, id: "optionLabCostMaxProfit")
                    costMetric("到期最大亏损", value: displayMoney(value.maxLoss), negative: value.maxLoss.amount > 0, id: "optionLabCostMaxLoss")
                    costMetric("盈亏平衡价", value: value.breakEven.map { displayMoney($0) } ?? "不存在", id: "optionLabCostBreakEven")
                }
                Text("成本口径 · 股票＋本次期权至到期；费用仅扣一次，不含历次权利金、股息、税费，非已实现盈亏。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func costMetric(_ title: String, value: String, negative: Bool = false, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7).help(value)
                .foregroundStyle(negative ? Color.red : Color.primary).textSelection(.enabled)
                .accessibilityIdentifier(id)
        }
    }
    private func referenceMetric(title: String, value: String, footnote: String?,
                                 tone: OptionReferenceMetric.Tone = .standard, identifier: String,
                                 divider: Bool, wide: Bool) -> some View {
        OptionReferenceMetric(title: title, value: value, footnote: footnote, tone: tone, accessibilityIdentifier: identifier)
            .padding(.leading, divider ? 12 : 0)
            .overlay(alignment: .leading) {
                if divider { Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1) }
            }
    }
    /// Group the canonical decimal text for display, without a binary floating
    /// point conversion or a second rounding policy for financial results.
    private func displayMoney(_ value: Money?) -> String {
        guard let value else { return "—" }
        let raw = value.decimalString
        let negative = raw.hasPrefix("-")
        let unsigned = negative ? String(raw.dropFirst()) : raw
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard let integer = parts.first else { return "—" }
        var grouped = ""
        for (offset, character) in integer.reversed().enumerated() {
            if offset > 0 && offset.isMultiple(of: 3) { grouped.insert(",", at: grouped.startIndex) }
            grouped.insert(character, at: grouped.startIndex)
        }
        let fraction = parts.count == 2 ? "." + String(parts[1]) : ""
        return (negative ? "−$" : "$") + grouped + fraction
    }
    private func compactContract(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("合约参数").font(.system(size: 17, weight: .semibold))
                Text(draft.usesContractParametersOnly ? "填好即可计算" : "完整资料研究").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { quoteDetailsExpanded.toggle() } label: {
                    Label(draft.usesContractParametersOnly ? "费用与进阶研究" : "报价明细与高级参数",
                          systemImage: quoteDetailsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("optionLabQuoteDetails")
                    .accessibilityValue(quoteDetailsExpanded ? "已展开" : "已收起")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: wide ? 4 : 2),
                      alignment: .leading, spacing: 8) {
                OptionReferenceField("策略") {
                    Picker("策略", selection: Binding(get: { draft.strategy }, set: { strategy in
                        draft.strategy = strategy
                        if strategy != .coveredCall { draft.coveredCallCostPerShare = "" }
                    })) {
                        ForEach(OptionLabStrategy.allCases, id: \.self) { Text(strategyName($0)).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).optionReferenceInputSurface()
                        .accessibilityIdentifier("optionLabStrategy")
                }
                OptionReferenceTextField("标的代码", text: $draft.symbol, accessibilityIdentifier: "optionLabSymbol")
                OptionReferenceField("标的类型") {
                    Picker("标的类型", selection: $draft.asset) {
                        Text("股票").tag(OptionLabAsset.stock); Text("ETF").tag(OptionLabAsset.etf)
                    }.labelsHidden().pickerStyle(.menu).optionReferenceInputSurface()
                        .accessibilityIdentifier("optionReferenceAsset")
                }
                OptionReferenceTextField("合约张数", text: $draft.shortLeg.quantity, accessibilityIdentifier: "optionReferenceQuantity")
                OptionReferenceTextField("行权价", text: $draft.shortLeg.strike, unit: "USD / 股", accessibilityIdentifier: "optionReferenceStrike")
                if draft.usesEnteredPrices {
                    OptionReferenceTextField("标的当前价格", text: $draft.underlyingPrice, unit: "USD / 股", accessibilityIdentifier: "optionReferenceUnderlyingPrice")
                    OptionReferenceTextField("权利金成交价", text: $draft.shortLeg.enteredPrice, unit: "USD / 股", accessibilityIdentifier: "optionReferencePremiumPrice")
                } else {
                    compactQuoteMid("标的报价中点", bid: draft.underlyingBid, ask: draft.underlyingAsk)
                    compactQuoteMid("权利金报价中点", bid: draft.shortLeg.bid, ask: draft.shortLeg.ask)
                }
                compactExpiry
            }.id(OptionDailySection.underlying.rawValue)
            if draft.strategy == .coveredCall {
                HStack(spacing: 10) {
                    Text("持股成本（选填）").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("平均每股成本", text: $draft.coveredCallCostPerShare)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("平均持股成本（选填），USD / 股")
                            .accessibilityIdentifier("optionReferenceHoldingCost")
                        Text("USD / 股").font(.caption).foregroundStyle(.secondary).fixedSize()
                            .accessibilityHidden(true)
                    }.optionReferenceInputSurface().frame(width: 180)
                    Text("留空按现价；填写后另列成本盈亏，不改账本。")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("可填写含买入费用的平均每股成本。未填写时不会推断或修改账本成本。")
                    Spacer(minLength: 0)
                }
            }
            if draft.hasLongLeg {
                if draft.usesContractParametersOnly {
                    HStack(alignment: .top, spacing: 12) {
                        OptionReferenceTextField("保护腿行权价", text: $draft.longLeg.strike, unit: "USD / 股",
                            accessibilityIdentifier: "optionReferenceProtectionStrike")
                        OptionReferenceTextField("保护腿成交价", text: $draft.longLeg.enteredPrice, unit: "USD / 股",
                            accessibilityIdentifier: "optionReferenceProtectionPrice")
                        Text("保护腿使用相同张数").font(.caption).foregroundStyle(.secondary).padding(.top, 24)
                    }.id(OptionDailySection.longLeg.rawValue)
                } else {
                    dailyLegEditor("买入保护合约", $draft.longLeg).id(OptionDailySection.longLeg.rawValue)
                }
            }
            Text(contractInputNote).font(.system(size: 12)).foregroundStyle(.secondary)
        }.disabled(blocked).id("option-contract-parameters")
    }
    private var contractInputNote: String {
        if draft.usesContractParametersOnly {
            return "每张 100 股 · 每张每腿费用 " + draft.openingFeePerContract
                + " USD（进阶可改） · "
                + (draft.strategy == .coveredCall ? "备兑按现价起算，实际持股另核对。" : "资金另核对；测算不自动记账。")
        }
        return draft.usesEnteredPrices
            ? "标准合约每张 100 股。权利金填写计划或实际成交价；实际记账仍需确认。Bid / Ask 可在高级参数补充。"
            : "当前沿用双边报价口径；Bid / Ask 在高级参数中编辑，也可切换为单价测算。"
    }
    private func compactQuoteMid(_ title: String, bid: String, ask: String) -> some View {
        let midpoint = try? Money(bid).adding(Money(ask)).multiplied(by: "0.5")
        return OptionReferenceField(title) {
            HStack {
                Text(midpoint?.decimalString ?? "待补充").monospacedDigit()
                Spacer(minLength: 4)
                Text("USD / 股").foregroundStyle(.secondary)
            }.optionReferenceInputSurface()
        }
    }
    private var priceDetails: some View {
        GroupBox("价格与价差（可选）") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("测算口径", selection: $draft.usesEnteredPrices) {
                    Text("所填成交价").tag(true)
                    Text("双边报价分析").tag(false)
                }.pickerStyle(.segmented).disabled(draft.chainEvidence != nil)
                    .accessibilityIdentifier("optionLabPriceBasis")
                Text(draft.usesEnteredPrices
                    ? "单价测算无需填写 Bid / Ask、深度或 tick。补充报价仅用于价差与流动性分析，不改动所填成交价。"
                    : "双边报价分析需要完整 Bid / Ask、报价张数与 tick；单价栏不参与此口径。")
                    .font(.caption).foregroundStyle(.secondary)
                OptionReferenceQuoteField("标的 Bid / Ask", bid: $draft.underlyingBid, ask: $draft.underlyingAsk,
                    accessibilityPrefix: "optionReferenceUnderlying")
                quoteSpread("标的", bid: draft.underlyingBid, ask: draft.underlyingAsk)
                OptionReferenceQuoteField("卖出腿 Bid / Ask", bid: $draft.shortLeg.bid, ask: $draft.shortLeg.ask,
                    accessibilityPrefix: "optionReferencePremium")
                quoteSpread("卖出腿", bid: draft.shortLeg.bid, ask: draft.shortLeg.ask)
                if draft.hasLongLeg {
                    OptionReferenceQuoteField("保护腿 Bid / Ask", bid: $draft.longLeg.bid, ask: $draft.longLeg.ask,
                        accessibilityPrefix: "optionReferenceProtection")
                    quoteSpread("保护腿", bid: draft.longLeg.bid, ask: draft.longLeg.ask)
                }
            }.padding(.vertical, 4)
        }
    }
    private func quoteSpread(_ title: String, bid: String, ask: String) -> some View {
        let buy = try? Money(bid), sell = try? Money(ask)
        let spread: Money? = if let buy, let sell, buy.amount >= 0, sell >= buy, sell.amount > 0 {
            try? sell.subtracting(buy)
        } else { nil }
        return Text(title + "价差：" + (spread.map { $0.decimalString + " USD / 股" } ?? "未提供完整有效报价"))
            .font(.caption).foregroundStyle(.secondary)
    }
    private var compactExpiry: some View {
        OptionReferenceField("到期时间（美东）") {
            Button {
                guard !blocked, section == "输入" else { return }
                expiryPresentation = .init(draft: draft, session: visibleSession,
                    navigation: navigationEpoch,
                    initialDate: (try? LedgerCSV.timestamp(draft.settlementAt)) ?? manualSettlementAt)
            } label: {
                HStack {
                    Text(expiryLabel).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                }.contentShape(Rectangle()).optionReferenceInputSurface()
            }.buttonStyle(.plain).accessibilityIdentifier("optionReferenceExpiry")
                .accessibilityLabel("到期时间，美东时间，" + expiryLabel)
                .popover(item: $expiryPresentation) { presentation in
                    OptionExpiryPicker(initialDate: presentation.initialDate,
                        canApply: canApplyExpiry(presentation), contractOnly: draft.usesContractParametersOnly,
                        cancel: { dismissExpiry(presentation) },
                        apply: { applyExpirySelection($0, presentation: presentation) })
                        .id(presentation.id)
                }
        }
    }
    private var expiryLabel: String {
        guard let date = try? LedgerCSV.timestamp(draft.settlementAt) else {
            return draft.settlementAt.isEmpty ? "选择到期时间" : "时间格式待修正"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private func canApplyExpiry(_ presentation: OptionExpiryPresentation) -> Bool {
        !blocked && section == "输入" && expiryPresentation?.id == presentation.id
            && presentation.draft == draft && presentation.session == visibleSession
            && presentation.navigation == navigationEpoch
    }
    private func dismissExpiry(_ presentation: OptionExpiryPresentation) {
        guard expiryPresentation?.id == presentation.id else { return }
        expiryPresentation = nil
    }
    private func applyExpirySelection(_ selectedDate: Date, presentation: OptionExpiryPresentation) {
        // A delayed callback from an old popup must not close a newer one.
        guard expiryPresentation?.id == presentation.id else { return }
        guard canApplyExpiry(presentation), selectedDate.timeIntervalSince1970.isFinite,
              let zone = TimeZone(identifier: "America/New_York") else {
            dismissExpiry(presentation); return
        }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian); day.timeZone = zone; day.dateFormat = "yyyy-MM-dd"
        var changed = draft
        changed.settlementAt = timestamp.string(from: selectedDate)
        changed.expirationDate = day.string(from: selectedDate)
        dismissExpiry(presentation)
        draft = changed; manualSettlementAt = selectedDate
        manualCommonTimeConfirmed = false; manualAssistanceMessage = nil
    }
    private var referenceActions: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack(spacing: 10) {
                Button("我已成交，确认开仓") { tradePresentation = .init(opening: draft) }
                    .buttonStyle(OptionReferenceButtonStyle(.outline))
                    .disabled(blocked || draft.origin == .synthetic)
                    .help("带入合约，核对实际成交并确认后才建立账户持仓；合成示例不入账。")
                    .accessibilityIdentifier("optionTradeRecord")
                Button("保存测算（不入账）") { saveCurrentReport() }
                    .buttonStyle(OptionReferenceButtonStyle(.subtle))
                    .disabled(currentDraftReport == nil || !model.canSave || preparingLedger)
                    .accessibilityIdentifier("optionLabSave")
                Button("重置") { resetDraft() }
                    .buttonStyle(OptionReferenceButtonStyle(.subtle))
                    .disabled(blocked).accessibilityIdentifier("optionLabNew")
                Spacer()
                Button { calculate() } label: {
                    Text(currentDraftReport == nil ? "计算收益" : "重新计算").frame(minWidth: 110)
                }.buttonStyle(OptionReferenceButtonStyle(.primary)).disabled(blocked)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .accessibilityIdentifier("optionLabCalculate")
            }
            Text("保存测算不入账；确认实际开仓才建立持仓，平仓/到期确认后核算盈亏并汇总到“我的投资”。不下单。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var dailyNavigation: some View {
        HStack(spacing: 4) {
            dailyTab("填写合约", value: "输入", id: "optionLabInputTab")
            dailyTab("收益、风险与胜率", value: "结果", id: "optionLabResultTab")
            dailyTab("测算记录", value: "已保存", id: "optionLabSavedTab")
            Spacer()
        }
        // Identify the three buttons individually; a SwiftUI container ID propagates to child buttons on macOS.
    }
    private func dailyTab(_ title: String, value: String, id: String) -> some View {
        Button {
            if value == "输入", let report = model.report, currentDraftReport == nil { copyToDraft(report) }
            section = value
        } label: {
            Text(title).font(.system(size: 12, weight: section == value ? .semibold : .regular))
                .fixedSize().padding(.horizontal, 8).padding(.vertical, 5)
                .background(section == value ? accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(section == value ? accent : Color.secondary)
        }.buttonStyle(.plain).accessibilityIdentifier(id)
            .accessibilityAddTraits(section == value ? .isSelected : [])
    }
    private var advancedNavigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { advancedToolsExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: advancedToolsExpanded ? "chevron.down" : "chevron.right")
                    Text(advancedSections.contains(section) ? "高级工具 · " + section : "高级工具")
                    Spacer()
                }
                .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("optionLabAdvancedTools")
            .accessibilityValue(advancedToolsExpanded ? "已展开" : "已收起")
            if advancedToolsExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading, spacing: 8) {
                    ForEach(advancedSections, id: \.self) { value in
                        Button(value) { section = value }
                            .accessibilityIdentifier("optionLabAdvanced-" + value)
                    }
                    Button("重新载入") {
                        let session = visibleSession
                        Task { guard visibleSession == session else { return }; await model.load() }
                    }.disabled(blocked).accessibilityIdentifier("optionLabReload")
                }.padding(.top, 10)
            }
        }
    }
    @ViewBuilder private var editor: some View {
        if draft.usesContractParametersOnly { simpleOptions }
        else { detailedEditor }
    }
    private var simpleOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            feeEditor
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("报价、账户与模型概率").font(.callout.weight(.medium))
                    Text("仅在需要价差、资金校验或模型概率时补充；基础收益不需要这些资料。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("进入进阶研究") { draft.usesContractParametersOnly = false }
                    .accessibilityIdentifier("optionUseDetailedResearch")
            }
        }.disabled(blocked)
    }
    private var feeEditor: some View {
        GroupBox(draft.usesEnteredPrices ? "费用（可修改）" : "费用与保守成交假设") {
            fields {
                if !draft.usesEnteredPrices { field("保守滑点 λ（0～0.5）", $draft.lambda) }
                field("开仓费 USD / 每张每腿", $draft.openingFeePerContract)
                field("整组开仓固定费 USD", $draft.ticketFee)
                field("到期总费用 USD（整组一次）", $draft.terminalFeeTotal)
            }
        }.id(OptionDailySection.costs.rawValue)
    }
    private var detailedEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            if draft.origin == .manual && draft.chainEvidence == nil {
                HStack {
                    Text("进阶模式需完整资料。返回简洁测算只保留合约、所填单价与费用。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("仅保留合约参数") { startContractOnlyDraft() }
                        .accessibilityIdentifier("optionUseContractParameters")
                }
            }
            priceDetails
            dailyPreparation
            if draft.canUseManualQuoteAssistance { manualQuoteAssistance.id(OptionDailySection.timing.rawValue) }
            capitalEditor.id(OptionDailySection.capital.rawValue)
            GroupBox("共同报价与时间依据") {
                fields {
                    field("评估时刻（ISO 8601，含时区）", $draft.asOf)
                    field("到期日（纽约 YYYY-MM-DD）", $draft.expirationDate)
                    field("到期时刻（含时区）", $draft.settlementAt, id: "optionLabSettlementAt")
                    field("报价来源／假设说明", $draft.sourceReference)
                    field("到期时刻依据", $draft.expiryReference)
                    field("标的报价时刻", $draft.underlyingQuotedAt)
                    field("标的接收时刻", $draft.underlyingReceivedAt)
                }
            }.id("option-detailed-quotes")
            legEditor("卖出腿", $draft.shortLeg, id: "optionLabShort").id(OptionDailySection.shortLeg.rawValue)
            if draft.hasLongLeg { legEditor("买入保护腿", $draft.longLeg, id: "optionLabLong") }
            Text("完整输入继续用于检查同一时刻的报价与合法合约；缺失时拒绝计算。手工来源不代表实时或历史数据资格。")
                .font(.caption).foregroundStyle(.secondary)
            dailyDisclosure("optionLabPricingDetails", isExpanded: $pricingExpanded) {
                pricingEditor.padding(.top, 10)
            } label: {
                Label(draft.pricing.enabled ? "模型获利概率 · 已启用假设" : "模型获利概率 · 可选", systemImage: "percent")
            }.id(OptionDailySection.pricing.rawValue)
            Text("模型获利概率不等于个人历史胜率。缺少可反解的 IV 时保留不可用，不补成估计值。")
                .font(.caption).foregroundStyle(.secondary)
            dailyDisclosure("optionDailyChartDetails", isExpanded: $chartDetailsExpanded) {
                chartSamplesEditor.padding(.top, 10)
            } label: {
                Label("损益图采样 · 使用已填价格或自行输入", systemImage: "chart.xyaxis.line")
            }.id(OptionDailySection.chart.rawValue)
            dailyDisclosure("optionLabAdvancedAssumptions", isExpanded: $advancedAssumptionsExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    feeEditor
                    if draft.origin == .synthetic {
                        Button("合成风险与情景示例") {
                            do { try draft.useSyntheticRiskScenarioAssumptions(); section = "输入"; pricingExpanded = true }
                            catch { inputError = "请先载入完整合成模板；未改动现有输入。" }
                        }.accessibilityIdentifier("optionLabRiskScenarioSynthetic")
                    }
                    riskEditor.id(OptionDailySection.risk.rawValue)
                    scenarioEditor.id(OptionDailySection.scenario.rawValue)
                }.padding(.top, 10)
            } label: {
                Label("高级假设 · 费用与情景", systemImage: "slider.horizontal.3")
            }
            Text("当前费用：每张每腿 \(draft.openingFeePerContract) USD；固定费 \(draft.ticketFee) USD；到期费 \(draft.terminalFeeTotal) USD。" + (draft.usesEnteredPrices ? "单价测算不另加滑点。" : "保守滑点 λ=\(draft.lambda)。"))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(blocked)
    }
    private var dailyPreparation: some View {
        GroupBox("整理本次输入") {
            VStack(alignment: .leading, spacing: 10) {
                Text("先填合约和报价，再整理缺项。已保存的资料可继续修改，不必重复填写。")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.hasLongLeg {
                    Toggle("保护腿采用卖出腿张数", isOn: $synchronizeProtectionQuantity)
                        .accessibilityIdentifier("optionDailyMatchQuantity")
                }
                Toggle("使用已填的标的报价与行权价作为损益图采样", isOn: $useEnteredChartPrices)
                    .accessibilityIdentifier("optionDailyUseChartPrices")
                HStack {
                    Button("整理输入并查看缺项") {
                        prepareDailyInput(.init(synchronizeProtectionQuantity: draft.hasLongLeg && synchronizeProtectionQuantity,
                                               useEnteredPricesForChart: useEnteredChartPrices))
                    }.accessibilityIdentifier("optionDailyPrepare")
                    Text("只应用勾选项，未知值不自动补齐。").font(.caption).foregroundStyle(.secondary)
                }
                if let checklist, checkedDraft == draft {
                    OptionDailyChecklistView(checklist: checklist, select: focusInput)
                } else if checkedDraft == nil {
                    Text("当前输入尚未整理；完整的资料仍可直接计算。").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }.id("option-daily-preparation")
    }
    @discardableResult private func prepareDailyInput(_ request: OptionDailyPreparationRequest = .init()) -> Bool {
        guard !blocked else { return false }
        do {
            var prepared = draft
            let result = try prepared.prepareDaily(request)
            // The whole value is published only after all requested actions succeed.
            draft = prepared; checkedDraft = prepared; checklist = result; inputError = nil
            return true
        } catch {
            inputError = "整理未应用：请核对已选择的时间、来源、张数和图表价格。原输入保留，未知值没有补成零。"
            return false
        }
    }
    private func focusInput(_ target: OptionDailySection) {
        quoteDetailsExpanded = true
        switch target {
        case .timing:
            if !draft.canUseManualQuoteAssistance { quoteDetailsExpanded = true }
        case .pricing: pricingExpanded = true
        case .costs, .risk, .scenario: advancedAssumptionsExpanded = true
        case .chart: chartDetailsExpanded = true
        default: break
        }
        inputTarget = target == .timing && !draft.canUseManualQuoteAssistance ? "option-detailed-quotes" : target.rawValue
        inputFocusRequest = UUID()
    }
    private func dailyDisclosure<Content: View, Heading: View>(_ identifier: String, isExpanded: Binding<Bool>,
                                                               @ViewBuilder content: () -> Content,
                                                               @ViewBuilder label: () -> Heading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    label()
                    Spacer()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(isExpanded.wrappedValue ? "已展开" : "已收起")
            if isExpanded.wrappedValue { content() }
        }
    }
    private func dailyLegEditor(_ title: String, _ leg: Binding<OptionLabLegDraft>) -> some View {
        GroupBox(title + " · " + (draft.right == .put ? "Put" : "Call")) {
            fields {
                field("行权价 · USD / 股", leg.strike)
                field("张数", leg.quantity)
                if draft.usesEnteredPrices { field("权利金成交价 · USD / 股", leg.enteredPrice) }
                else { compactQuoteMid("权利金报价中点", bid: leg.wrappedValue.bid, ask: leg.wrappedValue.ask) }
            }.padding(.vertical, 6)
        }
    }
    private var manualQuoteAssistance: some View {
        GroupBox("报价与到期时间") {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("报价与评估时间（本机时区）", selection: $manualQuoteAt, displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("optionLabManualQuoteDate")
                if let zone = TimeZone(identifier: "America/New_York") {
                    DatePicker("到期时间（纽约时区）", selection: $manualSettlementAt, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, zone).accessibilityIdentifier("optionLabManualExpiryDate")
                }
                fields {
                    field("报价从哪里查看／手工假设说明", $manualQuoteReference, id: "optionLabManualQuoteReference")
                    field("到期时间从哪里核对", $manualExpiryReference, id: "optionLabManualExpiryReference")
                }
                Toggle("我确认标的与各腿使用这同一时刻的手工报价", isOn: $manualCommonTimeConfirmed)
                    .accessibilityIdentifier("optionLabManualTimeConfirmed")
                HStack {
                    Button("应用这组时间与说明") {
                        let applied = prepareDailyInput(.init(quoteAssistance: .init(quotedAt: manualQuoteAt,
                            settlementAt: manualSettlementAt, quoteReference: manualQuoteReference,
                            expiryReference: manualExpiryReference, confirmedCommonQuoteTime: manualCommonTimeConfirmed)))
                        if applied {
                            manualAssistanceMessage = "已采用所选时间并生成内部手工合约标识。价格、tick、资金与费用没有改动。"
                        } else {
                            manualAssistanceMessage = nil
                        }
                    }.disabled(!manualCommonTimeConfirmed).accessibilityIdentifier("optionLabApplyManualTime")
                    if !draft.expirationDate.isEmpty { Text("当前到期日：" + draft.expirationDate).font(.caption).foregroundStyle(.secondary) }
                }
                if let manualAssistanceMessage { Text(manualAssistanceMessage).font(.caption).foregroundStyle(.secondary) }
                Text(draft.usesEnteredPrices ? "确认后才采用这组手工时间与来源。深度和 tick 可留空，不影响单价测算。" : "确认后才采用这组手工时间与来源。双边报价分析仍需完整报价、深度与 tick；不会猜测补值。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
                .onChange(of: manualQuoteAt) { _, _ in manualCommonTimeConfirmed = false; manualAssistanceMessage = nil }
                .onChange(of: manualSettlementAt) { _, _ in manualCommonTimeConfirmed = false; manualAssistanceMessage = nil }
                .onChange(of: manualQuoteReference) { _, _ in manualAssistanceMessage = nil }
                .onChange(of: manualExpiryReference) { _, _ in manualAssistanceMessage = nil }
        }
    }
    private var chartSamplesEditor: some View {
        GroupBox("损益图：想看哪些到期价格？") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("填入价格即可看对应盈亏；每行一个 USD / 股数值。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("采用当前报价与行权价") {
                        do { try draft.useChartPricesFromEnteredInputs() }
                        catch { inputError = "请先填入有效的标的买卖价与各腿行权价；没有添加替代价格。" }
                    }.accessibilityIdentifier("optionLabUseEnteredChartPrices")
                }
                TextEditor(text: $draft.scenarioPrices).font(.system(.body, design: .monospaced)).frame(minHeight: 65, maxHeight: 100)
                    .accessibilityLabel("到期情景价格").accessibilityIdentifier("optionLabScenarioPrices")
                Text("按钮仅把你已填写的价格用于绘图，不预测未来价格，也不改变模型概率。可填写 1～401 个不同的非负价格。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }
    }
    private var pricingEditor: some View {
        GroupBox("可选：本地定价、IV / Greeks 与风险中性研究") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("显式启用模型研究", isOn: $draft.pricing.enabled).accessibilityIdentifier("optionLabPricingEnabled")
                Text("旧快照不会自动增加模型结果。启用后必须明确填写连续利率、连续股息率和理论价波动率假设；空白不当作零。")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.pricing.enabled {
                    fields {
                        field("连续利率 r（0.05 = 5%）", $draft.pricing.rate, id: "optionLabPricingRate")
                        field("连续股息率 q（0.01 = 1%）", $draft.pricing.dividendYield, id: "optionLabPricingDividend")
                        field("仅理论价使用的 σ（0.25 = 25%）", $draft.pricing.volatility, id: "optionLabPricingSigma")
                        field("r / q / σ 来源与假设说明", $draft.pricing.sourceReference, id: "optionLabPricingSource")
                    }
                    Text("理论价使用上面的手工 σ。IV 从" + (draft.usesEnteredPrices ? "所填成交价" : "每条腿的 Mid") + "反解；Greeks 与风险中性分布沿用本地 IV，失败不回退手工 σ 或供应商值。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("欧式连续股息 BSM 假设：对美式合约仅作模型参考，不处理提前行权或离散股息。风险中性概率不是经验胜率，也不是建议。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if draft.origin == .synthetic {
                    Button("填入合成模型假设") {
                        do { try draft.useSyntheticPricingAssumptions() }
                        catch { inputError = "合成假设只能填入显式合成草稿。" }
                    }.accessibilityIdentifier("optionLabPricingSynthetic")
                    Text("按钮会明确填入合成 r=5%、q=1%、理论 σ=25%；这些不是市场数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var riskEditor: some View {
        GroupBox("可选：流动性、财报与提前指派提示") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("显式启用离线风险核对", isOn: $draft.risk.enabled).accessibilityIdentifier("optionLabRiskEnabled")
                Text("只核对这份手工或合成证据。没有填事件不等于没有事件；缺邻点、OI、可比成交量或完整日历时保留不足状态。")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.risk.enabled {
                    field("风险证据来源／假设说明", $draft.risk.sourceReference, id: "optionLabRiskSource")
                    liquidityEditor("卖出腿流动性", $draft.risk.shortLeg)
                    if draft.hasLongLeg { liquidityEditor("买入保护腿流动性", $draft.risk.longLeg) }
                    earningsEditor
                    dividendEditor
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func liquidityEditor(_ title: String, _ value: Binding<OptionLabLiquidityDraft>) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 10) {
                fields {
                    field("OI 张数（可空，不是股数）", value.openInterest)
                    field("OI 距当前发布会话数（可空）", value.oiSessionsAgo)
                    field("成交量张数（可空）", value.volume)
                    Picker("成交量比较口径", selection: value.volumeBasis) {
                        Text("未核对").tag(OptionLabVolumeBasis.unverified)
                        Text("完整会话").tag(OptionLabVolumeBasis.fullSession)
                        Text("相同已过交易时长").tag(OptionLabVolumeBasis.sameElapsedTime)
                    }
                }
                Toggle("确认 OI 是最新已发布版本", isOn: value.oiIsLatestPublished)
                DisclosureGroup("相邻行权价报价（同标的、同到期、同 Put / Call）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每行以 | 分隔：合约标识 | 行权价 | Bid | Ask | Bid 张数 | Ask 张数 | tick | 报价时刻 | 接收时刻。时间须含时区；字段不自动从中心腿复制。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: value.neighbors).font(.system(.caption, design: .monospaced)).frame(minHeight: 100)
                            .accessibilityLabel(title + "相邻报价")
                        Toggle("明确声明这份邻点候选集合完整", isOn: value.neighborsComplete)
                        Text("先固定完整候选集合中两侧最近邻点；任一无效则连续性不可用，不改用更远报价。未提供或未确认完整时同样保留缺失。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 8)
        }
    }
    private var earningsEditor: some View {
        DisclosureGroup("财报事件与 Expected Move") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("提供一份明确财报事件证据", isOn: $draft.risk.earnings.enabled)
                if draft.risk.earnings.enabled {
                    fields {
                        field("事件版本", $draft.risk.earnings.eventVersion)
                        field("事件来源／假设", $draft.risk.earnings.sourceReference)
                        field("事件公告时刻（含时区）", $draft.risk.earnings.announcedAt)
                        field("财报日期（纽约 YYYY-MM-DD）", $draft.risk.earnings.eventDate)
                        Picker("财报时段", selection: $draft.risk.earnings.timing) {
                            Text("未知").tag(CorporateEventTiming.unknown)
                            Text("盘前").tag(CorporateEventTiming.beforeMarket)
                            Text("盘中").tag(CorporateEventTiming.duringMarket)
                            Text("盘后").tag(CorporateEventTiming.afterMarket)
                        }
                        certaintyPicker($draft.risk.earnings.certainty)
                        Picker("是否允许跨财报持有", selection: $draft.risk.earnings.holdingChoice) {
                            Text("未决定").tag(""); Text("允许").tag("allow"); Text("不允许").tag("deny")
                        }
                    }
                    calendarEditor("财报窗口日历", $draft.risk.earnings.calendar)
                    DisclosureGroup("事件后到期的 ATM 跨式候选") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("每行以 | 分隔：行权价 | 到期时刻 | Call Bid | Call Ask | Put Bid | Put Ask | 报价时刻。价格为 USD / 股，时间含时区。")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $draft.risk.earnings.straddles).font(.system(.caption, design: .monospaced)).frame(minHeight: 100)
                                .accessibilityLabel("财报跨式候选")
                            Toggle("明确声明到期与行权价候选集合完整", isOn: $draft.risk.earnings.straddleCoverageComplete)
                        }
                    }
                }
            }.padding(.vertical, 8)
        }
    }
    private var dividendEditor: some View {
        DisclosureGroup("除息与短腿提前指派提示") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("提供一份明确除息事件证据", isOn: $draft.risk.dividend.enabled)
                if draft.risk.dividend.enabled {
                    fields {
                        field("除息事件版本", $draft.risk.dividend.eventVersion)
                        field("除息来源／假设", $draft.risk.dividend.sourceReference)
                        field("除息公告时刻（含时区）", $draft.risk.dividend.announcedAt)
                        field("除息日期（纽约 YYYY-MM-DD）", $draft.risk.dividend.exDate)
                        field("明确支付时刻（可空）", $draft.risk.dividend.paymentAt)
                        field("每股现金股息（可空）", $draft.risk.dividend.amountPerShare)
                        field("币种（仅 USD）", $draft.risk.dividend.currency)
                        certaintyPicker($draft.risk.dividend.certainty)
                    }
                    calendarEditor("除息前会话日历", $draft.risk.dividend.calendar)
                    Text("提前指派是启发式提示，不是美式 CRR 或离散股息定价。未满足提示条件也不表示安全或指派概率为零。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }
    }
    private func certaintyPicker(_ certainty: Binding<CorporateEventCertainty>) -> some View {
        Picker("证据确定性", selection: certainty) {
            Text("未知").tag(CorporateEventCertainty.unknown)
            Text("估计").tag(CorporateEventCertainty.estimated)
            Text("已确认（仍为所填来源）").tag(CorporateEventCertainty.confirmed)
        }
    }
    private func calendarEditor(_ title: String, _ value: Binding<OptionLabCalendarDraft>) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("提供逐日完整日历", isOn: value.enabled)
                if value.enabled.wrappedValue {
                    fields {
                        field("日历版本", value.version); field("日历来源／假设", value.sourceReference)
                        field("覆盖开始 YYYY-MM-DD", value.from); field("覆盖结束 YYYY-MM-DD", value.through)
                    }
                    Text("覆盖内每个日期都须一行，含休市日：日期 | regular / earlyClose / closed / unknown | 开盘时刻 | 收盘时刻。休市行形如 2026-10-18|closed||；交易时刻须含时区。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: value.sessions).font(.system(.caption, design: .monospaced)).frame(minHeight: 120)
                        .accessibilityLabel(title + "逐日会话")
                    Text("空白不当作普通交易日，不通过周一至周五推定节假日或提前收盘。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 6)
        }
    }

    private var scenarioEditor: some View {
        GroupBox("可选：价格 × IV 瞬时情景") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("显式启用情景矩阵", isOn: $draft.scenario.enabled).accessibilityIdentifier("optionLabScenarioEnabled")
                Text("价格变动使用比例，IV 使用绝对百分点。矩阵停留在当前评估时刻，不模拟时间流逝，不代表收益预测。")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.scenario.enabled {
                    fields {
                        field("价格变化（-0.1 = -10%，逗号分隔）", $draft.scenario.spotShocks, id: "optionLabScenarioSpotAxis")
                        field("IV 变化（-10 = -10 个百分点，逗号分隔）", $draft.scenario.volatilityPointShocks, id: "optionLabScenarioIVAxis")
                        field("情景来源／假设说明", $draft.scenario.sourceReference, id: "optionLabScenarioSource")
                    }
                    Text("先从" + (draft.usesEnteredPrices ? "所填成交价" : "每条腿的 Mid") + "本地反解 IV，再施加同一百分点变化。缺 IV 时保留不可用原因，不改用理论 σ。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.origin == .synthetic {
                    Button("填入合成情景轴") {
                        do { try draft.useSyntheticScenarioAssumptions() }
                        catch { inputError = "合成情景只能填入显式合成草稿。" }
                    }.accessibilityIdentifier("optionLabScenarioSynthetic")
                    Text("显式示例：价格 -10% / 0 / +10%，IV -10 / 0 / +10 个百分点；不会自动开启定价模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legEditor(_ title: String, _ leg: Binding<OptionLabLegDraft>, id: String) -> some View {
        GroupBox("\(title) · \(draft.right == .put ? "Put" : "Call")") {
            fields {
                field("合约标识", leg.contractID, id: id + "Contract")
                field("腿来源（空白沿用总体说明）", leg.sourceReference)
                field("行权价 USD / 股", leg.strike)
                field("乘数（仅标准 100 股）", leg.multiplier)
                field("张数", leg.quantity)
                field("Bid 报价张数", leg.bidSize); field("Ask 报价张数", leg.askSize)
                field("合法 tick（不猜测）", leg.tick)
                field("报价时刻", leg.quotedAt); field("接收时刻", leg.receivedAt)
            }
        }
    }
    private var capitalEditor: some View {
        GroupBox("成交前资金与持股（USD，同一评估时刻）") {
            VStack(alignment: .leading, spacing: 8) {
                if let basis = draft.ledgerBasis {
                    Text("冻结账本依据：\(basis.account.name) · \(basis.ledgerRevision.uuidString)").font(.caption).textSelection(.enabled)
                    Text("这是选定时刻的只读依据，不会锁定资金或持股，也不会跟随之后的账本变化。现有空头义务保守扣除，不猜测价差抵扣。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("改用独立手工资金假设") { draft.useManualCapital() }
                }
                fields {
                    field("总现金（尚未扣承诺额度）", $draft.cashBeforeTrade)
                    field("已承诺现金", $draft.committedCash)
                    field("持有多头股数（尚未扣承诺）", $draft.availableShares)
                    field("已承诺交付股数", $draft.committedShares)
                    field("完整性／资金假设说明", $draft.capitalReference)
                }.disabled(draft.ledgerBasis != nil)
                Text("明确填写零值；空白不当作零。备兑只使用尚未承诺的持股，不把买入期权当成覆盖股票。")
                    .font(.caption).foregroundStyle(.secondary)
                dailyDisclosure("optionDailyLedgerCapital", isExpanded: $ledgerExpanded) {
                    ledgerEditor.padding(.top, 10)
                } label: {
                    Label("从我的投资复用资金与持股", systemImage: "tray.and.arrow.down")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var ledgerEditor: some View {
        GroupBox("可选：从本地账本取得只读资金依据") {
            VStack(alignment: .leading, spacing: 10) {
                Button("读取账本") {
                    let session = visibleSession
                    Task { guard visibleSession == session else { return }; await model.readLedger() }
                }.disabled(!model.canReadLedger).accessibilityIdentifier("optionLabReadLedger")
                if let error = model.ledgerError { Text(error).foregroundStyle(.orange) }
                if let snapshot = model.ledgerSnapshot {
                    Picker("账户", selection: $ledgerAccount) {
                        Text("请选择账户").tag("")
                        ForEach(snapshot.accounts) { Text("\($0.name) · \($0.id)").tag($0.id) }
                    }
                    fields { field("账本证券 ID（须与标的身份一致）", $ledgerSecurityID); field("账户交易与外部义务完整性声明", $completeness) }
                    Button("核对资金依据") { inspectLedger(snapshot) }.disabled(ledgerAccount.isEmpty || ledgerSecurityID.isEmpty)
                    if let basis = ledgerCandidate {
                        Text("现金 \(basis.cashBeforeTrade.decimalString) · 已承诺现金 \(basis.committedCash.decimalString) · 持股 \(basis.heldShares.decimalString) · 已承诺股数 \(basis.committedShares.decimalString)")
                        if !basis.gaps.isEmpty { Text("尚缺：" + basis.gaps.map(gapName).joined(separator: "；")).foregroundStyle(.orange) }
                        Button("使用这份资金依据") {
                            do { try draft.useLedgerBasis(basis) }
                            catch { inputError = "资金依据与当前标的或评估时刻不一致，请重新核对。" }
                        }.disabled(!basis.isUsableForOfflineLab)
                    }
                }
                Text("不自动读取账户，不修改账本。不完整或有额外保证金需求时不授予额度；账本失败不影响独立手工研究。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var dailyResults: some View {
        if let report = model.report {
            result(report)
        } else {
            ContentUnavailableView("先填写合约，再看本次收益与风险", systemImage: "chart.xyaxis.line",
                description: Text("个人历史可以在下方单独读取，不依赖本次合约计算。"))
            Button("填写合约") { section = "输入" }.accessibilityIdentifier("optionDailyBackToInput")
            if let personal = model.personalHistory { OptionPersonalHistoryView(model: personal) }
        }
    }
    private func result(_ report: OptionLabReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.input.underlying.symbol + " · " + strategyName(report.input.strategy)).font(.title2.weight(.semibold))
                    Text("\(containsSynthetic(report) ? "SYNTHETIC 合成" : "MANUAL 手工假设") · \(model.savedID == nil ? "未保存预览" : "已按完整输入重算")")
                        .font(.callout).foregroundStyle(containsSynthetic(report) ? .orange : .secondary)
                        .accessibilityIdentifier("optionLabReportStatus")
                    Text("到期 \(report.input.expiry.date.iso8601) · 剩余 \(report.dte) 个自然日 · " + (report.usesEnteredPrices ? "所填成交价口径" : "保守成交口径"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("修改输入") { copyToDraft(report) }.disabled(blocked).accessibilityIdentifier("optionLabCopy")
            }
            if report.selectedOutcome.funding == .notAssessed {
                Text("账户资金与持股未核对；不会将未知额度视为零或资金充足。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !report.conservative.canFund || !report.mid.canFund {
                Label("资金或覆盖持股不足，以下结果不能表示这笔交易可执行。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).accessibilityIdentifier("optionLabFundingGap")
            }
            dailyOutcome(report)
            coveredCallCostSummary(report)
            probabilitySummary(report)
            if let personal = model.personalHistory { OptionPersonalHistoryView(model: personal) }
            HStack {
                Label(model.savedID == nil ? "本次结果尚未保存" : "已保存，可从记录中重新打开", systemImage: model.savedID == nil ? "doc" : "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("optionDailySaveStatus")
                Spacer()
                Button("查看已保存计算") { section = "已保存" }
                    .accessibilityIdentifier("optionDailyGoToSaved")
            }
            Text("保存的是这次合约输入和计算；个人历史统计只读其选定的盈亏报告，不会写入或改动交易账本。")
                .font(.caption).foregroundStyle(.secondary)
            if report.input.strategy == .coveredCall {
                Text("下方损益图、年化和模型概率仍按当前股价口径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            payoffChart(report)
            DisclosureGroup(report.usesEnteredPrices ? "计算详情 · 费用与年化" : "计算详情 · Mid 对照、费用与年化") {
                VStack(alignment: .leading, spacing: 14) {
                    if report.usesEnteredPrices {
                        outcome(report.selectedOutcome, title: "所填成交价", shortDTE: report.dte < 7)
                    } else {
                        outcome(report.mid, title: "Mid 基准", shortDTE: report.dte < 7)
                        outcome(report.conservative, title: "保守成交", shortDTE: report.dte < 7)
                    }
                    Text("评估 \(report.input.asOf.formatted(.iso8601)) · 到期 \(report.input.expiry.settlementAt.formatted(.iso8601))")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
            DisclosureGroup("逐点到期损益") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { Text("到期价格 / 股").bold(); Text(report.usesEnteredPrices ? "测算损益" : "Mid 损益").bold(); if !report.usesEnteredPrices { Text("保守损益").bold() } }
                    ForEach(payoffRows(report)) { row in
                        GridRow { Text(row.price.decimalString); Text(row.mid?.decimalString ?? "—"); if !report.usesEnteredPrices { Text(row.conservative?.decimalString ?? "—") } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.top, 10)
            }
            DisclosureGroup("来源、完整输入与模型版本") { frozenInput(report).padding(.top, 10) }
            Text("到期损益不是盘中估值，不包含提前指派路径；净权利金收入也不等于已经实现的利润。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("适用范围") {
                ForEach(report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func dailyOutcome(_ report: OptionLabReport) -> some View {
        let value = report.selectedOutcome
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))], alignment: .leading, spacing: 12) {
                outcomeCard("净权利金", value: value.netCreditTotal.decimalString, unit: "USD · 已扣本次费用", id: "optionLabNetCredit")
                outcomeCard("最大亏损", value: value.maxLoss.decimalString, unit: "USD · 到期口径", id: "optionLabMaxLoss", risk: true)
                outcomeCard("最大盈利", value: value.maxProfit.decimalString, unit: "USD · 到期口径", id: "optionLabMaxProfit")
                outcomeCard("盈亏平衡", value: value.breakEven?.decimalString ?? "不存在", unit: "USD / 股", id: "optionLabBreakEven")
                if report.input.strategy == .coveredCall {
                    outcomeCard("需覆盖正股", value: requiredCoveredShares(report), unit: "股 · 账户实际持股另行核对", id: "optionLabCapital")
                } else {
                    outcomeCard("净资金需求", value: value.capitalRequired.decimalString, unit: "USD", id: "optionLabCapital")
                }
                outcomeCard("权利金收益率", value: ((try? value.premiumYield.multiplied(by: "100").decimalString) ?? "不可表示") + "%", unit: "本期口径 · 非年化预测", id: "optionLabPremiumYield")
            }
            if report.input.strategy == .coveredCall {
                Text("上方收益与风险以当前股价为起点，含股票与本次期权；净权利金已单独列出。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(fundingName(value.funding)).font(.caption).foregroundStyle(value.funding == .notAssessed || value.canFund ? Color.secondary : Color.red)
        }
    }
    private func requiredCoveredShares(_ report: OptionLabReport) -> String {
        // The validated report enforces standard multiplier 100 and quantity <= Int.max / 200.
        String(report.input.shortLeg.quantity * report.input.shortLeg.multiplier)
    }
    private func outcomeCard(_ title: String, value: String, unit: String, id: String, risk: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold)).monospacedDigit()
                .foregroundStyle(risk ? Color.red : accent)
                .textSelection(.enabled).accessibilityIdentifier(id)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .padding(16).background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }
    private func probabilitySummary(_ report: OptionLabReport) -> some View {
        GroupBox("获利概率 · 模型参考") {
            VStack(alignment: .leading, spacing: 10) {
                if let pricing = report.pricing, let distribution = pricing.distribution {
                    HStack(alignment: .top, spacing: 32) {
                        pricingMetric("风险中性净获利概率（PnL > 0）", distribution.conservative.probabilityProfit, factor: 100, suffix: "%")
                        pricingMetric("模型到期净损益 EV · USD", distribution.conservative.expectedPnL)
                    }.accessibilityIdentifier("optionLabDailyProbability")
                } else if let pricing = report.pricing {
                    Text("不可用：" + pricingState(pricing.distributionState)).foregroundStyle(.orange)
                        .accessibilityIdentifier("optionLabDailyProbabilityUnavailable")
                } else {
                    Text("尚未启用模型。可在「填写合约」中补齐模型假设；当前只计算确定性损益。")
                        .foregroundStyle(.secondary).accessibilityIdentifier("optionLabDailyProbabilityUnavailable")
                }
                Text("风险中性概率是本地 BSM 的模型估计，不是实际成功率。美式提前行权和离散股息未建模，缺 IV 不使用手工 σ 替代。")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("optionLabDailyProbabilityBoundary")
                Text("个人历史胜率需另按已闭合交易统计；这份合约计算不生成历史胜率。少于 30 个合资格回合不显示历史频率。")
                    .font(.caption).foregroundStyle(.secondary)
                if report.pricing != nil {
                    Button("查看 IV / Greeks 与分布详情") { section = "模型分析"; advancedToolsExpanded = true }
                        .accessibilityIdentifier("optionLabShowPricing")
                } else {
                    Button("补充模型假设") {
                        copyToDraft(report)
                        draft.usesContractParametersOnly = false
                        focusInput(.pricing)
                    }
                        .accessibilityIdentifier("optionLabConfigurePricing")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }
    }
    @ViewBuilder private func pricingAnalysis(_ report: OptionLabReport) -> some View {
        if let pricing = report.pricing {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("模型参考 · 欧式连续股息假设") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(containsSynthetic(report) ? "SYNTHETIC 合成" : "MANUAL 手工假设") · \(model.savedID == nil ? "未保存预览" : "已按完整输入重算")")
                            .font(.headline).accessibilityIdentifier("optionLabPricingStatus")
                        Text("RISK_NEUTRAL · 风险中性概率 ≠ 真实世界胜率；EV 和尾部指标不是收益承诺。")
                            .font(.headline).foregroundStyle(.orange).accessibilityIdentifier("optionLabRiskNeutralBoundary")
                        Text("当前合约为美式情景；本地 BSM 忽略提前行权和离散股息，仅作模型参考。")
                        Text("理论价使用显式假设 σ；IV / Greeks 来自" + (report.usesEnteredPrices ? "所填成交价" : "逐腿 Mid") + "本地求解；主分布使用短腿 IV。失败不会改用人工 σ 或供应商值。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("连续 r = \(pricing.input.rate.decimalString) · 连续 q = \(pricing.input.dividendYield.decimalString) · 理论价 σ = \(pricing.input.volatility.decimalString)（均为 ratio）")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("optionLabPricingInputs")
                        Text("模型时间 T = \(pricingNumber(pricing.timeYears)) 年；使用实际秒数 / 365 天，与到期损益的自然日 DTE 分开。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("来源：\(pricing.input.source.origin == .synthetic ? "SYNTHETIC 合成" : "MANUAL 手工假设") · \(pricing.input.source.reference)")
                            .font(.caption).textSelection(.enabled)
                        Button("复制为新草稿") { copyToDraft(report) }.disabled(blocked).accessibilityIdentifier("optionLabCopy")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(pricing.legs, id: \.contractID) { leg in legPricing(leg, in: report) }
                GroupBox("组合 Greeks · 按方向、张数与乘数聚合") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let greeks = pricing.aggregateGreeks {
                            greekGrid(greeks, aggregate: true)
                                .accessibilityIdentifier("optionLabAggregateGreeks")
                        } else {
                            Text("不可用：" + pricingState(pricing.aggregateState)).foregroundStyle(.orange)
                                .accessibilityIdentifier("optionLabAggregateUnavailable")
                        }
                        Text("聚合按多空方向、张数和乘数计算，备兑含覆盖股票的 Delta。任一必需腿缺少本地 IV 时不展示残缺组合 Greeks；缺值不当作零。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                distributionAnalysis(pricing, enteredPrices: report.usesEnteredPrices)
                DisclosureGroup("模型、参数和数值口径") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("方法：\(pricing.input.methodVersion)")
                        Text("模型：\(pricing.modelReference.id) · \(pricing.modelReference.version) · \(pricing.modelReference.contentHash)")
                        Text("参数：\(pricing.parameterReference.id) · \(pricing.parameterReference.version) · \(pricing.parameterReference.contentHash)")
                        Text("数值策略：\(pricing.numericPolicyVersion)")
                        Text("本页浮点模型数值按 8 位有效数字显示；快照保存原值与完整输入，重开须复算核对。到期损益金额仍用原精确十进制。")
                    }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(pricing.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            ContentUnavailableView("这份输入未启用模型研究", systemImage: "function",
                description: Text("原到期损益快照保持原样。复制为新草稿后显式开启并填写完整假设，再计算新结果；不会自动升级旧快照。"))
                .accessibilityIdentifier("optionLabPricingNotEnabled")
        }
    }
    private func riskAndScenarioAnalysis(_ report: OptionLabReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("风险提示与瞬时情景 · 仅供离线研究") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(containsSynthetic(report) ? "SYNTHETIC 合成" : "MANUAL 手工假设") · \(model.savedID == nil ? "未保存预览" : "已按完整输入重算")")
                        .font(.headline).accessibilityIdentifier("optionLabRiskScenarioStatus")
                    Text("缺少证据时显示不足，不把未知当作零、无事件或安全。分数和情景结果都不授予交易许可。")
                        .foregroundStyle(.secondary)
                    Button("复制为新草稿") { copyToDraft(report) }.disabled(blocked).accessibilityIdentifier("optionLabCopy")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let risk = report.risk { riskAnalysis(risk) }
            else { Text("未启用离线风险核对；没有风险结论。").foregroundStyle(.secondary).accessibilityIdentifier("optionLabRiskNotEnabled") }
            if let scenario = report.scenario { scenarioAnalysis(scenario, enteredPrices: report.usesEnteredPrices) }
            else {
                Text("未启用价格 × IV 矩阵；旧快照不会自动补入情景假设。")
                    .foregroundStyle(.secondary).accessibilityIdentifier("optionLabScenarioNotEnabled")
            }
        }
    }
    private func riskAnalysis(_ risk: OptionLabRiskReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("流动性 · 六项证据与最弱腿") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("综合等级：" + liquidityGrade(risk.liquidity.grade))
                        .font(.headline).foregroundStyle(risk.liquidity.grade == .avoid ? Color.red : Color.primary)
                        .accessibilityIdentifier("optionLabLiquidityGrade")
                    Text("综合分数：" + (risk.liquidity.score?.decimalString ?? "数据不足"))
                        .accessibilityIdentifier("optionLabLiquidityScore")
                    Text("只有六项齐备才给分；缺失不填零、不重新分配权重。存在硬性降级时仍保留 Avoid；价差策略按最弱腿。仅在所填情景下研究，不代表实时可成交性。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(risk.liquidity.legs, id: \.contractID) { leg in
                        DisclosureGroup("\(leg.contractID) · \(liquidityGrade(leg.grade)) · 覆盖 \(String(format: "%.0f", Double(leg.coverageBasisPoints) / 100))%") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(leg.components, id: \.factor) { component in
                                    Text("\(liquidityFactor(component.factor))（权重 \(component.weightBasisPoints / 100)%）：\(component.value?.decimalString ?? "不可用") · \(liquidityGrade(component.grade))")
                                    if let reason = component.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                                }
                                ForEach(leg.hardDowngrades, id: \.self) { Text($0).foregroundStyle(.orange) }
                            }.font(.callout).padding(.vertical, 8)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("财报事件窗口") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("证据状态：" + riskEvidenceState(risk.earnings.state)).font(.headline)
                        .accessibilityIdentifier("optionLabEarningsState")
                    Text("持有期与所填事件窗口：" + (risk.earnings.holdingOverlaps.map { $0 ? "重叠" : "不重叠" } ?? "证据不足"))
                    Text("跨事件持有偏好：" + (risk.earnings.allowsHoldingAcrossEvent.map { $0 ? "允许" : "不允许" } ?? "未决定"))
                    if let start = risk.earnings.windowStart, let end = risk.earnings.windowEnd {
                        Text("窗口 \(start.formatted(.iso8601)) 至 \(end.formatted(.iso8601))").font(.caption)
                    }
                    Text("Expected Move：\(risk.earnings.expectedMove?.decimalString ?? "不可用") USD / 股 · \(risk.earnings.expectedMoveFraction.map(scenarioPercent) ?? "不可用")")
                    Text("这是所选事件后 ATM 跨式 Mid 之和，不是置信区间。没有历史事件样本，不显示历史胜率、IV 溢价或 IV Crush 统计。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let selected = risk.earnings.selectedStraddle {
                        Text("跨式选择：K \(selected.strike.decimalString) · 到期 \(selected.settlementAt.formatted(.iso8601))").font(.caption)
                    }
                    ForEach(risk.earnings.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("短腿提前指派 · 启发式提示") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(assignmentLevel(risk.assignment.level)).font(.headline).accessibilityIdentifier("optionLabAssignmentLevel")
                    Text("内在价值 \(risk.assignment.intrinsicValue.decimalString) · 带符号时间价值 \(risk.assignment.extrinsicValue.decimalString) USD / 股")
                    Text("阈值 \(pricingNumber(risk.assignment.threshold)) · 股息现值 \(pricingNumber(risk.assignment.dividendPresentValue)) USD / 股")
                    if let date = risk.assignment.priorExDividendSession { Text("除息前交易日：" + date.iso8601) }
                    Text("近到期：\(risk.assignment.nearExpiry ? "是" : "否") · 深度价内：\(risk.assignment.deepInTheMoney ? "是" : "否")")
                    ForEach(risk.assignment.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Text("没有触发这份启发式也不能推断安全。本批不提供提前指派概率、美式定价或订单执行。")
                        .font(.caption).foregroundStyle(.orange)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("风险依据与版本") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("来源：" + risk.input.source.reference)
                    Text("模型：\(risk.modelReference.id) · \(risk.modelReference.version) · \(risk.modelReference.contentHash)")
                    Text("参数：\(risk.parameterReference.id) · \(risk.parameterReference.version) · \(risk.parameterReference.contentHash)")
                    Text("财报版本：\(risk.earnings.eventVersion ?? "未提供") · 日历版本：\(risk.earnings.calendarVersion ?? "未提供")")
                }.font(.caption).textSelection(.enabled)
            }
            ForEach(risk.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func liquidityGrade(_ grade: OptionLabLiquidityGrade) -> String {
        switch grade {
        case .excellent: "Excellent · 优"
        case .acceptable: "Acceptable · 可接受"
        case .weak: "Weak · 弱"
        case .avoid: "Avoid · 回避"
        case .dataInsufficient: "Data Insufficient · 数据不足"
        }
    }
    private func liquidityFactor(_ factor: OptionLabLiquidityFactor) -> String {
        switch factor {
        case .relativeSpread: "相对价差 ratio"
        case .openInterest: "OI 张数"
        case .volume: "可比成交量张数"
        case .quoteAge: "报价年龄秒"
        case .size: "双边最小张数"
        case .neighborContinuity: "相邻报价违例比例"
        }
    }
    private func riskEvidenceState(_ state: OptionLabRiskEvidenceState) -> String {
        switch state {
        case .available: "已核对所填证据"
        case .dataInsufficient: "数据不足"
        case .outsideHoldingWindow: "不在持有窗口内"
        case .notApplicable: "不适用"
        }
    }
    private func assignmentLevel(_ level: OptionLabAssignmentLevel) -> String {
        switch level {
        case .high: "高风险启发式触发"
        case .elevated: "需关注的启发式触发"
        case .noTrigger: "本次条件未触发（不代表安全）"
        case .dataInsufficient: "证据不足，不给安全结论"
        case .notApplicable: "本次提示不适用"
        }
    }

    private func scenarioAnalysis(_ scenario: OptionLabScenarioReport, enteredPrices: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(enteredPrices ? "价格 × IV 瞬时情景 · 所填成交价下的理论平仓损益 USD" : "价格 × IV 瞬时情景 · 保守开仓假设下的理论平仓损益 USD") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("INSTANTANEOUS · 常规模型格停留在 \(scenario.valuationAt.formatted(.iso8601))；不是到期分布或未来胜率。")
                        .foregroundStyle(.orange).accessibilityIdentifier("optionLabScenarioBoundary")
                    Text("基准标的 \(scenario.baseSpot.decimalString) USD / 股。每腿使用各自本地 IV；连续股息欧式 BSM 不包含美式提前行权或离散股息。")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            GridRow {
                                Text("价格变化 / IV 变化").bold()
                                ForEach(scenario.input.volatilityPointShocks, id: \.decimalString) { shock in
                                    Text(shock.decimalString + " 个百分点").bold()
                                }
                            }
                            ForEach(scenario.input.spotShocks, id: \.decimalString) { shock in
                                GridRow {
                                    Text(scenarioPercent(shock)).bold()
                                    ForEach(scenario.input.volatilityPointShocks, id: \.decimalString) { iv in
                                        if let cell = scenario.cells.first(where: { $0.spotShock == shock && $0.volatilityPointShock == iv }) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(pricingNumber(cell.conservative?.closeoutPnL))
                                                    .font(.system(.body, design: .monospaced))
                                                    .accessibilityIdentifier("optionLabScenarioCell-" + shock.decimalString + "-" + iv.decimalString)
                                                if cell.state != .available { Text(scenarioState(cell.state)).font(.caption).foregroundStyle(.orange) }
                                            }
                                        } else { Text("数据不足").foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("optionLabScenarioMatrix")
                    Text("理论退出价不包含新的退出价差或费用。每格沿用原开仓成交假设和完整费用额度，包含覆盖股票的价格变化；费用只计一次。零 IV、零价格 payoff 边界会单独标注，不伪装成常规模型格。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("来源：\(scenario.input.source.reference)").font(.caption).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(enteredPrices ? "逐格理论平仓损益与腿输入" : "逐格 Mid / 保守开仓的理论平仓损益与腿输入") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(scenario.cells.enumerated()), id: \.offset) { _, cell in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("价格 \(scenarioPercent(cell.spotShock)) · IV \(cell.volatilityPointShock.decimalString) 个百分点 · \(scenarioState(cell.state))").font(.headline)
                            Text("情景标的：\(cell.spot?.decimalString ?? "不可用") USD / 股")
                            if enteredPrices {
                                Text("所填成交价下的理论平仓损益：\(pricingNumber(cell.mid?.closeoutPnL)) USD")
                            } else {
                                Text("Mid 开仓理论平仓损益：\(pricingNumber(cell.mid?.closeoutPnL)) USD · 保守开仓：\(pricingNumber(cell.conservative?.closeoutPnL)) USD")
                            }
                            if let value = cell.conservative {
                                Text((enteredPrices ? "所填成交价净权利金 " : "保守开仓净权利金 ") + "\(value.netCreditTotal.decimalString) USD · 总费用 \(value.totalFees.decimalString) USD · 股票损益 \(pricingNumber(value.stockPnL)) USD")
                            }
                            ForEach(cell.legs, id: \.contractID) { leg in
                                Text("\(leg.contractID) · 原 IV \(pricingNumber(leg.baseIV.map { $0 * 100 }, suffix: "%")) → 情景 IV \(pricingNumber(leg.shockedIV.map { $0 * 100 }, suffix: "%")) · 理论价 \(pricingNumber(leg.theoreticalUnitPrice)) USD / 股")
                            }
                        }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    Text("方法：\(scenario.input.methodVersion) · 结果显示保留 8 位有效数字，完整模型输入与数值保存在快照中。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            ForEach(scenario.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func scenarioPercent(_ value: Money) -> String {
        guard let percent = try? value.multiplied(by: "100") else { return "不可表示" }
        return percent.decimalString + "%"
    }
    private func scenarioState(_ state: OptionLabScenarioState) -> String {
        switch state {
        case .available: "本模型内可用"
        case .zeroVolatilityBoundary: "零波动率边界"
        case .zeroSpotPayoffBoundary: "零价格 payoff 边界"
        case .missingPricing: "未启用定价模型"
        case .missingLegIV: "必需腿缺少本地 IV"
        case .negativeVolatility: "IV 调整后为负，拒绝计算"
        case .numericFailure: "数值不可用"
        }
    }

    private func legPricing(_ leg: OptionLabLegPricing, in report: OptionLabReport) -> some View {
        let isPut = ([report.input.shortLeg] + (report.input.longLeg.map { [$0] } ?? [])).first { $0.contractID == leg.contractID }?.right == .put
        return GroupBox("\(leg.direction == .sell ? "卖出腿" : "买入腿") · \(leg.contractID)") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205))], alignment: .leading, spacing: 12) {
                    metric(report.usesEnteredPrices ? "所填成交价 USD / 股" : "Mid 输入 USD / 股", leg.quoteMid)
                    pricingMetric("理论价 USD / 股 · 手工 σ", leg.theoreticalPrice)
                    pricingMetric("当前内在值边界 USD / 股", leg.expiryIntrinsicValue)
                    pricingMetric(report.usesEnteredPrices ? "手工价格反解 IV" : "本地反解 IV · 来自 Mid", leg.impliedVolatility.volatility, factor: 100, suffix: "%")
                }
                Text("理论价状态：" + pricingState(leg.theoryState)).font(.caption).foregroundStyle(.secondary)
                Text("IV 状态：" + pricingState(leg.impliedVolatility.state))
                    .foregroundStyle(leg.impliedVolatility.state == .available ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("optionLabIVState-" + leg.contractID)
                if let greeks = leg.canonicalGreeks {
                    Text("以下敏感度使用该腿的本地 IV；不是上方手工 σ 的敏感度。").font(.caption).foregroundStyle(.secondary)
                    greekGrid(greeks, aggregate: false)
                } else { Text("本地 IV / Greeks 不可用；没有采用供应商值或人工波动率替代。").foregroundStyle(.orange) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205))], alignment: .leading, spacing: 12) {
                    pricingMetric(isPut ? "Q 下实值概率 N(−d₂)" : "Q 下实值概率 N(d₂)", leg.itmProbability, factor: 100, suffix: "%")
                    pricingMetric("|Delta|（不是胜率）", leg.absoluteDelta)
                    pricingMetric("|Delta| − 实值概率", leg.itmDeltaDifference, factor: 100, suffix: " 个百分点")
                }
                Text("实值概率只说明模型下到期处于价内；扣除权利金、费用后的策略获利概率在下方分布中另算。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("本地 IV 求解依据") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("迭代次数：\(leg.impliedVolatility.iterations) · 价格残差：\(pricingNumber(leg.impliedVolatility.residual))")
                        Text("σ bracket：\(pricingNumber(leg.impliedVolatility.bracketLower)) 至 \(pricingNumber(leg.impliedVolatility.bracketUpper))")
                        Text("σ 容差：\(pricingNumber(leg.impliedVolatility.sigmaTolerance)) · 价格容差：\(pricingNumber(leg.impliedVolatility.priceTolerance))")
                    }.font(.caption).textSelection(.enabled)
                }
                ForEach(leg.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func distributionAnalysis(_ pricing: OptionLabPricingReport, enteredPrices: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("主分布 · 使用短腿本地 IV") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RISK_NEUTRAL · 风险中性测度 Q · 不是历史频率或真实世界概率")
                        .font(.headline).foregroundStyle(.orange).accessibilityIdentifier("optionLabDistributionMeasure")
                    Text("状态：" + pricingState(pricing.distributionState)).accessibilityIdentifier("optionLabDistributionStatus")
                    if let distribution = pricing.distribution {
                        distributionReport(distribution, sensitivity: false, enteredPrices: enteredPrices)
                    } else {
                        Text("没有可用的主分布；不显示获利概率、EV 或尾部数值，不回退人工 σ。")
                            .foregroundStyle(.secondary).accessibilityIdentifier("optionLabDistributionUnavailable")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if pricing.legs.count > 1 {
                DisclosureGroup("长腿 IV 敏感度对照（不参与主排序）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("将整条策略改用长腿本地 IV 重新计算。此处与主分布并列比较，不能解释为概率上下界或模型置信区间。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("状态：" + pricingState(pricing.longLegSensitivityState))
                        if let sensitivity = pricing.longLegSensitivity { distributionReport(sensitivity, sensitivity: true, enteredPrices: enteredPrices) }
                        else { Text("长腿对照不可用；没有填入替代波动率。").foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("optionLabLongIVSensitivity")
            }
        }
    }
    private func distributionReport(_ distribution: OptionLabDistributionReport, sensitivity: Bool, enteredPrices: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("σ 来源合约：\(distribution.volatilitySourceContractID) · 本地 IV \(pricingNumber(distribution.volatility * 100, suffix: "%"))")
                .font(.callout).textSelection(.enabled)
            Text("\(pricingNumber(distribution.confidence * 100, suffix: "%")) 尾部口径：取最差 \(pricingNumber(distribution.tailMass * 100, suffix: "%")) 的到期净损益；不是统计置信区间。")
                .font(.caption).foregroundStyle(.secondary)
            if enteredPrices {
                distributionOutcome(distribution.mid, title: "所填成交价损益", id: sensitivity ? "optionLabSensitivityEntered" : "optionLabDistributionEntered")
            } else {
                distributionOutcome(distribution.mid, title: "Mid 损益", id: sensitivity ? "optionLabSensitivityMid" : "optionLabDistributionMid")
                distributionOutcome(distribution.conservative, title: "保守成交损益", id: sensitivity ? "optionLabSensitivityConservative" : "optionLabDistributionConservative")
            }
            DisclosureGroup("分布模型与数值依据") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("版本：\(distribution.modelVersion)")
                    Text("连续 r \(pricingNumber(distribution.rate)) · 连续 q \(pricingNumber(distribution.dividendYield)) · T \(pricingNumber(distribution.timeYears)) 年")
                    Text("绝对 USD 容差 \(pricingNumber(distribution.absoluteUSDTolerance)) · 相对容差 \(pricingNumber(distribution.relativeTolerance)) · 分段上限 \(distribution.maximumSubintervals)")
                    Text("数值误差估计只描述积分／浮点计算，不包含输入误差、欧式近似误差或模型风险。")
                }.font(.caption).textSelection(.enabled)
            }
            ForEach(distribution.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func distributionOutcome(_ outcome: OptionLabDistributionOutcome, title: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityIdentifier(id)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205))], alignment: .leading, spacing: 12) {
                pricingMetric("Q 下净获利概率（PnL > 0）", outcome.probabilityProfit, factor: 100, suffix: "%")
                pricingMetric("到期净损益 EV · 未贴现 USD", outcome.expectedPnL)
                pricingMetric("最差尾部收益均值 · 带符号 USD", outcome.signedTailMean)
                pricingMetric("尾部损失 max(0, −尾均值) USD", outcome.tailLoss)
                pricingMetric("现值 EV USD", outcome.presentValueExpectedPnL)
                pricingMetric("估计绝对数值误差 USD", outcome.numericalErrorBound)
            }
            Text("未选择现值折算口径时，现值 EV 保持不可用；不把未贴现 EV 冒充现值。尾均值保留正负号，尾部损失保持非负。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func greekGrid(_ greeks: OptionLabGreeks, aggregate: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading, spacing: 12) {
            pricingMetric(aggregate ? "Delta · 组合" : "Delta · 每股", greeks.delta)
            pricingMetric(aggregate ? "Gamma · 组合" : "Gamma · 每股", greeks.gamma)
            pricingMetric("Theta / 自然日", greeks.thetaPerDay)
            pricingMetric("Vega / σ 上升 1 个百分点", greeks.vegaPerPercentagePoint)
            pricingMetric("Rho / r 上升 1 个百分点", greeks.rhoPerPercentagePoint)
        }
    }
    private func pricingMetric(_ title: String, _ value: Double?, factor: Double = 1, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(pricingNumber(value.map { $0 * factor }, suffix: suffix))
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
    private func pricingNumber(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "不可用" }
        return String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value) + suffix
    }
    private func pricingState(_ value: OptionLabPricingState) -> String {
        switch value {
        case .available: "可用（仅在本模型假设内）"
        case .expiryBoundary: "到期边界；不报告常规 IV / Greeks"
        case .zeroVolatilityBoundary: "零波动率边界"
        case .zeroSpotBoundary: "标的价格为零的边界"
        case .tooNearExpiry: "距离到期过近，拒绝常规模型指标"
        case .boundaryPrice: "报价处于无套利边界，无法取得有效内点 IV"
        case .arbitrageViolation: "报价不满足本模型无套利界限"
        case .ivNotBracketed: "给定搜索区间未包围 IV 根"
        case .ivIterationLimit: "IV 迭代次数达到上限"
        case .residualNotMet: "IV 价格残差未满足要求"
        case .numericFailure: "数值计算失败"
        case .invalidInput: "模型输入无效"
        case .missingLegIV: "必需腿缺少可用本地 IV"
        case .notApplicable: "不适用"
        }
    }
    private func outcome(_ value: OptionLabOutcome, title: String, shortDTE: Bool) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(fundingName(value.funding)).foregroundStyle(value.funding == .notAssessed || value.canFund ? Color.secondary : Color.red)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading, spacing: 14) {
                    metric("净权利金 USD", value.netCreditTotal, id: value.pricing == .entered ? "optionLabEnteredCreditDetails" : (value.pricing == .conservative ? "optionLabConservativeCreditDetails" : "optionLabMidCredit"))
                    metric("总费用 USD", value.totalFees); metric("最大盈利 USD", value.maxProfit); metric("最大亏损 USD", value.maxLoss)
                    if let breakEven = value.breakEven { metric("盈亏平衡 USD / 股", breakEven) }
                    else { Text("盈亏平衡：无（收益上限仍低于零）") }
                    metric("净资金需求 USD", value.capitalRequired)
                    metric("指派名义付款 USD", value.nominalAssignmentPayment); metric("权利金收益率", value.premiumYield, percent: true)
                    metric(shortDTE ? "简单年化 · 少于 7 天，高度敏感" : "简单年化（非预测）", value.annualizedSimple, percent: true, subdued: shortDTE)
                    if let risk = value.returnOnRisk { metric("最大风险回报率", risk, percent: true) }
                    if let stock = value.stockMarketValueYield { metric("备兑股票市值口径", stock, percent: true) }
                }
                ForEach(value.fills, id: \.contractID) { fill in Text("\(fill.direction == .sell ? "卖出" : "买入") \(fill.contractID)：\(fill.unitPrice.decimalString) USD / 股").font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private struct PayoffRow: Identifiable { let price: Money; var mid: Money?; var conservative: Money?; var id: String { price.decimalString } }
    private func payoffRows(_ report: OptionLabReport) -> [PayoffRow] {
        var rows: [String: PayoffRow] = [:]
        for point in report.mid.points { rows[point.spot.decimalString] = .init(price: point.spot, mid: point.pnl) }
        for point in report.conservative.points {
            let key = point.spot.decimalString
            if rows[key] == nil { rows[key] = .init(price: point.spot) }
            rows[key]?.conservative = point.pnl
        }
        return rows.values.sorted { $0.price < $1.price }
    }
    private struct PlotPoint: Identifiable { let id: String; let price: Double; let pnl: Double; let series: String }
    private func payoffChart(_ report: OptionLabReport) -> some View {
        let series = report.usesEnteredPrices ? [("所填成交价", report.selectedOutcome.points)] : [("Mid", report.mid.points), ("保守", report.conservative.points)]
        let points = series.flatMap { name, values in
            values.enumerated().compactMap { index, point -> PlotPoint? in
                guard let price = Double(point.spot.decimalString), let pnl = Double(point.pnl.decimalString), price.isFinite, pnl.isFinite else { return nil }
                return .init(id: "\(name)-\(index)", price: price, pnl: pnl, series: name)
            }
        }
        return GroupBox("到期损益图（所填情景及策略转折点，精确值见表）") {
            Chart(points) { point in
                LineMark(x: .value("到期标的价格", point.price), y: .value("到期损益", point.pnl)).foregroundStyle(by: .value("成交假设", point.series))
                PointMark(x: .value("到期标的价格", point.price), y: .value("到期损益", point.pnl)).foregroundStyle(by: .value("成交假设", point.series))
            }.frame(height: 230).accessibilityLabel("到期损益示意图；不代表盘中价格或获利概率，精确数值见表")
        }
    }
    private func frozenInput(_ report: OptionLabReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("输入 ID：\(report.input.id.uuidString)")
            Text("模型：\(report.modelReference.id) \(report.modelReference.version) · \(report.modelReference.contentHash)")
            Text("参数：\(report.parameterReference.id) \(report.parameterReference.version) · \(report.parameterReference.contentHash)")
            Text("来源：\(report.input.underlying.source.reference) · 到期依据：\(report.input.expiry.source.reference)")
            if let cost = report.coveredCallCostBasis {
                Text("手填平均持股成本：\(cost.costPerShare.decimalString) USD / 股 · 覆盖 \(cost.coveredShares.decimalString) 股；不是账本成本核验。")
                Text("成本口径模型：\(cost.model.reference.id) \(cost.model.reference.version)")
            }
            if let capital = report.input.capital {
                Text("资金性质：\(capital.origin.rawValue) · \(capital.reference)")
                Text("成交前现金 \(capital.cashBeforeTrade.decimalString) · 已承诺现金 \(capital.committedCash.decimalString) · 股数 \(capital.availableShares.decimalString) · 已承诺股数 \(capital.committedShares.decimalString)")
            } else {
                Text("账户资金与持股：未提供，仅计算策略需求。")
            }
            if report.input.isContractOnly {
                Text("简洁合约测算：时间为本地录入／计算记录，不是交易所报价时间；合约标识由所填参数生成。")
            }
            Text((report.usesEnteredPrices ? "单价口径，不另加滑点" : "λ \(report.input.policy.lambda.decimalString)") + " · 每张每腿费用 \(report.input.policy.openingFeePerContract.decimalString) · 固定费 \(report.input.policy.ticketFee.decimalString) · 到期总费 \(report.input.policy.terminalFeeTotal.decimalString)")
            Text("标的当前价：\(report.input.underlying.enteredPrice?.decimalString ?? "未采用") · Bid/Ask：\(report.input.underlying.bid?.decimalString ?? "未提供") / \(report.input.underlying.ask?.decimalString ?? "未提供")")
            ForEach([report.input.shortLeg] + (report.input.longLeg.map { [$0] } ?? []), id: \.contractID) { leg in
                Text("\(leg.contractID) · \(leg.right.rawValue) \(leg.strike.decimalString) × \(leg.multiplier) × \(leg.quantity) · 所填成交价 \(leg.enteredPrice?.decimalString ?? "未采用") · Bid/Ask \(leg.bid?.decimalString ?? "未提供")/\(leg.ask?.decimalString ?? "未提供") · 数量 \(leg.bidSize.map(String.init) ?? "未提供")/\(leg.askSize.map(String.init) ?? "未提供") · tick \(leg.tick?.decimalString ?? "缺失") · \(report.input.isContractOnly ? "录入" : "报价") \(leg.quotedAt.formatted(.iso8601)) · \(report.input.isContractOnly ? "计算" : "接收") \(leg.receivedAt.formatted(.iso8601))")
            }
        }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("重新载入快照目录") { Task { await model.reloadSaved() } }.disabled(blocked).accessibilityIdentifier("optionLabReloadSaved")
            if let error = model.listError { Text(error).foregroundStyle(.red) }
            if model.saved.isEmpty { Text("暂无可展示的保存记录。目录只展示摘要；打开后必须通过完整输入重算。").foregroundStyle(.secondary) }
            ForEach(model.saved) { item in
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.underlyingSymbol) · \(strategyName(item.strategy))").font(.headline)
                            Text("\(item.origin == .synthetic ? "SYNTHETIC" : "MANUAL") · \(item.createdAt.formatted(.iso8601)) · \(item.id.uuidString)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重算并打开") {
                            calculatedDraft = nil; calculatedReportID = nil; expiryPresentation = nil
                            let session = visibleSession, navigation = navigationEpoch
                            Task {
                                guard visibleSession == session, navigationEpoch == navigation else { return }
                                await model.open(item.id)
                                guard visibleSession == session, navigationEpoch == navigation,
                                      model.savedID == item.id, model.report?.input.id == item.id else { return }
                                section = "结果"
                            }
                        }.disabled(blocked).accessibilityIdentifier("optionLabSavedOpen")
                    }
                }
            }
            Text("快照只保存在独立期权实验室库；当前研究／账本归档不含它。本页没有导出、恢复或文件面板操作。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func copyToDraft(_ report: OptionLabReport) {
        calculatedDraft = nil; calculatedReportID = nil; expiryPresentation = nil
        var value = OptionLabInputDraft(input: report.input)
        if let basis = model.reportLedgerBasis { try? value.useLedgerBasis(basis) }
        draft = value; model.draftChanged(); section = "输入"
        pricingExpanded = value.pricing.enabled
        manualQuoteAt = report.input.asOf; manualSettlementAt = report.input.expiry.settlementAt
        manualQuoteReference = value.sourceReference; manualExpiryReference = value.expiryReference
        manualAssistanceMessage = nil; manualCommonTimeConfirmed = false
        checklist = nil; checkedDraft = nil
        synchronizeProtectionQuantity = false; useEnteredChartPrices = false
    }
    private func startContractOnlyDraft() {
        guard !blocked, draft.origin == .manual, draft.chainEvidence == nil else { return }
        // This explicit action starts a new draft and discards advanced evidence;
        // it cannot relabel an imported or synthetic source as a manual contract.
        var simple = OptionLabInputDraft()
        simple.strategy = draft.strategy; simple.symbol = draft.symbol; simple.asset = draft.asset
        simple.underlyingPrice = draft.underlyingPrice
        simple.coveredCallCostPerShare = draft.coveredCallCostPerShare
        simple.shortLeg.strike = draft.shortLeg.strike; simple.shortLeg.quantity = draft.shortLeg.quantity
        simple.shortLeg.multiplier = draft.shortLeg.multiplier; simple.shortLeg.enteredPrice = draft.shortLeg.enteredPrice
        simple.longLeg.strike = draft.longLeg.strike; simple.longLeg.quantity = draft.shortLeg.quantity
        simple.longLeg.multiplier = draft.longLeg.multiplier; simple.longLeg.enteredPrice = draft.longLeg.enteredPrice
        simple.expirationDate = draft.expirationDate; simple.settlementAt = draft.settlementAt
        simple.openingFeePerContract = draft.openingFeePerContract
        simple.ticketFee = draft.ticketFee; simple.terminalFeeTotal = draft.terminalFeeTotal
        draft = simple; ledgerCandidate = nil; quoteDetailsExpanded = false
        inputError = nil; section = "输入"
    }
    private func saveCurrentReport() {
        guard section == "输入", let current = currentDraftReport,
              model.canSave, !preparingLedger, let expectedRevision = model.revision else { return }
        let inputID = current.input.id
        let session = visibleSession, navigation = navigationEpoch
        Task {
            guard visibleSession == session, navigationEpoch == navigation,
                  currentDraftReport?.input.id == inputID, model.revision == expectedRevision else { return }
            _ = await model.save(expectedID: inputID, expectedRevision: expectedRevision)
            // The model owns publication. A completed commit after leaving does
            // not navigate, select a newer report or authorize another save.
        }
    }
    private func calculate() {
        guard !blocked else { return }
        calculatedDraft = nil; calculatedReportID = nil; expiryPresentation = nil
        model.draftChanged()
        let calculationDate = Date()
        do {
            let captured = draft, session = visibleSession, navigation = navigationEpoch
            let input = try captured.buildForCalculation(createdAt: calculationDate), basis = captured.ledgerBasis
            inputError = nil
            Task {
                guard visibleSession == session, draft == captured, navigationEpoch == navigation else { return }
                await model.calculate(input, ledgerBasis: basis)
                guard visibleSession == session, draft == captured, navigationEpoch == navigation else { return }
                guard model.report?.input.id == input.id else {
                    if model.hasError {
                        section = "输入"
                        if !captured.usesContractParametersOnly {
                            quoteDetailsExpanded = true; advancedAssumptionsExpanded = true
                            pricingExpanded = draft.pricing.enabled
                        }
                        checklist = captured.calculationChecklist(createdAt: calculationDate); checkedDraft = captured
                        inputTarget = captured.usesContractParametersOnly ? "option-contract-parameters" : "option-daily-preparation"
                        inputFocusRequest = UUID()
                    }
                    return
                }
                calculatedDraft = captured; calculatedReportID = input.id
                section = "输入"
                inputTarget = "option-reference-summary"; inputFocusRequest = UUID()
            }
        } catch {
            section = "输入"
            let currentChecklist = draft.calculationChecklist(createdAt: calculationDate)
            checklist = currentChecklist; checkedDraft = draft
            let issues = currentChecklist.groups.flatMap { $0.issues.map(\.message) }
            if draft.usesContractParametersOnly {
                if currentChecklist.groups.contains(where: { $0.section == .costs }) { quoteDetailsExpanded = true }
                inputError = issues.isEmpty ? "请核对合约、价格、到期时间和费用，暂未生成计算。" : issues.joined(separator: " ")
                inputTarget = "option-contract-parameters"
            } else {
                quoteDetailsExpanded = true; advancedAssumptionsExpanded = true
                pricingExpanded = draft.pricing.enabled
                inputError = issues.isEmpty
                    ? "输入未能组成有效计算。请核对已启用的进阶资料，或选择仅保留合约参数进行基础测算。"
                    : "请补齐或修正：" + issues.joined(separator: "；")
                inputTarget = "option-daily-preparation"
            }
            inputFocusRequest = UUID()
        }
    }
    private func inspectLedger(_ snapshot: LedgerSnapshot) {
        let captured = draft, account = ledgerAccount, securityID = ledgerSecurityID, evidence = completeness, session = visibleSession
        preparingLedger = true; ledgerCandidate = nil
        Task {
            defer { if visibleSession == session { preparingLedger = false } }
            do {
                let basis = try await Task.detached {
                    try OptionLabLedgerBridge.inspect(snapshot: snapshot, accountID: account,
                        underlying: .init(id: securityID, symbol: captured.symbol, kind: captured.asset == .stock ? .stock : .etf),
                        asOf: captured.evaluationDate(), completenessEvidence: evidence)
                }.value
                guard visibleSession == session, draft == captured, ledgerAccount == account, ledgerSecurityID == securityID, completeness == evidence, model.ledgerSnapshot?.revision == snapshot.revision else { return }
                ledgerCandidate = basis
            } catch {
                guard visibleSession == session else { return }
                inputError = "账本依据未通过身份、时间或重放校验；未把它作为资金输入。"
            }
        }
    }
    private func fields<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field(_ title: String, _ text: Binding<String>, id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).onSubmit { }
                .accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
    private func metric(_ title: String, _ money: Money, percent: Bool = false, id: String = "", subdued: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(percent ? ((try? money.multiplied(by: "100").decimalString) ?? "不可表示") + "%" : money.decimalString)
                .font(.system(subdued ? .caption : .body, design: .monospaced)).foregroundStyle(subdued ? Color.secondary : Color.primary)
                .textSelection(.enabled).accessibilityIdentifier(id)
        }
    }
    private func containsSynthetic(_ report: OptionLabReport) -> Bool {
        let input = report.input
        // Keep the same provenance rule with bounded Swift 6.1 type inference.
        let primarySynthetic: Bool = input.underlying.source.origin == .synthetic
            || input.shortLeg.source.origin == .synthetic
        let contractSynthetic: Bool = input.longLeg?.source.origin == .synthetic
            || input.expiry.source.origin == .synthetic || input.capital?.origin == .synthetic
        let pricingSynthetic: Bool = input.pricing?.source.origin == .synthetic
        let riskSynthetic: Bool = input.risk?.containsSyntheticInput == true
        let scenarioSynthetic: Bool = input.scenario?.source.origin == .synthetic
        return primarySynthetic || contractSynthetic || pricingSynthetic || riskSynthetic || scenarioSynthetic
    }
    private func strategyName(_ strategy: OptionLabStrategy) -> String {
        switch strategy { case .cashSecuredPut: "现金担保卖 Put"; case .coveredCall: "备兑 Call"; case .putCreditSpread: "Put 信用价差"; case .callCreditSpread: "Call 信用价差" }
    }
    private func fundingName(_ funding: OptionLabFunding) -> String {
        switch funding { case .notAssessed: "未核对账户资金与持股；已计算策略需求"; case .sufficient: "满足本次输入的资金约束；不等于券商准入"; case .insufficientCash: "成交前未承诺现金不足"; case .insufficientShares: "可覆盖持股不足" }
    }
    private func gapName(_ gap: OptionLabLedgerGap) -> String {
        switch gap {
        case .noAccountHistory: "账户没有交易历史"; case .completenessNotConfirmed: "未确认完整性"
        case .shortEquityNeedsMarginEvidence: "空头股票需要额外保证金依据"; case .uncoveredExistingCall: "现有空 Call 未完全覆盖"
        case .existingCashCommitmentsExceedBalance: "现有现金义务超过余额"; case .negativeCash: "现金为负"
        }
    }
}
