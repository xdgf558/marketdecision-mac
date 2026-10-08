import SwiftUI
import AppKit
import AppComposition
import DataContracts
import FundamentalsEngine

/// Explicit local capture workflow. Constructing this view does not check Keychain,
/// read a secret, construct a provider, or dispatch a market request.
struct EquityResearchContent: View {
    @Bindable var model: EquityResearchWorkspaceModel
    let financialTicker: String?

    private var confirmationOpen: Bool { model.confirmation != nil }
    private var credentialLocked: Bool { model.isCredentialBusy || confirmationOpen }
    private var requestLocked: Bool { model.isFetching || credentialLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("行情参考").font(.title2.bold())
                Text(model.networkAvailable
                    ? "Alpaca / IEX 单交易所报价与原始日线。点击读取才访问供应商；捕获记录不授予实时分析、历史 PIT、成交或账本资格。"
                    : "Alpaca / IEX 行情参考候选。此构建的网络服务未就绪，读取已停用；可以管理本机凭据和准备权利证据。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            credentials
            rights
            request
            if let message = model.fetchMessage {
                Text(message).font(.callout).foregroundStyle(model.hasFetchError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("equityFetchMessage")
            }
            if let result = model.result { capture(result) }
        }
        .background {
            EquityCredentialConfirmationHost(confirmation: model.confirmation) { id, confirmed in
                Task { await model.respondToConfirmation(id: id, confirmed: confirmed) }
            }.frame(width: 0, height: 0)
        }
        .onChange(of: [model.rightsAssertion, model.rightsEvidence, model.rightsEvidenceReference, model.rightsLicenseReference]) { _, _ in
            model.rightsConfirmed = false
        }
        .onDisappear {
            // Leaving just this tab preserves the completed capture for explicit use
            // in the valuation tab, but no secret draft or old confirmation survives.
            model.keyDraft = ""; model.secretDraft = ""
        }
    }

    private var credentials: some View {
        GroupBox("本机行情凭据") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(presenceText, systemImage: model.presence == .saved ? "key.fill" : "key")
                        .accessibilityIdentifier("equityCredentialPresence")
                    Spacer()
                    Button("检查保存状态") { Task { _ = await model.checkCredentials() } }
                        .disabled(credentialLocked).accessibilityIdentifier("equityCheckCredentials")
                    if model.isCredentialBusy { ProgressView().controlSize(.small) }
                }
                SecureField("API Key ID", text: $model.keyDraft)
                    .textFieldStyle(.roundedBorder).privacySensitive()
                    .disabled(credentialLocked || model.presence == .unknown)
                    .onSubmit { }
                    .accessibilityIdentifier("equityKeyID")
                SecureField("API Secret", text: $model.secretDraft)
                    .textFieldStyle(.roundedBorder).privacySensitive()
                    .disabled(credentialLocked || model.presence == .unknown)
                    .onSubmit { }
                    .accessibilityIdentifier("equitySecret")
                HStack {
                    Button(model.presence == .saved ? "替换凭据…" : "保存凭据") {
                        Task { await model.requestSaveCredentials() }
                    }.disabled(!model.canSaveCredentials || confirmationOpen)
                        .accessibilityIdentifier("equitySaveCredentials")
                    Button("删除凭据…", role: .destructive) { model.requestDeleteCredentials() }
                        .disabled(!model.canDeleteCredentials || confirmationOpen)
                        .accessibilityIdentifier("equityDeleteCredentials")
                }
                Text("先显式检查本机保存状态。Key ID 和 Secret 一起保存在钥匙串；输入框按 Return 只结束输入，不保存、不读取行情。保存状态不代表账户或数据权限有效。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.credentialMessage {
                    Text(message).font(.callout).foregroundStyle(model.hasCredentialError ? Color.red : Color.secondary)
                        .accessibilityIdentifier("equityCredentialMessage")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var presenceText: String {
        switch model.presence {
        case .unknown: "尚未检查本机凭据"
        case .absent: "尚未保存凭据"
        case .saved: "本机已保存凭据（未验证账户）"
        }
    }

    private var rights: some View {
        GroupBox("本次读取与本地留存权利") {
            VStack(alignment: .leading, spacing: 10) {
                Text("请依据自己的账户与适用条款填写。此处记录你的声明及证据，不认证供应商许可，也不自动购买或升级订阅。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("本次用途与本地留存权利声明", text: $model.rightsAssertion, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("equityRightsAssertion")
                TextField("支持声明的证据原文", text: $model.rightsEvidence, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("equityRightsEvidence")
                TextField("证据来源引用（如账户权限页或条款位置）", text: $model.rightsEvidenceReference)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("equityRightsReference")
                TextField("适用许可／条款引用", text: $model.rightsLicenseReference)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("equityLicenseReference")
                Toggle("我已核对本次读取与本地留存权利，并同意将上述证据随捕获记录保存在本机", isOn: $model.rightsConfirmed)
                    .accessibilityIdentifier("equityRightsConfirmed")
                Text("不要在证据文字中填写 API Key、Secret 或账户敏感信息。修改声明或引用后需重新确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(requestLocked).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var request: some View {
        GroupBox("显式读取行情") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("股票代码（大写）", text: $model.symbolDraft)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                        .accessibilityIdentifier("equitySymbol")
                    TextField("对应股类标识", text: $model.classIDDraft).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("equityClassID")
                    if let financialTicker {
                        Button("使用财报代码 " + financialTicker) { model.symbolDraft = financialTicker }
                    }
                }.disabled(requestLocked)
                Picker("本次价格参考", selection: $model.selectedSide) {
                    Text("买方报价 Bid").tag(SECReferencePriceSide.bid)
                    Text("卖方报价 Ask").tag(SECReferencePriceSide.ask)
                }.pickerStyle(.segmented).disabled(requestLocked).accessibilityIdentifier("equityQuoteSide")
                Text("股类标识需与财务报告补充证据一致。只使用你选定的一侧，不取中间价，不推定公允价值。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("同时读取原始日线", isOn: $model.includeDailyBars)
                    .disabled(requestLocked).accessibilityIdentifier("equityIncludeDailyBars")
                if model.includeDailyBars {
                    HStack {
                        DatePicker("开始（UTC）", selection: $model.barsStart, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("结束（UTC）", selection: $model.barsEnd, displayedComponents: [.date, .hourAndMinute])
                    }.environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .disabled(requestLocked)
                    Text("按所选 UTC 时间范围读取；不超过 366 天，结束时间须早于纽约今日。最多读取 4 页，达到上限时明确保留部分数据状态；不自动补齐或转为历史估值输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("读取 IEX 行情") { Task { await model.fetch() } }
                        .disabled(!model.canFetch || confirmationOpen).accessibilityIdentifier("equityFetch")
                    if model.isFetching {
                        ProgressView().controlSize(.small)
                        Text("正在读取并留存来源…").font(.callout)
                        Button("取消读取") { model.cancelFetch() }.accessibilityIdentifier("equityCancelFetch")
                    }
                }
                if let unavailable = model.networkUnavailableMessage {
                    Text(unavailable).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("equityNetworkUnavailable")
                    Text("需先完成独立行情服务的权限批准与嵌入；此状态不会读取已保存的秘密或尝试联网。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("点击后以已保存凭据向 Alpaca 发送股票代码及所选范围。进入本页或编辑字段均不会自动读取。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func capture(_ result: EquityResearchCapture) -> some View {
        GroupBox("本次捕获 · " + result.symbol) {
            VStack(alignment: .leading, spacing: 12) {
                capturedQuoteSummary(result.quoteEvidence)
                Text("Alpaca / IEX · 单交易所、非合并 NBBO · 原始未复权口径 · 不用于成交、实时分析或历史 PIT")
                    .font(.caption).foregroundStyle(.secondary)
                capturedRawQuote(result)
                capturedDailyStatus(result)
                ForEach(Array(result.pages.enumerated()), id: \.element.request.id) { index, page in
                    capturedPage(page, number: index + 1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.accessibilityIdentifier("equityCaptureResult")
    }

    @ViewBuilder private func capturedQuoteSummary(_ evidence: SECValuationPriceEvidence?) -> some View {
        if let price = evidence, let selectedPrice = price.selectedPrice {
            let side: String = price.selectedSide == .bid ? "选定买方报价 Bid：" : "选定卖方报价 Ask："
            let priceText: String = "\(side)\(selectedPrice.decimalString) USD"
            let identityText: String = "股类 \(price.classID) · 源时刻 \(price.record.sourceTimestamp)"
            let receivedText: String = "接收 \(price.capturedAt.formatted(date: .numeric, time: .standard)) · 历史公开可用时刻未知"
            Text(priceText).font(.headline).monospacedDigit()
            Text(identityText).font(.caption).textSelection(.enabled)
            Text(receivedText).font(.caption).foregroundStyle(.secondary)
            Text("只有在“估值与评分”中再次勾选才会加入补充报告；切换父报告或来源会清除勾选。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("本次报价未满足当前参考条件，不能选入补充报告。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func capturedRawQuote(_ result: EquityResearchCapture) -> some View {
        if let record = result.pages.first(where: { $0.request.capability == .quote })?.records.first,
           let quote = record.quote {
            let quoteText: String = "原报价 Bid \(quote.bid.decimalString) / Ask \(quote.ask.decimalString) USD；数量 \(quote.bidSize.decimalString) / \(quote.askSize.decimalString) round lots"
            Text(quoteText).font(.callout).monospacedDigit().textSelection(.enabled)
        }
    }

    @ViewBuilder private func capturedDailyStatus(_ result: EquityResearchCapture) -> some View {
        let dailyPages = result.pages.filter { $0.request.capability == .bars }
        if !dailyPages.isEmpty {
            let status: String = result.dailyBarsComplete ? "本次分页读取完毕" : "部分数据：达到分页上限，仍有后续页"
            let summary: String = "原始日线：\(result.dailyBarCount) 条、\(dailyPages.count) 页 · \(status)"
            Text(summary).font(.callout).foregroundStyle(result.dailyBarsComplete ? Color.secondary : Color.orange)
            Text("分页完毕只表示此次请求没有后续页，不证明每个交易日齐全或历史数据合格。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func capturedPage(_ page: EquityResearchPage, number: Int) -> some View {
        DisclosureGroup("第 \(number) 页 · " + (page.request.capability == .quote ? "报价" : "原始日线")
            + " · \(page.records.count) 条") {
            VStack(alignment: .leading, spacing: 7) {
                Text("供应商 " + page.request.providerID + " / " + page.request.feedID + " · 响应状态 " + page.status)
                Text("接收 " + page.receivedAt.formatted(date: .numeric, time: .standard)
                    + (page.nextPageToken == nil ? " · 无后续页标记" : " · 有后续页标记"))
                Text("请求 ID：" + page.request.id.uuidString)
                Text("源对象：" + page.rawSource.reference)
                Text("源 SHA-256：" + page.rawSource.contentHash)
                Text("权利证据引用：" + page.rights.evidenceReference)
                Text("许可引用：" + page.rights.licenseReference)
                Text("权利证据 SHA-256：" + page.rights.evidenceHash)
                if page.request.capability == .bars {
                    Text("下方预览本页前 50 条原始日线；不作复权、补值或历史估值。")
                        .foregroundStyle(.secondary)
                    ForEach(Array(page.records.prefix(50).enumerated()), id: \.offset) { _, record in
                        if let bar = record.bar {
                            Text(record.sourceTimestamp + " · O " + bar.open.decimalString + " H " + bar.high.decimalString
                                + " L " + bar.low.decimalString + " C " + bar.close.decimalString + " USD · V " + bar.volume.decimalString)
                                .monospacedDigit()
                        }
                    }
                }
            }.font(.caption).textSelection(.enabled).padding(.vertical, 8)
        }
    }
}

/// A native projection of one model confirmation ID. Aborting or dismantling the
/// sheet cannot authorize persistence; the model also checks session and revision.
private struct EquityCredentialConfirmationHost: NSViewRepresentable {
    let confirmation: EquityResearchWorkspaceModel.Confirmation?
    let respond: (UUID, Bool) -> Void

    final class HostView: NSView {
        var windowChanged: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?() }
    }
    @MainActor final class Coordinator {
        var presentation: EquityCredentialConfirmationHost
        private var rendered: (id: UUID, alert: NSAlert)?
        init(_ presentation: EquityCredentialConfirmationHost) { self.presentation = presentation }
        func synchronize(in window: NSWindow?) {
            if let rendered, rendered.id != presentation.confirmation?.id || window == nil { dismiss() }
            guard rendered == nil, let window, let confirmation = presentation.confirmation else { return }
            let replacing = confirmation.action == .replace, alert = NSAlert()
            alert.messageText = replacing ? "替换本机行情凭据？" : "删除本机行情凭据？"
            alert.informativeText = replacing
                ? "Key ID 和 Secret 将一起替换，原凭据无法在应用内恢复。按 Command-R 确认，Esc 取消。"
                : "删除后须重新输入行情凭据才能读取。按 Command-D 确认，Esc 取消。"
            let commit = alert.addButton(withTitle: replacing ? "替换" : "删除")
            commit.hasDestructiveAction = true
            commit.keyEquivalent = replacing ? "r" : "d"; commit.keyEquivalentModifierMask = .command
            let cancel = alert.addButton(withTitle: "取消")
            cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = nil
            rendered = (confirmation.id, alert)
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.rendered?.id == confirmation.id else { return }
                self.rendered = nil
                self.presentation.respond(confirmation.id, response == .alertFirstButtonReturn)
            }
        }
        func dismiss() {
            guard let current = rendered else { return }
            let parent = current.alert.window.sheetParent
            let keyWindowBeforeAbort = NSApp.isActive ? NSApp.keyWindow : nil
            rendered = nil
            parent?.endSheet(current.alert.window, returnCode: .abort)
            if NSApp.isActive, let keyWindowBeforeAbort, keyWindowBeforeAbort !== parent,
               keyWindowBeforeAbort !== current.alert.window, keyWindowBeforeAbort.isVisible,
               !keyWindowBeforeAbort.isMiniaturized {
                keyWindowBeforeAbort.makeKeyAndOrderFront(nil)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.windowChanged = { [weak view, weak coordinator = context.coordinator] in
            coordinator?.synchronize(in: view?.window)
        }
        return view
    }
    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.presentation = self; context.coordinator.synchronize(in: view.window)
    }
    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        view.windowChanged = nil; coordinator.dismiss()
    }
}
