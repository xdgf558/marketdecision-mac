import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import Persistence

private struct MarketArchiveFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }; self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}
struct MarketStateArchiveContent: View {
    @Bindable var model: MarketStateWorkspaceModel
    @State private var mode = MarketStateRestoreMode.merge
    @State private var capturedMode = MarketStateRestoreMode.merge
    @State private var confirmation = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var document: MarketArchiveFile?
    @State private var flow = ResearchFileRequestFlow()
    @State private var task: Task<Void, Never>?
    @State private var visible = false
    @State private var session = UUID()
    private var busy: Bool { model.isBusy || flow.isBusy }
    var body: some View {
        let request = flow.id, displayedPlanID = model.plan?.id
        VStack(alignment: .leading, spacing: 16) {
            Text("独立市场库归档").font(.title2.bold())
            Text("保存市场历史快照、来源版本和嵌入交易依据。不会导出或恢复研究库、期权库、实际账本、源缓存或 Keychain。")
                .foregroundStyle(.secondary)
            if let status = model.status { Text(marketCounts(status.counts)).accessibilityIdentifier("marketArchiveCounts") }
            GroupBox("导出市场快照 ZIP") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ZIP 未加密，可能包含手工输入的来源和历史交易信息。请选择你控制的位置。完整输入与归档校验仍在内存中，字节预算不是内存上限。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("生成并选择保存位置…") { beginExport() }.disabled(!model.canPrepare || flow.isBusy).accessibilityIdentifier("marketArchiveExport")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("从市场 ZIP 恢复") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("恢复方式", selection: $mode) {
                        Text("合并 · 相同内容去重，冲突保留两份").tag(MarketStateRestoreMode.merge)
                        Text("替换 · 仅替换市场冻结快照，保留源缓存").tag(MarketStateRestoreMode.replace)
                    }.pickerStyle(.radioGroup).disabled(busy || model.plan != nil)
                    Text("读取和完整预检不改变数据库；必须核对固定计划及版本，再显式确认。替换可修复损坏旧正文，但仍要求有效元数据和完整备份。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("选择市场归档并预检…") {
                        guard model.canPrepare, !flow.isBusy, flow.begin() != nil else { return }; capturedMode = mode; importing = true
                    }.disabled(!model.canPrepare || flow.isBusy).accessibilityIdentifier("marketArchiveImport")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if busy { ProgressView("正在核对市场归档与冻结证据…") }
            if flow.isBusy { Button("取消文件操作") { finish(.cancelled, request) } }
            Divider()
            Button("预检清空独立市场库…", role: .destructive) { run { await model.prepareClear() } }
                .disabled(!model.canPrepare || flow.isBusy).accessibilityIdentifier("marketArchiveClear")
            Text("清空包括市场快照、交易归因及独立市场源缓存；其他数据库不变。计划在本进程有效，关闭页面不会撤销已经发起的事务。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileExporter(isPresented: $exporting, document: document, contentTypes: [.zip], defaultFilename: "market-state-backup.zip") { result in
            switch result { case .success: finish(.succeeded, request); case .failure: finish(.failed, request) }
        } onCancellation: { finish(.cancelled, request) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            guard current(request) else { return }
            guard case .success(let urls) = result, urls.count == 1, let url = urls.first else { finish(.failed, request); return }
            guard flow.selectFile(for: request) else { return }; let selectedMode = capturedMode
            task = Task {
                guard current(request), !Task.isCancelled else { return }
                await model.prepareRestore(mode: selectedMode) { try await ResearchSelectedFile.read(url, maximumBytes: MarketStateArchiveCodec.maximumArchiveBytes) }
                endFile(request)
            }
        } onCancellation: { finish(.cancelled, request) }
        .sheet(item: Binding(get: { model.plan }, set: { value in
            if value == nil, let displayedPlanID, model.plan?.id == displayedPlanID, !model.isBusy { Task { await model.cancelPlan(expectedID: displayedPlanID) } }
        })) { plan in confirmationSheet(plan) }
        .onChange(of: model.plan?.id) { _, _ in confirmation = "" }
        .onChange(of: model.transferEpoch) { _, _ in session = UUID(); resetFile() }
        .onAppear { visible = true }
        .onDisappear {
            visible = false; session = UUID(); resetFile()
            if model.isBusy { model.cancelWork() }
            if !model.isBusy, let id = model.plan?.id { Task { await model.cancelPlan(expectedID: id) } }
        }
    }
    private func confirmationSheet(_ plan: MarketStateTransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.operation == .clear ? "确认清空独立市场库" : plan.operation == .delete ? "确认删除市场快照" : "确认市场恢复计划").font(.title2.bold())
            Text("原有：\(marketCounts(plan.previous))\n结果：\(marketCounts(plan.result))")
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(Array(plan.details.enumerated()), id: \.offset) { Text($0.element) } }.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 190)
            Text("计划 \(plan.id.uuidString)\n版本 \(plan.baseRevision.uuidString)").font(.caption).textSelection(.enabled)
            TextField("输入“确认”后提交", text: $confirmation).onSubmit { }.textFieldStyle(.roundedBorder).accessibilityIdentifier("marketArchiveConfirmText")
            if let message = model.message { Text(message).font(.caption) }
            HStack {
                Button("取消") { Task { if model.plan?.id == plan.id { await model.cancelPlan(expectedID: plan.id) } } }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy).accessibilityIdentifier("marketArchiveCancel")
                Spacer()
                Button("执行已确认计划", role: .destructive) { Task { await model.confirm(.init(plan: plan)) } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(confirmation != "确认" || !model.canConfirm || model.plan?.id != plan.id).accessibilityIdentifier("marketArchiveCommit")
            }
        }.padding(24).frame(width: 660)
    }
    private func current(_ request: UUID?) -> Bool { visible && flow.owns(request) }
    private func resetFile() { task?.cancel(); task = nil; flow.dismiss(); document = nil; exporting = false; importing = false; confirmation = "" }
    private func finish(_ outcome: ResearchFileRequestFlow.Outcome, _ request: UUID?) {
        let reading = flow.isReading
        guard current(request), flow.receive(outcome, for: request) else { return }
        if outcome == .cancelled { task?.cancel(); if reading || model.isBusy { model.cancelWork() } }
        model.fileOutcome(outcome); endFile(request)
    }
    private func endFile(_ request: UUID?) { guard current(request) else { return }; flow.finish(for: request); task = nil; document = nil }
    private func run(_ action: @escaping @MainActor () async -> Void) { guard visible, !flow.isBusy else { return }; flow.dismiss(); let token = session; Task { guard visible, session == token else { return }; await action() } }
    private func beginExport() {
        guard visible, !busy, let request = flow.begin() else { return }
        task = Task {
            let bytes = await model.exportArchive()
            guard current(request), !Task.isCancelled else { return }
            guard let bytes else { endFile(request); return }; document = MarketArchiveFile(bytes); task = nil; exporting = true
        }
    }
}
private func marketCounts(_ value: MarketStateArchiveCounts) -> String {
    "市场快照 \(value.marketReports) · 交易归因 \(value.attributionReports) · 正文 \(value.documentBodies) · 冲突副本 \(value.conflictCopies) · 源缓存 \(value.cachedSources)"
}
