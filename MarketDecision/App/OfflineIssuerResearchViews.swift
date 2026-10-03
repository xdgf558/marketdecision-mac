import SwiftUI
import AppComposition
import CoreDomain
import FundamentalsEngine

private struct OfflinePreparationKey: Hashable {
    let attempt: UUID
    let ready: Bool
}

/// Page-local interaction state; the shared environment supplies only the separate store.
struct OfflineIssuerResearchPage: View {
    let workspace: WorkspaceModel
    @State private var model: OfflineIssuerWorkspaceModel?
    @State private var preparationMessage: String?
    @State private var attempt = UUID()
    var body: some View {
        Group {
            if !workspace.isPrepared {
                VStack(spacing: 16) {
                    if let message = workspace.initializationError {
                        Text(message)
                        Button("重试初始化") { Task { await workspace.refresh() } }.disabled(workspace.isLoading)
                    } else { ProgressView("正在准备本地环境…") }
                }.padding(24)
            }
            else if let model { OfflineIssuerResearchContent(model: model) }
            else {
                VStack(spacing: 16) {
                    if let preparationMessage {
                        ContentUnavailableView("离线研究暂不可用", systemImage: "doc.text.magnifyingglass",
                            description: Text(preparationMessage))
                        Button("重试打开离线库") { attempt = UUID() }.accessibilityIdentifier("offlinePrepareRetry")
                    } else { ProgressView("正在打开独立离线研究库…") }
                }.padding(24)
            }
        }
        .task(id: OfflinePreparationKey(attempt: attempt, ready: workspace.isPrepared)) {
            guard workspace.isPrepared else { return }
            do {
                preparationMessage = nil
                if model == nil {
                    let ready = try await workspace.makeOfflineIssuerWorkspace()
                    try Task.checkCancellation()
                    model = ready
                }
                await model?.load()
            } catch {
                guard !Task.isCancelled else { return }
                preparationMessage = "离线库或随包摘录无法通过校验。已有数据不会被清空；可以重试，演示工作台仍可使用。"
            }
        }
        .onDisappear { model?.disappear() }
    }
}

struct OfflineIssuerResearchContent: View {
    @Bindable var model: OfflineIssuerWorkspaceModel
    @State private var section = "基础财务"
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("离线摘录研究").font(.system(size: 32, weight: .bold))
                Text("固定财报摘录 · 本地计算 · 独立保存").foregroundStyle(.secondary)
            }
            Label("人工摘录仅供研究。没有实时行情、完整股类资本或历史时点资格，不能据此生成投资价位。", systemImage: "info.circle.fill")
                .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("offlineResearchLimitations")
            HStack {
                Picker("公司摘录", selection: Binding(get: { model.selectionTicker }, set: { _ = model.choose($0) })) {
                    ForEach(model.issuers) { item in Text(item.ticker).tag(item.ticker) }
                }.frame(maxWidth: 280).disabled(model.isBusy).accessibilityIdentifier("offlineIssuerPicker")
                Button("生成离线研究") {
                    let ticker = model.selectionTicker
                    Task { await model.select(ticker) }
                }
                    .disabled(model.isBusy).accessibilityIdentifier("offlineGenerate")
                Spacer(minLength: 0)
            }
            Picker("离线研究内容", selection: $section) {
                ForEach(["基础财务", "增长", "补充", "来源与缺项", "已保存"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("offlineResearchTabs")
            if model.isBusy { ProgressView("正在处理离线研究…").controlSize(.small) }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("offlineResearchMessage")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if section == "已保存" { savedResearch }
                    else if let document = model.document {
                        documentHeader(document)
                        if section == "来源与缺项" { sources(document) }
                        else if model.canDisplayReports { reports(document) }
                        else {
                            ContentUnavailableView("报告数值尚未通过核对", systemImage: "checkmark.shield",
                                description: Text("点击上方“按冻结输入重算并核对”。一致后才展示三组报告数值；未核对、不一致或失败时均隐藏缓存指标。来源与缺项仍可查看。"))
                                .accessibilityIdentifier("offlineReportsUnverified")
                        }
                    } else {
                        ContentUnavailableView("选择一家公司开始", systemImage: "doc.text.magnifyingglass",
                            description: Text("从已审摘录生成离线研究，或在“已保存”中打开冻结版本。"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 20)
            }
        }.padding(24)
    }
    private func documentHeader(_ document: OfflineIssuerResearchDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.ticker + " · 财报摘录").font(.title2.bold()).accessibilityIdentifier("offlineResearchCompany")
                    Text("财务期末 " + document.baseReport.periodEnd.iso8601).font(.callout).foregroundStyle(.secondary)
                    Text(model.isSaved ? "已保存冻结版本" : "尚未保存").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isSaved ? "已保存" : "保存研究") { Task { await model.save() } }
                    .disabled(model.isBusy || !model.canSave).accessibilityIdentifier("offlineResearchSave")
            }
            Text(replayText).font(.callout).foregroundStyle(replayIsProblem ? Color.orange : Color.secondary)
                .accessibilityIdentifier("offlineReplayStatus")
            Button("按冻结输入重算并核对") { Task { await model.recompute() } }
                .disabled(model.isBusy).accessibilityIdentifier("offlineResearchReplay")
            Text("核对只比较现有模型与缓存结果，不代表模型已校准或数据已获准用于真实投资分析。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var replayText: String {
        switch model.recomputationState {
        case .notVerified: return "输入与结构已校验 · 尚未显式重算核对"
        case .matched: return "本次显式重算与冻结缓存一致"
        case .mismatched: return "本次重算与缓存不一致 · 原缓存未覆盖，请核查来源与模型"
        case .failed: return "重算未完成 · 不能把缓存结果视为已核对"
        }
    }
    private var replayIsProblem: Bool {
        model.recomputationState == .mismatched || model.recomputationState == .failed
    }
    private func reports(_ document: OfflineIssuerResearchDocument) -> some View {
        let metrics = section == "增长" ? document.growthReport.metrics
            : section == "补充" ? document.completionReport.metrics : document.baseReport.metrics
        let keys = section == "增长" ? ["revenueQuarter", "revenueQuarterQoQ", "revenueQuarterYoY", "operatingIncomeQuarter", "operatingIncomeTTMYoY", "epsQuarter", "epsQuarterYoY", "fcfQuarter", "fcfQuarterYoY"]
            : section == "补充" ? ["cash", "fcfExSBCTTM", "fcfExSBCConversion", "dividendsTTM", "buybacksTTM", "issuanceTTM", "netBuybacksTTM", "revenueCAGR3Y", "revenueCAGR5Y"]
            : ["revenue", "operatingIncome", "fcf", "debt", "roic", "marketCap", "enterpriseValue", "peMarketCap", "fcfYield"]
        return VStack(alignment: .leading, spacing: 14) {
            GroupBox(section + " · 冻结结果") {
                VStack(spacing: 10) {
                    ForEach(keys, id: \.self) { key in metricRow(key, metrics[key]) }
                }.padding(8)
            }
            Text("比值按小数展示（0.12 表示 12%）；缺值显示具体原因，不补零。金额保留十进制精度。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("全部指标（字段标识）与口径标记") {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(metrics.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            metricRow(key, metrics[key])
                            if let flags = metrics[key]?.flags, !flags.isEmpty {
                                Text(flags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }
    private func metricRow(_ key: String, _ metric: FundamentalMetric?) -> some View {
        HStack(alignment: .top) {
            Text(metricTitle(key)).frame(maxWidth: .infinity, alignment: .leading)
            Text(metricValue(metric)).monospacedDigit().textSelection(.enabled)
                .multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.callout)
    }
    private func sources(_ document: OfflineIssuerResearchDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("研究范围与缺失证据") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原始 PDF／HTML 全文未包含。原文引用哈希与本次摘录哈希分别保留，不代表原文真实性或供应商许可已核验。")
                    if let context = model.context {
                        ForEach(Array(context.knownMissing.enumerated()), id: \.offset) { _, value in Text("• " + value) }
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup("冻结期间、模型和摘录指纹") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CIK：" + document.cik)
                    Text("摘录 SHA-256：" + document.excerptHash)
                    Text("参数版本：" + document.parameters.version)
                    ForEach(document.models, id: \.reference.contentHash) { model in
                        Text("模型：" + model.version + " · " + model.reference.contentHash)
                    }
                    if let context = model.context {
                        Text("季度：" + context.quarters.map { $0.start + "…" + $0.end }.joined(separator: "、"))
                        Text("税率年度：" + context.fiscalYears.map(\.end).joined(separator: "、"))
                        Text("金融企业：" + (context.financialCompany ? "是" : "否"))
                        Text("拆股口径：" + (context.splitBasisEvidence ?? "缺失"))
                    }
                }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            TextField("筛选原始字段，如 revenue、cash、eps", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("offlineFactFilter")
            if let context = model.context {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(context.facts.filter { query.isEmpty || $0.fieldID.localizedCaseInsensitiveContains(query) }, id: \.sourceCellID) { fact in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("原文值：\(fact.reportedValue) · 比例：\(fact.reportedScale) · 单位：\(fact.unit)")
                                Text("标准值：\(fact.decimalValue) · 符号规则：\(fact.signConvention)")
                                Text("期间：\(fact.start ?? "时点") → \(fact.end) · \(fact.periodType)")
                                Text("检索时间（不等于历史可得时点）：" + fact.observedAt)
                                Text("原文定位：" + fact.sourceLocator)
                                Text("原文引用：" + fact.sourceURL)
                                Text("原文 SHA-256：" + fact.originalSourceHash)
                            }.font(.caption).textSelection(.enabled).padding(.vertical, 6)
                        } label: {
                            HStack { Text(fact.fieldID); Spacer(); Text(fact.end) }.font(.callout)
                        }
                    }
                }
            }
        }
    }
    private var savedResearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("独立离线研究库").font(.title2.bold()); Spacer()
                Button("重新载入") { Task { await model.load() } }.disabled(model.isBusy).accessibilityIdentifier("offlineSavedReload")
            }
            Text("打开只验证冻结输入与结构，并同步公司选择。报告数值须显式重算一致后才显示。").font(.callout).foregroundStyle(.secondary)
            if let message = model.savedReadError { Text(message).foregroundStyle(.red) }
            else if model.saved.isEmpty { Text("尚无已保存研究。生成后可在本机保存。").foregroundStyle(.secondary) }
            ForEach(model.saved) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.document.ticker + " · 离线摘录").font(.headline)
                        Text("财务期末 " + item.document.baseReport.periodEnd.iso8601).font(.caption)
                        Text(item.document.baseReport.executionAt.iso8601).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开冻结版本") {
                        Task { await model.open(item.id); if model.savedID == item.id { section = "基础财务" } }
                    }.disabled(model.isBusy).accessibilityIdentifier(OfflineIssuerWorkspaceModel.savedRowIdentifier(item))
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func metricValue(_ value: FundamentalMetric?) -> String {
        if let number = value?.value { return number.decimalString }
        switch value?.unavailable {
        case .missingClass: return "股类数据不完整"
        case .missingPrice: return "缺少合格价格"
        case .insufficientHistory: return "历史不足"
        case .nonpositiveDenominator: return "分母非正"
        case .notApplicable: return "不适用"
        case .notComparable: return "口径不可比"
        case .missingEvidence: return "缺少证据"
        default: return "缺少输入"
        }
    }
    private func metricTitle(_ key: String) -> String {
        ["revenue": "TTM 收入（USD）", "operatingIncome": "TTM 营业利润（USD）", "fcf": "TTM 自由现金流（USD）",
         "debt": "含租赁债务（USD）", "roic": "ROIC（比值）", "marketCap": "完整股类市值（USD）", "enterpriseValue": "企业价值（USD）",
         "peMarketCap": "市值／普通股净利（倍）", "fcfYield": "FCF 收益率（比值）", "revenueQuarter": "季度收入（USD）",
         "revenueQuarterQoQ": "收入环比（比值）", "revenueQuarterYoY": "收入同比（比值）", "operatingIncomeQuarter": "季度营业利润（USD）",
         "operatingIncomeTTMYoY": "TTM 营业利润同比（比值）", "epsQuarter": "季度 EPS（USD/股）", "epsQuarterYoY": "EPS 同比（比值）",
         "fcfQuarter": "季度 FCF（USD）", "fcfQuarterYoY": "FCF 同比（比值）", "cash": "现金（USD）", "fcfExSBCTTM": "TTM 扣除 SBC 后 FCF（USD）",
         "fcfExSBCConversion": "扣除 SBC 后现金流转化率（比值）", "dividendsTTM": "TTM 股息支出（USD）",
         "buybacksTTM": "TTM 回购支出（USD）", "issuanceTTM": "TTM 发股收入（USD）", "netBuybacksTTM": "TTM 净回购（USD）",
         "revenueCAGR3Y": "三年收入复合增长率（比值）", "revenueCAGR5Y": "五年收入复合增长率（比值）"][key] ?? (key + "（" + metricUnit(key) + "）")
    }
    private func metricUnit(_ key: String) -> String {
        let perShare = key.hasPrefix("eps") || key.contains("PerShare") || key == "dilutedEPSQuarterSum"
        if key.hasSuffix("Change") { return perShare ? "USD/股" : "USD" }
        if key.contains("YoY") || key.contains("QoQ") || key.contains("CAGR") { return "比值" }
        if perShare { return "USD/股" }
        if key.hasSuffix("Quarter") || key.hasSuffix("TTM") { return "USD" }
        if ["revenue", "operatingIncome", "commonIncome", "netIncome", "fcf", "fcfExSBC", "ebitda",
            "debt", "netDebt", "nopat", "marketCap", "enterpriseValue", "netBuybacks", "cash"].contains(key) { return "USD" }
        if ["peMarketCap", "peEPS", "priceBook", "priceSales", "priceFCF", "priceFCFExSBC", "evEBITDA",
            "evSales", "netDebtEBITDA", "interestCoverage", "currentRatio", "debtEquity"].contains(key) { return "倍" }
        if key == "liquidityTrend" { return "比值/季度" }
        if ["grossMargin", "operatingMargin", "netMargin", "fcfMargin", "fcfExSBCMargin", "sbcRevenue", "fcfConversion",
            "roa", "roe", "normalizedTax", "leaseRate", "roic", "fcfYield", "fcfExSBCYield", "earningsYield",
            "shareholderYield", "fcfExSBCConversion"].contains(key) { return "比值" }
        return "单位需核对"
    }
}
