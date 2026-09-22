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
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("导出与恢复").font(.title2.bold())
            Text("本批仅备份冻结合成研究、自选目标和冲突副本。源缓存不包含在研究备份中；API Key 始终单独管理。").foregroundStyle(.secondary)
            HStack {
                Button("导出当前研究 Markdown") {
                    Task {
                        guard let document = research.document else { return }
                        do { exportFile = ResearchExportFile(try await ResearchMarkdown.render(document)); exportType = .plainText; exportName = document.symbol+"-research.md"; exporting = true }
                        catch { transfer.fileFailed() }
                    }
                }.disabled(research.document == nil || transfer.isBusy).accessibilityIdentifier("researchExportMarkdown")
                Button("导出研究备份 ZIP") {
                    Task { if let bytes = await transfer.backup() { exportFile = ResearchExportFile(bytes); exportType = .zip; exportName = "MarketDecision-research.zip"; exporting = true } }
                }.disabled(transfer.isBusy).accessibilityIdentifier("researchExportBackup")
            }
            GroupBox("从备份恢复") {
                VStack(alignment:.leading,spacing:12) {
                    Picker("恢复方式",selection:$mode) {
                        Text("合并 · 冲突保留两份").tag(RestoreMode.merge)
                        Text("覆盖 · 替换研究与自选").tag(RestoreMode.replace)
                    }.pickerStyle(.radioGroup)
                    Text("选择文件后先校验和预览，确认后才写入。覆盖不清理源缓存；备份只支持本应用的普通 ZIP 格式。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择备份并预检…") { importing = true }.disabled(transfer.isBusy).accessibilityIdentifier("researchImport")
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            if let message = transfer.message { Text(message).font(.callout).accessibilityIdentifier("researchTransferMessage") }
            if transfer.isBusy { ProgressView("正在校验本地数据…") }
            GroupBox("合并保留的自选冲突") {
                VStack(alignment:.leading,spacing:10) {
                    Button("重新读取冲突") { Task { await transfer.readConflicts() } }.disabled(transfer.isBusy)
                    if transfer.conflicts.isEmpty { Text("当前没有可展示的冲突副本；读取失败会另行提示。").foregroundStyle(.secondary) }
                    ForEach(transfer.conflicts) { conflict in
                        Text("\(conflict.entry.symbol) · 目标 \(conflict.entry.targetPrice?.decimalString ?? "未填") · 最高接股价 \(conflict.entry.maximumAssignmentPrice?.decimalString ?? "未填")\n\(conflict.entry.riskNote)\n版本 \(conflict.entry.revision.uuidString)")
                            .font(.callout).textSelection(.enabled)
                    }
                    Text("现有自选不自动覆盖。对照副本后，可在自选页人工编辑目标；副本随备份保留。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            Divider()
            Button("预览清空全部业务数据…",role:.destructive) { Task { await transfer.prepareClear() } }
                .disabled(transfer.isBusy).accessibilityIdentifier("researchClearPreview")
            Text("清空包括研究、自选、冲突和源缓存。外部备份文件和 Keychain 不变；不承诺磁盘物理擦除。").font(.caption).foregroundStyle(.secondary)
        }
        .fileExporter(isPresented:$exporting,document:exportFile,contentType:exportType,defaultFilename:exportName) { result in
            switch result { case .success: transfer.exported(); case .failure: transfer.fileFailed() }; exportFile = nil
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.zip]) { result in
            guard case let .success(url) = result else { transfer.fileFailed(); return }
            let selectedMode = mode
            Task {
                do {
                    let data = try await Task.detached {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true,
                              let size = values.fileSize, size <= 2_147_483_648 else { throw CocoaError(.fileReadCorruptFile) }
                        try Task.checkCancellation()
                        return try Data(contentsOf:url,options:.mappedIfSafe)
                    }.value
                    await transfer.prepare(data,mode:selectedMode)
                } catch { transfer.fileFailed() }
            }
        }
        .sheet(item:Binding(get:{transfer.plan},set:{if $0 == nil { transfer.dismiss() }})) { plan in
            VStack(alignment:.leading,spacing:14) {
                Text(plan.operation == .clearBusiness ? "确认清空全部业务数据":"确认恢复计划").font(.title2.bold())
                ScrollView { VStack(alignment:.leading,spacing:6) { ForEach(Array(plan.details.enumerated()),id:\.offset) { Text($0.element).font(.callout) } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(height:240)
                Text("此计划仅本次进程有效；确认前数据变化会拒绝提交。").font(.caption).foregroundStyle(.secondary)
                TextField("输入 确认 后提交",text:$confirmation).onSubmit { }.textFieldStyle(.roundedBorder).accessibilityIdentifier("researchTransferConfirmText")
                if let message = transfer.message { Text(message).font(.callout) }
                HStack { Spacer()
                    Button("取消") { Task { await transfer.cancel() } }.keyboardShortcut(.cancelAction).disabled(transfer.isBusy)
                    Button("执行已确认计划",role:.destructive) {
                        Task { _ = await transfer.confirm(id:plan.id,digest:plan.digest) }
                    }.keyboardShortcut("d",modifiers:[.command,.shift])
                        .disabled(confirmation != "确认" || transfer.isBusy).accessibilityIdentifier("researchTransferCommit")
                }
            }.padding(24).frame(width:600).onAppear { confirmation = "" }
        }
        .task { await transfer.readConflicts() }
        .onDisappear { transfer.dismiss() }
    }
}
