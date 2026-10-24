import SwiftUI
import AppComposition
import CoreDomain
import PortfolioEngine
import Persistence

private struct InvestmentSaveApproval: Identifiable {
    let id: UUID
    let ledger: UUID
    let performance: UUID
}

/// Cheap value comparison only. Calendar parsing and validation belong to the
/// inspection worker, never to a date row's rendering path.
private struct InvestmentCalendarSelection: Equatable {
    let start: String
    let end: String
    let replaces: Bool
    let dates: String
    let evidence: PortfolioEvidenceDraft
    let reused: PerformanceCalendar?

    init(_ draft: InvestmentCalculationDraft) {
        start = draft.startDay; end = draft.endDay; replaces = draft.replacesCalendar
        dates = draft.replacementTradingDays; evidence = draft.replacementCalendarEvidence
        reused = draft.reusedRequest?.calendar
    }
}

/// One page-local draft against a fixed, already loaded ledger. Reusing evidence
/// never replaces its typed values with display strings or changes its quality.
struct InvestmentCalculationView: View {
    @Bindable var model: PortfolioWorkspaceModel
    let onSaved: (UUID) -> Void
    @State private var draft: InvestmentCalculationDraft?
    @State private var baseline: PortfolioPreparationBaseline?
    @State private var reusable: SavedPerformanceReport?
    @State private var rows: [InvestmentDayRequirement] = []
    @State private var inspectedDraft: InvestmentCalculationDraft?
    @State private var inspection = InvestmentInspectionModel()
    @State private var inspectionRequest: UUID?
    @State private var inspectedCalendar: InvestmentCalendarSelection?
    @State private var selectedDays: Set<String> = []
    @State private var requirementsByDay: [String: InvestmentDayRequirement] = [:]
    @State private var error: String?
    @State private var approval: InvestmentSaveApproval?
    @State private var confirmation = ""
    @State private var visible = false
    private let accent = Color(red: 0, green: 0.43, blue: 0.42)

    init(model: PortfolioWorkspaceModel, onSaved: @escaping (UUID) -> Void) {
        self.model = model; self.onSaved = onSaved
        _baseline = State(initialValue: model.preparationBaseline)
        _reusable = State(initialValue: model.origin == .frozen ? model.savedReport : nil)
        var empty = try? InvestmentCalculationDraft(accountID: model.selectedAccountID ?? "")
        empty?.replacesCalendar = true; empty?.usesNewFlowEvidence = true
        _draft = State(initialValue: empty)
    }

    private var current: Bool { baseline != nil && baseline == model.preparationBaseline }
    private var blocked: Bool { !current || model.isBusy }
    private var accountName: String {
        model.context?.ledger.accounts.first(where: { $0.id == draft?.accountID })?.name ?? "当前账户"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                heading
                if !current && !model.isBusy {
                    ContentUnavailableView("请重新载入账本", systemImage: "arrow.clockwise",
                        description: Text("账户、账本或页面会话已变化。这份草稿不能直接保存，请返回我的投资重新开始。"))
                        .accessibilityIdentifier("investmentCalculationStale")
                } else if draft != nil {
                    reuseSection
                    if let binding = Binding($draft) { inputSections(editable(binding)) }
                    previewSection
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("investmentCalculationError") }
                if let message = inspection.message { Text(message).foregroundStyle(.orange) }
                if let message = model.message {
                    Text(message).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                        .accessibilityIdentifier("investmentCalculationMessage")
                }
            }.padding(24).frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(item: $approval) { saveConfirmation($0) }
        .onAppear { visible = true }
        .onDisappear { visible = false; approval = nil; invalidateInspection() }
        .onChange(of: draft) { _, _ in
            approval = nil; error = nil
            if !model.isBusy { model.draftChanged() }
        }
        .onChange(of: model.preview?.id) { _, id in if approval?.id != id { approval = nil } }
        .onChange(of: model.inputEpoch) { _, _ in approval = nil; clearInspection() }
        .onChange(of: model.preparationBaseline) { _, _ in invalidateInspection() }
        .onChange(of: model.selectedAccountID) { _, _ in invalidateInspection() }
        .onChange(of: model.isBusy) { _, busy in if busy { invalidateInspection() } }
    }

    private func editable(_ value: Binding<InvestmentCalculationDraft>) -> Binding<InvestmentCalculationDraft> {
        Binding(get: { value.wrappedValue }, set: { updated in
            // Invalidate at the edit itself, even if A -> B -> A is coalesced
            // into a single SwiftUI update. Worker publication bypasses this.
            if updated != value.wrappedValue { invalidateInspection() }
            value.wrappedValue = updated
        })
    }

    private func invalidateInspection() {
        inspectionRequest = nil
        inspection.invalidate()
    }

    private func clearInspection() {
        invalidateInspection()
        rows = []; inspectedDraft = nil; inspectedCalendar = nil
        selectedDays = []; requirementsByDay = [:]
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("补齐数据，核算盈亏").font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("\(accountName) · USD").foregroundStyle(.secondary)
            Text("记账  →  补齐数据  →  核算并保存  →  分享").font(.callout).foregroundStyle(accent)
            Text("已有资料可以复用；缺项集中补齐。价格、时间和来源不会自动猜填。").foregroundStyle(.secondary)
        }
    }

    private var reuseSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let reusable, reusable.replayMatched, reusable.report.input.request.accountID == draft?.accountID {
                    let request = reusable.report.input.request
                    Text("可复用的已核对报告").font(.headline)
                    Text("\(request.calendar.tradingDays.first ?? "—") → \(request.calendar.tradingDays.last ?? "—") · \(request.days.count) 个估值日")
                    Text("原日期、来源和报价标记保持不变；新交易按当前账本重新计算。").font(.caption).foregroundStyle(.secondary)
                    Button("复用这份报告的资料") { reuse(request) }
                        .disabled(blocked).accessibilityIdentifier("investmentReuseEvidence")
                } else {
                    Text("首次核算：先提供期间日历，再补该期间的估值数据。以后可从保存的报告继续。").foregroundStyle(.secondary)
                }
                if draft?.reusedRequest != nil {
                    Label("原资料已带入，等待本次核算", systemImage: "doc.on.doc").foregroundStyle(accent)
                        .accessibilityIdentifier("investmentReusedStatus")
                    Button("从空白资料开始") { reset() }.disabled(blocked)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func inputSections(_ value: Binding<InvestmentCalculationDraft>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            calendarSection(value)
            dataSection(value)
            flowSection(value)
            Button("核算盈亏") { calculate() }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.regular)
                .disabled(blocked || inspection.isBusy).accessibilityIdentifier("investmentCalculate")
        }.disabled(blocked)
    }

    private func calendarSection(_ value: Binding<InvestmentCalculationDraft>) -> some View {
        GroupBox("核算期间") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("起始日期 YYYY-MM-DD", text: value.startDay).accessibilityIdentifier("investmentStartDay")
                    Text("至")
                    TextField("结束日期 YYYY-MM-DD", text: value.endDay).accessibilityIdentifier("investmentEndDay")
                }
                if value.wrappedValue.reusedRequest != nil {
                    Toggle("提供新的完整交易日历（扩展期间时需要）", isOn: value.replacesCalendar)
                }
                if value.wrappedValue.replacesCalendar {
                    Text("完整交易日列表，每行一个 YYYY-MM-DD。不能用自然日或仅有报价的日期替代。期间留空时使用该列表的首尾日期。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: value.replacementTradingDays).font(.system(.body, design: .monospaced)).frame(height: 90)
                        .accessibilityLabel("完整交易日列表").accessibilityIdentifier("investmentCalendarDays")
                    InvestmentEvidenceFields(title: "日历来源", draft: value.replacementCalendarEvidence, prefix: "investmentCalendar")
                } else if let old = value.wrappedValue.reusedRequest {
                    Text("复用 \(old.calendar.tradingDays.count) 个已声明交易日，可缩小期间；不会向外补日期。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private func dataSection(_ value: Binding<InvestmentCalculationDraft>) -> some View {
        let calendarMatches = inspectedCalendar == InvestmentCalendarSelection(value.wrappedValue)
        let originals = Dictionary((value.wrappedValue.reusedRequest?.days ?? []).map { ($0.day, $0) },
                                   uniquingKeysWith: { first, _ in first })
        return GroupBox("按日期补齐估值数据") {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("整理缺项并带入持仓") { inspect() }.disabled(inspection.isBusy)
                        .accessibilityIdentifier("investmentInspectMissing")
                    if inspection.isBusy {
                        ProgressView().controlSize(.small)
                        Button("取消整理") { invalidateInspection() }
                    } else if inspectedDraft == draft { Text("已按当前填写内容整理").font(.caption).foregroundStyle(.secondary) }
                    else { Text("修改期间或估值时刻后，再整理一次。").font(.caption).foregroundStyle(.secondary) }
                }
                Text("新日期先填估值时刻，再点击整理，即可列出那一刻实际持有的标的。旧资料按原值保留；有记录不等于价格已合格。")
                    .font(.caption).foregroundStyle(.secondary)
                if inspectedDraft == draft {
                    ForEach(rows) { row in
                        HStack(alignment: .top) {
                            Text(row.day).monospacedDigit()
                            Text(row.reason ?? "\(row.instrumentIDs.count) 个持仓标的；\(row.missingInstrumentIDs.count) 个缺原会话或报价记录")
                                .foregroundStyle(row.reason == nil ? Color.secondary : Color.orange)
                        }.font(.caption)
                    }
                }
                if calendarMatches {
                    ForEach(value.supplementalDays) { day in
                        if selectedDays.contains(day.wrappedValue.day) {
                            InvestmentDayFields(draft: day, original: originals[day.wrappedValue.day],
                                instruments: requirementsByDay[day.wrappedValue.day]?.instrumentIDs ?? [],
                                inspecting: inspection.isBusy, inspect: inspect)
                        }
                    }
                } else if !value.wrappedValue.supplementalDays.isEmpty {
                    Text("期间或日历已变化，请重新整理。已填资料会保留。").font(.caption).foregroundStyle(.secondary)
                }
                if let source = value.wrappedValue.reusedRequest {
                    DisclosureGroup("已保留的附加资料") {
                        Text("利率 \(source.rateCurves.count) 条 · 应计 \(source.accruals.count) 条 · 回合分配 \(source.roundAllocations.count) 条 · 收入归属 \(source.incomeAllocations.count) 条。基准和目标证据也保留原值；本页不改写这些资料。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(6)
        }
    }

    private func flowSection(_ value: Binding<InvestmentCalculationDraft>) -> some View {
        GroupBox("确认本次资金记录") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("我已核对本次期间全部出入金及转仓记录", isOn: value.externalFlowsComplete)
                    .accessibilityIdentifier("investmentConfirmFlows")
                Text("每次重新核算都需确认。未确认时可以查看缺口，但净盈亏和分享不会被标记为完整。").font(.caption).foregroundStyle(.secondary)
                if value.wrappedValue.reusedRequest?.flowCompletenessEvidence != nil {
                    Toggle("提供新的现金流核对依据", isOn: value.usesNewFlowEvidence)
                    if !value.wrappedValue.usesNewFlowEvidence {
                        Text("勾选上方确认后，将原核对依据用于本次声明；原文不会修改。范围或依据已变化时请提供新依据。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if value.wrappedValue.usesNewFlowEvidence {
                    InvestmentEvidenceFields(title: "现金流核对依据", draft: value.flowEvidence, prefix: "investmentFlow")
                }
            }.padding(6)
        }
    }

    @ViewBuilder private var previewSection: some View {
        if model.origin == .preview, let report = model.report, let plan = model.preview {
            let summary = InvestmentSummary(report: report)
            GroupBox("核算预览 · 尚未保存") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(InvestmentSummary.amountText(summary.netPnL) + " USD").font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .accessibilityIdentifier("investmentCalculationPnL")
                    Text("已实现 \(InvestmentSummary.amountText(summary.realizedPnL)) · 浮动变化 \(InvestmentSummary.amountText(summary.changeInUnrealizedPnL))")
                    if let reason = summary.unavailableReason { Text(reason).foregroundStyle(.orange) }
                    ForEach(report.daily.filter { $0.status != .available }, id: \.day) { day in
                        Text("\(day.day)：\(day.reason)").foregroundStyle(.orange)
                        ForEach(day.positions.filter { $0.marketValue == nil }) { position in
                            Text("\(position.instrumentID)：\(position.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if summary.usesStalePrices { Text("含 STALE 价格，仅用于账本估值。").foregroundStyle(.orange) }
                    Button("核对并保存报告…") {
                        confirmation = ""
                        approval = .init(id: plan.id, ledger: plan.ledgerRevision, performance: plan.performanceRevision)
                    }.disabled(!model.canSave || !current).accessibilityIdentifier("investmentSaveCalculation")
                    Text("保存后返回我的投资；盈亏完整对账后可使用分享卡片。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }

    private func saveConfirmation(_ value: InvestmentSaveApproval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存这次盈亏核算？").font(.title2.bold())
            Text("保存当前账本版本和完整输入，之后打开会重新核对。不会覆盖以前的报告。")
            TextField("输入“保存”确认", text: $confirmation).onSubmit { }
                .accessibilityIdentifier("investmentSaveConfirmation")
            HStack {
                Button("取消") { approval = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认保存") {
                    approval = nil
                    Task {
                        let saved = await model.save(id: value.id, ledgerRevision: value.ledger, performanceRevision: value.performance)
                        guard saved, visible, !Task.isCancelled, model.savedReport?.id == value.id else { return }
                        onSaved(value.id)
                    }
                }.disabled(confirmation != "保存" || !model.canSave || model.preview?.id != value.id || !current)
                    .accessibilityIdentifier("investmentConfirmSave")
            }
        }.padding(24).frame(width: 500)
    }

    private func reuse(_ request: PerformanceRequest) {
        guard current, !model.isBusy else { return }
        do {
            draft = try .init(accountID: model.selectedAccountID ?? "", reusing: request)
            clearInspection(); error = nil
        } catch { self.error = "这份报告不能用于当前账户。合成资料不能转换为个人账户证据。" }
    }
    private func reset() {
        guard current, !model.isBusy else { return }
        do {
            var empty = try InvestmentCalculationDraft(accountID: model.selectedAccountID ?? "")
            empty.replacesCalendar = true; empty.usesNewFlowEvidence = true
            draft = empty; clearInspection(); error = nil
        } catch { self.error = "请先选择有效账户。" }
    }
    private func inspect() {
        guard current, !model.isBusy, !inspection.isBusy, let value = draft,
              let baseline, let ledger = model.context?.ledger else { return }
        let request = UUID()
        inspectionRequest = request; error = nil
        Task {
            guard visible, inspectionRequest == request, draft == value,
                  model.preparationBaseline == baseline, !model.isBusy, !Task.isCancelled else { return }
            let result = await inspection.inspect(draft: value, baseline: baseline,
                                                  accounts: ledger.accounts, events: ledger.events)
            guard let result, visible, inspectionRequest == request, !Task.isCancelled,
                  self.baseline == result.baseline, model.preparationBaseline == result.baseline,
                  model.selectedAccountID == result.draft.accountID, !model.isBusy,
                  draft == result.sourceDraft else { return }
            inspectionRequest = nil
            rows = result.rows
            requirementsByDay = Dictionary(result.rows.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
            selectedDays = Set(result.rows.map(\.day))
            inspectedCalendar = InvestmentCalendarSelection(result.draft)
            draft = result.draft; inspectedDraft = result.draft
        }
    }
    private func calculate() {
        guard current, !model.isBusy, !inspection.isBusy, let draft, let baseline else { return }
        do {
            let request = try draft.build(calculatedAt: Date())
            error = nil
            Task { await model.prepare(request, baseline: baseline) }
        } catch { self.error = "请补齐表中的日期、报价时间、来源或现金流依据。不会沿用别日价格，也不会把缺项补成零。" }
    }
}

private struct InvestmentDayFields: View {
    @Binding var draft: PortfolioDayDraft
    let original: PerformanceDayInput?
    let instruments: [String]
    let inspecting: Bool
    let inspect: () -> Void
    var body: some View {
        GroupBox(draft.day) {
            VStack(alignment: .leading, spacing: 10) {
                if let original {
                    Text("估值时刻：\(original.valuationAt.formatted(.iso8601)) · 保留原精度")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("已带入 \(original.sessions.count) 份会话、\(original.prices.count) 条报价；原记录不改写。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("估值时刻（带时区，如 2026-01-02T21:00:00Z）", text: $draft.valuationAt)
                        .accessibilityIdentifier("investmentValuation-" + draft.day)
                    Button("按这个时刻列出持仓", action: inspect).disabled(inspecting)
                }
                ForEach($draft.quotes) { quote in
                    let quoteID = quote.wrappedValue.id
                    InvestmentQuoteFields(draft: quote, reusedSession: original?.sessions.first { $0.instrumentID == quote.wrappedValue.instrumentID }) {
                        draft.quotes.removeAll { $0.id == quoteID }
                    }
                }
                if !instruments.isEmpty {
                    Menu("补充某个持仓的报价") {
                        ForEach(instruments, id: \.self) { instrument in
                            Button(instrument) { draft.appendSupplementalQuote(instrumentID: instrument) }
                                .disabled(!draft.canAddSupplementalQuote(instrumentID: instrument))
                        }
                    }
                    Text("每个持仓保留一条待填报价；已添加的持仓请编辑上方记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}

private struct InvestmentQuoteFields: View {
    @Binding var draft: PortfolioQuoteDraft
    let reusedSession: PerformanceSession?
    let remove: () -> Void
    var body: some View {
        DisclosureGroup(draft.instrumentID + " · 补充报价") {
            VStack(alignment: .leading, spacing: 8) {
                if let reusedSession {
                    Text("沿用已核对会话 \(reusedSession.opensAt.formatted(.iso8601)) → \(reusedSession.closesAt.formatted(.iso8601))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("开市时刻（带时区）", text: $draft.opensAt)
                        TextField("收市时刻（带时区）", text: $draft.closesAt)
                    }
                    InvestmentEvidenceFields(title: "会话依据", draft: $draft.sessionEvidence, prefix: "investmentSession-" + draft.id)
                }
                TextField("报价时刻（带时区）", text: $draft.quoteAt)
                HStack {
                    TextField("Bid（可空）", text: $draft.bid)
                    TextField("Ask（可空）", text: $draft.ask)
                    TextField("Last（可空）", text: $draft.last)
                }
                Text("新增报价须为原始未复权 EOD；Last 回退仍会标记 STALE。其他口径请使用高级证据输入。")
                    .font(.caption).foregroundStyle(.secondary)
                InvestmentEvidenceFields(title: "报价来源", draft: $draft.priceEvidence, prefix: "investmentPrice-" + draft.id)
                Button("移除这条待填报价", action: remove)
            }.padding(.top, 6)
        }
    }
}

private struct InvestmentEvidenceFields: View {
    let title: String
    @Binding var draft: PortfolioEvidenceDraft
    let prefix: String
    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 7) {
                Picker("来源类型", selection: $draft.kind) {
                    Text("用户明确核对").tag(PerformanceEvidenceKind.userConfirmed)
                    Text("本地来源摘录").tag(PerformanceEvidenceKind.localDocument)
                }
                TextField("来源名称", text: $draft.source).accessibilityIdentifier(prefix + "Source")
                TextField("引用或版本", text: $draft.reference).accessibilityIdentifier(prefix + "Reference")
                TextField("取得该版本的时刻（带时区）", text: $draft.availableAt).accessibilityIdentifier(prefix + "AvailableAt")
                TextEditor(text: $draft.text).frame(height: 65).accessibilityLabel(title + "原文").accessibilityIdentifier(prefix + "Text")
                Text("原文仅保存本地；不会自动生成或修改证据。").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }.accessibilityIdentifier(prefix + "Details")
    }
}
