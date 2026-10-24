import SwiftUI
import AppComposition
import AIInsights
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
                    Text("仅发送当前公司的名称、代码、财务期间、截止时间、已核对指标和缺项及本地计算引用。不发送持仓、交易记录、完整财报或 SEC 联系邮箱。")
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
    let report: SECFinancialReportDocument
    let reportRevision: UUID
    @State private var showsSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("openAIFinancialModel") private var modelName = "gpt-6-luna"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text("AI 财报解读").font(.system(size: 18, weight: .semibold))
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            }
            if matchesSelection, let result = model.result, let input = model.input {
                VStack(alignment: .leading, spacing: 14) {
                    Text("数值仍以本地计算为准。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    claim(result.analysis.summary, input: input)
                    claims("优势", result.analysis.strengths, input: input)
                    claims("风险", result.analysis.risks, input: input)
                    claims("需要核实", result.analysis.questions, input: input)
                    DisclosureGroup("依据与局限") {
                        claims("本次限制", result.analysis.limitations, input: input)
                        Text("模型：" + result.model + " · 提示版本：" + result.promptVersion)
                            .font(.caption).foregroundStyle(.secondary)
                        if let usage = result.usage {
                            Text("API 返回用量：输入 \(usage.inputTokens) / 输出 \(usage.outputTokens) tokens（不是费用结算）。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("AI 文字可能出错。引用仅说明关联到所发指标，不代表结论已经事实核查或形成买卖建议。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                emptyState
            }
            analysisActions
            if matchesSelection, let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("aiMessage")
            }
            if !model.networkAvailable {
                Text("本构建尚未启用 AI 网络服务，本地财务报告可照常使用。")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("aiUnavailable")
            }
            Text("点击后发送财报摘要至 OpenAI，使用你的 API 账户计费。持仓与交易记录不发送。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Divider().opacity(0.6)
            DisclosureGroup("发送内容与隐私") {
                Text("发送 35 项白名单财务指标（包含明确缺项）、单位、所选期间、截止时刻和三个本地计算引用。完整财报与本地报告标识不会发送。")
                    .font(.caption).foregroundStyle(.secondary)
                if matchesSelection, let input = model.input {
                    ForEach(input.metrics, id: \.id) { metric in
                        HStack(alignment: .top) {
                            Text(metric.label)
                            Spacer()
                            Text(metric.value.map { $0 + " " + metric.unit } ?? "缺少证据")
                                .monospacedDigit().textSelection(.enabled)
                        }.font(.caption)
                    }
                }
                Text("本次回答仅在当前股票页面保留；切换报告或离开页面会清除。保存分析不包含 AI 回答，研究归档也不包含。取消后已发出的请求仍可能计费。")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.system(size: 12))
        }.padding(24)
            .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
            .background(Color.accentColor.opacity(colorScheme == .dark ? 0.09 : 0.035),
                        in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("aiInsightCard")
            .sheet(isPresented: $showsSettings) { AISettingsView(credentials: model.credentials) }
            .onAppear { model.select(reportID: report.id, revision: reportRevision) }
            .onChange(of: reportRevision) { _, revision in model.select(reportID: report.id, revision: revision) }
            .onChange(of: model.credentials.revision) { _, _ in model.credentialsChanged() }
            .onChange(of: modelName) { _, _ in model.cancel() }
            // SECResearchContent owns selection and SECResearchPage owns disappearance.
            // Hiding this card in another section must not discard the same report's answer.
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary).padding(.bottom, 4)
            Text(model.isBusy ? "正在生成解读" : "尚未生成解读")
                .font(.system(size: 16, weight: .semibold))
            Text("梳理本次财报的优势、风险与待核实事项。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("数值仍以本地计算为准。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 150)
    }
    private var analysisActions: some View {
        VStack(spacing: 12) {
            Button {
                model.select(reportID: report.id, revision: reportRevision)
                model.startAnalysis(report: report, revision: reportRevision, model: modelName)
            } label: {
                Text(model.result == nil ? "发送摘要并分析" : "重新分析（发送摘要）")
                    .frame(minWidth: 180)
            }.buttonStyle(StockActionButtonStyle(kind: .outline))
                .disabled(model.isBusy || !model.networkAvailable)
                .accessibilityIdentifier("aiAnalyze")
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }.accessibilityIdentifier("aiCancel")
                }
            }
            Button { showsSettings = true } label: {
                Text("AI 设置").underline().font(.system(size: 13, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("aiSettings")
        }.frame(maxWidth: .infinity)
    }
    private var matchesSelection: Bool {
        model.selectedReportID == report.id && model.selectedReportRevision == reportRevision
    }
    private func claims(_ title: String, _ values: [AIInsightClaim], input: AIInsightInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !values.isEmpty {
                Text(title).font(.headline)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in claim(value, input: input) }
            }
        }
    }
    private func claim(_ value: AIInsightClaim, input: AIInsightInput) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Plain text: model output cannot create active links, rich text or commands.
            Text(verbatim: value.text).textSelection(.enabled)
            Text("依据：" + value.evidenceIDs.map { id in
                input.metrics.first(where: { $0.id == id })?.label
                    ?? input.sources.first(where: { $0.id == id })?.label ?? id
            }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
