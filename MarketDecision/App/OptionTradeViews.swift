import SwiftUI
import AppComposition
import CoreDomain
import PortfolioEngine
import Persistence

/// An explicit execution sheet uses the SAME account ledger as My Investments.
/// Opening this sheet is the only point at which this flow opens that store.
struct OptionTradeSheet: View {
    let workspace: WorkspaceModel
    let opening: OptionLabInputDraft?
    let positionRequest: OptionPositionRequest?
    let onCommitted: (String) -> Void
    @State private var model: LedgerWorkspaceModel?
    @State private var failed = false
    @State private var attempt = UUID()
    @SceneStorage("investmentSelectedLedgerAccountID") private var preferredAccountID = ""
    @Environment(\.dismiss) private var dismiss

    init(workspace: WorkspaceModel, opening: OptionLabInputDraft?,
         positionRequest: OptionPositionRequest? = nil, onCommitted: @escaping (String) -> Void = { _ in }) {
        self.workspace = workspace; self.opening = opening
        self.positionRequest = positionRequest; self.onCommitted = onCommitted
    }

    var body: some View {
        Group {
            if let model {
                OptionTradeContent(model: model, opening: opening, positionRequest: positionRequest,
                    onCommitted: onCommitted, close: { dismiss() })
                    .interactiveDismissDisabled(model.isBusy)
            } else {
                VStack(spacing: 16) {
                    if failed {
                        Text("账户暂时无法读取，已有记录保留。")
                        Button("重新读取") { attempt = UUID() }
                    } else { ProgressView("正在读取本地期权持仓…") }
                    Button("关闭") { dismiss() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: 920, minHeight: 500, idealHeight: 620)
        .task(id: attempt) {
            do {
                failed = false
                let preferred = positionRequest?.accountID ?? preferredAccountID
                let ready = try await workspace.makeLedgerWorkspaceModel()
                try Task.checkCancellation()
                await ready.load()
                try Task.checkCancellation()
                if let positionRequest {
                    // Never reinterpret a missing requested account as the
                    // first account selected by the fresh ledger model.
                    guard ready.snapshot?.accounts.contains(where: { $0.id == positionRequest.accountID }) == true else {
                        throw OptionTradeEntryError.invalidAccount
                    }
                    await ready.chooseAccount(positionRequest.accountID)
                    try Task.checkCancellation()
                } else if !preferred.isEmpty, ready.snapshot?.accounts.contains(where: { $0.id == preferred }) == true {
                    await ready.chooseAccount(preferred)
                    try Task.checkCancellation()
                }
                model = ready
            } catch { if !Task.isCancelled { failed = true } }
        }
        .onChange(of: model?.selectedAccountID) { _, account in
            if let account { preferredAccountID = account }
        }
    }
}

private struct OptionTradeContent: View {
    @Bindable var model: LedgerWorkspaceModel
    let opening: OptionLabInputDraft?
    let positionRequest: OptionPositionRequest?
    let onCommitted: (String) -> Void
    let close: () -> Void
    @State private var entry: OptionTradeEntryDraft?
    @State private var entryRevision: UUID?
    @State private var confirmed = false
    @State private var started = false
    @State private var visible = false
    @State private var session = UUID()
    @State private var preparing: UUID?
    @State private var preparedEntry: OptionTradeEntryDraft?
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var showingLedger = false
    private let accent = Color(red: 0.06, green: 0.43, blue: 0.41)
    private var busy: Bool { model.isBusy || preparing != nil }
    private var lots: [LedgerLot] {
        (model.snapshot?.state.lots ?? []).filter {
            guard $0.accountID == model.selectedAccountID, !$0.isClosed else { return false }
            if case .option = $0.instrument { return true }; return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(showingLedger ? "行权 / 被指派" : (entry.map { title($0.action) } ?? "我的期权持仓")).font(.title2.bold())
                    Text(model.preview == nil ? "填写实际记录 → 核对预览 → 确认入账" : "核对以下记录，确认后同步到我的投资")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { close() }.disabled(busy).accessibilityIdentifier("optionTradeDone")
            }
            Divider()
            if showingLedger {
                LedgerWorkspaceContent(model: model, initialSection: "手工录入")
            } else if let snapshot = model.snapshot {
                if snapshot.accounts.isEmpty {
                    ContentUnavailableView("先建立一个账户", systemImage: "book.closed",
                        description: Text("回到“我的投资”填写账户名称，之后在这里记录实际成交。"))
                } else {
                    accountSelection(snapshot)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let entry {
                                if let preview = model.preview {
                                    previewContent(preview)
                                } else {
                                    OptionTradeEditor(draft: Binding(get: { self.entry ?? entry }, set: { value in
                                        guard self.entry?.id == entry.id, !busy else { return }; self.entry = value
                                    }), snapshot: snapshot, opening: opening).disabled(busy)
                                    Toggle(entry.action.verificationText, isOn: $confirmed)
                                        .toggleStyle(.checkbox).disabled(busy)
                                        .accessibilityIdentifier("optionTradeVerified")
                                    HStack {
                                        Button("返回持仓") { discardEntry() }.disabled(busy)
                                        Spacer()
                                        Button("下一步：核对入账") { prepare() }.buttonStyle(.borderedProminent).tint(accent)
                                            .disabled(!confirmed || busy || entryRevision != snapshot.revision)
                                            .accessibilityIdentifier("optionTradePreview")
                                    }
                                }
                            } else { positionList }
                            if let notice {
                                Text(notice).foregroundStyle(noticeIsError ? Color.red : Color.secondary)
                                    .accessibilityIdentifier("optionTradeNotice")
                            }
                            if model.hasError, let message = model.message {
                                Text(message).foregroundStyle(.red).accessibilityIdentifier("optionTradeLedgerError")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            } else if model.hasError {
                Text(model.message ?? "账户读取失败，未显示旧数据。").foregroundStyle(.red)
                Button("重新读取") { reload() }.disabled(busy)
            } else { ProgressView("正在读取账本…") }
            if busy { ProgressView("正在核对账本…").controlSize(.small) }
            Text("开仓记录持仓与权利金；平仓或到期结清后确认已实现盈亏。本工具不向券商下单。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
        .onAppear {
            visible = true; session = UUID()
            if !started {
                started = true
                if let positionRequest { begin(positionRequest) }
                else if opening != nil { beginOpening() }
            }
        }
        .onDisappear { visible = false; session = UUID(); preparing = nil; model.disappear() }
        .onChange(of: entry) { _, _ in
            confirmed = false; preparedEntry = nil
            if !model.isBusy { model.draftChanged() }
        }
        .onChange(of: model.transferEpoch) { _, _ in
            session = UUID(); preparing = nil; entry = nil; entryRevision = nil; preparedEntry = nil; confirmed = false
            notice = "账本已进入恢复或清空流程，请按完成后的记录重新选择。"; noticeIsError = false
        }
    }

    @ViewBuilder private func accountSelection(_ snapshot: LedgerSnapshot) -> some View {
        if snapshot.accounts.count == 1, let account = snapshot.accounts.first {
            Label(account.name + " · USD", systemImage: "book.closed").font(.headline)
        } else {
            Picker("记入账户", selection: Binding(get: { model.selectedAccountID ?? "" }, set: chooseAccount)) {
                ForEach(snapshot.accounts) { Text($0.name).tag($0.id) }
            }.disabled(busy || positionRequest != nil || entry?.action == .closing || entry?.action == .expiration || model.preview != nil)
                .accessibilityIdentifier("optionTradeAccount")
        }
    }

    private var positionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("未平仓记录").font(.headline)
                Spacer()
                if opening != nil { Button("记录本次开仓") { beginOpening() }.disabled(busy) }
                Button("刷新") { reload() }.disabled(busy)
            }
            if lots.isEmpty {
                Text("该账户暂无期权持仓。实际成交后，在合约页点击“我已成交，确认开仓”。")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(lots) { lot in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(lot.instrument.label).font(.headline).textSelection(.enabled)
                        Text("\(lot.side == .short ? "卖方" : "买方") · 剩余 \(lot.quantityRemaining.decimalString) 张")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("开仓 \(lot.acquiredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(OptionPositionRequest.status(for: lot, at: Date()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("平仓") { begin(lot, action: .closing) }.disabled(busy)
                    Menu("到期处理") {
                        Button("确认到期未行权") { begin(lot, action: .expiration) }
                        if positionRequest == nil { Button("行权 / 被指派：去账本") { openLedger() } }
                        Text("未确认时保留持仓，不自动计收益")
                    }.disabled(busy)
                }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("行权或被指派会改变股票持仓，请在交易账本中记录对应事件；这里的“到期”仅用于未行权结清。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func previewContent(_ preview: LedgerImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本次记账预览").font(.headline)
            if let entry, entry.action != .opening {
                Text("来源：\(entry.sourceSystem) · 编号：\(entry.externalID.isEmpty ? "见各腿成交编号" : entry.externalID)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(preview.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    if let event = row.event { previewEvent(event) }
                    Text(row.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = preview.validationMessage { Text(message).foregroundStyle(.red) }
            if let state = preview.projectedState {
                let newIDs = Set(preview.rows.filter { $0.disposition == .new }.compactMap { $0.event?.id })
                let values = state.realizations.filter { newIDs.contains($0.eventID) }
                if entry?.action != .opening, let pnl = try? values.reduce(Money("0"), { try $0.adding($1.pnl) }) {
                    Text("本次已实现盈亏：\(pnl.decimalString) USD（含相关费用）").font(.headline).monospacedDigit()
                }
                if entry?.action == .opening { Text("本次建立持仓并记录权利金；实际平仓或确认到期结清后，才汇总已实现盈亏。")
                    .font(.callout).foregroundStyle(.secondary) }
            }
            let hasNew = preview.rows.contains { $0.disposition == .new }
            if !hasNew, preview.canCommit { Text("这些成交已记入账户，不会重复入账。").foregroundStyle(.secondary) }
            HStack {
                Button("返回修改") { cancelPreview() }.disabled(busy)
                Spacer()
                Button("确认记账") { commit(preview) }.buttonStyle(.borderedProminent).tint(accent)
                    .disabled(busy || !hasNew || !model.canConfirm || preparedEntry != entry)
                    .accessibilityIdentifier("optionTradeCommit")
            }
        }
    }

    @ViewBuilder private func previewEvent(_ event: LedgerEvent) -> some View {
        switch event.payload {
        case .trade(let trade):
            let action: OptionTradeEntryAction = trade.effect == .open ? .opening : .closing
            Text("\(trade.instrument.label) · \(trade.side == .sell ? "卖出" : "买入")\(trade.effect == .open ? "开仓" : "平仓") \(trade.quantity.decimalString) 张")
            Text("\(action.unitPriceTitle) \(trade.unitPrice.decimalString) USD / 股 · \(action.feeTitle) \(trade.fee.decimalString) USD").font(.callout)
            Text("\(action.timeTitle)：\(event.effectiveAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            if case .option(let contract) = trade.instrument, contract.isLocalManualStandard {
                Text("标准合约 · 每张 100 股 · 本地手工记账")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .optionSettlement(let settlement):
            Text("\(settlement.contract.occSymbol) · 到期未行权 \(settlement.quantity.decimalString) 张")
            Text("到期结清费用 \(settlement.fee.decimalString) USD").font(.callout)
            Text("到期结清时间：\(event.effectiveAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
        if entry?.action == .opening {
            DisclosureGroup("记录信息") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源：" + (event.source.sourceSystem == "local-manual-option-opening.v1" ? "本地手工录入" : event.source.sourceSystem))
                    if let reference = event.source.externalTransactionID {
                        Text((reference.hasPrefix("local-option-opening.v1:") ? "内部记录编号：" : "成交编号：") + reference)
                    }
                    Text(event.source.evidence)
                }.textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        } else if let reference = event.source.externalTransactionID {
            Text("记录编号：" + reference).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func beginOpening() {
        guard !busy, let opening, let snapshot = model.snapshot, let account = model.selectedAccountID else { return }
        do {
            var value = try OptionTradeEntryDraft(openingFrom: opening, automaticContractTerms: true); value.accountID = account
            entryRevision = snapshot.revision; entry = value; notice = nil
        } catch { show(error) }
    }
    private func begin(_ lot: LedgerLot, action: OptionTradeEntryAction) {
        guard !busy, let snapshot = model.snapshot, lot.accountID == model.selectedAccountID else { return }
        do { begin(try OptionPositionRequest(lot: lot, action: action, ledgerRevision: snapshot.revision)) }
        catch { show(error) }
    }
    private func begin(_ request: OptionPositionRequest) {
        guard !busy, let snapshot = model.snapshot, model.selectedAccountID == request.accountID else { return }
        let token = session, epoch = model.transferEpoch, op = UUID()
        preparing = op; notice = nil
        Task {
            defer { if preparing == op { preparing = nil } }
            do {
                // Full ledger replay must not block the input thread. The
                // original request revision remains fixed across this work.
                let value = try await Task.detached { try request.draft(in: snapshot) }.value
                guard visible, session == token, model.transferEpoch == epoch,
                      model.selectedAccountID == request.accountID, model.snapshot?.revision == snapshot.revision,
                      !Task.isCancelled else { return }
                entryRevision = request.ledgerRevision; entry = value
            } catch {
                guard visible, session == token, model.transferEpoch == epoch,
                      model.selectedAccountID == request.accountID, !Task.isCancelled else { return }
                show(error)
            }
        }
    }
    private func openLedger() {
        guard !busy, positionRequest == nil, model.selectedAccountID != nil else { return }
        discardEntry()
        // Keep the selected account and existing ledger confirmations. This
        // route never synthesizes an assignment from the calendar or spot.
        showingLedger = true
    }
    private func chooseAccount(_ account: String) {
        guard !busy, positionRequest == nil else { return }
        let token = session, op = UUID(), epoch = model.transferEpoch
        preparing = op; confirmed = false; preparedEntry = nil
        Task {
            defer { if preparing == op { preparing = nil } }
            guard visible, session == token, model.transferEpoch == epoch else { return }
            await model.chooseAccount(account)
            guard visible, session == token, model.transferEpoch == epoch, model.selectedAccountID == account else { return }
            if var value = entry, value.action == .opening {
                value.accountID = account
                for index in value.legs.indices { value.legs[index].enterContractManually() }
                entry = value; entryRevision = model.snapshot?.revision
            }
        }
    }
    private func discardEntry() {
        guard !busy else { return }
        entry = nil; entryRevision = nil; preparedEntry = nil; notice = nil; confirmed = false; model.draftChanged()
    }
    private func reload() {
        guard !busy else { return }
        discardEntry()
        let token = session, epoch = model.transferEpoch
        Task { guard visible, session == token, model.transferEpoch == epoch else { return }; await model.load() }
    }
    private func prepare() {
        guard !busy, confirmed, let value = entry, let snapshot = model.snapshot,
              snapshot.revision == entryRevision, value.accountID == model.selectedAccountID else { return }
        let token = session, epoch = model.transferEpoch, op = UUID()
        preparing = op; notice = nil
        Task {
            defer { if preparing == op { preparing = nil } }
            do {
                let events = try await Task.detached { try value.events(in: snapshot) }.value
                guard visible, session == token, model.transferEpoch == epoch, entry == value,
                      model.snapshot?.revision == snapshot.revision, model.selectedAccountID == value.accountID,
                      !Task.isCancelled else { return }
                await model.prepareManual(events: events)
                guard visible, session == token, model.transferEpoch == epoch, entry == value,
                      model.preview?.targetRevision == snapshot.revision, !Task.isCancelled else { return }
                preparedEntry = value
            } catch {
                guard visible, session == token, model.transferEpoch == epoch, entry == value, !Task.isCancelled else { return }
                show(error)
            }
        }
    }
    private func cancelPreview() {
        guard !busy, let id = model.preview?.id else { return }
        let token = session, epoch = model.transferEpoch
        let value = entry
        preparedEntry = nil; confirmed = false
        Task {
            guard visible, session == token, model.transferEpoch == epoch,
                  model.preview?.id == id, entry == value else { return }
            await model.cancelPreview()
        }
    }
    private func commit(_ preview: LedgerImportPreview) {
        guard !busy, preparedEntry == entry, let value = entry, entryRevision == preview.targetRevision,
              model.preview?.id == preview.id, model.selectedAccountID == value.accountID else { return }
        let token = session, epoch = model.transferEpoch, op = UUID()
        preparing = op
        Task {
            defer { if preparing == op { preparing = nil } }
            guard visible, session == token, model.transferEpoch == epoch, entry == value else { return }
            let success = await model.confirm(id: preview.id, expectedRevision: preview.targetRevision)
            guard visible, session == token, model.transferEpoch == epoch, entry == value, success else { return }
            entry = nil; entryRevision = nil; preparedEntry = nil; confirmed = false
            switch value.action {
            case .opening:
                notice = "开仓已记账，持仓与权利金已同步；权利金不是最终利润，平仓或到期结清后再汇总已实现盈亏。"
            case .closing:
                notice = "本次平仓已记账，相关已实现盈亏自动汇总到我的投资；剩余张数仍保留在持仓中。"
            case .expiration:
                notice = "本次到期未行权结清已记账，相关已实现盈亏自动汇总到我的投资；仅结清本次确认的张数。"
            }
            noticeIsError = false
            onCommitted(value.accountID)
        }
    }
    private func show(_ error: any Error) {
        if let action = entry?.action, (error as? OptionTradeEntryError) == .missingExecution {
            notice = action.missingExecutionText
        } else if (error as? LedgerError) == .invalidContract {
            notice = entry?.action == .expiration
                ? "请核对到期结清日期。仅记录已确认到期且未行权、未被指派的张数，不能提前结清。"
                : OptionTradeEntryError.invalidContract.errorDescription
        } else {
            notice = (error as? OptionTradeEntryError)?.errorDescription
                ?? entry?.action.missingExecutionText
                ?? "请补齐本次开仓、平仓或到期结清的记录。空白不会当成零，无法核对的记录不会入账。"
        }
        noticeIsError = true
    }
    private func title(_ action: OptionTradeEntryAction) -> String {
        switch action { case .opening: "确认实际开仓"; case .closing: "记录实际平仓"; case .expiration: "确认到期未行权" }
    }
}

// Keep entry fields, preview and validation wording on the same trade stage.
// These are presentation labels only; ledger price and realization rules remain unchanged.
private extension OptionTradeEntryAction {
    var timeTitle: String {
        switch self {
        case .opening: "开仓成交时间"
        case .closing: "平仓成交时间"
        case .expiration: "到期结清时间"
        }
    }
    var unitPriceTitle: String {
        self == .opening ? "开仓权利金单价" : "平仓成交单价"
    }
    var quantityTitle: String {
        switch self {
        case .opening: "开仓张数"
        case .closing: "平仓总张数"
        case .expiration: "到期结清张数"
        }
    }
    var feeTitle: String {
        switch self {
        case .opening: "本腿开仓总费用"
        case .closing: "平仓总费用"
        case .expiration: "到期结清费用"
        }
    }
    var verificationText: String {
        switch self {
        case .opening: "我已核对开仓合约、张数、权利金及费用"
        case .closing: "我已核对平仓成交、费用及持仓批次"
        case .expiration: "我已核对到期未行权、未被指派、结清张数及费用"
        }
    }
    var evidencePrompt: String {
        switch self {
        case .opening: "例如：已核对开仓成交回单"
        case .closing: "例如：已核对平仓成交回单"
        case .expiration: "例如：已核对到期未行权结清记录"
        }
    }
    var missingExecutionText: String {
        switch self {
        case .opening:
            "请填写开仓成交时间、开仓权利金单价及费用（无费用填 0）；来源、编号和记录依据可留空。"
        case .closing:
            "请填写平仓成交时间、来源、唯一成交编号、记录依据、平仓成交单价及费用；本次已实现盈亏由账本计算。"
        case .expiration:
            "请填写到期结清时间、来源、唯一记录编号、记录依据及结清费用；到期未行权无需填写成交价。"
        }
    }
}

private struct OptionTradeEditor: View {
    @Binding var draft: OptionTradeEntryDraft
    let snapshot: LedgerSnapshot
    let opening: OptionLabInputDraft?
    @State private var details = false
    @State private var referenceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.action != .opening {
                HStack(alignment: .top, spacing: 12) {
                    field("券商 / 记录来源", text: $draft.sourceSystem, prompt: "例如：券商名称")
                    if draft.legs.count == 1 {
                        field(draft.action == .expiration ? "到期记录编号" : "成交编号", text: $draft.externalID, prompt: "与回单 / CSV 中的编号保持一致")
                    }
                }
            }
            OptionTradeDateField(draft.action.timeTitle, text: $draft.timestamp)
            if draft.action == .opening, let opening {
                HStack(spacing: 8) {
                    Button("开仓权利金与测算相同，带入") {
                        do { try draft.applyOpeningReferencePrices(from: opening); referenceError = nil }
                        catch { referenceError = "测算价格不完整或合约已变化，请填写开仓权利金单价。" }
                    }.font(.caption)
                    Text("请核对实际开仓价格与费用").font(.caption).foregroundStyle(.secondary)
                }
                if let referenceError { Text(referenceError).font(.caption).foregroundStyle(.red) }
            }
            ForEach($draft.legs) { $leg in
                VStack(alignment: .leading, spacing: 8) {
                    Text(leg.label + " · " + (leg.form.existingOption?.occSymbol ?? leg.form.occSymbol))
                        .font(.headline).textSelection(.enabled)
                    if draft.action != .opening, draft.legs.count > 1 {
                        field("本腿成交编号", text: $leg.form.externalID, prompt: "填写回单 / CSV 中本腿的唯一编号")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field(draft.action.quantityTitle, text: $leg.form.quantity)
                        if draft.action != .expiration { field(draft.action.unitPriceTitle + " · USD / 股", text: $leg.form.unitPrice) }
                        field(draft.action.feeTitle + " · USD", text: $leg.form.fee, prompt: "无费用请填 0")
                    }
                    if draft.action == .closing, draft.closingCandidates.count > 1 {
                        OptionTradeLotSelection(candidates: draft.closingCandidates, snapshot: snapshot,
                            allocations: $draft.closingAllocations, quantity: leg.form.quantity)
                    }
                    DisclosureGroup("同刻成交顺序（按需填写）") {
                        VStack(alignment: .leading, spacing: 5) {
                            field("来源顺序号", text: $leg.form.sequence, prompt: "仅填写回单中的实际顺序号")
                            Text("同一标的在完全相同时刻平仓或到期，需要同一来源的不同顺序号；没有依据时请保留空白，不猜测顺序。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 5)
                    }.font(.caption)
                }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            if draft.action == .opening {
                DisclosureGroup("来源与记录信息（选填）") { openingMetadataFields }
                    .font(.callout)
            } else {
                field("记录依据", text: $draft.evidence, prompt: draft.action.evidencePrompt)
            }
            if draft.action == .expiration {
                Text("仅确认已到期且未行权、未被指派的部分；不会按日期自动判断作废。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("备注与策略口径", isExpanded: $details) {
                VStack(alignment: .leading, spacing: 10) {
                    field("备注（可不填）", text: $draft.notes)
                    if draft.action == .opening {
                        Picker("目的", selection: $draft.strategyPurpose) {
                            Text("权利金收入").tag(LedgerStrategyPurpose.premiumIncome)
                            Text("取得股票").tag(LedgerStrategyPurpose.acquireShares)
                            Text("总回报").tag(LedgerStrategyPurpose.totalReturn)
                            Text("对冲 / 管理").tag(LedgerStrategyPurpose.hedgeOrManage)
                        }
                        field("成功定义", text: $draft.strategySuccessDefinition)
                        if draft.strategyPurpose == .acquireShares { field("最高可接受取得价格 · USD / 股", text: $draft.strategyMaximumAcquisitionPrice) }
                        Toggle("未被指派也符合该策略的成功定义", isOn: $draft.strategyUnassignedCountsAsSuccess)
                    }
                }.padding(.top, 8)
            }.font(.callout)
            if draft.action == .opening {
                Text("合约信息自动整理，无需另填。标准合约每张 100 股；调整合约请使用高级账本。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("开仓单价是每股收取或支付的权利金；平仓或到期结清后才确认已实现盈亏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
    }
    private var openingMetadataFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                field("来源（选填）", text: $draft.sourceSystem, prompt: "例如：券商名称")
                if draft.legs.count == 1 {
                    field("成交编号（选填）", text: $draft.externalID, prompt: "有回单时可填写")
                }
            }
            if draft.legs.count > 1 {
                ForEach($draft.legs) { $leg in
                    field(leg.label + "成交编号（选填）", text: $leg.form.externalID, prompt: "有回单时填写本腿编号，不用订单编号代替")
                }
            }
            field("记录依据（选填）", text: $draft.evidence, prompt: "例如：开仓记录备注")
            Text("留空按手工记录保存，软件自动编号。日后另行录入或导入同一笔成交时，请核对是否重复。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 5)
    }
    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).onSubmit { }.accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One fill can consume several explicitly selected compatible lots. Allocation
/// changes do not create executions, alter broker IDs or split the total fee.
private struct OptionTradeLotSelection: View {
    let candidates: [LedgerLot]
    let snapshot: LedgerSnapshot
    @Binding var allocations: [String: String]
    let quantity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择平仓批次").font(.subheadline.bold())
            Text("仅显示同账户、同合约版本、同方向的持仓。各批次张数合计须等于上方平仓总张数；平仓单价和总费用只填一次。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(candidates) { lot in
                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: Binding(get: { allocations[lot.id] != nil }, set: { selected in
                        if selected { allocations[lot.id] = lot.quantityRemaining.decimalString }
                        else { allocations.removeValue(forKey: lot.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(lot.acquiredAt.formatted(date: .abbreviated, time: .standard)) · 剩余 \(lot.quantityRemaining.decimalString) 张")
                            if let event = snapshot.events.first(where: { $0.id == lot.openEventID }),
                               let reference = event.source.externalTransactionID {
                                Text("开仓成交：\(reference)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("optionTradeLotSelect_" + lot.id)
                    if allocations[lot.id] != nil {
                        if allocations.count > 1 {
                            TextField("平仓张数", text: Binding(get: { allocations[lot.id] ?? "" }, set: { allocations[lot.id] = $0 }))
                                .frame(width: 90).onSubmit { }.accessibilityLabel("本批次平仓张数")
                                .accessibilityIdentifier("optionTradeLotQuantity_" + lot.id)
                        } else {
                            Text("本批次平仓 \(quantity) 张").font(.callout).monospacedDigit()
                        }
                    }
                }
            }
            Text("批次成本与费用由账本分配；预览通过并确认后才入账。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }
}

/// Date picker values remain uncommitted proposals until the explicit apply action.
private struct OptionTradeDateField: View {
    let title: String
    @Binding var text: String
    @State private var date = Date()
    @State private var editing = false
    init(_ title: String, text: Binding<String>) { self.title = title; _text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                if let value = try? LedgerCSV.timestamp(text) {
                    Text(value.formatted(date: .abbreviated, time: .standard)).font(.callout)
                } else { Text("尚未确认").foregroundStyle(.secondary) }
                Spacer()
                Button(text.isEmpty ? "选择时间" : "修改") {
                    date = (try? LedgerCSV.timestamp(text)) ?? Date(); editing = true
                }
            }
            DisclosureGroup("精确时间（可选）") {
                TextField("带时区的 ISO 时间，可保留秒与小数秒", text: $text)
                    .textFieldStyle(.roundedBorder).font(.caption).onSubmit { }
                    .accessibilityLabel(title + "精确时间")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                DatePicker("日期与时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Text("本地时区：\(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
                Text("选择器按分钟确认，秒与小数秒置零。精确成交时刻可在外层直接填写。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("取消") { editing = false }
                    Spacer()
                    Button("确认时间") {
                        let calendar = Calendar.current
                        let components = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
                        guard let minute = calendar.date(from: components) else { return }
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        text = formatter.string(from: minute); editing = false
                    }
                }
            }.padding(16).frame(width: 340)
        }
    }
}
