import SwiftUI
import AppComposition
import Persistence

/// The daily stock workflow stays on one page. Separate databases and specialist
/// tools remain explicit destinations; selecting a destination never imports data.
struct StockAnalysisPage: View {
    let workspace: WorkspaceModel
    @State private var tool: StockAnalysisTool = .company

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if tool != .company {
                    Button {
                        tool = .company
                    } label: {
                        Label("返回股票分析", systemImage: "chevron.left")
                    }.buttonStyle(.borderless).accessibilityIdentifier("stockBackToAnalysis")
                }
                Spacer()
                Menu("高级工具") {
                    Button("公司财报") { tool = .company }
                        .accessibilityIdentifier("stockOpenCompany")
                    Button("离线财报摘录") { tool = .offline }
                        .accessibilityIdentifier("stockOpenOffline")
                    Button("合成研究与自选管理") { tool = .demonstration }
                        .accessibilityIdentifier("stockOpenDemo")
                }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("stockAdvancedTools")
            }.frame(maxWidth: 1280)
                .padding(.horizontal, 24).padding(.top, 8)
                .frame(maxWidth: .infinity)
            switch tool {
            case .company:
                SECResearchPage(workspace: workspace)
            case .offline:
                OfflineIssuerResearchPage(workspace: workspace)
            case .demonstration:
                if let research = workspace.research {
                    ResearchContent(model: research)
                } else {
                    VStack(spacing: 16) {
                        if let message = workspace.initializationError {
                            ContentUnavailableView("研究暂不可用", systemImage: "doc.text.magnifyingglass",
                                description: Text(message))
                            Button("重试初始化") { Task { await workspace.refresh() } }
                                .disabled(workspace.isLoading)
                        } else {
                            ProgressView("正在准备本地研究…")
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                }
            }
        }
    }
}

private enum StockAnalysisTool: Hashable {
    case company, offline, demonstration
}

/// Metadata-only navigation. Choosing a company never opens a body or sends a request.
struct StockDailyControls: View {
    @Bindable var model: SECResearchWorkspaceModel
    @Binding var contactEmail: String
    @Binding var showsConnectionSettings: Bool
    let showOverview: () -> Void
    let showSaved: () -> Void

    private var catalog: SECStockDailyCatalog {
        .init(ticker: model.ticker, research: model.saved, reports: model.savedFinancialReports)
    }

    var body: some View {
        let local = catalog
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("股票代码，如 AAPL", text: Binding(get: { model.ticker }, set: { model.chooseTicker($0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200).disabled(model.isBusy)
                    .accessibilityIdentifier("secTicker")
                Menu("最近公司") {
                    ForEach(local.companies) { company in
                        Button(company.ticker + " · " + company.companyName) {
                            model.chooseTicker(company.ticker)
                            showOverview()
                        }
                    }
                }.disabled(model.isBusy || local.companies.isEmpty)
                    .accessibilityIdentifier("stockRecentCompanies")
                Spacer(minLength: 0)
                Button("本地记录") { showSaved() }.accessibilityIdentifier("stockOpenSaved")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { primaryAction(local); updateAction; cancelAction }
                VStack(alignment: .leading, spacing: 8) { primaryAction(local); updateAction; cancelAction }
            }
            localStatus(local)
            Text("本地分析与重开不联网。更新只在点击后请求 SEC，保留旧版本；AI 解读另行点击。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("SEC 连接设置", isExpanded: $showsConnectionSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("SEC 联系邮箱", text: $contactEmail).textFieldStyle(.roundedBorder)
                        .disabled(model.isBusy).accessibilityIdentifier("secContactEmail")
                    Text("填写一次即可在本机复用。邮箱仅随你发起的 SEC 请求发送，不进入财报、AI 摘要或归档。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }.font(.callout).accessibilityIdentifier("stockConnectionSettings")
            if !model.networkAvailable {
                Text("本构建的 SEC 服务不可用，仍可使用本地财报和已保存分析。")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("secNetworkDisabled")
            }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private func primaryAction(_ local: SECStockDailyCatalog) -> some View {
        if let report = model.financialReport {
            if model.canDisplayFinancialReport {
                Button(model.financialReportIsSaved ? "分析已保存" : "保存分析") {
                    perform(.saveReport(report.id))
                }.buttonStyle(.borderedProminent).disabled(!model.canSaveFinancialReport)
                    .accessibilityIdentifier("stockSaveAnalysis")
            } else {
                Button("重算并核对报告") { perform(.replayReport(report.id)) }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    .accessibilityIdentifier("stockReplayAnalysis")
            }
        } else if let document = model.document {
            Button("用这份财报生成分析") { perform(.analyzeResearch(document.id)) }
                .buttonStyle(.borderedProminent).disabled(!model.canGenerateFinancialReport)
                .accessibilityIdentifier("stockGenerateAnalysis")
        } else if let report = local.reports.first {
            Button("打开最近分析并核对") { perform(.openReport(report.id)) }
                .buttonStyle(.borderedProminent).disabled(model.isBusy)
                .accessibilityIdentifier("stockOpenLatestAnalysis")
        } else if let document = local.research.first {
            Button("用本地财报生成分析") { perform(.analyzeResearch(document.id)) }
                .buttonStyle(.borderedProminent).disabled(model.isBusy)
                .accessibilityIdentifier("stockGenerateAnalysis")
        }
    }

    private var updateAction: some View {
        Button("更新财报并分析") {
            guard !model.isBusy else { return }
            if contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showsConnectionSettings = true
            } else {
                showOverview()
                model.startDailyUpdate(email: contactEmail)
            }
        }.disabled(model.isBusy || !model.networkAvailable).accessibilityIdentifier("secImport")
    }

    @ViewBuilder private var cancelAction: some View {
        if model.isBusy && !model.archiveRestoreInProgress {
            Button("取消") { model.cancel() }.accessibilityIdentifier("secCancel")
        }
    }

    @ViewBuilder private func localStatus(_ local: SECStockDailyCatalog) -> some View {
        if model.canDisplayFinancialReport && !model.financialReportIsSaved {
            Text("分析尚未保存。保存后可离线重开；切换公司或更新会放下当前草稿。")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("stockUnsavedAnalysis")
        }
        if let report = local.reports.first {
            Text("最近保存的分析 · 来源截止 " + report.cutoff.formatted(date: .numeric, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let source = local.research.first {
            Text("本地财报 · 来源截止 " + source.cutoff.formatted(date: .numeric, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            if let displayed = model.financialReport, displayed.parentDocumentID != source.id,
               source.cutoff > displayed.cutoff {
                Button("用较新的本地财报生成分析") { perform(.analyzeResearch(source.id)) }
                    .buttonStyle(.borderless).disabled(model.isBusy)
                    .accessibilityIdentifier("stockAnalyzeNewerLocalSource")
            }
        } else if local.reports.isEmpty && model.document == nil && model.financialReport == nil {
            Text("该股票尚无可用的本地记录。可先更新财报，或从“最近公司”选择已有记录。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.listError != nil || model.financialListError != nil {
            Text("部分本地列表未能读取；可在“本地记录”中重试，已有可读内容仍可使用。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if local.conflictingRecordCount > 0 {
            Text("部分版本摘要有冲突，已从快捷选择中隐藏；请重新载入本地列表。")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func perform(_ action: SECStockDailyAction) {
        guard let request = model.makeDailyRequest(action) else { return }
        showOverview()
        Task { await model.performDaily(request) }
    }
}

/// Saved reports and source versions share company selection, not storage identity.
struct StockDailySavedRecords: View {
    @Bindable var model: SECResearchWorkspaceModel
    let showOverview: () -> Void

    var body: some View {
        let catalog = SECStockDailyCatalog(ticker: model.ticker, research: model.saved, reports: model.savedFinancialReports)
        return LazyVStack(alignment: .leading, spacing: 10) {
            Text(model.ticker + " · 本地记录").font(.title3.weight(.semibold))
            Text("只列当前股票的版本。打开分析会先核对冻结输入，不更新财报、不发送 AI 请求。")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("secSavedSummaryNotice")
            Button("重新载入本地列表") { reloadLists() }.disabled(model.isBusy)
            if let error = model.financialListError { Text(error).foregroundStyle(.red) }
            Text("已保存分析").font(.headline)
            ForEach(catalog.reports) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.companyName)
                        Text("来源截止 " + item.cutoff.formatted(date: .numeric, time: .shortened))
                        Text("生成于 " + item.createdAt.formatted(date: .numeric, time: .shortened))
                    }.font(.callout)
                    Spacer()
                    Button("打开并核对") { perform(.openReport(item.id)) }
                        .disabled(model.isBusy).accessibilityIdentifier("stockOpenAnalysis-" + item.id.uuidString)
                }
            }
            if catalog.reports.isEmpty && model.financialListError == nil {
                Text("尚无该股票的已保存分析。").foregroundStyle(.secondary)
            }
            Divider()
            Text("本地财报版本").font(.headline)
            if let error = model.listError { Text(error).foregroundStyle(.red) }
            ForEach(catalog.research) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.companyName)
                        Text("来源截止 " + item.cutoff.formatted(date: .numeric, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("生成分析") { perform(.analyzeResearch(item.id)) }
                        .disabled(model.isBusy).accessibilityIdentifier("stockAnalyzeSource-" + item.id.uuidString)
                }
            }
            if catalog.research.isEmpty && model.listError == nil {
                Text("尚无该股票的本地财报。").foregroundStyle(.secondary)
            }
            if catalog.conflictingRecordCount > 0 {
                Text("有冲突的版本摘要已隐藏，不会自动选择其中一份。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func reloadLists() {
        guard let request = model.makeDailyRequest(.reloadLists) else { return }
        Task { await model.performDaily(request) }
    }

    private func perform(_ action: SECStockDailyAction) {
        guard let request = model.makeDailyRequest(action) else { return }
        showOverview()
        Task { await model.performDaily(request) }
    }
}
