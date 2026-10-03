import Foundation
import Testing
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private let workspaceDate = Date(timeIntervalSince1970: 1_800_000_000)
private enum OfflineWorkspaceFailure: Error { case injected }

/// Explicit arrival/release handshake; no delay or timeout can silently release work.
private actor OfflineWorkspaceGate {
    private var arrived = false, released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }; arrivalWaiters = []
        if !released { await withCheckedContinuation { blocked = $0 } }
    }
    func waitUntilEntered() async {
        if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}

private actor OfflineWorkspaceDocuments {
    static let shared = OfflineWorkspaceDocuments()
    private var tasks: [String: Task<OfflineIssuerResearchDocument, any Error>] = [:]
    func get(_ ticker: String = "MSFT") async throws -> OfflineIssuerResearchDocument {
        if let task = tasks[ticker] { return try await task.value }
        let task = Task {
            let bytes = try OfflineIssuerCatalog.bundled().excerpt(for: ticker)
            return try await OfflineIssuerResearchDocument.make(excerptData: bytes, asOf: workspaceDate,
                executionDate: workspaceDate, retention: .init(mayStore: true, mayBackup: false,
                    evidenceReference: "USER_AUTHORIZED_LOCAL_REVIEWED_EXCERPT_WORKSPACE"))
        }
        tasks[ticker] = task
        return try await task.value
    }
}

private actor OfflineWorkspaceReplayControl {
    private var calls = 0
    let gate = OfflineWorkspaceGate()
    func run(_ document: OfflineIssuerResearchDocument) async throws -> OfflineIssuerResearchRecomputation {
        calls += 1
        if calls > 1 { await gate.hold(); throw OfflineWorkspaceFailure.injected }
        return try await document.recompute()
    }
}

private actor OfflineWorkspaceStore: OfflineIssuerWorkspaceStorage {
    var revision = UUID()
    var records: [SavedOfflineIssuerResearch]
    var reads = 0, writes = 0, revisionReads = 0
    var failingReads = false, failingWrites = false
    var readGate: OfflineWorkspaceGate?, saveGate: OfflineWorkspaceGate?
    var capturedRevision: UUID?
    init(records: [SavedOfflineIssuerResearch] = []) { self.records = records }
    func writeRevision() -> UUID { revisionReads += 1; return revision }
    func savedResearch() async throws -> [SavedOfflineIssuerResearch] {
        reads += 1
        let result = records, fail = failingReads, gate = readGate
        readGate = nil
        if let gate { await gate.hold() }
        if fail { throw OfflineWorkspaceFailure.injected }
        return result
    }
    func save(_ document: OfflineIssuerResearchDocument, expectedRevision: UUID) async throws {
        writes += 1; capturedRevision = expectedRevision
        if let saveGate { await saveGate.hold() }
        guard expectedRevision == revision else { throw SnapshotError.stalePlan }
        if failingWrites { throw OfflineWorkspaceFailure.injected }
        records.append(.init(address: .init(namespace: document.id,
            identity: .init(id: document.id.uuidString.lowercased(), version: "offline-issuer.v1")), document: document))
        revision = UUID()
    }
    func configure(readGate: OfflineWorkspaceGate? = nil, saveGate: OfflineWorkspaceGate? = nil,
                   failingReads: Bool = false, failingWrites: Bool = false) {
        self.readGate = readGate; self.saveGate = saveGate
        self.failingReads = failingReads; self.failingWrites = failingWrites
    }
    func replace(_ list: [SavedOfflineIssuerResearch]) { records = list; revision = UUID() }
}

private func offlineWorkspaceRecord(_ document: OfflineIssuerResearchDocument) -> SavedOfflineIssuerResearch {
    .init(address: .init(namespace: document.id,
        identity: .init(id: document.id.uuidString.lowercased(), version: "offline-issuer.v1")), document: document)
}

@MainActor private func offlineWorkspace(_ store: any OfflineIssuerWorkspaceStorage,
    generate: (@Sendable (Data, Date) async throws -> OfflineIssuerResearchDocument)? = nil,
    replay: (@Sendable (OfflineIssuerResearchDocument) async throws -> OfflineIssuerResearchRecomputation)? = nil
) throws -> OfflineIssuerWorkspaceModel {
    let generation: @Sendable (Data, Date) async throws -> OfflineIssuerResearchDocument
    if let generate { generation = generate }
    else {
        generation = { @Sendable bytes, _ in
            try await OfflineWorkspaceDocuments.shared.get(OfflineIssuerResearchContext.decode(excerptData: bytes).ticker)
        }
    }
    let replaying: @Sendable (OfflineIssuerResearchDocument) async throws -> OfflineIssuerResearchRecomputation
    if let replay { replaying = replay }
    else { replaying = { @Sendable document in try await document.recompute() } }
    return try .init(storage: store, catalog: .bundled(), now: { workspaceDate }, generate: generation, replay: replaying)
}

@Suite @MainActor struct OfflineIssuerWorkspaceTests {
    @Test func initializationAndListingNeverComputeOrVerifyCachedNumbers() async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get(), record = offlineWorkspaceRecord(document)
        let store = OfflineWorkspaceStore(records: [record])
        let model = try offlineWorkspace(store, generate: { _, _ in throw OfflineWorkspaceFailure.injected },
                                         replay: { _ in throw OfflineWorkspaceFailure.injected })
        #expect(model.issuers.count == 10 && model.document == nil && model.context == nil)
        #expect(model.selectionTicker == "MSFT" && !model.canDisplayReports)
        #expect(await store.reads == 0)
        #expect(await store.revisionReads == 0)
        #expect(await store.writes == 0)
        await model.load()
        #expect(model.saved.count == 1 && model.document == nil && !model.hasError)
        await model.open(record.id)
        #expect(model.document?.id == document.id && model.savedID == record.id && model.isSaved)
        #expect(model.recomputationState == .notVerified && !model.canSave)
        #expect(!model.canDisplayReports)
        await model.recompute()
        #expect(model.recomputationState == .failed && model.hasError)
        #expect(!model.canDisplayReports)
    }

    @Test func selectionAndExplicitReplayKeepLimitsAndOriginalCache() async throws {
        let store = OfflineWorkspaceStore(), model = try offlineWorkspace(store)
        await model.select("MSFT")
        let document = try #require(model.document)
        let before = try ResearchDocument.encoded(document)
        #expect(model.selectedTicker == "MSFT" && model.context?.ticker == "MSFT")
        #expect(!model.isSaved && model.canSave && model.recomputationState == .notVerified)
        #expect(!model.canDisplayReports)
        #expect(!document.retention.mayBackup && document.retention.mayStore)
        #expect(!document.providerAdmitted && !document.historicalPITQualified && !document.capitalInputsAllowed)
        #expect(document.baseReport.metrics["marketCap"]?.value == nil)
        await model.recompute()
        #expect(model.recomputationState == .matched && !model.hasError)
        #expect(model.canDisplayReports)
        #expect(try ResearchDocument.encoded(model.document) == ResearchDocument.encoded(Optional(document)))
        #expect(try ResearchDocument.encoded(document) == before)
        #expect(model.document?.cacheState == "requires-explicit-recompute")
        #expect(await store.writes == 0)
    }

    @Test func unknownSelectionClearsPreviousOutputAndCanRecover() async throws {
        let model = try offlineWorkspace(OfflineWorkspaceStore())
        await model.select("MSFT")
        await model.select("NOT-REVIEWED")
        #expect(model.document == nil && model.context == nil && model.hasError && !model.canSave)
        #expect(model.recomputationState == .notVerified)
        #expect(!model.canDisplayReports)
        await model.select("MSFT")
        #expect(model.document?.ticker == "MSFT" && !model.hasError && !model.isBusy)
    }

    @Test func lateSelectionCannotReplaceNewSelectionOrClearNewBusyState() async throws {
        let first = try await OfflineWorkspaceDocuments.shared.get("MSFT")
        let second = try await OfflineWorkspaceDocuments.shared.get("AAPL")
        let oldGate = OfflineWorkspaceGate(), newGate = OfflineWorkspaceGate()
        let model = try offlineWorkspace(OfflineWorkspaceStore(), generate: { bytes, _ in
            let ticker = try OfflineIssuerResearchContext.decode(excerptData: bytes).ticker
            if ticker == "MSFT" { await oldGate.hold(); return first }
            await newGate.hold(); return second
        })
        let old = Task { await model.select("MSFT") }
        await oldGate.waitUntilEntered()
        let new = Task { await model.select("AAPL") }
        await newGate.waitUntilEntered()
        await oldGate.release(); await old.value
        #expect(model.isBusy && model.selectedTicker == "AAPL" && model.document == nil)
        await newGate.release(); await new.value
        #expect(model.document?.id == second.id && !model.isBusy && !model.hasError)
        #expect(model.selectionTicker == "AAPL" && !model.canDisplayReports)
    }

    @Test func lateOpenAfterLeavingCannotPublishIntoReenteredPage() async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get(), record = offlineWorkspaceRecord(document)
        let store = OfflineWorkspaceStore(records: [record]), gate = OfflineWorkspaceGate()
        let model = try offlineWorkspace(store)
        await store.configure(readGate: gate)
        let old = Task { await model.open(record.id) }
        await gate.waitUntilEntered()
        model.disappear()
        await store.replace([])
        await model.load()
        await gate.release(); await old.value
        #expect(model.document == nil && model.context == nil && model.savedID == nil && model.saved.isEmpty)
        #expect(!model.isBusy && !model.hasError && model.recomputationState == .notVerified)
        #expect(!model.canDisplayReports)
    }

    @Test func lateListFailureCannotClearNewSessionRecordsOrPublishError() async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get(), record = offlineWorkspaceRecord(document)
        let store = OfflineWorkspaceStore(records: [record]), gate = OfflineWorkspaceGate()
        let model = try offlineWorkspace(store)
        await store.configure(readGate: gate, failingReads: true)
        let old = Task { await model.load() }
        await gate.waitUntilEntered()
        model.disappear()
        await store.configure()
        await model.load()
        await gate.release(); await old.value
        #expect(model.saved.map(\.id) == [record.id] && model.savedReadError == nil)
        #expect(!model.hasError && !model.isBusy && model.message == nil)
    }

    @Test func lateReplayCannotVerifyADifferentDocumentOrReopenedSession() async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get(), result = try await document.recompute()
        let gate = OfflineWorkspaceGate()
        let model = try offlineWorkspace(OfflineWorkspaceStore(), replay: { _ in await gate.hold(); return result })
        await model.select("MSFT")
        let old = Task { await model.recompute() }
        await gate.waitUntilEntered()
        model.disappear()
        await model.select("MSFT")
        await gate.release(); await old.value
        #expect(model.document?.id == document.id && model.recomputationState == .notVerified)
        #expect(!model.canDisplayReports)
        #expect(!model.isBusy && !model.hasError)
    }

    @Test func cacheMismatchIsDifferentFromFailureAndNeverOverwritesStoredCache() async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get()
        var json = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(document)) as? [String: Any])
        var report = try #require(json["baseReport"] as? [String: Any])
        var metrics = try #require(report["metrics"] as? [String: Any])
        var revenue = try #require(metrics["revenue"] as? [String: Any])
        revenue["value"] = "1"; metrics["revenue"] = revenue; report["metrics"] = metrics; json["baseReport"] = report
        let damaged = try JSONDecoder().decode(OfflineIssuerResearchDocument.self,
            from: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        let record = offlineWorkspaceRecord(damaged), store = OfflineWorkspaceStore(records: [record])
        let model = try offlineWorkspace(store)
        await model.open(record.id)
        #expect(!model.hasError && model.recomputationState == .notVerified)
        #expect(!model.canDisplayReports)
        await model.recompute()
        #expect(model.recomputationState == .mismatched && model.hasError)
        #expect(!model.canDisplayReports)
        #expect(model.document?.baseReport.metrics["revenue"]?.value == (try Money("1")))
        #expect(await store.writes == 0)
        #expect(try await store.savedResearch().first?.document.baseReport.metrics["revenue"]?.value == Money("1"))
    }

    @Test func savePinsRevisionBeforeSuspensionAndNeverRebasesAfterConcurrentWrite() async throws {
        let store = OfflineWorkspaceStore(), gate = OfflineWorkspaceGate(), model = try offlineWorkspace(store)
        await model.select("MSFT")
        let originalRevision = await store.revision
        await store.configure(saveGate: gate)
        let saving = Task { await model.save() }
        await gate.waitUntilEntered()
        await store.replace([])
        await gate.release(); await saving.value
        #expect(await store.capturedRevision == originalRevision)
        #expect(await store.revisionReads == 1)
        #expect(await store.records.isEmpty)
        #expect(model.hasError && !model.isSaved && model.canSave)
        await store.configure()
        await model.save()
        #expect(model.isSaved && !model.hasError && !model.canSave)
    }

    @Test func leavingDuringSaveDoesNotReportRollbackOrPublishCompletionInNewSession() async throws {
        let store = OfflineWorkspaceStore(), gate = OfflineWorkspaceGate(), model = try offlineWorkspace(store)
        await model.select("MSFT")
        await store.configure(saveGate: gate)
        let saving = Task { await model.save() }
        await gate.waitUntilEntered()
        model.disappear()
        await model.load()
        await gate.release(); await saving.value
        #expect(model.document == nil && model.savedID == nil && model.message == nil && !model.isSaved)
        #expect(await store.records.count == 1)
        await model.load()
        #expect(model.saved.count == 1 && !model.hasError)
    }

    @Test func committedSaveAndFailedListRefreshRemainDistinctAndPreventDuplicateSave() async throws {
        let store = OfflineWorkspaceStore(), model = try offlineWorkspace(store)
        await model.select("MSFT")
        await store.configure(failingReads: true)
        await model.save()
        #expect(model.isSaved && model.savedID == nil && !model.canSave && model.hasError)
        #expect(model.message?.contains("已保存") == true && model.savedReadError != nil)
        await model.save()
        #expect(await store.writes == 1)
        await store.configure()
        await model.load()
        #expect(model.saved.count == 1 && !model.hasError && model.savedReadError == nil && model.isSaved)
    }

    @Test func realIndependentStoreReopensAndExplicitlyRecomputesWithoutGeneratingAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("offline-issuer-research.sqlite").path
        let first = try offlineWorkspace(OfflineIssuerResearchStore(path: path))
        await first.select("MSFT"); await first.save()
        let record = try #require(first.saved.first)
        #expect(first.isSaved && !first.hasError && first.savedID == record.id)
        first.disappear()
        let next = try offlineWorkspace(OfflineIssuerResearchStore(path: path),
            generate: { _, _ in throw OfflineWorkspaceFailure.injected })
        await next.load(); await next.open(record.id)
        #expect(next.isSaved && next.recomputationState == .notVerified && !next.hasError)
        await next.recompute()
        #expect(next.recomputationState == .matched && !next.hasError)
        #expect(next.document?.excerptData == record.document.excerptData)
        #expect(next.document?.cacheState == "requires-explicit-recompute")
        #expect(throws: MigrationError.incompatiblePurpose) { _ = try DatabaseStore(path: path) }
    }

    @Test func currentClockCannotBeSilentlyRaisedToExcerptRetrievalDate() async throws {
        let model = try OfflineIssuerWorkspaceModel(storage: OfflineWorkspaceStore(), catalog: .bundled(),
            now: { Date(timeIntervalSince1970: 0) })
        await model.select("MSFT")
        #expect(model.document == nil && model.context == nil && model.hasError && !model.canSave)
    }

    @Test func pickerSelectionAndOpenedRecordShareOneAuthority() async throws {
        let apple = try await OfflineWorkspaceDocuments.shared.get("AAPL"), record = offlineWorkspaceRecord(apple)
        let model = try offlineWorkspace(OfflineWorkspaceStore(records: [record]))
        await model.select("MSFT"); await model.recompute()
        #expect(model.canDisplayReports && model.selectionTicker == "MSFT")
        #expect(model.choose("AAPL"))
        #expect(model.selectionTicker == "AAPL" && model.document == nil && model.context == nil)
        #expect(model.selectedTicker == nil && !model.canDisplayReports && !model.isSaved)
        #expect(model.recomputationState == .notVerified)
        await model.select(model.selectionTicker)
        #expect(model.document?.ticker == "AAPL" && model.selectionTicker == "AAPL" && !model.canDisplayReports)
        #expect(model.choose("MSFT"))
        await model.open(record.id)
        #expect(model.selectionTicker == "AAPL" && model.selectedTicker == "AAPL" && model.savedID == record.id)
        #expect(!model.choose("NOT-REVIEWED"))
        #expect(model.selectionTicker == "AAPL" && model.document?.id == apple.id && !model.canDisplayReports)
        model.disappear()
        #expect(!model.canDisplayReports && model.document == nil && model.recomputationState == .notVerified)
    }

    @Test(arguments: ["generate", "open", "replay"])
    func pickerChangesAreRejectedWhileBusy(operation: String) async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get("AAPL"), record = offlineWorkspaceRecord(document)
        let result = try await document.recompute(), gate = OfflineWorkspaceGate()
        let store = OfflineWorkspaceStore(records: [record])
        let model = try offlineWorkspace(store, generate: { _, _ in
            if operation == "generate" { await gate.hold() }
            return document
        }, replay: { _ in await gate.hold(); return result })
        if operation == "replay" { await model.select("AAPL") }
        if operation == "open" { await store.configure(readGate: gate) }
        let task = Task {
            switch operation {
            case "generate": await model.select("AAPL")
            case "open": await model.open(record.id)
            default: await model.recompute()
            }
        }
        await gate.waitUntilEntered()
        let fixedSelection = model.selectionTicker
        #expect(model.isBusy && !model.canDisplayReports)
        #expect(!model.choose("NVDA") && model.selectionTicker == fixedSelection)
        await gate.release(); await task.value
        #expect(model.selectionTicker == "AAPL" && model.document?.ticker == "AAPL" && !model.isBusy)
        #expect(model.canDisplayReports == (operation == "replay"))
    }

    @Test func lateOpenCannotResetPickerAfterANewerGeneration() async throws {
        let oldDocument = try await OfflineWorkspaceDocuments.shared.get(), record = offlineWorkspaceRecord(oldDocument)
        let store = OfflineWorkspaceStore(records: [record]), gate = OfflineWorkspaceGate()
        let model = try offlineWorkspace(store)
        await store.configure(readGate: gate)
        let old = Task { await model.open(record.id) }
        await gate.waitUntilEntered()
        await model.select("AAPL")
        #expect(model.selectionTicker == "AAPL" && model.document?.ticker == "AAPL")
        await gate.release(); await old.value
        #expect(model.selectionTicker == "AAPL" && model.selectedTicker == "AAPL")
        #expect(model.document?.ticker == "AAPL" && model.savedID == nil && !model.canDisplayReports)
    }

    @Test func savedRowIdentifiersIncludeImmutableVersionAndConflictNamespace() async throws {
        let document = try await OfflineWorkspaceDocuments.shared.get(), first = offlineWorkspaceRecord(document)
        let conflict = SavedOfflineIssuerResearch(address: .init(namespace: UUID(), identity: first.address.identity),
            document: document)
        let newer = SavedOfflineIssuerResearch(address: .init(namespace: first.address.namespace,
            identity: .init(id: first.address.identity.id, version: "another-version")), document: document)
        let ids = [first, conflict, newer].map(OfflineIssuerWorkspaceModel.savedRowIdentifier)
        #expect(Set(ids).count == 3)
        #expect(ids[0] == OfflineIssuerWorkspaceModel.savedRowIdentifier(first))
        #expect(ids.allSatisfy { $0.hasPrefix("openOfflineIssuer-") })
        let model = try offlineWorkspace(OfflineWorkspaceStore(records: [first, conflict]))
        await model.open(conflict.id)
        #expect(model.savedID == conflict.id && model.savedID != first.id)
        #expect(model.selectionTicker == "MSFT" && !model.canDisplayReports)
    }

    @Test func repeatingReplayWithdrawsPreviousDisplayPermissionBeforeWaitingAndOnFailure() async throws {
        let replay = OfflineWorkspaceReplayControl()
        let model = try offlineWorkspace(OfflineWorkspaceStore(), replay: { try await replay.run($0) })
        await model.select("MSFT"); await model.recompute()
        #expect(model.canDisplayReports && model.recomputationState == .matched)
        let pending = Task { await model.recompute() }
        await replay.gate.waitUntilEntered()
        #expect(model.isBusy && !model.canDisplayReports && model.recomputationState == .notVerified)
        await replay.gate.release(); await pending.value
        #expect(!model.isBusy && !model.canDisplayReports && model.recomputationState == .failed)
        #expect(model.document?.ticker == "MSFT" && model.context?.ticker == "MSFT")
    }
}
