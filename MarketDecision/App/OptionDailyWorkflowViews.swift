import SwiftUI
import AppComposition
import PortfolioEngine

/// Presentation-only controls for the compact contract form. Parsing and
/// acceptance remain with the existing option draft and calculation engine.
struct OptionReferenceField<Content: View>: View {
    let title: String
    let hint: String?
    private let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            content
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OptionReferenceTextField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var text: String
    let unit: String?
    let hint: String?
    let accessibilityIdentifier: String?

    init(_ title: String, text: Binding<String>, unit: String? = nil,
         hint: String? = nil, accessibilityIdentifier: String? = nil) {
        self.title = title
        self._text = text
        self.unit = unit
        self.hint = hint
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        OptionReferenceField(title, hint: hint) {
            HStack(spacing: 0) {
                identifiedInput
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                if let unit {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
                    Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.025))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 36)
            .background(colorScheme == .dark ? Color.white.opacity(0.035) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.13), lineWidth: 1)
            }
        }
    }

    private var input: some View {
        TextField(title, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .accessibilityLabel(unit.map { "\(title)，\($0)" } ?? title)
    }

    @ViewBuilder private var identifiedInput: some View {
        if let accessibilityIdentifier {
            input.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            input
        }
    }
}

struct OptionReferenceInputSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(colorScheme == .dark ? Color.white.opacity(0.035) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.13), lineWidth: 1)
            }
    }
}

/// Keeps both manually entered sides of a quote visible. This control does not
/// infer a midpoint, duplicate one side, or normalize the input strings.
struct OptionReferenceQuoteField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var bid: String
    @Binding var ask: String
    let accessibilityPrefix: String

    init(_ title: String, bid: Binding<String>, ask: Binding<String>, accessibilityPrefix: String) {
        self.title = title
        self._bid = bid
        self._ask = ask
        self.accessibilityPrefix = accessibilityPrefix
    }

    var body: some View {
        OptionReferenceField(title) {
            HStack(spacing: 7) {
                Text("Bid").font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Bid", text: $bid)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .accessibilityLabel("\(title) Bid，USD 每股")
                    .accessibilityIdentifier(accessibilityPrefix + "Bid")
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18)
                    .accessibilityHidden(true)
                Text("Ask").font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Ask", text: $ask)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .accessibilityLabel("\(title) Ask，USD 每股")
                    .accessibilityIdentifier(accessibilityPrefix + "Ask")
                Text("USD / 股").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize().accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(colorScheme == .dark ? Color.white.opacity(0.035) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.13), lineWidth: 1)
            }
        }
    }
}

extension View {
    func optionReferenceInputSurface() -> some View {
        modifier(OptionReferenceInputSurface())
    }
}

struct OptionReferenceMetric: View {
    enum Tone { case standard, positive, negative }

    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let footnote: String?
    let tone: Tone
    let accessibilityIdentifier: String?

    init(title: String, value: String, footnote: String? = nil,
         tone: Tone = .standard, accessibilityIdentifier: String? = nil) {
        self.title = title
        self.value = value
        self.footnote = footnote
        self.tone = tone
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            identifiedValue
            if let footnote {
                Text(footnote)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueText: some View {
        Text(value)
            .font(.system(size: 28, weight: .semibold).monospacedDigit())
            .foregroundStyle(valueColor)
            .lineLimit(1).minimumScaleFactor(0.65)
            .help(value).textSelection(.enabled)
            .accessibilityLabel("\(title)：\(value)")
    }

    @ViewBuilder private var identifiedValue: some View {
        if let accessibilityIdentifier {
            valueText.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            valueText
        }
    }

    private var valueColor: Color {
        switch tone {
        case .standard: return .primary
        case .positive:
            return colorScheme == .dark
                ? Color(red: 0.48, green: 0.77, blue: 0.68)
                : Color(red: 0.10, green: 0.34, blue: 0.31)
        case .negative:
            return colorScheme == .dark
                ? Color(red: 0.95, green: 0.53, blue: 0.39)
                : Color(red: 0.67, green: 0.23, blue: 0.13)
        }
    }
}

struct OptionReferenceButtonStyle: ButtonStyle {
    enum Kind: Equatable { case primary, outline, subtle }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .foregroundStyle(kind == .primary ? Color.white : accent)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(kind == .outline ? accent.opacity(0.75) : .clear, lineWidth: 1.2)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.40)
    }

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.48, green: 0.77, blue: 0.68)
            : Color(red: 0.10, green: 0.34, blue: 0.31)
    }

    private var background: Color {
        switch kind {
        case .primary:
            return colorScheme == .dark
                ? Color(red: 0.17, green: 0.42, blue: 0.36)
                : Color(red: 0.10, green: 0.34, blue: 0.31)
        case .outline: return .clear
        case .subtle: return accent.opacity(colorScheme == .dark ? 0.13 : 0.065)
        }
    }
}

/// The checklist is prepared on an explicit action, not reparsed on every field
/// render. It guides editing; only the existing builder/engine accepts inputs.
struct OptionDailyChecklistView: View {
    let checklist: OptionDailyChecklist
    let select: (OptionDailySection) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if checklist.isEmpty {
                Label("常用字段已填写，可继续计算", systemImage: "checkmark.circle")
                Text("计算时仍会检查数值、时间、来源及策略约束。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("还有 \(checklist.issueCount) 项需要处理").font(.headline)
                ForEach(checklist.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { select(group.section) } label: {
                            Label(group.title, systemImage: "arrow.down.circle")
                        }.buttonStyle(.borderless)
                        ForEach(group.issues) { issue in Text(issue.message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("optionDailyChecklist")
    }
}

/// This reads one chosen, replay-checked performance report. It never calculates
/// personal history from option experiments or combines overlapping reports.
struct OptionPersonalHistoryView: View {
    @Bindable var model: OptionPersonalHistoryWorkspaceModel
    @State private var visibleSession: UUID?
    var body: some View {
        GroupBox("我的历史胜率 · 独立于本次模型概率") {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择一份已保存的盈亏报告，核对其中的卖期权经济回合。不会把模型实验、股票或买入期权算作卖期权样本。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.hasLoadedAccounts ? "刷新账户与报告" : "读取本地账户") {
                        perform { await model.loadAccounts() }
                    }.disabled(model.isBusy).accessibilityIdentifier("optionPersonalLoadAccounts")
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
                if model.hasLoadedAccounts {
                    if model.accounts.isEmpty {
                        Text("尚无本地账户。先在「我的投资」中记账并保存盈亏报告。").foregroundStyle(.secondary)
                    } else {
                        Menu(accountName) {
                            ForEach(model.accounts) { account in
                                Button(account.name) { perform { await model.selectAccount(account.id) } }
                            }
                        }.disabled(model.isBusy).accessibilityIdentifier("optionPersonalChooseAccount")
                        if model.selectedAccountID != nil {
                            reportChoices
                        }
                    }
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(model.hasError ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("optionPersonalMessage")
                }
                if let result = model.result { statistics(result) }
                Text("这是已发生交易的描述统计，不是当前合约的未来成功率。少于 30 个合资格回合时，只显示计数，不显示频率。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }
        .onAppear { visibleSession = UUID() }
        .onDisappear { visibleSession = nil }
    }
    private var accountName: String {
        model.accounts.first(where: { $0.id == model.selectedAccountID })?.name ?? "选择账户"
    }
    private var reportChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hasLoadedReports && model.summaries.isEmpty && !model.isBusy {
                Text("该账户暂无已保存的盈亏报告。到「我的投资」核算并保存后再读取。").foregroundStyle(.secondary)
            }
            ForEach(model.summaries) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("报告区间：\(item.startDate) → \(item.endDate)")
                        Text("保存于 \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.selectedReportID == item.id && model.result != nil ? "重新核对" : "查看统计") {
                        perform { await model.openSelected(item.id) }
                    }.disabled(model.isBusy).accessibilityIdentifier("optionPersonalOpenReport")
                }
            }
        }
    }
    private func statistics(_ selected: OptionPersonalHistorySelection) -> some View {
        let stats = selected.statistics
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(selected.accountName).font(.headline)
            Text("统计截止：\(selected.asOf.formatted(.iso8601))").font(.caption).foregroundStyle(.secondary)
            Text(selected.statisticsScope).font(.caption).foregroundStyle(.secondary)
            Text(selected.isCurrentLedger ? "核对时与当前账本版本一致" : "历史账本版本；不代表当前全部记录")
                .font(.caption).foregroundStyle(selected.isCurrentLedger ? Color.secondary : Color.orange)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("历史盈利回合比例").font(.caption).foregroundStyle(.secondary)
                    Text(percent(stats.winRate)).font(.title2.monospacedDigit())
                        .accessibilityIdentifier("optionPersonalWinRate")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("合资格回合").font(.caption).foregroundStyle(.secondary)
                    Text("\(stats.eligibleN)").font(.title2.monospacedDigit())
                        .accessibilityIdentifier("optionPersonalEligibleN")
                }
            }
            Text("盈利 \(stats.wins) · 亏损 \(stats.losses) · 持平 \(stats.zeros)")
                .accessibilityIdentifier("optionPersonalCounts")
            Text("仅经济闭合、费用和归属可核对的回合进入分母；持平不是亏损，指派本身不等于成功或失败。")
                .font(.caption).foregroundStyle(.secondary)
            if stats.winRate.status != .available { Text(stats.winRate.reason).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("统计口径与区间") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("纳入检查的卖期权经济回合：\(stats.displayN)；不合资格：\(stats.displayN - stats.eligibleN)。不是张数、订单数或期权组合订单胜率。")
                    Text("原报告中其他类型的经济回合未纳入：\(selected.excludedRoundCount)。")
                    Text("Wilson 95% 区间：" + interval(stats.winRateInterval))
                    Text("目的达成率：" + percent(stats.purposeSuccessRate) + "；分母只含已判定成功或失败的回合。")
                    Text("来源报告区间：\(selected.startDay) → \(selected.endDay)。统计沿用该冻结账本的经济回合，可能包含报告开始前开仓的历史。")
                    Text("来源报告：\(selected.reportID.uuidString)")
                    Text("账本版本：\(selected.ledgerRevision.uuidString)")
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard let session = visibleSession else { return }
        Task {
            guard visibleSession == session, !Task.isCancelled else { return }
            await action()
        }
    }
    private func percent(_ value: PerformanceNumber) -> String {
        guard value.status == .available, let number = value.value, number.isFinite else { return "暂不显示" }
        return String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), number * 100)
    }
    private func interval(_ value: PerformanceInterval) -> String {
        guard value.status == .available, let low = value.low, let high = value.high,
              low.isFinite, high.isFinite else { return "暂不显示" }
        return String(format: "%.2f%%～%.2f%%", locale: Locale(identifier: "en_US_POSIX"), low * 100, high * 100)
    }
}
