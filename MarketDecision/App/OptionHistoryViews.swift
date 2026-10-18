import SwiftUI
import Charts
import UniformTypeIdentifiers
import AppComposition
import CoreDomain
import DataContracts
import OptionsAnalytics
import Persistence

private struct OptionHistoryExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
struct OptionHistoryContent: View {
    @Bindable var model: OptionHistoryWorkspaceModel
    @State private var draft = OptionDailyInputDraft()
    @State private var page = "日摘要"
    @State private var inputError: String?
    @State private var calendarText = ""
    @State private var calendarReference = ""
    @State private var visible = false
    @State private var session = UUID()
    @State private var exporting = false
    @State private var exportFile: OptionHistoryExportFile?
    @State private var exportName = "options-volatility.md"
    @State private var exportType = UTType.plainText
    @State private var fileFlow = ResearchFileRequestFlow()
    @State private var actionTask: Task<Void, Never>?
    @State private var exportMessage: String?
    private var blocked: Bool { model.isBusy || fileFlow.isBusy }
    var body: some View {
        let fileRequest = fileFlow.id
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("波动率历史").font(.title2.bold())
                Spacer()
                Button("刷新目录") { perform { await model.load() } }.disabled(blocked).accessibilityIdentifier("optionHistoryReload")
            }
            Text("日摘要保存链与合约两层信息。IV30 由到期两侧总方差插值；历史分析要求当前日前 252 个有效声明会话、跨度不超过 400 个日历日。手工与合成数据均不授予市场资格。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("波动率内容", selection: $page) {
                Text("日摘要").tag("日摘要"); Text("历史分析").tag("历史分析"); Text("摘要目录").tag("摘要目录")
            }.pickerStyle(.segmented).accessibilityIdentifier("optionHistorySections")
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("optionHistoryMessage") }
            if let inputError { Text(inputError).foregroundStyle(.red).accessibilityIdentifier("optionHistoryInputError") }
            if let exportMessage { Text(exportMessage).foregroundStyle(.secondary) }
            if model.isBusy { ProgressView("正在核对完整日摘要与历史输入…") }
            if page == "日摘要" { dailyEditor }
            else if page == "历史分析" { historyEditor }
            else { savedCatalog }
        }
        .onChange(of: draft) { _, _ in model.draftChanged(); inputError = nil }
        .onChange(of: calendarText) { _, _ in model.historyDraftChanged(); inputError = nil }
        .onChange(of: calendarReference) { _, _ in model.historyDraftChanged(); inputError = nil }
        .fileExporter(isPresented: $exporting, document: exportFile, contentTypes: [exportType], defaultFilename: exportName) { result in
            switch result { case .success: finishExport(.succeeded, fileRequest); case .failure: finishExport(.failed, fileRequest) }
        } onCancellation: { finishExport(.cancelled, fileRequest) }
        .onAppear { visible = true; session = UUID() }
        .task { await model.load() }
        .onDisappear { visible = false; session = UUID(); actionTask?.cancel(); actionTask = nil; fileFlow.dismiss(); exporting = false; exportFile = nil; model.disappear() }
    }
    private var dailyEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("新建手工日摘要") { draft = .init(); model.draftChanged() }.disabled(blocked).accessibilityIdentifier("optionDailyNew")
                Button("载入合成日摘要") {
                    do { draft = try .synthetic(); model.draftChanged() }
                    catch { inputError = "合成模板未能建立。" }
                }.disabled(blocked).accessibilityIdentifier("optionDailyTemplate")
                Button("计算日摘要") {
                    do { let input = try draft.build(); perform { await model.calculateDaily(input) } }
                    catch { inputError = "请填写日期、报价、数量与来源。时间需含时区，缺失时不会自动补零或取最新。" }
                }.disabled(blocked).accessibilityIdentifier("optionDailyCalculate")
                Button("保存日摘要") { perform { _ = await model.saveDaily() } }.disabled(!model.canSaveDaily || fileFlow.isBusy).accessibilityIdentifier("optionDailySave")
            }
            Text(draft.origin == .synthetic ? "SYNTHETIC · 修改合成模板仍是合成研究。" : "MANUAL · 以下均为你声明的离线假设。")
                .foregroundStyle(draft.origin == .synthetic ? .orange : .secondary).accessibilityIdentifier("optionDailyOrigin")
            if let report = model.dailyReport { dailyResult(report) }
            GroupBox("日期、来源与标的") {
                VStack(alignment: .leading, spacing: 10) {
                    row("标的", $draft.symbol, "optionDailySymbol"); row("会话日（纽约 YYYY-MM-DD）", $draft.session)
                    row("评估时刻（ISO 8601，含时区）", $draft.asOf)
                    Toggle("我声明评估时刻就是该会话的收盘时点（离线假设）", isOn: $draft.declaredClose).disabled(blocked)
                    row("来源说明", $draft.sourceReference); row("本次声明覆盖范围", $draft.declaredScope)
                    Toggle("本次数据不完整，仅保留部分链摘要", isOn: $draft.partial).disabled(blocked)
                    HStack { row("标的 Bid（USD/股）", $draft.underlyingBid); row("标的 Ask（USD/股）", $draft.underlyingAsk) }
                    HStack { row("r（小数年利率）", $draft.rate); row("q（连续股息率）", $draft.dividendYield) }
                    row("共同报价时刻（可空则未知）", $draft.quotedAt); row("共同接收时刻（可空则未知）", $draft.receivedAt)
                    HStack { row("四合约共同 Bid 数量（张）", $draft.bidSize); row("共同 Ask 数量（张）", $draft.askSize); row("报价 tick（USD/股）", $draft.tick) }
                    Text("这些明确的共同时间、数量与 tick 适用于本页全部四份报价。没有逐合约成交量或独立 OI 发布时间的输入时，它们保持未知。标准 100 股交割是本地手工假设，不是交易所资格证明。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            expiry("近到期 · 同一行权价的 Call / Put", $draft.near)
            expiry("远到期 · 同一行权价的 Call / Put", $draft.far)
        }
    }
    private var historyEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("计算 252 日合成历史示例") { perform { await model.syntheticHistory() } }
                    .disabled(blocked).accessibilityIdentifier("optionHistorySynthetic")
                Button("保存历史分析") { perform { _ = await model.saveHistory() } }
                    .disabled(!model.canSaveHistory || fileFlow.isBusy).accessibilityIdentifier("optionHistorySave")
            }
            Text("合成示例明确包含 252 个前序会话与当前日；它使用合成工作日历，不是交易所日历。单到期代理、缺日或无有效本地 IV 的记录不会替代有效 IV30。")
                .font(.caption).foregroundStyle(.secondary)
            if let report = model.historyReport { historyResult(report) }
            GroupBox("使用自己的已保存日摘要") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("先打开或计算一份当前日摘要，再填写完整声明会话清单（每行 YYYY-MM-DD，含当前日）。程序只读取同标的的已保存前序日摘要，不补行情或缺日。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(model.dailyReport.map { "当前：\($0.input.symbol) · \($0.input.session.iso8601)" } ?? "尚无已核对的当前日摘要")
                    TextEditor(text: $calendarText).font(.body.monospaced()).frame(height: 110).border(.secondary.opacity(0.25))
                        .disabled(blocked).accessibilityLabel("声明会话日期，每行一个").accessibilityIdentifier("optionHistoryCalendar")
                    row("日历来源／假设说明", $calendarReference)
                    Button("核对已保存历史") {
                        do {
                            let days = try calendarText.split(whereSeparator: \.isNewline).map { try MarketDate(iso8601: String($0).trimmingCharacters(in: .whitespaces)) }
                            let reference = calendarReference
                            perform { await model.calculateSavedHistory(sessions: days, reference: reference) }
                        } catch { inputError = "日期清单无效，必须使用 YYYY-MM-DD；不会推定缺失会话。" }
                    }.disabled(blocked || model.dailyReport == nil || calendarReference.trimmingCharacters(in: .whitespaces).isEmpty)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
    private var savedCatalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report = model.dailyReport, model.savedDailyID != nil { dailyResult(report) }
            if let report = model.historyReport, model.savedHistoryID != nil { historyResult(report) }
            GroupBox("日摘要目录 · 仅显示身份，打开后才发布数值") {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.dailyListError { Text(error).foregroundStyle(.red) }
                    else if model.dailySummaries.isEmpty { Text("暂无已读取的日摘要").foregroundStyle(.secondary) }
                    ForEach(model.dailySummaries) { item in
                        HStack {
                            Text("\(item.symbol) · \(item.session.iso8601) · \(item.origin == .synthetic ? "合成" : "手工") · \(item.contractCount) 合约")
                            Spacer()
                            Button("打开并核对") { perform { await model.openDaily(item.id) } }.disabled(blocked)
                                .accessibilityIdentifier("optionDailyOpen-\(item.id.uuidString)")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("历史报告目录 · 保留原窗口与来源") {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.historyListError { Text(error).foregroundStyle(.red) }
                    else if model.historySummaries.isEmpty { Text("暂无已读取的历史报告").foregroundStyle(.secondary) }
                    ForEach(model.historySummaries) { item in
                        HStack {
                            Text("\(item.symbol) · \(item.session.iso8601) · \(item.origin == .synthetic ? "合成" : "手工")")
                            Spacer()
                            Button("打开并核对") { perform { await model.openHistory(item.id) } }.disabled(blocked)
                                .accessibilityIdentifier("optionHistoryOpen-\(item.id.uuidString)")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
    private func dailyResult(_ report: OptionDailyReport) -> some View {
        GroupBox("已核对日摘要") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("\(report.input.symbol) · \(report.input.session.iso8601)").font(.headline)
                    Spacer(); Text(report.containsSynthetic ? "合成研究" : "手工研究").foregroundStyle(.orange)
                }
                Text("IV30：\(percent(report.iv30)) · \(dailyState(report.state))").font(.title3.bold()).accessibilityIdentifier("optionDailyResult")
                Text("来源：\(report.input.source.reference)\n覆盖：\(report.input.declaredScope)").font(.caption).textSelection(.enabled)
                Text("合约 \(report.contractSummaries.count) · 成交量 \(report.chainSummary.totalVolume.map(String.init) ?? "未知") · OI \(report.chainSummary.totalOpenInterest.map(String.init) ?? "未知")")
                ForEach(report.contractSummaries, id: \.contractID) { value in
                    Text("\(value.contractID) · Mid \(value.closingMid?.decimalString ?? "不可用") · IV \(percent(value.canonicalIV)) · Delta \(number(value.canonicalDelta)) · \(dailyState(value.state))").font(.caption)
                }
                ForEach(Array(report.limitations.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                Button("导出已核对日摘要 Markdown…") { exportDaily(report) }.disabled(blocked).accessibilityIdentifier("optionDailyReadableExport")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func historyResult(_ report: OptionVolatilityHistoryReport) -> some View {
        GroupBox("已核对历史位置") {
            VStack(alignment: .leading, spacing: 9) {
                Text(report.containsSynthetic ? "SYNTHETIC · 合成历史，不能据此推断真实胜率" : "MANUAL · 手工声明历史，不是供应商准入").foregroundStyle(.orange)
                Text("IV Rank：\(number(report.ivRank)) · IV Percentile：\(number(report.ivPercentile))").font(.title3.bold()).accessibilityIdentifier("optionHistoryResult")
                Text("\(historyState(report.state)) · 有效 \(report.validDays) / \(report.requiredDays) 日 · 当前 IV30 \(percent(report.currentIV30))")
                    .accessibilityIdentifier("optionHistoryCoverage")
                Chart(Array(report.window.enumerated()), id: \.offset) { item in
                    if let value = item.element.iv30 { LineMark(x: .value("声明会话序号", item.offset), y: .value("IV30 %", value * 100)) }
                }.frame(height: 180).accessibilityLabel("已核对前序日 IV30，缺失日期不绘制替代值")
                Text("不同数据系列已排除 \(model.excludedHistoryCount) 条；窗口缺日仍按缺失处理，重复版本不自动择一。").font(.caption).foregroundStyle(.secondary)
                Text("来源：\(report.input.calendar.source.reference) · 当前 \(report.input.current.input.session.iso8601)").font(.caption).textSelection(.enabled)
                ForEach(Array(report.limitations.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("导出历史 CSV…") { exportHistory(report, csv: true) }.disabled(blocked)
                    Button("导出历史 Markdown…") { exportHistory(report, csv: false) }.disabled(blocked)
                }
                Text("CSV / Markdown 仅为可读报告，不能导回恢复；完整恢复请使用“期权归档”的 ZIP。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func expiry(_ title: String, _ value: Binding<OptionDailyExpiryDraft>) -> some View {
        GroupBox(title) {
            VStack(spacing: 9) {
                HStack { row("到期日 YYYY-MM-DD", value.date); row("确切到期时刻（含时区）", value.settlementAt) }
                row("Call / Put 共同行权价（USD）", value.strike)
                HStack { row("Call Bid", value.callBid); row("Call Ask", value.callAsk); row("Put Bid", value.putBid); row("Put Ask", value.putAsk) }
            }.padding(6)
        }
    }
    private func row(_ title: String, _ text: Binding<String>, _ id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).accessibilityIdentifier(id)
        }.frame(maxWidth: .infinity, alignment: .leading).disabled(blocked)
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        let token = session
        actionTask?.cancel()
        actionTask = Task { guard visible, session == token, !Task.isCancelled else { return }; await action() }
    }
    private func beginExport(_ text: String, name: String, csv: Bool) {
        guard !blocked, visible, fileFlow.begin() != nil else { return }
        exportMessage = nil; exportFile = .init(Data(text.utf8)); exportName = name
        exportType = csv ? .commaSeparatedText : .plainText; exporting = true
    }
    private func finishExport(_ outcome: ResearchFileRequestFlow.Outcome, _ id: UUID?) {
        guard visible, fileFlow.receive(outcome, for: id) else { return }
        switch outcome {
        case .succeeded: exportMessage = "可读报告已导出；它不是恢复归档。"
        case .cancelled: exportMessage = "导出已取消。"
        case .failed: exportMessage = "导出未完成，请核对所选位置与权限。"
        }
        fileFlow.finish(for: id); exportFile = nil
    }
    private func exportDaily(_ report: OptionDailyReport) {
        let lines = report.contractSummaries.map { "\($0.contractID): Mid \($0.closingMid?.decimalString ?? "NA"), IV \(percent($0.canonicalIV)), Delta \(number($0.canonicalDelta)), \(dailyState($0.state))" }
        let text = "# 离线期权日摘要\n\n\(report.input.symbol) · \(report.input.session.iso8601) · \(report.containsSynthetic ? "SYNTHETIC" : "MANUAL")\n\nIV30: \(percent(report.iv30))\n状态: \(dailyState(report.state))\n来源: \(report.input.source.reference)\n覆盖: \(report.input.declaredScope)\n模型: \(report.input.methodVersion)\n\n" + lines.joined(separator: "\n") + "\n\n" + report.limitations.joined(separator: "\n") + "\n\n可读报告，不可恢复。\n"
        beginExport(text, name: "options-daily.md", csv: false)
    }
    private func exportHistory(_ report: OptionVolatilityHistoryReport, csv: Bool) {
        let text: String
        if csv {
            text = "session,iv30,origin,method\n" + report.window.map {
                "\($0.session.iso8601),\($0.iv30.map { String($0) } ?? ""),\(report.containsSynthetic ? "SYNTHETIC" : "MANUAL"),\(report.input.methodVersion)"
            }.joined(separator: "\n") + "\n"
        } else {
            text = "# 离线波动率历史\n\n\(report.input.current.input.symbol) · \(report.input.current.input.session.iso8601) · \(report.containsSynthetic ? "SYNTHETIC" : "MANUAL")\n\nIV Rank: \(number(report.ivRank))\nIV Percentile: \(number(report.ivPercentile))\n\(historyState(report.state)) · \(report.validDays)/\(report.requiredDays)\n日历来源: \(report.input.calendar.source.reference)\n模型: \(report.input.methodVersion)\n\n" + report.limitations.joined(separator: "\n") + "\n\n可读报告，不可恢复。\n"
        }
        beginExport(text, name: csv ? "options-history.csv" : "options-history.md", csv: csv)
    }
}
private func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "不可用" }
private func number(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "不可用" }
private func dailyState(_ state: OptionDailyState) -> String {
    switch state {
    case .available: "可用（离线研究）"
    case .partialChain: "覆盖不完整"
    case .unknownQuoteTime: "报价时刻未知"
    case .staleQuote: "报价已陈旧"
    case .quoteSkew: "时间偏差超限"
    case .invalidQuote: "报价无效"
    case .missingTick: "缺 tick"
    case .missingATMCallOrPut: "缺同价 Call / Put"
    case .missingCanonicalIV: "缺本地规范 IV"
    case .noBracket: "30 日没有双侧到期包围"
    case .numericFailure: "数值校验失败"
    default: "收盘或日历证据不足"
    }
}
private func historyState(_ state: OptionVolatilityHistoryState) -> String {
    switch state {
    case .available: "历史门槛已满足"
    case .insufficientSessions: "声明会话不足 252 日"
    case .missingDay: "窗口内缺日摘要"
    case .unavailableDailyIV: "窗口内存在无效 IV30"
    case .excessiveSpan: "跨度超过 400 日"
    case .currentIVUnavailable: "当前 IV30 不可用"
    case .constantHistory: "历史极差为零，IV Rank 不可用"
    }
}
