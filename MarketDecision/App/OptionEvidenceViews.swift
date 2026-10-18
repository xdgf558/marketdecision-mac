import SwiftUI
import AppComposition
import CoreDomain
import OptionsAnalytics
import PortfolioEngine
import Persistence

/// Existing laboratory system controls. Only explicit complete offline inputs are
/// evaluated; changing the form invalidates the prior report before a new task starts.
struct OptionEvidenceContent: View {
    @Bindable var model: OptionEvidenceWorkspaceModel
    @State private var kind: OptionEvidenceKind = .providerComparison
    @State private var draft = ""
    @State private var showInput = false
    @State private var inputError: String?
    @State private var session = UUID()
    @State private var formRevision = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("数据对照与交易归因").font(.title2.bold())
            Text("以完整离线证据研究供应商差异、25-Delta 波动率和开仓时点分组。供应商值不替代本地计算，未知历史不使用当前数据回填。")
                .foregroundStyle(.secondary)
            Picker("研究类型", selection: Binding(get: { kind }, set: { value in
                guard kind != value else { return }; kind = value; draft = ""; changed()
            })) {
                ForEach(OptionEvidenceKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(!model.canEdit).accessibilityIdentifier("optionEvidenceKind")
            HStack {
                Button("载入合成证据") {
                    changed()
                    do { draft = try OptionEvidenceWorkspaceModel.demoJSON(kind) }
                    catch { inputError = "合成模板未能建立，没有填入替代值。" }
                }.disabled(!model.canEdit || model.isBusy).accessibilityIdentifier("optionEvidenceTemplate")
                Button("计算并核对") {
                    let text = draft, selection = kind
                    act { await model.calculateJSON(text, kind: selection) }
                }.disabled(draft.isEmpty || model.isBusy || !model.canEdit).accessibilityIdentifier("optionEvidenceCalculate")
                Button("保存冻结报告") {
                    let id = model.report?.id
                    act { guard model.report?.id == id else { return }; await model.save() }
                }.disabled(!model.canSave).accessibilityIdentifier("optionEvidenceSave")
                if model.canCancel { Button("取消计算") { model.cancel() }.accessibilityIdentifier("optionEvidenceCancel") }
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            if let message = model.message {
                Text(message).foregroundStyle(model.hasError ? Color.red : Color.secondary).accessibilityIdentifier("optionEvidenceMessage")
            }
            if let inputError { Text(inputError).foregroundStyle(.red) }
            DisclosureGroup("完整离线证据（JSON）", isExpanded: $showInput) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("载入模板后可检查或编辑完整来源、时间、单位和模型引用。缺少证据会保留缺口或拒绝计算；修改输入即清除旧结果。仅编辑来源文字不会授予真实数据资格。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { draft }, set: { draft = $0; changed() }))
                        .font(.system(.caption, design: .monospaced)).frame(minHeight: 180, maxHeight: 300)
                        .disabled(!model.canEdit).accessibilityIdentifier("optionEvidenceInput")
                }.padding(.top, 8)
            }.accessibilityIdentifier("optionEvidenceInputDisclosure")
            if let report = model.report { result(report) }
            else {
                Text("尚无已核对报告。载入合成证据或填写完整离线输入后，显式计算。")
                    .foregroundStyle(.secondary).accessibilityIdentifier("optionEvidenceEmpty")
            }
            catalog
            Text("报告随期权库归档保留完整输入、参数和结果；重开前完整重放，不写入账户账本。普通 ZIP 不加密，输入预算不是进程内存上限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.load() }
        .onChange(of: model.report?.id) { _, _ in
            guard let report = model.report else { return }
            // Direct state assignment synchronizes an opened report without going
            // through the user-edit binding and clearing that same report.
            kind = report.input.kind
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(report.input) { draft = String(decoding: data, as: UTF8.self) }
        }
        .onDisappear { session = UUID(); model.disappear() }
    }
    private var catalog: some View {
        GroupBox("已保存的离线证据报告") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("目录仅含元数据，打开并完整重算通过后才显示数值。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新载入目录") { act { await model.load() } }.disabled(model.isBusy || !model.canEdit)
                        .accessibilityIdentifier("optionEvidenceReload")
                }
                if let error = model.listError { Text(error).foregroundStyle(.red) }
                if model.saved.isEmpty { Text("尚无已保存报告。").foregroundStyle(.secondary) }
                ForEach(model.saved) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(item.kind.title) · \(item.containsSynthetic ? "SYNTHETIC" : "离线记录")")
                            Text("\(dateText(item.createdAt)) · \(item.id.uuidString)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("打开并重放") { act { await model.open(item.id) } }.disabled(model.isBusy || !model.canEdit)
                            .accessibilityIdentifier("optionEvidenceOpen-" + item.id.uuidString)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func result(_ report: OptionEvidenceReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.containsSynthetic ? "SYNTHETIC · 离线合成研究" : "离线来源记录 · 仅供研究")
                .font(.headline).foregroundStyle(report.containsSynthetic ? Color.orange : Color.primary)
                .accessibilityIdentifier("optionEvidenceOrigin")
            Text(model.savedID == nil ? "完整输入已计算，尚未保存" : "已按冻结输入完整重放核对")
                .accessibilityIdentifier("optionEvidenceReplay")
            switch report {
            case .providerComparison(let value): providerResult(value)
            case .delta25(let value): deltaResult(value)
            case .tradeAttribution(let value): attributionResult(value)
            }
        }
    }
    private func providerResult(_ report: OptionProviderComparisonReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IV / Greeks 对照").font(.headline).accessibilityIdentifier("optionEvidenceProviderTitle")
            Text("本地数据源：\(report.input.localFeedID) · 评估：\(dateText(report.input.localReport.input.asOf))")
                .font(.caption).textSelection(.enabled)
            ForEach(report.rows, id: \.contractID) { row in
                GroupBox(row.contractID) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(modelLabel(row.modelComparison)).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("字段"); Text("本地"); Text("供应商"); Text("本地 − 供应商"); Text("阈值判断") }.font(.caption.bold())
                            ForEach(row.fields, id: \.field) { item in
                                GridRow {
                                    Text(fieldLabel(item.field))
                                    Text(number(item.local)).monospacedDigit()
                                    Text(number(item.provider)).monospacedDigit()
                                    Text(number(item.difference)).monospacedDigit()
                                    Text(alertLabel(item)).foregroundStyle(item.thresholdExceeded == true ? Color.orange : Color.secondary)
                                }
                            }
                        }.font(.callout)
                        ForEach(row.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            notes(report.limitations)
        }
    }
    private func deltaResult(_ report: OptionDelta25Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("25-Delta 波动率 · 30 日同期限").font(.headline).accessibilityIdentifier("optionEvidenceDeltaTitle")
            Text("Call IV：\(volatility(report.call25DeltaIV)) · Put IV：\(volatility(report.put25DeltaIV)) · Put − Call：\(number(report.putMinusCallSkew))（十进制波动率）")
                .accessibilityIdentifier("optionEvidenceDeltaValues")
            Text("状态：\(deltaState(report.state)) · 来源：\(report.input.daily.input.feedID) · \(report.input.daily.input.session.iso8601)")
                .font(.caption).textSelection(.enabled)
            Text("两侧使用同一到期或到期夹点；无夹点、缺规范 IV 或数据不足均不外推。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(report.expiries, id: \.settlementAt) { expiry in
                GroupBox(dateText(expiry.settlementAt)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(deltaState(expiry.state)) · Put − Call：\(number(expiry.putMinusCallSkew))")
                        selection(expiry.call)
                        selection(expiry.put)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            notes(report.limitations)
        }
    }
    private func selection(_ value: OptionDelta25Selection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value.right == .call ? "Call +0.25" : "Put −0.25")：\(volatility(value.iv)) · \(deltaState(value.state))")
            ForEach(value.points, id: \.contractID) { point in
                Text("\(point.contractID) · K=\(point.strike.decimalString) · Delta=\(number(point.delta)) · IV=\(volatility(point.iv))")
                    .font(.caption).textSelection(.enabled)
            }
            if let weight = value.secondPointWeight { Text("第二夹点权重：\(number(weight))").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func attributionResult(_ report: TradeOptionAttributionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("交易时点归因").font(.headline).accessibilityIdentifier("optionEvidenceAttributionTitle")
            Text("按开仓时实际记录的 Delta / IV Rank 分组。未知记录独立保留；已记录但方法未核对的 IV Rank 与完整历史重放分开统计。")
                .foregroundStyle(.secondary)
            ForEach(report.rows) { row in
                GroupBox(row.instrument.label + " · " + row.round.roundLotID) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开仓事件：\(row.openingEventID)").font(.caption).textSelection(.enabled)
                        Text("Delta：\(number(row.delta)) · IV：\(volatility(row.impliedVolatility)) · IV Rank：\(number(row.ivRank))")
                        Text("Delta：\(gap(row.deltaGap)) · IV Rank：\(gap(row.ivRankGap)) · \(basis(row.ivRankBasis))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("净损益：\(row.round.netPnL?.decimalString ?? "不可用") USD · \(row.round.reason)").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(report.groupedStatistics) { group in
                GroupBox("\(group.axis == .absoluteDelta ? "|Delta|" : "IV Rank") · \(group.label)") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(group.roundIDs.count) 个回合 · 可计入统计 \(group.statistics.eligibleN) · 记录 \(basis(group.ivRankBasis))")
                        Text("已完成净损益：\(group.completedNetPnL?.decimalString ?? "不可用") USD；盈利 \(group.statistics.wins) / 亏损 \(group.statistics.losses) / 零损益 \(group.statistics.zeros)")
                            .font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !report.excludedNonOptionRoundIDs.isEmpty {
                Text("非期权回合未进入 Delta / IV 分组：\(report.excludedNonOptionRoundIDs.count) 个。 ").font(.caption).foregroundStyle(.secondary)
            }
            notes(report.limitations)
        }
    }
    private func notes(_ values: [String]) -> some View {
        DisclosureGroup("方法与限制") { VStack(alignment: .leading, spacing: 5) { ForEach(values, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) } } }
    }
    private func changed() { formRevision = UUID(); model.draftChanged(); inputError = nil }
    private func act(_ operation: @escaping @MainActor () async -> Void) {
        let token = session, form = formRevision
        Task { guard session == token, formRevision == form else { return }; await operation() }
    }
    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "不可用" }
        return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private func volatility(_ value: Double?) -> String { value.map { number($0 * 100) + "%" } ?? "不可用" }
    private func dateText(_ value: Date) -> String { value.formatted(date: .numeric, time: .standard) }
    private func fieldLabel(_ value: OptionProviderField) -> String {
        switch value {
        case .iv: "IV（十进制）"
        case .delta: "Delta / 股"
        case .gamma: "Gamma / 股 / USD"
        case .theta: "Theta / 股 / 日历日"
        case .vega: "Vega / 股 / 百分点"
        case .rho: "Rho / 股 / 百分点"
        }
    }
    private func alertLabel(_ value: OptionProviderComparisonField) -> String {
        if value.state != .compared { return "缺少数值" }
        guard let exceeded = value.thresholdExceeded else { return value.absoluteThreshold == nil ? "只列差值" : "模型未具可比性" }
        return exceeded ? "超过 \(number(value.absoluteThreshold))" : "未超过 \(number(value.absoluteThreshold))"
    }
    private func modelLabel(_ value: OptionProviderModelComparison) -> String {
        switch value {
        case .sameEuropeanReference: "同为欧式连续股息参考；已知假设匹配"
        case .differentAssumptions: "假设不同；仅显示数值诊断"
        case .differentModel: "模型家族不同；仅显示数值诊断"
        case .unknownModel: "模型或假设未知；不判定偏差警报"
        case .missingLocalPricing: "缺少本地定价证据"
        }
    }
    private func deltaState(_ value: OptionDelta25State) -> String {
        switch value {
        case .available: "可重放"
        case .partialChain: "链范围不完整"
        case .unverifiedSessionClose: "收盘时点未核对"
        case .unknownQuoteTime: "报价时刻未知"
        case .quoteSkew: "报价时差超限"
        case .missingCanonicalIV: "缺规范 IV"
        case .nonMonotoneDelta: "Delta 不单调"
        case .noDeltaBracket: "没有 Delta 夹点"
        case .noExpiryBracket: "没有期限夹点"
        case .numericFailure: "数值计算不可用"
        case .missingSide: "缺少 Call 或 Put"
        case .mismatchedContractBasis: "合约规格口径不一致"
        }
    }
    private func gap(_ value: TradeOptionAttributionGap?) -> String {
        switch value {
        case nil: "有冻结记录"
        case .missingObservation: "未知（未记录）"
        case .missingCanonicalIV: "缺规范 IV"
        case .missingIVRank: "IV Rank 未记录"
        case .transferredOpening: "转入持仓缺开仓证据"
        }
    }
    private func basis(_ value: TradeOptionIVRankBasis?) -> String {
        switch value { case nil: "不适用或未知"; case .recordedUnverified: "已记录，方法未核对"; case .replayedHistory: "完整历史已重放" }
    }
}
