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
    @State private var model: LedgerWorkspaceModel?
    @State private var failed = false
    @State private var attempt = UUID()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                OptionTradeContent(model: model, opening: opening, close: { dismiss() })
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
        .frame(minWidth: 640, idealWidth: 740, maxWidth: 920, minHeight: 560, idealHeight: 700)
        .task(id: attempt) {
            do {
                failed = false
                let ready = try await workspace.makeLedgerWorkspaceModel()
                try Task.checkCancellation()
                await ready.load()
                try Task.checkCancellation()
                model = ready
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct OptionTradeContent: View {
    @Bindable var model: LedgerWorkspaceModel
    let opening: OptionLabInputDraft?
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
    private let accent = Color(red: 0.06, green: 0.43, blue: 0.41)
    private var busy: Bool { model.isBusy || preparing != nil }
    private var lots: [LedgerLot] {
        (model.snapshot?.state.lots ?? []).filter {
            guard $0.accountID == model.selectedAccountID, !$0.isClosed else { return false }
            if case .option = $0.instrument { return true }; return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.map { title($0.action) } ?? "我的期权持仓").font(.title2.bold())
                    Text("记一次，自动汇总到“我的投资”").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { close() }.disabled(busy).accessibilityIdentifier("optionTradeDone")
            }
            Divider()
            if let snapshot = model.snapshot {
                if snapshot.accounts.isEmpty {
                    ContentUnavailableView("先建立一个账户", systemImage: "book.closed",
                        description: Text("回到“我的投资”填写账户名称，之后在这里记录实际成交。"))
                } else {
                    accountSelection(snapshot)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let entry {
                                OptionTradeEditor(draft: Binding(get: { self.entry ?? entry }, set: { value in
                                    guard self.entry?.id == entry.id, !busy else { return }; self.entry = value
                                }), snapshot: snapshot).disabled(busy || model.preview != nil)
                                if model.preview == nil {
                                    Toggle("我已核对实际成交、费用及合约信息", isOn: $confirmed)
                                        .toggleStyle(.checkbox).disabled(busy)
                                        .accessibilityIdentifier("optionTradeVerified")
                                    HStack {
                                        Button("返回持仓") { discardEntry() }.disabled(busy)
                                        Spacer()
                                        Button("核对并预览") { prepare() }.buttonStyle(.borderedProminent).tint(accent)
                                            .disabled(!confirmed || busy || entryRevision != snapshot.revision)
                                            .accessibilityIdentifier("optionTradePreview")
                                    }
                                }
                                if let preview = model.preview { previewContent(preview) }
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
            Text("仅记录你已完成的交易，不向券商下单。测算收益与收取权利金不等于已实现盈亏。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .onAppear {
            visible = true; session = UUID()
            if !started { started = true; if opening != nil { beginOpening() } }
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
            }.disabled(busy || entry?.action == .closing || entry?.action == .expiration || model.preview != nil)
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
                Text("该账户暂无期权持仓。在合约页填好参数，点击“记录实际成交”即可开仓记账。")
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
                    }
                    Spacer()
                    Button("记录平仓") { begin(lot, action: .closing) }.disabled(busy)
                    Button("确认到期未行权") { begin(lot, action: .expiration) }.disabled(busy)
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("行权或被指派会改变股票持仓，请在交易账本中记录对应事件；这里的“到期”仅用于未行权结清。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func previewContent(_ preview: LedgerImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("本次记账预览").font(.headline)
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
                if let pnl = try? values.reduce(Money("0"), { try $0.adding($1.pnl) }) {
                    Text("本次新增已实现盈亏：\(pnl.decimalString) USD").font(.headline).monospacedDigit()
                }
                if entry?.action == .opening { Text("开仓只记录权利金和持仓，平仓或到期后才实现盈亏。").font(.caption).foregroundStyle(.secondary) }
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
            Text("\(trade.instrument.label) · \(trade.side == .sell ? "卖出" : "买入") \(trade.quantity.decimalString) 张")
            Text("实际成交价 \(trade.unitPrice.decimalString) USD / 股 · 本腿总费用 \(trade.fee.decimalString) USD").font(.callout)
        case .optionSettlement(let settlement):
            Text("\(settlement.contract.occSymbol) · 到期未行权 \(settlement.quantity.decimalString) 张")
            Text("本次总费用 \(settlement.fee.decimalString) USD").font(.callout)
        default: EmptyView()
        }
        Text(event.effectiveAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
    }

    private func beginOpening() {
        guard !busy, let opening, let snapshot = model.snapshot, let account = model.selectedAccountID else { return }
        do {
            var value = try OptionTradeEntryDraft(openingFrom: opening); value.accountID = account
            entryRevision = snapshot.revision; entry = value; notice = nil
        } catch { show(error) }
    }
    private func begin(_ lot: LedgerLot, action: OptionTradeEntryAction) {
        guard !busy, let snapshot = model.snapshot, lot.accountID == model.selectedAccountID else { return }
        do { entry = try .init(lot: lot, action: action); entryRevision = snapshot.revision; notice = nil }
        catch { show(error) }
    }
    private func chooseAccount(_ account: String) {
        guard !busy else { return }
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
            notice = "已记入账户。返回“我的投资”即可看到更新后的持仓与已实现盈亏，无需再次录入。"; noticeIsError = false
        }
    }
    private func show(_ error: any Error) {
        notice = (error as? OptionTradeEntryError)?.errorDescription
            ?? "请补齐实际价格、费用、发生时间与合约依据。空白不会当成零，无法核对的记录不会入账。"
        noticeIsError = true
    }
    private func title(_ action: OptionTradeEntryAction) -> String {
        switch action { case .opening: "记录实际开仓"; case .closing: "记录实际平仓"; case .expiration: "确认到期未行权" }
    }
}

private struct OptionTradeEditor: View {
    @Binding var draft: OptionTradeEntryDraft
    let snapshot: LedgerSnapshot
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                field("券商 / 记录来源", text: $draft.sourceSystem, prompt: "例如：券商名称")
                if draft.legs.count == 1 {
                    field(draft.action == .expiration ? "到期记录编号" : "成交编号", text: $draft.externalID, prompt: "与回单 / CSV 中的编号保持一致")
                }
            }
            OptionTradeDateField("实际发生时间", text: $draft.timestamp)
            ForEach($draft.legs) { $leg in
                VStack(alignment: .leading, spacing: 10) {
                    Text(leg.label + " · " + (leg.form.existingOption?.occSymbol ?? leg.form.occSymbol))
                        .font(.headline).textSelection(.enabled)
                    if draft.legs.count > 1 {
                        field("本腿成交编号", text: $leg.form.externalID, prompt: "填写回单 / CSV 中本腿的唯一编号")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("实际张数", text: $leg.form.quantity)
                        if draft.action != .expiration { field("实际成交价 · USD / 股", text: $leg.form.unitPrice) }
                        field("本腿总费用 · USD", text: $leg.form.fee, prompt: "无费用请填 0")
                    }
                    DisclosureGroup("同刻成交顺序（按需填写）") {
                        VStack(alignment: .leading, spacing: 5) {
                            field("来源顺序号", text: $leg.form.sequence, prompt: "仅填写回单中的实际顺序号")
                            Text("同一标的在完全相同时刻平仓或到期，需要同一来源的不同顺序号；没有依据时请保留空白，不猜测顺序。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 5)
                    }.font(.caption)
                    if draft.action == .opening {
                        OptionTradeContractFields(leg: $leg, snapshot: snapshot, accountID: draft.accountID)
                    }
                }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            field("记录依据", text: $draft.evidence, prompt: "例如：已核对成交回单 / 已核对到期结清")
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
                Text("成功定义：\(draft.strategySuccessDefinition)。可在“备注与策略口径”调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).onSubmit { }.accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
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

private struct OptionTradeContractFields: View {
    @Binding var leg: OptionTradeEntryLegDraft
    let snapshot: LedgerSnapshot
    let accountID: String
    @State private var expanded = false
    @State private var errorMessage: String?
    private var contracts: [LedgerOptionVersion] {
        var result: [LedgerOptionVersion] = []
        for lot in snapshot.state.lots where lot.accountID == accountID {
            if case .option(let contract) = lot.instrument,
               contract.occSymbol == leg.form.occSymbol, !result.contains(contract) { result.append(contract) }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !contracts.isEmpty {
                Menu("复用账户中的合约条款") {
                    ForEach(Array(contracts.enumerated()), id: \.offset) { _, contract in
                        Button(contract.versionID + " · " + contract.occSymbol) {
                            do { try leg.reuseContract(contract); errorMessage = nil }
                            catch { errorMessage = "该版本不能用于当前成交，请核对合约与来源。" }
                        }
                    }
                }
            }
            if let contract = leg.form.existingOption {
                Text("已选原合约版本：" + contract.versionID).font(.caption).foregroundStyle(.secondary)
                Button("重新填写合约") { leg.enterContractManually(); expanded = true }
            } else {
                DisclosureGroup("首次使用：核对合约条款", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("以下信息只需在该合约首次记账时核对，后续平仓和到期自动沿用。")
                            .font(.caption).foregroundStyle(.secondary)
                        field("标的标识", text: $leg.form.securityID)
                        field("合约版本", text: $leg.form.contractVersionID)
                        Picker("行权方式", selection: $leg.form.exerciseStyle) {
                            Text("美式").tag(LedgerExerciseStyle.american)
                            Text("欧式").tag(LedgerExerciseStyle.european)
                        }
                        OptionTradeDateField("合约版本生效时间", text: $leg.form.effectiveFrom)
                        OptionTradeDateField("最后交易时间", text: $leg.form.tradingEndsAt)
                        OptionTradeDateField("行权截止时间", text: $leg.form.exerciseDeadline)
                        OptionTradeDateField("交割时间", text: $leg.form.settlementAt)
                        field("合约条款依据", text: $leg.form.memoReference)
                        Text("标准实物交割：每张100股；无额外现金交割。请核对上方合约代码与行权价。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("上述合约条款与我的实际合约一致", isOn: $leg.contractConfirmed)
                            .toggleStyle(.checkbox)
                    }.padding(.top, 8)
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }.font(.callout)
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).onSubmit { }.accessibilityLabel(title)
        }
    }
}
