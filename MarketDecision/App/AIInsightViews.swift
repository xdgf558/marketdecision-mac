import SwiftUI
import AppComposition
import AIInsights
import CoreDomain
import Persistence

struct AISettingsView: View {
    let credentials: CredentialSettingsModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openAIFinancialModel") private var modelName = "gpt-6-luna"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 财报解读设置").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.top, 20)
            Form {
                Section("模型") {
                    TextField("OpenAI 模型 ID", text: $modelName).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("aiModelID")
                    Text("默认 gpt-6-luna。可填写账户支持的 Responses / Structured Outputs 模型；API 单独按使用量计费。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CredentialSettingsSection(model: credentials, title: "OpenAI API Key",
                    explanation: "密钥只存入本机钥匙串，不会回显。点击 AI 解读时用于向 OpenAI 认证，不放入分析正文。保存不代表账户或额度已验证。",
                    identifierPrefix: "aiCredential")
                Section("发送范围") {
                    Text("发送当前公司的财务摘要与本地计算引用。补充估值资料后，还会发送你确认可用于 AI 的参考价、实际股数、日期及本地参考倍数。同一次请求生成解读，并在收入与股数齐备时提出三个目标市销率假设；你确认后才在本地计算情景股价。不发送持仓、交易记录、完整财报或 SEC 联系邮箱。")
                    Text("请求关闭响应存储（store=false）；这不等于零保留，服务方仍可能按政策保留安全监测记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("OpenAI 数据使用说明", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                }
            }.formStyle(.grouped)
        }.frame(minWidth: 540, idealWidth: 600, minHeight: 540, idealHeight: 660)
    }
}

struct AIInsightCard: View {
    @Bindable var model: AIInsightWorkspaceModel
    let researchModel: SECResearchWorkspaceModel
    let report: SECFinancialReportDocument
    let reportRevision: UUID
    @State private var showsSettings = false
    @State private var showsValuationInputs = false
    @State private var detail: AIInsightDetail?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("openAIFinancialModel") private var modelName = "gpt-6-luna"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI 财报解读", systemImage: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Button("AI 设置") { showsSettings = true }
                    .buttonStyle(.link).font(.system(size: 12))
                    .accessibilityIdentifier("aiSettings")
            }
            if matchesSelection, let result = model.result, model.input != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("结论").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    // The overview is a bounded excerpt of the validated conclusion.
                    // The complete answer, including every risk, remains one click away.
                    Text(verbatim: result.analysis.summary.text)
                        .font(.system(size: 14)).lineLimit(6)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("aiConclusion")
                    HStack {
                        Text("风险 \(result.analysis.risks.count) 项 · 待核实 \(result.analysis.questions.count) 项")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("查看完整解读") { detail = .analysis }
                            .buttonStyle(.link).font(.system(size: 12))
                            .accessibilityIdentifier("aiShowFullAnalysis")
                    }
                }
            } else {
                emptyState
            }
            Divider().opacity(0.6)
            analysisActions
            if matchesSelection, let message = model.message, model.hasError || model.result == nil {
                Text(message).font(.system(size: 12))
                    .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .textSelection(.enabled).accessibilityIdentifier("aiMessage")
            }
            if !model.networkAvailable {
                Text("AI 网络服务不可用（服务缺失或校验未通过）。未发送请求，本地财务报告可照常使用。[AI-SERVICE]")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("aiUnavailable")
            }
            Text("手动发送财报摘要至 OpenAI，按 API 用量计费；不发送持仓或交易。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("数值以本地计算为准 · AI 解读仅供研究")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("发送内容与隐私") { detail = .privacy }
                    .buttonStyle(.link).font(.system(size: 11))
                    .accessibilityIdentifier("aiShowPrivacy")
            }
        }.padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.accentColor.opacity(colorScheme == .dark ? 0.09 : 0.035),
                        in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("aiInsightCard")
            .sheet(isPresented: $showsSettings) { AISettingsView(credentials: model.credentials) }
            .sheet(isPresented: $showsValuationInputs) {
                AIValuationReferenceEditor(model: model, researchModel: researchModel,
                    report: report, reportRevision: reportRevision)
            }
            .sheet(item: $detail) { selected in
                AICompactDetailSheet(title: selected == .analysis ? "AI 财报解读" : "发送内容与隐私") {
                    if selected == .analysis { fullAnalysis } else { privacyDetails }
                }
            }
            .onAppear { model.select(reportID: report.id, revision: reportRevision) }
            .onChange(of: reportRevision) { _, revision in
                showsValuationInputs = false
                detail = nil
                model.select(reportID: report.id, revision: revision)
            }
            .onChange(of: model.selectedReportID) { _, _ in detail = nil }
            .onChange(of: model.selectedReportRevision) { _, _ in detail = nil }
            .onChange(of: model.result?.inputDigest) { _, _ in detail = nil }
            .onChange(of: model.credentials.revision) { _, _ in model.credentialsChanged() }
            .onChange(of: modelName) { _, _ in model.cancel() }
            // SECResearchContent owns selection and SECResearchPage owns disappearance.
            // Hiding this card in another section must not discard the same report's answer.
    }

    private var emptyState: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 25, weight: .light)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isBusy ? "正在生成解读" : "尚未生成解读")
                    .font(.system(size: 15, weight: .semibold))
                Text("梳理财报优势与风险，并同步生成估值解读。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var analysisActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { analyzeButton; valuationInputButton; cancelButton }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { analyzeButton; cancelButton }
                valuationInputButton
            }
        }
    }

    private var analyzeButton: some View {
        Button {
            model.select(reportID: report.id, revision: reportRevision)
            model.startAnalysis(report: report, revision: reportRevision, model: modelName)
        } label: {
            Text(model.result == nil ? "发送摘要并分析" : "重新发送并分析")
        }.buttonStyle(StockActionButtonStyle(kind: .outline))
            .disabled(model.isBusy || !model.networkAvailable)
            .accessibilityIdentifier("aiAnalyze")
    }

    private var valuationInputButton: some View {
        Button(model.valuationReference == nil ? "补充股价与股数" : "修改估值资料") {
            showsValuationInputs = true
        }.buttonStyle(.link).font(.system(size: 12))
            .disabled(model.isBusy || researchModel.isBusy)
            .accessibilityIdentifier("aiValuationInputs")
    }

    @ViewBuilder private var cancelButton: some View {
        if model.isBusy {
            ProgressView().controlSize(.small)
            Button("取消") { model.cancel() }.accessibilityIdentifier("aiCancel")
        }
    }

    @ViewBuilder private var fullAnalysis: some View {
        if matchesSelection, let result = model.result, model.input != nil {
            Text("数值仍以本地计算为准。AI 解读可能出错，仅供理解财报，不构成买卖建议。")
                .font(.caption).foregroundStyle(.secondary)
            claims("优势", result.analysis.strengths)
            claims("风险", result.analysis.risks)
            claims("需要核实", result.analysis.questions)
            claims("解读范围与限制", result.analysis.limitations)
            Divider()
            Text("结论").font(.headline)
            claim(result.analysis.summary)
        } else {
            Text("当前报告已变化，请回到股票分析查看新的结果。")
                .foregroundStyle(.secondary)
        }
    }

    private var privacyDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("默认发送 35 项财务指标及三个本地计算引用。补充估值资料后，另发送你确认的参考价、实际股数、各自日期，以及本地计算的参考市值、市盈率、市销率和自由现金流倍数。完整财报、持仓、交易记录与本地报告标识不发送。")
            Text("只发送本次明确提供的参考输入，不转发仅获本地使用权的采集行情。倍数使用 TTM 财务数据；AI 可提出明确标为假设的保守／中性／乐观目标市销率，不冒充同业或历史基准；你确认后，本地按 TTM 收入和股数计算情景股价，不额外发送请求，也不承诺合理价值。概览期间切换不会自动分析。")
            if matchesSelection, let input = model.input {
                Text("本次摘要指标").font(.headline)
                ForEach(input.metrics, id: \.id) { metric in
                    HStack(alignment: .top) {
                        Text(metric.label)
                        Spacer()
                        Text(metric.value.map { $0 + " " + metric.unit } ?? "缺少证据")
                            .monospacedDigit().textSelection(.enabled)
                    }.font(.caption)
                }
            }
            Text("财报解读、估值假设及情景价格仅在当前股票页面保留；切换报告、重新核对财报或离开页面会一起清除。保存分析和研究归档均不包含 AI 回答或情景价格。取消后已发出的请求仍可能计费。")
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }

    private var matchesSelection: Bool {
        model.selectedReportID == report.id && model.selectedReportRevision == reportRevision
    }
    private func claims(_ title: String, _ values: [AIInsightClaim]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !values.isEmpty {
                Text(title).font(.headline)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in claim(value) }
            }
        }
    }
    private func claim(_ value: AIInsightClaim) -> some View {
        // Evidence remains in the validated result. Plain text cannot create active links.
        Text(verbatim: value.text).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private enum AIInsightDetail: String, Identifiable, Equatable {
    case analysis, privacy
    var id: String { rawValue }
}

/// Full text lives in a bounded secondary surface; expanding it never lengthens the overview.
private struct AICompactDetailSheet<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.dismiss) private var dismiss

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
        }.padding(20).frame(width: 610, height: 520)
    }
}

/// A second presentation of the same validated response, never a separate request or
/// a replacement for the locally computed, evidence-bound valuation supplement.
struct AIValuationReferenceCard: View {
    @Bindable var model: AIInsightWorkspaceModel
    let reportID: UUID
    let reportRevision: UUID
    let localDetailsDisabled: Bool
    let showLocalDetails: () -> Void
    @State private var showsDetails = false

    private var matchesSelection: Bool {
        model.selectedReportID == reportID && model.selectedReportRevision == reportRevision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("AI 估值参考").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 4)
                Button("本地估值资料", action: showLocalDetails)
                    .buttonStyle(.link).font(.system(size: 11)).disabled(localDetailsDisabled)
                    .accessibilityIdentifier("stockOverviewOpenValuation")
            }
            if matchesSelection, let reference = model.valuationReference {
                // The comparison price is the user's input, never an AI target price.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("参考股价").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("$" + reference.price.decimalString)
                        .font(.system(size: 18, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                        .accessibilityIdentifier("aiValuationReferencePrice")
                    Text("USD / 股 · 手工输入，非推算价")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if matchesSelection, let result = model.result, model.input != nil {
                if let proposal = result.analysis.valuation.scenarioProposal, let proposalID = model.valuationProposalID {
                    AIValuationScenarioSection(model: model, proposal: proposal, proposalID: proposalID,
                        reportID: reportID, reportRevision: reportRevision, inputDigest: result.inputDigest,
                        showDetails: { showsDetails = true })
                } else {
                    Text(verbatim: result.analysis.valuation.interpretation.text)
                        .font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                        .accessibilityIdentifier("aiValuationInterpretation")
                    Text("资料不足时不生成情景股价。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("查看估值解读与缺项") { showsDetails = true }
                        .buttonStyle(.link).font(.system(size: 12))
                        .accessibilityIdentifier("aiShowValuationDetails")
                }
                if !result.analysis.valuation.limitations.isEmpty {
                    Button("资料限制 \(result.analysis.valuation.limitations.count) 项 · 查看") { showsDetails = true }
                        .buttonStyle(.link).font(.system(size: 11))
                        .accessibilityIdentifier("aiValuationLimitation")
                }
            } else if matchesSelection && model.isBusy && model.message == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在生成估值解读").font(.system(size: 13))
                }
            } else {
                Text(matchesSelection && model.hasError ? "估值解读未生成" : "随 AI 分析一并生成")
                    .font(.system(size: 15, weight: .semibold))
                Text(matchesSelection && model.hasError
                     ? "请查看 AI 财报解读中的错误提示，手动重试。"
                     : "补充资料并分析后，确认三档假设即可计算股价。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("stockMetric-valuation")
            .sheet(isPresented: $showsDetails) {
                AICompactDetailSheet(title: "估值解读、假设与限制") { valuationDetails }
            }
            .onChange(of: reportID) { _, _ in showsDetails = false }
            .onChange(of: reportRevision) { _, _ in showsDetails = false }
            .onChange(of: model.selectedReportID) { _, _ in showsDetails = false }
            .onChange(of: model.selectedReportRevision) { _, _ in showsDetails = false }
            .onChange(of: model.result?.inputDigest) { _, _ in showsDetails = false }
    }

    @ViewBuilder private var valuationDetails: some View {
        if matchesSelection, let result = model.result, let input = model.input {
            Text(verbatim: result.analysis.valuation.interpretation.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("aiValuationFullInterpretation")
            if let proposal = result.analysis.valuation.scenarioProposal {
                Text("三档目标市销率假设").font(.headline)
                Text("AI 主观情景假设，未获同业或历史估值验证；不是已证实的合理价或买卖建议。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([("保守", proposal.conservative), ("中性", proposal.base), ("乐观", proposal.optimistic)], id: \.0) { title, assumption in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title + " · P/S " + assumption.multiple + "×").font(.system(size: 13, weight: .semibold))
                        Text(verbatim: assumption.rationale.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("推算方法：TTM 收入 × 目标市销率 ÷ 已确认股数；财报期末 " + input.periodEnd + "。仅在主页面确认后本地计算，不额外发送 API 请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("资料限制").font(.headline)
            ForEach(Array(result.analysis.valuation.limitations.enumerated()), id: \.offset) { _, value in
                Text(verbatim: value.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if input.referenceValuation != nil { referenceMultiples(input) }
            Text(input.referenceValuation == nil
                 ? "尚未补充参考价和实际股数；可点击“补充股价与股数”。"
                 : "当前倍数按手工参考价计算；情景股价取决于确认的假设，非实时行情或保证合理价值。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("当前报告或参考资料已变化，请回到股票分析查看新的结果。")
                .foregroundStyle(.secondary)
        }
    }

    private func referenceMultiples(_ input: AIInsightInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .top, spacing: 14) {
                ForEach([("reference.pe", "市盈率"), ("reference.ps", "市销率"),
                         ("reference.pfcf", "自由现金流倍数")], id: \.0) { id, title in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                        let metric = input.metrics.first(where: { $0.id == id })
                        Text(metric?.value.map { value in
                            if let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) {
                                return decimal > 0 && decimal < Decimal(1) / Decimal(100)
                                    ? "<0.01×" : decimal.formatted(.number.precision(.fractionLength(2))) + "×"
                            }
                            return "待补充"
                        } ?? referenceMissingText(metric?.unavailable, id: id))
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let context = input.referenceValuation {
                Text("参考价时刻 \(String(context.referenceAt.prefix(19)).replacingOccurrences(of: "T", with: " ")) UTC · 股数截至 \(context.sharesAsOf)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private func referenceMissingText(_ reason: String?, id: String) -> String {
        switch reason {
        case "nonpositiveDenominator": return "分母非正，不适用"
        case "belowCalculationPrecision": return "低于计算精度"
        default:
            switch id {
            case "reference.pe": return "缺少普通股利润"
            case "reference.ps": return "缺少收入"
            default: return "缺少自由现金流"
            }
        }
    }
}

/// Model-suggested multiples remain visible assumptions until a single explicit
/// confirmation computes prices locally. This view never dispatches another request.
private struct AIValuationScenarioSection: View {
    @Bindable var model: AIInsightWorkspaceModel
    let proposal: AIPriceSalesScenarioProposal
    let proposalID: UUID
    let reportID: UUID
    let reportRevision: UUID
    let inputDigest: String
    let showDetails: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.48, green: 0.77, blue: 0.68)
            : Color(red: 0.10, green: 0.34, blue: 0.31)
    }
    private var assumptions: [(String, AIPriceSalesScenarioAssumption)] {
        [("保守", proposal.conservative), ("中性", proposal.base), ("乐观", proposal.optimistic)]
    }
    private var calculation: AIValuationScenarioCalculation? {
        guard model.valuationProposalID == proposalID,
              let value = model.valuationScenarioCalculation,
              value.inputDigest == inputDigest, value.proposal == proposal else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(calculation == nil ? "目标市销率假设" : "估值推算价")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(calculation == nil ? "AI 提议 · 待确认" : "已确认假设 · USD / 股")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let calculation {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(calculation.rows, id: \.scenario.rawValue) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(row.scenario)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(priceText(row.price)).font(.system(size: 23, weight: .semibold))
                                .monospacedDigit().foregroundStyle(accent).textSelection(.enabled)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .help(priceText(row.price) + " USD / 股")
                            Text("P/S " + row.targetMultiple.decimalString + "×")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("aiScenarioPrice-" + row.scenario.rawValue)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(assumptions, id: \.0) { title, assumption in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(assumption.multiple + "×").font(.system(size: 18, weight: .semibold))
                                .monospacedDigit().textSelection(.enabled)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .help("目标市销率 " + assumption.multiple + "×；完整说明见“假设与解读”。")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("主观假设，非已证实合理价；按 TTM 收入与股数计算。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("假设与解读", action: showDetails)
                    .buttonStyle(.link).font(.system(size: 11))
                    .accessibilityIdentifier("aiShowValuationDetails")
            }
            if calculation == nil {
                Button("确认这组假设并计算股价") {
                    model.confirmValuationScenarios(proposalID: proposalID,
                        reportID: reportID, reportRevision: reportRevision)
                }.buttonStyle(StockActionButtonStyle(kind: .outline))
                    .disabled(model.isBusy || model.valuationProposalID != proposalID)
                    .accessibilityIdentifier("aiConfirmValuationScenarios")
                    .help("确认仅在本地计算，不再调用 API。")
            }
            if let message = model.valuationScenarioMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("aiValuationScenarioMessage")
            }
        }.padding(8)
            .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("aiValuationScenarios")
    }
    private func title(_ scenario: AIValuationScenario) -> String {
        switch scenario {
        case .conservative: return "保守"
        case .base: return "中性"
        case .optimistic: return "乐观"
        }
    }
    private func priceText(_ value: Money) -> String {
        if value.amount > 0 && value.amount < Decimal(1) / Decimal(100) { return "<$0.01" }
        return "$" + ((try? value.fixedString()) ?? value.decimalString)
    }
}

/// Edits explicit reference inputs only. Neither opening nor applying this sheet sends
/// an API request; captured provider quotes and their rights are never copied into it.
private struct AIValuationReferenceEditor: View {
    @Bindable var model: AIInsightWorkspaceModel
    @Bindable var researchModel: SECResearchWorkspaceModel
    let report: SECFinancialReportDocument
    let reportRevision: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIValuationReferenceDraft
    @State private var message: String?
    @State private var isLoadingShares = false
    @State private var candidate: SECShareCountCandidate?
    @State private var sourceTask: Task<Void, Never>?

    init(model: AIInsightWorkspaceModel, researchModel: SECResearchWorkspaceModel,
         report: SECFinancialReportDocument, reportRevision: UUID) {
        self.model = model; self.researchModel = researchModel
        self.report = report; self.reportRevision = reportRevision
        var value = AIValuationReferenceDraft(now: Date())
        if let current = model.valuationReference {
            value.price = current.price.decimalString
            value.referenceAt = current.referenceAt
            value.shares = current.shares.decimalString
            value.sharesAsOf = current.sharesAsOf.iso8601
            value.confirmedSingleClassSameBasis = true
            value.maySendReferenceData = true
        }
        _draft = State(initialValue: value)
    }

    private var isCurrent: Bool {
        model.selectedReportID == report.id && model.selectedReportRevision == reportRevision
            && researchModel.financialReport?.id == report.id
            && researchModel.financialReportRevision == reportRevision
            && researchModel.canDisplayFinancialReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("补充估值资料").font(.title3.weight(.semibold))
                Text(report.ticker).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("按参考股价计算 TTM 估值倍数；AI 分析后可确认目标市销率假设，生成三个情景股价。")
                .font(.caption).foregroundStyle(.secondary)
            priceFields
            Divider()
            shareFields
            Toggle("我已核对：这是该公司完整的单一普通股股数，与参考价采用相同股类和拆股口径。",
                   isOn: $draft.confirmedSingleClassSameBasis)
                .font(.caption)
            Text("多股类、ADR 或拆股口径不一致时，请使用本地估值资料，不勾选此项。")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("这些参考输入可随本次财报摘要发送给 OpenAI。", isOn: $draft.maySendReferenceData)
                .font(.caption)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                if model.valuationReference != nil {
                    Button("清除参考输入") {
                        if model.updateValuationReference(nil, reportID: report.id, reportRevision: reportRevision) {
                            dismiss()
                        } else { message = "报告已切换，请关闭后重新打开。" }
                    }.buttonStyle(.link)
                }
                Spacer()
                Button("应用资料") { apply() }
                    .buttonStyle(StockActionButtonStyle(kind: .filled))
                    .disabled(!isCurrent || isLoadingShares || !draft.confirmedSingleClassSameBasis || !draft.maySendReferenceData)
                    .accessibilityIdentifier("aiApplyValuationInputs")
            }
            Text("应用只更新当前报告的参考输入；返回后点击“发送摘要并分析”才会发送。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(width: 570)
            .onChange(of: draft.price) { _, _ in draft.maySendReferenceData = false }
            .onChange(of: draft.referenceAt) { _, _ in
                draft.confirmedSingleClassSameBasis = false; draft.maySendReferenceData = false
            }
            .onChange(of: draft.shares) { _, _ in
                draft.confirmedSingleClassSameBasis = false; draft.maySendReferenceData = false
                clearChangedCandidate()
            }
            .onChange(of: draft.sharesAsOf) { _, _ in
                draft.confirmedSingleClassSameBasis = false; draft.maySendReferenceData = false
                clearChangedCandidate()
            }
            .onChange(of: researchModel.financialReportRevision) { _, _ in dismiss() }
            .onDisappear { sourceTask?.cancel() }
    }

    private var priceFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("参考股价").frame(width: 88, alignment: .leading)
                TextField("例如 123.45", text: $draft.price).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("aiReferencePrice")
                Text("USD／股").font(.caption).foregroundStyle(.secondary)
            }
            DatePicker("参考时刻", selection: $draft.referenceAt, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field).font(.callout)
            Text("填写你可用于此次 AI 分析的参考价；时刻使用本机时区，不会自动获取或转发采集行情。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var shareFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("实际普通股股数").font(.callout.weight(.medium))
                Spacer()
                if isLoadingShares { ProgressView().controlSize(.small) }
                Button("从本地财报带入") { loadShares() }
                    .buttonStyle(.link).font(.caption)
                    .disabled(!isCurrent || isLoadingShares || !researchModel.canGenerateValuationSupplement)
                    .accessibilityIdentifier("aiLoadShareCandidate")
            }
            HStack(spacing: 12) {
                TextField("完整整数，不使用加权平均稀释股数", text: $draft.shares)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("aiReferenceShares")
                TextField("股数日期 YYYY-MM-DD", text: $draft.sharesAsOf)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
                    .accessibilityIdentifier("aiReferenceSharesDate")
            }.disabled(isLoadingShares)
            if let candidate {
                Text("SEC 候选：\(candidate.taxonomy):\(candidate.concept) · \(candidate.asOfDate.iso8601) · \(candidate.accessionNumber)")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Text("已带入原申报股数，仍须确认完整股类与拆股口径；它不是实时股本。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !researchModel.financialReportIsSaved {
                Text("先保存当前分析，才能读取其绑定原财报中的股数候选；也可按自己的可靠资料填写。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadShares() {
        guard isCurrent, !isLoadingShares else { return }
        isLoadingShares = true; message = nil
        candidate = nil
        draft.confirmedSingleClassSameBasis = false; draft.maySendReferenceData = false
        sourceTask = Task { @MainActor in
            defer { isLoadingShares = false; sourceTask = nil }
            guard isCurrent, !Task.isCancelled else { return }
            await researchModel.loadValuationSources()
            guard isCurrent, !Task.isCancelled else { return }
            guard let source = researchModel.valuationSourceDocument,
                  source.id == report.parentDocumentID, source.ticker == report.ticker,
                  source.cutoff == report.cutoff, source.parentResearchHash == report.parentDocumentHash else {
                message = "原财报来源未能完成核对，股数未带入。"; return
            }
            let projection = source.shareCountCandidates
            if let value = projection.candidate {
                candidate = value
                draft.shares = value.outstandingShares.decimalString
                draft.sharesAsOf = value.asOfDate.iso8601
                draft.confirmedSingleClassSameBasis = false; draft.maySendReferenceData = false
                message = "已带入股数候选，请核对其日期与适用股类。"
            } else {
                candidate = nil
                switch projection.status {
                case .missing: message = "这份财报没有可用的实际股数；不会用加权平均稀释股数替代。"
                case .conflicting: message = "财报股数存在相互冲突的口径或版本，未自动选取；请核对原申报。"
                case .unsupported: message = "现有股数含未支持的股类或口径，不能自动带入。"
                case .available: message = "未找到唯一可带入的股数候选。"
                }
            }
        }
    }

    private func clearChangedCandidate() {
        guard let current = candidate else { return }
        if draft.shares != current.outstandingShares.decimalString || draft.sharesAsOf != current.asOfDate.iso8601 {
            candidate = nil
        }
    }

    private func apply() {
        guard isCurrent else { message = "报告已切换，请关闭后重新打开。"; return }
        do {
            let value = try draft.validated()
            guard value.referenceAt >= report.cutoff else {
                message = "参考时刻不能早于这份财报的来源截止时刻，避免用后来的财报解释过去股价。"; return
            }
            guard model.updateValuationReference(value, reportID: report.id, reportRevision: reportRevision) else {
                message = "报告已切换，请关闭后重新打开。"; return
            }
            dismiss()
        } catch let error as AIValuationReferenceError {
            switch error {
            case .invalidPrice: message = "参考股价须是大于零的十进制数。"
            case .invalidShares: message = "实际股数须是大于零的完整整数。"
            case .invalidReferenceDate: message = "参考时刻无效或晚于现在，请重新选择。"
            case .invalidSharesDate: message = "股数日期须有效，且不能晚于参考价格日期。"
            case .unconfirmedShareBasis: message = "请先核对单一完整股类及相同拆股口径。"
            case .sendingNotAllowed: message = "请先确认这些输入可用于本次 AI 分析。"
            }
        } catch { message = "参考资料未通过校验，请检查股价、股数及日期。" }
    }
}
