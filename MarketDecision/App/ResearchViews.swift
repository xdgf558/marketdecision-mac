import SwiftUI
import AppComposition
import CoreDomain
import DataContracts
import FundamentalsEngine
import Persistence

struct ResearchContent: View {
    @Bindable var model: ResearchWorkspaceModel
    @State private var tab = "概览"
    @State private var query = ""
    @State private var metricKey = "fcf"
    @State private var editingWatchlist = false
    @State private var symbolDraft = "DEMO"
    @State private var targetDraft = ""
    @State private var maximumDraft = ""
    @State private var riskDraft = ""
    @State private var removeEntry: WatchlistEntry?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("公司研究").font(.system(size:32,weight:.bold))
                    Text("本地研究 · 合成演示").foregroundStyle(.secondary)
                }
                Spacer()
                Button("载入示例") { Task { await model.select("DEMO") } }.accessibilityIdentifier("researchDemo")
                Button("缺失示例") { Task { await model.select("GAP") } }.accessibilityIdentifier("researchGap")
            }
            Label("合成数据，不代表真实公司、当前行情或投资建议。",systemImage:"info.circle.fill")
                .font(.callout).padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color.blue.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
            Picker("研究内容",selection:$tab) {
                ForEach(["概览","原始数据","自选","快照"],id:\.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("researchTabs")
            if model.isBusy { ProgressView("正在处理本地研究…").controlSize(.small) }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("researchMessage")
            }
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if tab == "自选" { watchlist }
                    else if tab == "快照" { snapshots }
                    else if let document = model.document {
                        if tab == "原始数据" { inspector(document) } else { overview(document) }
                    } else {
                        ContentUnavailableView("暂无研究数据",systemImage:"doc.text.magnifyingglass",
                            description:Text("载入合成示例或打开已保存快照。真实数据接入尚未开放。"))
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,20)
            }
        }
        .padding(24).disabled(model.isBusy)
        .task { await model.load(); if model.document == nil && !model.hasError { await model.select("DEMO") } }
        .sheet(isPresented:$editingWatchlist) { watchlistEditor }
        .confirmationDialog("移出自选并删除此标的的用户目标？",isPresented:Binding(get:{removeEntry != nil},set:{if !$0 {removeEntry = nil}}),titleVisibility:.visible) {
            if let entry = removeEntry { Button("移出自选",role:.destructive) { Task { await model.remove(entry) }; removeEntry = nil } }
            Button("取消",role:.cancel) { removeEntry = nil }
        } message: { Text("保存的研究快照不会删除。") }
    }
    private func overview(_ doc: ResearchDocument) -> some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text("\(doc.symbol) · \(doc.name)").font(.title2.bold()).accessibilityIdentifier("researchCompany")
                    Text("财务期末 \(doc.report.periodEnd.iso8601)  ·  价格日 \(doc.report.priceDay.iso8601)").font(.callout).foregroundStyle(.secondary)
                    Text(model.savedID == nil ? "未保存的演示计算":"冻结版本 · 离线可读").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.savedID == nil ? "保存研究快照":"已冻结") { Task { await model.save() } }
                    .disabled(model.savedID != nil).accessibilityIdentifier("researchSave")
            }
            HStack {
                Text("基本面总分").font(.headline)
                Text(number(doc.score.total)).font(.title.bold()).monospacedDigit().accessibilityIdentifier("researchScore")
                Text("/ 100").foregroundStyle(.secondary)
                Spacer()
                Text("覆盖权重 \(doc.score.coveredWeightOf84) / 84").font(.callout)
            }
            Text("分数是未校准的规则结果；覆盖程度不是胜率。缺失分项保留为空。").font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:220),alignment:.leading)],alignment:.leading,spacing:10) {
                ForEach(doc.score.dimensions.keys.sorted(),id:\.self) { key in
                    VStack(alignment:.leading,spacing:6) {
                        HStack { Text(dimensionTitle(key)).font(.headline); Spacer(); Text(number(doc.score.dimensions[key]?.value)).monospacedDigit() }
                        if let dimension = doc.score.dimensions[key] {
                            ForEach(dimension.leaves.keys.sorted(),id:\.self) { leaf in
                                HStack { Text(leaf).lineLimit(1); Spacer(); Text(metric(dimension.leaves[leaf])).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                }
            }
            GroupBox("财报卡片 · TTM") {
                VStack(spacing:8) {
                    ForEach(["revenue","dilutedEPSQuarterSum","operatingIncome","fcf","revenueYoY","epsYoY","fcfYoY","sharesYoY"],id:\.self) { key in
                        HStack { Button(metricTitle(key)) { inspectMetric(key) }.buttonStyle(.link); Spacer(); Text(metric(doc.report.metrics[key])).monospacedDigit().textSelection(.enabled) }
                    }
                    Divider()
                    Text("管理层指引、财报前后价格变化：无数据。事件 IV 与隐含波动待 Phase 3 接入。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity).padding(8)
            }
            GroupBox("估值与资本结构") {
                VStack(spacing:8) {
                    ForEach(["marketCap","enterpriseValue","peMarketCap","peEPS","priceFCF","fcfYield","evEBITDA","roic","debt"],id:\.self) { key in
                        HStack { Button(metricTitle(key)) { inspectMetric(key) }.buttonStyle(.link); Spacer(); Text(metric(doc.report.metrics[key])).monospacedDigit() }
                    }
                    Divider()
                    Text("历史估值区间不可用：当前样本没有合格历史序列，不能输出价位或区间位置。")
                        .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("researchHistoryMissing")
                }.frame(maxWidth:.infinity).padding(8)
            }
            HStack {
                Button("检查原始数据") { tab = "原始数据" }.accessibilityIdentifier("researchInspect")
                Button("加入／编辑自选") { edit(doc.symbol) }.accessibilityIdentifier("researchWatch")
                Button("按保存输入复算") { Task { await model.recompute() } }.accessibilityIdentifier("researchReplay")
            }
        }
    }
    private func inspector(_ doc: ResearchDocument) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text("输入与来源检查器").font(.title2.bold())
            Text("以下为生成的示例原文与映射，不是 SEC 原始文件。字段可展开核对原值、单位、期间、修订与可得时点。")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("指标口径") {
                VStack(alignment:.leading,spacing:8) {
                    Picker("指标",selection:$metricKey) {
                        ForEach(["revenue","dilutedEPSQuarterSum","operatingIncome","fcf","marketCap","enterpriseValue","peMarketCap","peEPS","priceFCF","fcfYield","evEBITDA","roic","debt"],id:\.self) { Text(metricTitle($0)).tag($0) }
                    }
                    Text(metricFormula(metricKey)).font(.callout)
                    Text("当前值：" + metric(doc.report.metrics[metricKey])).font(.callout).monospacedDigit()
                    if let flags = doc.report.metrics[metricKey]?.flags, !flags.isEmpty { Text("口径标记：" + flags.joined(separator:", ")).font(.caption) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            DisclosureGroup("绑定的计算上下文、版本与窗口") {
                VStack(alignment:.leading,spacing:6) {
                    Text("财务截止：\(doc.report.asOf.iso8601)")
                    Text("执行时间：\(doc.report.executionAt.iso8601)")
                    Text("模型：\(doc.model.version) · \(doc.model.reference.contentHash)")
                    Text("参数：\(doc.parameters.version) · \(doc.parameters.reference.contentHash)")
                    Text("字典：\(doc.report.dictionaryVersion)")
                    Text("来源 SHA-256：\(doc.rawHash)")
                    Text("模型规则：\(doc.model.formula)")
                    Text("评分：七维等权；维内叶子等权。各维至少 70% 覆盖；总分至少五维且总覆盖 70%。")
                    Text("季度窗口：" + doc.report.inputSnapshot.input.quarters.map { $0.start.iso8601 + "…" + $0.end.iso8601 }.joined(separator:"、"))
                    Text("税率年度：" + doc.report.inputSnapshot.input.fiscalYears.map { String($0.end.year) }.joined(separator:"、"))
                    Text("金融企业分类：" + (doc.report.inputSnapshot.input.financialCompany ? "是":"否"))
                    Text("拆股依据：" + (doc.report.inputSnapshot.input.splitBasisEvidence ?? "缺失"))
                    Text("价格／股数来源：合成 demo-close；不具备行情分析资格。")
                    Text("价格／股数原文：" + (String(data:doc.capitalData,encoding:.utf8) ?? "不可用"))
                }.font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            TextField("筛选字段，如 revenue、cash、eps",text:$query).textFieldStyle(.roundedBorder).accessibilityIdentifier("researchFieldFilter")
            LazyVStack(alignment:.leading,spacing:8) {
                ForEach(doc.report.normalizedInputs.filter { query.isEmpty || $0.fieldID.localizedCaseInsensitiveContains(query) },id:\.id) { fact in
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:5) {
                            Text("标准值：\(fact.value.decimalString) \(fact.unit) · 原文：\(fact.sourceValue ?? "由源事实推导")")
                            Text("期间：\(fact.periodStart?.iso8601 ?? "时点") → \(fact.periodEnd.iso8601) · \(fact.periodType.rawValue)")
                            Text("推导：\(fact.derivation.rawValue) · 置信度：\(fact.confidence.rawValue)")
                            Text("可得时间：\((try? MillisecondInstant(rounding:fact.availableAt).iso8601) ?? "不可用")")
                            Text("来源事实：" + fact.sourceFactIDs.joined(separator:", "))
                            Text("版本：" + fact.sourceVersions.joined(separator:", "))
                            Text("示例 accession：" + fact.accessionNumbers.joined(separator:", "))
                            Text("限制：" + (fact.limitations.isEmpty ? "合成示例，不授予资格":fact.limitations.joined(separator:", ")))
                            ForEach(doc.report.inputSnapshot.input.normalization.selectedSourceFacts.filter { fact.sourceFactIDs.contains($0.factID) },id:\.recordID) { source in
                                Text("\(source.taxonomy):\(source.concept) = \(source.sourceValue) \(source.unit)")
                            }
                        }.font(.caption).textSelection(.enabled).padding(.vertical,6)
                    } label: {
                        HStack { Text(fact.fieldID); Spacer(); Text(fact.periodEnd.iso8601); Text(fact.value.decimalString).monospacedDigit() }.font(.callout)
                    }
                }
            }
            DisclosureGroup("完整合成来源 JSON（只读）") {
                TextEditor(text:.constant(String(data:doc.rawData,encoding:.utf8) ?? "无法解码"))
                    .font(.system(.caption,design:.monospaced)).frame(height:220).accessibilityIdentifier("researchRawJSON")
            }
        }
    }
    private var snapshots: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("已保存研究").font(.title2.bold()); Spacer(); Button("重新载入") { Task { await model.load() } } }
            Text("每次保存创建不可变版本。打开时验证冻结字节、来源与模型，并核对复算结果。").font(.callout).foregroundStyle(.secondary)
            if model.saved.isEmpty { Text("尚无快照。在概览中保存一份研究。").foregroundStyle(.secondary) }
            ForEach(model.saved) { item in
                HStack {
                    VStack(alignment:.leading,spacing:4) { Text("\(item.document.symbol) · 合成研究").font(.headline); Text(item.document.report.executionAt.iso8601).font(.caption); Text(item.document.id.uuidString).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("打开冻结版本") { Task { await model.open(item.id); tab = "概览" } }.accessibilityIdentifier("researchOpenSaved")
                }.padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            }
        }
    }
    private var watchlist: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("自选与用户目标").font(.title2.bold()); Spacer(); Button("添加自选") { edit("") }.accessibilityIdentifier("researchAddWatch") }
            Text("价格目标以 USD 记录；风险备注是用户约束，不会自动交易或产生系统风险限额。真实行情、收益、事件、持仓、期权和提醒尚未接入。").font(.callout).foregroundStyle(.secondary)
            if model.watchlist.isEmpty { Text("暂无自选。可添加代码，或从演示研究加入。").foregroundStyle(.secondary) }
            ForEach(model.watchlist) { entry in
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(entry.symbol).font(.headline); Spacer(); Text(["DEMO","GAP"].contains(entry.symbol) ? "合成演示":"无已准入数据").font(.caption).foregroundStyle(.secondary) }
                    Text("目标价：\(number(entry.targetPrice)) USD · 最高接股价：\(number(entry.maximumAssignmentPrice)) USD").font(.callout)
                    if !entry.riskNote.isEmpty { Text(entry.riskNote).font(.callout).textSelection(.enabled) }
                    HStack {
                        Button("查看研究") { Task { await model.select(entry.symbol); tab = "概览" } }
                        Button("编辑目标") { edit(entry.symbol) }
                        Button("移出…",role:.destructive) { removeEntry = entry }
                    }
                }.padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            }
        }
    }
    private func edit(_ symbol: String) {
        let entry = model.watchlist.first { $0.symbol == symbol }
        symbolDraft = symbol; targetDraft = entry?.targetPrice?.decimalString ?? ""; maximumDraft = entry?.maximumAssignmentPrice?.decimalString ?? ""
        riskDraft = entry?.riskNote ?? ""; editingWatchlist = true
    }
    private var watchlistEditor: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("自选与用户目标").font(.title2.bold())
            Form {
                TextField("股票代码",text:$symbolDraft).accessibilityIdentifier("watchSymbol")
                TextField("目标价格（USD，可留空）",text:$targetDraft).accessibilityIdentifier("watchTarget")
                TextField("最高接股价（USD，可留空）",text:$maximumDraft)
                TextField("风险备注（最多 500 字）",text:$riskDraft,axis:.vertical).lineLimit(3...5)
            }
            Text("记录个人目标，不会连接交易账户或发出交易指令。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { editingWatchlist = false }.keyboardShortcut(.cancelAction)
                Button("保存自选") { Task { await model.updateWatchlist(symbol:symbolDraft,target:targetDraft,maximum:maximumDraft,riskNote:riskDraft); if !model.hasError { editingWatchlist = false } } }
                    .disabled(model.isBusy || symbolDraft.trimmingCharacters(in:.whitespaces).isEmpty).accessibilityIdentifier("watchSave")
            }
            if model.hasError, let message = model.message { Text(message).foregroundStyle(.red).font(.callout) }
        }.padding(24).frame(width:500)
    }
    private func number(_ value: Money?) -> String { guard let value else { return "—" }; return (try? value.fixedString(at:.accounting)) ?? value.decimalString }
    private func metric(_ value: FundamentalMetric?) -> String {
        guard let value else { return "缺少输入" }
        if let number = value.value { return number.decimalString }
        switch value.unavailable {
        case .missingClass: return "股类数据不完整"
        case .missingPrice: return "缺少价格"
        case .insufficientHistory: return "历史不足"
        case .nonpositiveDenominator: return "分母非正"
        case .notApplicable: return "不适用"
        case .notComparable: return "口径不可比"
        case .missingEvidence: return "缺少证据"
        default: return "缺少输入"
        }
    }
    private func inspectMetric(_ key: String) { metricKey = key; query = ""; tab = "原始数据" }
    private func metricFormula(_ key: String) -> String {
        switch key {
        case "revenue", "operatingIncome": return "相同口径最近四个连续季度求和；缺季度不补零。"
        case "dilutedEPSQuarterSum": return "同一拆股口径的四季度摊薄 EPS 求和；不是全年加权股数法 EPS。"
        case "fcf": return "标准 FCF = 经营现金流 − 资本支出；不在这里扣除 SBC。"
        case "marketCap": return "各股份类别的实际流通股数 × 对应类别价格后求和；类别必须齐全。"
        case "enterpriseValue": return "市值 + 含租赁债务 + 优先股 + 非控股权益 − 现金；默认不减短期投资。"
        case "peMarketCap": return "完整市值 ÷ 普通股可分配净利；分母须为正。"
        case "peEPS": return "同类股价格 ÷ 四季度 EPS 之和；须有拆股口径依据。"
        case "priceFCF": return "完整市值 ÷ 标准 FCF；FCF 须为正。"
        case "fcfYield": return "标准 FCF ÷ 完整市值；保留现金流的正负号。"
        case "evEBITDA": return "企业价值 ÷ EBITDA；默认包含经营租赁，EBITDA 不是 EBITDAR。"
        case "roic": return "调整后的税后经营利润 ÷ 五个季度末投入资本平均值；金融企业不适用，任一点资本非正不输出。"
        case "debt": return "短借款、当期及长期债务、融资租赁和经营租赁按互斥口径求和。"
        default: return "按绑定模型计算；同比要求同口径可比期间及有效分母。"
        }
    }
    private func dimensionTitle(_ key: String) -> String {
        ["growth":"成长","profitability":"盈利","balanceSheet":"资产负债","cashFlowQuality":"现金流质量","capitalAllocation":"资本配置","valuation":"估值","earningsStability":"盈利稳定性"][key] ?? key
    }
    private func metricTitle(_ key: String) -> String {
        ["revenue":"TTM 收入（USD）","dilutedEPSQuarterSum":"季度 EPS 之和（USD/股）","operatingIncome":"TTM 营业利润（USD）","fcf":"TTM 自由现金流（USD）",
         "revenueYoY":"收入同比（比值）","epsYoY":"EPS 同比（比值）","fcfYoY":"FCF 同比（比值）","sharesYoY":"股数同比（比值）",
         "marketCap":"完整股类市值（USD）","enterpriseValue":"企业价值（USD）","peMarketCap":"市值 / 普通股净利（倍）","peEPS":"价格 / EPS（倍）",
         "priceFCF":"市值 / FCF（倍）","fcfYield":"FCF 收益率（比值）","evEBITDA":"EV / EBITDA（倍）","roic":"ROIC（比值）","debt":"含租赁债务（USD）"][key] ?? key
    }
}
