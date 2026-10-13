import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
@testable import Persistence

private func ppDate(_ value:String) throws -> Date { try LedgerCSV.timestamp(value) }
private func ppEvidence(_ id:String) throws -> PerformanceEvidence {
    .init(id:id,source:"synthetic-local-evidence",kind:.synthetic,availableAt:try ppDate("2026-01-01T00:00:00.0004Z"),
          reference:"fixture/" + id,rawDocument:Data(("synthetic raw bytes: " + id).utf8))
}
private func ppRequest(account:String = "A",calculatedAt:String = "2026-01-07T00:00:00.0006Z") throws -> PerformanceRequest {
    let dates = ["2026-01-05","2026-01-06"]
    let days = try dates.map { day in
        let close = try ppDate(day + "T21:00:00Z")
        return PerformanceDayInput(day:day,valuationAt:close,
            sessions:[.init(id:"session/" + day,instrumentID:"SYN",opensAt:try ppDate(day + "T14:30:00Z"),closesAt:close,evidence:try ppEvidence("session/" + day))],
            prices:[.init(id:"quote/" + day,instrumentID:"SYN",sessionID:"session/" + day,quoteAt:close,
                bid:try Money("10"),ask:try Money("12"),quality:[.synthetic],evidence:try ppEvidence("quote/" + day))])
    }
    return PerformanceRequest(accountID:account,calculatedAt:try ppDate(calculatedAt),
        calendar:.init(tradingDays:dates,evidence:try ppEvidence("calendar")),days:days,
        accruals:[.init(id:"receivable",kind:.interestReceivable,recognizedAt:try ppDate("2026-01-05T12:00:00Z"),amount:try Money("5"),settlements:[],evidence:try ppEvidence("accrual"))],
        rateCurves:[.init(id:"rate",source:.explicitUserConstant,observationAt:try ppDate("2026-01-01T00:00:00Z"),
            validFrom:try ppDate("2026-01-01T00:00:00Z"),validThrough:try ppDate("2026-01-31T23:59:59Z"),
            points:[.init(termYears:2,annualRate:try Money("4"),unit:.annualPercent)],evidence:try ppEvidence("rate"))],
        benchmark:.init(points:try dates.enumerated().map { .init(day:$0.element,totalReturnIndex:try Money(String(100 + $0.offset)),evidence:try ppEvidence("benchmark/" + $0.element)) },isTotalReturn:true),
        externalFlowsComplete:true,flowCompletenessEvidence:try ppEvidence("flows"))
}
private func ppEvent(_ id:String = "deposit",amount:String = "100") throws -> LedgerEvent {
    .init(id:id,accountID:"A",effectiveAt:try ppDate("2026-01-02T00:00:00Z"),
        source:.init(sourceSystem:"synthetic-manual",externalTransactionID:id,evidence:"synthetic cash receipt " + id),
        payload:.cash(.init(kind:.deposit,amount:try Money(amount))))
}
private func ppSeed(_ database:DatabaseStore) async throws -> (LedgerStore,PerformanceStore) {
    let ledger = try LedgerStore(database:database), initial = try await ledger.snapshot()
    let account = try await ledger.createAccount(.init(id:"A",name:"Synthetic performance account"),expectedRevision:initial.revision)
    let preview = try await ledger.previewManual(events:[try ppEvent()],expectedRevision:account.revision)
    _ = try await ledger.commit(planID:preview.id,expectedRevision:account.revision)
    return (ledger,try await ledger.makePerformanceStore())
}
private func ppPrepare(_ store:PerformanceStore,request:PerformanceRequest? = nil,raw:Data? = nil) async throws -> PerformancePreview {
    let context = try await store.context()
    return try await store.prepare(request:try request ?? ppRequest(),rawRequest:raw,
        expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision)
}
private func ppCommit(_ store:PerformanceStore,_ preview:PerformancePreview) async throws -> SavedPerformanceReport {
    try await store.commit(planID:preview.id,expectedLedgerRevision:preview.ledgerRevision,expectedPerformanceRevision:preview.performanceRevision)
}
private func ppRows(_ database:DatabaseStore) throws -> [[Row]] {
    try database.read { db in try ["performance_metadata","performance_inputs","performance_report_catalog","performance_report_documents"].map {
        try Row.fetchAll(db,sql:"SELECT * FROM " + $0 + " ORDER BY 1")
    } }
}
private func ppPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("performance-" + UUID().uuidString + ".sqlite") }

@Suite("Frozen portfolio performance SQLite integrity")
struct PerformancePersistenceTests {
    @Test func performanceMigrationPreservesExistingLedgerAndRejectsOtherDatabasePurposes() async throws {
        let path = ppPath(); defer { try? FileManager.default.removeItem(at:path) }
        let database = try DatabaseStore(path:path.path,purpose:.portfolioLedger)
        let (ledger,_) = try await ppSeed(database), before = try await ledger.snapshot()
        let original = try database.read { db in try ["ledger_metadata","ledger_accounts","ledger_sources","ledger_batches","ledger_events"].map { try Row.fetchAll(db,sql:"SELECT * FROM " + $0 + " ORDER BY 1") } }
        // Recreate the exact pre-performance schema/history while retaining real ledger bytes.
        try database.transaction { db in
            try db.execute(sql:"DROP TABLE ledger_archive_batch_links; DROP TABLE ledger_archive_origins; DROP TABLE ledger_archive_conflicts")
            try db.execute(sql:"DROP TABLE performance_report_documents; DROP TABLE performance_report_catalog; DROP TABLE performance_inputs; DROP TABLE performance_metadata")
            try db.execute(sql:"DELETE FROM grdb_migrations WHERE identifier IN ('portfolio-ledger.performance.v1','portfolio-ledger.archive.v1')")
        }
        let reopened = try DatabaseStore(path:path.path,purpose:.portfolioLedger)
        let after = try LedgerStore(database:reopened)
        #expect(try await after.snapshot() == before)
        #expect(try reopened.read { db in try ["ledger_metadata","ledger_accounts","ledger_sources","ledger_batches","ledger_events"].map { try Row.fetchAll(db,sql:"SELECT * FROM " + $0 + " ORDER BY 1") } } == original)
        #expect(try reopened.migrationVersions() == ["foundation.v1","portfolio-ledger.archive.v1","portfolio-ledger.performance.v1","portfolio-ledger.v1"])
        #expect(try reopened.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'p1_%'") } == 0)
        for purpose in [DatabasePurpose.business,.offlineIssuerResearch,.secResearch] {
            let foreign = try DatabaseStore(path:":memory:",purpose:purpose)
            #expect(throws:PerformanceStoreError.incompatiblePurpose) { try PerformanceStore(database:foreign) }
            #expect(try foreign.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'performance_%'") } == 0)
            #expect(throws:MigrationError.incompatiblePurpose) { try DatabaseStore(path:path.path,purpose:purpose) }
        }
    }

    @Test func originalRequestEvidenceAndFrozenLedgerReplayAfterReopenAndLedgerChanges() async throws {
        let path = ppPath(); defer { try? FileManager.default.removeItem(at:path) }
        let database = try DatabaseStore(path:path.path,purpose:.portfolioLedger), (ledger,store) = try await ppSeed(database)
        let request = try ppRequest(), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let raw = try encoder.encode(request)
        let preview = try await ppPrepare(store,request:request,raw:raw), saved = try await ppCommit(store,preview)
        #expect(saved.replayMatched); #expect(saved.isCurrentLedger)
        #expect(saved.report.input.request == request)
        #expect(saved.report.daily.map(\.nav) == [try Money("105"),try Money("105")])
        #expect(try database.read { try Data.fetchOne($0,sql:"SELECT request_json FROM performance_inputs") } == raw)
        #expect(try database.read { try String.fetchOne($0,sql:"SELECT request_hash FROM performance_inputs") } == LedgerCSV.hash(raw))
        let fields = try database.read { try Row.fetchOne($0,sql:"SELECT engine_version,parameters_version,numeric_policy_version FROM performance_inputs") }
        #expect(fields?["engine_version"] as String? == PerformanceEngine.version)
        #expect(fields?["parameters_version"] as String? == "PARAMETERS_V1")
        #expect(fields?["numeric_policy_version"] as String? == Money.numericPolicyVersion)
        let context = try await ledger.snapshot(), edit = try await ledger.previewManual(events:[try ppEvent("later",amount:"7")],expectedRevision:context.revision)
        _ = try await ledger.commit(planID:edit.id,expectedRevision:context.revision)
        let reopened = try PerformanceStore(path:path.path), old = try await reopened.open(id:saved.id)
        #expect(old.report == saved.report); #expect(old.replayMatched); #expect(!old.isCurrentLedger)
        #expect(old.report.input.request.calculatedAt.timeIntervalSinceReferenceDate.bitPattern == request.calculatedAt.timeIntervalSinceReferenceDate.bitPattern)
        #expect(old.report.input.request.calendar.evidence.availableAt.timeIntervalSinceReferenceDate.bitPattern == request.calendar.evidence.availableAt.timeIntervalSinceReferenceDate.bitPattern)
        let listed = try await reopened.reports(accountID:"A")
        #expect(listed.count == 1); #expect(listed[0].startDate == "2026-01-05"); #expect(listed[0].endDate == "2026-01-06")
        #expect(!listed[0].isCurrentLedger); #expect(try await reopened.reports(accountID:"other").isEmpty)
        // Opening a historical calculation uses its frozen ledger, not unrelated current rows.
        try database.transaction { try $0.execute(sql:"UPDATE ledger_sources SET raw_bytes = x'00'") }
        #expect(try await reopened.open(id:saved.id).report == saved.report)
        await #expect(throws:LedgerStoreError.corruptedStorage) { try await reopened.context() }
    }

    @Test func identicalInputDeduplicatesWithoutChangingRevisionButDifferentRawBytesRemainDistinct() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
        let first = try await ppCommit(store,ppPrepare(store)), rows = try ppRows(database)
        let duplicate = try await ppPrepare(store), second = try await ppCommit(store,duplicate)
        #expect(second.id == first.id); #expect(try ppRows(database) == rows)
        let request = try ppRequest(), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        let changedRaw = try await ppPrepare(store,request:request,raw:encoder.encode(request))
        #expect(changedRaw.inputHash != first.inputHash)
        let distinct = try await ppCommit(store,changedRaw)
        #expect(distinct.id != first.id); #expect(distinct.report == first.report)
        #expect(try await store.reports(accountID:"A").count == 2)
    }

    @Test func completeCommitFailureRollsBackAndSameApprovalCanRetry() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (ledger,store) = try await ppSeed(database)
        let baseline = try ppRows(database), ledgerBefore = try await ledger.snapshot(), plan = try await ppPrepare(store)
        await store.injectFailureOnNextCommit()
        await #expect(throws:PerformanceStoreError.injectedFailure) { try await ppCommit(store,plan) }
        #expect(try ppRows(database) == baseline); #expect(try await ledger.snapshot() == ledgerBefore)
        let saved = try await ppCommit(store,plan)
        #expect(saved.replayMatched); #expect(try await ledger.snapshot() == ledgerBefore)
        #expect(try await store.reports(accountID:"A").count == 1)
        await #expect(throws:PerformanceStoreError.invalidPlan) { try await ppCommit(store,plan) }
    }

    @Test func twoConnectionCASChecksPerformanceAndLedgerRevisionsAndConsumesStalePlan() async throws {
        for changeLedger in [false,true] {
            let path = ppPath(); defer { try? FileManager.default.removeItem(at:path) }
            let database = try DatabaseStore(path:path.path,purpose:.portfolioLedger), (ledger,first) = try await ppSeed(database)
            let second = try PerformanceStore(path:path.path), stale = try await ppPrepare(second)
            if changeLedger {
                let context = try await ledger.snapshot(), plan = try await ledger.previewManual(events:[try ppEvent("later",amount:"2")],expectedRevision:context.revision)
                _ = try await ledger.commit(planID:plan.id,expectedRevision:context.revision)
            } else { _ = try await ppCommit(first,ppPrepare(first)) }
            let afterExternal = try ppRows(database)
            await #expect(throws:PerformanceStoreError.stalePlan) { try await ppCommit(second,stale) }
            await #expect(throws:PerformanceStoreError.invalidPlan) { try await ppCommit(second,stale) }
            #expect(try ppRows(database) == afterExternal)
        }
    }

    @Test func calculationCannotRefreshBaselineAfterConcurrentLedgerOrReportCommit() async throws {
        for changeLedger in [false,true] {
            let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (ledger,other) = try await ppSeed(database)
            let gate = PerformancePersistenceGate(), store = try PerformanceStore(database:database,preparationCheckpoint:{ await gate.pause() })
            let context = try await store.context(), request = try ppRequest()
            let task = Task { try await store.prepare(request:request,rawRequest:nil,expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision) }
            await gate.arrived()
            if changeLedger {
                let plan = try await ledger.previewManual(events:[try ppEvent("later",amount:"1")],expectedRevision:context.ledger.revision)
                _ = try await ledger.commit(planID:plan.id,expectedRevision:context.ledger.revision)
            } else { _ = try await ppCommit(other,ppPrepare(other)) }
            await gate.release()
            await #expect(throws:PerformanceStoreError.stalePlan) { try await task.value }
        }
    }

    @Test func explicitCancellationRestartAndTaskCancellationHaveSeparateApprovalSemantics() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
        let baseline = try ppRows(database), cancelled = try await ppPrepare(store)
        await store.cancel(planID:cancelled.id)
        await #expect(throws:PerformanceStoreError.invalidPlan) { try await ppCommit(store,cancelled) }
        let pending = try await ppPrepare(store), restarted = try PerformanceStore(database:database)
        await #expect(throws:PerformanceStoreError.invalidPlan) { try await ppCommit(restarted,pending) }
        let gate = PerformancePersistenceGate()
        let task = Task { await gate.pause(); return try await ppCommit(store,pending) }
        await gate.arrived(); task.cancel(); await gate.release()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(try ppRows(database) == baseline)
        #expect(try await ppCommit(store,pending).replayMatched)
    }

    @Test func cancelledPreparationPublishesNoPlanAndCommitsNothing() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,_) = try await ppSeed(database)
        let gate = PerformancePersistenceGate(), store = try PerformanceStore(database:database,preparationCheckpoint:{ await gate.pause() })
        let baseline = try ppRows(database), context = try await store.context(), request = try ppRequest()
        let task = Task { try await store.prepare(request:request,rawRequest:nil,expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision) }
        await gate.arrived(); task.cancel(); await gate.release()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(try ppRows(database) == baseline)
    }

    @Test func openAndDuplicateCommitValidateEveryStoredInputSourceAndIndex() async throws {
        let mutations = [
            "UPDATE performance_inputs SET input_json = x'7b7d'",
            "UPDATE performance_inputs SET request_json = x'7b7d'",
            "UPDATE performance_inputs SET request_hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'",
            "UPDATE performance_inputs SET ledger_revision = '00000000-0000-0000-0000-000000000000'",
            "UPDATE performance_inputs SET engine_version = 'future-engine'",
            "UPDATE performance_inputs SET parameters_version = 'future-parameters'",
            "UPDATE performance_inputs SET numeric_policy_version = 'future-numeric'",
            "UPDATE performance_report_catalog SET ledger_revision = '00000000-0000-0000-0000-000000000000'",
            "UPDATE performance_report_catalog SET report_hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'",
            "UPDATE performance_report_catalog SET summary_json = x'7b7d'",
            "UPDATE performance_report_documents SET report_json = x'7b7d'",
            "DELETE FROM performance_report_documents"
        ]
        for mutation in mutations {
            let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
            let saved = try await ppCommit(store,ppPrepare(store)), duplicate = try await ppPrepare(store)
            try database.transaction { try $0.execute(sql:mutation) }
            let corrupted = try ppRows(database)
            await #expect(throws:PerformanceStoreError.corruptedStorage) { try await store.open(id:saved.id) }
            await #expect(throws:PerformanceStoreError.corruptedStorage) { try await ppCommit(store,duplicate) }
            #expect(try ppRows(database) == corrupted)
        }
    }

    @Test func matchingHashesCannotMakeAlteredCachedNumbersPassFrozenInputReplay() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
        let saved = try await ppCommit(store,ppPrepare(store)), duplicate = try await ppPrepare(store)
        try database.transaction { db in
            let body = try #require(try Data.fetchOne(db,sql:"SELECT report_json FROM performance_report_documents"))
            var report = try #require(JSONSerialization.jsonObject(with:body) as? [String:Any])
            var daily = try #require(report["daily"] as? [[String:Any]])
            #expect(daily.count == 2)
            daily[0]["nav"] = "999"; report["daily"] = daily
            let changed = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
            let reportHash = LedgerCSV.hash(changed)
            let summaryBytes = try #require(try Data.fetchOne(db,sql:"SELECT summary_json FROM performance_report_catalog"))
            var summary = try #require(JSONSerialization.jsonObject(with:summaryBytes) as? [String:Any])
            summary["reportHash"] = reportHash
            let changedSummary = try JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys])
            try db.execute(sql:"UPDATE performance_report_documents SET report_json = ?",arguments:[changed])
            try db.execute(sql:"UPDATE performance_report_catalog SET report_hash = ?, summary_hash = ?, summary_json = ?",
                arguments:[reportHash,LedgerCSV.hash(changedSummary),changedSummary])
        }
        await #expect(throws:PerformanceStoreError.corruptedStorage) { try await store.open(id:saved.id) }
        await #expect(throws:PerformanceStoreError.corruptedStorage) { try await ppCommit(store,duplicate) }
    }

    @Test func summaryListingNeverAdvertisesBodyReplayAndOpeningRejectsCorruptBody() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
        let saved = try await ppCommit(store,ppPrepare(store)), before = try await store.reports(accountID:"A")
        try database.transaction { try $0.execute(sql:"UPDATE performance_report_documents SET report_json = x'7b7d'") }
        #expect(try await store.reports(accountID:"A") == before)
        await #expect(throws:PerformanceStoreError.corruptedStorage) { try await store.open(id:saved.id) }
    }

    @Test func mismatchedRawRequestBadMetadataAndChangedLedgerBytesFailClosed() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
        let baseline = try ppRows(database), context = try await store.context(), request = try ppRequest()
        let wrongRaw = try JSONEncoder().encode(ppRequest(account:"other"))
        await #expect(throws:PerformanceStoreError.invalidInput) {
            try await store.prepare(request:request,rawRequest:wrongRaw,expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision)
        }
        #expect(try ppRows(database) == baseline)
        let plan = try await ppPrepare(store)
        try database.transaction { try $0.execute(sql:"UPDATE ledger_sources SET raw_bytes = x'00'") }
        await #expect(throws:LedgerStoreError.corruptedStorage) { try await ppCommit(store,plan) }
        #expect(try ppRows(database) == baseline)
        try database.transaction { try $0.execute(sql:"UPDATE performance_metadata SET revision = 'malformed'") }
        await #expect(throws:PerformanceStoreError.corruptedStorage) { try await ppCommit(store,plan) }
    }

    @Test func rawRequestLimitRejectsBeforeCalculationAndLeavesNoPartialRows() async throws {
        let database = try DatabaseStore(path:":memory:",purpose:.portfolioLedger), (_,store) = try await ppSeed(database)
        let baseline = try ppRows(database), context = try await store.context(), request = try ppRequest()
        await #expect(throws:PerformanceStoreError.budgetExceeded) {
            try await store.prepare(request:request,rawRequest:Data(repeating:32,count:PerformanceStore.maximumRequestBytes + 1),
                expectedLedgerRevision:context.ledger.revision,expectedPerformanceRevision:context.revision)
        }
        #expect(try ppRows(database) == baseline)
    }
}

/// Explicit arrival/release handshake; no elapsed timeout permits the operation to continue.
private actor PerformancePersistenceGate {
    private var entered = false
    private var released = false
    private var waiting:CheckedContinuation<Void,Never>?
    private var arrivalWaiters:[CheckedContinuation<Void,Never>] = []
    func pause() async {
        entered = true
        arrivalWaiters.forEach { $0.resume() }; arrivalWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func arrived() async {
        if entered { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
