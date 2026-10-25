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
            // Independent workspaces remain reachable while the SEC page loads or fails.
            // This navigation must never depend on a child database opening successfully.
            HStack {
                if tool == .company {
                    Text("股票分析").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("stockAnalysisTitle")
                } else {
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
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                    .accessibilityIdentifier("stockAdvancedTools")
            }.frame(maxWidth: 1280)
                .padding(.horizontal, 20).padding(.top, 4)
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

/// Shared visual treatment only; the native Button retains its enabled and keyboard behavior.
struct StockActionButtonStyle: ButtonStyle {
    enum Kind: Equatable { case quiet, outline, filled }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.48, green: 0.77, blue: 0.68)
            : Color(red: 0.10, green: 0.34, blue: 0.31)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(kind == .filled ? Color.white : accent)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if kind == .outline {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
    }

    private var backgroundColor: Color {
        switch kind {
        case .quiet: accent.opacity(colorScheme == .dark ? 0.12 : 0.06)
        case .outline: Color.clear
        case .filled: Color(red: 0.10, green: 0.34, blue: 0.31)
        }
    }
}

/// Metadata-only navigation. Choosing a company never opens a body or sends a request.
struct StockDailyControls: View {
    @Bindable var model: SECResearchWorkspaceModel
    @Binding var contactEmail: String
    @Binding var showsConnectionSettings: Bool
    let showOverview: () -> Void
    let showSaved: () -> Void
    @State private var showsCompanyPicker = false

    private var catalog: SECStockDailyCatalog {
        .init(ticker: model.ticker, research: model.saved, reports: model.savedFinancialReports)
    }

    var body: some View {
        let local = catalog
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    companyHeading(local).frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
                    headerActions(local).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    companyHeading(local)
                    headerActions(local)
                }
            }
            localStatus(local)
            if !model.networkAvailable {
                Text("本构建的 SEC 服务不可用，仍可使用本地财报和已保存分析。")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("secNetworkDisabled")
            }
        }.padding(.vertical, 2)
            .popover(isPresented: $showsCompanyPicker, arrowEdge: .bottom) {
                companySelection(local)
            }
    }

    private var selectedTicker: String {
        model.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var selectedReport: SECFinancialReportDocument? {
        guard let report = model.financialReport, report.ticker.uppercased() == selectedTicker else { return nil }
        return report
    }

    private var selectedDocument: SECResearchDocument? {
        guard let document = model.document, document.ticker.uppercased() == selectedTicker else { return nil }
        return document
    }

    private func companyName(_ local: SECStockDailyCatalog) -> String {
        selectedReport?.companyName ?? selectedDocument?.identity.name
            ?? local.companies.first(where: { $0.ticker == selectedTicker })?.companyName
            ?? (selectedTicker.isEmpty ? "选择一家公司" : selectedTicker)
    }

    private func companyHeading(_ local: SECStockDailyCatalog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    companyIdentity(local)
                    companyPicker
                }
                VStack(alignment: .leading, spacing: 6) {
                    companyIdentity(local)
                    companyPicker
                }
            }
            companyMetadata(local)
        }
    }

    private func companyIdentity(_ local: SECStockDailyCatalog) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(companyName(local)).font(.system(size: 22, weight: .bold))
                .lineLimit(2).accessibilityAddTraits(.isHeader)
            if !selectedTicker.isEmpty && companyName(local) != selectedTicker {
                Text(selectedTicker).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func companyMetadata(_ local: SECStockDailyCatalog) -> some View {
        if let report = selectedReport {
            Text((model.canDisplayFinancialReport
                    ? "财报期末 " + report.financials.baseReport.periodEnd.iso8601 + " · " : "")
                 + "来源截至 " + report.cutoff.formatted(date: .numeric, time: .shortened)
                 + (model.canDisplayFinancialReport ? " · 本地财报" : " · 报告待核对"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let source = selectedDocument {
            Text("来源截至 " + source.cutoff.formatted(date: .numeric, time: .shortened) + " · 本地财报")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let company = local.companies.first(where: { $0.ticker == selectedTicker }) {
            Text("本地记录截至 " + company.cutoff.formatted(date: .numeric, time: .shortened) + " · 尚未打开核对")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Text("选择股票后，更新财报或打开本地记录。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var companyPicker: some View {
        Button {
            showsCompanyPicker = true
        } label: {
            Label("切换公司", systemImage: "chevron.down")
        }.buttonStyle(StockActionButtonStyle(kind: .quiet))
            .disabled(model.isBusy).accessibilityIdentifier("stockSwitchCompany")
    }

    private func companySelection(_ local: SECStockDailyCatalog) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择公司").font(.headline)
            TextField("股票代码，如 AAPL", text: Binding(get: { model.ticker }, set: { model.chooseTicker($0) }))
                .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                .accessibilityIdentifier("secTicker")
            Menu("最近公司") {
                ForEach(local.companies) { company in
                    Button(company.ticker + " · " + company.companyName) {
                        model.chooseTicker(company.ticker)
                        showsCompanyPicker = false
                        showOverview()
                    }
                }
            }.disabled(model.isBusy || local.companies.isEmpty)
                .accessibilityIdentifier("stockRecentCompanies")
            Text("切换只选择公司，不会联网或自动生成分析。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { showsCompanyPicker = false; showOverview() }
                    .buttonStyle(StockActionButtonStyle(kind: .quiet))
            }
        }.padding(18).frame(width: 300)
    }

    private func headerActions(_ local: SECStockDailyCatalog) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    savedRecordsAction
                    primaryAction(local)
                    updateAction
                    cancelAction
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { savedRecordsAction; primaryAction(local) }
                    HStack(spacing: 8) { updateAction; cancelAction }
                }
            }
            if selectedReport != nil && model.canDisplayFinancialReport && !model.financialReportIsSaved {
                Label("分析未保存", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                    .help("保存后可离线重开；切换公司或更新会放下当前草稿。")
                    .accessibilityIdentifier("stockUnsavedAnalysis")
            }
        }
    }

    private var savedRecordsAction: some View {
        Button("本地记录") { showSaved() }
            .buttonStyle(StockActionButtonStyle(kind: .quiet)).accessibilityIdentifier("stockOpenSaved")
    }

    @ViewBuilder private func primaryAction(_ local: SECStockDailyCatalog) -> some View {
        if let report = selectedReport {
            if model.canDisplayFinancialReport {
                Button(model.financialReportIsSaved ? "分析已保存" : "保存分析") {
                    perform(.saveReport(report.id))
                }.buttonStyle(StockActionButtonStyle(kind: .outline)).disabled(!model.canSaveFinancialReport)
                    .accessibilityIdentifier("stockSaveAnalysis")
            } else {
                Button("重算并核对报告") { perform(.replayReport(report.id)) }
                    .buttonStyle(StockActionButtonStyle(kind: .outline)).disabled(model.isBusy)
                    .accessibilityIdentifier("stockReplayAnalysis")
            }
        } else if let document = selectedDocument {
            Button("用这份财报生成分析") { perform(.analyzeResearch(document.id)) }
                .buttonStyle(StockActionButtonStyle(kind: .outline)).disabled(!model.canGenerateFinancialReport)
                .accessibilityIdentifier("stockGenerateAnalysis")
        } else if let report = local.reports.first {
            Button("打开最近分析并核对") { perform(.openReport(report.id)) }
                .buttonStyle(StockActionButtonStyle(kind: .outline)).disabled(model.isBusy)
                .accessibilityIdentifier("stockOpenLatestAnalysis")
        } else if let document = local.research.first {
            Button("用本地财报生成分析") { perform(.analyzeResearch(document.id)) }
                .buttonStyle(StockActionButtonStyle(kind: .outline)).disabled(model.isBusy)
                .accessibilityIdentifier("stockGenerateAnalysis")
        }
    }

    private var updateAction: some View {
        Button("更新财报") {
            guard !model.isBusy else { return }
            if contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showOverview()
                showsConnectionSettings = true
            } else {
                showOverview()
                model.startDailyUpdate(email: contactEmail)
            }
        }.buttonStyle(StockActionButtonStyle(kind: .filled))
            .disabled(model.isBusy || !model.networkAvailable).accessibilityIdentifier("secImport")
            .help("点击后请求 SEC 更新财报，并用新来源准备本地分析；保留旧版本，不自动发送 AI 请求。")
    }

    @ViewBuilder private var cancelAction: some View {
        if model.isBusy && !model.archiveRestoreInProgress {
            Button("取消") { model.cancel() }.buttonStyle(StockActionButtonStyle(kind: .quiet))
                .accessibilityIdentifier("secCancel")
        }
    }

    @ViewBuilder private func localStatus(_ local: SECStockDailyCatalog) -> some View {
        if selectedReport == nil, let report = local.reports.first {
            Text("最近保存的分析 · 来源截止 " + report.cutoff.formatted(date: .numeric, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let source = local.research.first {
            if selectedReport == nil && selectedDocument == nil {
                Text("本地财报 · 来源截止 " + source.cutoff.formatted(date: .numeric, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let displayed = selectedReport, displayed.parentDocumentID != source.id,
               source.cutoff > displayed.cutoff {
                Button("用较新的本地财报生成分析") { perform(.analyzeResearch(source.id)) }
                    .buttonStyle(.borderless).disabled(model.isBusy)
                    .accessibilityIdentifier("stockAnalyzeNewerLocalSource")
            }
        } else if local.reports.isEmpty && selectedDocument == nil && selectedReport == nil {
            Text("该股票尚无可用的本地记录。可先更新财报，或在“切换公司”中选择已有记录。")
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

/// Explicit connection configuration is displayed inside the page's advanced section.
struct StockConnectionControls: View {
    @Bindable var model: SECResearchWorkspaceModel
    @Binding var contactEmail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("SEC 联系邮箱", text: $contactEmail).textFieldStyle(.roundedBorder)
                .disabled(model.isBusy).accessibilityIdentifier("secContactEmail")
            Text("填写一次即可在本机复用。邮箱仅随你发起的 SEC 请求发送，不进入财报、AI 摘要或归档。")
                .font(.caption).foregroundStyle(.secondary)
            Text("本地分析与重开不联网。更新只在点击后请求 SEC，保留旧版本；AI 解读另行点击。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
