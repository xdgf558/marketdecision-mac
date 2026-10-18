import SwiftUI
import AppComposition
import CoreDomain
import DataContracts
import PortfolioEngine
import Persistence

/// Existing laboratory styling and system controls; all evidence selection is explicit.
struct PortfolioGreeksContent: View {
    @Bindable var model: PortfolioGreeksWorkspaceModel
    @State private var account = ""
    @State private var cutoff = ""
    @State private var instrument = ""
    @State private var source = ""
    @State private var leg = ""
    @State private var inputError: String?
    @State private var session = UUID()
    @State private var formRevision = UUID()
    private var chosenSource: SavedOptionLab? { model.verifiedSources.first { $0.id.uuidString == source } }
    private var uniquePositions: [LedgerLot] {
        var seen = Set<String>()
        return model.positions.filter { seen.insert($0.instrument.identity).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("组合 Greeks · 冻结证据研究").font(.title2.bold())
            Text("按同一评估时刻汇总账本批次。Delta / Gamma 只在同标的内解释；缺证据明确留空，不代表零风险。不计算净值占比、交易限额或真实世界概率。")
                .foregroundStyle(.secondary)
            HStack {
                Button("读取本地账本") { act { await model.readLedger() } }.disabled(!model.canReadLedger)
                    .accessibilityIdentifier("portfolioGreeksReadLedger")
                Button("完整合成示例") { act { await model.calculateSynthetic(includeMissing: false) } }.disabled(model.isBusy)
                    .accessibilityIdentifier("portfolioGreeksSyntheticComplete")
                Button("含缺口合成示例") { act { await model.calculateSynthetic(includeMissing: true) } }.disabled(model.isBusy)
                    .accessibilityIdentifier("portfolioGreeksSyntheticMissing")
                Button("保存冻结报告") {
                    let reportID = model.report?.id
                    act { guard model.report?.id == reportID else { return }; await model.save() }
                }.disabled(!model.canSave)
                    .accessibilityIdentifier("portfolioGreeksSave")
                if model.canCancel { Button("取消读取／计算") { model.cancel() } }
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            if let message = model.message { Text(message).foregroundStyle(model.hasError ? .red : .secondary).accessibilityIdentifier("portfolioGreeksMessage") }
            if let inputError { Text(inputError).foregroundStyle(.red) }
            if let report = model.report { result(report) }
            if let snapshot = model.ledgerSnapshot { ledgerEditor(snapshot) }
            sourceCatalog
            savedCatalog
            Text("报告冻结所选账户的账本事件、来源报告和模型参数，随期权库归档保存。归档不恢复账户账本；普通 ZIP 不加密。输入预算不是进程内存上限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.load() }
        .onChange(of: source) { _, _ in leg = "" }
        .onChange(of: model.ledgerSnapshot?.revision) { _, _ in
            if model.ledgerSnapshot?.accounts.contains(where: { $0.id == account }) != true { account = "" }
            instrument = ""
        }
        .onChange(of: model.verifiedSources.map(\.id)) { _, ids in
            if !ids.contains(where: { $0.uuidString == source }) { source = ""; leg = "" }
        }
        .onDisappear { session = UUID(); model.disappear() }
    }
    private func ledgerEditor(_ snapshot: LedgerSnapshot) -> some View {
        GroupBox("只读账本与明确绑定") {
            VStack(alignment: .leading, spacing: 10) {
                Text("已读取账本版本：\(snapshot.revision.uuidString)").font(.caption).textSelection(.enabled)
                HStack {
                    Picker("账户", selection: Binding(get: { account }, set: { account = $0; formChanged() })) {
                        Text("请选择账户").tag("")
                        ForEach(snapshot.accounts) { Text("\($0.name) · \($0.id)").tag($0.id) }
                    }.accessibilityIdentifier("portfolioGreeksAccount")
                    TextField("评估时刻：ISO 8601，含时区", text: Binding(get: { cutoff }, set: { cutoff = $0; formChanged() }))
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("portfolioGreeksAsOf")
                    Button("采用账户与时刻") {
                        guard let date = parseDate(cutoff), !account.isEmpty else { inputError = "请选择账户并填写带时区的完整时刻。"; return }
                        inputError = nil; let selected = account
                        act { await model.configure(accountID: selected, asOf: date) }
                    }.disabled(account.isEmpty || cutoff.isEmpty)
                }
                Text("选择的是截至该经济时刻的账本重放，不是当时已知信息的 PIT 证明。报价报告必须具有完全相同的评估时刻。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.accountID != nil {
                    Text("未平仓批次：\(model.positions.count)；绑定按完整合约身份应用到同身份批次，不沿用实验室策略的数量或买卖方向。")
                    Picker("持仓身份", selection: Binding(get: { instrument }, set: { instrument = $0; evidenceSelectionChanged() })) {
                        Text("请选择持仓").tag("")
                        ForEach(uniquePositions, id: \.instrument.identity) { item in
                            Text("\(item.instrument.label) · \(item.instrument.identity)").tag(item.instrument.identity)
                        }
                    }
                    Picker("已完整核对的报告", selection: Binding(get: { source }, set: { source = $0; evidenceSelectionChanged() })) {
                        Text("请选择来源").tag("")
                        ForEach(model.verifiedSources) { item in
                            Text("\(item.report.input.underlying.symbol) · \(dateText(item.report.input.asOf)) · \(item.id.uuidString.prefix(8))")
                                .tag(item.id.uuidString)
                        }
                    }
                    if let selected = chosenSource {
                        Picker("报价对象", selection: Binding(get: { leg }, set: { leg = $0; evidenceSelectionChanged() })) {
                            Text("标的股票／ETF").tag("")
                            Text("期权腿 · \(selected.report.input.shortLeg.contractID)").tag(selected.report.input.shortLeg.contractID)
                            if let long = selected.report.input.longLeg { Text("期权腿 · \(long.contractID)").tag(long.contractID) }
                        }
                    }
                    HStack {
                        Button("明确绑定该持仓") {
                            guard let id = UUID(uuidString: source) else { return }
                            model.bind(instrumentIdentity: instrument, reportID: id, contractID: leg.isEmpty ? nil : leg)
                        }.disabled(instrument.isEmpty || chosenSource == nil)
                        Button("移除此持仓绑定") { model.removeBinding(instrument) }.disabled(instrument.isEmpty)
                        Button("计算组合风险") { act { await model.calculate() } }.disabled(!model.canCalculateLedger)
                            .accessibilityIdentifier("portfolioGreeksCalculate")
                    }
                    ForEach(model.bindings, id: \.instrumentIdentity) { binding in
                        Text("\(binding.instrumentIdentity) → \(binding.reportID.uuidString.prefix(8)) / \(binding.contractID ?? "标的报价")")
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).disabled(model.isBusy)
        }
    }
    private var sourceCatalog: some View {
        GroupBox("可选来源：已保存实验室报告") {
            VStack(alignment: .leading, spacing: 8) {
                Text("目录只列元数据。必须显式打开并完整重算核对，才可绑定。SYNTHETIC 来源不能用于普通账本。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.sourceError { Text(error).foregroundStyle(.red) }
                if model.sources.isEmpty { Text("尚无来源报告。可先在实验室保存完整报告，或使用上方独立合成示例。").foregroundStyle(.secondary) }
                ForEach(model.sources) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(item.underlyingSymbol) · \(item.origin.rawValue.uppercased())")
                            Text("\(dateText(item.asOf)) · \(item.id.uuidString)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("打开并核对来源") { act { await model.openSource(item.id) } }.disabled(model.isBusy)
                            .accessibilityIdentifier("portfolioGreeksSource-" + item.id.uuidString)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var savedCatalog: some View {
        GroupBox("已保存组合报告") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("只列冻结元数据；重开后完整重放通过才显示数值。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新载入目录") { act { await model.load() } }.disabled(model.isBusy).accessibilityIdentifier("portfolioGreeksReload")
                }
                if let error = model.listError { Text(error).foregroundStyle(.red) }
                if model.saved.isEmpty { Text("尚无已保存组合报告。").foregroundStyle(.secondary) }
                ForEach(model.saved) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(item.mode == .synthetic ? "SYNTHETIC 示例" : item.accountID) · \(dateText(item.asOf))")
                            Text("\(item.positionCount) 个批次 · 冻结版本 \(item.ledgerRevision.uuidString.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("打开并重放") { act { await model.open(item.id) } }.disabled(model.isBusy)
                            .accessibilityIdentifier("portfolioGreeksOpen-" + item.id.uuidString)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func result(_ report: PortfolioGreeksReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.input.mode == .synthetic ? "SYNTHETIC · 独立合成组合" : "只读账本 · 冻结历史研究")
                .font(.headline).foregroundStyle(report.input.mode == .synthetic ? .orange : .primary)
                .accessibilityIdentifier("portfolioGreeksOrigin")
            Text(model.savedID == nil ? "本次完整输入已计算，尚未保存" : "已按冻结账本与来源完整重放核对")
                .accessibilityIdentifier("portfolioGreeksReplayStatus")
            Text("覆盖 \(report.coverage.coveredPositions) / \(report.coverage.totalPositions) 个批次 · 缺口 \(report.coverage.missingPositions)")
                .font(.headline).accessibilityIdentifier("portfolioGreeksCoverage")
            Text(report.coverage.isComplete ? "声明持仓范围完整覆盖" : "覆盖不完整：以下数值仅属于已覆盖部分，完整组合汇总不可用。")
                .foregroundStyle(report.coverage.isComplete ? .secondary : .orange)
                .accessibilityIdentifier("portfolioGreeksCompleteness")
            Text("账户 \(report.input.accountID) · 评估 \(dateText(report.input.asOf))\n冻结账本版本：\(report.input.ledgerRevision.uuidString)")
                .font(.caption).textSelection(.enabled)
            if report.input.mode == .ledger {
                Text(model.currentLedgerRevision.map { "最近一次明确读取的当前版本：\($0.uuidString)；\($0 == report.input.ledgerRevision ? "当次相同" : "已不同")。" }
                     ?? "当前账本版本尚未读取核对；不能将此历史报告称为当前组合。")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("portfolioGreeksRevisionStatus")
                Button("只读核对当前账本版本") { act { await model.checkLedgerRevision() } }.disabled(!model.canReadLedger)
            }
            if let totals = report.coveredTotals {
                GroupBox(report.coverage.isComplete ? "声明持仓范围的金额敞口" : "已覆盖部分的金额敞口 · 非完整组合") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("净 Delta 美元：\(number(totals.netDeltaDollars)) USD").accessibilityIdentifier("portfolioGreeksNetDelta")
                        Text("毛 Delta 美元：\(number(totals.grossDeltaDollars)) USD")
                        Text("Theta：\(number(totals.thetaDollarsPerDay)) USD / 日历日")
                        Text("Vega：\(number(totals.vegaDollarsPerPercentagePoint)) USD / 波动率百分点")
                        Text("Rho：\(number(totals.rhoDollarsPerPercentagePoint)) USD / 利率百分点")
                        Text("毛敞口先对每批次取绝对值再求和。Vega / Rho 是各持仓自身假设同时变动 1 个百分点的局部敏感度；不是市场联动预测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox("按标的与到期日") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(group.underlyingSymbol) · \(group.expirationDate?.iso8601 ?? "股票／ETF") · \(group.coverage.coveredPositions)/\(group.coverage.totalPositions)").font(.headline)
                            if let values = group.covered { greekValues(values) }
                            else { Text("缺证据，未生成数值。").foregroundStyle(.secondary) }
                            if !group.coverage.isComplete { Text("仅已覆盖部分；该分组完整汇总不可用。").font(.caption).foregroundStyle(.orange) }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("逐批次来源与缺口") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(row.instrument.label) · 批次 \(row.id)").font(.headline)
                            Text("有符号数量 \(row.signedQuantity.decimalString) · 乘数 \(row.multiplier.decimalString)").font(.caption)
                            if let values = row.values { greekValues(values) }
                            if let gap = row.gap { Text("不可用：\(gapText(gap))").foregroundStyle(.orange) }
                            if let id = row.reportID { Text("来源报告 \(id.uuidString) · \(row.contractID ?? "标的报价")").font(.caption).textSelection(.enabled) }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("欧式 BSM 局部敏感度，不含提前行权、离散股息或可执行限额；美式合约仅作模型参考。重放误差与跨 CPU/libm 行为仍按模型边界处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func greekValues(_ values: PortfolioGreeksValues) -> some View {
        Text("Delta \(number(values.deltaShares)) 股 · Gamma \(number(values.gammaSharesPerDollar)) 股/USD\nTheta \(number(values.thetaDollarsPerDay)) USD/日 · Vega \(number(values.vegaDollarsPerPercentagePoint)) USD/百分点 · Rho \(number(values.rhoDollarsPerPercentagePoint)) USD/百分点")
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
    private func formChanged() {
        formRevision = UUID(); model.draftChanged(); instrument = ""; source = ""; leg = ""; inputError = nil
    }
    private func evidenceSelectionChanged() {
        formRevision = UUID(); model.evidenceSelectionChanged(); inputError = nil
    }
    private func act(_ action: @escaping @MainActor () async -> Void) {
        let token = session, form = formRevision
        Task { guard session == token, formRevision == form else { return }; await action() }
    }
    private func number(_ value: Double) -> String { String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value) }
    private func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter(); full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    private func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private func gapText(_ gap: PortfolioGreeksGap) -> String {
        switch gap {
        case .missingBinding: "未明确绑定来源"
        case .missingReport: "缺少完整报告"
        case .missingContract: "来源不含所选合约"
        case .missingPricing: "缺本地定价输入"
        case .missingIV: "IV 反解不可用，不回退手工 σ"
        case .unsupportedContract: "合约交付或乘数不受当前模型支持"
        case .mismatchedContract: "合约身份、权利、执行价或到期不一致"
        case .mismatchedAsOf: "评估时刻不一致"
        case .staleQuote: "报价时效不符合离线计算合同"
        case .inconsistentUnderlying: "同标的价格证据不一致"
        }
    }
}
