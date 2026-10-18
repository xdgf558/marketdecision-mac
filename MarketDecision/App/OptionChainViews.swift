import SwiftUI
import AppComposition
import CoreDomain
import DataContracts
import OptionsAnalytics
import Persistence

/// This view displays only captures published after complete source replay. A
/// catalog row is metadata, never permission to use its cached quote or Greeks.
struct OptionChainContent: View {
    @Bindable var model: OptionChainWorkspaceModel
    let history: OptionHistoryWorkspaceModel?
    let onDraft: @MainActor (OptionLabInputDraft, @MainActor () -> Bool) async throws -> Void
    @State private var page = "选择合约"
    @State private var strategy: OptionLabStrategy = .cashSecuredPut
    @State private var expiration = ""
    @State private var shortID = ""
    @State private var longID = ""
    @State private var quantity = "1"
    @State private var rate = ""
    @State private var dividendYield = ""
    @State private var tick = ""
    @State private var assumptionReference = ""
    @State private var settlements: [String: String] = [:]
    @State private var declaredClose = false
    @State private var inputError: String?
    @State private var visible = false
    @State private var session = UUID()
    @State private var actionTask: Task<Void, Never>?
    @State private var preparingDraft = false
    private var blocked: Bool { model.isBusy || history?.isBusy == true || preparingDraft }
    private var hasLongLeg: Bool { strategy == .putCreditSpread || strategy == .callCreditSpread }
    private var right: OptionChainRight { strategy == .coveredCall || strategy == .callCreditSpread ? .call : .put }
    private var canHandOff: Bool {
        !blocked && !shortID.isEmpty && (!hasLongLeg || (!longID.isEmpty && shortID != longID))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("期权链候选").font(.title2.bold())
                Spacer()
                if blocked { ProgressView().controlSize(.small) }
            }
            Text("显式载入本地合成链，核对来源后选择合约。没有供应商账户或真实请求；完整采集只代表声明范围，不授予实时、PIT 或交易资格。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("载入合成期权链") { perform { await model.loadSynthetic() } }
                    .disabled(blocked).accessibilityIdentifier("optionChainLoadSynthetic")
                Button("保存采集") { perform { _ = await model.saveCapture() } }
                    .disabled(!model.canSave || history?.isBusy == true).accessibilityIdentifier("optionChainSave")
                Button("刷新采集目录") { perform { await model.load() } }
                    .disabled(blocked).accessibilityIdentifier("optionChainReload")
                if model.canCancel {
                    Button("取消采集或读取") { actionTask?.cancel(); model.cancel() }
                        .accessibilityIdentifier("optionChainCancel")
                }
            }
            if model.isBusy && !model.canCancel {
                Text("保存一旦开始便不能通过离页撤销；完成后仍会核对原写入版本。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("optionChainMessage")
            }
            if let inputError { Text(inputError).foregroundStyle(.red).accessibilityIdentifier("optionChainInputError") }
            Picker("期权链内容", selection: $page) {
                Text("选择合约").tag("选择合约")
                Text("链日摘要").tag("链日摘要")
                Text("采集目录").tag("采集目录")
            }.pickerStyle(.segmented).accessibilityIdentifier("optionChainSections")
            if page == "采集目录" { catalog }
            else if let capture = model.capture {
                captureStatus(capture)
                if page == "链日摘要" { daily(capture) }
                else { selection(capture) }
            } else {
                ContentUnavailableView("尚无已核对期权链", systemImage: "list.bullet.rectangle",
                    description: Text("点击“载入合成期权链”，或从目录打开一份采集。未核对的目录条目不会展示报价。"))
            }
        }
        .onAppear { visible = true; session = UUID() }
        .task { await model.load(); guard !Task.isCancelled else { return }; await history?.load() }
        .onDisappear {
            visible = false; session = UUID(); actionTask?.cancel(); actionTask = nil
            preparingDraft = false; model.disappear(); history?.disappear()
        }
        .onChange(of: model.capture?.id) { _, _ in
            expiration = ""; shortID = ""; longID = ""; settlements = [:]
            rate = ""; dividendYield = ""; tick = ""; assumptionReference = ""; declaredClose = false
            inputError = nil; history?.draftChanged()
            if model.capture != nil { page = "选择合约" }
        }
        .onChange(of: strategy) { _, _ in shortID = ""; longID = ""; inputError = nil }
        .onChange(of: expiration) { _, _ in shortID = ""; longID = ""; inputError = nil }
        .onChange(of: rate) { _, _ in invalidateDaily() }
        .onChange(of: dividendYield) { _, _ in invalidateDaily() }
        .onChange(of: tick) { _, _ in invalidateDaily() }
        .onChange(of: assumptionReference) { _, _ in invalidateDaily() }
        .onChange(of: settlements) { _, _ in invalidateDaily() }
        .onChange(of: declaredClose) { _, _ in invalidateDaily() }
    }

    private func captureStatus(_ capture: OptionChainCapture) -> some View {
        GroupBox("本次来源与覆盖") {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(capture.synthetic ? "SYNTHETIC · 合成研究" : "候选来源 · 尚未准入") · \(capture.symbol)")
                    .font(.headline).foregroundStyle(.orange).accessibilityIdentifier("optionChainOrigin")
                Text("\(status(capture.snapshot.status)) · 已完成 \(capture.snapshot.completedExpirations.count) / \(capture.snapshot.requestedExpirations.count) 个声明到期 · \(capture.snapshot.contracts.count) 份合约 · \(capture.pages.count) 页来源")
                    .accessibilityIdentifier("optionChainCoverage")
                Text("\(capture.providerID) / \(capture.feedID) · 采集 \(timestamp(capture.requestedAt))")
                    .font(.caption).textSelection(.enabled)
                if let underlying = capture.snapshot.underlying {
                    Text("标的 Bid / Ask：\(underlying.bid.decimalString) / \(underlying.ask.decimalString) USD · \(timeliness(underlying.timeliness))\n报价 \(timestamp(underlying.quoteTime)) · 接收 \(timestamp(underlying.provenance.receivedAt))")
                        .font(.caption).textSelection(.enabled)
                } else { Text("标的报价缺失；不能带入实验室计算。").foregroundStyle(.orange) }
                Text("供应商 IV / Greeks 未请求，不比较、不作为本地计算结果。成交量与 OI 仅是响应观测值；缺独立发布时点时不冒充最新 OI。")
                    .font(.caption).foregroundStyle(.secondary)
                if capture.snapshot.status != .complete {
                    Text("本次不是完整链。可留存来源，但不将部分、空或失败页面当作完整数据；带入和日摘要仍需通过各自完整性检查。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !capture.snapshot.failures.isEmpty {
                    Text("失败页：\(capture.snapshot.failures.count)；未改记为空成功。").font(.caption).foregroundStyle(.red)
                }
                if model.savedID != nil {
                    Text("已保存采集 · 当前来源已完整重放核对").font(.caption).accessibilityIdentifier("optionChainSavedStatus")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }

    private func selection(_ capture: OptionChainCapture) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("选择策略与到期日") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("策略", selection: $strategy) {
                        ForEach(OptionLabStrategy.allCases, id: \.self) { Text(strategyName($0)).tag($0) }
                    }.accessibilityIdentifier("optionChainStrategy")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 8) {
                        ForEach(capture.snapshot.requestedExpirations, id: \.iso8601) { date in
                            Button {
                                expiration = date.iso8601
                            } label: {
                                Label(date.iso8601, systemImage: expiration == date.iso8601 ? "checkmark.circle.fill" : "circle")
                            }.accessibilityIdentifier("optionChainExpiry-" + date.iso8601)
                        }
                    }
                    row("每腿张数（明确的研究假设）", $quantity, "optionChainQuantity")
                    Text("卖出腿：\(shortID.isEmpty ? "尚未选择" : shortID)\(hasLongLeg ? "\n保护腿：\(longID.isEmpty ? "尚未选择" : longID)" : "")")
                        .font(.caption).textSelection(.enabled).accessibilityIdentifier("optionChainSelection")
                    Button("带入实验室输入") { handOff() }
                        .disabled(!canHandOff).accessibilityIdentifier("optionChainHandOff")
                    Text("只复制这次已核对的合约与报价。确切到期时刻、tick、资本及 r / q 等仍需在输入页显式填写；费用沿用实验室已批准默认值，请核对。不会自动计算或采用供应商 Greeks，更改策略或到期日会清空选腿。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
            }.disabled(blocked)
            if expiration.isEmpty {
                Text("先选择一个到期日，再选择所需的卖出腿和保护腿。").foregroundStyle(.secondary)
            } else {
                let contracts = capture.snapshot.contracts.filter { $0.expiration.iso8601 == expiration && $0.right == right }
                    .sorted { $0.strike.amount == $1.strike.amount ? $0.recordID < $1.recordID : $0.strike.amount < $1.strike.amount }
                if contracts.isEmpty { Text("该到期日没有所选方向的有效合约记录。").foregroundStyle(.orange) }
                ForEach(contracts, id: \.recordID) { contract in contractRow(contract) }
            }
        }
    }

    private func contractRow(_ contract: OptionChainContract) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("\(contract.right == .put ? "Put" : "Call") · K \(contract.strike.decimalString)").font(.headline)
                    Spacer()
                    Button(shortID == contract.recordID ? "已选卖出腿" : "设为卖出腿") {
                        shortID = contract.recordID; if longID == shortID { longID = "" }; inputError = nil
                    }.disabled(blocked).accessibilityIdentifier("optionChainShort-" + contract.recordID)
                    if hasLongLeg {
                        Button(longID == contract.recordID ? "已选保护腿" : "设为保护腿") {
                            longID = contract.recordID; inputError = nil
                        }.disabled(blocked || shortID == contract.recordID).accessibilityIdentifier("optionChainLong-" + contract.recordID)
                    }
                }
                Text("\(contract.recordID) · 乘数 \(contract.multiplier)\nBid / Ask \(contract.quote.bid.decimalString) / \(contract.quote.ask.decimalString) USD · 数量 \(contract.quote.bidSize) / \(contract.quote.askSize) 张")
                    .font(.caption).textSelection(.enabled)
                Text("\(timeliness(contract.quote.timeliness)) · \(quality(contract.quote.quality))\n报价 \(timestamp(contract.quote.quoteTime)) · 接收 \(timestamp(contract.provenance.receivedAt))\n观测成交量 \(contract.observedVolume.map(String.init) ?? "未知") · 观测 OI \(contract.observedOpenInterest.map(String.init) ?? "未知")")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }

    private func daily(_ capture: OptionChainCapture) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请先保存当前采集，再把本次全部合约带入日摘要；不会缩成四份模板报价。每个到期时刻和统一 tick 都是你明确声明的离线假设，日历日不会自动补成 16:00。")
                .font(.callout).foregroundStyle(.secondary)
            if model.savedID != capture.id {
                Text("当前采集尚未保存。请先点击上方“保存采集”，再核对日摘要。").foregroundStyle(.orange)
                    .accessibilityIdentifier("optionChainDailyNeedsCaptureSave")
            }
            GroupBox("日摘要的显式假设") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { row("连续利率 r（0.05 = 5%）", $rate, "optionChainDailyRate"); row("连续股息率 q", $dividendYield, "optionChainDailyDividend") }
                    row("所有报价共同 tick 假设（USD / 股）", $tick, "optionChainDailyTick")
                    row("上述假设与到期时刻的依据", $assumptionReference, "optionChainDailyReference")
                    ForEach(Array(Set(capture.snapshot.contracts.map(\.expiration))).sorted(), id: \.iso8601) { date in
                        row("\(date.iso8601) 确切到期时刻（ISO 8601，含时区）", settlementBinding(date.iso8601), "optionChainSettlement-" + date.iso8601)
                    }
                    Text("仅为实际收到合约的到期填写时刻；上方声明范围与未完成页面仍保留，填完这些字段不会把部分链变成完整链。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("我声明这次采集评估时刻就是该会话收盘时点（离线假设）", isOn: $declaredClose)
                        .accessibilityIdentifier("optionChainDeclaredClose")
                    Text("未声明收盘时点或不足以求解本地 IV 时，IV30 保持不可用。观测 OI 缺独立发布证据时不计入最新 OI 聚合。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("核对全链日摘要") { calculateDaily() }.disabled(blocked || history == nil || model.savedID != capture.id)
                            .accessibilityIdentifier("optionChainCalculateDaily")
                        Button("保存链日摘要") { if let history { perform { _ = await history.saveDaily() } } }
                            .disabled(history?.canSaveDaily != true || model.isBusy).accessibilityIdentifier("optionChainSaveDaily")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
            }.disabled(blocked)
            if let history, let message = history.message {
                Text(message).foregroundStyle(history.hasError ? .red : .secondary).accessibilityIdentifier("optionChainDailyMessage")
            }
            if let report = history?.dailyReport {
                GroupBox("已核对的链日摘要") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("IV30：\(report.iv30.map { String(format: "%.2f%%", $0 * 100) } ?? "不可用") · \(report.contractSummaries.count) 份合约")
                            .font(.headline).accessibilityIdentifier("optionChainDailyResult")
                        Text("\(report.input.symbol) · \(report.input.session.iso8601) · \(report.containsSynthetic ? "SYNTHETIC" : "MANUAL")")
                        ForEach(Array(report.limitations.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
            }
        }
    }

    private var catalog: some View {
        GroupBox("采集目录 · 打开后才发布报价") {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.listError { Text(error).foregroundStyle(.red) }
                else if model.saved.isEmpty { Text("暂无已读取的期权链采集。").foregroundStyle(.secondary) }
                ForEach(model.saved) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.symbol) · \(item.contractCount) 合约 · \(item.pageCount) 来源页")
                            Text("\(item.providerID) / \(item.feedID) · \(timestamp(item.createdAt))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("打开并重放核对") { perform { await model.open(item.id) } }
                            .disabled(blocked).accessibilityIdentifier("optionChainOpen-" + item.id.uuidString)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }

    private struct HandoffSelection: Equatable {
        let strategy: OptionLabStrategy
        let expiration: String
        let shortID: String
        let longID: String
        let quantity: String
    }
    private var handoffSelection: HandoffSelection {
        .init(strategy: strategy, expiration: expiration, shortID: shortID, longID: longID, quantity: quantity)
    }
    private func handOff() {
        guard canHandOff, let captureID = model.capture?.id, let count = Int(quantity), count > 0 else {
            inputError = "请明确选择合约并填写正整数字段张数。"; return
        }
        do {
            let imported = try model.makeDraft(strategy: strategy, shortID: shortID, longID: hasLongLeg ? longID : nil, quantity: count)
            let token = session, selection = handoffSelection, form = dailyForm
            let stillCurrent: @MainActor () -> Bool = {
                visible && session == token && page == "选择合约" && model.capture?.id == captureID
                    && handoffSelection == selection && dailyForm == form && !Task.isCancelled
            }
            perform {
                guard stillCurrent() else { return }
                preparingDraft = true
                defer { if session == token { preparingDraft = false } }
                do { try await onDraft(imported, stillCurrent) }
                catch {
                    guard stillCurrent() else { return }
                    inputError = "草稿写入基线未能核对，请重新带入；没有发布未核对的旧草稿。"
                }
            }
        } catch { inputError = "所选合约、来源或时效未通过检查。请重新选择；没有将不完整报价带入实验室。" }
    }
    private struct DailyForm: Equatable {
        let rate: String
        let dividendYield: String
        let tick: String
        let reference: String
        let settlements: [String: String]
        let declaredClose: Bool
    }
    private var dailyForm: DailyForm {
        .init(rate: rate, dividendYield: dividendYield, tick: tick, reference: assumptionReference,
              settlements: settlements, declaredClose: declaredClose)
    }
    private func calculateDaily() {
        guard !blocked, let history, let captureID = model.capture?.id, model.savedID == captureID else { return }
        let token = session, form = dailyForm
        perform {
            // Saving the capture advances the shared database revision. Acquire
            // the daily write baseline now, before any asynchronous calculation.
            await history.load()
            guard visible, session == token, page == "链日摘要", dailyForm == form,
                  model.capture?.id == captureID, model.savedID == captureID,
                  !model.isBusy, !history.isBusy, !Task.isCancelled else { return }
            do {
                let dates = try form.settlements.mapValues(parseDate)
                let input = try model.makeDailyInput(rate: Money(form.rate), dividendYield: Money(form.dividendYield), settlements: dates,
                    tick: Money(form.tick), assumptionReference: form.reference, declaredClose: form.declaredClose)
                await history.calculateDaily(input)
            } catch {
                guard visible, session == token, model.capture?.id == captureID, !Task.isCancelled else { return }
                inputError = "请完整填写 r / q、tick、来源和各到期时刻；缺值不会自动补零或取最新。"
            }
        }
    }
    private func settlementBinding(_ key: String) -> Binding<String> {
        Binding(get: { settlements[key] ?? "" }, set: { settlements[key] = $0 })
    }
    private func row(_ title: String, _ text: Binding<String>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).accessibilityIdentifier(id)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        let token = session
        actionTask?.cancel(); inputError = nil
        actionTask = Task { guard visible, session == token, !Task.isCancelled else { return }; await action() }
    }
    private func invalidateDaily() { history?.draftChanged(); inputError = nil }
    private func parseDate(_ value: String) throws -> Date {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]
        guard let date = format.date(from: value) else { throw OptionLabDraftError.invalidDate }
        return date
    }
    private func timestamp(_ date: Date?) -> String { date.map { $0.formatted(.iso8601) } ?? "未知" }
    private func status(_ state: OptionChainCaptureStatus) -> String {
        switch state { case .complete: "声明范围完整"; case .partial: "部分链"; case .empty: "空链"; case .error: "采集失败" }
    }
    private func timeliness(_ value: Timeliness) -> String {
        switch value { case .realtime: "源声明实时（未获分析资格）"; case .delayed: "延迟"; case .endOfDay: "日终"; case .notApplicable: "不适用"; case .unknown: "时效未知" }
    }
    private func quality(_ values: Set<QualityFlag>) -> String {
        values.isEmpty ? "无额外质量标记，仍需时效核对" : values.map(\.rawValue).sorted().joined(separator: ", ")
    }
    private func strategyName(_ value: OptionLabStrategy) -> String {
        switch value { case .cashSecuredPut: "现金担保卖 Put"; case .coveredCall: "备兑 Call"; case .putCreditSpread: "Put 信用价差"; case .callCreditSpread: "Call 信用价差" }
    }
}
