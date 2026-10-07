import SwiftUI
import SECNetworkBroker
import AppComposition
import CoreDomain
import DataContracts
import FundamentalsEngine
import Persistence

private struct SECPagePreparation: Hashable { let ready: Bool; let attempt: UUID }

struct SECResearchPage: View {
    let workspace: WorkspaceModel
    @State private var model: SECResearchWorkspaceModel?
    @State private var errorMessage: String?
    @State private var attempt = UUID()
    var body: some View {
        Group {
            if let model { SECResearchContent(model: model) }
            else if let errorMessage {
                VStack(spacing: 14) {
                    ContentUnavailableView("SEC 研究暂不可用", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
                    Button("重新打开") { attempt = UUID() }
                }.padding(24)
            } else { ProgressView("正在打开本地 SEC 研究…") }
        }
        .task(id: SECPagePreparation(ready: workspace.isPrepared, attempt: attempt)) {
            guard workspace.isPrepared else { return }
            do {
                errorMessage = nil
                if model == nil {
                    let ready = try await workspace.makeSECResearchWorkspace(networkAvailable: SECNetworkServiceAvailability.isAvailable)
                    try Task.checkCancellation(); model = ready
                }
                await model?.load()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "本地研究库无法通过检查。已有记录保留，可以重试；其他工作区不受影响。"
            }
        }
        .onDisappear { model?.disappear() }
    }
}

struct SECResearchContent: View {
    @Bindable var model: SECResearchWorkspaceModel
    // User-provided contact stays in local preferences. It is excluded from research documents,
    // source provenance, exported material, error messages and diagnostics.
    @AppStorage("secContactEmail") private var contactEmail = ""
    @State private var section = "财务数据"
    @State private var filter = ""
    @State private var reportSection = "基础财务"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SEC 财报研究").font(.system(size: 32, weight: .bold))
                Text("公开申报 · 本地保存 · 可追溯重算").foregroundStyle(.secondary)
            }
            Label("仅供财报研究；未接入合格股价、股类资本或模型校准，不提供投资价位。", systemImage: "info.circle")
                .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            GroupBox("从 SEC 导入") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("股票代码", text: Binding(get: { model.ticker }, set: { model.chooseTicker($0) }))
                            .textFieldStyle(.roundedBorder).frame(width: 120).disabled(model.isBusy)
                            .accessibilityIdentifier("secTicker")
                        TextField("SEC 联系邮箱", text: $contactEmail).textFieldStyle(.roundedBorder).disabled(model.isBusy)
                            .accessibilityIdentifier("secContactEmail")
                        Button("导入财报") { model.startImport(email: contactEmail) }
                            .disabled(model.isBusy || !model.networkAvailable).accessibilityIdentifier("secImport")
                        if model.isBusy { Button("取消") { model.cancel() }.accessibilityIdentifier("secCancel") }
                    }
                    Text("点击后发送股票代码和联系邮箱给 SEC。邮箱仅保存在本机；不会随研究记录保存或公开。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.networkAvailable {
                        Text("本构建的 SEC 导入服务不可用，可查看和重算已保存研究。")
                            .font(.callout).foregroundStyle(.orange).accessibilityIdentifier("secNetworkDisabled")
                    }
                }.padding(8)
            }
            if model.isBusy {
                HStack { ProgressView().controlSize(.small); Text(progressText).font(.callout) }
                    .accessibilityIdentifier("secProgress")
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("secMessage")
            }
            Picker("研究内容", selection: $section) {
                ForEach(["财务数据", "财务报告", "来源与修订", "已保存"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("secSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if section == "财务报告" { financialReports }
                    else if section == "已保存" { saved }
                    else if let document = model.document {
                        header(document)
                        if section == "来源与修订" { sources(document) }
                        else if model.canDisplayValues { values(document) }
                        else {
                            ContentUnavailableView("标准化数值尚未核对", systemImage: "checkmark.shield",
                                description: Text("按冻结源事实重算并核对后才显示数值。未核对、不一致或失败时保持隐藏；原始来源仍可查看。"))
                                .accessibilityIdentifier("secUnverified")
                        }
                    } else {
                        ContentUnavailableView("导入一家公司开始", systemImage: "building.2",
                            description: Text("也可以在“已保存”中打开本地研究。应用启动和进入本页不会自动联网。"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 20)
            }
        }.padding(24)
    }
    private var progressText: String {
        guard let progress = model.progress else { return "正在准备…" }
        return "\(stageTitle(progress.stage)) · 已接收 \(progress.acceptedPages) 页 / \(progress.acceptedRecords) 条"
    }
    private func stageTitle(_ stage: SECResearchStage) -> String {
        switch stage {
        case .identity: "核对公司身份"
        case .submissions: "下载申报目录"
        case .companyFacts: "下载财务事实"
        case .filingIndex: "核对原始文件索引"
        case .filingDocument: "下载最近报告原文"
        case .normalizing: "按截止时点归一化"
        case .saving: "保存研究版本"
        }
    }
    private func header(_ document: SECResearchDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.ticker + " · " + document.identity.name).font(.title2.bold()).textSelection(.enabled)
            Text("CIK " + document.identity.cik + " · 截止 " + document.cutoff.formatted(date: .numeric, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
            Button("按冻结源事实重算并核对") { Task { await model.recompute() } }
                .disabled(model.isBusy).accessibilityIdentifier("secReplay")
            Text(model.canDisplayValues ? "本次重算一致；仅证明固定输入下结果一致。" : "数值尚未通过本次显式核对。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(document.gaps.enumerated()), id: \.offset) { _, gap in
                Text(gapTitle(gap)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func gapTitle(_ gap: SECResearchGap) -> String {
        switch gap {
        case .missingAnnualFiling: "未取得年度申报，不能视为完整财务研究。"
        case .missingQuarterlyFiling: "未取得季度申报，季度与 TTM 可能缺失。"
        case .missingFacts: "没有可用的标准化财务事实。"
        case .unmappedFacts: "部分原始标签尚无已审映射，已保留在来源中。"
        case .noQualifiedPricesOrCapital: "缺少合格价格及股类资本，估值不可用。"
        case .financialClassificationNotSupplied: "行业适用性尚未核定。源记录不自动等于完整报告；财务报告另按期间及字段证据检查。"
        case .researchOnly: "结果仅供财报研究，不构成投资分析准入。"
        }
    }
    private func values(_ document: SECResearchDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标准化财务与可形成的季度／TTM").font(.headline)
            Text("不推测财年、行业或拆股口径；未映射及冲突事实保留为缺项。单位逐条列出，缺失不补零。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("筛选字段", text: $filter).textFieldStyle(.roundedBorder)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(document.normalization.values.filter { filter.isEmpty || $0.fieldID.localizedCaseInsensitiveContains(filter) }, id: \.id) { fact in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fact.fieldID)
                            Text((fact.periodStart?.iso8601 ?? "时点") + " → " + fact.periodEnd.iso8601 + " · " + fact.periodType.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(fact.value.decimalString + " " + fact.unit).monospacedDigit().textSelection(.enabled)
                    }.font(.callout)
                    Divider()
                }
            }
        }
    }
    private func sources(_ document: SECResearchDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("字典：" + document.normalization.dictionaryVersion).font(.caption).textSelection(.enabled)
            Text("SEC 的接收时间不等于保证的公开可得时间；本页不授予历史 PIT 资格。")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("归一化缺项与冲突（\(document.normalization.issues.count)）") {
                ForEach(Array(document.normalization.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.code + " · " + issue.message).font(.caption).textSelection(.enabled)
                }
            }
            DisclosureGroup("申报记录（\(document.submissions.count)）") {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(document.submissions, id: \.recordID) { filing in
                        Text(filing.form + " · " + filing.filingDate.iso8601 + " · " + filing.accessionNumber)
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
            TextField("筛选原始标签", text: $filter).textFieldStyle(.roundedBorder)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(document.facts.filter { filter.isEmpty || $0.concept.localizedCaseInsensitiveContains(filter) }, id: \.recordID) { fact in
                    DisclosureGroup(fact.concept + " · " + fact.endDate.iso8601) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原始值：" + fact.sourceValue + " " + fact.unit)
                            Text("申报：" + fact.accessionNumber + " · " + fact.filedDate.iso8601)
                            Text("版本：" + (fact.provenance.versionID ?? "缺失"))
                            Text("源 SHA-256：" + (fact.provenance.rawHash ?? "缺失"))
                            Text("源对象：" + (fact.provenance.rawObjectRef ?? "缺失"))
                        }.font(.caption).textSelection(.enabled).padding(.vertical, 6)
                    }.font(.callout)
                }
            }
        }
    }
    private var financialReports: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("从冻结研究生成财务报告") {
                VStack(alignment: .leading, spacing: 10) {
                    if let document = model.document {
                        Text(document.ticker + " · " + document.identity.name).font(.headline)
                        Text("选定源研究：" + document.id.uuidString).font(.caption).textSelection(.enabled)
                    } else {
                        Text("先在“已保存”中打开一份源研究，或打开下方报告绑定的源研究。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button("生成财务报告") { Task { await model.generateFinancialReport() } }
                        .disabled(!model.canGenerateFinancialReport).accessibilityIdentifier("secGenerateFinancialReport")
                    Text("全部计算使用本地冻结事实。期间不足或有歧义时说明原因；行业分类未核定，不生成 ROIC 与净债务／EBITDA。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("报告不包含行情估值或评分。缺失不补零，也不会为了计算下载新的数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let message = model.financialMessage {
                Text(message).font(.callout).foregroundStyle(model.financialHasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("secFinancialMessage")
            }
            if let report = model.financialReport {
                financialReportHeader(report)
                financialEvidence(report)
                if model.canDisplayFinancialReport { financialMetrics(report) }
                else {
                    ContentUnavailableView("财务报告数值尚未核对", systemImage: "checkmark.shield",
                        description: Text("显式重算一致后才显示三个模型的数值；未核对、不一致或失败时保持隐藏。"))
                        .accessibilityIdentifier("secFinancialReportUnverified")
                }
            }
            GroupBox("已保存的财务报告") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("列表仅读取摘要；每份报告绑定一份不可变的源研究。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重新载入报告列表") { Task { await model.loadFinancialReports() } }
                        .disabled(model.isBusy).accessibilityIdentifier("secReloadFinancialReports")
                    if let error = model.financialListError {
                        Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("secFinancialListError")
                    }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.savedFinancialReports, id: \.id) { report in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.ticker + " · " + report.companyName)
                                    Text("生成 " + report.createdAt.formatted(date: .numeric, time: .standard))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("源研究：" + report.parentDocumentID.uuidString)
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button("打开报告") { Task { await model.openFinancialReport(report.id) } }
                                    .disabled(model.isBusy).accessibilityIdentifier("openSECFinancialReport-" + report.id.uuidString)
                            }
                        }
                    }
                    if model.savedFinancialReports.isEmpty && model.financialListError == nil {
                        Text("尚无已保存的财务报告。").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }
    private func financialReportHeader(_ report: SECFinancialReportDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.ticker + " · 财务报告").font(.title2.bold())
            Text("源截止 " + report.cutoff.formatted(date: .numeric, time: .standard)
                 + " · 财务期末 " + report.financials.baseReport.periodEnd.iso8601)
                .font(.caption).foregroundStyle(.secondary)
            Text("绑定源研究：" + report.parentDocumentID.uuidString).font(.caption).textSelection(.enabled)
            HStack {
                Button("保存报告") { Task { await model.saveFinancialReport() } }
                    .disabled(!model.canSaveFinancialReport).accessibilityIdentifier("secSaveFinancialReport")
                Button("重算并核对报告") { Task { await model.recomputeFinancialReport() } }
                    .disabled(model.isBusy).accessibilityIdentifier("secReplayFinancialReport")
                if model.document?.id != report.parentDocumentID {
                    Button("打开绑定源研究") {
                        section = "财务数据"
                        Task { await model.open(report.parentDocumentID) }
                    }.disabled(model.isBusy).accessibilityIdentifier("secOpenFinancialParent")
                }
                if model.financialReportIsSaved { Label("已保存", systemImage: "checkmark.circle").font(.caption) }
            }
            Text(financialVerificationText).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var financialVerificationText: String {
        switch model.financialReportState {
        case .generated: model.financialReportIsSaved ? "本次从冻结输入生成；结果已保存。" : "本次从冻结输入生成；结果尚未保存。"
        case .matched: "本次显式重算与三个模型的缓存结果一致。"
        case .notVerified: "缓存数值尚未经过本次显式核对。"
        case .mismatched: "重算与缓存不一致；原缓存未覆盖。"
        case .failed: "重算未完成；缓存数值保持隐藏。"
        }
    }
    private func financialEvidence(_ report: SECFinancialReportDocument) -> some View {
        let financials = report.financials
        let evidence = financials.evidence
        let normalization = financials.inputSnapshot.financials.input.normalization
        return DisclosureGroup("期间与来源") {
            VStack(alignment: .leading, spacing: 12) {
                Text("父研究 SHA-256：" + report.parentDocumentHash)
                Text("证据规则：" + financials.evidencePolicy + " · 字典：" + normalization.dictionaryVersion)
                VStack(alignment: .leading, spacing: 4) {
                    Text("选定季度（\(evidence.quarters.count) 个）").font(.headline)
                    ForEach(Array(evidence.quarters.enumerated()), id: \.offset) { _, quarter in
                        Text(quarter.start.iso8601 + " → " + quarter.end.iso8601)
                    }
                    if let start = evidence.quarters.suffix(4).first?.start, let end = evidence.quarters.last?.end {
                        Text("本期 TTM：" + start.iso8601 + " → " + end.iso8601)
                    }
                    Text("单季指标取末季；同比、环比及 TTM 依各自所需窗口检查，不足则保留缺项。")
                        .foregroundStyle(.secondary)
                }
                financialYears("税率年度窗口", years: evidence.fiscalYears,
                    note: "标准化税率需要三个完整年度及相应税前利润、税额；年度窗口不代表字段齐全。")
                financialYears("收入 CAGR 年度窗口", years: evidence.revenueYears,
                    note: "三年／五年 CAGR 分别需要四个／六个连续完整年度的收入，不使用季度年化值。")
                if let classification = evidence.classification {
                    Text("观测到的 SEC SIC：\(classification.sic)；仅保留源元数据，未授予行业适用性。")
                    Text("SIC 来源：" + classification.sourceReference + " · " + classification.sourceVersion)
                    Text("SIC 源 SHA-256：" + classification.sourceHash)
                } else {
                    Text("未提供 SEC SIC 元数据；行业适用性保持未知。")
                }
                Text("本批 ROIC 与净债务／EBITDA 保留缺少核定证据；不据 SIC 数值推定企业行业。")
                    .foregroundStyle(.secondary)
                DisclosureGroup("模型与参数引用") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(financials.models, id: \.id) { definition in
                            financialReference("模型", reference: definition.reference)
                        }
                        financialReference("参数", reference: financials.parameters.reference)
                    }.padding(.vertical, 6)
                }
                DisclosureGroup("模型输入字段与源事实（\(normalization.values.count) 条）") {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(normalization.values, id: \.id) { fact in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fact.fieldID + " · " + fact.unit)
                                Text((fact.periodStart?.iso8601 ?? "时点") + " → " + fact.periodEnd.iso8601
                                     + " · " + fact.periodType.rawValue + " · " + fact.derivation.rawValue)
                                Text("来源版本：" + fact.sourceVersions.joined(separator: " · "))
                                Text("源事实 ID：" + fact.sourceFactIDs.joined(separator: " · "))
                                Text("申报编号：" + fact.accessionNumbers.joined(separator: " · "))
                            }
                            Divider()
                        }
                    }.padding(.vertical, 6)
                }
            }.font(.caption).textSelection(.enabled).padding(.vertical, 8)
        }.accessibilityIdentifier("secFinancialEvidence")
    }
    private func financialYears(_ title: String, years: [FiscalYearWindow], note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title + "（\(years.count) 年）").font(.headline)
            ForEach(Array(years.enumerated()), id: \.offset) { _, year in
                Text(year.start.iso8601 + " → " + year.end.iso8601)
            }
            if years.isEmpty { Text("没有满足证据要求的年度窗口。") }
            Text(note).foregroundStyle(.secondary)
        }
    }
    private func financialReference(_ title: String, reference: RegistryReference) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + "：" + reference.id + " · " + reference.version)
            Text("修订：" + reference.revisionID.uuidString)
            Text("指纹：" + reference.contentHash + " · " + reference.fingerprintVersion)
        }
    }
    private func financialMetrics(_ report: SECFinancialReportDocument) -> some View {
        let financials = report.financials
        let metrics = reportSection == "增长" ? financials.growthReport.metrics
            : reportSection == "现金流与分配" ? financials.completionReport.metrics : financials.baseReport.metrics
        let reference = reportSection == "增长" ? financials.growthReport.model
            : reportSection == "现金流与分配" ? financials.completionReport.model : financials.baseReport.model
        let excluded: Set<String> = ["marketCap", "enterpriseValue", "peEPS", "peMarketCap", "priceBook", "priceSales",
            "priceFCF", "priceFCFExSBC", "evEBITDA", "evSales", "fcfYield", "fcfExSBCYield", "earningsYield", "shareholderYield"]
        return VStack(alignment: .leading, spacing: 12) {
            Picker("财务模型", selection: $reportSection) {
                ForEach(["基础财务", "增长", "现金流与分配"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("secFinancialModelSections")
            Text("模型：" + reference.version).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("金额以 USD 原精度显示；比值 0.12 表示 12%。缺项显示原因，口径标记随指标保留。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(metrics.keys.filter { !excluded.contains($0) }.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            Text(financialMetricTitle(key)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(financialMetricValue(metrics[key])).monospacedDigit().textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }.font(.callout)
                        if let flags = metrics[key]?.flags, !flags.isEmpty {
                            Text(flags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            }.accessibilityIdentifier("secFinancialMetrics")
        }
    }
    private func financialMetricValue(_ metric: FundamentalMetric?) -> String {
        if let value = metric?.value { return value.decimalString }
        switch metric?.unavailable {
        case .missingClass: return "股类数据不完整"
        case .missingPrice: return "缺少合格价格"
        case .insufficientHistory: return "历史期间不足"
        case .nonpositiveDenominator: return "分母非正"
        case .notApplicable: return "不适用"
        case .notComparable: return "口径不可比"
        case .missingEvidence: return "缺少核定证据"
        default: return "缺少输入"
        }
    }
    private func financialMetricTitle(_ key: String) -> String {
        let titles = ["revenue": "TTM 收入", "operatingIncome": "TTM 营业利润", "commonIncome": "普通股净利润",
            "netIncome": "TTM 净利润", "fcf": "TTM 自由现金流", "fcfExSBC": "TTM 扣除 SBC 后 FCF",
            "ebitda": "TTM EBITDA", "debt": "含租赁债务", "netDebt": "净债务", "roic": "ROIC",
            "netDebtEBITDA": "净债务／EBITDA", "cash": "现金", "revenueCAGR3Y": "三年收入复合增长率",
            "revenueCAGR5Y": "五年收入复合增长率", "revenueCAGR3YChange": "三年收入变化额",
            "revenueCAGR5YChange": "五年收入变化额", "grossMargin": "毛利率", "operatingMargin": "营业利润率",
            "netMargin": "净利率", "fcfMargin": "自由现金流率", "fcfExSBCMargin": "扣除 SBC 后自由现金流率",
            "sbcRevenue": "股权激励／收入", "fcfConversion": "自由现金流／净利润", "currentRatio": "流动比率",
            "roa": "资产回报率", "roe": "股东权益回报率", "debtEquity": "债务／权益", "interestCoverage": "利息覆盖倍数",
            "normalizedTax": "标准化税率", "leaseRate": "租赁贴现率", "nopat": "税后营业利润",
            "netBuybacks": "TTM 净回购", "dilutedEPSQuarterSum": "四季稀释每股收益合计",
            "liquidityTrend": "流动比率季度趋势", "sharesYoY": "股数同比",
            "fcfExSBCConversion": "扣除 SBC 后自由现金流／净利润"]
        if let title = titles[key] { return title + "（" + financialMetricUnit(key) + "）" }
        let roots = ["revenue": "收入", "operatingIncome": "营业利润", "netIncome": "净利润", "eps": "稀释每股收益",
            "fcf": "自由现金流", "revenuePerShare": "每股收入", "fcfPerShare": "每股自由现金流",
            "fcfExSBC": "扣除 SBC 后自由现金流", "fcfExSBCPerShare": "每股扣除 SBC 后自由现金流",
            "dividends": "股利", "buybacks": "回购", "issuance": "发行所得", "netBuybacks": "净回购",
            "capex": "资本支出", "sbc": "股权激励费用（非现金）",
            "acquisitions": "收购支出", "shareholderCashReturned": "返还股东现金",
            "dividendsCashFlow": "股利现金流（支出为负）", "buybacksCashFlow": "回购现金流（支出为负）",
            "issuanceCashFlow": "发行现金流（流入为正）", "netBuybacksCashFlow": "净回购现金流（净支出为负）",
            "capexCashFlow": "资本支出现金流（支出为负）", "acquisitionsCashFlow": "收购现金流（支出为负）"]
        let suffixes = [("QuarterYoYChange", "单季同比变化额"), ("QuarterQoQChange", "单季环比变化额"),
            ("TTMYoYChange", "TTM 同比变化额"), ("QuarterYoY", "单季同比"), ("QuarterQoQ", "单季环比"),
            ("TTMYoY", "TTM 同比"), ("YoYChange", "同比变化额"), ("YoY", "同比"),
            ("Quarter", "单季金额"), ("TTM", "TTM 金额")]
        for (suffix, description) in suffixes where key.hasSuffix(suffix) {
            if let root = roots[String(key.dropLast(suffix.count))] {
                return root + " · " + description + "（" + financialMetricUnit(key) + "）"
            }
        }
        return key + "（" + financialMetricUnit(key) + "）"
    }
    private func financialMetricUnit(_ key: String) -> String {
        let perShare = key.hasPrefix("eps") || key.contains("PerShare") || key == "dilutedEPSQuarterSum"
        if key.hasSuffix("Change") { return perShare ? "USD/股" : "USD" }
        if key.contains("YoY") || key.contains("QoQ") || key.contains("CAGR") { return "比值" }
        if perShare { return "USD/股" }
        if key.hasSuffix("Quarter") || key.hasSuffix("TTM") { return "USD" }
        if ["revenue", "operatingIncome", "commonIncome", "netIncome", "fcf", "fcfExSBC", "ebitda",
            "debt", "netDebt", "nopat", "netBuybacks", "cash"].contains(key) { return "USD" }
        if ["netDebtEBITDA", "interestCoverage", "currentRatio", "debtEquity"].contains(key) { return "倍" }
        if key == "liquidityTrend" { return "比值/季度" }
        if ["grossMargin", "operatingMargin", "netMargin", "fcfMargin", "fcfExSBCMargin", "sbcRevenue", "fcfConversion",
            "roa", "roe", "normalizedTax", "leaseRate", "roic", "fcfExSBCConversion"].contains(key) { return "比值" }
        return "单位需核对"
    }
    private var saved: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("列表仅载入版本摘要；打开后检查冻结内容，显式重算核对后才显示标准化数值。")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("secSavedSummaryNotice")
            Button("重新载入列表") { Task { await model.load() } }.disabled(model.isBusy)
            if let error = model.listError { Text(error).foregroundStyle(.red) }
            ForEach(model.saved, id: \.id) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.ticker + " · " + item.companyName)
                        Text(item.cutoff.formatted(date: .numeric, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        Text("\(item.sourceCount) 份来源 · \(item.factCount) 条事实")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开") { Task { await model.open(item.id) } }.disabled(model.isBusy)
                        .accessibilityIdentifier("openSECResearch-" + item.id.uuidString)
                }
            }
            if model.saved.isEmpty && model.listError == nil { Text("尚无已保存的 SEC 研究。").foregroundStyle(.secondary) }
        }
    }
}
