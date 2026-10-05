import SwiftUI
import Security
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
                    let ready = try await workspace.makeSECResearchWorkspace(networkAvailable: SECNetworkPermission.isEnabled)
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

/// Read the effective signature, not an app preference. The synthetic UI host remains unable to make
/// real SEC requests even if a contact address is entered into their settings.
private enum SECNetworkPermission {
    static var isEnabled: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.network.client"] as? Bool == true
    }
}

struct SECResearchContent: View {
    @Bindable var model: SECResearchWorkspaceModel
    // User-provided contact stays in local preferences. It is excluded from research documents,
    // source provenance, exported material, error messages and diagnostics.
    @AppStorage("secContactEmail") private var contactEmail = ""
    @State private var section = "财务数据"
    @State private var filter = ""
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
                        Text("本构建尚未启用 SEC 网络权限，可查看和重算已保存研究。")
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
                ForEach(["财务数据", "来源与修订", "已保存"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("secSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if section == "已保存" { saved }
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
        case .financialClassificationNotSupplied: "企业行业及完整计算期间尚未核定，不自动生成完整比率与评分。"
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
    private var saved: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("重新载入列表") { Task { await model.load() } }.disabled(model.isBusy)
            if let error = model.listError { Text(error).foregroundStyle(.red) }
            ForEach(model.saved, id: \.id) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.ticker + " · " + item.identity.name)
                        Text(item.cutoff.formatted(date: .numeric, time: .standard)).font(.caption).foregroundStyle(.secondary)
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
