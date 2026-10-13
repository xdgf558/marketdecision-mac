import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
@testable import Persistence

private func laDatabase() throws -> DatabaseStore { try DatabaseStore(path:":memory:",purpose:.portfolioLedger) }
private func laSeed(_ db:DatabaseStore,account:String = "A",amount:String = "100",eventID:String = "deposit") async throws -> LedgerStore {
    let ledger = try LedgerStore(database:db), before = try await ledger.snapshot()
    let created = try await ledger.createAccount(.init(id:account,name:"Synthetic " + account),expectedRevision:before.revision)
    let event = LedgerEvent(id:account + "/" + eventID,accountID:account,effectiveAt:try LedgerCSV.timestamp("2026-01-02T00:00:00.0004Z"),
        source:.init(sourceSystem:"synthetic",externalTransactionID:eventID,evidence:"Synthetic account receipt"),
        payload:.cash(.init(kind:.deposit,amount:try Money(amount))))
    let preview = try await ledger.previewManual(events:[event],expectedRevision:created.revision)
    _ = try await ledger.commit(planID:preview.id,expectedRevision:preview.targetRevision); return ledger
}
private func laPlan(_ store:LedgerArchiveStore,_ bytes:Data,_ mode:LedgerRestoreMode) async throws -> LedgerTransferPlan {
    let status = try await store.status()
    return try await store.prepareRestore(bytes,mode:mode,expectedLedgerRevision:status.ledgerRevision,expectedPerformanceRevision:status.performanceRevision)
}
private func laClear(_ store:LedgerArchiveStore) async throws -> LedgerTransferPlan {
    let status = try await store.status()
    return try await store.prepareClear(expectedLedgerRevision:status.ledgerRevision,expectedPerformanceRevision:status.performanceRevision)
}
private func laRequest(_ account:String = "A") throws -> PerformanceRequest {
    let early = try LedgerCSV.timestamp("2026-01-01T00:00:00.0004Z"),end = try LedgerCSV.timestamp("2026-01-03T21:00:00.0006Z")
    let evidence = PerformanceEvidence(id:"calendar",source:"synthetic",kind:.synthetic,availableAt:early,reference:"fixture/calendar",rawDocument:Data("synthetic calendar raw".utf8))
    return PerformanceRequest(accountID:account,calculatedAt:end,calendar:.init(tradingDays:["2026-01-03"],evidence:evidence),
        days:[.init(day:"2026-01-03",valuationAt:end,sessions:[],prices:[])],externalFlowsComplete:true,flowCompletenessEvidence:evidence)
}
private func laReport(_ ledger:LedgerStore) async throws -> SavedPerformanceReport {
    let performance = try await ledger.makePerformanceStore(),context = try await performance.context(),request = try laRequest()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    let preview = try await performance.prepare(request:request,rawRequest:encoder.encode(request),expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision)
    return try await performance.commit(planID:preview.id,expectedLedgerRevision:preview.ledgerRevision,expectedPerformanceRevision:preview.performanceRevision)
}

@Suite("Independent ledger archive integrity and transactional restore")
struct LedgerArchiveTests {
    @Test func archiveRoundTripPreservesEverySourceReportByteAndReopensHistoricalReplay() async throws {
        let source = try laDatabase(),ledger = try await laSeed(source),report = try await laReport(ledger)
        let archive = try await ledger.makeArchiveStore(),raw = try await archive.exportArchive()
        let original = try source.read(LedgerArchiveState.capture)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("archive-" + UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at:path) }
        let target = try DatabaseStore(path:path.path,purpose:.portfolioLedger),store = try LedgerArchiveStore(database:target)
        let plan = try await laPlan(store,raw,.replace),result = try await store.commit(.init(plan:plan))
        #expect(result.ledgerRevision != original.ledgerRevision)
        #expect(result.performanceRevision != original.performanceRevision)
        #expect(try target.read(LedgerArchiveState.capture).tables == original.tables)
        let reopened = try PerformanceStore(path:path.path),saved = try await reopened.open(id:report.id)
        #expect(saved.replayMatched); #expect(!saved.isCurrentLedger); #expect(saved.report == report.report)
        #expect(saved.report.input.events[0].effectiveAt.timeIntervalSinceReferenceDate.bitPattern == report.report.input.events[0].effectiveAt.timeIntervalSinceReferenceDate.bitPattern)
    }

    @Test func independentHistoriesRebaseAuditIndexesAndPreserveOriginAcrossNextBackup() async throws {
        let aDB = try laDatabase(),bDB = try laDatabase(),a = try await laSeed(aDB),b = try await laSeed(bDB,account:"B")
        let target = try await a.makeArchiveStore(),source = try await b.makeArchiveStore(),raw = try await source.exportArchive()
        let before = try await b.snapshot(),plan = try await laPlan(target,raw,.merge)
        #expect(plan.canCommit); #expect(plan.result.events == 2)
        _ = try await target.commit(.init(plan:plan))
        let merged = try await a.snapshot()
        #expect(merged.events.count == 2); #expect(merged.state.cashByAccount["A"] == (try Money("100"))); #expect(merged.state.cashByAccount["B"] == (try Money("100")))
        #expect(merged.events[1] == before.events[0])
        #expect(try aDB.read { try Int.fetchAll($0,sql:"SELECT audit_sequence FROM ledger_events ORDER BY audit_sequence") } == [1,2])
        #expect(try aDB.read { try Data.fetchOne($0,sql:"SELECT archive_bytes FROM ledger_archive_origins") } == raw)
        let second = try laDatabase(),restored = try LedgerArchiveStore(database:second),nextRaw = try await target.exportArchive()
        _ = try await restored.commit(.init(plan:laPlan(restored,nextRaw,.replace)))
        let secondLedger = try LedgerStore(database:second)
        #expect(try await secondLedger.snapshot().events == merged.events)
        #expect(try second.read(LedgerArchiveState.capture).tables == aDB.read(LedgerArchiveState.capture).tables)
        // Re-import does not duplicate the active cash or introduce another origin.
        _ = try await target.commit(.init(plan:laPlan(target,raw,.merge)))
        #expect(try await a.snapshot().events == merged.events)
        #expect(try aDB.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM ledger_archive_origins") } == 1)
    }

    @Test func conflictingIdentityRequiresExplicitIsolationAndReexportsOriginalBytes() async throws {
        let a = try await laSeed(laDatabase()),b = try await laSeed(laDatabase(),amount:"101")
        let target = try await a.makeArchiveStore(),source = try await b.makeArchiveStore(),raw = try await source.exportArchive()
        let before = try await a.snapshot(),status = try await target.status(),blocked = try await laPlan(target,raw,.merge)
        #expect(!blocked.canCommit)
        await #expect(throws:LedgerArchiveError.invalidPlan) { try await target.commit(.init(plan:blocked)) }
        #expect(try await target.status() == status)
        let isolated = try await laPlan(target,raw,.retainConflict)
        #expect(isolated.canCommit); #expect(isolated.result.conflicts == 1)
        _ = try await target.commit(.init(plan:isolated))
        #expect(try await a.snapshot() == before)
        let conflicts = try await target.conflicts(),summary = try #require(conflicts.first)
        #expect(conflicts.count == 1); #expect(try await target.exportConflict(id:summary.id) == raw)
        _ = try await target.commit(.init(plan:laPlan(target,raw,.retainConflict)))
        #expect(try await target.conflicts().count == 1)
    }

    @Test func replaceRepairsDamagedBodiesButMergeRequiresValidCurrentAndMetadata() async throws {
        let source = try await laSeed(laDatabase()),bytes = try await source.makeArchiveStore().exportArchive()
        for mutation in ["UPDATE ledger_sources SET raw_bytes = x'00'","UPDATE ledger_events SET event_json = x'00'","UPDATE ledger_accounts SET content_hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"] {
            let db = try laDatabase(),targetLedger = try await laSeed(db),target = try await targetLedger.makeArchiveStore()
            try db.transaction { try $0.execute(sql:mutation) }
            _ = try await target.status()
            await #expect(throws:(any Error).self) { try await laPlan(target,bytes,.merge) }
            _ = try await target.commit(.init(plan:laPlan(target,bytes,.replace)))
            #expect(try await targetLedger.snapshot().events.count == 1)
        }
        let db = try laDatabase(),target = try LedgerArchiveStore(database:db)
        try db.transaction { try $0.execute(sql:"UPDATE ledger_metadata SET revision = 'not-a-revision'") }
        await #expect(throws:LedgerArchiveError.corruptedStorage) { try await laPlan(target,bytes,.replace) }
    }

    @Test func injectedFailureRollsBackAndExactPlanRetriesWhileStaleIsConsumed() async throws {
        let db = try laDatabase(),ledger = try await laSeed(db),store = try await ledger.makeArchiveStore()
        let before = try db.read(LedgerArchiveState.capture),plan = try await laClear(store)
        await store.injectFailureOnNextCommit()
        await #expect(throws:LedgerArchiveError.injectedFailure) { try await store.commit(.init(plan:plan)) }
        #expect(try db.read(LedgerArchiveState.capture) == before)
        let wrong = LedgerTransferApproval(planID:plan.id,digest:"wrong",ledgerRevision:plan.baseLedgerRevision,performanceRevision:plan.basePerformanceRevision)
        await #expect(throws:LedgerArchiveError.invalidPlan) { try await store.commit(wrong) }
        let result = try await store.commit(.init(plan:plan)); #expect(result.counts.events == 0)
        let stale = try await laClear(store),other = try LedgerArchiveStore(database:db)
        _ = try await other.commit(.init(plan:laClear(other)))
        await #expect(throws:LedgerArchiveError.stalePlan) { try await store.commit(.init(plan:stale)) }
        await #expect(throws:LedgerArchiveError.invalidPlan) { try await store.commit(.init(plan:stale)) }
    }

    @Test func clearInvalidatesExistingLedgerAndPerformancePlansWithoutDeletingOtherDatabase() async throws {
        let db = try laDatabase(),ledger = try await laSeed(db),store = try await ledger.makeArchiveStore(),performance = try await ledger.makePerformanceStore()
        let context = try await performance.context(),event = LedgerEvent(id:"later",accountID:"A",effectiveAt:try LedgerCSV.timestamp("2026-01-02T01:00:00Z"),
            source:.init(sourceSystem:"synthetic",externalTransactionID:"later",evidence:"synthetic receipt"),payload:.cash(.init(kind:.deposit,amount:try Money("5"))))
        let oldLedger = try await ledger.previewManual(events:[event],expectedRevision:context.ledger.revision)
        let oldPerformance = try await performance.prepare(request:laRequest(),rawRequest:nil,expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision)
        let business = try DatabaseStore(path:":memory:")
        try business.transaction { try $0.execute(sql:"CREATE TABLE retained(value TEXT); INSERT INTO retained VALUES ('untouched')") }
        _ = try await store.commit(.init(plan:laClear(store)))
        await #expect(throws:LedgerStoreError.stalePlan) { try await ledger.commit(planID:oldLedger.id,expectedRevision:oldLedger.targetRevision) }
        await #expect(throws:PerformanceStoreError.stalePlan) { try await performance.commit(planID:oldPerformance.id,expectedLedgerRevision:oldPerformance.ledgerRevision,expectedPerformanceRevision:oldPerformance.performanceRevision) }
        #expect(try await ledger.snapshot().events.isEmpty)
        #expect(try business.read { try String.fetchOne($0,sql:"SELECT value FROM retained") } == "untouched")
        #expect(throws:LedgerArchiveError.incompatiblePurpose) { try LedgerArchiveStore(database:business) }
    }

    @Test func malformedFormatHashIndexAndOriginAreRejectedByAllArchiveReads() async throws {
        let db = try laDatabase(),ledger = try await laSeed(db),store = try await ledger.makeArchiveStore(),raw = try await store.exportArchive()
        let files = try ResearchZIP.decode(raw),stateBytes = try #require(files["research-state.json"])
        let foreign = try ResearchZIP.encode(["manifest.json":Data("{\"format\":\"research-backup.v1\"}".utf8),"research-state.json":stateBytes])
        #expect(throws:(any Error).self) { try LedgerArchiveValidation().decode(foreign) }
        let state = try LedgerArchiveCodec.decode(raw)
        var emptyRow = state
        emptyRow.tables[0].rows = [[]]
        #expect(throws:LedgerArchiveError.corruptedArchive) { try emptyRow.validateShape() }
        #expect(throws:(any Error).self) { try LedgerArchiveValidation().decode(LedgerArchiveCodec.encode(emptyRow)) }
        var altered = state
        let index = try #require(altered.tables.firstIndex(where: { $0.name == "ledger_events" }))
        altered.tables[index].rows[0][3] = .integer(9)
        #expect(throws:(any Error).self) { try LedgerArchiveValidation().decode(LedgerArchiveCodec.encode(altered)) }
        try db.transaction { try $0.execute(sql:"UPDATE ledger_events SET source_row = 2") }
        await #expect(throws:(any Error).self) { try await store.exportArchive() }
    }

    @Test func pendingApprovalsAreNotPersistentAndUnknownTablesAreNotSilentlyCleared() async throws {
        let db = try laDatabase(),ledger = try await laSeed(db),store = try await ledger.makeArchiveStore(),plan = try await laClear(store)
        let restarted = try LedgerArchiveStore(database:db)
        await #expect(throws:LedgerArchiveError.invalidPlan) { try await restarted.commit(.init(plan:plan)) }
        await store.cancel(plan.id)
        await #expect(throws:LedgerArchiveError.invalidPlan) { try await store.commit(.init(plan:plan)) }
        try db.transaction { try $0.execute(sql:"CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES ('preserved')") }
        await #expect(throws:LedgerArchiveError.unsupportedFormat) { try await laClear(store) }
        #expect(try db.read { try String.fetchOne($0,sql:"SELECT value FROM future_data") } == "preserved")
    }
    @Test func changedCSVFileWithSameExternalIdentityKeepsOneEconomicEventAndBothRawSources() async throws {
        let aDB = try laDatabase(),bDB = try laDatabase()
        let map = LedgerCSVMapping(fields:[.timestamp:"time",.type:"type",.amount:"amount",.externalID:"external"])
        let rawA = Data("time,type,amount,external\n2026-01-02T00:00:00Z,DEPOSIT,100,one\n".utf8)
        let rawB = Data("time,type,amount,external\r\n2026-01-02T00:00:00Z,DEPOSIT,100,one\r\n".utf8)
        func seed(_ db:DatabaseStore,_ raw:Data) async throws -> LedgerStore {
            let ledger = try LedgerStore(database:db),empty = try await ledger.snapshot()
            let created = try await ledger.createAccount(.init(id:"A",name:"Synthetic"),expectedRevision:empty.revision)
            let preview = try await ledger.previewCSV(data:raw,accountID:"A",sourceSystem:"synthetic-broker",mapping:map,expectedRevision:created.revision)
            _ = try await ledger.commit(planID:preview.id,expectedRevision:preview.targetRevision)
            return ledger
        }
        let a = try await seed(aDB,rawA),b = try await seed(bDB,rawB),target = try await a.makeArchiveStore()
        let raw = try await b.makeArchiveStore().exportArchive()
        _ = try await target.commit(.init(plan:laPlan(target,raw,.merge)))
        let merged = try await a.snapshot()
        #expect(merged.events.count == 1); #expect(merged.state.cashByAccount["A"] == (try Money("100")))
        let sources = try aDB.read { try Data.fetchAll($0,sql:"SELECT raw_bytes FROM ledger_sources") }
        #expect(sources.count == 2); #expect(sources.contains(rawA)); #expect(sources.contains(rawB))
        #expect(merged.batches.reduce(0,{ $0 + $1.duplicateRowCount }) == 1)
        _ = try await target.exportArchive()
    }

    @Test func archiveAncestryDepthAndTamperedOriginBindingAreRejected() async throws {
        let db = try laDatabase(),store = try LedgerArchiveStore(database:db)
        let empty = try db.read(LedgerArchiveState.capture)
        var nested = try LedgerArchiveCodec.encode(empty)
        for _ in 0...LedgerArchiveCodec.maximumDepth {
            var parent = empty
            let index = try #require(parent.tables.firstIndex(where: { $0.name == "ledger_archive_origins" }))
            parent.tables[index].rows = [[.text(LedgerCSV.hash(nested)),.blob(nested)]]
            nested = try LedgerArchiveCodec.encode(parent)
        }
        #expect(throws:LedgerArchiveError.budgetExceeded) { try LedgerArchiveValidation().decode(nested) }
        let a = try await laSeed(db),b = try await laSeed(laDatabase(),account:"B"),raw = try await b.makeArchiveStore().exportArchive()
        _ = try await store.commit(.init(plan:laPlan(store,raw,.merge)))
        try db.transaction { try $0.execute(sql:"UPDATE ledger_archive_batch_links SET original_batch_id = 'missing'") }
        await #expect(throws:LedgerArchiveError.corruptedArchive) { try await store.exportArchive() }
        #expect(try await a.snapshot().events.count == 2)
    }

    @Test func twoConnectionLedgerAndPerformanceChangesRejectPinnedTransfer() async throws {
        for changeLedger in [false,true] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("archive-cas-" + UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at:path) }
            let db = try DatabaseStore(path:path.path,purpose:.portfolioLedger),ledger = try await laSeed(db)
            let first = try await ledger.makeArchiveStore(),second = try LedgerArchiveStore(path:path.path)
            let plan = try await laClear(second)
            if changeLedger {
                let snapshot = try await ledger.snapshot()
                _ = try await ledger.createAccount(.init(id:"B",name:"New synthetic account"),expectedRevision:snapshot.revision)
            } else { _ = try await laReport(ledger) }
            let before = try await first.status()
            await #expect(throws:LedgerArchiveError.stalePlan) { try await second.commit(.init(plan:plan)) }
            #expect(try await first.status() == before)
        }
    }

    @Test func untrustedAppendBaseCannotOverflowOrClaimMissingAuditPrefix() async throws {
        let db = try laDatabase(),ledger = try await laSeed(db),store = try await ledger.makeArchiveStore()
        let valid = try LedgerArchiveCodec.decode(await store.exportArchive())
        for base in [Int.max,2] {
            var altered = valid
            let table = try #require(altered.tables.firstIndex(where: { $0.name == "ledger_batches" }))
            let original = try JSONDecoder().decode(LedgerStore.Batch.self,from:altered.tables[table].rows[0][3].blob())
            let bad = LedgerStore.Batch(id:original.id,sourceID:original.sourceID,appendBaseCount:base,rows:original.rows)
            let bytes = try LedgerArchiveCodec.canonical(bad)
            altered.tables[table].rows[0][2] = .text(LedgerCSV.hash(bytes)); altered.tables[table].rows[0][3] = .blob(bytes)
            #expect(throws:LedgerStoreError.corruptedStorage) { try LedgerArchiveValidation().decode(LedgerArchiveCodec.encode(altered)) }
        }
    }

    @Test func cachedAncestorStillEnforcesTotalStructuralDepth() throws {
        let empty = try laDatabase().read(LedgerArchiveState.capture)
        func wrap(_ child:Data) throws -> Data {
            var parent = empty
            let index = try #require(parent.tables.firstIndex(where: { $0.name == "ledger_archive_origins" }))
            parent.tables[index].rows = [[.text(LedgerCSV.hash(child)),.blob(child)]]
            return try LedgerArchiveCodec.encode(parent)
        }
        let leaf = try LedgerArchiveCodec.encode(empty),child = try wrap(wrap(leaf))
        let validator = LedgerArchiveValidation()
        _ = try validator.decode(child) // Cache a subtree with relative height 2.
        var root = child
        for _ in 0..<7 { root = try wrap(root) }
        // The cached child occurs at depth 7, so total depth is 9, not merely 7.
        #expect(throws:LedgerArchiveError.budgetExceeded) { try validator.decode(root) }
    }

}
