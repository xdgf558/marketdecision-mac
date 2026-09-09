import SwiftUI
import AppComposition
import DataContracts

@MainActor @Observable final class WorkspaceModel {
    private(set) var credentials: CredentialSettingsModel?
    var quote: Quote?
    var isLoading = false
    private(set) var isPreparing = false
    private(set) var initializationError: String?
    var message: String?
    private var environment: AppEnvironment?

    private func prepare() async {
        guard environment == nil, !isPreparing else { return }
        isPreparing = true
        initializationError = nil
        defer { isPreparing = false }
        do {
            let ready = try await Task.detached {
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("MarketDecision", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try AppEnvironment.mock(databasePath: folder.appendingPathComponent("foundation.sqlite").path)
            }.value
            environment = ready
            credentials = ready.makeCredentialSettings()
        } catch {
            initializationError = "本地数据暂时不可用，请重试。"
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await prepare()
        guard let environment else { message = initializationError; return }
        do {
            quote = try await environment.quotes.quote(for: "DEMO")
            message = "演示数据已刷新"
        } catch is CancellationError {
            message = "刷新已取消"
        } catch {
            message = "演示数据暂时不可用，请重试。"
        }
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case workspace = "工作台", settings = "设置"
    var id: Self { self }
    var symbol: String { self == .workspace ? "house.fill" : "gearshape" }
}

@main enum MarketDecisionEntry {
    @MainActor static func main() async {
        #if DEBUG
        if CommandLine.arguments.contains("--keychain-diagnostic") {
            exit(await KeychainDiagnostic.run(CommandLine.arguments))
        }
        #endif
        MarketDecisionApp.main()
    }
}

struct MarketDecisionApp: App {
    @State private var model = WorkspaceModel()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("MarketDecision") {
            RootView(model: model)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .defaultSize(width: 1392, height: 944)
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsContent(model: model).frame(width: 650, height: 620)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

struct RootView: View {
    @Bindable var model: WorkspaceModel
    @State private var page: AppPage = .workspace
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(AppPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(page == item ? Color.white : Color.primary)
                    .background(page == item ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .keyboardShortcut(item == .workspace ? "1" : "2", modifiers: .command)
                    .help(item == .workspace ? "工作台（⌘1）" : "设置（⌘2）")
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 40)
            .frame(width: 260)
            .background(.regularMaterial)
            Divider()
            Group {
                if page == .workspace { WorkspaceContent(model: model) }
                else { SettingsContent(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 620)
        .task { await model.refresh() }
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
                    quoteRow(name: quote.symbol, bid: quote.bid.amount.formatted(.number.precision(.fractionLength(2))), ask: quote.ask.amount.formatted(.number.precision(.fractionLength(2))), state: "演示数据", header: false)
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
}

struct SettingsContent: View {
    @Bindable var model: WorkspaceModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var connectionMessage: String?
    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            }
            Section("数据服务") {
                LabeledContent("数据模式", value: "合成演示")
                Text("演示数据不会用于真实分析，尚未连接真实数据源。")
                    .foregroundStyle(.secondary)
                Button("测试演示连接") {
                    Task { await model.refresh(); connectionMessage = model.quote == nil ? "演示连接失败，请重试。" : "演示连接正常；未访问真实数据服务。" }
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
            Section { Text("数据默认保存在本机。当前不会调用付费 API。") }
        }
        .formStyle(.grouped).navigationTitle("设置")
        .task { await model.refresh() }
    }
}

struct CredentialSettingsSection: View {
    @Bindable var model: CredentialSettingsModel
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var confirmReplace = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private var canSave: Bool {
        !model.isBusy && model.presence != .unknown && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Section("服务凭据") {
            LabeledContent("本机状态", value: model.presence == .saved ? "已保存" : model.presence == .absent ? "未保存" : "待检查")
            Text("预留的数据服务凭据，仅存入本机钥匙串，不会显示已保存的内容。保存不代表已连接或验证服务。")
                .foregroundStyle(.secondary)
            SecureField(model.presence == .saved ? "输入新凭据以替换" : "输入凭据", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("credentialInput")
                .accessibilityLabel(model.presence == .saved ? "输入新凭据以替换" : "输入凭据")
                .accessibilityHint("安全文本，不显示已保存的凭据。Command S 保存或打开替换确认。")
                .focused($inputFocused)
                .onSubmit { requestSave() }
                .disabled(model.isBusy || model.presence == .unknown)
            HStack {
                Button(model.presence == .saved ? "替换凭据…" : "保存凭据") {
                    requestSave()
                }.disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("保存或替换凭据（⌘S）")
                Button("删除凭据…", role: .destructive) { confirmDelete = true }
                    .disabled(model.isBusy || model.presence != .saved)
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .help("删除凭据（⇧⌘⌫），仍需确认")
                Spacer()
                Button("检查状态") { Task { await model.refresh() } }.disabled(model.isBusy)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("检查钥匙串状态（⇧⌘R）")
            }
            if model.isBusy { ProgressView("正在访问钥匙串…").controlSize(.small) }
            if let message = model.message {
                Label(message, systemImage: model.hasError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background {
            Button("聚焦凭据输入") { inputFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
        .task { await model.refresh() }
        .onDisappear { draft = "" }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { draft = ""; confirmReplace = false; confirmDelete = false }
        }
        .alert("替换本机凭据？", isPresented: $confirmReplace) {
            Button("取消", role: .cancel) {}
            Button("替换") { saveDraft() }.disabled(!canSave)
        } message: { Text("原凭据将被覆盖，无法在本应用内恢复。") }
        .alert("删除本机凭据？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { draft = ""; Task { await model.delete() } }
        } message: { Text("删除后如需使用，必须重新输入凭据。") }
    }
    private func requestSave() {
        guard canSave else { return }
        if model.presence == .saved { confirmReplace = true } else { saveDraft() }
    }
    private func saveDraft() {
        guard canSave else { return }
        let value = draft
        draft = ""
        Task { await model.save(value) }
    }
}
