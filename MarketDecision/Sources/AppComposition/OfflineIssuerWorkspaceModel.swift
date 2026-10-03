import Foundation
import Observation
import CoreDomain
import FundamentalsEngine
import Persistence

public protocol OfflineIssuerWorkspaceStorage: Sendable {
    func writeRevision() async throws -> UUID
    func save(_ document: OfflineIssuerResearchDocument, expectedRevision: UUID) async throws
    func savedResearch() async throws -> [SavedOfflineIssuerResearch]
}

extension OfflineIssuerResearchStore: OfflineIssuerWorkspaceStorage {}

public enum OfflineIssuerRecomputationState: Sendable, Equatable {
    case notVerified, matched, mismatched, failed
}

/// One instance belongs to one visible research page. Storage may be shared, but publication
/// belongs to the page's current operation; leaving the page does not undo a completed write.
@MainActor @Observable public final class OfflineIssuerWorkspaceModel {
    public let issuers: [OfflineIssuerCatalog.Entry]
    public private(set) var document: OfflineIssuerResearchDocument?
    public private(set) var context: OfflineIssuerResearchContext?
    public private(set) var saved: [SavedOfflineIssuerResearch] = []
    public private(set) var savedID: String?
    public private(set) var selectedTicker: String?
    public private(set) var isBusy = false
    public private(set) var isSaved = false
    public private(set) var message: String?
    public private(set) var savedReadError: String?
    public private(set) var hasError = false
    public private(set) var recomputationState: OfflineIssuerRecomputationState = .notVerified
    public var canSave: Bool { !isBusy && document != nil && !isSaved }

    private let storage: any OfflineIssuerWorkspaceStorage
    private let catalog: OfflineIssuerCatalog
    private let now: @Sendable () -> Date
    private let generate: @Sendable (Data, Date) async throws -> OfflineIssuerResearchDocument
    private let replay: @Sendable (OfflineIssuerResearchDocument) async throws -> OfflineIssuerResearchRecomputation
    private var generation = UUID()

    public init(storage: any OfflineIssuerWorkspaceStorage, catalog: OfflineIssuerCatalog,
                now: @escaping @Sendable () -> Date = { Date() },
                generate: @escaping @Sendable (Data, Date) async throws -> OfflineIssuerResearchDocument = { bytes, date in
                    try await .make(excerptData: bytes, asOf: date, executionDate: date,
                        retention: .init(mayStore: true, mayBackup: false,
                            evidenceReference: "USER_AUTHORIZED_LOCAL_REVIEWED_EXCERPT_WORKSPACE"))
                },
                replay: @escaping @Sendable (OfflineIssuerResearchDocument) async throws -> OfflineIssuerResearchRecomputation = {
                    try await $0.recompute()
                }) {
        self.storage = storage; self.catalog = catalog; issuers = catalog.entries
        self.now = now; self.generate = generate; self.replay = replay
    }

    /// Listing validates stored bytes but does not execute financial formulas.
    public func load() async {
        let token = begin()
        defer { finish(token) }
        await readSaved(token)
    }

    public func select(_ ticker: String) async {
        let token = begin(clearDocument: true)
        selectedTicker = ticker
        defer { finish(token) }
        do {
            try Task.checkCancellation()
            let bytes = try catalog.excerpt(for: ticker)
            let result = try await generate(bytes, now())
            guard generation == token else { return }
            try Task.checkCancellation()
            try result.validate()
            guard result.ticker == ticker, result.excerptData == bytes else {
                throw OfflineIssuerResearchError.inconsistentEvidence
            }
            let evidence = try result.context()
            document = result; context = evidence
            message = "已按本地摘录计算；尚未执行独立重算核对，缺项仍保留。"
        } catch {
            guard generation == token else { return }
            hasError = true
            message = Task.isCancelled ? "摘录研究已取消，可以重新选择。" : "摘录或计算未通过校验；未显示旧结果，请重试。"
        }
    }

    /// Reread the record instead of trusting a previously displayed list. Imported numerical
    /// caches remain unverified until the user explicitly requests recomputation.
    public func open(_ id: String) async {
        let token = begin(clearDocument: true)
        defer { finish(token) }
        do {
            let list = try await storage.savedResearch()
            guard generation == token else { return }
            try Task.checkCancellation()
            guard let item = list.first(where: { $0.id == id }) else {
                throw OfflineIssuerResearchError.invalidDocument
            }
            try item.document.validate()
            let evidence = try item.document.context()
            saved = list; savedReadError = nil
            document = item.document; context = evidence; selectedTicker = item.document.ticker
            savedID = item.id; isSaved = true
            message = "已打开冻结摘录；结构校验通过，缓存数值仍待显式重算。"
        } catch {
            guard generation == token else { return }
            hasError = true
            message = "冻结摘录无法打开或已不可用；未将缓存数值标为已验证。"
        }
    }

    public func save() async {
        guard canSave, let document else { return }
        let token = begin()
        defer { finish(token) }
        do {
            // Pin before the storage layer's validation/actor hops. Never adopt a newer
            // revision after another page has changed the archive.
            let revision = try await storage.writeRevision()
            guard generation == token else { return }
            try Task.checkCancellation()
            try await storage.save(document, expectedRevision: revision)
        } catch {
            guard generation == token else { return }
            hasError = true
            message = "保存未完成，请重载记录后再试；已有冻结版本不会被覆盖。"
            return
        }
        guard generation == token else { return }
        // A completed commit is still a commit even when its caller was cancelled.
        isSaved = true
        message = "摘录研究已保存到独立本地库；不包含原始报告文件。"
        await readSaved(token, committedDocument: document.id)
    }

    public func recompute() async {
        guard !isBusy, let document else { return }
        let token = begin()
        recomputationState = .notVerified
        defer { finish(token) }
        do {
            try Task.checkCancellation()
            let result = try await replay(document)
            guard generation == token else { return }
            try Task.checkCancellation()
            if try document.cachedReportsMatch(result) {
                recomputationState = .matched
                message = "重算一致：使用冻结输入和绑定模型，未改写原缓存。"
            } else {
                recomputationState = .mismatched; hasError = true
                message = "重算与缓存不一致；原缓存保持不变，不应将它作为已验证结果。"
            }
        } catch {
            guard generation == token else { return }
            recomputationState = .failed; hasError = true
            message = Task.isCancelled ? "重算已取消；缓存仍未验证。" : "重算未完成；原缓存未修改，不能视为核对通过。"
        }
    }

    public func disappear() {
        generation = UUID(); isBusy = false
        clearDocument(); saved = []; savedReadError = nil; message = nil; hasError = false
    }

    private func begin(clearDocument shouldClear: Bool = false) -> UUID {
        generation = UUID(); isBusy = true; message = nil; hasError = false
        if shouldClear { clearDocument() }
        return generation
    }
    private func clearDocument() {
        document = nil; context = nil; selectedTicker = nil; savedID = nil; isSaved = false
        recomputationState = .notVerified
    }
    private func finish(_ token: UUID) {
        if generation == token { isBusy = false }
    }
    private func readSaved(_ token: UUID, committedDocument: UUID? = nil) async {
        do {
            let list = try await storage.savedResearch()
            guard generation == token else { return }
            try Task.checkCancellation()
            saved = list; savedReadError = nil
            if let committedDocument {
                savedID = list.first { $0.document.id == committedDocument }?.id
            }
        } catch {
            guard generation == token else { return }
            saved = []; hasError = true
            savedReadError = "保存列表读取失败，请重新载入。"
            message = committedDocument == nil ? savedReadError : "摘录已保存，但列表读取失败；请重新载入，不要重复保存。"
        }
    }
}
