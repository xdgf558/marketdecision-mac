import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
@testable import Persistence

private let ledgerCashMap = LedgerCSVMapping(fields:[.timestamp:"time",.type:"type",.amount:"amount",.externalID:"external"])
private func ledgerCashCSV(_ amount:String = "100",_ id:String = "one",extra:String = "") -> Data {
    Data(("time,type,amount,external\n2026-01-02T00:00:00Z,DEPOSIT,\(amount),\(id)\n" + extra).utf8)
}
private func ledgerNewDatabase() throws -> DatabaseStore { try DatabaseStore(path:":memory:",purpose:.portfolioLedger) }
private func ledgerSeed(_ database:DatabaseStore,id:String = "A") async throws -> (LedgerStore,LedgerSnapshot) {
    let store = try LedgerStore(database:database)
    let empty = try await store.snapshot()
    return (store,try await store.createAccount(.init(id:id,name:"Synthetic account"),expectedRevision:empty.revision))
}
private func ledgerPlan(_ store:LedgerStore,_ revision:UUID,data:Data = ledgerCashCSV(),account:String = "A",excluded:Set<Int> = []) async throws -> LedgerImportPreview {
    try await store.previewCSV(data:data,accountID:account,sourceSystem:"synthetic-broker",mapping:ledgerCashMap,excludedRows:excluded,expectedRevision:revision)
}
private func ledgerRows(_ database:DatabaseStore) throws -> [[Row]] {
    try database.read { db in
        try ["ledger_metadata","ledger_accounts","ledger_sources","ledger_batches","ledger_events"].map {
            try Row.fetchAll(db,sql:"SELECT * FROM " + $0 + " ORDER BY 1")
        }
    }
}
private func ledgerTempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ledger-" + UUID().uuidString + ".sqlite") }
private func ledgerManualCash(_ id:String,amount:String = "10") throws -> LedgerEvent {
    LedgerEvent(id:id,accountID:"A",effectiveAt:try LedgerCSV.timestamp("2026-01-03T00:00:00Z"),
        source:.init(sourceSystem:"manual",externalTransactionID:id,evidence:"synthetic signed receipt"),
        payload:.cash(.init(kind:.deposit,amount:try Money(amount))))
}

@Suite("Ledger SQLite source, approval and transaction integrity")
struct LedgerPersistenceTests {
    @Test func ledgerPurposeRejectsResearchFilesAndKeepsOldBusinessBytes() async throws {
        let path = ledgerTempURL(); defer { try? FileManager.default.removeItem(at:path) }
        let business = try DatabaseStore(path:path.path)
        try business.transaction { db in try db.execute(sql:"CREATE TABLE retained_business(value BLOB); INSERT INTO retained_business(value) VALUES (x'0001ff')") }
        #expect(throws:MigrationError.incompatiblePurpose) { try LedgerStore(path:path.path) }
        #expect(throws:LedgerStoreError.incompatiblePurpose) { try LedgerStore(database:business) }
        #expect(try business.read { try Data.fetchOne($0,sql:"SELECT value FROM retained_business") } == Data([0,1,255]))
        let sec = try DatabaseStore(path:":memory:",purpose:.secResearch)
        #expect(throws:LedgerStoreError.incompatiblePurpose) { try LedgerStore(database:sec) }
        let independent = try ledgerNewDatabase()
        #expect(try independent.migrationVersions() == ["foundation.v1","portfolio-ledger.v1"])
        #expect(try independent.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'p1_%'") } == 0)
    }

    @Test func appendedLedgerMigrationKeepsEarlierFoundationRows() async throws {
        let path = ledgerTempURL(); defer { try? FileManager.default.removeItem(at:path) }
        do {
            let queue = try DatabaseQueue(path:path.path)
            try await queue.write { try $0.execute(sql:"PRAGMA application_id = 1296321585") }
            var migration = DatabaseMigrator()
            migration.registerMigration("foundation.v1") { db in
                try db.execute(sql:"CREATE TABLE retained_foundation(value TEXT); INSERT INTO retained_foundation(value) VALUES ('retained')")
            }
            try migration.migrate(queue)
        }
        let database = try DatabaseStore(path:path.path,purpose:.portfolioLedger)
        #expect(try database.read { try String.fetchOne($0,sql:"SELECT value FROM retained_foundation") } == "retained")
        let store = try LedgerStore(database:database)
        #expect(try await store.snapshot().events.isEmpty)
    }

    @Test func originalCSVMappingVersionsAndExplicitExclusionsSurviveReopen() async throws {
        let path = ledgerTempURL(); defer { try? FileManager.default.removeItem(at:path) }
        let database = try DatabaseStore(path:path.path,purpose:.portfolioLedger)
        let (store,initial) = try await ledgerSeed(database)
        let bytes = ledgerCashCSV(extra:"2026-01-02T00:01:00Z,DEPOSIT,invalid,excluded\n")
        let rejected = try await ledgerPlan(store,initial.revision,data:bytes)
        #expect(!rejected.canCommit); #expect(rejected.rows[1].disposition == .invalid)
        await store.cancel(planID:rejected.id)
        let accepted = try await ledgerPlan(store,initial.revision,data:bytes,excluded:[2])
        #expect(accepted.canCommit); #expect(accepted.rows[1].disposition == .excluded)
        let saved = try await store.commit(planID:accepted.id,expectedRevision:initial.revision)
        #expect(saved.state.cashByAccount["A"] == (try Money("100")))
        let source = try database.read { db in
            let row = try Row.fetchOne(db,sql:"SELECT raw_bytes,metadata_json FROM ledger_sources")
            return try #require(row)
        }
        #expect((source["raw_bytes"] as Data) == bytes)
        let metadata = try #require(JSONSerialization.jsonObject(with:source["metadata_json"] as Data) as? [String:Any])
        #expect(metadata["excludedRows"] as? [Int] == [2])
        #expect(metadata["engineVersion"] as? String == LedgerEngine.version)
        #expect(metadata["parametersVersion"] as? String == "PARAMETERS_V1")
        #expect(metadata["numericPolicyVersion"] as? String == Money.numericPolicyVersion)
        let reopened = try LedgerStore(path:path.path)
        #expect(try await reopened.snapshot() == saved)
    }

    @Test func externalIDsAreScopedByAccountAndSourceButNoIDsKeepTwoEqualRows() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let second = try await store.createAccount(.init(id:"B",name:"Other"),expectedRevision:initial.revision)
        let a = try await ledgerPlan(store,second.revision)
        let first = try await store.commit(planID:a.id,expectedRevision:second.revision)
        let b = try await ledgerPlan(store,first.revision,account:"B")
        let two = try await store.commit(planID:b.id,expectedRevision:first.revision)
        let other = try await store.previewCSV(data:ledgerCashCSV(),accountID:"A",sourceSystem:"other-broker",mapping:ledgerCashMap,excludedRows:[],expectedRevision:two.revision)
        let three = try await store.commit(planID:other.id,expectedRevision:two.revision)
        let duplicateRows = ledgerCashCSV("10","",extra:"2026-01-02T00:00:00Z,DEPOSIT,10,\n")
        let file = try await ledgerPlan(store,three.revision,data:duplicateRows)
        #expect(file.rows.map(\.disposition) == [.new,.new])
        let all = try await store.commit(planID:file.id,expectedRevision:three.revision)
        #expect(all.events.count == 5)
        #expect(all.state.cashByAccount["A"] == (try Money("220")))
        let repeated = try await ledgerPlan(store,all.revision,data:duplicateRows)
        #expect(repeated.rows.map(\.disposition) == [.duplicate,.duplicate])
        #expect(try await store.commit(planID:repeated.id,expectedRevision:all.revision) == all)
    }

    @Test func sameExternalContentAcrossFilesRetainsOriginalSourceAndChangedContentRequiresChoice() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let plan = try await ledgerPlan(store,initial.revision)
        let saved = try await store.commit(planID:plan.id,expectedRevision:initial.revision)
        let originalSource = try database.read { try String.fetchOne($0,sql:"SELECT source_id FROM ledger_events") }
        let extraFile = ledgerCashCSV(extra:"2026-01-02T00:01:00Z,DEPOSIT,2,new-two\n")
        let second = try await ledgerPlan(store,saved.revision,data:extraFile)
        #expect(second.rows.map(\.disposition) == [.duplicate,.new])
        let combined = try await store.commit(planID:second.id,expectedRevision:saved.revision)
        #expect(combined.events.count == 2)
        #expect(try database.read { try String.fetchOne($0,sql:"SELECT source_id FROM ledger_events WHERE event_id = ?",arguments:[saved.events[0].id]) } == originalSource)
        let conflict = try await ledgerPlan(store,combined.revision,data:ledgerCashCSV("999"))
        #expect(conflict.rows[0].disposition == .conflict); #expect(!conflict.canCommit)
        await #expect(throws:LedgerStoreError.invalidPlan) { try await store.commit(planID:conflict.id,expectedRevision:combined.revision) }
        let choice = try await ledgerPlan(store,combined.revision,data:ledgerCashCSV("999",extra:"2026-01-02T00:02:00Z,DEPOSIT,3,three\n"),excluded:[1])
        #expect(choice.rows.map(\.disposition) == [.excluded,.new])
        let chosen = try await store.commit(planID:choice.id,expectedRevision:combined.revision)
        #expect(chosen.state.cashByAccount["A"] == (try Money("105")))
    }

    @Test func cancelledPreviewAndFailedWholeBatchLeaveNoRowsAndFailureCanRetry() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let baseline = try ledgerRows(database)
        let cancelled = try await ledgerPlan(store,initial.revision)
        await store.cancel(planID:cancelled.id)
        await #expect(throws:LedgerStoreError.invalidPlan) { try await store.commit(planID:cancelled.id,expectedRevision:initial.revision) }
        #expect(try ledgerRows(database) == baseline)
        let retry = try await ledgerPlan(store,initial.revision,data:ledgerCashCSV(extra:"2026-01-02T00:01:00Z,DEPOSIT,2,two\n"))
        await store.injectFailureOnNextCommit()
        await #expect(throws:LedgerStoreError.injectedFailure) { try await store.commit(planID:retry.id,expectedRevision:initial.revision) }
        #expect(try ledgerRows(database) == baseline)
        let saved = try await store.commit(planID:retry.id,expectedRevision:initial.revision)
        #expect(saved.events.count == 2)
        #expect(saved.state.cashByAccount["A"] == (try Money("102")))
    }

    @Test func crossProcessRevisionCASRejectsOldApprovalAndReopenDoesNotRestoreTokens() async throws {
        let path = ledgerTempURL(); defer { try? FileManager.default.removeItem(at:path) }
        let database = try DatabaseStore(path:path.path,purpose:.portfolioLedger)
        let (first,initial) = try await ledgerSeed(database), second = try LedgerStore(path:path.path)
        let p1 = try await ledgerPlan(first,initial.revision), p2 = try await ledgerPlan(second,initial.revision,data:ledgerCashCSV("2","two"))
        let saved = try await first.commit(planID:p1.id,expectedRevision:initial.revision)
        await #expect(throws:LedgerStoreError.stalePlan) { try await second.commit(planID:p2.id,expectedRevision:initial.revision) }
        await #expect(throws:LedgerStoreError.invalidPlan) { try await second.commit(planID:p2.id,expectedRevision:initial.revision) }
        #expect(try await second.snapshot() == saved)
        let waiting = try await ledgerPlan(first,saved.revision,data:ledgerCashCSV("3","three"))
        let reopened = try LedgerStore(path:path.path)
        await #expect(throws:LedgerStoreError.invalidPlan) { try await reopened.commit(planID:waiting.id,expectedRevision:saved.revision) }
        #expect(try await reopened.snapshot() == saved)
    }

    @Test func cancelledTaskCannotCommitAnApprovedPlan() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let plan = try await ledgerPlan(store,initial.revision)
        let gate = LedgerTestCancellationGate()
        let task = Task {
            await gate.wait()
            return try await store.commit(planID:plan.id,expectedRevision:initial.revision)
        }
        await gate.started(); task.cancel(); await gate.release()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(try await store.snapshot() == initial)
        #expect(try await store.commit(planID:plan.id,expectedRevision:initial.revision).events.count == 1)
    }

    @Test func everyReadAndDuplicatePreviewRejectsCorruptedRawHashSourceAndIndexes() async throws {
        for mutation in [
            "UPDATE ledger_sources SET raw_bytes = x'00'",
            "UPDATE ledger_sources SET metadata_json = x'7b7d'",
            "UPDATE ledger_events SET identity_key = 'wrong'",
            "UPDATE ledger_events SET effective_at_json = x'30'",
            "UPDATE ledger_events SET comparison_hash = replace(comparison_hash, substr(comparison_hash,1,1), 'z')",
            "UPDATE ledger_events SET event_json = x'7b7d'",
            "UPDATE ledger_events SET audit_sequence = 9",
            "DELETE FROM ledger_events",
        ] {
            let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
            let plan = try await ledgerPlan(store,initial.revision)
            let saved = try await store.commit(planID:plan.id,expectedRevision:initial.revision)
            try database.transaction { try $0.execute(sql:mutation) }
            await #expect(throws:LedgerStoreError.corruptedStorage) { try await store.snapshot() }
            await #expect(throws:LedgerStoreError.corruptedStorage) { try await ledgerPlan(store,saved.revision) }
        }
    }

    @Test func wrongButForeignKeyValidSourceReferenceFailsBeforeDedup() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let one = try await ledgerPlan(store,initial.revision)
        let first = try await store.commit(planID:one.id,expectedRevision:initial.revision)
        let two = try await ledgerPlan(store,first.revision,data:ledgerCashCSV("2","two"))
        let saved = try await store.commit(planID:two.id,expectedRevision:first.revision)
        try database.transaction { db in
            let ids = try String.fetchAll(db,sql:"SELECT source_id FROM ledger_sources ORDER BY source_id")
            try db.execute(sql:"UPDATE ledger_events SET source_id = ? WHERE source_id = ?",arguments:[ids[0],ids[1]])
            #expect(try Row.fetchAll(db,sql:"PRAGMA foreign_key_check").isEmpty)
        }
        await #expect(throws:LedgerStoreError.corruptedStorage) { try await store.snapshot() }
        await #expect(throws:LedgerStoreError.corruptedStorage) { try await ledgerPlan(store,saved.revision) }
    }

    @Test func correctionAppendsReversalAndReplacementAndKeepsOriginalBytes() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let original = try ledgerManualCash("deposit",amount:"10")
        let plan = try await store.previewManual(events:[original],expectedRevision:initial.revision)
        let saved = try await store.commit(planID:plan.id,expectedRevision:initial.revision)
        let bytes = try database.read { try Data.fetchOne($0,sql:"SELECT event_json FROM ledger_events WHERE event_id = 'deposit'") }
        let replacement = try ledgerManualCash("deposit-corrected",amount:"12")
        let fix = try await store.previewCorrection(originalEventID:"deposit",replacement:replacement,reason:"Receipt corrected",expectedRevision:saved.revision)
        #expect(fix.canCommit)
        let corrected = try await store.commit(planID:fix.id,expectedRevision:saved.revision)
        #expect(corrected.events.count == 3)
        #expect(corrected.state.cashByAccount["A"] == (try Money("12")))
        #expect(corrected.state.reversedEventIDs == ["deposit"])
        #expect(try database.read { try Data.fetchOne($0,sql:"SELECT event_json FROM ledger_events WHERE event_id = 'deposit'") } == bytes)
        #expect(try await store.snapshot() == corrected)
    }

    @Test func aValidlyHashedBatchCannotClaimAnotherBatchesNewEvent() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let one = try await ledgerPlan(store,initial.revision)
        let first = try await store.commit(planID:one.id,expectedRevision:initial.revision)
        let duplicateFile = ledgerCashCSV(extra:"2026-01-02T00:01:00Z,DEPOSIT,2,two\n")
        let two = try await ledgerPlan(store,first.revision,data:duplicateFile)
        _ = try await store.commit(planID:two.id,expectedRevision:first.revision)
        try database.transaction { db in
            let stored = try Data.fetchOne(db,sql:"SELECT batch_json FROM ledger_batches WHERE batch_id = ?",arguments:[two.id.uuidString.lowercased()])
            let bytes = try #require(stored)
            var object = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            var rows = try #require(object["rows"] as? [[String:Any]])
            rows[0]["disposition"] = "new"; object["rows"] = rows
            let changed = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
            try db.execute(sql:"UPDATE ledger_batches SET batch_json = ?,content_hash = ? WHERE batch_id = ?",arguments:[changed,LedgerCSV.hash(changed),two.id.uuidString.lowercased()])
        }
        await #expect(throws:LedgerStoreError.corruptedStorage) { try await store.snapshot() }
    }

    @Test func correctingAWrongFutureDatePreservesChosenEconomicDateAndActualAuditTime() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let original = LedgerEvent(id:"wrong-future",accountID:"A",effectiveAt:try LedgerCSV.timestamp("2099-01-02T00:00:00Z"),
            source:.init(sourceSystem:"manual",externalTransactionID:"wrong-future",evidence:"original receipt"),
            payload:.cash(.init(kind:.deposit,amount:try Money("10"))))
        let originalPlan = try await store.previewManual(events:[original],expectedRevision:initial.revision)
        let saved = try await store.commit(planID:originalPlan.id,expectedRevision:initial.revision)
        let corrected = try ledgerManualCash("fixed-date")
        let plan = try await store.previewCorrection(originalEventID:original.id,replacement:corrected,reason:"Wrong year entered",expectedRevision:saved.revision)
        #expect(plan.canCommit)
        let result = try await store.commit(planID:plan.id,expectedRevision:saved.revision)
        #expect(result.events.last?.effectiveAt == corrected.effectiveAt)
        #expect(result.events[1].effectiveAt < original.effectiveAt)
        #expect(result.state.activeEventIDs == [corrected.id])
    }

    @Test func correctionCannotEraseLotsRequiredByExistingTransactions() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let t = try LedgerCSV.timestamp("2026-01-02T00:00:00Z")
        func trade(_ id:String,_ qty:String,_ side:LedgerSide,_ when:Date) throws -> LedgerEvent {
            LedgerEvent(id:id,accountID:"A",effectiveAt:when,source:.init(sourceSystem:"manual",externalTransactionID:id,evidence:"receipt"),
                payload:.trade(.init(instrument:.equity(.init(id:"X",symbol:"X")),side:side,effect:side == .buy ? .open:.close,
                    quantity:try Money(qty),unitPrice:try Money("10"),fee:try Money("0"),openingLotID:side == .buy ? id + "-lot":nil)))
        }
        let events = try [trade("buy","2",.buy,t),trade("sell","2",.sell,t.addingTimeInterval(1))]
        let p = try await store.previewManual(events:events,expectedRevision:initial.revision)
        let saved = try await store.commit(planID:p.id,expectedRevision:initial.revision)
        let correction = try await store.previewCorrection(originalEventID:"buy",replacement:trade("smaller","1",.buy,t),reason:"Synthetic correction",expectedRevision:saved.revision)
        #expect(!correction.canCommit)
        await #expect(throws:LedgerStoreError.invalidPlan) { try await store.commit(planID:correction.id,expectedRevision:saved.revision) }
        #expect(try await store.snapshot() == saved)
    }

    @Test func batchReversalKeepsAuditAndCannotRemoveOpeningLotsWithLaterSales() async throws {
        let database = try ledgerNewDatabase(), (store,initial) = try await ledgerSeed(database)
        let cash = try await ledgerPlan(store,initial.revision)
        let saved = try await store.commit(planID:cash.id,expectedRevision:initial.revision)
        let batch = try #require(saved.batches.first)
        let reverse = try await store.previewBatchReversal(batchID:batch.id,effectiveAt:LedgerCSV.timestamp("2026-01-03T00:00:00Z"),reason:"User cancelled synthetic batch",expectedRevision:saved.revision)
        #expect(reverse.canCommit)
        let reversed = try await store.commit(planID:reverse.id,expectedRevision:saved.revision)
        #expect(reversed.events.count == 2); #expect(reversed.state.cashByAccount["A"] == (try Money("0")))
        #expect(reversed.batches.contains(batch))

        let buyCSV = Data("timestamp,type,symbol,quantity,unit_price,fee,amount,external_id\n2026-01-04T00:00:00Z,BUY_STOCK,X,2,10,0,,buy\n".utf8)
        let buy = try await store.previewCSV(data:buyCSV,accountID:"A",sourceSystem:"broker",mapping:.standard,excludedRows:[],expectedRevision:reversed.revision)
        let bought = try await store.commit(planID:buy.id,expectedRevision:reversed.revision)
        let sellCSV = Data("timestamp,type,symbol,quantity,unit_price,fee,amount,external_id\n2026-01-05T00:00:00Z,SELL_STOCK,X,2,11,0,,sell\n".utf8)
        let sell = try await store.previewCSV(data:sellCSV,accountID:"A",sourceSystem:"broker",mapping:.standard,excludedRows:[],expectedRevision:bought.revision)
        let sold = try await store.commit(planID:sell.id,expectedRevision:bought.revision)
        let blocked = try await store.previewBatchReversal(batchID:buy.id.uuidString.lowercased(),effectiveAt:LedgerCSV.timestamp("2026-01-06T00:00:00Z"),reason:"Reverse opening batch",expectedRevision:sold.revision)
        #expect(!blocked.canCommit)
        await #expect(throws:LedgerStoreError.invalidPlan) { try await store.commit(planID:blocked.id,expectedRevision:sold.revision) }
        #expect(try await store.snapshot() == sold)
    }
}

private actor LedgerTestCancellationGate {
    private var isStarted = false
    private var continuation:CheckedContinuation<Void,Never>?
    private var startWaiters:[CheckedContinuation<Void,Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; isStarted = true
            for waiter in startWaiters { waiter.resume() }; startWaiters.removeAll()
        }
    }
    func started() async {
        if isStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
