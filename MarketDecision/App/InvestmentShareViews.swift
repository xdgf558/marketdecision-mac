import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppComposition

private struct InvestmentSharePeriodRequest: Identifiable {
    let id = UUID()
    let period: InvestmentReportPeriod
}

private struct InvestmentSharePNG: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct InvestmentShareSheet: View {
    let snapshot: InvestmentShareSnapshot
    let selectPeriod: (@MainActor (InvestmentReportPeriod) async -> InvestmentShareSnapshot?)?
    @Environment(\.dismiss) private var dismiss
    @State private var displayedSnapshot: InvestmentShareSnapshot?
    @State private var selectedPeriod: InvestmentReportPeriod?
    @State private var periodRequest: InvestmentSharePeriodRequest?
    @State private var options = InvestmentShareOptions()
    @State private var message: String?
    @State private var showsDetails = false
    @State private var visible = false
    @State private var exporting = false
    @State private var exportFile: InvestmentSharePNG?
    @State private var fileFlow = ResearchFileRequestFlow()
    private let accent = Color(red: 0, green: 0.40, blue: 0.37)
    private let previewWidth: CGFloat = 460
    private var content: InvestmentShareCardContent? { displayedSnapshot?.card(options: options) }
    private var isLoading: Bool { periodRequest != nil }
    private var busy: Bool { isLoading || fileFlow.isBusy }
    private var hidesAmounts: Binding<Bool> {
        Binding(get: { !options.showAmounts }, set: { options.showAmounts = !$0 })
    }

    init(snapshot: InvestmentShareSnapshot,
         selectPeriod: (@MainActor (InvestmentReportPeriod) async -> InvestmentShareSnapshot?)? = nil) {
        self.snapshot = snapshot
        self.selectPeriod = selectPeriod
        _displayedSnapshot = State(initialValue: snapshot)
        _selectedPeriod = State(initialValue: snapshot.periodSelection)
    }

    var body: some View {
        let fileRequest = fileFlow.id
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("收益分享").font(.system(size: 30, weight: .bold))
                    Text("个人投资 · USD").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.plain).foregroundStyle(accent)
                    .font(.headline).keyboardShortcut(.cancelAction)
                    .disabled(fileFlow.isBusy).accessibilityIdentifier("investmentShareClose")
            }
            HStack(alignment: .top, spacing: 40) {
                controls.frame(width: 348, alignment: .leading)
                preview.frame(width: previewWidth)
            }
        }
        .padding(28).frame(width: 944)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .fileExporter(isPresented: $exporting, document: exportFile, contentTypes: [.png],
                      defaultFilename: "投资收益分享.png") { result in
            switch result {
            case .success: finishExport(.succeeded, request: fileRequest)
            case .failure: finishExport(.failed, request: fileRequest)
            }
        } onCancellation: { finishExport(.cancelled, request: fileRequest) }
        .task(id: periodRequest?.id) {
            guard let request = periodRequest, let selectPeriod else { return }
            let result = await selectPeriod(request.period)
            guard !Task.isCancelled, visible, periodRequest?.id == request.id else { return }
            if let result, result.periodSelection == request.period {
                displayedSnapshot = result
            } else {
                message = "这段收益未能完成账本核对，请重新选择周期或关闭后刷新。"
            }
            periodRequest = nil
        }
        .onChange(of: options) { _, _ in clearFileResult() }
        .onAppear { visible = true }
        .onDisappear {
            visible = false; periodRequest = nil; displayedSnapshot = nil
            fileFlow.dismiss(); exportFile = nil; exporting = false; message = nil
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("统计周期").font(.headline)
                if selectedPeriod != nil, selectPeriod != nil {
                    HStack(spacing: 0) {
                        ForEach(InvestmentReportPeriod.allCases) { period in
                            Button { changePeriod(period) } label: {
                                Text(period.title).font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .foregroundStyle(selectedPeriod == period ? accent : Color.primary)
                                    .background(selectedPeriod == period ? accent.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain).disabled(busy)
                            .accessibilityIdentifier("investmentSharePeriod-" + period.id)
                            .accessibilityAddTraits(selectedPeriod == period ? .isSelected : [])
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                } else { Text(content?.periodTitle ?? "冻结区间报告").font(.headline) }
                Text(content?.dateRange ?? "正在核对所选周期…")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("investmentShareDates")
                Text("按美东时间统计 · 滚动自然月").font(.caption).foregroundStyle(.secondary)
                    .opacity(selectedPeriod == nil ? 0 : 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("隐藏金额", isOn: hidesAmounts).toggleStyle(.switch).font(.headline)
                    .disabled(busy).accessibilityIdentifier("investmentShareHideAmounts")
                Text("开启后，分享图将隐藏总额与所有金额明细。")
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.supportsReturn {
                    Toggle("显示收益率", isOn: $options.showReturn).toggleStyle(.checkbox)
                        .disabled(busy).accessibilityIdentifier("investmentShareReturn")
                }
                if snapshot.supportsHoldingNames {
                    Toggle("显示持仓名称", isOn: $options.showHoldingNames).toggleStyle(.checkbox)
                        .disabled(busy).accessibilityIdentifier("investmentShareHoldings")
                    if options.showHoldingNames {
                        Text("最多显示 6 项持仓名称，请核对是否愿意公开。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(snapshot.supportsReturn ? "仅分享已复算的冻结报告" : "仅展示已入账收益，不含持仓浮盈")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Button(action: saveCard) {
                    Label("保存分享图", systemImage: "square.and.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(accent, in: RoundedRectangle(cornerRadius: 9))
                .opacity(content == nil || busy ? 0.45 : 1).disabled(content == nil || busy)
                .accessibilityIdentifier("investmentShareSave")
                Button("查看收益明细") { showsDetails = true }
                    .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(accent)
                    .disabled(content == nil || busy).accessibilityIdentifier("investmentShareDetails")
                    .popover(isPresented: $showsDetails) { details }
                HStack(spacing: 16) {
                    Button("复制图片") { copyCard(openX: false) }.accessibilityIdentifier("investmentShareCopy")
                    Button("复制并打开 X") { copyCard(openX: true) }.accessibilityIdentifier("investmentShareOpenX")
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .disabled(content == nil || busy)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("investmentShareMessage")
            }
            Text("图片不含账户名称、原始交易或来源文件。打开 X 后需自行粘贴并发布。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 20)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("分享预览").font(.callout).foregroundStyle(.secondary)
            if let content {
                InvestmentShareCard(content: content)
                    .environment(\.colorScheme, .light)
                    .scaleEffect(previewWidth / InvestmentShareCard.width, anchor: .topLeading)
                    .frame(width: previewWidth, height: InvestmentShareCard.height * previewWidth / InvestmentShareCard.width, alignment: .topLeading)
                Text(content.asOfLabel).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(spacing: 12) {
                    if isLoading { ProgressView("正在核对分享数据…") }
                    else { Label("尚未取得可分享的收益", systemImage: "doc.text.magnifyingglass") }
                }
                .frame(width: previewWidth, height: InvestmentShareCard.height * previewWidth / InvestmentShareCard.width)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("收益明细与统计口径").font(.headline)
            if let content {
                Text(content.period).font(.caption).textSelection(.enabled)
                HStack { Text(content.profitLabel); Spacer(); Text(content.amount).monospacedDigit() }
                ForEach(content.breakdown.indices, id: \.self) { index in
                    HStack { Text(content.breakdown[index].title); Spacer(); Text(content.breakdown[index].value).monospacedDigit() }
                }
                Divider()
                Text(content.scope)
                if !content.breakdown.isEmpty {
                    Text("交易费用已计入交易盈亏；费用与税款一行仅列独立入账支出，不重复扣除。")
                }
                Text(content.evidenceLabel)
                Text(content.valuationLabel)
                Text(content.versionLabel)
                Text(content.footnote)
            }
        }.font(.callout).padding(20).frame(width: 420)
    }

    private func changePeriod(_ period: InvestmentReportPeriod) {
        guard !busy, selectPeriod != nil else { return }
        guard period != displayedSnapshot?.periodSelection else { return }
        clearFileResult(); showsDetails = false
        selectedPeriod = period; displayedSnapshot = nil
        periodRequest = .init(period: period)
    }

    private func clearFileResult() {
        guard !fileFlow.isBusy else { return }
        fileFlow.dismiss(); exportFile = nil; message = nil
    }

    @MainActor private func renderedPNG() -> Data? {
        guard visible, !busy, let content else { return nil }
        let renderer = ImageRenderer(content: InvestmentShareCard(content: content).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @MainActor private func saveCard() {
        guard let png = renderedPNG() else { message = "分享图未能生成，请重新核对后重试。"; return }
        guard fileFlow.begin() != nil else { return }
        // Freeze these bytes before opening the native panel. Its callbacks
        // cannot pick up a later period or privacy setting.
        exportFile = InvestmentSharePNG(png); message = nil; exporting = true
    }

    private func finishExport(_ outcome: ResearchFileRequestFlow.Outcome, request: UUID?) {
        guard visible, fileFlow.receive(outcome, for: request) else { return }
        switch outcome {
        case .succeeded: message = "分享图已保存；尚未上传或发布。"
        case .failed: message = "图片未能保存，请重新选择可写入的位置。"
        case .cancelled: message = "已取消保存。"
        }
        exportFile = nil
    }

    @MainActor private func copyCard(openX: Bool) {
        guard let png = renderedPNG() else { message = "卡片未能生成，未复制或打开 X。"; return }
        clearFileResult()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(png, forType: .png) else {
            message = "图片未能复制，未打开 X。"; return
        }
        if openX {
            message = NSWorkspace.shared.open(InvestmentShareSnapshot.composeURL)
                ? "图片已复制。请在 X 粘贴图片、核对后自行发布。"
                : "图片已复制，但 X 未能打开。可以手动打开 X 并粘贴。"
        } else { message = "PNG 图片已复制，可粘贴到 X；尚未上传或发布。" }
    }
}

/// The preview and the exported bitmap use this exact fixed-size view. All
/// account/private source data has already been removed by the snapshot type.
private struct InvestmentShareCard: View {
    static let width: CGFloat = 600
    static let height: CGFloat = 650
    let content: InvestmentShareCardContent
    private func currency(_ value: String, signed: Bool = true) -> String {
        guard value.hasSuffix(" USD") else { return value }
        let number = String(value.dropLast(4))
        if number.hasPrefix("-") { return "-$" + number.dropFirst() }
        if number.hasPrefix("+") { return (signed ? "+$" : "$") + number.dropFirst() }
        return "$" + number
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("个人投资").font(.system(size: 24, weight: .medium))
                Spacer(); Text("USD").font(.system(size: 20, weight: .semibold)).opacity(0.75)
            }
            Text(content.periodTitle).font(.system(size: 26, weight: .semibold)).padding(.top, 28)
                .accessibilityIdentifier("investmentShareCardPeriod")
            Text(content.dateRange).font(.system(size: 18)).opacity(0.8).padding(.top, 6)
            Text(content.periodBoundaryLabel).font(.system(size: 10)).opacity(0.75).padding(.top, 5)
                .fixedSize(horizontal: false, vertical: true)
            Text(content.profitLabel).font(.system(size: 22, weight: .medium)).padding(.top, 26)
            Text(currency(content.amount)).font(.system(size: 72, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.4).padding(.top, 8)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .accessibilityLabel(content.amount).accessibilityIdentifier("investmentShareTotal")
            Rectangle().fill(Color.white.opacity(0.28)).frame(height: 1).padding(.top, 24).padding(.bottom, 20)
            if content.breakdown.isEmpty {
                frozenDetails
            } else {
                VStack(spacing: 17) {
                    ForEach(content.breakdown.indices, id: \.self) { index in
                        HStack {
                            Text(content.breakdown[index].title)
                            Spacer()
                            Text(currency(content.breakdown[index].value, signed: index != 2)).monospacedDigit()
                                .accessibilityLabel(content.breakdown[index].value)
                                .accessibilityIdentifier("investmentShareBreakdown-\(index)")
                        }.font(.system(size: 20)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 5) {
                Text(content.evidenceLabel).font(.system(size: 12, weight: .medium))
                Text(content.breakdown.isEmpty ? content.valuationLabel + " · " + content.versionLabel : "含已入账费用，不含持仓浮盈 · 入出金不计收益")
                    .font(.system(size: 13))
                if !content.breakdown.isEmpty { Text(content.versionLabel).font(.system(size: 10)) }
                Text(content.footnote).font(.system(size: 10))
            }.opacity(0.85).fixedSize(horizontal: false, vertical: true)
        }
        .padding(36).frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .background {
            Image("InvestmentShareBackdrop").resizable().scaledToFill()
                .frame(width: Self.width, height: Self.height).clipped()
                .overlay(Color.black.opacity(0.10))
                .background(Color(red: 0.015, green: 0.17, blue: 0.14))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("investmentSharePreview")
    }

    private var frozenDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label = content.returnLabel {
                HStack { Text(label); Spacer(); Text(content.returnText).monospacedDigit() }.font(.system(size: 21))
            }
            if !content.holdings.isEmpty {
                // Reserve space for synthetic/stale/history evidence even when
                // all six names contain long CJK strings. This is an excerpt.
                Text("持仓摘录（共 \(content.holdings.count) 项）：" + content.holdings.prefix(6).joined(separator: " · "))
                    .font(.system(size: 14)).lineLimit(3).truncationMode(.tail)
                    .frame(maxHeight: 54, alignment: .topLeading)
            }
            Text(content.scope).font(.system(size: 12)).opacity(0.8)
        }
    }
}
