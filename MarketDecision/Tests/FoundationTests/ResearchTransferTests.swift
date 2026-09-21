import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence
@testable import AppComposition

private struct TransferFixture {
    let db: DatabaseStore
    let business: BusinessDataStore
    let research: ResearchStore
    let transfer: ResearchTransferStore
    init(path: String = ":memory:") throws {
        db = try DatabaseStore(path:path); business = try BusinessDataStore(database:db)
        research = ResearchStore(database:db,snapshots:business); transfer = ResearchTransferStore(database:db)
    }
}
private func transferDemo(_ symbol: String = "DEMO") async throws -> ResearchDocument {
    try await SyntheticResearchFactory.make(symbol:symbol,executionDate:Date(timeIntervalSince1970:1_800_000_000))
}
private func approve(_ plan: ResearchTransferPlan) -> PlanApproval { .init(planID:plan.id,digest:plan.digest) }
@Suite struct ResearchTransferTests {
    @Test func zipRoundTripReopensFrozenEvidenceAndUserTargets() async throws {
        let source = try TransferFixture(), doc = try await transferDemo()
        try await source.research.save(doc)
        let entry = try WatchlistEntry(symbol:"USER",targetPrice:Money("12.34567890123456789"),riskNote:"synthetic note")
        try await source.research.setWatchlist(entry,expectedRevision:nil)
        let bytes = try await source.transfer.exportBackup()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath:path) }
        do {
            let target = try TransferFixture(path:path)
            let plan = try await target.transfer.prepare(bytes,mode:.merge)
            #expect(try await target.research.savedResearch().isEmpty)
            try await target.transfer.commit(approve(plan))
        }
        let reopened = try TransferFixture(path:path)
        let restored = try #require(try await reopened.research.savedResearch().first)
        #expect(restored.document.rawData == doc.rawData); #expect(restored.document.capitalData == doc.capitalData)
        #expect(try await ResearchDocument.encoded(restored.document.recompute()) == ResearchDocument.encoded(doc.score))
        let restoredEntry = try #require(try await reopened.research.watchlist().first)
        #expect(restoredEntry.targetPrice == entry.targetPrice); #expect(restoredEntry.riskNote == entry.riskNote)
        #expect(restoredEntry.revision != entry.revision)
    }
    @Test func zipHasStandardCRCAndOnlyTwoDeclaredBusinessFiles() async throws {
        let source = try TransferFixture(); try await source.research.save(transferDemo())
        let bytes = try await source.transfer.exportBackup(), files = try ResearchZIP.decode(bytes)
        #expect(Set(files.keys) == Set(["manifest.json","research-state.json"]))
        #expect(ResearchZIP.crc(Data("123456789".utf8)) == 0xcbf43926)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at:url) }; try bytes.write(to:url)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments = ["-t",url.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding:files["manifest.json"]!,as:UTF8.self).contains("synthetic-research-and-watchlist"))
    }
    @Test func unsafeZIPEntriesAndHeadersFailClosed() throws {
        let good = try ResearchZIP.encode(["manifest.json":Data("{}".utf8),"research-state.json":Data("{}".utf8)])
        func put(_ bytes: inout Data, _ at: Int, _ value: UInt32, _ count: Int) {
            for i in 0..<count { bytes[at+i] = UInt8(truncatingIfNeeded:value >> (i*8)) }
        }
        let end = good.count-22
        let directory = Int(good[end+16]) | Int(good[end+17])<<8 | Int(good[end+18])<<16 | Int(good[end+19])<<24
        for variant in 0..<8 {
            var bad = good
            switch variant {
            case 0: bad[30] = 47 // absolute name, inconsistent/unsafe
            case 1: put(&bad,directory+38,UInt32(0o120777)<<16,4) // symlink
            case 2: put(&bad,directory+10,8,2) // compressed content unsupported
            case 3: put(&bad,directory+24,0xffff_ffff,4) // oversized declaration
            case 4: put(&bad,directory+8,1,2) // encryption
            case 5: put(&bad,directory+42,1,4) // offset alias/overlap
            case 6: bad[43] ^= 1 // content CRC mismatch
            default: bad.append(0) // trailing data/EOCD ambiguity
            }
            #expect(throws:(any Error).self) { try ResearchZIP.decode(bad) }
        }
        #expect(throws:SnapshotError.unsafeArchive) { try ResearchZIP.encode(["../secret":Data()]) }
        for length in [0,1,21,good.count-1] { #expect(throws:(any Error).self) { try ResearchZIP.decode(Data(good.prefix(length))) } }
    }
    @Test func manifestHashVersionAndReferenceDamageRejectBeforeWriting() async throws {
        let source = try TransferFixture(); try await source.research.save(transferDemo())
        let good = try await ResearchZIP.decode(source.transfer.exportBackup())
        let target = try TransferFixture(), before = await target.business.revision()
        for variant in 0..<4 {
            var files = good
            var manifest = try #require(JSONSerialization.jsonObject(with:files["manifest.json"]!) as? [String:Any])
            if variant == 0 { manifest["schema"] = "future.v99" }
            if variant == 1 { manifest["sha256"] = String(repeating:"0",count:64) }
            if variant >= 2 {
                var body = try #require(JSONSerialization.jsonObject(with:files["research-state.json"]!) as? [String:Any])
                if variant == 2 { body["objects"] = [] }
                else { body["format"] = "unknown" }
                files["research-state.json"] = try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)
                manifest["sha256"] = digest(files["research-state.json"]!); manifest["size"] = files["research-state.json"]!.count
                if variant == 2 { manifest["objects"] = 0 }
            }
            files["manifest.json"] = try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys)
            let bytes = try ResearchZIP.encode(files)
            await #expect(throws:(any Error).self) { try await target.transfer.prepare(bytes,mode:.replace) }
            #expect(await target.business.revision() == before)
        }
    }
    @Test func mergeRetainsConflictingFrozenGraphsAndDeduplicatesRepeatedImport() async throws {
        let source = try TransferFixture(), target = try TransferFixture(), original = try await transferDemo()
        try await target.research.save(original)
        let gap = try await transferDemo("GAP")
        var json = try #require(JSONSerialization.jsonObject(with:ResearchDocument.encoded(gap)) as? [String:Any])
        json["id"] = original.id.uuidString
        let other = try JSONDecoder().decode(ResearchDocument.self,from:JSONSerialization.data(withJSONObject:json))
        try await source.research.save(other)
        let bytes = try await source.transfer.exportBackup()
        for _ in 0..<2 { let plan = try await target.transfer.prepare(bytes,mode:.merge); try await target.transfer.commit(approve(plan)) }
        let records = try await target.research.savedResearch()
        #expect(records.count == 2); #expect(Set(records.map(\.id)).count == 2)
        #expect(Set(records.map { $0.document.symbol }) == Set(["DEMO","GAP"]))
        for record in records { try await record.document.validate() }
        // Back up the remapped graph and reopen it without rejoining sources by logical ID.
        let third = try TransferFixture(), backup = try await target.transfer.exportBackup()
        try await third.transfer.commit(approve(third.transfer.prepare(backup,mode:.replace)))
        #expect(try await third.research.savedResearch().count == 2)
    }
    @Test func watchlistConflictsPreserveBothRevisionsAcrossRebackup() async throws {
        let source = try TransferFixture(), target = try TransferFixture()
        let old = try WatchlistEntry(symbol:"DEMO",targetPrice:Money("10"),riskNote:"local")
        let incoming = try WatchlistEntry(symbol:"DEMO",targetPrice:Money("20"),riskNote:"incoming")
        try await target.research.setWatchlist(old,expectedRevision:nil); try await source.research.setWatchlist(incoming,expectedRevision:nil)
        let bytes = try await source.transfer.exportBackup()
        for _ in 0..<2 { try await target.transfer.commit(approve(target.transfer.prepare(bytes,mode:.merge))) }
        #expect(try await target.research.watchlist() == [old])
        #expect(try await target.transfer.conflicts().map(\.entry) == [incoming])
        let third = try TransferFixture(); try await third.transfer.commit(approve(third.transfer.prepare(target.transfer.exportBackup(),mode:.replace)))
        #expect(try await third.research.watchlist().first?.targetPrice == old.targetPrice); #expect(try await third.transfer.conflicts().map(\.entry) == [incoming])
    }
    @Test func changedWatchlistInvalidatesPlanAndOldDraftAfterRestoreIsRejected() async throws {
        let fixture = try TransferFixture(), entry = try WatchlistEntry(symbol:"DEMO")
        try await fixture.research.setWatchlist(entry,expectedRevision:nil)
        let bytes = try await fixture.transfer.exportBackup(), plan = try await fixture.transfer.prepare(bytes,mode:.replace)
        let new = try WatchlistEntry(symbol:"DEMO",targetPrice:Money("20"))
        try await fixture.research.setWatchlist(new,expectedRevision:entry.revision)
        await #expect(throws:SnapshotError.stalePlan) { try await fixture.transfer.commit(approve(plan)) }
        let fresh = try await fixture.transfer.prepare(bytes,mode:.replace); try await fixture.transfer.commit(approve(fresh))
        await #expect(throws:ResearchError.staleWatchlist) { try await fixture.research.setWatchlist(new,expectedRevision:entry.revision) }
        await #expect(throws:ResearchError.staleWatchlist) { try await fixture.research.setWatchlist(new,expectedRevision:new.revision) }
    }
    @Test func failedRestoreRollsBackGraphAndWatchlistAndSamePlanCanRetry() async throws {
        let source = try TransferFixture(), target = try TransferFixture()
        try await source.research.save(transferDemo()); try await source.research.setWatchlist(WatchlistEntry(symbol:"NEW"),expectedRevision:nil)
        try await target.research.save(transferDemo("GAP")); try await target.research.setWatchlist(WatchlistEntry(symbol:"OLD"),expectedRevision:nil)
        let before = try await target.transfer.exportBackup(), revision = await target.business.revision()
        let plan = try await target.transfer.prepare(source.transfer.exportBackup(),mode:.replace)
        try target.db.transaction { try $0.execute(sql:"CREATE TRIGGER fail_import BEFORE INSERT ON p1_watchlist BEGIN SELECT RAISE(ABORT,'synthetic'); END") }
        await #expect(throws:(any Error).self) { try await target.transfer.commit(approve(plan)) }
        #expect(try await target.transfer.exportBackup() == before); #expect(await target.business.revision() == revision)
        try target.db.transaction { try $0.execute(sql:"DROP TRIGGER fail_import") }
        try await target.transfer.commit(approve(plan))
        #expect(try await target.research.watchlist().map(\.symbol) == ["NEW"])
        await #expect(throws:SnapshotError.unknownPlan) { try await target.transfer.commit(approve(plan)) }
    }
    @Test func cancelWrongApprovalAndPrecancelledCommitDoNotMutate() async throws {
        let fixture = try TransferFixture(); try await fixture.research.save(transferDemo())
        let plan = try await fixture.transfer.prepareClear(), before = try await fixture.transfer.exportBackup()
        await #expect(throws:SnapshotError.approvalMismatch) { try await fixture.transfer.commit(.init(planID:plan.id,digest:"wrong")) }
        await fixture.transfer.cancel(plan.id)
        await #expect(throws:SnapshotError.unknownPlan) { try await fixture.transfer.commit(approve(plan)) }
        #expect(try await fixture.transfer.exportBackup() == before)
        let another = try await fixture.transfer.prepareClear()
        // Cancellation is established before commit enters the store.
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; try await fixture.transfer.commit(approve(another)) }
        await #expect(throws:CancellationError.self) { try await cancelled.value }
        #expect(try await fixture.transfer.exportBackup() == before)
    }
    @Test func explicitClearRemovesCurrentBusinessTablesButPreservesSchemaAndExternalBackup() async throws {
        let fixture = try TransferFixture(); try await fixture.research.save(transferDemo())
        try await fixture.research.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at:external) }
        let bytes = try await fixture.transfer.exportBackup(); try bytes.write(to:external)
        let plan = try await fixture.transfer.prepareClear()
        try await fixture.transfer.commit(approve(plan))
        for table in ResearchTransferStore.clearTables { #expect(try fixture.db.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM \(table)") } == 0) }
        #expect(try fixture.db.migrationVersions().contains("business.p1.v6"))
        #expect(try Data(contentsOf:external) == bytes)
        #expect(try fixture.db.read { try Row.fetchAll($0,sql:"PRAGMA foreign_key_check").isEmpty })
    }
    @Test func researchReplacePreservesSourceCacheAndClearFailureRollsBackIt() async throws {
        let f = try TransferFixture(), instant = try MillisecondInstant(iso8601:"2025-01-10T12:00:00.000Z")
        let source = try SourceDocument(reference:"synthetic/cache.json",providerID:"fixture",feedID:"fixture",endpoint:.bars,
            receivedAt:instant,availableAt:instant,mediaType:"application/json",evidenceRef:"synthetic",licenseRef:"synthetic",payload:Data("{}".utf8))
        _ = try await f.business.ingest(document:source,observations:[],expectedRevision:f.business.revision())
        try await f.research.setWatchlist(WatchlistEntry(symbol:"OLD"),expectedRevision:nil)
        let empty = try TransferFixture(), archive = try await empty.transfer.exportBackup()
        try await f.transfer.commit(approve(f.transfer.prepare(archive,mode:.replace)))
        #expect(try await f.business.sourceDocument(reference:source.reference).payload == source.payload)
        let plan = try await f.transfer.prepareClear(), revision = await f.business.revision()
        // This fails after the source cache has been deleted inside the transaction.
        try f.db.transaction { try $0.execute(sql:"CREATE TRIGGER fail_clear BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT,'synthetic'); END") }
        await #expect(throws:(any Error).self) { try await f.transfer.commit(approve(plan)) }
        #expect(try await f.business.sourceDocument(reference:source.reference).payload == source.payload)
        #expect(await f.business.revision() == revision)
        try f.db.transaction { try $0.execute(sql:"DROP TRIGGER fail_clear") }
        try await f.transfer.commit(approve(plan))
        #expect(try await f.business.counts().sourceDocuments == 0)
    }
    @Test func plansAreBoundedAndDoNotSurviveStoreRecreation() async throws {
        let f = try TransferFixture()
        var plans: [ResearchTransferPlan] = []
        for _ in 0..<16 { plans.append(try await f.transfer.prepareClear()) }
        await #expect(throws:SnapshotError.resourceLimit) { try await f.transfer.prepareClear() }
        await f.transfer.cancel(plans[0].id)
        _ = try await f.transfer.prepareClear()
        let restarted = ResearchTransferStore(database:f.db)
        await #expect(throws:SnapshotError.unknownPlan) { try await restarted.commit(approve(plans[1])) }
    }
    @Test func markdownPreservesSourcesVersionsAndUnavailableMetrics() async throws {
        let doc = try await transferDemo("GAP"), data = try await ResearchMarkdown.render(doc)
        let text = String(decoding:data,as:UTF8.self)
        #expect(text.contains("合成 DEMO")); #expect(text.contains("不是可恢复备份"))
        #expect(text.contains(doc.rawHash)); #expect(text.contains(doc.model.reference.contentHash))
        #expect(text.contains("income.revenue")); #expect(text.contains("missingClass"))
        #expect(text.contains("fundamental-input.v1")); #expect(text.contains("sourceFactIDs"))
    }
    @Test func migrationFromResearchSchemaPreservesWatchlist() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("archive-upgrade-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath:path) }
        let old = try TransferFixture(path:path), entry = try WatchlistEntry(symbol:"DEMO")
        try await old.research.setWatchlist(entry,expectedRevision:nil)
        try old.db.transaction { db in
            try db.execute(sql:"DROP TABLE p1_watchlist_conflicts")
            try db.execute(sql:"DELETE FROM grdb_migrations WHERE identifier = 'business.p1.v6'")
        }
        let upgraded = try TransferFixture(path:path)
        #expect(try await upgraded.research.watchlist() == [entry])
        #expect(try await upgraded.transfer.conflicts().isEmpty)
    }
}
@Suite @MainActor struct ResearchTransferModelTests {
    @Test func previewCancelAndWrongSheetIdentityCannotAuthorizeClear() async throws {
        let f = try TransferFixture(); try await f.research.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        let model = ResearchTransferModel(store:f.transfer); await model.prepareClear()
        let plan = try #require(model.plan)
        #expect(!(await model.confirm(id:UUID(),digest:plan.digest)))
        #expect(try await f.research.watchlist().count == 1)
        await model.cancel()
        #expect(!(await model.confirm(id:plan.id,digest:plan.digest)))
        #expect(try await f.research.watchlist().count == 1)
    }
    @Test func stalePlanRequiresNewPreviewAndConfirmedCommitPublishesOnce() async throws {
        let f = try TransferFixture(), model = ResearchTransferModel(store:f.transfer)
        await model.prepareClear(); let old = try #require(model.plan)
        try await f.research.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        #expect(!(await model.confirm(id:old.id,digest:old.digest))); #expect(model.plan == nil)
        await model.prepareClear(); let next = try #require(model.plan)
        #expect(await model.confirm(id:next.id,digest:next.digest))
        #expect(model.plan == nil); #expect(model.message?.contains("操作已提交") == true)
        #expect(!(await model.confirm(id:next.id,digest:next.digest)))
        #expect(try await f.research.watchlist().isEmpty)
    }
}

private actor TransferControlStore: ResearchTransferStorage {
    let wrapped: ResearchTransferStore
    let pause: Bool
    var pending: CheckedContinuation<Void,Never>?
    var started: CheckedContinuation<Void,Never>?
    var didStart = false
    var commits = 0
    init(_ wrapped: ResearchTransferStore, pause: Bool) { self.wrapped = wrapped; self.pause = pause }
    func waitForStart() async { if !didStart { await withCheckedContinuation { started = $0 } } }
    func release() { pending?.resume(); pending = nil }
    func exportBackup() async throws -> Data { try await wrapped.exportBackup() }
    func prepare(_ data: Data, mode: RestoreMode) async throws -> ResearchTransferPlan { try await wrapped.prepare(data,mode:mode) }
    func prepareClear() async throws -> ResearchTransferPlan {
        let plan = try await wrapped.prepareClear()
        if pause { await withCheckedContinuation { pending = $0; didStart = true; started?.resume(); started = nil } }
        return plan
    }
    func commit(_ approval: PlanApproval) async throws { try await wrapped.commit(approval); commits += 1 }
    func cancel(_ id: UUID) async { await wrapped.cancel(id) }
    func conflicts() throws -> [WatchlistConflict] { throw BusinessStoreError.corruptedStorage }
}
@Suite @MainActor struct ResearchTransferLifecycleTests {
    @Test func dismissedPreviewDropsLatePreparedPlanWithoutAuthorizingClear() async throws {
        let f = try TransferFixture(), controlled = TransferControlStore(f.transfer,pause:true)
        try await f.research.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        let model = ResearchTransferModel(store:controlled), task = Task { await model.prepareClear() }
        await controlled.waitForStart(); await model.cancel(); await controlled.release(); await task.value
        #expect(model.plan == nil); #expect(await controlled.commits == 0)
        #expect(try await f.research.watchlist().count == 1)
    }
    @Test func committedWriteRemainsSuccessWhenConflictReadFails() async throws {
        let f = try TransferFixture(), controlled = TransferControlStore(f.transfer,pause:false)
        try await f.research.setWatchlist(WatchlistEntry(symbol:"DEMO"),expectedRevision:nil)
        let model = ResearchTransferModel(store:controlled); await model.prepareClear()
        let plan = try #require(model.plan)
        #expect(await model.confirm(id:plan.id,digest:plan.digest)); #expect(await controlled.commits == 1)
        #expect(model.message?.contains("操作已提交，但") == true); #expect(model.plan == nil)
        #expect(try await f.research.watchlist().isEmpty)
    }
}
