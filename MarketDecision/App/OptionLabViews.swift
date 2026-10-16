import SwiftUI
import Charts
import AppComposition
import CoreDomain
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
            Text("到期损益 · 手工假设或合成输入 · 不联网、不下单。资金检查是研究约束，不是券商购买力或交易许可。")
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("optionLabMessage") }
            if let inputError { Text(inputError).foregroundStyle(.red).accessibilityIdentifier("optionLabInputError") }
            Picker("实验室内容", selection: $section) {
                Text("输入").tag("输入"); Text("结果").tag("结果"); Text("已保存").tag("已保存")
            }.pickerStyle(.segmented).accessibilityIdentifier("optionLabSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if section == "输入" { editor }
                    else if section == "已保存" { history }
                    else if let report = model.report { result(report) }
                    else {
                        ContentUnavailableView("尚无已核对计算", systemImage: "chart.xyaxis.line",
                            description: Text("填写完整输入并计算，或显式载入合成模板。修改输入后，旧结果立即失效。"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
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
                    Text("从完整输入核对四种策略的到期损益").foregroundStyle(.secondary)
                }
                Spacer()
                if blocked { ProgressView().controlSize(.small) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading, spacing: 8) {
                Button("新建手工输入") { model.draftChanged(); draft = .init(); ledgerCandidate = nil; section = "输入" }.disabled(blocked).accessibilityIdentifier("optionLabNew")
                Button("载入合成模板") {
                    do { model.draftChanged(); draft = try .synthetic(strategy: draft.strategy); section = "输入" }
                    catch { inputError = "合成模板未能建立，没有填入替代值。" }
                }.disabled(blocked).accessibilityIdentifier("optionLabTemplate")
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
                        field("明确的到期时刻（含时区）", $draft.settlementAt)
                        field("报价来源／假设说明", $draft.sourceReference)
                        field("到期时刻依据", $draft.expiryReference)
                    }
                    Text("到期时刻必须明确输入。本批没有官方到期日历准入，不推定 16:00、不输出交易日 DTE。报价时效只校验所选离线场景，不表示这些数据是实时。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
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
                    Text("自然日 DTE \(report.dte) · ANN_v1 简单年化 · 不含提前指派、动态 Greeks 或获利概率。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !report.conservative.canFund || !report.mid.canFund {
                        Text("资金或覆盖持股不足：以下仅为损益研究，不能表示可执行策略。")
                            .foregroundStyle(.red).accessibilityIdentifier("optionLabFundingGap")
                    }
                    Button("复制为新草稿") {
                        var value = OptionLabInputDraft(input: report.input)
                        if let basis = model.reportLedgerBasis { try? value.useLedgerBasis(basis) }
                        draft = value; model.draftChanged(); section = "输入"
                    }.disabled(blocked).accessibilityIdentifier("optionLabCopy")
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
            inputError = "请填写所有必需字段；金额用十进制文本，张数用整数，时间须含明确时区。账本依据须与当前标的和评估时刻一致。"
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
        report.input.underlying.source.origin == .synthetic || report.input.shortLeg.source.origin == .synthetic
            || report.input.longLeg?.source.origin == .synthetic || report.input.expiry.source.origin == .synthetic
            || report.input.capital.origin == .synthetic
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
