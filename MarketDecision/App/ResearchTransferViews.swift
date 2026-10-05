import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import DataContracts
import Persistence
import FundamentalsEngine

private struct ResearchExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .plainText] }
    var bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:bytes) }
}
struct ResearchTransferContent: View {
    @Bindable var transfer: ResearchTransferModel
    @Bindable var research: ResearchWorkspaceModel
    @State private var exportFile: ResearchExportFile?
    @State private var exportName = "MarketDecision-research.zip"
    @State private var exportType = UTType.zip
    @State private var exporting = false
    @State private var importing = false
    @State private var mode = RestoreMode.merge
    @State private var confirmation = ""
    @State private var visibleSession: UUID?
    @State private var fileFlow = ResearchFileRequestFlow()
    @State private var fileTask: Task<Void,Never>?
    @State private var importMode = RestoreMode.merge
    private var fileBusy: Bool { fileFlow.isBusy }
    var body: some View {
        // Each panel callback belongs to the request rendered with this view.
        let request = fileFlow.id
        let displayedPlanID = transfer.plan?.id
        VStack(alignment:.leading,spacing:16) {
            Text("导出与恢复").font(.title2.bold())
            Text("本批仅备份冻结合成研究、自选目标和冲突副本。源缓存不包含在研究备份中；API Key 始终单独管理。").foregroundStyle(.secondary)
            HStack {
                Button("导出当前研究 Markdown") { beginExport(markdown:true) }
                    .disabled(research.document == nil || transfer.isBusy || fileBusy).accessibilityIdentifier("researchExportMarkdown")
                Button("导出研究备份 ZIP") { beginExport(markdown:false) }
                    .disabled(transfer.isBusy || fileBusy).accessibilityIdentifier("researchExportBackup")
            }
            GroupBox("从备份恢复") {
                VStack(alignment:.leading,spacing:12) {
                    Picker("恢复方式",selection:$mode) {
                        Text("合并 · 冲突保留两份").tag(RestoreMode.merge)
                        Text("覆盖 · 替换研究与自选").tag(RestoreMode.replace)
                    }.pickerStyle(.radioGroup).accessibilityIdentifier("researchRestoreMode")
                    Text("选择文件后先校验和预览，确认后才写入。覆盖不清理源缓存；备份只支持本应用的普通 ZIP 格式。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择备份并预检…") { beginImport() }
                        .disabled(transfer.isBusy || fileBusy).accessibilityIdentifier("researchImport")
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            if let message = transfer.message { Text(message).font(.callout).accessibilityIdentifier("researchTransferMessage") }
            if transfer.isBusy { ProgressView("正在校验本地数据…") }
            GroupBox("合并保留的自选冲突") {
                VStack(alignment:.leading,spacing:10) {
                    Button("重新读取冲突") { runVisible { await transfer.readConflicts() } }.disabled(transfer.isBusy || fileBusy)
                    if transfer.conflicts.isEmpty { Text("当前没有可展示的冲突副本；读取失败会另行提示。").foregroundStyle(.secondary) }
                    ForEach(transfer.conflicts) { conflict in
                        Text("\(conflict.entry.symbol) · 目标 \(conflict.entry.targetPrice?.decimalString ?? "未填") · 最高接股价 \(conflict.entry.maximumAssignmentPrice?.decimalString ?? "未填")\n\(conflict.entry.riskNote)\n版本 \(conflict.entry.revision.uuidString)")
                            .font(.callout).textSelection(.enabled)
                    }
                    Text("现有自选不自动覆盖。对照副本后，可在自选页人工编辑目标；副本随备份保留。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            Divider()
            Button("预览清空合成研究工作区…",role:.destructive) { runVisible { await transfer.prepareClear() } }
                .disabled(transfer.isBusy || fileBusy).accessibilityIdentifier("researchClearPreview")
            Text("仅清空合成研究工作区的研究、自选、冲突和源缓存。SEC 财报库、离线摘录库、外部备份文件和 Keychain 不变；不承诺磁盘物理擦除。").font(.caption).foregroundStyle(.secondary)
        }
        .fileExporter(isPresented:$exporting,document:exportFile,contentTypes:[exportType],defaultFilename:exportName) { result in
            switch result {
            case .success: report(.succeeded, for: request)
            case .failure: report(.failed, for: request)
            }
        } onCancellation: {
            report(.cancelled, for: request)
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.zip],allowsMultipleSelection:false) { result in
            guard current(request) else { return }
            guard case let .success(urls) = result, urls.count == 1, let url = urls.first else {
                report(.failed, for: request); return
            }
            guard fileFlow.selectFile(for: request) else { return }
            let selectedMode = importMode
            fileTask = Task {
                guard current(request), !Task.isCancelled else { return }
                // The model owns the session before the first file read, so an old
                // read cannot reopen a plan after leaving this page or clearing data.
                await transfer.prepare(mode:selectedMode) { try await ResearchSelectedFile.read(url) }
                finishFileRequest(request)
            }
        } onCancellation: {
            report(.cancelled, for: request)
        }
        .sheet(item:Binding(get:{transfer.plan},set:{if $0 == nil, let displayedPlanID, transfer.plan?.id == displayedPlanID { transfer.dismiss() }})) { plan in
            VStack(alignment:.leading,spacing:14) {
                Text(plan.operation == .clearBusiness ? "确认清空合成研究工作区":"确认恢复计划").font(.title2.bold())
                ScrollView { VStack(alignment:.leading,spacing:6) { ForEach(Array(plan.details.enumerated()),id:\.offset) { Text($0.element).font(.callout) } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(height:240)
                Text("此计划仅本次进程有效；确认前数据变化会拒绝提交。").font(.caption).foregroundStyle(.secondary)
                TextField("输入 确认 后提交",text:$confirmation).onSubmit { }.textFieldStyle(.roundedBorder).accessibilityIdentifier("researchTransferConfirmText")
                if let message = transfer.message { Text(message).font(.callout) }
                HStack { Spacer()
                    Button("取消") { Task { if transfer.plan?.id == plan.id { await transfer.cancel() } } }.keyboardShortcut(.cancelAction).disabled(transfer.isBusy)
                    Button("执行已确认计划",role:.destructive) {
                        Task { _ = await transfer.confirm(id:plan.id,digest:plan.digest) }
                    }.keyboardShortcut("d",modifiers:[.command,.shift])
                        .disabled(confirmation != "确认" || transfer.isBusy).accessibilityIdentifier("researchTransferCommit")
                }
            }.padding(24).frame(width:600).onAppear { confirmation = "" }
        }
        .onAppear { visibleSession = UUID() }
        .task { await transfer.readConflicts() }
        .onDisappear {
            visibleSession = nil
            fileTask?.cancel(); fileTask = nil
            fileFlow.dismiss(); exportFile = nil; exporting = false; importing = false
            transfer.dismiss()
        }
    }
    private func runVisible(_ action: @escaping @MainActor () async -> Void) {
        // A new non-file operation ends the previous panel's callback window.
        // Its late cancellation must not overwrite a clear/refresh outcome.
        if !fileFlow.isBusy { fileFlow.dismiss() }
        let session = visibleSession
        Task {
            guard let session, visibleSession == session, !Task.isCancelled else { return }
            await action()
        }
    }
    private func current(_ request: UUID?) -> Bool {
        visibleSession != nil && fileFlow.owns(request)
    }
    private func report(_ outcome: ResearchFileRequestFlow.Outcome, for request: UUID?) {
        let wasReading = fileFlow.isReading
        guard current(request), fileFlow.receive(outcome, for: request) else { return }
        switch outcome {
        case .succeeded: transfer.exported()
        case .failed: transfer.fileFailed()
        case .cancelled:
            fileTask?.cancel()
            // A cancelled syscall may later fail with its original POSIX error.
            // Invalidate publication now; task cancellation alone is insufficient.
            if wasReading { transfer.dismiss() }
            transfer.fileCancelled()
        }
        finishFileRequest(request)
    }
    private func finishFileRequest(_ request: UUID?) {
        guard current(request) else { return }
        fileFlow.finish(for: request); fileTask = nil; exportFile = nil
    }
    private func beginImport() {
        guard visibleSession != nil, !fileBusy, !transfer.isBusy else { return }
        guard fileFlow.begin() != nil else { return }
        importMode = mode; importing = true
    }
    private func beginExport(markdown: Bool) {
        guard visibleSession != nil, !fileBusy, !transfer.isBusy else { return }
        let document = research.document
        if markdown && document == nil { return }
        guard let request = fileFlow.begin() else { return }
        fileTask = Task {
            guard current(request), !Task.isCancelled else { return }
            do {
                let bytes: Data?
                if markdown, let document { bytes = try await ResearchMarkdown.render(document) }
                else { bytes = await transfer.backup() }
                guard current(request), !Task.isCancelled else { return }
                guard let bytes else { finishFileRequest(request); return }
                exportFile = ResearchExportFile(bytes)
                exportType = markdown ? .plainText : .zip
                exportName = markdown ? ((document?.symbol ?? "research") + "-research.md") : "MarketDecision-research.zip"
                fileTask = nil; exporting = true
            } catch {
                guard current(request), !Task.isCancelled else { return }
                report(.failed, for: request)
            }
        }
    }
}
