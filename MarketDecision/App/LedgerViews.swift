import SwiftUI
import UniformTypeIdentifiers
import AppComposition
import CoreDomain
import PortfolioEngine
import Persistence

struct LedgerPage: View {
    let workspace: WorkspaceModel
    let initialSection: String
    let initialAccountID: String?
    let onContinueToCalculation: ((String?) -> Void)?
    @State private var model: LedgerWorkspaceModel?
    @State private var failure = false
    @State private var attempt = UUID()
    init(workspace: WorkspaceModel, initialSection: String = "现金与批次", initialAccountID: String? = nil,
         onContinueToCalculation: ((String?) -> Void)? = nil) {
        self.workspace = workspace; self.initialSection = initialSection; self.initialAccountID = initialAccountID
        self.onContinueToCalculation = onContinueToCalculation
    }
    var body: some View {
        Group {
            if let model { LedgerWorkspaceContent(model: model, initialSection: initialSection,
                onContinueToCalculation: onContinueToCalculation) }
            else if failure {
                ContentUnavailableView("交易账本暂不可用", systemImage: "book.closed",
                    description: Text("本地账本未能通过检查。已有记录保留，不影响研究工作区。"))
                Button("重新打开") { attempt = UUID() }
            } else { ProgressView("正在打开本地交易账本…") }
        }
        .task(id: "\(workspace.isPrepared)-\(attempt)") {
            guard workspace.isPrepared else { return }
            do {
                failure = false
                if model == nil {
                    let ready = try await workspace.makeLedgerWorkspaceModel()
                    try Task.checkCancellation(); model = ready
                }
                await model?.load()
                if let initialAccountID { await model?.chooseAccount(initialAccountID) }
            } catch { if !Task.isCancelled { failure = true } }
        }
    }
}

private struct LedgerActionMapping: Identifiable, Equatable {
    var id = UUID()
    var source: String
    var action: LedgerCSVAction
}

private struct LedgerApproval: Identifiable {
    let id: UUID
    let revision: UUID
}

struct LedgerWorkspaceContent: View {
    @Bindable var model: LedgerWorkspaceModel
    let onContinueToCalculation: ((String?) -> Void)?
    @State private var section = "现金与批次"
    @State private var accountID = "local-" + UUID().uuidString
    @State private var accountName = ""
    @State private var accountExpanded = true
    @State private var accountDetailsExpanded = false
    @State private var basisMethod: LedgerCostBasisMethod = .fifo
    @State private var form = LedgerManualDraft()
    @State private var staged: [LedgerEvent] = []
    @State private var formError: String?
    @State private var correctionID = ""
    @State private var reversalTimestamp = ""
    @State private var reversalReason = ""
    @State private var reversalBatchID = ""
    @State private var csvText = ""
    @State private var sourceSystem = ""
    @State private var selectedCSVBytes: Data?
    @State private var selectedCSVDisplayBytes: Data?
    @State private var actionMappings = LedgerCSVAction.allCases.map { LedgerActionMapping(source: $0.rawValue, action: $0) }
    @State private var fields = LedgerCSVMapping.standard.fields
    @State private var parsedHeaders: [String] = []
    @State private var showClosedLots = false
    @State private var excludedRows: Set<Int> = []
    @State private var previewUsesCSV = false
    @State private var approval: LedgerApproval?
    @State private var confirmation = ""
    @State private var importing = false
    @State private var fileFlow = ResearchFileRequestFlow()
    @State private var fileTask: Task<Void, Never>?
    @State private var visible = false
    @State private var fileMessage: String?
    @State private var pageSession = UUID()
    @State private var accountCreation: UUID?
    @Environment(\.colorScheme) private var colorScheme

    init(model: LedgerWorkspaceModel, initialSection: String = "现金与批次", onContinueToCalculation: ((String?) -> Void)? = nil) {
        self.model = model; _section = State(initialValue: initialSection)
        self.onContinueToCalculation = onContinueToCalculation
        _form = State(initialValue: Self.newManualDraft())
    }
    private static func newManualDraft() -> LedgerManualDraft {
        var draft = LedgerManualDraft()
        draft.externalID = "manual-" + UUID().uuidString
        draft.openingLotID = "lot-" + UUID().uuidString
        return draft
    }

    private var lots: [LedgerLot] {
        (model.snapshot?.state.lots ?? []).filter { $0.accountID == model.selectedAccountID && !$0.isClosed }
    }
    private var events: [LedgerEvent] {
        (model.snapshot?.events ?? []).filter { $0.accountID == model.selectedAccountID }
    }
    private var options: [LedgerOptionVersion] {
        var values: [LedgerOptionVersion] = []
        for lot in lots {
            if case .option(let item) = lot.instrument, !values.contains(where: { $0.identity == item.identity }) { values.append(item) }
        }
        return values
    }
    private var csvSourceData: Data { selectedCSVBytes ?? Data(csvText.utf8) }
    private var headers: [String] { parsedHeaders }
    private var selectableLots: [LedgerLot] {
        (model.snapshot?.state.lots ?? []).filter { $0.accountID == model.selectedAccountID && (showClosedLots || !$0.isClosed) }
    }
    private var busy: Bool { model.isBusy || fileFlow.isBusy || accountCreation != nil }
    private var accountAccent: Color {
        colorScheme == .dark ? Color(red: 0.38, green: 0.78, blue: 0.72) : Color(red: 0.06, green: 0.43, blue: 0.41)
    }
    private var canCreateAccount: Bool {
        !busy && model.snapshot != nil && !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Keep the view and modifier groups in separate expressions for the Swift 6.1 compiler.
    var body: some View {
        draftObservedContent
        .onAppear { visible = true; pageSession = UUID(); accountExpanded = model.snapshot?.accounts.isEmpty != false }
        .onChange(of: model.snapshot?.accounts.count) { _, _ in accountExpanded = model.snapshot?.accounts.isEmpty != false }
        .onDisappear {
            visible = false; pageSession = UUID(); accountCreation = nil
            fileTask?.cancel(); fileTask = nil; fileFlow.dismiss(); approval = nil
            model.disappear()
        }
    }

    private var draftObservedContent: some View {
        workspaceObservedContent
        .onChange(of: csvText) { _, value in
            if Data(value.utf8) != selectedCSVDisplayBytes { selectedCSVBytes = nil; selectedCSVDisplayBytes = nil }
            excludedRows = []; invalidateDraft()
        }
        .onChange(of: actionMappings) { _, _ in invalidateDraft() }
        .onChange(of: sourceSystem) { _, _ in invalidateDraft() }
        .onChange(of: fields) { _, _ in invalidateDraft() }
        .onChange(of: correctionID) { _, _ in invalidateDraft() }
        .onChange(of: reversalTimestamp) { _, _ in invalidateDraft() }
        .onChange(of: reversalReason) { _, _ in invalidateDraft() }
        .onChange(of: reversalBatchID) { _, _ in invalidateDraft() }
    }

    private var workspaceObservedContent: some View {
        filePresentationContent
        .onChange(of: model.transferEpoch) { _, _ in
            accountCreation = nil; resetAccountDraft()
            fileTask?.cancel(); fileTask = nil; fileFlow.dismiss(); importing = false; approval = nil
            staged = []; correctionID = ""; reversalBatchID = ""; form = Self.newManualDraft()
            csvText = ""; selectedCSVBytes = nil; selectedCSVDisplayBytes = nil; parsedHeaders = []; excludedRows = []
        }
        .onChange(of: model.preview?.id) { _, id in if approval?.id != id { approval = nil } }
        .onChange(of: form) { _, _ in if !model.isBusy { invalidateDraft() } }
        .onChange(of: model.selectedAccountID) { _, _ in
            staged = []; correctionID = ""; approval = nil; reversalBatchID = ""
            form.lots = [:]; form.equityLots = [:]; form.existingOption = nil
        }
    }

    private var filePresentationContent: some View {
        let fileRequest = fileFlow.id
        return workspaceContent
        .sheet(item: $approval) { item in confirmationSheet(item) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
            guard visible, fileFlow.owns(fileRequest) else { return }
            guard case .success(let urls) = result, urls.count == 1, let url = urls.first else {
                finishFile(.failed, request: fileRequest); return
            }
            guard fileFlow.selectFile(for: fileRequest) else { return }
            fileTask = Task {
                if let bytes = await model.readSelectedCSV(url), let text = String(data: bytes, encoding: .utf8), visible, fileFlow.owns(fileRequest), !Task.isCancelled {
                    selectedCSVBytes = bytes; selectedCSVDisplayBytes = Data(text.utf8)
                    csvText = text; excludedRows = []; parsedHeaders = (try? LedgerCSV.parse(bytes).headers) ?? []
                    finishRead(succeeded: true, request: fileRequest)
                } else if visible, fileFlow.owns(fileRequest) {
                    finishRead(succeeded: false, request: fileRequest)
                }
            }
        } onCancellation: { finishFile(.cancelled, request: fileRequest) }
    }

    @ViewBuilder private var workspaceContent: some View {
        // Recovery must remain mounted while its coordinator temporarily clears
        // the snapshot. A failed read is never evidence of an empty ledger.
        if section == "导出与备份" {
            ledgerContent
        } else if let snapshot = model.snapshot {
            if snapshot.accounts.isEmpty { firstAccountContent }
            else { ledgerContent }
        } else { unavailableLedgerContent }
    }

    private var firstAccountContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "book.closed").font(.system(size: 24, weight: .medium))
                        .foregroundStyle(accountAccent).accessibilityHidden(true)
                    Text("建立你的投资账户").font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text("起个名字。期权页确认成交后，持仓与已实现盈亏会自动汇总。").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("账户名称").font(.callout.weight(.medium))
                    TextField("例如：我的美股账户", text: $accountName)
                        .textFieldStyle(.roundedBorder).controlSize(.regular)
                        .accessibilityLabel("账户名称").accessibilityIdentifier("ledgerAccountName")
                        .disabled(busy)
                    Text("本地记账 · 美元 USD · 无需连接券商")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { createAccount() } label: {
                    Text(accountCreation == nil ? "建立账户" : "正在建立…")
                        .frame(maxWidth: .infinity).padding(.vertical, 2)
                }.buttonStyle(.borderedProminent).tint(accountAccent).controlSize(.regular)
                    .disabled(!canCreateAccount).accessibilityIdentifier("ledgerCreateAccount")
                if let message = model.message, model.hasError {
                    Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ledgerMessage")
                    Button("重新载入") { Task { await model.load() } }.disabled(busy)
                        .accessibilityIdentifier("ledgerReload")
                }
                DisclosureGroup("高级设置", isExpanded: $accountDetailsExpanded) {
                    accountCostMethod.padding(.top, 8)
                }.font(.callout).foregroundStyle(.secondary).disabled(busy)
                    .accessibilityIdentifier("ledgerAccountDetails")
                if model.transfer != nil {
                    Button("已有账本备份？从备份恢复") { section = "导出与备份" }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(accountAccent).disabled(busy)
                        .accessibilityIdentifier("ledgerSetupRestore")
                }
            }
            .padding(24).frame(maxWidth: 440, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 24)
        }.accessibilityIdentifier("ledgerAccountSetup")
    }

    private var unavailableLedgerContent: some View {
        VStack(spacing: 16) {
            if model.hasError {
                ContentUnavailableView("暂时无法读取账户", systemImage: "book.closed",
                    description: Text(model.message ?? "已有记录保留，请重新载入。"))
                Button("重新载入") { Task { await model.load() } }.disabled(busy)
                    .accessibilityIdentifier("ledgerReload")
                if model.transfer != nil {
                    Button("从账本备份恢复") { section = "导出与备份" }.disabled(busy)
                        .accessibilityIdentifier("ledgerSetupRestore")
                }
            } else { ProgressView("正在读取本地账户…") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var ledgerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("交易账本").font(.system(size: 28, weight: .bold))
                    Text("本地 USD 账户 · 先预览再入账 · 事件可追溯").foregroundStyle(.secondary)
                }
                Spacer()
                if model.snapshot?.accounts.isEmpty == true {
                    Button("返回建立账户") { section = "现金与批次" }.disabled(busy)
                        .accessibilityIdentifier("ledgerBackToSetup")
                } else if let onContinueToCalculation {
                    Button("用已入账记录继续核算") { onContinueToCalculation(model.selectedAccountID) }
                        .disabled(busy || model.selectedAccountID == nil || model.preview != nil)
                        .accessibilityIdentifier("ledgerContinueCalculation")
                        .help("只使用已确认入账的记录；未提交的表单与 CSV 不计入核算。")
                }
                Button("重新载入") { Task { await model.load() } }.disabled(busy)
                    .accessibilityIdentifier("ledgerReload")
            }
            Label("记录先预览、确认后入账。出入金不计利润，权利金收入不等于已实现盈亏。", systemImage: "info.circle")
                .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if model.snapshot?.accounts.isEmpty == false { accountSection }
            if model.isBusy { ProgressView("正在校验本地账本…").controlSize(.small) }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("ledgerMessage")
            }
            Picker("账本内容", selection: $section) {
                ForEach(["现金与批次", "手工录入", "CSV 导入", "来源与审计", "导出与备份"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("ledgerSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch section {
                    case "手工录入": manualSection
                    case "CSV 导入": csvSection
                    case "来源与审计": auditSection
                    case "导出与备份":
                        if let transfer = model.transfer { LedgerTransferContent(model: transfer, reportID: nil) }
                    default: balancesSection
                    }
                    if section != "导出与备份", let preview = model.preview { previewSection(preview) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }.padding(24)
    }

    private var accountSection: some View {
        GroupBox("账户") {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot = model.snapshot, !snapshot.accounts.isEmpty {
                    HStack {
                        Picker("当前账户", selection: Binding(get: { model.selectedAccountID ?? "" }, set: { id in
                            staged = []; correctionID = ""; form.lots = [:]; approval = nil
                            Task { await model.chooseAccount(id) }
                        })) {
                            ForEach(snapshot.accounts) { Text($0.name + " · " + $0.costBasisMethod.rawValue).tag($0.id) }
                        }.disabled(busy).accessibilityIdentifier("ledgerAccount")
                        Text("USD").foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("新增本地账户", isExpanded: $accountExpanded) {
                    HStack {
                        TextField("账户名称", text: $accountName).textFieldStyle(.roundedBorder).accessibilityIdentifier("ledgerAccountName")
                        Button("建立账户") { createAccount() }.disabled(!canCreateAccount)
                            .accessibilityIdentifier("ledgerCreateAccount")
                    }.disabled(busy).padding(.top, 8)
                    Button { accountDetailsExpanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: accountDetailsExpanded ? "chevron.down" : "chevron.right")
                            Text("账户标识与成本口径")
                            Spacer()
                        }.font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("ledgerAccountDetails")
                        .accessibilityValue(accountDetailsExpanded ? "已展开" : "已收起")
                    if accountDetailsExpanded {
                        TextField("账户标识", text: $accountID).textFieldStyle(.roundedBorder).accessibilityIdentifier("ledgerAccountID")
                        accountCostMethod
                    }
                    Text("默认使用 FIFO。账户标识自动生成；有交易后成本方法锁定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }

    private var accountCostMethod: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("成本方法", selection: $basisMethod) {
                Text("先买先卖（默认）").tag(LedgerCostBasisMethod.fifo)
                Text("指定批次").tag(LedgerCostBasisMethod.specificLot)
            }.accessibilityIdentifier("ledgerAccountCostMethod")
            Text("用于卖出时匹配买入成本；有交易后锁定。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resetAccountDraft() {
        accountName = ""; accountID = "local-" + UUID().uuidString
        basisMethod = .fifo; accountDetailsExpanded = false
    }

    private func createAccount() {
        guard visible, canCreateAccount else { return }
        let account = LedgerAccount(id: accountID, name: accountName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    costBasisMethod: basisMethod)
        let session = pageSession, epoch = model.transferEpoch, request = UUID()
        accountCreation = request
        Task {
            defer { if accountCreation == request { accountCreation = nil } }
            guard visible, pageSession == session, model.transferEpoch == epoch,
                  accountCreation == request, !Task.isCancelled else { return }
            await model.createAccount(account)
            guard visible, pageSession == session, model.transferEpoch == epoch,
                  accountCreation == request, !Task.isCancelled, !model.hasError,
                  model.snapshot?.accounts.contains(account) == true else { return }
            resetAccountDraft(); accountExpanded = false
        }
    }

    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let account = model.selectedAccountID, let snapshot = model.snapshot {
                GroupBox("账本现金") {
                    Text((snapshot.state.cashByAccount[account]?.decimalString ?? "未提供") + " USD")
                        .font(.title2.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading).padding(8).accessibilityIdentifier("ledgerCash")
                }
                Text("未平仓批次").font(.headline)
                if lots.isEmpty { Text("没有未平仓批次。可从手工录入或 CSV 导入开始。 ").foregroundStyle(.secondary) }
                ForEach(lots) { lot in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lot.instrument.label).font(.headline)
                            Text(lot.id).font(.caption.monospaced()).textSelection(.enabled)
                            Text("取得 " + lot.acquiredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(lot.quantityRemaining.decimalString + (lot.side == .long ? " · 多头" : " · 空头"))
                            Text("管理成本 " + lot.managementCostRemaining.decimalString + " USD")
                            if lot.hasNegativeEconomicBasis { Text("经济成本为负，保留原值").foregroundStyle(.orange).font(.caption) }
                        }.monospacedDigit()
                    }.padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            } else { ContentUnavailableView("先建立或选择账户", systemImage: "book.closed") }
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("事件类型", selection: $form.kind) {
                ForEach(LedgerManualKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("ledgerEventKind")
            GroupBox("时间与来源") {
                VStack(alignment: .leading, spacing: 8) {
                    line("生效时刻（须带时区）", text: $form.timestamp, prompt: "2026-01-02T14:30:00Z")
                    line("证据 / 记录依据", text: $form.evidence)
                    line("备注", text: $form.notes)
                    DisclosureGroup("来源标识与同刻顺序") {
                        line("原始同刻顺序（可空）", text: $form.sequence, prompt: "来源提供的非负整数")
                        line("来源系统", text: $form.sourceSystem)
                        line("外部交易标识", text: $form.externalID)
                        Text("手工记录标识已自动生成。导入券商成交时，应使用原交易标识避免重复。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            Toggle("显示已关闭历史批次供明确选择", isOn: $showClosedLots)
            manualFields
            DisclosureGroup("期权策略与多腿关联") {
                VStack(alignment: .leading, spacing: 8) {
                    line("展期组标识", text: $form.rollGroupID)
                    line("多腿组标识", text: $form.multiLegGroupID)
                    Toggle("记录策略目的与成功定义（期权开仓必填）", isOn: $form.strategyEnabled)
                    if form.strategyEnabled {
                        line("策略标识", text: $form.strategyID)
                        Picker("目的", selection: $form.purpose) {
                            Text("权利金收入").tag(LedgerStrategyPurpose.premiumIncome)
                            Text("接股").tag(LedgerStrategyPurpose.acquireShares)
                            Text("总回报").tag(LedgerStrategyPurpose.totalReturn)
                            Text("对冲 / 管理").tag(LedgerStrategyPurpose.hedgeOrManage)
                        }
                        line("成功定义", text: $form.successDefinition)
                        line("最大接股价（接股目的必填）", text: $form.maximumAcquisitionPrice)
                        Toggle("未被指派也计为成功", isOn: $form.unassignedCountsAsSuccess)
                    }
                    Text("展期应把平旧仓与开新仓加入同一批；组标识不会合并不同合约的成本。 ").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Button("加入本批") { stageEvent() }.disabled(!model.canPrepare)
                Button("预检本笔") { previewManual() }.disabled(!model.canPrepare)
                    .accessibilityIdentifier("ledgerPreviewManual")
                Button("新建空白记录") { form = Self.newManualDraft(); formError = nil; correctionID = "" }.disabled(busy)
            }
            if !staged.isEmpty {
                GroupBox("待预检批次 · \(staged.count) 笔") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(staged) { event in
                            HStack { Text(event.source.externalTransactionID ?? event.id); Text(event.payload.kind).foregroundStyle(.secondary); Spacer()
                                Button("移除") { staged.removeAll { $0.id == event.id }; invalidateDraft() }.disabled(busy)
                            }
                        }
                        Button("预检整批") { previewUsesCSV = false; Task { await model.prepareManual(events: staged) } }.disabled(!model.canPrepare)
                    }.padding(8)
                }
            }
            DisclosureGroup("修正已有事件（追加冲销与新记录）") {
                Picker("原事件", selection: $correctionID) {
                    Text("请选择").tag("")
                    ForEach(events.filter { !(model.snapshot?.state.reversedEventIDs.contains($0.id) ?? false) }) {
                        Text(($0.source.externalTransactionID ?? $0.id) + " · " + $0.payload.kind).tag($0.id)
                    }
                }
                Text("上方表单是新的替代记录，须使用新的外部交易标识。原事件及来源保留；不能直接改写历史行。 ").font(.caption).foregroundStyle(.secondary)
                Button("预检修正") { previewManual(correction: true) }.disabled(!model.canPrepare || correctionID.isEmpty)
            }
            if let formError { Text(formError).foregroundStyle(.red).font(.callout) }
        }.disabled(busy)
    }

    @ViewBuilder private var manualFields: some View {
        switch form.kind {
        case .deposit, .withdrawal, .dividend, .interest, .fee, .dividendWithholding, .interestWithholding, .otherTax:
            GroupBox("现金事件") { VStack(spacing: 8) { line("金额 USD（正数）", text: $form.amount); line("关联证券标识（可空）", text: $form.securityID) }.padding(8) }
        case .equityTrade, .optionTrade:
            GroupBox("成交与费用") {
                VStack(alignment: .leading, spacing: 8) {
                    if form.kind == .optionTrade { optionFields } else { securityFields }
                    Picker("方向", selection: $form.side) { Text("买入").tag(LedgerSide.buy); Text("卖出").tag(LedgerSide.sell) }
                    Picker("开平", selection: $form.effect) { Text("开仓").tag(LedgerTradeEffect.open); Text("平仓").tag(LedgerTradeEffect.close) }
                    line("数量（期权为合约张数）", text: $form.quantity); line("单位成交价", text: $form.unitPrice)
                    line("实际费用 USD（零也须填 0）", text: $form.fee)
                    if form.effect == .open { DisclosureGroup("批次标识（已自动生成）") { line("新批次标识", text: $form.openingLotID) } }
                    else { lotSelection(title: "指定批次及本次数量", values: $form.lots) }
                }.padding(8)
            }
        case .optionSettlement:
            GroupBox("期权生命周期") {
                VStack(alignment: .leading, spacing: 8) {
                    optionFields
                    Picker("事件", selection: $form.settlementAction) {
                        Text("到期").tag(LedgerSettlementAction.expiration); Text("主动行权").tag(LedgerSettlementAction.exercise)
                        Text("被指派").tag(LedgerSettlementAction.assignment)
                    }
                    positionSidePicker
                    line("合约张数", text: $form.quantity); line("实际费用 USD", text: $form.fee)
                    lotSelection(title: "期权批次及数量", values: $form.lots, optionOnly: true)
                    lotSelection(title: "交出股票的批次及数量", values: $form.equityLots, equityOnly: true)
                    line("取得股票的新批次标识（如适用）", text: $form.acquiredLotID)
                    Text("只按已确认合约交割；不会从 OCC 符号猜测 100 股。多证券交割请使用高级输入。 ").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        case .split:
            GroupBox("拆并股与零股") {
                VStack(alignment: .leading, spacing: 8) {
                    line("证券标识", text: $form.securityID); line("新股数 / 旧股数", text: $form.ratio); line("确认人", text: $form.confirmedBy)
                    Text("每个发生零股处置的原批次，必须同时填写处置新股数与官方现金；空白表示该批次没有零股处置。 ").font(.caption).foregroundStyle(.secondary)
                    ForEach(lots.filter { if case .equity(let s) = $0.instrument { return s.id == form.securityID }; return false }) { lot in
                        HStack { Text(lot.id).font(.caption); TextField("处置新股数", text: dictionary($form.fractionQuantities, lot.id)); TextField("官方现金 USD", text: dictionary($form.fractionCash, lot.id)) }.textFieldStyle(.roundedBorder)
                    }
                }.padding(8)
            }
        case .returnOfCapital:
            GroupBox("资本返还") { VStack(alignment: .leading, spacing: 8) { line("确认人", text: $form.confirmedBy); lotSelection(title: "每批实际返还金额 USD（不是数量）", values: $form.lots, equityOnly: true, allocationAmounts: true) }.padding(8) }
        case .cashInLieu:
            GroupBox("零股现金") { VStack(spacing: 8) { line("公司行动事件标识", text: $form.corporateActionEventID); line("官方现金 USD", text: $form.amount); line("实际费用 USD", text: $form.fee); lotSelection(title: "处置批次及数量", values: $form.lots, equityOnly: true) }.padding(8) }
        case .transferIn, .transferOut:
            GroupBox("转仓依据") {
                VStack(alignment: .leading, spacing: 8) {
                    securityFields; positionSidePicker; line("数量", text: $form.quantity)
                    line("事件时点市值 USD（须有依据）", text: $form.eventMarketValue)
                    if form.kind == .transferIn {
                        line("新批次标识", text: $form.openingLotID); line("原取得时刻（须带时区）", text: $form.acquiredAt)
                        line("历史管理成本 USD", text: $form.historicalCost); line("用户申报税务成本（可空）", text: $form.reportedTaxBasis)
                    } else { lotSelection(title: "转出批次及数量", values: $form.lots, equityOnly: true) }
                }.padding(8)
            }
        case .advanced:
            GroupBox("严格结构化公司行动 / 调整交割") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("适用于分拆、合并、调整交割篮子及其他完整 LedgerPayload。须填写官方证据、确认人、每个原批次、新数量与成本权重；缺项会拒绝。标准事件优先使用上方表单类型。 ").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $form.advancedPayload).font(.system(.caption, design: .monospaced)).frame(minHeight: 200)
                        .border(Color.secondary.opacity(0.25))
                }.padding(8)
            }
        }
    }

    private var securityFields: some View {
        VStack(spacing: 8) {
            line("稳定证券标识", text: $form.securityID); line("显示代码", text: $form.symbol)
            Picker("类别", selection: $form.securityKind) { Text("股票").tag(LedgerSecurityKind.stock); Text("ETF").tag(LedgerSecurityKind.etf) }
        }
    }
    private var positionSidePicker: some View {
        Picker("持仓方向", selection: $form.positionSide) { Text("多头").tag(LedgerPositionSide.long); Text("空头").tag(LedgerPositionSide.short) }
    }
    private var optionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("合约来源", selection: Binding(get: { form.existingOption?.identity ?? "" }, set: { id in form.existingOption = options.first { $0.identity == id } })) {
                Text("明确录入合约版本").tag("")
                ForEach(options, id: \.identity) { Text($0.occSymbol + " · " + $0.versionID).tag($0.identity) }
            }
            if let option = form.existingOption {
                Text("已选择 " + option.occSymbol + " · 倍数 " + option.quoteMultiplier.decimalString).font(.caption).textSelection(.enabled)
            } else {
                line("完整 OCC 符号（21 位，含空格）", text: $form.occSymbol); line("合约版本", text: $form.contractVersionID)
                line("版本生效时刻", text: $form.effectiveFrom); line("版本失效时刻（可空）", text: $form.effectiveTo)
                line("报价乘数", text: $form.quoteMultiplier); line("每张行权对价 USD", text: $form.exerciseConsideration)
                securityFields
                line("每张实际交割股数", text: $form.deliverableQuantity); line("每张交割现金 USD", text: $form.deliverableCash)
                line("交易截止时刻", text: $form.tradingEndsAt); line("行权截止时刻", text: $form.exerciseDeadline)
                line("交割时刻", text: $form.settlementAt); line("官方合约 / 调整备忘录", text: $form.memoReference)
                Picker("行权方式", selection: $form.exerciseStyle) { Text("美式").tag(LedgerExerciseStyle.american); Text("欧式").tag(LedgerExerciseStyle.european) }
                Text("时刻使用带时区的 ISO 8601 文本；当前简表只支持单一股票/ETF交割，成本权重为 1。 ").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lotSelection(title: String, values: Binding<[String:String]>, optionOnly: Bool = false, equityOnly: Bool = false, allocationAmounts: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold())
            Text(allocationAmounts ? "请逐批填写有依据的返还金额；空白不表示自动分配。" : "FIFO 可留空；指定批次账户必须选足本次数量。填写值后按指定批次处理，不会自动补选其他批次。 ").font(.caption).foregroundStyle(.secondary)
            ForEach(selectableLots.filter { lot in
                switch lot.instrument { case .option: return !equityOnly; case .equity: return !optionOnly }
            }) { lot in
                HStack {
                    Text(lot.instrument.label + " · " + lot.id).font(.caption).lineLimit(2)
                    Spacer(); Text("剩余 " + lot.quantityRemaining.decimalString).font(.caption)
                    TextField("本次值", text: dictionary(values, lot.id)).textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
        }
    }

    private var csvSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UTF-8 CSV，最多 8 MiB / 10,000 个逻辑数据行。字段及日期不自动猜测，费用缺失不当零。 ").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("选择 CSV…") { guard fileFlow.begin() != nil else { return }; fileMessage = nil; importing = true }.disabled(busy)
                Button("填入合成模板") { selectedCSVBytes = nil; selectedCSVDisplayBytes = nil; csvText = LedgerCSVMapping.standardTemplate; fields = LedgerCSVMapping.standard.fields; parsedHeaders = (try? LedgerCSV.parse(Data(LedgerCSVMapping.standardTemplate.utf8)).headers) ?? []; sourceSystem = "synthetic-example" }.disabled(busy)
                Button("解析编辑区表头") {
                    do { parsedHeaders = try LedgerCSV.parse(csvSourceData).headers; fileMessage = "表头已更新，请核对映射。" }
                    catch { parsedHeaders = []; fileMessage = "CSV 表头或行格式无效，请修正后再解析。" }
                }.disabled(busy || csvText.isEmpty)
                if fileFlow.isBusy { Button("取消读取") { fileTask?.cancel(); finishFile(.cancelled, request: fileFlow.id) } }
            }
            if let fileMessage { Text(fileMessage).font(.caption).foregroundStyle(.secondary) }
            line("稳定来源系统（用于去重）", text: $sourceSystem)
            TextEditor(text: $csvText).font(.system(.caption, design: .monospaced)).frame(minHeight: 190)
                .border(Color.secondary.opacity(0.25)).disabled(busy).accessibilityIdentifier("ledgerCSVText")
            GroupBox("明确字段映射") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(LedgerCSVField.allCases, id: \.self) { field in
                        Picker(fieldTitle(field), selection: Binding(get: { fields[field] ?? "" }, set: { value in
                            if value.isEmpty { fields.removeValue(forKey: field) } else { fields[field] = value }
                        })) {
                            Text("不映射").tag("")
                            if let current = fields[field], !headers.contains(current) { Text(current + "（待核对表头）").tag(current) }
                            ForEach(headers, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }.padding(8).disabled(busy)
            }
            DisclosureGroup("明确事件代码映射") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($actionMappings) { $row in
                        HStack {
                            TextField("原始事件代码", text: $row.source).textFieldStyle(.roundedBorder)
                            Picker("对应行为", selection: $row.action) { ForEach(LedgerCSVAction.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            Button("删除映射") { actionMappings.removeAll { $0.id == row.id } }
                        }
                    }
                    Button("新增代码映射") { actionMappings.append(.init(source: "", action: .deposit)) }
                    Text("同一原始代码只能映射一次。股票买入/卖出为对应开多/平多；复杂事件使用已验证的 PAYLOAD。 ").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8).disabled(busy)
            }
            Text(selectedCSVBytes == nil ? "将按编辑区的 UTF-8 内容保存来源；时间必须带时区。" : "尚未编辑所选文件；预览将保留它的原始 UTF-8 字节与哈希。").font(.caption).foregroundStyle(.secondary)
            Button("预检 CSV") { previewCSV() }.disabled(!model.canPrepare || busy || csvText.isEmpty || sourceSystem.isEmpty)
                .accessibilityIdentifier("ledgerPreviewCSV")
        }
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("批次审计与整批冲销") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("列出本地账本的全部导入批次。冲销追加历史记录；如果会破坏后续交易依赖，整批拒绝。 ").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.snapshot?.batches ?? [], id: \.id) { batch in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(batch.id).font(.caption.monospaced()); Spacer()
                                Button("选择冲销此批") { reversalBatchID = batch.id }.disabled(busy || batch.newEventIDs.isEmpty
                                    || !batch.newEventIDs.allSatisfy { id in events.contains { $0.id == id } })
                            }
                            Text("新增 \(batch.newEventIDs.count) · 重复 \(batch.duplicateRowCount) · 明确排除 \(batch.excludedRowCount)").font(.caption)
                            Text("源哈希 " + batch.sourceHash).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                    if !reversalBatchID.isEmpty {
                        Text("拟冲销批次 " + reversalBatchID).font(.caption.monospaced())
                        line("冲销生效时刻（须带时区）", text: $reversalTimestamp)
                        line("冲销原因", text: $reversalReason)
                        Button("预检整批冲销") {
                            previewUsesCSV = false
                            let id = reversalBatchID, time = reversalTimestamp, reason = reversalReason
                            Task { await model.prepareBatchReversal(batchID: id, timestamp: time, reason: reason) }
                        }.disabled(busy || !model.canPrepare)
                    }
                }.padding(.top, 8)
            }
            Text("来源与追加历史").font(.headline)
            if events.isEmpty { Text("还没有账本事件。 ").foregroundStyle(.secondary) }
            ForEach(events) { event in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(event.payload.kind).font(.headline); Spacer(); Text(event.effectiveAt.formatted()).font(.caption) }
                        Text("事件 " + event.id).font(.caption.monospaced()).textSelection(.enabled)
                        Text(event.source.sourceSystem + " · " + (event.source.externalTransactionID ?? "文件行 \(event.source.rowIndex ?? 0)"))
                        Text(event.source.evidence).font(.caption).textSelection(.enabled)
                        if let hash = event.source.fileHash { Text("文件 SHA-256 " + hash).font(.caption.monospaced()).textSelection(.enabled) }
                        if model.snapshot?.state.reversedEventIDs.contains(event.id) == true { Text("已冲销 · 原始来源保留").foregroundStyle(.orange) }
                        if !event.notes.isEmpty { Text(event.notes).font(.caption) }
                        if let posting = model.snapshot?.state.postings.first(where: { $0.eventID == event.id }) {
                            Text("现金变化 \(posting.cashChange.decimalString) USD · 费用 \(posting.transactionFee.decimalString) USD").font(.caption).monospacedDigit()
                        }
                        Button("作为修正对象") { correctionID = event.id; section = "手工录入" }
                            .disabled(busy || model.snapshot?.state.reversedEventIDs.contains(event.id) == true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
        }
    }

    private func previewSection(_ preview: LedgerImportPreview) -> some View {
        GroupBox("入账前预览") {
            VStack(alignment: .leading, spacing: 10) {
                Text("计划 \(preview.id.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
                if let validation = preview.validationMessage { Text(validation).font(.callout).foregroundStyle(.red) }
                previewProjection(preview)
                ForEach(preview.rows, id: \.rowIndex) { row in
                    previewRow(row)
                    Divider()
                }
                previewExclusionActions
                previewActions(preview)
            }.padding(8)
        }
    }

    @ViewBuilder private func previewProjection(_ preview: LedgerImportPreview) -> some View {
        if let state = preview.projectedState, let account = model.selectedAccountID, let cash = state.cashByAccount[account] {
            projectedPreviewContent(state: state, account: account, cash: cash, preview: preview)
        }
    }

    @ViewBuilder private func projectedPreviewContent(state: LedgerState, account: String, cash: Money,
                                                     preview: LedgerImportPreview) -> some View {
        let projectedLots: [LedgerLot] = state.lots.filter { $0.accountID == account && !$0.isClosed }
        let affected: Set<String> = Set(preview.rows.compactMap { $0.event?.id })
        let realizations: [LedgerRealization] = state.realizations.filter { affected.contains($0.eventID) }
        Text("预期账户 " + account).font(.caption.bold())
        Text("预期账本现金 " + cash.decimalString + " USD").font(.callout).monospacedDigit().accessibilityIdentifier("ledgerPreviewCash")
        ForEach(projectedLots) { lot in previewLot(lot) }
        ForEach(Array(realizations.enumerated()), id: \.offset) { _, realization in
            previewRealization(realization)
        }
    }

    private func previewLot(_ lot: LedgerLot) -> some View {
        let summary: String = "预期批次 \(lot.id) · \(lot.instrument.label) · \(lot.quantityRemaining.decimalString) · 管理成本 \(lot.managementCostRemaining.decimalString) USD"
        return Text(summary).font(.caption).monospacedDigit()
    }

    private func previewRealization(_ realization: LedgerRealization) -> some View {
        let summary: String = "本批实现管理盈亏 \(realization.lotID) · \(realization.pnl.decimalString) USD"
        return Text(summary).font(.caption).monospacedDigit()
    }

    private func previewRow(_ row: LedgerImportRow) -> some View {
        HStack(alignment: .top) {
            Text("第 \(row.rowIndex) 行").frame(width: 70, alignment: .leading)
            Text(row.disposition.rawValue).frame(width: 85, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let event = row.event { previewEvent(event) }
                Text(row.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if previewUsesCSV { previewExclusionToggle(rowIndex: row.rowIndex) }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private func previewEvent(_ event: LedgerEvent) -> some View {
        let title: String = event.payload.kind + " · " + (event.source.externalTransactionID ?? event.id)
        Text(title).font(.headline)
        Text("实际账户 " + event.accountID).font(.caption.bold())
        Text(event.effectiveAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
        Text(eventEconomics(event)).font(.callout).monospacedDigit()
        DisclosureGroup("完整事件与证据（日期为 2001-01-01 UTC 起秒数）") {
            Text(eventJSON(event)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func previewExclusionToggle(rowIndex: Int) -> some View {
        Toggle("本次排除", isOn: Binding(get: { excludedRows.contains(rowIndex) }, set: { skip in
            if skip { excludedRows.insert(rowIndex) } else { excludedRows.remove(rowIndex) }
            approval = nil
        })).toggleStyle(.checkbox).disabled(busy)
    }

    @ViewBuilder private var previewExclusionActions: some View {
        if previewUsesCSV {
            Text("已明确选择排除 \(excludedRows.count) 行。改变选择后必须重新预检；排除选择和原始文件一并留存，未选择的冲突仍阻止整批。 ").font(.caption).foregroundStyle(.secondary)
            Button("按当前排除选择重新预检") { previewCSV() }.disabled(busy)
        }
    }

    private func previewActions(_ preview: LedgerImportPreview) -> some View {
        HStack {
            Button("取消预览") { Task { await model.cancelPreview() } }.disabled(busy).accessibilityIdentifier("ledgerCancelPreview")
            Spacer()
            Button("审阅并确认入账…") {
                approval = .init(id: preview.id, revision: preview.targetRevision); confirmation = ""
            }.disabled(!model.canConfirm || busy || (previewUsesCSV && excludedRows != csvPreviewExclusions))
                .accessibilityIdentifier("ledgerReviewCommit")
        }
    }
    @State private var csvPreviewExclusions: Set<Int> = []
    private func confirmationSheet(_ item: LedgerApproval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认整批入账").font(.title2.bold())
            Text("记录将追加到当前本地账户。重复记录不再入账；修正保留原始审计记录。计划只对预检时的账本版本有效。 ")
            Text("计划 " + item.id.uuidString).font(.caption.monospaced())
            TextField("输入 入账 后确认", text: $confirmation).textFieldStyle(.roundedBorder).onSubmit { }.accessibilityIdentifier("ledgerConfirmText")
            if let message = model.message { Text(message).font(.callout) }
            HStack {
                Spacer()
                Button("返回检查") { approval = nil }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button("确认入账") { Task { _ = await model.confirm(id: item.id, expectedRevision: item.revision) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(confirmation != "入账" || !model.canConfirm || model.preview?.id != item.id)
                    .accessibilityIdentifier("ledgerCommit")
            }
        }.padding(24).frame(width: 560)
    }

    private func line(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        HStack { Text(title).frame(width: 210, alignment: .leading); TextField(prompt, text: text).textFieldStyle(.roundedBorder).onSubmit { }.accessibilityIdentifier("ledgerField-" + title) }
    }
    private func dictionary(_ values: Binding<[String:String]>, _ key: String) -> Binding<String> {
        Binding(get: { values.wrappedValue[key] ?? "" }, set: { values.wrappedValue[key] = $0 })
    }
    private func invalidateDraft() { approval = nil; model.draftChanged() }
    private func stageEvent() {
        guard let account = model.selectedAccountID else { return }
        do {
            let event = try form.event(accountID: account)
            guard !staged.contains(where: { $0.id == event.id }) else { throw LedgerError.duplicateIdentity }
            staged.append(event); formError = nil; form = Self.newManualDraft()
        } catch { formError = "本笔未加入。请核对时间、来源、明确费用、合约交割与批次证据，空白不代表零。" }
    }
    private func previewManual(correction: Bool = false) {
        guard let account = model.selectedAccountID else { return }
        do {
            let event = try form.event(accountID: account); formError = nil; previewUsesCSV = false
            let target = correctionID
            Task {
                if correction { await model.prepareCorrection(originalEventID: target, replacement: event) }
                else { await model.prepareManual(events: [event]) }
            }
        } catch { formError = "本笔未预检。请核对时间、来源、明确费用、合约交割与批次证据，空白不代表零。" }
    }
    private func previewCSV() {
        previewUsesCSV = true
        csvPreviewExclusions = excludedRows
        guard Set(actionMappings.map(\.source)).count == actionMappings.count,
              actionMappings.allSatisfy({ !$0.source.isEmpty }) else {
            fileMessage = "事件代码映射存在空白或重复，请明确修正后预检。"; return
        }
        let actions = Dictionary(uniqueKeysWithValues: actionMappings.map { ($0.source, $0.action) })
        let data = csvSourceData, mapping = LedgerCSVMapping(fields: fields, actions: actions), excluded = excludedRows, source = sourceSystem
        Task { await model.prepareCSV(data, sourceSystem: source, mapping: mapping, excludedRows: excluded) }
    }
    private func finishRead(succeeded: Bool, request: UUID?) {
        guard visible, fileFlow.owns(request), fileFlow.isReading else { return }
        fileMessage = succeeded ? "文件已载入编辑区，尚未入账。" : "文件未能载入，未写入账本。"
        fileFlow.finish(for: request); fileTask = nil
    }
    private func finishFile(_ outcome: ResearchFileRequestFlow.Outcome, request: UUID?) {
        guard visible, fileFlow.owns(request), fileFlow.receive(outcome, for: request) else { return }
        switch outcome {
        case .succeeded: fileMessage = "文件已载入编辑区，尚未入账。"
        case .cancelled: fileTask?.cancel(); fileMessage = "文件选择或读取已取消，未入账。"
        case .failed: fileMessage = "文件未能载入，请核对格式与访问权限。"
        }
        fileFlow.finish(for: request); fileTask = nil
    }
    private func eventEconomics(_ event: LedgerEvent) -> String {
        switch event.payload {
        case .cash(let cash): return cash.kind.rawValue + " · " + cash.amount.decimalString + " USD"
        case .trade(let trade):
            return trade.instrument.label + " · " + trade.side.rawValue + " / " + trade.effect.rawValue
                + " · 数量 " + trade.quantity.decimalString + " × 单价 " + trade.unitPrice.decimalString
                + " · 费用 " + trade.fee.decimalString + " USD"
        case .optionSettlement(let value):
            return value.contract.occSymbol + " · " + value.action.rawValue + " · " + value.quantity.decimalString
                + " 张 · 费用 " + value.fee.decimalString + " USD"
        case .split(let value): return value.securityID + " · 新 / 旧数量 " + value.ratio.decimalString + " · 零股处置 " + String(value.fractions.count) + " 批"
        case .returnOfCapital(let value): return value.allocations.sorted { $0.key < $1.key }.map { $0.key + "：" + $0.value.decimalString + " USD" }.joined(separator: "；")
        case .cashInLieu(let value): return "零股现金 " + value.cash.decimalString + " USD · 费用 " + value.fee.decimalString + " USD"
        case .transferIn(let value): return value.instrument.label + " · 转入 " + value.quantity.decimalString + " · 历史成本 " + value.historicalCost.decimalString + " USD · 当时市值 " + value.eventMarketValue.decimalString + " USD"
        case .transferOut(let value): return value.instrument.label + " · 转出 " + value.quantity.decimalString + " · 当时市值 " + value.eventMarketValue.decimalString + " USD"
        case .reorganization(let value): return value.kind.rawValue + " · 原批次 " + String(value.rows.count) + " · 请展开核对每项数量与权重"
        case .contractAdjustment(let value): return value.previous.identity + " → " + value.replacement.identity + " · 合约数量比例 " + value.contractQuantityRatio.decimalString
        case .reversal(let value): return "冲销原事件 " + value.originalEventID + " · 原因 " + value.reason
        }
    }
    private func eventJSON(_ event: LedgerEvent) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else { return "事件无法显示；请取消并重新预检。" }
        return text
    }
    private func fieldTitle(_ field: LedgerCSVField) -> String {
        switch field {
        case .timestamp: "时间 *"
        case .type: "事件代码 *"
        case .symbol: "证券代码"
        case .quantity: "数量"
        case .unitPrice: "单位价格"
        case .fee: "明确费用"
        case .amount: "现金金额"
        case .externalID: "外部交易标识"
        case .payloadJSON: "高级事件 JSON"
        case .providerSequence: "来源同刻顺序"
        case .rollGroupID: "展期组"
        case .multiLegGroupID: "多腿组"
        case .notes: "备注"
        }
    }
}
