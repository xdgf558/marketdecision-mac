import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import MacroProviders
import MarketAnalytics
import Persistence

private struct MacroImportApproval: Identifiable {
    let id: UUID
    let revision: UUID
}

struct MacroSourceContent: View {
    @Bindable var model: MacroSourceWorkspaceModel
    let marketBase: MarketStateInput?
    @State private var format = MacroSourceFormat.fredObservationsJSON
    @State private var manifest = ""
    @State private var rawText = ""
    @State private var inputExpanded = false
    @State private var inputError: String?
    @State private var approval: MacroImportApproval?
    @State private var confirming = ""
    @State private var importing = false
    @State private var capturedManifest = ""
    @State private var flow = ResearchFileRequestFlow()
    @State private var fileMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var templateTask: Task<Void, Never>?
    @State private var loadingTemplate = false
    @State private var session = UUID()
    @State private var form = UUID()
    @State private var visible = false
    private var busy: Bool { model.isBusy || flow.isBusy || loadingTemplate }
    var body: some View {
        let fileRequest = flow.id
        VStack(alignment: .leading, spacing: 16) {
            Text("原始来源导入与宏观数据").font(.title2.bold()).accessibilityIdentifier("macroSourceTitle")
            Text("从原始 CSV / JSON 和明确的来源描述建立预览。发布与可得时点必须有独立证据；抓取时间、ALFRED 修订日期都不能代替发布时间。当前没有网络传输或供应商准入。")
                .foregroundStyle(.secondary)
            input
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? Color.red : Color.secondary).accessibilityIdentifier("macroSourceMessage") }
            if let inputError { Text(inputError).foregroundStyle(.red) }
            if let fileMessage { Text(fileMessage).foregroundStyle(.secondary).accessibilityIdentifier("macroSourceFileMessage") }
            if busy { HStack { ProgressView().controlSize(.small); Text("正在核对来源与发布证据…").font(.caption) } }
            if model.isBusy && model.canEdit { Button("取消发布") { model.cancel() }.accessibilityIdentifier("macroSourceCancelWork") }
            if flow.isBusy { Button("取消文件操作") { finishFile(.cancelled, fileRequest) } }
            if let report = model.report { reportView(report) }
            else if model.bridge == nil { Text("尚未选定核对通过的来源。目录元数据不作为数值报告。").foregroundStyle(.secondary).accessibilityIdentifier("macroSourceEmpty") }
            basket
            if let bridge = model.bridge { bridgeView(bridge) }
            catalog
            Text("市场 ZIP 归档保留完整来源原字节与冻结报告；普通 ZIP 不加密。离线文件数量和字节预算不是进程内存上限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { visible = true; await model.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
            guard current(fileRequest) else { return }
            guard case .success(let urls) = result, urls.count == 1, let url = urls.first else { finishFile(.failed, fileRequest); return }
            guard flow.selectFile(for: fileRequest) else { return }; let text = capturedManifest
            task = Task {
                guard current(fileRequest), !Task.isCancelled else { return }
                await model.prepare(manifestJSON: text) { try await ResearchSelectedFile.read(url, maximumBytes: MacroSourceWorkspaceModel.maximumSourceBytes) }
                guard current(fileRequest), !Task.isCancelled else { return }
                if let report = model.preview?.report { rawText = String(decoding: report.input.rawData, as: UTF8.self); manifest = text }
                flow.finish(for: fileRequest); task = nil
            }
        } onCancellation: { finishFile(.cancelled, fileRequest) }
        .sheet(item: $approval) { value in confirmationSheet(value) }
        .onChange(of: model.preview?.id) { _, id in if approval?.id != id { approval = nil; confirming = "" } }
        .onChange(of: model.savedID) { _, _ in synchronizeInput() }
        .onChange(of: model.transferEpoch) { _, _ in resetFile(); templateTask?.cancel(); loadingTemplate = false; approval = nil; form = UUID() }
        .onDisappear {
            visible = false; session = UUID(); form = UUID(); resetFile(); templateTask?.cancel(); loadingTemplate = false
            approval = nil; model.disappear()
        }
    }
    private var input: some View {
        GroupBox("选择格式与原始输入") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("模板格式", selection: Binding(get: { format }, set: { format = $0; manifest = ""; rawText = ""; changed() })) {
                    ForEach(MacroSourceFormat.allCases, id: \.self) { Text(formatTitle($0)).tag($0) }
                }.disabled(busy || !model.canEdit).accessibilityIdentifier("macroSourceFormat")
                HStack {
                    Button("载入合成原始文件") { template() }.disabled(busy || !model.canEdit).accessibilityIdentifier("macroSourceDemo")
                    Button("预览文本输入") {
                        let text = manifest, bytes = Data(rawText.utf8)
                        act { await model.prepare(manifestJSON: text) { bytes } }
                    }.disabled(manifest.isEmpty || rawText.isEmpty || busy || !model.canEdit).accessibilityIdentifier("macroSourcePreview")
                    Button("选择原始文件并预览…") { beginFile() }
                        .disabled(manifest.isEmpty || busy || !model.canEdit).accessibilityIdentifier("macroSourceSelectFile")
                }
                DisclosureGroup("原始文本与来源 / 发布证据描述", isExpanded: $inputExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原始文件内容（CSV / JSON）").font(.headline)
                        TextEditor(text: Binding(get: { rawText }, set: { rawText = $0; changed() }))
                            .font(.system(.caption, design: .monospaced)).frame(minHeight: 130, maxHeight: 230)
                            .disabled(!model.canEdit || flow.isBusy || loadingTemplate).accessibilityIdentifier("macroSourceRawInput")
                        Text("来源、序列、单位口径、修订及每条发布证据").font(.headline)
                        TextEditor(text: Binding(get: { manifest }, set: { manifest = $0; changed() }))
                            .font(.system(.caption, design: .monospaced)).frame(minHeight: 180, maxHeight: 280)
                            .disabled(!model.canEdit || flow.isBusy || loadingTemplate).accessibilityIdentifier("macroSourceManifest")
                        Text("先载入模板再编辑描述，无需手写冻结报告或把文件转为 Base64。来源文字不授予许可；缺少发布时间的值留在溯源记录，不进入截至时刻可用值。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func reportView(_ report: MacroSourceReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.containsSynthetic ? "SYNTHETIC · 合成原始来源" : "本地原始文件 · 未授予供应商资格")
                .font(.headline).foregroundStyle(.orange).accessibilityIdentifier("macroSourceOrigin")
            Text(model.preview == nil ? "已保存来源 · 原字节与解析报告已核对" : "导入预览 · 尚未保存")
                .font(.headline).accessibilityIdentifier("macroSourcePreviewState")
            Text("\(formatTitle(report.input.descriptor.format)) · \(report.input.descriptor.sourceID) / \(report.input.descriptor.feedID) · 修订 \(report.input.descriptor.revisionID)")
                .font(.caption).textSelection(.enabled)
            Text("截至 \(report.input.asOf.formatted(date: .numeric, time: .complete)) · 原始 \(report.observations.count) 条 · 可用修订 \(report.selectedObservations.count) 条 · 缺口 \(report.gaps.count) 条")
                .accessibilityIdentifier("macroSourceCounts")
            Text("SHA-256：\(report.contentSHA256)").font(.caption.monospaced()).textSelection(.enabled)
            Text("当前选择只覆盖已导入的修订和明确可得证据；不证明供应商完整历史。FRED 日期区间可能被查询裁剪，不作为精确失效时间。")
                .font(.caption).foregroundStyle(.secondary)
            if let preview = model.preview {
                Button("确认保存这份预览…") { approval = .init(id: preview.id, revision: preview.revision); confirming = "" }
                    .disabled(!model.canConfirm || flow.isBusy).accessibilityIdentifier("macroSourceSavePreview")
            }
            available(report)
            DisclosureGroup("缺失与不可用原因") {
                if report.gaps.isEmpty { Text("当前描述范围未记录缺项。").font(.caption) }
                ForEach(Array(report.gaps.enumerated()), id: \.offset) { _, gap in
                    Text("\(gap.series.rawValue) · \(gap.observationDate) · \(gap.vintageID) · \(gapTitle(gap.reason))").font(.caption).textSelection(.enabled)
                }
            }
            DisclosureGroup("全部原始修订（仅溯源）") {
                ForEach(Array(report.observations.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.series.rawValue) · \(item.observationDate) · \(item.vintageID)").font(.caption.bold())
                        Text(item.rawFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(item.transformation) · \(item.missingReason.map(gapTitle) ?? "有解析值；是否可用以截止时刻选择为准")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let release = item.release {
                            Text("发布 \(release.releasedAt.formatted(date: .numeric, time: .complete)) · 可得 \(release.availableAt.formatted(date: .numeric, time: .complete))\n\(release.evidenceReference)").font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }
            }
            DisclosureGroup("来源限制") { ForEach(Array(report.limitations.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) } }
        }
    }
    private func available(_ report: MacroSourceReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.input.descriptor.series, id: \.self) { series in
                GroupBox(series.rawValue + (series.frequency == .releaseCycle ? " · 宏观发布周期" : " · 日 / 周序列")) {
                    VStack(alignment: .leading, spacing: 5) {
                        let rows = report.selectedObservations.filter { $0.series == series }
                        if rows.isEmpty { Text("该截止时刻没有可用值，不使用当前最新值回填。").foregroundStyle(.secondary) }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                            Text("\(item.observationDate) · \(item.value?.decimalString ?? "缺失") \(unitTitle(item.unit)) · \(item.vintageID)")
                                .font(.callout.monospacedDigit()).textSelection(.enabled)
                        }
                        if series.frequency == .releaseCycle { Text("只按发布周期展示；不重复填充为交易日样本，也不加入三分数。").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.accessibilityIdentifier("macroSourceAvailable")
    }
    private var basket: some View {
        GroupBox("明确选择来源后重算市场状态") {
            VStack(alignment: .leading, spacing: 9) {
                Button("将当前已保存来源加入计算") { model.selectCurrentSource() }
                    .disabled(!model.canSelectSource || flow.isBusy).accessibilityIdentifier("macroSourceAdd")
                ForEach(model.selectedSources, id: \.id) { source in
                    HStack {
                        Text("\(source.input.descriptor.sourceID) · \(source.input.descriptor.revisionID) · \(source.id.uuidString)").font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("移除") { model.removeSelectedSource(source.id) }.disabled(busy || !model.canEdit)
                    }
                }
                if let marketBase {
                    Text("基础快照：\(marketBase.sessionDate) · \(marketBase.id.uuidString)。保留其明确日历、截止时刻和其他输入，只替换来源覆盖的日 / 周序列。").font(.caption).foregroundStyle(.secondary)
                    Button("用已选来源重算") { act { await model.buildMarket(base: marketBase) } }
                        .disabled(model.selectedSources.isEmpty || busy || !model.canEdit).accessibilityIdentifier("macroSourceBuildMarket")
                } else { Text("先在“总览与计算”核对一份基础市场输入，再进入此页选择来源；不会自动伪造完整日历或其他缺失序列。").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func bridgeView(_ result: MacroMarketBridgeReport) -> some View {
        GroupBox("完整来源支持的独立市场报告") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(result.market.current.sessionDate) · \(result.market.current.confirmedLabel.title)").font(.headline).accessibilityIdentifier("macroSourceBridgeLabel")
                Text("本报告基础：\(result.input.base.sessionDate) · \(result.input.base.id.uuidString) · 截止 \(result.input.base.asOf.formatted(date: .numeric, time: .complete))").font(.caption).foregroundStyle(.secondary)
                Text("热度 \(sourceNumber(result.market.current.heat.value)) · 压力 \(sourceNumber(result.market.current.stress.value)) · 情绪 \(sourceNumber(result.market.current.sentiment.value))")
                Text("替换：\(result.replacedKeys.map(\.rawValue).joined(separator: "、"))").font(.caption)
                Text("来源缺口 \(result.bridge.gaps.count) · \(result.containsSynthetic ? "包含合成输入" : "仅离线来源，未授予历史分析资格")").font(.caption)
                ForEach(Array(result.bridge.transformations.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                Button("保存完整来源与市场报告") { act { await model.saveBridge() } }.disabled(!model.canSaveBridge || flow.isBusy).accessibilityIdentifier("macroSourceSaveBridge")
                Text(model.savedID == nil ? "尚未保存。" : "已按完整输入重放核对。原基础快照不变。 ").font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private var catalog: some View {
        GroupBox("已保存来源、修订与来源市场报告") {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("目录不含观测值；打开后先核对原始字节与完整报告。 ").font(.caption).foregroundStyle(.secondary); Spacer()
                    Button("刷新来源目录") { act { await model.load() } }.disabled(busy || !model.canEdit).accessibilityIdentifier("macroSourceReload") }
                if let error = model.listError { Text(error).foregroundStyle(.red) }
                if model.saved.isEmpty { Text("尚无来源记录。").foregroundStyle(.secondary).accessibilityIdentifier("macroSourceCatalogEmpty") }
                ForEach(model.saved) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(item.kind == .source ? "来源原文" : "来源市场报告") · \(item.containsSynthetic ? "SYNTHETIC" : "离线文件")\(item.id != item.originalID ? " · 冲突副本" : "")")
                            Text("\(item.sourceID ?? "多来源") · \(item.revisionID ?? "完整来源集合") · \(item.id.uuidString)").font(.caption).textSelection(.enabled)
                        }; Spacer()
                        Button("打开并核对") { act { await model.open(item) } }.disabled(busy || !model.canEdit).accessibilityIdentifier("macroSourceOpen-" + item.id.uuidString)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func confirmationSheet(_ value: MacroImportApproval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认保存来源预览").font(.title2.bold())
            if let preview = model.preview, preview.id == value.id {
                Text("\(preview.report.input.descriptor.sourceID) / \(preview.report.input.descriptor.feedID)\n修订 \(preview.report.input.descriptor.revisionID) · 原始观测 \(preview.report.observations.count) · 缺口 \(preview.report.gaps.count)")
                Text("将保存原始文件和完整发布证据。不会请求供应商，也不会修改已有市场三分数。批准绑定此预览和市场库版本。").font(.callout).foregroundStyle(.secondary)
            }
            TextField("输入“确认”后保存", text: $confirming).onSubmit { }.textFieldStyle(.roundedBorder).accessibilityIdentifier("macroSourceConfirmText")
            HStack {
                Button("取消") { approval = nil; confirming = "" }.keyboardShortcut(.cancelAction).disabled(model.isBusy).accessibilityIdentifier("macroSourceConfirmCancel")
                Spacer()
                Button("保存已确认来源") { act { _ = await model.confirm(id: value.id, expectedRevision: value.revision) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(confirming != "确认" || !model.canConfirm || model.preview?.id != value.id).accessibilityIdentifier("macroSourceConfirmSave")
            }
            if model.hasError, let message = model.message { Text(message).foregroundStyle(.red) }
        }.padding(24).frame(width: 620)
    }
    private func changed() { form = UUID(); approval = nil; model.draftChanged(); inputError = nil; fileMessage = nil }
    private func synchronizeInput() {
        guard let report = model.report else { return }
        format = report.input.descriptor.format
        rawText = String(decoding: report.input.rawData, as: UTF8.self)
        if let text = try? MacroSourceManifest(report.input).json() { manifest = text }
    }
    private func template() {
        changed(); loadingTemplate = true; let token = session, edit = form, selection = format
        templateTask = Task {
            do {
                let example = try await Task.detached { try MacroSourceWorkspaceModel.demo(selection) }.value
                guard visible, session == token, form == edit, !Task.isCancelled else { return }
                rawText = example.raw; manifest = example.manifest; loadingTemplate = false
            } catch { guard visible, session == token, form == edit, !Task.isCancelled else { return }; loadingTemplate = false; inputError = "合成原始文件未能建立。" }
        }
    }
    private func act(_ action: @escaping @MainActor () async -> Void) { let token = session, edit = form; Task { guard visible, session == token, form == edit else { return }; await action() } }
    private func current(_ id: UUID?) -> Bool { visible && flow.owns(id) }
    private func beginFile() {
        guard !busy, model.canEdit else { return }
        do {
            capturedManifest = try JSONDecoder().decode(MacroSourceManifest.self, from: Data(manifest.utf8)).selectingLocalFile().json()
            changed(); guard flow.begin() != nil else { return }; importing = true
        } catch { inputError = "请先填写有效来源描述，再选择文件。" }
    }
    private func finishFile(_ outcome: ResearchFileRequestFlow.Outcome, _ id: UUID?) {
        let reading = flow.isReading
        guard current(id), flow.receive(outcome, for: id) else { return }
        switch outcome {
        case .cancelled: task?.cancel(); if reading || model.isBusy { model.cancel() }; fileMessage = "已取消文件操作。"
        case .failed: fileMessage = "文件未能打开，请检查所选文件。"
        case .succeeded: break
        }
        flow.finish(for: id); task = nil
    }
    private func resetFile() { task?.cancel(); task = nil; flow.dismiss(); importing = false; fileMessage = nil }
}
private func formatTitle(_ value: MacroSourceFormat) -> String {
    switch value { case .fredObservationsJSON: "FRED 观测 JSON"; case .alfredObservationsJSON: "ALFRED 修订 JSON"; case .cboeIndexHistoryCSV: "Cboe 指数历史 CSV"; case .cboePutCallHistoryCSV: "Cboe Put / Call CSV"; case .cftcFinancialFuturesCSV: "CFTC 金融期货 CSV" }
}
private func gapTitle(_ value: MacroSourceGapReason) -> String {
    switch value { case .sourceMissingValue: "来源缺值"; case .unverifiedRelease: "发布时点未核对"; case .notAvailableAtCutoff: "截止时刻尚不可得"; case .zeroOpenInterest: "未平仓量为零"; case .noMarketMapping: "只作独立展示，不加入市场分数" }
}
private func unitTitle(_ value: MacroSourceUnit) -> String {
    switch value { case .percent: "%"; case .percentagePoints: "百分点"; case .indexLevel: "指数点"; case .thousandsPersons: "千人"; case .billionsChainedDollars: "十亿链式美元"; case .ratio: "比率" }
}
private func sourceNumber(_ value: Double?) -> String { value.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "不可用" }
