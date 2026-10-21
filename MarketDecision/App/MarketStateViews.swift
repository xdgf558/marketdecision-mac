import SwiftUI
import Charts
import AppComposition
import CoreDomain
import MarketAnalytics
import PortfolioEngine
import Persistence

struct MarketStatePage: View {
    let workspace: WorkspaceModel
    @State private var model: MarketStateWorkspaceModel?
    @State private var failed = false
    @State private var attempt = UUID()
    var body: some View {
        Group {
            if let model { MarketStateContent(model: model) }
            else if failed {
                ContentUnavailableView("市场工作区暂不可用", systemImage: "globe", description: Text("独立市场库未能打开，未显示旧分数。"))
                Button("重新打开") { attempt = UUID() }
            } else { ProgressView("正在打开离线市场工作区…") }
        }.task(id: "\(workspace.isPrepared)-\(attempt)") {
            guard workspace.isPrepared else { return }
            do {
                failed = false
                if model == nil { let ready = try await workspace.makeMarketStateWorkspaceModel(); try Task.checkCancellation(); model = ready }
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct MarketStateContent: View {
    @Bindable var model: MarketStateWorkspaceModel
    @State private var kind = MarketDocumentKind.marketState
    @State private var section = "总览与计算"
    @State private var draft = ""
    @State private var inputError: String?
    @State private var showInput = false
    @State private var session = UUID()
    @State private var form = UUID()
    @State private var templateTask: Task<Void, Never>?
    @State private var loadingTemplate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("市场状态与数据中心").font(.largeTitle.bold()).accessibilityIdentifier("marketTitle")
                    Text("离线研究 · 三分数、历史证据与交易时点归因").foregroundStyle(.secondary)
                }
                Spacer()
                Text("离线 / 合成输入").font(.caption.bold()).padding(9).background(.orange.opacity(0.12), in: Capsule())
            }
            Text("市场标签描述环境，不是买卖指令。当前不安装任何行情或宏观传输，不为缺失数据生成替代值。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("市场工作区内容", selection: $section) {
                Text("总览与计算").tag("总览与计算"); Text("数据与历史").tag("数据与历史")
                Text("已保存快照").tag("已保存快照"); Text("市场归档").tag("市场归档")
            }.pickerStyle(.segmented).accessibilityIdentifier("marketSections")
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? Color.red : Color.secondary).accessibilityIdentifier("marketMessage") }
            if let inputError { Text(inputError).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if section == "市场归档" { MarketStateArchiveContent(model: model) }
                    else if section == "已保存快照" { catalog }
                    else if section == "数据与历史" {
                        if let report = model.report { history(report); sources(report) }
                        else { Text("请先计算或打开一份市场快照；目录中的缓存分数不会用于展示。").foregroundStyle(.secondary) }
                    } else { input; results }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 20)
            }
        }.padding(28)
        .task { await model.load() }
        .onChange(of: model.report?.input.id) { _, _ in synchronizeInput() }
        .onChange(of: model.attribution?.id) { _, _ in synchronizeInput() }
        .onChange(of: section) { _, _ in templateTask?.cancel(); templateTask = nil; loadingTemplate = false; form = UUID() }
        .onDisappear { session = UUID(); templateTask?.cancel(); loadingTemplate = false; model.disappear() }
    }
    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("计算类型", selection: Binding(get: { kind }, set: { kind = $0; draft = ""; changed() })) {
                Text("市场三分数").tag(MarketDocumentKind.marketState)
                Text("历史交易归因").tag(MarketDocumentKind.tradeAttribution)
            }.pickerStyle(.segmented).disabled(!model.canEdit || model.isBusy || loadingTemplate).accessibilityIdentifier("marketKind")
            HStack {
                Button("载入完整合成示例") { loadTemplate(short: false) }
                    .disabled(!model.canEdit || model.isBusy || loadingTemplate).accessibilityIdentifier("marketDemo")
                Button("载入缺项合成示例") { loadTemplate(short: true) }
                    .disabled(!model.canEdit || model.isBusy || loadingTemplate || kind != .marketState).accessibilityIdentifier("marketMissingDemo")
                Button("计算并核对") { let text = draft, selected = kind; act { await model.calculateJSON(text, kind: selected) } }
                    .disabled(draft.isEmpty || !model.canEdit || model.isBusy || loadingTemplate).accessibilityIdentifier("marketCalculate")
                Button("保存冻结报告") { act { await model.save() } }.disabled(!model.canSave || loadingTemplate).accessibilityIdentifier("marketSave")
            }
            if model.isBusy || loadingTemplate {
                HStack { ProgressView().controlSize(.small); Text("正在核对完整历史输入…").font(.caption)
                    if model.canEdit { Button("取消发布") { templateTask?.cancel(); loadingTemplate = false; form = UUID(); model.cancelWork() } }
                }
            }
            DisclosureGroup("完整离线输入（JSON）", isExpanded: $showInput) {
                TextEditor(text: Binding(get: { draft }, set: { draft = $0; changed() }))
                    .font(.system(.caption, design: .monospaced)).frame(minHeight: 180, maxHeight: 300)
                    .disabled(!model.canEdit || loadingTemplate).accessibilityIdentifier("marketInput")
                Text("来源、发布/可得时刻、修订、交易日与方法都属于冻结输入。修改即清除旧结果；声明来源不授予供应商或历史分析资格。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var results: some View {
        if let report = model.report { current(report) }
        else if let report = model.attribution { trades(report) }
        else { Text("尚无已核对结果。载入合成示例或填写完整离线输入后显式计算。").foregroundStyle(.secondary).accessibilityIdentifier("marketEmpty") }
    }
    private func current(_ report: MarketStateReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            origin(report.containsSynthetic)
            Text("\(report.current.sessionDate) · \(report.current.confirmedLabel.title)").font(.title2.bold()).accessibilityIdentifier("marketRegime")
            Text("候选状态：\(report.current.rawLabel.title) · 连续确认 \(report.current.confirmationStreak) 日 · \(report.current.isClosedSession ? "已收盘会话" : "未收盘，不计连续确认")")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                scoreCard(report.current.heat); scoreCard(report.current.stress); scoreCard(report.current.sentiment)
            }
            Text(model.savedID == nil ? "尚未保存；仅使用本次明确输入" : "已冻结 · 完整输入重放核对通过")
                .font(.callout).accessibilityIdentifier("marketReplay")
            ForEach([report.current.heat, report.current.stress, report.current.sentiment], id: \.kind) { value in
                DisclosureGroup("\(scoreTitle(value.kind))：分项贡献与缺项") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(value.components, id: \.id) { component in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(component.title) · 分值 \(marketNumber(component.value)) · 贡献 \(marketNumber(component.contribution))")
                                Text("原权重 \(Double(component.originalWeightBps) / 100)% · 有效原子 \(component.validAtomCount)/\(component.atoms.count) · \(missing(component.missingReason))")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(component.atoms, id: \.id) { atom in
                                    Text("\(atom.id)：原值 \(marketNumber(atom.rawValue)) / 分位分数 \(marketNumber(atom.score)) · 独立历史 \(atom.independentHistoryCount) · \(missing(atom.missingReason))")
                                        .font(.caption).textSelection(.enabled)
                                }
                            }.padding(.vertical, 4)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("模型：\(report.modelReference.id) · \(report.modelReference.version)").font(.caption).textSelection(.enabled)
            limitations(report.limitations)
        }
    }
    private func scoreCard(_ score: MarketScoreResult) -> some View {
        GroupBox(scoreTitle(score.kind)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(marketNumber(score.value)).font(.largeTitle.monospacedDigit().bold())
                Text("有效权重 \(Double(score.effectiveWeightBps) / 100)%").font(.caption)
                Text("缺项 \(score.droppedComponents.count) / \(score.components.count)").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.accessibilityIdentifier("marketScore-" + score.kind.rawValue)
    }
    private func history(_ report: MarketStateReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("历史分数与状态").font(.title2.bold())
            Text("逐日仅使用当时可得修订；缺失不会延续上一日标签。展示历史是当前冻结输入的重放，不构成真实 PIT 准入。")
                .foregroundStyle(.secondary)
            Chart {
                ForEach(report.history, id: \.sessionDate) { day in
                    ForEach([day.heat, day.stress, day.sentiment], id: \.kind) { score in
                        if let value = score.value {
                            PointMark(x: .value("交易日", day.sessionDate), y: .value("分数", value))
                                .foregroundStyle(by: .value("指标", scoreTitle(score.kind))).symbolSize(8)
                        }
                    }
                }
            }.chartYScale(domain: 0...100).frame(height: 230).accessibilityIdentifier("marketHistoryChart")
            Text("有效收盘会话 \(report.diagnostics.eligibleSessionCount) · 三分数共同有效 \(report.diagnostics.commonValidDayCount) · 覆盖 \(marketPercent(report.diagnostics.coverage))")
            ForEach(Array(report.diagnostics.correlations.enumerated()), id: \.offset) { _, correlation in
                Text("\(scoreTitle(correlation.first)) / \(scoreTitle(correlation.second))：\(marketNumber(correlation.coefficient)) · 共同样本 \(correlation.commonCount)\(correlation.overlapWarning ? " · 指标可能存在重叠" : "")")
                    .font(.caption)
            }
            HStack { ForEach(report.diagnostics.frequencies, id: \.label) { item in Text("\(item.label.title)\n\(item.count) 日 / \(marketPercent(item.fraction))").font(.caption) } }
            DisclosureGroup("逐日标签记录") {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(report.history, id: \.sessionDate) { day in Text("\(day.sessionDate) · \(day.confirmedLabel.title) · 候选 \(day.rawLabel.title) · \(day.confirmationStreak) 日").font(.caption) }
                }
            }
        }
    }
    private func sources(_ report: MarketStateReport) -> some View {
        GroupBox("数据中心 · 来源与版本") {
            VStack(alignment: .leading, spacing: 9) {
                Text("评估截止：\(report.input.asOf.formatted(date: .numeric, time: .complete)) · \(report.input.calendarEvidence)").font(.caption).textSelection(.enabled)
                ForEach(report.input.series, id: \.key) { source in
                    DisclosureGroup("\(source.key.rawValue) · \(source.frequency.rawValue) · \(source.observations.count) 份观测版本") {
                        Text("\(source.sourceID) / \(source.feedID)\n单位 \(source.unit.rawValue) · 口径 \(source.basisVersion)\n\(source.methodology)\n总体：\(source.population ?? "不适用")")
                            .font(.caption).textSelection(.enabled)
                        ForEach(Array(source.observations.suffix(5).enumerated()), id: \.offset) { _, point in
                            Text("\(point.observationDate) · \(point.vintageID) · 原值 \(point.rawValue)\n发布 \(point.releasedAt.formatted(date: .numeric, time: .complete)) · 可得 \(point.availableAt.formatted(date: .numeric, time: .complete))")
                                .font(.caption).textSelection(.enabled)
                        }
                        Text("仅展开末五份原始版本；具体公式使用的窗口和修订保存在完整报告中。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func trades(_ report: MarketTradeAttributionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            origin(report.containsSynthetic)
            Text("开仓时市场状态归因").font(.title2.bold()).accessibilityIdentifier("marketAttributionTitle")
            Text("只有开仓时已知、完整重放核对的冻结市场快照参与分组；未知单列，不把今日标签回填历史。")
            ForEach(report.groupedStatistics) { group in
                GroupBox(group.label) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("回合 \(group.roundIDs.count) · 统计样本 \(group.statistics.eligibleN) · 已完成净损益 \(group.completedNetPnL?.decimalString ?? "不可用") USD")
                        Text("盈利 \(group.statistics.wins) / 亏损 \(group.statistics.losses) / 零损益 \(group.statistics.zeros)").font(.caption)
                        if let model = group.snapshotModel { Text("市场模型 \(model.id) · \(model.version)").font(.caption).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DisclosureGroup("逐回合证据") {
                ForEach(report.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.round.roundLotID) · \(row.label ?? "缺少可用市场快照")")
                        Text("\(row.openingEventID) · \(row.snapshotSession ?? "无历史日期") · \(row.gap?.rawValue ?? "已核对")").font(.caption).textSelection(.enabled)
                    }
                }
            }
            limitations(report.limitations)
        }
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("已保存历史快照").font(.title2.bold()); Spacer(); Button("刷新目录") { act { await model.load() } }.disabled(model.isBusy || !model.canEdit) }
            Text("目录只显示身份和日期；打开后先全量重算，核对通过才展示数值。冲突副本保留原冻结身份和字节。 ").font(.caption).foregroundStyle(.secondary)
            if let error = model.listError { Text(error).foregroundStyle(.red) }
            if model.saved.isEmpty { Text("尚无已保存快照。").foregroundStyle(.secondary).accessibilityIdentifier("marketCatalogEmpty") }
            ForEach(model.saved) { item in
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(item.kind == .marketState ? "市场快照" : "交易归因") · \(item.containsSynthetic ? "SYNTHETIC" : "离线记录")\(item.id != item.originalID ? " · 冲突副本" : "")")
                            Text("\(item.createdAt.formatted(date: .numeric, time: .standard)) · \(item.id.uuidString)").font(.caption).textSelection(.enabled)
                        }
                        Spacer()
                        Button("打开并重放") { act { await model.open(item); if model.savedID == item.id { section = "总览与计算" } } }
                            .disabled(model.isBusy || !model.canEdit).accessibilityIdentifier("marketOpen-" + item.id.uuidString)
                        Button("预检删除…", role: .destructive) { act { await model.prepareDelete(item.id); section = "市场归档" } }.disabled(!model.canPrepare)
                    }
                }
            }
        }
    }
    private func origin(_ synthetic: Bool) -> some View { Text(synthetic ? "SYNTHETIC · 合成研究，非真实市场" : "离线记录 · 未授予真实数据资格").font(.headline).foregroundStyle(.orange).accessibilityIdentifier("marketOrigin") }
    private func limitations(_ values: [String]) -> some View { DisclosureGroup("方法与限制") { ForEach(Array(values.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) } } }
    private func changed() { form = UUID(); model.draftChanged(); inputError = nil }
    private func synchronizeInput() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let report = model.report { kind = .marketState; if let data = try? encoder.encode(report.input) { draft = String(decoding: data, as: UTF8.self) } }
        else if let report = model.attribution { kind = .tradeAttribution; if let data = try? encoder.encode(report.input) { draft = String(decoding: data, as: UTF8.self) } }
    }
    private func loadTemplate(short: Bool) {
        changed(); loadingTemplate = true
        let selected = kind, token = session, edit = form
        templateTask = Task {
            do {
                let json = try await Task.detached {
                    if short {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        return String(decoding: try encoder.encode(MarketStateDemo.input(sessionCount: 5)), as: UTF8.self)
                    }
                    return try MarketStateWorkspaceModel.demoJSON(selected)
                }.value
                guard session == token, form == edit, !Task.isCancelled else { return }; draft = json; loadingTemplate = false
            } catch { guard session == token, form == edit, !Task.isCancelled else { return }; inputError = "合成输入未能建立。"; loadingTemplate = false }
        }
    }
    private func act(_ operation: @escaping @MainActor () async -> Void) { let token = session, edit = form; Task { guard session == token, form == edit else { return }; await operation() } }
}
private func scoreTitle(_ kind: MarketScoreKind) -> String { switch kind { case .heat: "市场热度"; case .stress: "市场压力"; case .sentiment: "市场情绪" } }
private func missing(_ reason: MarketMissingReason?) -> String { reason.map { "缺项：" + $0.rawValue } ?? "已核对" }
private func marketNumber(_ value: Double?) -> String { guard let value, value.isFinite else { return "不可用" }; return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
private func marketPercent(_ value: Double?) -> String { value.map { marketNumber($0 * 100) + "%" } ?? "不可用" }
