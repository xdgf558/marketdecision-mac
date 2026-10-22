import Foundation
import Observation
import MacroProviders
import MarketAnalytics
import Persistence

/// Editable declaration is separate from raw file bytes. Internal snapshot IDs
/// and creation time are generated for each explicit preview, not hand authored.
public struct MacroSourceManifest: Codable, Equatable, Sendable {
    public let retrievedAt: Date
    public let asOf: Date
    public let origin: MacroSourceOrigin
    public let descriptor: MacroSourceDescriptor
    public let releases: [MacroReleaseEvidence]
    public init(_ input: MacroImportInput) {
        retrievedAt = input.retrievedAt; asOf = input.asOf; origin = input.origin
        descriptor = input.descriptor; releases = input.releases
    }
    public func input(rawData: Data, id: UUID = UUID(), createdAt: Date = Date()) -> MacroImportInput {
        .init(id: id, createdAt: createdAt, retrievedAt: retrievedAt, asOf: asOf, origin: origin,
            descriptor: descriptor, rawData: rawData, releases: releases)
    }
    public func selectingLocalFile() -> Self {
        Self(.init(createdAt: Date(), retrievedAt: retrievedAt, asOf: asOf, origin: .localFile,
            descriptor: descriptor, rawData: Data(), releases: releases))
    }
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
public struct MacroSourceImportPreview: Identifiable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let report: MacroSourceReport
}

/// No transport is installed here. Preview, selection, bridge and save share one
/// page generation; SQLite CAS is still the final old-writer boundary.
@MainActor @Observable public final class MacroSourceWorkspaceModel: MarketStateTransferParticipant {
    public private(set) var preview: MacroSourceImportPreview?
    public private(set) var report: MacroSourceReport?
    public private(set) var bridge: MacroMarketBridgeReport?
    public private(set) var savedID: UUID?
    public private(set) var bridgeRevision: UUID?
    public private(set) var selectedSources: [MacroSourceReport] = []
    public private(set) var saved: [MacroSourceSummary] = []
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var listError: String?
    public private(set) var isBusy = false
    public private(set) var transferEpoch = UUID()
    private let storage: any MacroSourceStorage
    private let coordinator: MarketStateTransferCoordinator
    private let evaluate: @Sendable (MacroImportInput) async throws -> MacroSourceReport
    private let evaluateBridge: @Sendable (MacroMarketBridgeInput) async throws -> MacroMarketBridgeReport
    private var generation = UUID()
    private var operation: UUID?
    private var committing: UUID?
    private var transfer: UUID?
    private var refreshed: UUID?
    private var visible = true
    private var pendingReload = false
    public init(storage: any MacroSourceStorage, coordinator: MarketStateTransferCoordinator = MarketStateTransferCoordinator(),
                evaluate: @escaping @Sendable (MacroImportInput) async throws -> MacroSourceReport = { input in
                    try await Task.detached { try MacroSourceEngine.evaluate(input) }.value
                }, evaluateBridge: @escaping @Sendable (MacroMarketBridgeInput) async throws -> MacroMarketBridgeReport = { input in
                    try await Task.detached { try MacroMarketBridgeEngine.evaluate(input) }.value
                }) {
        self.storage = storage; self.coordinator = coordinator; self.evaluate = evaluate; self.evaluateBridge = evaluateBridge
        coordinator.register(self)
    }
    public var canEdit: Bool { committing == nil && transfer == nil && !coordinator.isTransferring }
    public var canConfirm: Bool { !isBusy && canEdit && preview != nil }
    public var canSaveBridge: Bool { !isBusy && canEdit && bridge != nil && bridgeRevision != nil && savedID == nil }
    public var canSelectSource: Bool { !isBusy && canEdit && report != nil && savedID != nil && preview == nil }
    public func load() async {
        visible = true
        if committing != nil { pendingReload = true; return }
        guard !coordinator.isTransferring, !isBusy else { return }
        let token = begin(); defer { finish(token) }; await readSaved(token)
    }
    public func draftChanged() {
        guard canEdit else { return }; generation = UUID(); operation = nil; isBusy = false
        clear(); message = nil; hasError = false
    }
    public nonisolated static func demo(_ format: MacroSourceFormat) throws -> (manifest: String, raw: String) {
        let input = try MacroSourceDemo.input(format: format)
        guard let raw = String(data: input.rawData, encoding: .utf8) else { throw MacroSourceError.malformedSource }
        return (try MacroSourceManifest(input).json(), raw)
    }
    public func prepare(manifestJSON: String, read: @escaping @Sendable () async throws -> Data) async {
        guard canEdit, !isBusy else { return }; let token = begin(); clear(); defer { finish(token) }
        do {
            guard manifestJSON.utf8.count <= Self.maximumManifestBytes else { throw MarketStateStorageError.budgetExceeded }
            let manifest = try JSONDecoder().decode(MacroSourceManifest.self, from: Data(manifestJSON.utf8))
            let baseline = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            let bytes = try await read()
            guard owns(token), !Task.isCancelled else { return }
            guard bytes.count <= Self.maximumSourceBytes else { throw MarketStateStorageError.budgetExceeded }
            let input = manifest.input(rawData: bytes), value = try await evaluate(input)
            guard owns(token), !Task.isCancelled else { return }
            guard value.input == input else { throw MarketStateStorageError.corruptedStorage }
            preview = .init(id: UUID(), revision: baseline, report: value); report = value
            message = "来源已解析并核对，尚未保存。请核对原始字节、修订和发布证据后明确确认。"
        } catch { if owns(token), !Task.isCancelled { fail("来源文件或描述未通过核对；未保存，也未沿用之前的观测值。") } }
    }
    @discardableResult public func confirm(id: UUID, expectedRevision: UUID) async -> Bool {
        guard canConfirm, let candidate = preview, candidate.id == id, candidate.revision == expectedRevision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let value = try await storage.save(candidate.report.input, expectedRevision: expectedRevision)
            guard value.replayMatched, Self.sameEvidence(value.report, candidate.report) else { throw MarketStateStorageError.corruptedStorage }
            if owns(token), !Task.isCancelled {
                report = value.report; savedID = value.id; preview = nil
                message = "来源原始字节与解析报告已冻结。相同证据复用已有记录；这不授予供应商或历史分析资格。"
                await readSaved(token)
            }
            await finishCommit(token, commit); return true
        } catch {
            if owns(token), !Task.isCancelled {
                if (error as? MarketStateStorageError) == .staleRevision { clear(); fail("市场库已变化，请重新预览；旧导入不会取得恢复后的写入资格。") }
                else { fail("保存失败，保留原预览和原版本供重试；未标记为已保存。") }
            }
            await finishCommit(token, commit); return false
        }
    }
    public func open(_ item: MacroSourceSummary) async {
        guard canEdit, !isBusy else { return }; let token = begin(); clear(); defer { finish(token) }
        do {
            let before = try await storage.revision()
            switch item.kind {
            case .source:
                let value = try await storage.open(id: item.id)
                let after = try await storage.revision()
                guard owns(token), !Task.isCancelled else { return }
                guard before == after, value.id == item.id, value.report.id == item.originalID,
                      value.inputHash == item.inputHash, value.reportHash == item.reportHash, value.replayMatched else { throw MarketStateStorageError.corruptedStorage }
                report = value.report
            case .marketBridge:
                let value = try await storage.openBridge(id: item.id)
                let after = try await storage.revision()
                guard owns(token), !Task.isCancelled else { return }
                guard before == after, value.id == item.id, value.report.input.id == item.originalID,
                      value.inputHash == item.inputHash, value.reportHash == item.reportHash, value.replayMatched else { throw MarketStateStorageError.corruptedStorage }
                bridge = value.report
            }
            savedID = item.id; message = "已核对原始字节并完整重放所选版本；没有读取当前供应商数据。"
        } catch { if owns(token), !Task.isCancelled { fail("所选版本未通过完整性或重放核对，未显示目录缓存数值。") } }
    }
    public func selectCurrentSource() {
        guard canSelectSource, let report else { return }
        guard !selectedSources.contains(where: { $0 == report }) else { return }
        guard !selectedSources.contains(where: { $0.id == report.id }) else { fail("篮子中已有相同原始身份的不同内容，请先移除旧选择，再显式选择这个版本。"); return }
        selectedSources.append(report); bridge = nil; bridgeRevision = nil
        message = "已选择这份核对通过的冻结来源。宏观发布周期序列只作独立展示，不加入三分数。"; hasError = false
    }
    public func removeSelectedSource(_ id: UUID) {
        guard canEdit, !isBusy else { return }; selectedSources.removeAll { $0.id == id }; bridge = nil; bridgeRevision = nil
    }
    public func buildMarket(base: MarketStateInput) async {
        guard canEdit, !isBusy, !selectedSources.isEmpty else { return }
        let sources = selectedSources, token = begin(); clear(); defer { finish(token) }
        do {
            let baseline = try await storage.revision()
            guard owns(token), !Task.isCancelled else { return }
            let input = MacroMarketBridgeInput(createdAt: Date(), base: base, sources: sources)
            let value = try await evaluateBridge(input)
            guard owns(token), !Task.isCancelled else { return }
            guard value.input == input else { throw MarketStateStorageError.corruptedStorage }
            bridge = value; bridgeRevision = baseline
            message = "已用显式选择的来源重算独立市场报告，尚未保存。仅替换可映射日/周序列，其他输入没有补填。"
        } catch { if owns(token), !Task.isCancelled { fail("所选来源、发布时点或基础市场输入未通过核对；未生成替代分数。") } }
    }
    @discardableResult public func saveBridge() async -> Bool {
        guard canSaveBridge, let candidate = bridge, let baseline = bridgeRevision else { return false }
        let token = begin(), commit = UUID(); committing = commit
        do {
            let value = try await storage.saveBridge(candidate.input, expectedRevision: baseline)
            guard value.replayMatched, try MacroSourceContentIdentity.hash(value.report.input) == MacroSourceContentIdentity.hash(candidate.input) else { throw MarketStateStorageError.corruptedStorage }
            if owns(token), !Task.isCancelled {
                bridge = value.report; bridgeRevision = nil; savedID = value.id
                message = "基础市场输入、完整来源原字节及新报告已一并冻结；旧市场快照未被改写。"; await readSaved(token)
            }
            await finishCommit(token, commit); return true
        } catch {
            if owns(token), !Task.isCancelled {
                if (error as? MarketStateStorageError) == .staleRevision { clear(); fail("市场库已变化，请重新计算；未将旧报告保存到新基线。") }
                else { fail("完整来源报告保存失败，保留原版本供重试。") }
            }
            await finishCommit(token, commit); return false
        }
    }
    public func cancel() { guard canEdit else { return }; draftChanged(); message = "已取消发布；已发起的文件读取或计算可能仍在收尾。" }
    public func disappear() {
        visible = false; pendingReload = false; generation = UUID(); operation = nil; clear(); selectedSources = []; saved = []
        message = nil; hasError = false; isBusy = committing != nil || transfer != nil
    }
    var marketStateTransferRefreshNeeded: Bool { transfer != nil && visible && refreshed != generation }
    func beginMarketStateTransfer(_ id: UUID) {
        transfer = id; refreshed = nil; generation = UUID(); operation = nil; clear(); selectedSources = []; saved = []; message = nil; isBusy = true; transferEpoch = UUID()
    }
    func refreshMarketStateTransfer(_ id: UUID) async {
        guard transfer == id, visible else { return }; let token = begin(); await readSaved(token)
        if owns(token) { refreshed = generation }; finish(token)
    }
    func endMarketStateTransfer(_ id: UUID) { guard transfer == id else { return }; transfer = nil; refreshed = nil; isBusy = operation != nil || committing != nil }
    private func begin() -> UUID { let token = UUID(); generation = token; operation = token; isBusy = true; message = nil; hasError = false; return token }
    private func owns(_ token: UUID) -> Bool { visible && generation == token && operation == token }
    private func finish(_ token: UUID) { guard operation == token else { return }; operation = nil; isBusy = committing != nil || transfer != nil }
    private func finishCommit(_ token: UUID, _ commit: UUID) async {
        guard committing == commit else { return }; committing = nil; finish(token)
        if operation == nil { isBusy = transfer != nil }
        if pendingReload && visible { pendingReload = false; await load() }
    }
    private func clear() { preview = nil; report = nil; bridge = nil; savedID = nil; bridgeRevision = nil }
    private func fail(_ text: String) { message = text; hasError = true }
    private func readSaved(_ token: UUID) async {
        do {
            let values = try await storage.summaries()
            guard owns(token), !Task.isCancelled else { return }
            guard Set(values.map(\.id)).count == values.count else { throw MarketStateStorageError.corruptedStorage }
            saved = values; listError = nil
        } catch { if owns(token), !Task.isCancelled { saved = []; listError = "来源目录读取失败，未沿用旧目录。" } }
    }
    // Idempotence may return an older identity/createdAt, but every semantic input
    // and every decoded field must still match the user's inspected candidate.
    private static func sameEvidence(_ lhs: MacroSourceReport, _ rhs: MacroSourceReport) -> Bool {
        let a = lhs.input, b = rhs.input
        return a.retrievedAt == b.retrievedAt && a.asOf == b.asOf && a.origin == b.origin && a.descriptor == b.descriptor
            && a.rawData == b.rawData && a.releases == b.releases && lhs.schemaVersion == rhs.schemaVersion
            && lhs.decoderVersion == rhs.decoderVersion && lhs.contentSHA256 == rhs.contentSHA256
            && lhs.observations == rhs.observations && lhs.selectedObservations == rhs.selectedObservations
            && lhs.gaps == rhs.gaps && lhs.limitations == rhs.limitations
    }
    public nonisolated static let maximumSourceBytes = MacroSourceEngine.maximumSourceBytes
    public nonisolated static let maximumManifestBytes = 8 * 1_024 * 1_024
}
