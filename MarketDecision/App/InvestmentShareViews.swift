import SwiftUI
import AppKit
import AppComposition

struct InvestmentShareSheet: View {
    let snapshot: InvestmentShareSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var options = InvestmentShareOptions()
    @State private var message: String?
    private var content: InvestmentShareCardContent { snapshot.card(options: options) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分享我的投资记录").font(.title2.bold())
                    Text("只生成下方卡片，不包含账户名称、原始交易、来源文件或密钥。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 24) {
                Toggle("显示金额", isOn: $options.showAmounts).accessibilityIdentifier("investmentShareAmounts")
                Toggle("显示收益率", isOn: $options.showReturn).accessibilityIdentifier("investmentShareReturn")
                Toggle("显示持仓名称", isOn: $options.showHoldingNames).accessibilityIdentifier("investmentShareHoldings")
            }.toggleStyle(.checkbox)
            if options.showHoldingNames { Text("卡片最多显示 6 项持仓名称，长名称会缩短；请核对是否愿意公开。").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                InvestmentShareCard(content: content)
                    .environment(\.colorScheme, .light)
                    .frame(maxWidth: .infinity)
            }.frame(maxHeight: 500)
            Text("复制后，在 X 粘贴图片并自行发布。打开 X 不会自动上传卡片或发布内容；请在发布前核对预览。")
                .font(.callout).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).accessibilityIdentifier("investmentShareMessage") }
            HStack {
                Button("复制图片") { copyCard(openX: false) }.accessibilityIdentifier("investmentShareCopy")
                Spacer()
                Button("复制图片并打开 X") { copyCard(openX: true) }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0, green: 0.43, blue: 0.42))
                    .accessibilityIdentifier("investmentShareOpenX")
            }
        }.padding(24).frame(width: 770)
        .onChange(of: options) { _, _ in message = nil }
    }

    @MainActor private func copyCard(openX: Bool) {
        let renderer = ImageRenderer(content: InvestmentShareCard(content: content)
            .environment(\.colorScheme, .light).frame(width: 900))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            message = "卡片未能生成，未复制或打开 X。"; return
        }
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

private struct InvestmentShareCard: View {
    let content: InvestmentShareCardContent
    private let accent = Color(red: 0, green: 0.43, blue: 0.42)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("投资手账", systemImage: "chart.line.uptrend.xyaxis").font(.headline).foregroundStyle(accent)
                Spacer(); Text("USD").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text("这一段投资，留下记录。").font(.system(size: 28, weight: .bold))
            Text(content.period).font(.callout).foregroundStyle(.secondary)
            Text("区间净盈亏").font(.headline)
            Text(content.amount).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(content.amount.hasPrefix("-") ? Color.red : accent).minimumScaleFactor(0.5).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text("时间加权收益").foregroundStyle(.secondary)
                Text(content.returnText).font(.title2.weight(.semibold)).monospacedDigit()
            }
            if !content.holdings.isEmpty {
                Text("持仓：" + content.holdings.prefix(6).joined(separator: " · ") + (content.holdings.count > 6 ? " 等 \(content.holdings.count) 项" : ""))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text(content.scope)
                Text(content.evidenceLabel).fontWeight(.semibold)
                Text(content.valuationLabel + " · " + content.versionLabel)
                Text(content.footnote)
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(36).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.black.opacity(0.08)))
            .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.16))
            .accessibilityIdentifier("investmentSharePreview")
    }
}
