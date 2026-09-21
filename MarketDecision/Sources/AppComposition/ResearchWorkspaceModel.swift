import Foundation
import Observation
import CoreDomain
import FundamentalsEngine
import Persistence

@MainActor @Observable public final class ResearchWorkspaceModel {
    public private(set) var document: ResearchDocument?
    public private(set) var saved: [SavedResearch] = []
    public private(set) var watchlist: [WatchlistEntry] = []
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var savedID: String?
    public private(set) var selectedSymbol = "DEMO"
    private let storage: any ResearchStorage
    private let generate: @Sendable (String) async throws -> ResearchDocument
    public init(storage: any ResearchStorage, generate: @escaping @Sendable (String) async throws -> ResearchDocument = {
        try await SyntheticResearchFactory.make(symbol:$0)
    }) { self.storage = storage; self.generate = generate }

    public func load() async {
        guard !isBusy else { return }
        isBusy = true; message = nil; hasError = false
        defer { isBusy = false }
        do {
            let list = try await storage.savedResearch(), entries = try await storage.watchlist()
            try Task.checkCancellation(); saved = list; watchlist = entries
        } catch {
            saved = []; watchlist = []; hasError = true
            message = Task.isCancelled ? "读取已取消，可以重试。":"本地研究记录读取失败；未将损坏数据作为有效结果。"
        }
    }
    public func select(_ symbol: String) async {
        guard !isBusy else { return }
        isBusy = true; selectedSymbol = symbol; document = nil; savedID = nil; message = nil; hasError = false
        defer { isBusy = false }
        guard ["DEMO","GAP"].contains(symbol) else { message = "此自选标的尚无已准入数据，无法生成研究结果。"; return }
        do {
            try Task.checkCancellation()
            let result = try await generate(symbol)
            try await result.validate(); try Task.checkCancellation()
            guard result.symbol == symbol else { throw ResearchError.invalidDocument }
            document = result
        } catch {
            hasError = true; message = Task.isCancelled ? "研究载入已取消，可以重试。":"研究计算失败；未显示上一次结果，请重试。"
        }
    }
    /// Always reread verified frozen bytes; a cached list is not the authority for opening a run.
    public func open(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true; document = nil; savedID = nil; message = nil; hasError = false
        defer { isBusy = false }
        do {
            let fresh = try await storage.savedResearch()
            guard let item = fresh.first(where:{$0.id == id}) else { throw ResearchError.invalidDocument }
            try Task.checkCancellation()
            saved = fresh; document = item.document; selectedSymbol = item.document.symbol; savedID = id
            message = "已打开冻结版本；来源、输入与模型保存在本机。"
        } catch { hasError = true; message = "冻结版本无法通过完整性校验或已不可用，请重新载入。" }
    }
    public func save() async {
        guard !isBusy, savedID == nil, let document else { return }
        isBusy = true; message = nil; hasError = false
        defer { isBusy = false }
        do { try await storage.save(document) }
        catch { hasError = true; message = "保存未完成，请重载记录后再试；不会覆盖已有版本。"; return }
        // Do not claim cancellation rolled back a completed SQLite commit.
        savedID = document.id.uuidString + "/" + document.id.uuidString.lowercased() + "/v1"
        message = "研究快照已保存；此版本不可覆盖。"
        do { saved = try await storage.savedResearch() }
        catch { hasError = true; message = "快照已保存，但列表读取失败；请重新载入。" }
    }
    public func recompute() async {
        guard !isBusy, let document else { return }
        isBusy = true; message = nil; hasError = false
        defer { isBusy = false }
        do {
            try await document.validate(); try Task.checkCancellation()
            message = "复算一致：使用保存的输入与绑定模型，未改写快照。"
        } catch { hasError = true; message = "复算校验未通过；快照未被修改。" }
    }
    public func updateWatchlist(symbol: String, target: String, maximum: String, riskNote: String) async {
        guard !isBusy else { return }
        isBusy = true; message = nil; hasError = false
        defer { isBusy = false }
        do {
            func amount(_ text: String) throws -> Money? {
                let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
                return clean.isEmpty ? nil : try Money(clean)
            }
            let cleanSymbol = symbol.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
            let entry = try WatchlistEntry(symbol:cleanSymbol,targetPrice:amount(target),maximumAssignmentPrice:amount(maximum),riskNote:riskNote)
            try await storage.setWatchlist(entry,expectedRevision:watchlist.first(where:{$0.symbol == cleanSymbol})?.revision)
            watchlist = try await storage.watchlist(); message = "自选已保存；用户目标不代表估值建议或交易指令。"
        } catch { hasError = true; message = "自选未更新或尚未确认结果。价格须为正数；若其他窗口已修改，请重载后再试。" }
    }
    public func remove(_ entry: WatchlistEntry) async {
        guard !isBusy else { return }
        isBusy = true; message = nil; hasError = false
        defer { isBusy = false }
        do {
            try await storage.removeWatchlist(symbol:entry.symbol,expectedRevision:entry.revision)
            watchlist = try await storage.watchlist(); message = "已移出自选；保存的研究快照仍保留。"
        } catch { hasError = true; message = "移出自选未完成，请重载后再试。" }
    }
}
