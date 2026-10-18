import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import Persistence

private struct OptionArchiveExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .commaSeparatedText, .plainText] }
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
struct OptionArchiveTransferContent: View {
    @Bindable var model: OptionArchiveTransferModel
    @State private var mode = OptionLabRestoreMode.merge
    @State private var capturedMode = OptionLabRestoreMode.merge
    @State private var confirmation = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var exportFile: OptionArchiveExportFile?
    @State private var exportName = "options-backup.zip"
    @State private var exportType = UTType.zip
    @State private var fileFlow = ResearchFileRequestFlow()
    @State private var task: Task<Void, Never>?
    @State private var visible = false
    private var busy: Bool { model.isBusy || fileFlow.isBusy }
    var body: some View {
        let request = fileFlow.id, displayedPlanID = model.plan?.id
        VStack(alignment: .leading, spacing: 16) {
            heading
            exportSection
            restoreSection
            if let message = model.message {
                Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("optionArchiveMessage")
            }
            if model.isBusy { ProgressView("正在校验期权库报告与冻结证据…") }
            clearSection
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentTypes: [exportType], defaultFilename: exportName) { result in
            switch result { case .success: finish(.succeeded, request); case .failure: finish(.failed, request) }
        } onCancellation: { finish(.cancelled, request) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            guard current(request) else { return }
            guard case .success(let urls) = result, urls.count == 1, let url = urls.first else { finish(.failed, request); return }
            guard fileFlow.selectFile(for: request) else { return }
            let selectedMode = capturedMode
            task = Task {
                guard current(request), !Task.isCancelled else { return }
                await model.prepare(mode: selectedMode) {
                    try await ResearchSelectedFile.read(url, maximumBytes: OptionLabArchiveCodec.maximumArchiveBytes)
                }
                endFile(request)
            }
        } onCancellation: { finish(.cancelled, request) }
        .sheet(item: Binding(get: { model.plan }, set: { newValue in
            if newValue == nil, let displayedPlanID, model.plan?.id == displayedPlanID, !model.isBusy {
                Task { await model.cancel() }
            }
        })) { plan in confirmationSheet(plan) }
        .onChange(of: model.plan?.id) { _, _ in confirmation = "" }
        .onChange(of: model.transferEpoch) { _, _ in resetFileRequest() }
        .onAppear { visible = true }
        .task { await model.load() }
        .onDisappear { visible = false; resetFileRequest(); model.dismiss() }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("期权库导出与恢复").font(.title2.bold())
                Spacer()
                Button("刷新元数据") { run { await model.load() } }.disabled(busy).accessibilityIdentifier("optionArchiveReload")
            }
            Text("此归档包含期权实验、日摘要、历史分析、链采集、组合风险、数据对照和交易归因。研究库和实际账本库不被导出或恢复；包内可能含只读历史账户及事件依据。").foregroundStyle(.secondary)
            if let value = model.status {
                Text(counts(value.counts)).font(.callout).accessibilityIdentifier("optionArchiveCounts")
                Text("期权库版本 \(value.revision.uuidString)").font(.caption).textSelection(.enabled)
            } else { Text("尚无可确认的元数据；损坏记录不会被静默当作空期权库。").foregroundStyle(.secondary) }
        }
    }
    private var exportSection: some View {
        GroupBox("导出报告或独立备份") {
            VStack(alignment: .leading, spacing: 10) {
                Text("完整期权备份使用 ZIP。波动率页面导出的 CSV / Markdown 仅供阅读，不能恢复期权库。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("普通 ZIP 未加密；若实验关联过账本，会包含当时选定账户及历史事件。请选择你控制的位置。输入预算不等于进程内存上限。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("生成并选择保存位置…") { beginExport() }
                        .disabled(busy).accessibilityIdentifier("optionArchiveExport")
                    if fileFlow.isBusy { Button("取消文件操作") { finish(.cancelled, fileFlow.id) } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private var restoreSection: some View {
        GroupBox("从期权备份恢复") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("恢复方式", selection: $mode) {
                    Text("合并 · 严格检查身份与经济内容").tag(OptionLabRestoreMode.merge)
                    Text("替换 · 仅替换期权库").tag(OptionLabRestoreMode.replace)
                }.pickerStyle(.radioGroup).disabled(busy)
                Text("先校验完整包并显示预检摘要，再明确确认。同一标识但内容不同会拒绝合并，绝不静默覆盖。替换仍要求有效元数据与完整备份。").font(.caption).foregroundStyle(.secondary)
                Button("选择期权备份并预检…") {
                    guard model.canPrepare, !fileFlow.isBusy, fileFlow.begin() != nil else { return }
                    capturedMode = mode; importing = true
                }.disabled(!model.canPrepare || fileFlow.isBusy).accessibilityIdentifier("optionArchiveImport")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private var clearSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button("预检清空独立期权库…", role: .destructive) { run { await model.prepareClear() } }
                .disabled(!model.canPrepare || fileFlow.isBusy).accessibilityIdentifier("optionArchiveClearPreview")
            Text("清空范围包含预检列出的期权库全部类型；研究归档、实际账本库、行情/SEC 来源库、设置、Keychain 和外部备份不变；不是磁盘物理擦除。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func confirmationSheet(_ plan: OptionLabTransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.operation == .clear ? "确认清空期权实验、日摘要与历史报告" : "确认期权恢复计划").font(.title2.bold())
            Text("原有：\(counts(plan.previous))\n结果：\(counts(plan.result))")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { ForEach(Array(plan.details.enumerated()), id: \.offset) { Text($0.element) } }
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: 180)
            Text("批准固定计划 ID、包摘要及期权库版本；数据变化后必须重新预检。关闭页面不会撤销已发起的事务。").font(.caption).foregroundStyle(.secondary)
            if !plan.canCommit { Text("此计划不可提交，请取消并处理冲突。").foregroundStyle(.orange) }
            TextField("输入“确认”后提交", text: $confirmation).onSubmit { }.textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("optionArchiveConfirmText")
            if let message = model.message { Text(message).font(.callout) }
            HStack {
                Button("取消") { Task { if model.plan?.id == plan.id { await model.cancel() } } }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy).accessibilityIdentifier("optionArchiveCancel")
                Spacer()
                Button("执行已确认计划", role: .destructive) { Task { _ = await model.confirm(.init(plan: plan)) } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(confirmation != "确认" || !model.canConfirm || model.plan?.id != plan.id)
                    .accessibilityIdentifier("optionArchiveCommit")
            }
        // Keep identifiers on the actionable children: a container identifier propagates
        // to the sheet controls on macOS 15 and masks their distinct identities.
        }.padding(24).frame(width: 640)
    }
    private func current(_ request: UUID?) -> Bool { visible && fileFlow.owns(request) }
    private func resetFileRequest() {
        task?.cancel(); task = nil; fileFlow.dismiss(); exportFile = nil; exporting = false; importing = false; confirmation = ""
    }
    private func finish(_ outcome: ResearchFileRequestFlow.Outcome, _ request: UUID?) {
        let reading = fileFlow.isReading
        guard current(request), fileFlow.receive(outcome, for: request) else { return }
        switch outcome {
        case .succeeded: model.exported()
        case .failed: model.fileFailed()
        case .cancelled:
            task?.cancel()
            if reading || model.isBusy { model.cancelFileWork() }
            model.fileCancelled()
        }
        endFile(request)
    }
    private func endFile(_ request: UUID?) {
        guard current(request) else { return }
        fileFlow.finish(for: request); task = nil; exportFile = nil
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard visible, !fileFlow.isBusy else { return }
        fileFlow.dismiss()
        Task { guard visible else { return }; await action() }
    }
    private func beginExport() {
        guard visible, !busy, let request = fileFlow.begin() else { return }
        task = Task {
            guard current(request), !Task.isCancelled else { return }
            let payload = await model.export()
            guard current(request), !Task.isCancelled else { return }
            guard let payload else { endFile(request); return }
            exportFile = OptionArchiveExportFile(payload.bytes); exportName = payload.filename
            exportType = .zip; task = nil; exporting = true
        }
    }
}
private func counts(_ value: OptionLabArchiveCounts) -> String {
    "链采集 \(value.chainCaptures) · 实验 \(value.experiments) · 日摘要 \(value.dailySummaries) · 历史报告 \(value.historyReports) · 组合风险 \(value.portfolioReports) · 对照与归因 \(value.evidenceReports) · 嵌入账户依据 \(value.embeddedLedgerBases)"
}
