import Foundation
import Testing
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private enum SECWorkspaceFailure: Error { case injected }

/// The producer remains blocked until the test releases it, including after task cancellation.
/// This models providers/storage that deliver a late response despite their caller cancelling.
private actor SECWorkspaceGate {
    private var arrived = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true
        waiters.forEach { $0.resume() }; waiters = []
        if !released { await withCheckedContinuation { blocked = $0 } }
    }
    func waitUntilEntered() async {
        if !arrived { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}

private actor SECWorkspaceDocumentCache {
    static let shared = SECWorkspaceDocumentCache()
    private var value: Task<SECResearchDocument, any Error>?
    func document() async throws -> SECResearchDocument {
        if let value { return try await value.value }
        let next = Task { try await secResearchFixtureDocument() }
        value = next
        return try await next.value
    }
}

private final class SECWorkspaceDescriptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func describe() -> String {
        lock.lock(); reads += 1; lock.unlock()
        return "Bearer synthetic-secret https://example.invalid/private researcher@example.invalid"
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}

private struct SECWorkspaceSensitiveFailure: LocalizedError {
    let probe: SECWorkspaceDescriptionProbe
    var errorDescription: String? { probe.describe() }
}

private actor SECWorkspaceStorage: SECResearchWorkspaceStorage {
    var records: [SECResearchDocument]
    var listReads = 0, openReads = 0
    private var listFails = false
    private var listGate: SECWorkspaceGate?
    private var openGate: SECWorkspaceGate?
    init(records: [SECResearchDocument] = []) { self.records = records }
    func savedResearch() async throws -> [SECResearchDocument] {
        listReads += 1
        let result = records, failing = listFails, gate = listGate
        listGate = nil
        if let gate { await gate.hold() }
        if failing { throw SECWorkspaceFailure.injected }
        return result
    }
    func open(id: UUID) async throws -> SECResearchDocument {
        openReads += 1
        let result = records.first { $0.id == id }, gate = openGate
        openGate = nil
        if let gate { await gate.hold() }
        guard let result else { throw SnapshotError.missingReference }
        return result
    }
    func configure(listFails: Bool = false, listGate: SECWorkspaceGate? = nil,
                   openGate: SECWorkspaceGate? = nil) {
        self.listFails = listFails; self.listGate = listGate; self.openGate = openGate
    }
}

private enum SECWorkspaceImportOutcome: Sendable {
    case document(SECResearchDocument), sensitiveFailure, rateLimited
}

private struct SECWorkspaceImportAction: Sendable {
    let gate: SECWorkspaceGate?
    let outcome: SECWorkspaceImportOutcome
    init(_ outcome: SECWorkspaceImportOutcome, gate: SECWorkspaceGate? = nil) {
        self.outcome = outcome; self.gate = gate
    }
}

private actor SECWorkspaceImporter {
    private var actions: [SECWorkspaceImportAction]
    var calls = 0
    var requestedSymbols: [String] = []
    let descriptionProbe = SECWorkspaceDescriptionProbe()
    init(_ actions: [SECWorkspaceImportAction] = []) { self.actions = actions }
    func run(_ symbol: String, _ contact: SECContactIdentity,
             _ progress: @escaping @Sendable (SECResearchProgress) async -> Void) async throws -> SECResearchDocument {
        calls += 1; requestedSymbols.append(symbol)
        #expect(contact.email == "researcher@example.invalid")
        guard !actions.isEmpty else { throw SECWorkspaceFailure.injected }
        let action = actions.removeFirst()
        await progress(.init(stage: .identity, acceptedPages: calls, acceptedRecords: 0))
        if let gate = action.gate { await gate.hold() }
        await progress(.init(stage: .saving, acceptedPages: 9, acceptedRecords: 10))
        switch action.outcome {
        case let .document(document): return document
        case .sensitiveFailure: throw SECWorkspaceSensitiveFailure(probe: descriptionProbe)
        case .rateLimited: throw ProviderFailure.rateLimited
        }
    }
}

@MainActor private func secWorkspace(_ storage: any SECResearchWorkspaceStorage,
    importer: SECWorkspaceImporter = .init(), network: Bool = true,
    replay: (@Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult)? = nil
) -> SECResearchWorkspaceModel {
    let replaying: @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult
    if let replay { replaying = replay }
    else { replaying = { @Sendable document in try document.recompute() } }
    return .init(storage: storage, networkAvailable: network,
        importer: { symbol, contact, progress in try await importer.run(symbol, contact, progress) }, replay: replaying)
}

@Suite @MainActor struct SECResearchWorkspaceTests {
    @Test func initializationAndPageListingNeverImportOrVerifyNumbers() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document()
        let storage = SECWorkspaceStorage(records: [document]), importer = SECWorkspaceImporter()
        let model = secWorkspace(storage, importer: importer,
            replay: { _ in throw SECWorkspaceFailure.injected })
        #expect(await storage.listReads == 0)
        #expect(await storage.openReads == 0)
        #expect(await importer.calls == 0)
        #expect(model.document == nil && !model.isBusy && !model.canDisplayValues)
        await model.load()
        #expect(model.saved.map(\.id) == [document.id])
        #expect(model.document == nil && model.progress == nil && !model.canDisplayValues)
        #expect(await importer.calls == 0)
        #expect(await storage.openReads == 0)
    }

    @Test func disabledNetworkAndInvalidContactNeverCallImporter() async throws {
        let importer = SECWorkspaceImporter(), storage = SECWorkspaceStorage()
        let disabled = secWorkspace(storage, importer: importer, network: false)
        #expect(disabled.startImport(email: "researcher@example.invalid") == nil)
        #expect(disabled.hasError && !disabled.isBusy)
        #expect(disabled.message?.contains("researcher@example.invalid") == false)
        let enabled = secWorkspace(storage, importer: importer)
        for invalid in ["", "researcher", "researcher@example.invalid\r\nAuthorization: Bearer synthetic", "a..b@example.invalid"] {
            #expect(enabled.startImport(email: invalid) == nil)
            #expect(enabled.hasError && !enabled.isBusy && enabled.document == nil)
            #expect(enabled.message == "请输入有效的股票代码和 SEC 联系邮箱。")
        }
        enabled.chooseTicker("BAD SYMBOL")
        #expect(enabled.startImport(email: "researcher@example.invalid") == nil)
        #expect(await importer.calls == 0)
        #expect(await storage.listReads == 0)
    }

    @Test func busyPageRejectsSecondImportAndTickerChanges() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document(), gate = SECWorkspaceGate()
        let importer = SECWorkspaceImporter([.init(.document(document), gate: gate)])
        let model = secWorkspace(SECWorkspaceStorage(records: [document]), importer: importer)
        model.chooseTicker(document.ticker)
        let first = try #require(model.startImport(email: "researcher@example.invalid"))
        await gate.waitUntilEntered()
        #expect(model.isBusy && model.progress?.stage == .identity)
        #expect(model.startImport(email: "researcher@example.invalid") == nil)
        model.chooseTicker("MSFT")
        #expect(model.ticker == document.ticker)
        #expect(await importer.calls == 1)
        await gate.release(); await first.value
        #expect(!model.isBusy && !model.hasError && model.document?.id == document.id)
        #expect(model.saved.map(\.id) == [document.id])
        #expect(!model.canDisplayValues && model.recomputationState == .notVerified)
    }

    @Test func cancelDiscardsLateImportSuccessAndProgress() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document(), gate = SECWorkspaceGate()
        let importer = SECWorkspaceImporter([.init(.document(document), gate: gate)])
        let model = secWorkspace(SECWorkspaceStorage(), importer: importer)
        model.chooseTicker(document.ticker)
        let pending = try #require(model.startImport(email: "researcher@example.invalid"))
        await gate.waitUntilEntered()
        model.cancel()
        let cancellation = model.message
        await gate.release(); await pending.value
        #expect(model.document == nil && model.saved.isEmpty && model.progress == nil)
        #expect(model.message == cancellation && !model.hasError && !model.isBusy)
        #expect(!model.canDisplayValues)
    }

    @Test func disappearDiscardsLateImportFailureAndProgress() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document(), gate = SECWorkspaceGate()
        let importer = SECWorkspaceImporter([.init(.sensitiveFailure, gate: gate)])
        let model = secWorkspace(SECWorkspaceStorage(records: [document]), importer: importer)
        let pending = try #require(model.startImport(email: "researcher@example.invalid"))
        await gate.waitUntilEntered()
        model.disappear()
        await model.load()
        await gate.release(); await pending.value
        #expect(model.saved.map(\.id) == [document.id])
        #expect(model.document == nil && model.progress == nil && model.message == nil)
        #expect(!model.hasError && !model.isBusy)
        #expect(importer.descriptionProbe.count() == 0)
    }

    @Test func cancelledOldImportCannotEndOrOverwriteNewImport() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document()
        let oldGate = SECWorkspaceGate(), newGate = SECWorkspaceGate()
        let importer = SECWorkspaceImporter([.init(.sensitiveFailure, gate: oldGate),
            .init(.document(document), gate: newGate)])
        let model = secWorkspace(SECWorkspaceStorage(records: [document]), importer: importer)
        model.chooseTicker(document.ticker)
        let old = try #require(model.startImport(email: "researcher@example.invalid"))
        await oldGate.waitUntilEntered()
        model.cancel()
        let current = try #require(model.startImport(email: "researcher@example.invalid"))
        await newGate.waitUntilEntered()
        let newProgress = model.progress
        await oldGate.release(); await old.value
        #expect(model.isBusy && model.progress == newProgress)
        #expect(model.message == nil && model.document == nil && !model.hasError)
        await newGate.release(); await current.value
        #expect(!model.isBusy && !model.hasError && model.document?.id == document.id)
        #expect(await importer.calls == 2)
    }

    @Test func providerFailureDoesNotRenderOrInspectSensitiveDescriptions() async throws {
        let importer = SECWorkspaceImporter([.init(.sensitiveFailure)])
        let model = secWorkspace(SECWorkspaceStorage(), importer: importer)
        let pending = try #require(model.startImport(email: "researcher@example.invalid"))
        await pending.value
        #expect(model.hasError && !model.isBusy && model.document == nil)
        #expect(model.message == "导入未完成；请检查访问配置或稍后重试。已接收的源页可能保留，不代表整次导入成功。")
        #expect(importer.descriptionProbe.count() == 0)
    }

    @Test func rateLimitIsVisibleAsFailureWithoutAutomaticRetry() async throws {
        let importer = SECWorkspaceImporter([.init(.rateLimited)])
        let model = secWorkspace(SECWorkspaceStorage(), importer: importer)
        let pending = try #require(model.startImport(email: "researcher@example.invalid"))
        await pending.value
        #expect(model.hasError && !model.isBusy && model.document == nil)
        #expect(model.message?.contains("限流") == true)
        #expect(await importer.calls == 1)
    }

    @Test func openingRequiresExplicitReplayAndReopeningClearsVerification() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document()
        let original = try ResearchDocument.encoded(document)
        let importer = SECWorkspaceImporter()
        let model = secWorkspace(SECWorkspaceStorage(records: [document]), importer: importer)
        await model.open(document.id)
        #expect(model.document?.id == document.id && model.ticker == document.ticker)
        #expect(!model.canDisplayValues && model.recomputationState == .notVerified)
        await model.recompute()
        #expect(model.canDisplayValues && model.recomputationState == .matched)
        #expect(model.document?.mayRunValuation == false)
        #expect(try ResearchDocument.encoded(try #require(model.document)) == original)
        await model.open(document.id)
        #expect(!model.canDisplayValues && model.recomputationState == .notVerified)
        #expect(await importer.calls == 0)
    }

    @Test func mismatchedOrFailedReplayKeepsCachedNumbersHiddenAndUnchanged() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document()
        let original = try ResearchDocument.encoded(document)
        let mismatched = try FinancialNormalizer.normalizeComplete([], dictionary: .fundamentalsCompletionV1(),
            asOf: document.cutoff.addingTimeInterval(1))
        let mismatch = secWorkspace(SECWorkspaceStorage(records: [document]), replay: { _ in mismatched })
        await mismatch.open(document.id); await mismatch.recompute()
        #expect(mismatch.recomputationState == .mismatched && mismatch.hasError && !mismatch.canDisplayValues)
        #expect(try ResearchDocument.encoded(try #require(mismatch.document)) == original)
        let failed = secWorkspace(SECWorkspaceStorage(records: [document]),
            replay: { _ in throw SECWorkspaceFailure.injected })
        await failed.open(document.id); await failed.recompute()
        #expect(failed.recomputationState == .failed && failed.hasError && !failed.canDisplayValues)
        #expect(try ResearchDocument.encoded(try #require(failed.document)) == original)
    }

    @Test func choosingDifferentTickerClearsDocumentAndVerifiedStateWithoutImport() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document(), importer = SECWorkspaceImporter()
        let model = secWorkspace(SECWorkspaceStorage(records: [document]), importer: importer)
        await model.open(document.id); await model.recompute()
        #expect(model.canDisplayValues)
        model.chooseTicker(" msft ")
        #expect(model.ticker == "MSFT" && model.document == nil && !model.canDisplayValues)
        #expect(model.recomputationState == .notVerified && model.message == nil && !model.hasError)
        #expect(await importer.calls == 0)
    }

    @Test func committedImportSurvivesListRefreshFailureWithoutClaimingSaveFailure() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document()
        let storage = SECWorkspaceStorage(records: [document])
        await storage.configure(listFails: true)
        let importer = SECWorkspaceImporter([.init(.document(document))])
        let model = secWorkspace(storage, importer: importer)
        model.chooseTicker(document.ticker)
        let pending = try #require(model.startImport(email: "researcher@example.invalid"))
        await pending.value
        #expect(model.document?.id == document.id && !model.hasError && !model.isBusy)
        #expect(model.listError != nil && model.saved.isEmpty && !model.canDisplayValues)
        #expect(model.message == "研究已保存，但列表刷新失败；请重新载入，避免重复导入。")
        await storage.configure()
        await model.load()
        #expect(model.saved.map(\.id) == [document.id] && model.listError == nil)
        #expect(await importer.calls == 1)
    }

    @Test func oldOpenCannotPublishIntoReenteredPage() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document(), gate = SECWorkspaceGate()
        let storage = SECWorkspaceStorage(records: [document]), model = secWorkspace(storage)
        await storage.configure(openGate: gate)
        let old = Task { await model.open(document.id) }
        await gate.waitUntilEntered()
        model.disappear()
        await model.load()
        await gate.release(); await old.value
        #expect(model.document == nil && !model.canDisplayValues && model.message == nil)
        #expect(model.saved.map(\.id) == [document.id] && !model.isBusy && !model.hasError)
    }

    @Test func oldListFailureCannotEraseNewSessionList() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document(), gate = SECWorkspaceGate()
        let storage = SECWorkspaceStorage(records: [document]), model = secWorkspace(storage)
        await storage.configure(listFails: true, listGate: gate)
        let old = Task { await model.load() }
        await gate.waitUntilEntered()
        model.disappear()
        await storage.configure()
        await model.load()
        await gate.release(); await old.value
        #expect(model.saved.map(\.id) == [document.id] && model.listError == nil)
        #expect(!model.isBusy && !model.hasError && model.message == nil)
    }

    @Test func oldReplayCannotVerifyOrReleaseNewImportBusyState() async throws {
        let document = try await SECWorkspaceDocumentCache.shared.document()
        let replayGate = SECWorkspaceGate(), importGate = SECWorkspaceGate()
        let importer = SECWorkspaceImporter([.init(.document(document), gate: importGate)])
        let model = secWorkspace(SECWorkspaceStorage(records: [document]), importer: importer,
            replay: { value in await replayGate.hold(); return try value.recompute() })
        await model.open(document.id)
        let old = Task { await model.recompute() }
        await replayGate.waitUntilEntered()
        #expect(!model.canDisplayValues)
        model.cancel()
        let current = try #require(model.startImport(email: "researcher@example.invalid"))
        await importGate.waitUntilEntered()
        await replayGate.release(); await old.value
        #expect(model.isBusy && model.document == nil && !model.canDisplayValues)
        #expect(model.recomputationState == .notVerified && !model.hasError)
        await importGate.release(); await current.value
        #expect(!model.isBusy && model.document?.id == document.id && !model.canDisplayValues)
    }
}
