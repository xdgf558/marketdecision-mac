import SwiftUI
import AppKit
import AppComposition
import CoreDomain
import DataContracts
import AIInsights

enum AppPage: String, CaseIterable, Identifiable {
    case investments = "我的投资", options = "期权交易", stocks = "股票分析", settings = "设置"
    var id: Self { self }
    static var daily: [Self] { [.investments, .options, .stocks] }
    var shortcut: KeyEquivalent {
        switch self { case .investments: "1"; case .options: "2"; case .stocks: "3"; case .settings: "," }
    }
    var accessibilityID: String {
        switch self { case .investments: "pageInvestments"; case .options: "pageOptions"; case .stocks: "pageStocks"; case .settings: "pageSettings" }
    }
}

@main enum MarketDecisionEntry {
    @MainActor static func main() async {
        #if DEBUG && !UI_TEST_HOST
        if CommandLine.arguments.contains("--keychain-diagnostic") {
            exit(await KeychainDiagnostic.run(CommandLine.arguments))
        }
        #endif
        MarketDecisionApp.main()
    }
}

struct MarketDecisionApp: App {
    @State private var model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    init() {
        AIModelConfiguration.migrateStoredModel(in: .standard)
        #if UI_TEST_HOST
        // A separate test-only target. Shipping Debug/Release never select this factory.
        _model = State(initialValue: WorkspaceModel(prepareEnvironment: NativeUITestEnvironment.prepare))
        #else
        _model = State(initialValue: WorkspaceModel())
        #endif
    }
    var body: some Scene {
        WindowGroup("MarketDecision") {
            RootView(model: model)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .defaultSize(width: 1392, height: 944)
        .windowStyle(.hiddenTitleBar)
        .commands { CredentialMenuCommands() }
        Settings {
            SettingsContent(model: model).frame(width: 650, height: 620)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

struct RootView: View {
    @Bindable var model: WorkspaceModel
    @State private var page: AppPage = .investments
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.38, green: 0.78, blue: 0.72) : Color(red: 0.06, green: 0.43, blue: 0.41) }
    private var surface: Color { colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.985, green: 0.985, blue: 0.972) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Text("投资手账").font(.system(size: 19, weight: .semibold))
                    .frame(width: 150, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 30) {
                    ForEach(AppPage.daily) { item in
                        Button { page = item } label: {
                            Text(item.rawValue)
                                .font(.system(size: 16, weight: page == item ? .semibold : .medium))
                                .padding(.vertical, page == .stocks || page == .options || page == .investments ? 12 : 23).padding(.horizontal, 9)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    if page == item { Rectangle().fill(accent).frame(height: 3) }
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(page == item ? accent : Color.primary)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                        .keyboardShortcut(item.shortcut, modifiers: .command)
                        .accessibilityIdentifier(item.accessibilityID)
                    }
                }
                Spacer(minLength: 0)
                Button { page = .settings } label: {
                    Label("设置", systemImage: "gearshape").font(.system(size: 15))
                        .padding(.vertical, 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(page == .settings ? accent : Color.secondary)
                .accessibilityAddTraits(page == .settings ? .isSelected : [])
                // Command-comma belongs to the independent native Settings scene.
                .accessibilityIdentifier("pageSettings")
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 32).padding(.top, page == .stocks || page == .options || page == .investments ? 6 : 17)
            Divider()
            Group {
                if page != .settings, !model.isPrepared, let error = model.initializationError {
                    VStack(spacing: 16) {
                        ContentUnavailableView("本地数据暂不可用", systemImage: "externaldrive.badge.exclamationmark", description: Text(error))
                        Button("重试打开本地数据") { Task { await model.refresh() } }
                            .disabled(model.isLoading).accessibilityIdentifier("dailyWorkspaceRetry")
                    }
                } else {
                    switch page {
                    case .investments: InvestmentsPage(workspace: model)
                    case .options: OptionLabPage(workspace: model)
                    case .stocks: StockAnalysisPage(workspace: model)
                    case .settings: SettingsHub(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent).background(surface)
        .frame(minWidth: 900, minHeight: 620)
        .task { await model.refresh() }
    }
}

/// Infrequent research/diagnostic tools remain reachable without occupying daily navigation.
private struct SettingsHub: View {
    @Bindable var model: WorkspaceModel
    @State private var advanced = false
    @State private var tool: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tool {
                Button { self.tool = nil } label: { Label("返回设置", systemImage: "chevron.left") }
                    .buttonStyle(.plain).padding(.horizontal, 32).padding(.top, 20)
                    .accessibilityIdentifier("settingsBack")
                if tool == "market" { MarketStatePage(workspace: model) }
                else { WorkspaceContent(model: model) }
            } else {
                SettingsContent(model: model)
                VStack(alignment: .leading, spacing: 14) {
                    Button { advanced.toggle() } label: {
                        Label("高级工具", systemImage: advanced ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).accessibilityIdentifier("settingsAdvancedTools")
                    if advanced {
                        HStack(spacing: 24) {
                            Button("市场与数据") { tool = "market" }.accessibilityIdentifier("settingsOpenMarket")
                            Button("合成演示与诊断") { tool = "demo" }.accessibilityIdentifier("settingsOpenDemo")
                        }.buttonStyle(.bordered)
                        Text("来源、修订和研究工具按需使用，不影响三个日常入口。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 32).padding(.bottom, 24)
            }
        }
    }
}

struct WorkspaceContent: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("工作台").font(.system(size: 48, weight: .bold))
                    Text("本地演示").font(.system(size: 26)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button { Task { await model.refresh() } } label: {
                    Label(model.isLoading ? "正在刷新" : "刷新演示", systemImage: "arrow.clockwise")
                        .font(.system(size: 18, weight: .medium)).padding(.vertical, 8).padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.blue.opacity(model.isLoading ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
                .disabled(model.isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("refreshDemo")
            }
            Divider()
            Label { Text("合成示例，非真实行情。") } icon: { Image(systemName: "info.circle.fill").foregroundStyle(.blue) }
                .font(.system(size: 22, weight: .medium)).foregroundStyle(Color.primary)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.18)))
            VStack(spacing: 2) {
                quoteRow(name: "名称", bid: "买价 (Bid)", ask: "卖价 (Ask)", state: "数据状态", header: true)
                if let quote = model.quote {
                    quoteRow(name: quote.symbol, bid: display(quote.bid), ask: display(quote.ask), state: "演示数据", header: false)
                } else {
                    Text(model.isLoading ? "正在载入演示数据…" : "暂无演示数据")
                        .foregroundStyle(.secondary).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("尚未连接数据服务。", systemImage: "info.circle.fill").foregroundStyle(.secondary)
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("refreshStatus") }
            }.font(.system(size: 20))
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 30)
    }
    func quoteRow(name: String, bid: String, ask: String, state: String, header: Bool) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Text(name).frame(width: geometry.size.width * 0.30, alignment: .leading)
                Text(bid).monospacedDigit().frame(width: geometry.size.width * 0.27, alignment: .leading)
                Text(ask).monospacedDigit().frame(width: geometry.size.width * 0.215, alignment: .leading)
                Group {
                    if header { Text(state) }
                    else { HStack(spacing: 10) { Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(.blue).accessibilityHidden(true); Text(state) } }
                }.frame(width: geometry.size.width * 0.215, alignment: .leading)
            }
            .font(.system(size: header ? 18 : 22, weight: header ? .medium : .regular))
            .foregroundStyle(header ? Color.secondary : Color.primary)
        }
        .frame(height: header ? 24 : 28)
        .padding(.horizontal, 20).padding(.vertical, header ? 16 : 20)
        .background(header ? Color.primary.opacity(0.045) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(header ? Color.clear : Color.primary.opacity(0.09)))
    }
    /// Quote text follows the same locale-independent fixed-scale policy as the
    /// calculation layer. A valid Money value always has a canonical fallback.
    private func display(_ value: CoreDomain.Money) -> String {
        (try? value.fixedString(at: .accounting)) ?? value.decimalString
    }
}

struct SettingsContent: View {
    @Bindable var model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var connectionMessage: String?
    @State private var showsAISettings = false
    var body: some View {
        Form {
            AppReleaseNotesSection()
            Section("外观") {
                Picker("显示模式", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .accessibilityIdentifier("appearanceMode")
            }
            Section("数据服务") {
                LabeledContent("数据模式", value: "合成演示")
                Text("演示数据不会用于真实分析，尚未连接真实数据源。")
                    .foregroundStyle(.secondary)
                Button("测试演示连接") {
                    Task { let succeeded = await model.refresh(); connectionMessage = succeeded ? "演示连接正常；未访问真实数据服务。" : "演示连接失败，请重试。" }
                }.disabled(model.isLoading || model.isPreparing || model.credentials == nil)
                if let connectionMessage { Text(connectionMessage).foregroundStyle(.secondary) }
            }
            if let credentials = model.credentials {
                CredentialSettingsSection(model: credentials)
            } else {
                Section("服务凭据") {
                    if let error = model.initializationError {
                        Text(error).foregroundStyle(.red)
                        Button("重试初始化") { Task { await model.refresh() } }
                            .disabled(model.isPreparing)
                    } else { ProgressView("正在准备本地服务…") }
                }
            }
            if let aiCredentials = model.aiCredentials {
                Section("AI 财报解读") {
                    Text("在股票分析页手动发送当前公司的财报摘要。API 使用你的 OpenAI 账户计费。")
                        .foregroundStyle(.secondary)
                    Button("AI 设置…") { showsAISettings = true }
                        .sheet(isPresented: $showsAISettings) { AISettingsView(credentials: aiCredentials) }
                }
            }
            Section { Text("数据默认保存在本机。AI 解读仅在你点击时发送摘要，不会自动调用。") }
        }
        .formStyle(.grouped).navigationTitle("设置")
        .task { await model.refresh() }
    }
}

private struct AppReleaseNotesSection: View {
    @State private var showsReleaseNotes = false

    // Read the running bundle, including when hosted outside the production app.
    // A missing value must not borrow the version of another build or target.
    private func bundleValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未标注"
        }
        return value
    }

    var body: some View {
        Section("关于投资手账") {
            LabeledContent("应用版本") {
                Text("\(bundleValue("CFBundleShortVersionString"))（构建 \(bundleValue("CFBundleVersion"))）")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settingsAppVersion")
            }
            DisclosureGroup("更新说明", isExpanded: $showsReleaseNotes) {
                VStack(alignment: .leading, spacing: 8) {
                    // Content date only; do not present this as the build date.
                    Text("版本 \(bundleValue("CFBundleShortVersionString")) · 2026-10-26")
                        .font(.caption).foregroundStyle(.secondary)
                    note("修复分享加载停留", "分享时连续完成报告生成、账本核对和卡片展示，避免一直停留在“正在核对分享数据”。")
                    note("核对失败可重试", "未完成核对时显示说明并提供重试；账户和版本校验保留，关闭后不发布旧结果。")
                    note("收益分享新布局", "紧凑左右布局搭配深绿色金币卡片，点击分享直接进入预览，支持近一年、近一季度与近一月切换。")
                    note("分享金额可隐藏", "总额与交易盈亏、股息利息、独立费用税款一起隐藏；仅分享已入账收益，保留统计时刻，不把持仓浮盈计入。")
                    note("保存分享图片", "支持保存 PNG，也可复制后在 X 手动粘贴发布；保存与预览使用同一卡片，不自动上传。")
                    note("区间报告可以分享", "近一年、近一季度和近一个月的已入账收益可生成分享卡片，金额默认隐藏；开仓权利金不直接算利润，完整估值报告仍单独核对。")
                    note("价差张数保持一致", "修复简化测算、开仓草稿和进阶输入之间的价差张数同步，两腿按同一张数带入；实际成交记录仍可逐腿编辑并核对张数。")
                    note("合约条款自动整理", "日常开仓无需手填合约条款，软件按标准参数自动整理或复用同账户已有合约；成交时间、张数、权利金、费用及确认仍保留，不会按到期日自动确认收益。")
                    note("开仓填写更简洁", "来源、成交编号和记录依据改为选填并默认折叠，留空时由软件生成内部记录编号；实际成交时间、价格、费用和合约仍需核对。")
                    note("开仓信息更明确", "实际成交录入明确标为“开仓权利金单价”和“开仓成交时间”，便于核对开仓记录。")
                    note("测算与实际交易分开", "保存测算明确标为不入账；实际成交后确认开仓，平仓或确认到期结清后才汇总盈亏，不按日期自动计收入。")
                    note("持仓直接处理", "期权交易和我的投资共用持仓处理入口，明确区分平仓与到期，并显示本次已实现盈亏；自动带入原账户、合约和批次，同一窗口记住账户选择。")
                    note("减少重复填写", "实际价格与测算相同时可明确点击带入，同账户已有合约自动核对复用；实际费用和时间仍需核对。编辑与最终确认分步显示，布局更紧凑。")
                    note("一键区间报告", "我的投资一次生成近一年、近三个月和近一个月的已入账收益报告，无需另选日期；未实现盈亏与完整估值报告仍分开。")
                    DisclosureGroup("近期更新") {
                        VStack(alignment: .leading, spacing: 8) {
                            note("期权页面更紧凑", "常规窗口下合约采用两行四列输入，持股成本对照并排展示；主要操作固定在输入页底部，进阶内容默认折叠。")
                            note("备兑持股成本", "备兑 Call 可选填平均持股成本，另列成本口径最大收益、最大亏损和盈亏平衡价；净权利金单独展示。成本随计算保存并在重开时核对，编辑后旧结果失效，不改账本成本。")
                            note("简化期权输入", "填写主要合约参数即可测算；Bid／Ask、资金及模型资料收进进阶研究。未核对资金与持股时明确提示，缺少数据不生成概率；到期时间使用美东时间。")
                            note("投资与成交", "紧凑概览展示累计盈亏、标的贡献和持仓；确认期权实际成交后自动记账，支持一笔平仓选择多个同合约批次。")
                            note("紧凑股票概览", "默认显示单季度并支持 TTM 切换，标明期间与缺项；首页优先呈现财务数据和 AI 结论，完整解读收进详情。")
                            note("情景估值", "参考股价与已确认股数用于本地倍数计算；AI 提出三档市销率假设，你确认后本地计算价格。资料或报告变更后清除旧结果，缺项不编造。")
                            note("AI 解读与离线工具", "修复回答结构和引用兼容问题，保留财务与来源校验并显示具体错误，不自动重发；SEC 工作区不可用时仍可进入独立离线工具。")
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("settingsReleaseNotes")
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        (Text("\(title)：").fontWeight(.medium) + Text(detail))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CredentialSettingsSection: View {
    @Bindable var model: CredentialSettingsModel
    var title = "服务凭据"
    var explanation = "预留的数据服务凭据，仅存入本机钥匙串，不会显示已保存的内容。保存不代表已连接或验证服务。"
    var identifierPrefix = "credential"
    @State private var draft = ""
    @State private var flow = CredentialInteractionFlow()
    private enum Control: Hashable { case input, save, delete, check }
    @FocusState private var focusedControl: Control?
    @Environment(\.scenePhase) private var scenePhase
    private var canSave: Bool {
        !model.isBusy && model.presence != .unknown && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Section(title) {
            LabeledContent("本机状态", value: model.presence == .saved ? "已保存" : model.presence == .absent ? "未保存" : "待检查")
                .accessibilityIdentifier(identifierPrefix + "Presence")
            Text(explanation)
                .foregroundStyle(.secondary)
            SecureField(model.presence == .saved ? "输入新凭据以替换" : "输入凭据", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifierPrefix + "Input")
                .accessibilityLabel(model.presence == .saved ? "输入新凭据以替换" : "输入凭据")
                .accessibilityHint("安全文本，不显示已保存的凭据。按 Command S 保存或打开替换确认；回车不保存。")
                .focused($focusedControl, equals: .input)
                .onSubmit(ignoreCredentialTextSubmission)
                .disabled(model.isBusy || model.presence == .unknown)
            HStack {
                Button(model.presence == .saved ? "替换凭据…" : "保存凭据") {
                    requestSave()
                }
                    .focusable(canSave)
                    .focused($focusedControl, equals: .save)
                    .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                        requestSave(); return .handled
                    }
                    .disabled(!canSave)
                    .help(model.presence == .saved ? "替换凭据（⌘S），仍需确认" : "保存凭据（⌘S）")
                    .accessibilityIdentifier(identifierPrefix + "Save")
                Button("删除凭据…", role: .destructive) { requestDelete() }
                    .focusable(model.presence == .saved && !model.isBusy)
                    .focused($focusedControl, equals: .delete)
                    .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                        requestDelete(); return .handled
                    }
                    .disabled(model.isBusy || model.presence != .saved)
                    .help("删除凭据（⇧⌘⌫），仍需确认")
                    .accessibilityIdentifier(identifierPrefix + "Delete")
                Spacer()
                Button("检查状态") { checkStatus() }
                    .focusable(!model.isBusy)
                    .focused($focusedControl, equals: .check)
                    .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                        checkStatus(); return .handled
                    }
                    .disabled(model.isBusy)
                    .help("检查钥匙串状态（⇧⌘R）")
                    .accessibilityIdentifier(identifierPrefix + "Check")
            }
            if let confirmationNotice = flow.confirmationNotice { Text(confirmationNotice).foregroundStyle(.secondary) }
            if model.isBusy { ProgressView("正在访问钥匙串…").controlSize(.small) }
            if let message = model.message {
                Label(message, systemImage: model.hasError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message)
                    .accessibilityIdentifier(identifierPrefix + "Message")
            }
        }
        .focusedSceneValue(\.credentialActions, CredentialSceneActions(
            saveTitle: model.presence == .saved ? "替换凭据…" : "保存凭据",
            canFocus: canUseInput && !confirmationOpen,
            canSave: canSave && !confirmationOpen,
            canDelete: model.presence == .saved && !model.isBusy && !confirmationOpen,
            canCheck: !model.isBusy && !confirmationOpen,
            focus: restoreInputFocus, save: requestSave,
            delete: requestDelete, check: checkStatus
        ))
        .onKeyPress(.tab, phases: .down) { press in
            guard let current = focusedControl, let index = focusOrder.firstIndex(of: current) else { return .ignored }
            let next = index + (press.modifiers.contains(.shift) ? -1 : 1)
            guard focusOrder.indices.contains(next) else { return .ignored }
            focusedControl = focusOrder[next]
            return .handled
        }
        .task { await model.refresh() }
        .onAppear { flow.appear() }
        .task(id: flow.focusRequest) {
            guard flow.focusRequest != nil else { return }
            await Task.yield()
            guard !Task.isCancelled, flow.isVisible, scenePhase == .active,
                  !confirmationOpen, focusOrder.contains(.input) else { return }
            focusedControl = .input
        }
        .onDisappear {
            flow.disappear()
            draft = ""
            cancelFocusRequest()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { draft = ""; flow.disappear(); cancelFocusRequest() }
            else { flow.appear() }
        }
        .background {
            CredentialConfirmationHost(confirmation: flow.confirmation, respond: respondToConfirmation)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: focusOrder) { _, order in
            if let current = focusedControl, !order.contains(current) { focusedControl = nil }
        }
        .onChange(of: model.revision) { _, revision in
            flow.invalidate(revision: revision)
        }
    }
    private var confirmationOpen: Bool { flow.confirmation != nil }
    private var canUseInput: Bool { !model.isBusy && model.presence != .unknown }
    private var focusOrder: [Control] {
        guard !model.isBusy else { return [] }
        var order: [Control] = canUseInput ? [.input] : []
        if canSave { order.append(.save) }
        if model.presence == .saved { order.append(.delete) }
        order.append(.check)
        return order
    }
    private func cancelFocusRequest() {
        flow.clearFocusRequest()
        focusedControl = nil
    }
    /// Return commits text or an input-method candidate. Persistence stays on
    /// the explicit button and Command-S paths.
    private func ignoreCredentialTextSubmission() {}
    private func restoreInputFocus() {
        guard scenePhase == .active else { return }
        focusedControl = nil
        flow.requestFocus()
    }
    private func respondToConfirmation(_ confirmation: CredentialInteractionFlow.Confirmation, confirmed: Bool) {
        guard let operation = flow.respond(to: confirmation.id, confirmed: confirmed, revision: model.revision) else { return }
        switch confirmation.action {
        case .delete:
            draft = ""
            Task {
                let deleted = await model.delete(expectedRevision: operation.revision)
                flow.completed(operation, succeeded: deleted)
            }
        case .replace:
            saveDraft(operation: operation)
        }
    }
    private func requestDelete() {
        guard !model.isBusy, model.presence == .saved, !confirmationOpen else { return }
        flow.present(.delete, revision: model.revision)
    }
    private func checkStatus() {
        guard !model.isBusy, !confirmationOpen, let operation = flow.begin(revision: model.revision) else { return }
        Task {
            let checked = await model.refresh()
            flow.completedCheck(operation, succeeded: checked)
        }
    }
    private func requestSave() {
        guard canSave, !confirmationOpen else { return }
        if model.presence == .saved {
            flow.present(.replace, revision: model.revision)
        } else if let operation = flow.begin(revision: model.revision) {
            saveDraft(operation: operation)
        }
    }
    private func saveDraft(operation: CredentialInteractionFlow.Operation) {
        guard canSave else { return }
        let value = draft
        draft = ""
        Task {
            let saved = await model.save(value, expectedRevision: operation.revision)
            flow.completed(operation, succeeded: saved)
        }
    }
}

/// A projection of flow.confirmation, with one terminal native-sheet response.
/// The coordinator retains only the rendered alert; it cannot authorize storage writes.
private struct CredentialConfirmationHost: NSViewRepresentable {
    let confirmation: CredentialInteractionFlow.Confirmation?
    let respond: (CredentialInteractionFlow.Confirmation, Bool) -> Void

    final class HostView: NSView {
        var windowChanged: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?() }
    }
    @MainActor final class Coordinator {
        var presentation: CredentialConfirmationHost
        private var rendered: (id: UUID, alert: NSAlert)?
        init(_ presentation: CredentialConfirmationHost) { self.presentation = presentation }
        func synchronize(in window: NSWindow?) {
            if let rendered, rendered.id != presentation.confirmation?.id || window == nil {
                dismiss()
            }
            guard rendered == nil, let window, let confirmation = presentation.confirmation else { return }
            let alert = NSAlert()
            let replacing = confirmation.action == .replace
            alert.messageText = replacing ? "替换本机凭据？" : "删除本机凭据？"
            alert.informativeText = replacing
                ? "原凭据将被覆盖，无法在本应用内恢复。按 Command-R 确认替换，Esc 取消。"
                : "删除后如需使用，必须重新输入凭据。按 Command-D 确认删除，Esc 取消。"
            let commit = alert.addButton(withTitle: replacing ? "替换" : "删除")
            commit.hasDestructiveAction = true
            commit.keyEquivalent = replacing ? "r" : "d"
            commit.keyEquivalentModifierMask = .command
            let cancel = alert.addButton(withTitle: "取消")
            cancel.keyEquivalent = "\u{1b}"
            cancel.keyEquivalentModifierMask = []
            // Return must never activate the destructive button.
            alert.window.defaultButtonCell = nil
            rendered = (confirmation.id, alert)
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.rendered?.id == confirmation.id else { return }
                self.rendered = nil
                self.presentation.respond(confirmation, response == .alertFirstButtonReturn)
            }
        }
        func dismiss() {
            guard let current = rendered else { return }
            let parent = current.alert.window.sheetParent
            // Capture the user's key window before endSheet can reactivate the
            // old parent. Never activate an application that is in the background.
            let keyWindowBeforeAbort = NSApp.isActive ? NSApp.keyWindow : nil
            // An abort only removes the native projection. Clearing rendered
            // first makes the completion a no-op, so it can never authorize a
            // save/delete. Flow invalidation or disappearance owns business state.
            rendered = nil
            parent?.endSheet(current.alert.window, returnCode: .abort)
            // Ending an old sheet can reactivate its parent on macOS 15. Preserve
            // the other window the user was working in; do not activate the app.
            if NSApp.isActive, let keyWindowBeforeAbort, keyWindowBeforeAbort !== parent,
               keyWindowBeforeAbort !== current.alert.window, keyWindowBeforeAbort.isVisible,
               !keyWindowBeforeAbort.isMiniaturized {
                keyWindowBeforeAbort.makeKeyAndOrderFront(nil)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        let coordinator = context.coordinator
        view.windowChanged = { [weak view, weak coordinator] in coordinator?.synchronize(in: view?.window) }
        return view
    }
    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.presentation = self
        context.coordinator.synchronize(in: view.window)
    }
    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.dismiss()
    }
}

@MainActor private struct CredentialSceneActions {
    let saveTitle: String
    let canFocus: Bool
    let canSave: Bool
    let canDelete: Bool
    let canCheck: Bool
    let focus: () -> Void
    let save: () -> Void
    let delete: () -> Void
    let check: () -> Void
}
private struct CredentialActionsKey: FocusedValueKey {
    typealias Value = CredentialSceneActions
}
private extension FocusedValues {
    var credentialActions: CredentialSceneActions? {
        get { self[CredentialActionsKey.self] }
        set { self[CredentialActionsKey.self] = newValue }
    }
}
private struct CredentialMenuCommands: Commands {
    @FocusedValue(\.credentialActions) private var actions
    var body: some Commands {
        CommandMenu("凭据") {
            Button("聚焦凭据输入") { actions?.focus() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(actions?.canFocus != true)
            Button(actions?.saveTitle ?? "保存凭据") { actions?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.canSave != true)
            Button("删除凭据…") { actions?.delete() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.canDelete != true)
            Divider()
            Button("检查钥匙串状态") { actions?.check() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canCheck != true)
        }
    }
}
