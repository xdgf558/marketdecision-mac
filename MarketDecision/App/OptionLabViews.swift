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
            if let model { OptionLabContent(model: model) }
            else if failed {
                ContentUnavailableView("期权实验室暂不可用", systemImage: "chart.xyaxis.line", description: Text("本地快照库未能打开，不显示旧计算结果。"))
                Button("重新打开") { attempt = UUID() }
            } else { ProgressView("正在打开离线实验室…") }
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

struct OptionLabContent: View {
    @Bindable var model: OptionLabWorkspaceModel
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
    private var blocked: Bool { model.isBusy || preparingLedger }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text("本地模型与到期损益 · 手工假设或合成输入 · 不联网、不下单。资金约束和风险中性概率都不代表交易许可或真实胜率。")
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("optionLabMessage") }
            if let inputError { Text(inputError).foregroundStyle(.red).accessibilityIdentifier("optionLabInputError") }
            Picker("实验室内容", selection: $section) {
                Text("数据对照").tag("数据对照"); Text("组合风险").tag("组合风险"); Text("期权链").tag("期权链"); Text("输入").tag("输入"); Text("结果").tag("结果"); Text("模型分析").tag("模型分析"); Text("风险与情景").tag("风险与情景"); Text("已保存").tag("已保存"); Text("波动率历史").tag("波动率历史"); Text("期权归档").tag("期权归档")
            }.pickerStyle(.segmented).accessibilityIdentifier("optionLabSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                    else if section == "输入" { editor }
                    else if section == "已保存" { history }
                    else if let report = model.report {
                        if section == "模型分析" { pricingAnalysis(report) }
                        else if section == "风险与情景" { riskAndScenarioAnalysis(report) }
                        else { result(report) }
                    }
                    else {
                        ContentUnavailableView("尚无已核对计算", systemImage: "chart.xyaxis.line",
                            description: Text("填写完整输入并计算，或显式载入合成模板。修改输入后，旧结果立即失效。"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }.id(section)
        }.padding(24)
        .onChange(of: draft) { _, _ in
            model.draftChanged(); inputError = nil
            if ledgerCandidate?.capital != draft.ledgerBasis?.capital { ledgerCandidate = nil }
        }
        .onChange(of: section) { _, _ in navigationEpoch = UUID() }
        .onChange(of: model.ledgerSnapshot?.revision) { _, _ in
            ledgerCandidate = nil
            if model.ledgerSnapshot?.accounts.contains(where: { $0.id == ledgerAccount }) != true { ledgerAccount = "" }
        }
        .onChange(of: ledgerAccount) { _, _ in ledgerCandidate = nil }
        .onChange(of: ledgerSecurityID) { _, _ in ledgerCandidate = nil }
        .onChange(of: completeness) { _, _ in ledgerCandidate = nil }
        .onDisappear { visibleSession = UUID(); preparingLedger = false; model.disappear() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("期权实验室").font(.system(size: 32, weight: .bold))
                    Text("从完整输入核对四种策略的定价与到期损益").foregroundStyle(.secondary)
                }
                Spacer()
                if blocked { ProgressView().controlSize(.small) }
            }
            if section != "数据对照" && section != "组合风险" && section != "期权链" && section != "波动率历史" && section != "期权归档" {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading, spacing: 8) {
                Button("新建手工输入") { model.draftChanged(); draft = .init(); ledgerCandidate = nil; section = "输入" }.disabled(blocked).accessibilityIdentifier("optionLabNew")
                Button("载入合成模板") {
                    do { model.draftChanged(); draft = try .synthetic(strategy: draft.strategy); section = "输入" }
                    catch { inputError = "合成模板未能建立，没有填入替代值。" }
                }.disabled(blocked).accessibilityIdentifier("optionLabTemplate")
                if draft.origin == .synthetic {
                    Button("合成风险与情景示例") {
                        do { try draft.useSyntheticRiskScenarioAssumptions(); section = "输入" }
                        catch { inputError = "请先载入完整合成模板；未改动现有输入。" }
                    }.disabled(blocked).help("明确填入合成流动性、事件与日历，r=5%、q=1%、理论 σ=25%，以及 3×3 价格/IV 情景；不是市场数据。")
                        .accessibilityIdentifier("optionLabRiskScenarioSynthetic")
                }
                Button("计算") { calculate() }.disabled(blocked).keyboardShortcut("r", modifiers: [.command, .shift]).accessibilityIdentifier("optionLabCalculate")
                Button("保存快照") {
                    let session = visibleSession, inputID = model.report?.input.id
                    Task {
                        guard visibleSession == session, model.report?.input.id == inputID else { return }
                        await model.save()
                    }
                }.disabled(!model.canSave || preparingLedger).accessibilityIdentifier("optionLabSave")
                Button("重新载入") {
                    let session = visibleSession
                    Task { guard visibleSession == session else { return }; await model.load() }
                }.disabled(blocked).accessibilityIdentifier("optionLabReload")
            }
            }
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("输入性质与时间") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(draft.origin == .synthetic ? "SYNTHETIC · 合成模板及其修改仍是合成研究，不变成真实行情。" : "MANUAL · 所填数据均为手工假设，来源文字不授予实时或历史数据资格。")
                        .foregroundStyle(draft.origin == .synthetic ? .orange : .secondary).accessibilityIdentifier("optionLabOrigin")
                    Picker("策略", selection: $draft.strategy) { ForEach(OptionLabStrategy.allCases, id: \.self) { Text(strategyName($0)).tag($0) } }
                        .accessibilityIdentifier("optionLabStrategy")
                    fields {
                        field("标的代码", $draft.symbol, id: "optionLabSymbol")
                        Picker("标的类型", selection: $draft.asset) { Text("股票").tag(OptionLabAsset.stock); Text("ETF").tag(OptionLabAsset.etf) }
                        field("评估时刻（ISO 8601，含时区）", $draft.asOf)
                        field("到期日（纽约日期 YYYY-MM-DD）", $draft.expirationDate)
                        field("明确的到期时刻（含时区）", $draft.settlementAt, id: "optionLabSettlementAt")
                        field("报价来源／假设说明", $draft.sourceReference)
                        field("到期时刻依据", $draft.expiryReference)
                    }
                    Text("到期时刻必须明确输入。本批没有官方到期日历准入，不推定 16:00、不输出交易日 DTE。报价时效只校验所选离线场景，不表示这些数据是实时。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            pricingEditor
            riskEditor
            scenarioEditor
            GroupBox("标的报价（USD / 股）") {
                fields {
                    field("买价 Bid", $draft.underlyingBid); field("卖价 Ask", $draft.underlyingAsk)
                    field("报价时刻", $draft.underlyingQuotedAt); field("接收时刻", $draft.underlyingReceivedAt)
                }
            }
            legEditor("卖出腿", $draft.shortLeg, id: "optionLabShort")
            if draft.hasLongLeg { legEditor("买入保护腿", $draft.longLeg, id: "optionLabLong") }
            GroupBox("成交与费用假设") {
                fields {
                    field("保守滑点 λ（0～0.5）", $draft.lambda)
                    field("开仓费 USD / 每张每腿", $draft.openingFeePerContract)
                    field("整组开仓固定费 USD", $draft.ticketFee)
                    field("到期总费用 USD（整组一次）", $draft.terminalFeeTotal)
                }
            }
            capitalEditor
            ledgerEditor
            GroupBox("到期标的价格（USD / 股，每行一个，1～401 个）") {
                TextEditor(text: $draft.scenarioPrices).font(.system(.body, design: .monospaced)).frame(minHeight: 110)
                    .accessibilityLabel("到期情景价格").accessibilityIdentifier("optionLabScenarioPrices")
            }
        }.disabled(blocked)
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
                    Text("理论价使用上面的手工 σ。IV 由每条腿的 Mid 在本地反解，Greeks 用该腿反解结果；主分布只用短腿反解 IV，失败不回退手工 σ 或供应商值。")
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
                    Text("先从每条腿的 Mid 本地反解 IV，再施加同一百分点变化。未开启模型或必需腿缺 IV 时保留不可用原因，不改用理论 σ。")
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
                field("Bid USD / 股", leg.bid); field("Ask USD / 股", leg.ask)
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
    private func result(_ report: OptionLabReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(containsSynthetic(report) ? "SYNTHETIC 合成" : "MANUAL 手工假设") · \(strategyName(report.input.strategy)) · \(model.savedID == nil ? "未保存预览" : "已按完整输入重算")")
                        .font(.headline).accessibilityIdentifier("optionLabReportStatus")
                    Text("评估 \(report.input.asOf.formatted(.iso8601)) · 到期 \(report.input.expiry.settlementAt.formatted(.iso8601))")
                    Text("自然日 DTE \(report.dte) · ANN_v1 简单年化 · 到期损益不包含提前指派路径；启用后的模型指标在“模型分析”页。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !report.conservative.canFund || !report.mid.canFund {
                        Text("资金或覆盖持股不足：以下仅为损益研究，不能表示可执行策略。")
                            .foregroundStyle(.red).accessibilityIdentifier("optionLabFundingGap")
                    }
                    if report.pricing != nil {
                        Button("查看模型分析") { section = "模型分析" }.accessibilityIdentifier("optionLabShowPricing")
                    }
                    Button("复制为新草稿") { copyToDraft(report) }.disabled(blocked).accessibilityIdentifier("optionLabCopy")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            outcome(report.mid, title: "Mid 基准", shortDTE: report.dte < 7)
            outcome(report.conservative, title: "保守成交", shortDTE: report.dte < 7)
            payoffChart(report)
            GroupBox("精确到期损益（USD；— 为仅另一口径加入的转折点）") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { Text("到期价格 / 股").bold(); Text("Mid 损益").bold(); Text("保守损益").bold() }
                    ForEach(payoffRows(report)) { row in
                        GridRow { Text(row.price.decimalString); Text(row.mid?.decimalString ?? "—"); Text(row.conservative?.decimalString ?? "—") }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            DisclosureGroup("本次输入与模型依据") { frozenInput(report) }
            ForEach(report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
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
                        Text("理论价使用显式假设 σ；IV / Greeks 来自逐腿 Mid 本地求解；主分布使用短腿 IV。失败不会改用人工 σ 或供应商值。")
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
                distributionAnalysis(pricing)
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
            if let scenario = report.scenario { scenarioAnalysis(scenario) }
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

    private func scenarioAnalysis(_ scenario: OptionLabScenarioReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("价格 × IV 瞬时情景 · 保守开仓假设下的理论平仓损益 USD") {
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
            DisclosureGroup("逐格 Mid / 保守开仓的理论平仓损益与腿输入") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(scenario.cells.enumerated()), id: \.offset) { _, cell in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("价格 \(scenarioPercent(cell.spotShock)) · IV \(cell.volatilityPointShock.decimalString) 个百分点 · \(scenarioState(cell.state))").font(.headline)
                            Text("情景标的：\(cell.spot?.decimalString ?? "不可用") USD / 股")
                            Text("Mid 开仓理论平仓损益：\(pricingNumber(cell.mid?.closeoutPnL)) USD · 保守开仓：\(pricingNumber(cell.conservative?.closeoutPnL)) USD")
                            if let value = cell.conservative {
                                Text("保守开仓净权利金 \(value.netCreditTotal.decimalString) USD · 总费用 \(value.totalFees.decimalString) USD · 股票损益 \(pricingNumber(value.stockPnL)) USD")
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
                    metric("Mid 输入 USD / 股", leg.quoteMid)
                    pricingMetric("理论价 USD / 股 · 手工 σ", leg.theoreticalPrice)
                    pricingMetric("当前内在值边界 USD / 股", leg.expiryIntrinsicValue)
                    pricingMetric("本地反解 IV · 来自 Mid", leg.impliedVolatility.volatility, factor: 100, suffix: "%")
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
    private func distributionAnalysis(_ pricing: OptionLabPricingReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("主分布 · 使用短腿本地 IV") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RISK_NEUTRAL · 风险中性测度 Q · 不是历史频率或真实世界概率")
                        .font(.headline).foregroundStyle(.orange).accessibilityIdentifier("optionLabDistributionMeasure")
                    Text("状态：" + pricingState(pricing.distributionState)).accessibilityIdentifier("optionLabDistributionStatus")
                    if let distribution = pricing.distribution {
                        distributionReport(distribution, sensitivity: false)
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
                        if let sensitivity = pricing.longLegSensitivity { distributionReport(sensitivity, sensitivity: true) }
                        else { Text("长腿对照不可用；没有填入替代波动率。").foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("optionLabLongIVSensitivity")
            }
        }
    }
    private func distributionReport(_ distribution: OptionLabDistributionReport, sensitivity: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("σ 来源合约：\(distribution.volatilitySourceContractID) · 本地 IV \(pricingNumber(distribution.volatility * 100, suffix: "%"))")
                .font(.callout).textSelection(.enabled)
            Text("\(pricingNumber(distribution.confidence * 100, suffix: "%")) 尾部口径：取最差 \(pricingNumber(distribution.tailMass * 100, suffix: "%")) 的到期净损益；不是统计置信区间。")
                .font(.caption).foregroundStyle(.secondary)
            distributionOutcome(distribution.mid, title: "Mid 损益", id: sensitivity ? "optionLabSensitivityMid" : "optionLabDistributionMid")
            distributionOutcome(distribution.conservative, title: "保守成交损益", id: sensitivity ? "optionLabSensitivityConservative" : "optionLabDistributionConservative")
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
                Text(fundingName(value.funding)).foregroundStyle(value.canFund ? Color.secondary : Color.red)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading, spacing: 14) {
                    metric("净权利金 USD", value.netCreditTotal, id: value.pricing == .conservative ? "optionLabNetCredit" : "optionLabMidCredit")
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
        let points = [("Mid", report.mid.points), ("保守", report.conservative.points)].flatMap { name, values in
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
            Text("资金性质：\(report.input.capital.origin.rawValue) · \(report.input.capital.reference)")
            Text("成交前现金 \(report.input.capital.cashBeforeTrade.decimalString) · 已承诺现金 \(report.input.capital.committedCash.decimalString) · 股数 \(report.input.capital.availableShares.decimalString) · 已承诺股数 \(report.input.capital.committedShares.decimalString)")
            Text("λ \(report.input.policy.lambda.decimalString) · 每张每腿费用 \(report.input.policy.openingFeePerContract.decimalString) · 固定费 \(report.input.policy.ticketFee.decimalString) · 到期总费 \(report.input.policy.terminalFeeTotal.decimalString)")
            Text("标的 Bid/Ask：\(report.input.underlying.bid.decimalString) / \(report.input.underlying.ask.decimalString)")
            ForEach([report.input.shortLeg] + (report.input.longLeg.map { [$0] } ?? []), id: \.contractID) { leg in
                Text("\(leg.contractID) · \(leg.right.rawValue) \(leg.strike.decimalString) × \(leg.multiplier) × \(leg.quantity) · Bid/Ask \(leg.bid.decimalString)/\(leg.ask.decimalString) · 数量 \(leg.bidSize)/\(leg.askSize) · tick \(leg.tick?.decimalString ?? "缺失") · 报价 \(leg.quotedAt.formatted(.iso8601)) · 接收 \(leg.receivedAt.formatted(.iso8601))")
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
        var value = OptionLabInputDraft(input: report.input)
        if let basis = model.reportLedgerBasis { try? value.useLedgerBasis(basis) }
        draft = value; model.draftChanged(); section = "输入"
    }
    private func calculate() {
        do {
            let captured = draft, session = visibleSession, navigation = navigationEpoch
            let input = try captured.build(), basis = captured.ledgerBasis
            inputError = nil
            Task {
                guard visibleSession == session, draft == captured, navigationEpoch == navigation else { return }
                await model.calculate(input, ledgerBasis: basis)
                guard visibleSession == session, draft == captured, navigationEpoch == navigation,
                      model.report?.input.id == input.id else { return }
                section = "结果"
            }
        } catch {
            inputError = "请补齐输入：金额和 r/q/σ 用十进制，张数用整数，时间含明确时区；启用项须有来源，模型 r/q/σ 与情景轴不得空白。邻点、日历和跨式按列格式填写，未知证据留空。账本依据须与标的和评估时刻一致。"
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
            || input.expiry.source.origin == .synthetic || input.capital.origin == .synthetic
        let pricingSynthetic: Bool = input.pricing?.source.origin == .synthetic
        let riskSynthetic: Bool = input.risk?.containsSyntheticInput == true
        let scenarioSynthetic: Bool = input.scenario?.source.origin == .synthetic
        return primarySynthetic || contractSynthetic || pricingSynthetic || riskSynthetic || scenarioSynthetic
    }
    private func strategyName(_ strategy: OptionLabStrategy) -> String {
        switch strategy { case .cashSecuredPut: "现金担保卖 Put"; case .coveredCall: "备兑 Call"; case .putCreditSpread: "Put 信用价差"; case .callCreditSpread: "Call 信用价差" }
    }
    private func fundingName(_ funding: OptionLabFunding) -> String {
        switch funding { case .sufficient: "满足本次输入的资金约束；不等于券商准入"; case .insufficientCash: "成交前未承诺现金不足"; case .insufficientShares: "可覆盖持股不足" }
    }
    private func gapName(_ gap: OptionLabLedgerGap) -> String {
        switch gap {
        case .noAccountHistory: "账户没有交易历史"; case .completenessNotConfirmed: "未确认完整性"
        case .shortEquityNeedsMarginEvidence: "空头股票需要额外保证金依据"; case .uncoveredExistingCall: "现有空 Call 未完全覆盖"
        case .existingCashCommitmentsExceedBalance: "现有现金义务超过余额"; case .negativeCash: "现金为负"
        }
    }
}
