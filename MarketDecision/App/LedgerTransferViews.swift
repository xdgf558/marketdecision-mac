import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import Persistence

private struct LedgerExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .commaSeparatedText, .plainText] }
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
struct LedgerTransferContent: View {
    @Bindable var model: LedgerTransferModel
    let reportID: UUID?
    @State private var kind = LedgerExportKind.backup
    @State private var mode = LedgerRestoreMode.merge
    @State private var capturedMode = LedgerRestoreMode.merge
    @State private var confirmation = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var exportFile: LedgerExportFile?
    @State private var exportName = "ledger-backup.zip"
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
                Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("ledgerArchiveMessage")
            }
            if model.isBusy { ProgressView("正在校验账本与冻结收益记录…") }
            conflictSection
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
                    try await ResearchSelectedFile.read(url, maximumBytes: LedgerArchiveCodec.maximumArchiveBytes)
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
                Text("账本与收益数据管理").font(.title2.bold())
                Spacer()
                Button("刷新元数据") { run { await model.load() } }.disabled(busy).accessibilityIdentifier("ledgerArchiveReload")
            }
            Text("独立于研究归档。备份包含本地全部账本账户、原始批次/来源、事件与冻结收益输入；API Key、研究库和外部文件不在操作范围内。").foregroundStyle(.secondary)
            if let value = model.status {
                Text(counts(value.counts)).font(.callout).accessibilityIdentifier("ledgerArchiveCounts")
                Text("账本 \(value.ledgerRevision.uuidString) · 收益 \(value.performanceRevision.uuidString)").font(.caption).textSelection(.enabled)
            } else { Text("尚无可确认的元数据；损坏记录不会被静默当作空账本。").foregroundStyle(.secondary) }
        }
    }
    private var exportSection: some View {
        GroupBox("导出报告或独立备份") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("格式与用途", selection: $kind) { ForEach(LedgerExportKind.allCases, id: \.self) { Text(exportTitle($0)).tag($0) } }
                Text("CSV / Markdown 是可读报告，保留费用、来源及口径，不可导回作为交易或备份。收益报告只导出当前已打开、经过复算的冻结版本。").font(.caption).foregroundStyle(.secondary)
                if kind.requiresReport && reportID == nil { Text("请先在“组合收益”打开并核对一份冻结报告，再从该页进入此分区导出。").foregroundStyle(.orange) }
                Text("普通 ZIP 未加密，可能含账户、持仓及原始来源文本；请选择你控制的本地位置。体积限制不等于进程内存上限。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("生成并选择保存位置…") { beginExport() }
                        .disabled(busy || (kind.requiresReport && reportID == nil)).accessibilityIdentifier("ledgerArchiveExport")
                    if fileFlow.isBusy { Button("取消文件操作") { finish(.cancelled, fileFlow.id) } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private var restoreSection: some View {
        GroupBox("从账本备份恢复") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("恢复方式", selection: $mode) {
                    Text("合并 · 严格检查身份与经济内容").tag(LedgerRestoreMode.merge)
                    Text("替换 · 仅替换账本与收益").tag(LedgerRestoreMode.replace)
                    Text("隔离保留冲突原包 · 不加入活动账本").tag(LedgerRestoreMode.retainConflict)
                }.pickerStyle(.radioGroup).disabled(busy)
                Text("先校验完整包并显示预检摘要，再明确确认。合并冲突不会自动覆盖或丢弃；可取消后选择隔离保留原包。替换能修复可替换内容的损坏，但仍要求有效元数据和有效备份。").font(.caption).foregroundStyle(.secondary)
                Button("选择账本备份并预检…") {
                    guard model.canPrepare, !fileFlow.isBusy, fileFlow.begin() != nil else { return }
                    capturedMode = mode; importing = true
                }.disabled(!model.canPrepare || fileFlow.isBusy).accessibilityIdentifier("ledgerArchiveImport")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private var conflictSection: some View {
        GroupBox("隔离保留的冲突原包") {
            VStack(alignment: .leading, spacing: 9) {
                if let error = model.conflictError { Text(error).foregroundStyle(.red) }
                if model.conflicts.isEmpty && model.conflictError == nil { Text("当前没有已读取的隔离包。").foregroundStyle(.secondary) }
                ForEach(model.conflicts) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(item.id.uuidString) · \(counts(item.counts))").font(.callout)
                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        Text("源哈希 \(item.sourceHash)").font(.caption.monospaced()).textSelection(.enabled)
                        Button("重新导出这份原包…") { beginExport(conflict: item.id) }.disabled(busy)
                    }
                }
                Text("隔离包不参与现金、持仓或收益计算；这里不自动消解身份冲突。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private var clearSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button("预检清空账本与收益…", role: .destructive) { run { await model.prepareClear() } }
                .disabled(!model.canPrepare || fileFlow.isBusy).accessibilityIdentifier("ledgerArchiveClearPreview")
            Text("清空范围以预检摘要为准。只影响独立账本与收益库，研究归档、行情/SEC 来源库、设置、Keychain 和外部备份不变；不是磁盘物理擦除。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func confirmationSheet(_ plan: LedgerTransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.operation == .clear ? "确认清空账本与收益" : "确认账本恢复计划").font(.title2.bold())
            Text("原有：\(counts(plan.previous))\n结果：\(counts(plan.result))")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { ForEach(Array(plan.details.enumerated()), id: \.offset) { Text($0.element) } }
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: 180)
            Text("批准固定计划 ID、包摘要及账本/收益双版本；数据变化后必须重新预检。关闭页面不会撤销已发起的事务。").font(.caption).foregroundStyle(.secondary)
            if !plan.canCommit { Text("此计划不可提交，请取消并处理冲突。").foregroundStyle(.orange) }
            TextField("输入“确认”后提交", text: $confirmation).onSubmit { }.textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ledgerArchiveConfirmText")
            if let message = model.message { Text(message).font(.callout) }
            HStack {
                Button("取消") { Task { if model.plan?.id == plan.id { await model.cancel() } } }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy).accessibilityIdentifier("ledgerArchiveCancel")
                Spacer()
                Button("执行已确认计划", role: .destructive) { Task { _ = await model.confirm(.init(plan: plan)) } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(confirmation != "确认" || !model.canConfirm || model.plan?.id != plan.id)
                    .accessibilityIdentifier("ledgerArchiveCommit")
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
    private func beginExport(conflict: UUID? = nil) {
        guard visible, !busy, let request = fileFlow.begin() else { return }
        let chosen = kind, frozenID = reportID
        task = Task {
            guard current(request), !Task.isCancelled else { return }
            let payload: LedgerExportPayload?
            if let conflict { payload = await model.exportConflict(conflict) }
            else { payload = await model.export(chosen, reportID: frozenID) }
            guard current(request), !Task.isCancelled else { return }
            guard let payload else { endFile(request); return }
            exportFile = LedgerExportFile(payload.bytes); exportName = payload.filename
            exportType = payload.contentType.contains("zip") ? .zip : payload.contentType.contains("csv") ? .commaSeparatedText : .plainText
            task = nil; exporting = true
        }
    }
}
private func counts(_ value: LedgerArchiveCounts) -> String {
    "账户 \(value.accounts) · 事件 \(value.events) · 批次 \(value.batches) · 收益报告 \(value.reports) · 隔离包 \(value.conflicts)"
}
private func exportTitle(_ kind: LedgerExportKind) -> String {
    switch kind {
    case .backup: "账本与收益备份 · 普通 ZIP"
    case .transactions: "交易与费用来源 · CSV"
    case .positions: "当前持仓与批次 · CSV"
    case .realizations: "已实现明细 · CSV"
    case .cash: "账户现金 · CSV"
    case .daily: "冻结收益逐日 NAV · CSV"
    case .performancePositions: "冻结估值持仓 · CSV"
    case .sources: "冻结收益来源证据 · CSV"
    case .metrics: "冻结收益指标 · CSV"
    case .monthlyCSV: "冻结月收益 · CSV"
    case .monthlyMarkdown: "冻结月收益 · Markdown"
    }
}
