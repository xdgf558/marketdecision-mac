import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import DataContracts
import Persistence

private struct SECArchiveFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct SECArchiveTransferContent: View {
    @Bindable var transfer: SECArchiveTransferModel
    @Bindable var research: SECResearchWorkspaceModel
    @State private var consent = false
    @State private var mode = RestoreMode.merge
    @State private var importMode = RestoreMode.merge
    @State private var exportFile: SECArchiveFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmation = ""
    @State private var visibleSession: UUID?
    @State private var fileFlow = ResearchFileRequestFlow()
    @State private var fileTask: Task<Void, Never>?
    private var busy: Bool { transfer.isBusy || research.isBusy || fileFlow.isBusy }

    var body: some View {
        let request = fileFlow.id
        let displayedPlanID = transfer.plan?.id
        VStack(alignment: .leading, spacing: 16) {
            Text("SEC 本地归档").font(.title2.bold())
            Text("保存选中的一份 SEC 研究、冻结来源及其关联财务报告和估值补充。恢复后保留原版本，重新打开并核对前不显示缓存数值。")
                .foregroundStyle(.secondary)
            Toggle("仅用于我自己的本地备份与恢复", isOn: $consent)
                .disabled(busy).accessibilityIdentifier("secArchiveConsent")
            Text("ZIP 未加密，可能包含研究笔记。联系邮箱、Keychain、独立源缓存和其他工作区不在归档内；含行情价格证据的研究族本批不支持导出。")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("导出选中研究") {
                VStack(alignment: .leading, spacing: 10) {
                    if let document = research.document {
                        Text(document.ticker + " · " + document.identity.name).font(.headline)
                        Text("研究版本 " + document.id.uuidString).font(.caption).textSelection(.enabled)
                    } else {
                        Text("先在“已保存”中打开一份 SEC 研究，再导出该版本及其关联报告。")
                            .foregroundStyle(.secondary)
                    }
                    Button("导出 SEC 归档 ZIP…") { beginExport() }
                        .disabled(!consent || busy || research.document == nil)
                        .accessibilityIdentifier("secArchiveExport")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("从 SEC 归档恢复") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("恢复方式", selection: $mode) {
                        Text("合并 · 相同版本去重，内容冲突拒绝").tag(RestoreMode.merge)
                        Text("覆盖 · 替换全部 SEC 研究及关联报告").tag(RestoreMode.replace)
                    }.pickerStyle(.radioGroup).disabled(busy).accessibilityIdentifier("secArchiveMode")
                    Text("先预检，再确认写入。覆盖会移除当前全部 SEC 研究、财务报告和估值补充，保留源缓存及其他工作区。仅接受本应用的 SEC 归档格式。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择 SEC 归档并预检…") { beginImport() }
                        .disabled(!consent || busy).accessibilityIdentifier("secArchiveImport")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if transfer.isBusy { ProgressView("正在处理本地归档…") }
            if let message = transfer.message {
                Text(message).font(.callout).accessibilityIdentifier("secArchiveMessage")
            }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentTypes: [.zip],
                      defaultFilename: "MarketDecision-sec-research.zip") { result in
            switch result {
            case .success: report(.succeeded, for: request)
            case .failure: report(.failed, for: request)
            }
        } onCancellation: { report(.cancelled, for: request) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            guard current(request) else { return }
            guard case let .success(urls) = result, urls.count == 1, let url = urls.first else {
                report(.failed, for: request); return
            }
            guard fileFlow.selectFile(for: request) else { return }
            let selectedMode = importMode
            fileTask = Task {
                guard current(request), !Task.isCancelled else { return }
                await transfer.prepare(mode: selectedMode, consent: .personalLocalBackup) {
                    try await ResearchSelectedFile.read(url)
                }
                finishFileRequest(request)
            }
        } onCancellation: { report(.cancelled, for: request) }
        .sheet(item: Binding(get: { transfer.plan }, set: {
            if $0 == nil, let displayedPlanID, transfer.plan?.id == displayedPlanID { transfer.dismiss() }
        })) { plan in
            VStack(alignment: .leading, spacing: 14) {
                Text(plan.mode == .replace ? "确认覆盖 SEC 研究库" : "确认合并 SEC 归档").font(.title2.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(plan.details.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 240)
                Text("计划仅本次进程有效；确认前研究库发生变化会拒绝提交。恢复不会自动联网或核对缓存结果。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("输入 确认 后提交", text: $confirmation).onSubmit { }
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("secArchiveConfirmText")
                if let message = transfer.message { Text(message).font(.callout) }
                HStack {
                    Spacer()
                    Button("取消") { Task { if transfer.plan?.id == plan.id { await transfer.cancel() } } }
                        .keyboardShortcut(.cancelAction).disabled(transfer.isBusy)
                    Button("执行恢复计划", role: .destructive) {
                        Task { _ = await transfer.confirm(id: plan.id, digest: plan.digest) }
                    }.keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(confirmation != "确认" || transfer.isBusy || research.isBusy)
                        .accessibilityIdentifier("secArchiveCommit")
                }
            }.padding(24).frame(width: 600).onAppear { confirmation = "" }
        }
        .onAppear { visibleSession = UUID(); consent = false }
        .onDisappear {
            visibleSession = nil; fileTask?.cancel(); fileTask = nil
            fileFlow.dismiss(); exportFile = nil; exporting = false; importing = false
            transfer.dismiss()
        }
    }

    private func current(_ request: UUID?) -> Bool { visibleSession != nil && fileFlow.owns(request) }
    private func report(_ outcome: ResearchFileRequestFlow.Outcome, for request: UUID?) {
        let wasReading = fileFlow.isReading
        guard current(request), fileFlow.receive(outcome, for: request) else { return }
        switch outcome {
        case .succeeded: transfer.exported()
        case .failed: transfer.fileFailed()
        case .cancelled:
            fileTask?.cancel()
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
        guard visibleSession != nil, consent, !busy, fileFlow.begin() != nil else { return }
        importMode = mode; importing = true
    }
    private func beginExport() {
        guard visibleSession != nil, consent, !busy, let id = research.document?.id,
              let request = fileFlow.begin() else { return }
        fileTask = Task {
            guard current(request), !Task.isCancelled else { return }
            let bytes = await transfer.export(researchID: id, consent: .personalLocalBackup)
            guard current(request), !Task.isCancelled else { return }
            guard let bytes else { finishFileRequest(request); return }
            exportFile = SECArchiveFile(bytes); fileTask = nil; exporting = true
        }
    }
}
