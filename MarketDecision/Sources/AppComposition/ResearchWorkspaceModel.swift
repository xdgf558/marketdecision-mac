import Foundation
import Observation
import CoreDomain
import FundamentalsEngine
import Persistence

/// Text is editable; the compare-and-swap baseline belongs to when the editor opened.
/// A new draft always expects absence, even if the shared list later gains that symbol.
public struct WatchlistDraft: Sendable, Equatable {
    public let original: WatchlistEntry?
    public var symbol: String
    public var target: String
    public var maximum: String
    public var riskNote: String
    public init(entry: WatchlistEntry? = nil, symbol: String = "") {
        original = entry; self.symbol = entry?.symbol ?? symbol
        target = entry?.targetPrice?.decimalString ?? ""
        maximum = entry?.maximumAssignmentPrice?.decimalString ?? ""
        riskNote = entry?.riskNote ?? ""
    }
}

@MainActor @Observable public final class ResearchWorkspaceModel {
    public private(set) var document: ResearchDocument?
    public private(set) var saved: [SavedResearch] = []
    public private(set) var watchlist: [WatchlistEntry] = []
    public private(set) var savedReadError: String?
    public private(set) var watchlistReadError: String?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var savedID: String?
    public private(set) var selectedSymbol = "DEMO"
    public let transfer: ResearchTransferModel?
    private var generation = UUID()
    private let storage: any ResearchStorage
    private let generate: @Sendable (String) async throws -> ResearchDocument
    public init(storage: any ResearchStorage, transfer: ResearchTransferModel? = nil, generate: @escaping @Sendable (String) async throws -> ResearchDocument = {
        try await SyntheticResearchFactory.make(symbol:$0)
    }) {
        self.storage = storage; self.transfer = transfer; self.generate = generate
        transfer?.commitWillBegin = { [weak self] in self?.invalidateForTransfer() }
        transfer?.commitDidFinish = { [weak self] in await self?.reloadAfterTransfer() }
    }

    // A new generation owns publication and busy state. Old tasks may finish, but
    // cannot republish data, errors or clear the newer operation's busy flag.
    private func invalidateForTransfer() {
        generation = UUID(); isBusy = true
        document = nil; savedID = nil; saved = []; watchlist = []
        savedReadError = nil; watchlistReadError = nil; message = nil; hasError = false
    }
    public func reloadAfterTransfer() async {
        invalidateForTransfer()
        isBusy = false
        await load()
    }

    public func load() async {
        guard !isBusy else { return }
        let token = generation
        isBusy = true; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        await readSavedList(token:token)
        guard generation == token else { return }
        // Failure of either store does not suppress the other independent query.
        await readWatchlist(token:token)
        guard generation == token else { return }
        hasError = savedReadError != nil || watchlistReadError != nil
        if hasError { message = "部分记录读取失败；请查看对应区域并重新载入。" }
    }
    private func readSavedList(token: UUID) async {
        do {
            let list = try await storage.savedResearch()
            guard generation == token else { return }
            try Task.checkCancellation(); saved = list; savedReadError = nil
        } catch {
            guard generation == token else { return }
            saved = []
            savedReadError = "快照列表读取失败；未显示未验证的快照，请重新载入。"
        }
    }
    private func readWatchlist(token: UUID, keepCommittedChanges: Bool = false) async {
        do {
            let entries = try await storage.watchlist()
            guard generation == token else { return }
            try Task.checkCancellation(); watchlist = entries; watchlistReadError = nil
        } catch {
            guard generation == token else { return }
            if !keepCommittedChanges { watchlist = [] }
            watchlistReadError = keepCommittedChanges
                ? "自选列表刷新失败；显示本机已确认的修改及旧记录，不代表完整最新列表。请重新载入。"
                : "自选列表读取失败；未显示未验证的自选，请重新载入。"
        }
    }
    public func select(_ symbol: String) async {
        guard !isBusy else { return }
        let token = generation
        isBusy = true; selectedSymbol = symbol; document = nil; savedID = nil; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        guard ["DEMO","GAP"].contains(symbol) else { message = "此自选标的尚无已准入数据，无法生成研究结果。"; return }
        do {
            try Task.checkCancellation()
            let result = try await generate(symbol)
            guard generation == token else { return }
            try await result.validate(); try Task.checkCancellation()
            guard generation == token else { return }
            guard result.symbol == symbol else { throw ResearchError.invalidDocument }
            document = result
        } catch {
            guard generation == token else { return }
            hasError = true; message = Task.isCancelled ? "研究载入已取消，可以重试。":"研究计算失败；未显示上一次结果，请重试。"
        }
    }
    /// Always reread verified frozen bytes; a cached list is not the authority for opening a run.
    public func open(_ id: String) async {
        guard !isBusy else { return }
        let token = generation
        isBusy = true; document = nil; savedID = nil; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        do {
            let fresh = try await storage.savedResearch()
            guard generation == token else { return }
            guard let item = fresh.first(where:{$0.id == id}) else { throw ResearchError.invalidDocument }
            try Task.checkCancellation()
            saved = fresh; savedReadError = nil; document = item.document; selectedSymbol = item.document.symbol; savedID = id
            message = "已打开冻结版本；来源、输入与模型保存在本机。"
        } catch { guard generation == token else { return }; hasError = true; message = "冻结版本无法通过完整性校验或已不可用，请重新载入。" }
    }
    public func save() async {
        guard !isBusy, savedID == nil, let document else { return }
        let token = generation
        isBusy = true; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        do { try await storage.save(document) }
        catch { guard generation == token else { return }; hasError = true; message = "保存未完成，请重载记录后再试；不会覆盖已有版本。"; return }
        guard generation == token else { return }
        // Do not claim cancellation rolled back a completed SQLite commit.
        savedID = document.id.uuidString + "/" + document.id.uuidString.lowercased() + "/v1"
        message = "研究快照已保存；此版本不可覆盖。"
        await readSavedList(token:token)
        guard generation == token else { return }
        if savedReadError != nil { hasError = true; message = "快照已保存，但列表读取失败；请重新载入。" }
    }
    public func recompute() async {
        guard !isBusy, let document else { return }
        let token = generation
        isBusy = true; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        do {
            try await document.validate(); try Task.checkCancellation()
            guard generation == token else { return }
            message = "复算一致：使用保存的输入与绑定模型，未改写快照。"
        } catch { guard generation == token else { return }; hasError = true; message = "复算校验未通过；快照未被修改。" }
    }
    /// Returns whether storage committed, separately from the subsequent refresh.
    /// Failure leaves the caller's value-type draft unchanged; no automatic rebase.
    @discardableResult public func updateWatchlist(_ draft: WatchlistDraft) async -> Bool {
        guard !isBusy else { return false }
        let token = generation
        isBusy = true; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        let entry: WatchlistEntry
        do {
            func amount(_ text: String) throws -> Money? {
                let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
                return clean.isEmpty ? nil : try Money(clean)
            }
            let symbol = draft.symbol.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
            // Editing cannot silently turn into a rename or a different-symbol overwrite.
            guard draft.original.map({ $0.symbol == symbol }) ?? true else { throw ResearchError.invalidDocument }
            entry = try WatchlistEntry(symbol:symbol,targetPrice:amount(draft.target),maximumAssignmentPrice:amount(draft.maximum),riskNote:draft.riskNote)
            try await storage.setWatchlist(entry,expectedRevision:draft.original?.revision)
        } catch ResearchError.staleWatchlist {
            guard generation == token else { return false }
            hasError = true; message = "自选已被其他窗口修改或创建；草稿已保留。请取消后重新载入并打开最新记录，再确认修改。"
            return false
        } catch {
            guard generation == token else { return false }
            hasError = true; message = "自选未更新；草稿已保留。价格须为正数；请检查输入或重新载入。"
            return false
        }
        guard generation == token else { return true } // A committed write is still a success.
        watchlist.removeAll { $0.symbol == entry.symbol }; watchlist.append(entry)
        watchlist.sort { $0.symbol < $1.symbol }
        await readWatchlist(token:token,keepCommittedChanges:true)
        guard generation == token else { return true }
        hasError = watchlistReadError != nil
        message = hasError ? "自选已保存，但列表刷新失败；请重新载入。":"自选已保存；用户目标不代表估值建议或交易指令。"
        return true
    }
    public func remove(_ entry: WatchlistEntry) async {
        guard !isBusy else { return }
        let token = generation
        isBusy = true; message = nil; hasError = false
        defer { if generation == token { isBusy = false } }
        do { try await storage.removeWatchlist(symbol:entry.symbol,expectedRevision:entry.revision) }
        catch { guard generation == token else { return }; hasError = true; message = "移出自选未完成，请重载后再试。"; return }
        guard generation == token else { return }
        watchlist.removeAll { $0.symbol == entry.symbol }
        await readWatchlist(token:token,keepCommittedChanges:true)
        guard generation == token else { return }
        hasError = watchlistReadError != nil
        message = hasError ? "已移出自选，但列表刷新失败；请重新载入。":"已移出自选；保存的研究快照仍保留。"
    }
}
