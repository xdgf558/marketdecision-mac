import SwiftUI
import AppComposition

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
            }.padding(.horizontal, 28).padding(.top, 12)
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
