import Foundation
import Observation
import DataContracts
import FundamentalsEngine
import Persistence

public enum SECResearchConfigurationError: Error { case invalidContact, networkDisabled }

/// Contact identity belongs only to this explicit request. It is never part of the saved
/// document, source metadata, error message or diagnostic log.
public struct SECContactIdentity: Sendable {
    public let email: String
    public var userAgent: String { "MarketDecision/0.1 " + email }
    public init(email: String) throws {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 160,
              clean.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}\z"#,
                          options: .regularExpression) != nil,
              !clean.contains("..") else { throw SECResearchConfigurationError.invalidContact }
        self.email = clean
    }
}

public protocol SECResearchWorkspaceStorage: Sendable {
    func savedResearch() async throws -> [SECResearchDocument]
    func open(id: UUID) async throws -> SECResearchDocument
}
extension SECResearchStore: SECResearchWorkspaceStorage {}

public typealias SECResearchImport = @Sendable (String, SECContactIdentity,
    @escaping @Sendable (SECResearchProgress) async -> Void) async throws -> SECResearchDocument

/// A page owns its task, progress and replay status. Opening a page only reads the isolated
/// local store. Neither startup, selection nor replay constructs a network session.
@MainActor @Observable public final class SECResearchWorkspaceModel {
    public private(set) var ticker = "MSFT"
    public let networkAvailable: Bool
    public private(set) var document: SECResearchDocument?
    public private(set) var saved: [SECResearchDocument] = []
    public private(set) var progress: SECResearchProgress?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var listError: String?
    public private(set) var hasError = false
    public private(set) var recomputationState: OfflineIssuerRecomputationState = .notVerified
    public var canDisplayValues: Bool { document != nil && recomputationState == .matched }
    private let storage: any SECResearchWorkspaceStorage
    private let importer: SECResearchImport
    private let replay: @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult
    private var generation = UUID()
    private var task: Task<Void, Never>?

    public init(storage: any SECResearchWorkspaceStorage, networkAvailable: Bool,
                importer: @escaping SECResearchImport,
                replay: @escaping @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult = {
                    try $0.recompute()
                }) {
        self.storage = storage; self.networkAvailable = networkAvailable
        self.importer = importer; self.replay = replay
    }

    public func chooseTicker(_ value: String) {
        guard !isBusy else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ticker != value else { return }
        generation = UUID(); ticker = value; clearDocument(); message = nil; hasError = false
    }

    public func load() async {
        guard !isBusy else { return }
        let token = begin(clear: false)
        defer { finish(token) }
        await reloadList(token)
    }

    /// Called only by the explicit import action. A busy page does not start a second task.
    @discardableResult public func startImport(email: String) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let contact: SECContactIdentity
        do {
            guard networkAvailable else { throw SECResearchConfigurationError.networkDisabled }
            contact = try SECContactIdentity(email: email)
            try EquityRecord.validateSymbol(ticker)
        } catch {
            clearDocument(); hasError = true
            message = networkAvailable ? "请输入有效的股票代码和 SEC 联系邮箱。" : "本构建尚未启用 SEC 网络权限，仍可打开本地已保存研究。"
            return nil
        }
        let token = begin(clear: true), symbol = ticker
        task = Task { [weak self, importer] in
            do {
                let result = try await importer(symbol, contact) { [weak self] value in
                    await self?.receive(value, token: token)
                }
                guard let self, self.generation == token else { return }
                try Task.checkCancellation()
                try result.validate()
                guard result.ticker == symbol else { throw ContractError.mismatchedSource }
                self.document = result; self.ticker = result.ticker
                self.message = "导入研究已保存；请显式重算核对后查看标准化数值。缺项与访问范围保留。"
                await self.reloadList(token, committed: true)
                self.finish(token)
            } catch {
                guard let self, self.generation == token else { return }
                self.hasError = !Task.isCancelled
                self.message = Task.isCancelled ? "导入已取消；已接收的源页可能保留，取消不撤销已完成的保存。"
                    : Self.failureMessage(error)
                self.finish(token)
            }
        }
        return task
    }

    public func open(_ id: UUID) async {
        guard !isBusy else { return }
        let token = begin(clear: true)
        defer { finish(token) }
        do {
            let result = try await storage.open(id: id)
            guard generation == token else { return }
            try Task.checkCancellation(); try result.validate()
            guard result.id == id else { throw ContractError.mismatchedSource }
            document = result; ticker = result.ticker
            message = "已打开冻结研究；数值缓存仍待显式重算核对。"
        } catch {
            guard generation == token else { return }
            hasError = true; message = "研究未能打开或未通过完整性检查；未显示旧结果。"
        }
    }

    public func recompute() async {
        guard !isBusy, let document else { return }
        let token = begin(clear: false)
        recomputationState = .notVerified
        defer { finish(token) }
        do {
            let result = try await replay(document)
            guard generation == token else { return }
            try Task.checkCancellation()
            if result == document.normalization {
                recomputationState = .matched; message = "冻结输入重算一致；不授予历史时点或投资分析资格。"
            } else {
                recomputationState = .mismatched; hasError = true
                message = "重算与缓存不一致，数值已隐藏；原记录未修改。"
            }
        } catch {
            guard generation == token else { return }
            recomputationState = .failed; hasError = true
            message = "重算未完成，数值保持隐藏；原记录未修改。"
        }
    }

    public func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false; progress = nil
        clearDocument(); hasError = false
        message = "操作已取消；已接收的源页或已提交的研究可能保留，可重新载入列表检查。"
    }
    public func disappear() { cancel(); message = nil; saved = []; listError = nil }
    private func receive(_ value: SECResearchProgress, token: UUID) {
        guard generation == token else { return }; progress = value
    }
    private func begin(clear: Bool) -> UUID {
        generation = UUID(); isBusy = true; progress = nil; message = nil; hasError = false
        if clear { clearDocument() }
        return generation
    }
    private func clearDocument() { document = nil; recomputationState = .notVerified }
    private func finish(_ token: UUID) { if generation == token { isBusy = false; task = nil } }
    private func reloadList(_ token: UUID, committed: Bool = false) async {
        do {
            let rows = try await storage.savedResearch()
            guard generation == token else { return }
            try Task.checkCancellation(); saved = rows; listError = nil
        } catch {
            guard generation == token else { return }
            saved = []; listError = "保存列表无法读取，请重新载入。"
            if committed { message = "研究已保存，但列表刷新失败；请重新载入，避免重复导入。" }
        }
    }
    private static func failureMessage(_ error: any Error) -> String {
        // Only closed typed categories; never render provider descriptions, request headers or URLs.
        switch error {
        case ProviderFailure.rateLimited: "SEC 暂时限流，导入未完成；请稍后手动重试，已接收的源页可能保留。"
        case ProviderFailure.symbolUnavailable: "未找到所选代码或申报文件；导入未完成。"
        default: "导入未完成；请检查访问配置或稍后重试。已接收的源页可能保留，不代表整次导入成功。"
        }
    }
}
