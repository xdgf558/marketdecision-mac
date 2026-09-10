import SwiftUI
import AppKit
import AppComposition
import DataContracts

enum AppPage: String, CaseIterable, Identifiable {
    case workspace = "工作台", settings = "设置"
    var id: Self { self }
    var symbol: String { self == .workspace ? "house.fill" : "gearshape" }
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
                    .accessibilityIdentifier(item == .workspace ? "pageWorkspace" : "pageSettings")
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
            Section { Text("数据默认保存在本机。当前不会调用付费 API。") }
        }
        .formStyle(.grouped).navigationTitle("设置")
        .task { await model.refresh() }
    }
}

struct CredentialSettingsSection: View {
    @Bindable var model: CredentialSettingsModel
    @State private var draft = ""
    @State private var flow = CredentialInteractionFlow()
    private enum Control: Hashable { case input, save, delete, check }
    @FocusState private var focusedControl: Control?
    @Environment(\.scenePhase) private var scenePhase
    private var canSave: Bool {
        !model.isBusy && model.presence != .unknown && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Section("服务凭据") {
            LabeledContent("本机状态", value: model.presence == .saved ? "已保存" : model.presence == .absent ? "未保存" : "待检查")
                .accessibilityIdentifier("credentialPresence")
            Text("预留的数据服务凭据，仅存入本机钥匙串，不会显示已保存的内容。保存不代表已连接或验证服务。")
                .foregroundStyle(.secondary)
            SecureField(model.presence == .saved ? "输入新凭据以替换" : "输入凭据", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("credentialInput")
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
                    .accessibilityIdentifier("credentialSave")
                Button("删除凭据…", role: .destructive) { requestDelete() }
                    .focusable(model.presence == .saved && !model.isBusy)
                    .focused($focusedControl, equals: .delete)
                    .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                        requestDelete(); return .handled
                    }
                    .disabled(model.isBusy || model.presence != .saved)
                    .help("删除凭据（⇧⌘⌫），仍需确认")
                    .accessibilityIdentifier("credentialDelete")
                Spacer()
                Button("检查状态") { checkStatus() }
                    .focusable(!model.isBusy)
                    .focused($focusedControl, equals: .check)
                    .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                        checkStatus(); return .handled
                    }
                    .disabled(model.isBusy)
                    .help("检查钥匙串状态（⇧⌘R）")
                    .accessibilityIdentifier("credentialCheck")
            }
            if let confirmationNotice = flow.confirmationNotice { Text(confirmationNotice).foregroundStyle(.secondary) }
            if model.isBusy { ProgressView("正在访问钥匙串…").controlSize(.small) }
            if let message = model.message {
                Label(message, systemImage: model.hasError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("credentialMessage")
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
