import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private let researchDate = Date(timeIntervalSince1970:1_800_000_000)
private func demo(_ symbol: String = "DEMO") async throws -> ResearchDocument {
    try await SyntheticResearchFactory.make(symbol:symbol,executionDate:researchDate)
}
@Suite struct ResearchWorkflowTests {
    @Test func generatedEvidenceNormalizesAndReplaysWithoutOriginalInput() async throws {
        let bytes = try await ResearchDocument.encoded(demo())
        let decoded = try JSONDecoder().decode(ResearchDocument.self,from:bytes)
        try await decoded.validate()
        #expect(decoded.report.metrics["revenue"]?.value == (try Money("400000000")))
        #expect(decoded.report.metrics["fcf"]?.value == (try Money("40000000")))
        #expect(decoded.report.normalizedInputs.allSatisfy { !$0.sourceFactIDs.isEmpty })
        #expect(decoded.report.inputSnapshot.input.normalization.selectedSourceFacts.allSatisfy { $0.provenance.origin == .derived })
        #expect(decoded.score.valuation.metrics.values.allSatisfy { $0.prices.isEmpty && $0.position == nil })
    }
    @Test func missingDemoDoesNotBecomeZeroOrBorrowCompleteCompanyPrices() async throws {
        let doc = try await demo("GAP"); try await doc.validate()
        #expect(doc.report.metrics["fcf"]?.value == nil)
        #expect(doc.report.metrics["marketCap"]?.unavailable == .missingClass)
        #expect(doc.report.metrics["peEPS"]?.value == nil)
        #expect(doc.score.valuation.metrics.values.allSatisfy { $0.prices.isEmpty })
    }
}

@Suite struct ResearchPersistenceTests {
    @Test func reopenReadsFrozenSourceBytesAndRecomputesOffline() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("research-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath:path) }
        let original = try await demo()
        do {
            let db = try DatabaseStore(path:path), business = try BusinessDataStore(database:db)
            let store = ResearchStore(database:db,snapshots:business)
            try await store.save(original)
            _ = try await business.purgeCache(seriesIDs:["demo"],expectedRevision:business.revision())
            #expect(try await business.counts().sourceDocuments == 0)
            #expect(try await business.counts().snapshotObjects == 6)
        }
        let db = try DatabaseStore(path:path), business = try BusinessDataStore(database:db)
        let reopened = try await ResearchStore(database:db,snapshots:business).savedResearch()
        #expect(reopened.count == 1)
        let saved = try #require(reopened.first)
        #expect(saved.document.rawData == original.rawData)
        #expect(saved.document.capitalData == original.capitalData)
        #expect(try ResearchDocument.encoded(saved.document) == ResearchDocument.encoded(original))
        #expect(try await ResearchDocument.encoded(saved.document.recompute()) == ResearchDocument.encoded(original.score))
    }
    @Test func duplicateSaveCannotOverwriteImmutableResearch() async throws {
        let db = try DatabaseStore(path:":memory:"), business = try BusinessDataStore(database:db)
        let store = ResearchStore(database:db,snapshots:business), doc = try await demo()
        try await store.save(doc)
        let revision = await business.revision()
        await #expect(throws:SnapshotError.duplicateObject) { try await store.save(doc) }
        #expect(await business.revision() == revision)
        #expect(try await store.savedResearch().count == 1)
    }
    @Test func sqliteFailureRollsBackWholeGraphAndAllowsExplicitRetry() async throws {
        let db = try DatabaseStore(path:":memory:"), business = try BusinessDataStore(database:db)
        let store = ResearchStore(database:db,snapshots:business)
        try await store.save(demo())
        let revision = await business.revision(), next = try await demo("GAP")
        try db.transaction { db in try db.execute(sql:"CREATE TRIGGER synthetic_reject BEFORE INSERT ON p1_snapshot_roots BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
        await #expect(throws:(any Error).self) { try await store.save(next) }
        #expect(await business.revision() == revision)
        #expect(try await store.savedResearch().count == 1)
        try db.transaction { try $0.execute(sql:"DROP TRIGGER synthetic_reject") }
        try await store.save(next)
        #expect(try await store.savedResearch().count == 2)
    }
    @Test func corruptedFrozenBytesOrEdgesFailClosed() async throws {
        for edges in [false,true] {
            let db = try DatabaseStore(path:":memory:"), business = try BusinessDataStore(database:db)
            let store = ResearchStore(database:db,snapshots:business)
            try await store.save(demo())
            try db.transaction { try $0.execute(sql:edges ? "DELETE FROM p1_snapshot_root_edges WHERE role = 'sources'":"UPDATE p1_snapshot_objects SET content = X'00'") }
            await #expect(throws:(any Error).self) { try await store.savedResearch() }
        }
    }
    @Test func modifiedEvidenceFormatOrCachedResultsCannotBeSaved() async throws {
        let original = try await ResearchDocument.encoded(demo())
        for mode in 0..<4 {
            var json = try #require(JSONSerialization.jsonObject(with:original) as? [String:Any])
            if mode == 0 { json["format"] = "research-demo.v2" }
            if mode == 1 { json["rawData"] = Data("[]".utf8).base64EncodedString() }
            if mode == 2 { json["capitalData"] = Data("price=999".utf8).base64EncodedString() }
            if mode == 3 {
                var score = try #require(json["score"] as? [String:Any]); score["coveredWeightOf84"] = 84; json["score"] = score
            }
            let decoded = try JSONDecoder().decode(ResearchDocument.self,from:JSONSerialization.data(withJSONObject:json))
            let db = try DatabaseStore(path:":memory:"), business = try BusinessDataStore(database:db)
            await #expect(throws:(any Error).self) { try await ResearchStore(database:db,snapshots:business).save(decoded) }
            #expect(try await business.counts().snapshotObjects == 0)
        }
    }
    @Test func frozenSourceCannotBeDeletedWhileResearchReferencesIt() async throws {
        let db = try DatabaseStore(path:":memory:"), business = try BusinessDataStore(database:db)
        let store = ResearchStore(database:db,snapshots:business); try await store.save(demo())
        let record = try #require(try await business.researchRecords().first)
        let object = try #require(record.objects["sources"])
        let address = ObjectAddress(namespace:record.address.namespace,identity:object.identity)
        await #expect(throws:SnapshotError.protectedObject) {
            try await business.prepareDeletion(.unreferencedCache([address]),expectedRevision:business.revision())
        }
    }
    @Test func watchlistRoundTripPreservesDecimalTargetsAndRejectsStaleEdits() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("watchlist-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath:path) }
        let entry = try WatchlistEntry(symbol:"DEMO",targetPrice:Money("12.34567890123456789"),maximumAssignmentPrice:Money("10"),riskNote:"用户自定上限；不自动交易")
        do {
            let db = try DatabaseStore(path:path), store = ResearchStore(database:db,snapshots:try BusinessDataStore(database:db))
            try await store.setWatchlist(entry,expectedRevision:nil)
            await #expect(throws:ResearchError.staleWatchlist) { try await store.setWatchlist(entry,expectedRevision:nil) }
        }
        let db = try DatabaseStore(path:path), store = ResearchStore(database:db,snapshots:try BusinessDataStore(database:db))
        #expect(try await store.watchlist() == [entry])
        let replacement = try WatchlistEntry(symbol:"DEMO",riskNote:"new")
        try await store.setWatchlist(replacement,expectedRevision:entry.revision)
        await #expect(throws:ResearchError.staleWatchlist) { try await store.removeWatchlist(symbol:"DEMO",expectedRevision:entry.revision) }
        try await store.removeWatchlist(symbol:"DEMO",expectedRevision:replacement.revision)
        #expect(try await store.watchlist().isEmpty)
    }
    @Test func watchlistRejectsInvalidValuesAndDetectsIndexCorruption() async throws {
        #expect(throws:ResearchError.invalidDocument) { try WatchlistEntry(symbol:"URL?token") }
        #expect(throws:ResearchError.invalidDocument) { try WatchlistEntry(symbol:"DEMO",targetPrice:Money("0")) }
        #expect(throws:ResearchError.invalidDocument) { try WatchlistEntry(symbol:"DEMO",maximumAssignmentPrice:Money("-1")) }
        #expect(throws:ResearchError.invalidDocument) { try WatchlistEntry(symbol:"DEMO",riskNote:String(repeating:"a",count:501)) }
        let db = try DatabaseStore(path:":memory:"), store = ResearchStore(database:db,snapshots:try BusinessDataStore(database:db))
        try await store.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        try db.transaction { try $0.execute(sql:"UPDATE p1_watchlist SET symbol = 'OTHER'") }
        await #expect(throws:BusinessStoreError.corruptedStorage) { try await store.watchlist() }
        await #expect(throws:BusinessStoreError.corruptedStorage) { try await store.setWatchlist(WatchlistEntry(symbol:"OTHER"),expectedRevision:nil) }
    }
    @Test func upgradeFromEquitySchemaPreservesExistingRows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("research-upgrade-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath:path) }
        do {
            let old = try DatabaseStore(path:path)
            try old.transaction { db in
                try db.execute(sql:"DROP TABLE p1_watchlist_conflicts")
                try db.execute(sql:"DELETE FROM grdb_migrations WHERE identifier = 'business.p1.v6'")
                try db.execute(sql:"DROP TABLE p1_watchlist")
                try db.execute(sql:"DELETE FROM grdb_migrations WHERE identifier = 'business.p1.v5'")
                try db.execute(sql:"CREATE TABLE synthetic_prior (value TEXT)")
                try db.execute(sql:"INSERT INTO synthetic_prior VALUES ('keep')")
            }
        }
        let upgraded = try DatabaseStore(path:path)
        #expect(try upgraded.read { try String.fetchOne($0,sql:"SELECT value FROM synthetic_prior") } == "keep")
        #expect(try upgraded.migrationVersions().contains("business.p1.v5"))
    }
}

private actor ResearchGate {
    private var waiting: CheckedContinuation<ResearchDocument,Never>?
    private var started: CheckedContinuation<Void,Never>?
    private var entered = false
    func generate(_ symbol: String) async -> ResearchDocument {
        entered = true; started?.resume(); started = nil
        return await withCheckedContinuation { waiting = $0 }
    }
    func waitStarted() async { if entered { return }; await withCheckedContinuation { started = $0 } }
    func release(_ document: ResearchDocument) { waiting?.resume(returning:document); waiting = nil }
}
private actor FailingResearchStore: ResearchStorage {
    var rejectReads = false
    var saves = 0
    var rejectWatchReads = false
    var failAfterRemove = false
    var failAfterWrite = false
    var removals = 0
    func configureWatchFailure(remove: Bool = false, write: Bool = false) {
        failAfterRemove = remove; failAfterWrite = write; rejectWatchReads = false
    }
    let base: ResearchStore
    init() throws { let db = try DatabaseStore(path:":memory:"); base = ResearchStore(database:db,snapshots:try BusinessDataStore(database:db)) }
    func savedResearch() async throws -> [SavedResearch] { if rejectReads { throw ResearchError.invalidDocument }; return try await base.savedResearch() }
    func save(_ document: ResearchDocument) async throws { try await base.save(document); saves += 1; rejectReads = true }
    func watchlist() async throws -> [WatchlistEntry] {
        if rejectWatchReads { throw ResearchError.invalidDocument }
        return try await base.watchlist()
    }
    func setWatchlist(_ entry: WatchlistEntry, expectedRevision: UUID?) async throws {
        try await base.setWatchlist(entry,expectedRevision:expectedRevision)
        if failAfterWrite { rejectWatchReads = true }
    }
    func removeWatchlist(symbol: String, expectedRevision: UUID) async throws {
        try await base.removeWatchlist(symbol:symbol,expectedRevision:expectedRevision); removals += 1
        if failAfterRemove { rejectWatchReads = true }
    }
}
@Suite @MainActor struct ResearchModelTests {
    private func model() throws -> ResearchWorkspaceModel {
        let db = try DatabaseStore(path:":memory:")
        return ResearchWorkspaceModel(storage:ResearchStore(database:db,snapshots:try BusinessDataStore(database:db)),generate:{try await demo($0)})
    }
    @Test func companySwitchClearsOldResultAndUnknownSymbolsStayUnavailable() async throws {
        let model = try model(); await model.select("DEMO"); #expect(model.document != nil)
        await model.select("GAP"); #expect(model.document?.report.metrics["fcf"]?.value == nil)
        await model.select("AAPL"); #expect(model.document == nil); #expect(model.selectedSymbol == "AAPL")
    }
    @Test func saveOpenAndReplayUseFrozenVersionWithoutChangingIt() async throws {
        let model = try model(); await model.select("DEMO"); await model.save()
        #expect(model.saved.count == 1); #expect(model.savedID != nil)
        let item = try #require(model.saved.first)
        await model.select("GAP"); await model.open(item.id)
        #expect(model.document?.id == item.document.id)
        await model.recompute(); #expect(!model.hasError)
        #expect(model.message?.contains("复算一致") == true)
        await model.save(); #expect(model.saved.count == 1)
    }
    @Test func cancelledGenerationDiscardsLateResultAndBusyPreventsCrossCompanyPublication() async throws {
        let db = try DatabaseStore(path:":memory:"), gate = ResearchGate()
        let model = ResearchWorkspaceModel(storage:ResearchStore(database:db,snapshots:try BusinessDataStore(database:db)),generate:{await gate.generate($0)})
        let task = Task { await model.select("DEMO") }; await gate.waitStarted()
        await model.select("GAP"); #expect(model.selectedSymbol == "DEMO")
        task.cancel(); await gate.release(try await demo()); await task.value
        #expect(model.document == nil); #expect(!model.isBusy)
    }
    @Test func completedSaveIsNotMisreportedAsRollbackWhenListRefreshFails() async throws {
        let store = try FailingResearchStore(), model = ResearchWorkspaceModel(storage:store,generate:{try await demo($0)})
        await model.select("DEMO"); await model.save()
        #expect(await store.saves == 1); #expect(model.savedID != nil)
        #expect(model.message?.contains("快照已保存") == true)
        await model.save(); #expect(await store.saves == 1)
    }
    @Test func invalidUserTargetDoesNotWriteWatchlist() async throws {
        let model = try model()
        var draft = WatchlistDraft(symbol:"demo"); draft.target = "-1"
        await model.updateWatchlist(draft)
        #expect(model.hasError); #expect(model.watchlist.isEmpty)
        draft.target = "12.5"; draft.maximum = "10"; draft.riskNote = "人工约束"
        await model.updateWatchlist(draft)
        #expect(!model.hasError); #expect(model.watchlist.first?.symbol == "DEMO")
    }

    @Test func oldDraftKeepsItsBaselineAcrossSharedUpdatesAndReloads() async throws {
        for reload in [false,true] {
            let model = try model()
            var initial = WatchlistDraft(symbol:"DEMO"); initial.target = "10"; initial.maximum = "8"; initial.riskNote = "original"
            #expect(await model.updateWatchlist(initial))
            let first = try #require(model.watchlist.first)
            var windowA = WatchlistDraft(entry:first); windowA.target = "12"
            let preserved = windowA
            var windowB = WatchlistDraft(entry:first); windowB.target = "20"; windowB.maximum = "18"; windowB.riskNote = "new restriction"
            #expect(await model.updateWatchlist(windowB))
            if reload { await model.load() }
            let latest = try #require(model.watchlist.first)
            #expect(!(await model.updateWatchlist(windowA)))
            #expect(model.hasError); #expect(model.message?.contains("草稿已保留") == true)
            #expect(windowA == preserved)
            #expect(model.watchlist == [latest]); #expect(latest.targetPrice == (try Money("20")))
            #expect(latest.maximumAssignmentPrice == (try Money("18"))); #expect(latest.riskNote == "new restriction")
            await model.load(); #expect(model.watchlist == [latest])
            // Reopening is an explicit new baseline; the old draft was never rebased.
            var reopened = WatchlistDraft(entry:latest); reopened.target = windowA.target
            #expect(await model.updateWatchlist(reopened))
            #expect(model.watchlist.first?.maximumAssignmentPrice == latest.maximumAssignmentPrice)
        }
    }
    @Test func newDraftStillExpectsAbsenceAfterAnotherWindowCreatesSymbol() async throws {
        let model = try model()
        var oldNew = WatchlistDraft(symbol:"demo"); oldNew.target = "12"
        var other = WatchlistDraft(symbol:"DEMO"); other.target = "20"
        #expect(await model.updateWatchlist(other)); await model.load()
        let latest = model.watchlist
        #expect(!(await model.updateWatchlist(oldNew)))
        #expect(oldNew.original == nil); #expect(oldNew.target == "12")
        #expect(model.watchlist == latest); #expect(model.hasError)
    }
    @Test func editCannotRenameItsRevisionOntoAnotherSymbol() async throws {
        let model = try model()
        #expect(await model.updateWatchlist(WatchlistDraft(symbol:"DEMO")))
        var draft = WatchlistDraft(entry:try #require(model.watchlist.first)); draft.symbol = "OTHER"
        #expect(!(await model.updateWatchlist(draft)))
        await model.load(); #expect(model.watchlist.map(\.symbol) == ["DEMO"])
    }
    @Test func corruptSnapshotDoesNotHideOrDisableHealthyWatchlist() async throws {
        let db = try DatabaseStore(path:":memory:"), store = ResearchStore(database:db,snapshots:try BusinessDataStore(database:db))
        try await store.save(demo())
        let entry = try WatchlistEntry(symbol:"DEMO",targetPrice:Money("10"))
        try await store.setWatchlist(entry,expectedRevision:nil)
        try db.transaction { try $0.execute(sql:"UPDATE p1_snapshot_objects SET content = X'00'") }
        let model = ResearchWorkspaceModel(storage:store)
        await model.load()
        #expect(model.saved.isEmpty); #expect(model.savedReadError != nil)
        #expect(model.watchlist == [entry]); #expect(model.watchlistReadError == nil)
        var draft = WatchlistDraft(entry:entry); draft.target = "20"
        #expect(await model.updateWatchlist(draft))
        #expect(try await store.watchlist().first?.targetPrice == Money("20"))
        #expect(model.savedReadError != nil) // Independent error remains visible after healthy write.
    }
    @Test func corruptWatchlistDoesNotHideHealthySnapshotsAndRecoveryClearsOnlyItsError() async throws {
        let db = try DatabaseStore(path:":memory:"), store = ResearchStore(database:db,snapshots:try BusinessDataStore(database:db))
        try await store.save(demo())
        try await store.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        let model = ResearchWorkspaceModel(storage:store); await model.load()
        try db.transaction { try $0.execute(sql:"UPDATE p1_watchlist SET symbol = 'OTHER'") }
        await model.load()
        #expect(model.watchlist.isEmpty); #expect(model.watchlistReadError != nil)
        #expect(model.saved.count == 1); #expect(model.savedReadError == nil)
        await model.open(try #require(model.saved.first).id)
        #expect(model.document != nil); #expect(model.watchlistReadError != nil)
        try db.transaction { try $0.execute(sql:"UPDATE p1_watchlist SET symbol = 'DEMO'") }
        await model.load()
        #expect(model.watchlist.count == 1); #expect(model.saved.count == 1)
        #expect(model.watchlistReadError == nil); #expect(!model.hasError)
    }
    @Test func committedDeletionRemovesLocalRowEvenWhenRefreshFails() async throws {
        let store = try FailingResearchStore(), model = ResearchWorkspaceModel(storage:store)
        #expect(await model.updateWatchlist(WatchlistDraft(symbol:"DEMO")))
        let entry = try #require(model.watchlist.first)
        await store.configureWatchFailure(remove:true)
        await model.remove(entry)
        #expect(try await store.base.watchlist().isEmpty); #expect(await store.removals == 1)
        #expect(model.watchlist.isEmpty); #expect(model.watchlistReadError != nil)
        #expect(model.message?.contains("已移出自选，但列表刷新失败") == true)
        await store.configureWatchFailure(); await model.load()
        #expect(model.watchlistReadError == nil); #expect(model.watchlist.isEmpty)
        #expect(await store.removals == 1)
    }
    @Test func committedWatchlistSaveReturnsSuccessButMarksFailedRefresh() async throws {
        let store = try FailingResearchStore(), model = ResearchWorkspaceModel(storage:store)
        await store.configureWatchFailure(write:true)
        var draft = WatchlistDraft(symbol:"DEMO"); draft.target = "12.50"
        #expect(await model.updateWatchlist(draft))
        #expect(model.watchlist.first?.targetPrice == (try Money("12.50")))
        #expect(model.watchlistReadError != nil); #expect(model.hasError)
        #expect(model.message?.contains("自选已保存，但列表刷新失败") == true)
        #expect(try await store.base.watchlist() == model.watchlist)
        await store.configureWatchFailure(); await model.load()
        #expect(model.watchlistReadError == nil); #expect(!model.hasError)
    }
}
