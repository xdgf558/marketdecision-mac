import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

private struct OfflineArchiveFixture {
    let db: DatabaseStore
    let store: OfflineIssuerResearchStore
    init(path: String = ":memory:") throws {
        db = try DatabaseStore(path: path, purpose: .offlineIssuerResearch)
        store = try OfflineIssuerResearchStore(database: db)
    }
}
private func offlineApproval(_ plan: OfflineIssuerRestorePlan) -> PlanApproval {
    .init(planID: plan.id, digest: plan.digest)
}
private func offlineTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("offline-issuer-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

@Suite struct OfflineIssuerArchiveTests {
    @Test(arguments: ["AAPL", "MSFT", "META", "AMZN", "NVDA", "COST", "WMT", "KO", "JPM", "BRK.B"])
    func tenIssuerArchivesReopenAndExplicitlyRecompute(ticker: String) async throws {
        let directory = try offlineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try OfflineArchiveFixture()
        let document = try await offlineIssuerDocument(ticker)
        try await source.store.save(document, expectedRevision: source.store.writeRevision())
        let bytes = try await source.store.exportBackup()
        let path = directory.appendingPathComponent("restored.sqlite").path
        do {
            let target = try OfflineArchiveFixture(path: path)
            let plan = try await target.store.prepareRestore(bytes, mode: .replace, expectedRevision: target.store.writeRevision())
            #expect(try await target.store.savedResearch().isEmpty)
            let commit = try await target.store.commit(offlineApproval(plan))
            #expect(commit.credentialAction == .untouched)
        }
        // Reopen a different connection; only frozen bytes remain available to the replay.
        let reopened = try OfflineArchiveFixture(path: path)
        let records = try await reopened.store.savedResearch()
        let restored = try #require(records.count == 1 ? records.first?.document : nil)
        #expect(try ResearchDocument.encoded(restored) == ResearchDocument.encoded(document))
        let replay = try await restored.recompute()
        #expect(try ResearchDocument.encoded(replay.base) == ResearchDocument.encoded(document.baseReport))
        #expect(try ResearchDocument.encoded(replay.growth) == ResearchDocument.encoded(document.growthReport))
        #expect(try ResearchDocument.encoded(replay.completion) == ResearchDocument.encoded(document.completionReport))
        #expect(try reopened.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test func repeatedMergeAndRebackupPreserveDistinctNamespaces() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        let a = try await offlineIssuerDocument("MSFT"), b = try await offlineIssuerDocument("WMT")
        try await source.store.save(a, expectedRevision: source.store.writeRevision())
        try await target.store.save(b, expectedRevision: target.store.writeRevision())
        let archive = try await source.store.exportBackup()
        for _ in 0..<2 {
            let plan = try await target.store.prepareRestore(archive, mode: .merge, expectedRevision: target.store.writeRevision())
            _ = try await target.store.commit(offlineApproval(plan))
        }
        let records = try await target.store.savedResearch()
        #expect(records.count == 2)
        #expect(Set(records.map(\.address.namespace)).count == 2)
        let rebackup = try await target.store.exportBackup(), third = try OfflineArchiveFixture()
        let plan = try await third.store.prepareRestore(rebackup, mode: .replace, expectedRevision: third.store.writeRevision())
        _ = try await third.store.commit(offlineApproval(plan))
        #expect(try await third.store.savedResearch().count == 2)
        let repeated = try await third.store.prepareRestore(archive, mode: .merge, expectedRevision: third.store.writeRevision())
        _ = try await third.store.commit(offlineApproval(repeated))
        #expect(try await third.store.savedResearch().count == 2)
    }

    @Test func conflictingImmutableIdentityRetainsBothVersionsAfterRebackup() async throws {
        let first = try await offlineIssuerDocument("MSFT"), second = try await offlineIssuerDocument("WMT")
        var encoded = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(second)) as? [String: Any])
        encoded["id"] = first.id.uuidString
        let collision = try JSONDecoder().decode(OfflineIssuerResearchDocument.self,
            from: JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]))
        try collision.validate()
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        try await source.store.save(first, expectedRevision: source.store.writeRevision())
        try await target.store.save(collision, expectedRevision: target.store.writeRevision())
        let archive = try await source.store.exportBackup()
        for _ in 0..<2 {
            let plan = try await target.store.prepareRestore(archive, mode: .merge, expectedRevision: target.store.writeRevision())
            _ = try await target.store.commit(offlineApproval(plan))
        }
        let records = try await target.store.savedResearch()
        #expect(records.count == 2 && Set(records.map(\.address.namespace)).count == 2)
        #expect(Set(records.map(\.document.id)).count == 1)
        #expect(Set(records.map { digest($0.document.excerptData) }).count == 2)
        let rebackup = try await target.store.exportBackup(), third = try OfflineArchiveFixture()
        let plan = try await third.store.prepareRestore(rebackup, mode: .replace, expectedRevision: third.store.writeRevision())
        _ = try await third.store.commit(offlineApproval(plan))
        #expect(try await third.store.savedResearch().count == 2)
    }

    @Test func failedTransactionKeepsApprovalRetryableAndStaleApprovalIsConsumed() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        try await source.store.save(offlineIssuerDocument("MSFT"), expectedRevision: source.store.writeRevision())
        try await target.store.save(offlineIssuerDocument("WMT"), expectedRevision: target.store.writeRevision())
        let before = try await target.store.exportBackup(), revision = try await target.store.writeRevision()
        let archive = try await source.store.exportBackup()
        let plan = try await target.store.prepareRestore(archive, mode: .replace, expectedRevision: revision)
        try target.db.transaction { try $0.execute(sql: "CREATE TRIGGER fail_offline BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT,'fixture'); END") }
        await #expect(throws: (any Error).self) { try await target.store.commit(offlineApproval(plan)) }
        #expect(try await target.store.writeRevision() == revision)
        #expect(try await target.store.exportBackup() == before)
        try target.db.transaction { try $0.execute(sql: "DROP TRIGGER fail_offline") }
        _ = try await target.store.commit(offlineApproval(plan))
        let stale = try await target.store.prepareRestore(archive, mode: .merge, expectedRevision: target.store.writeRevision())
        try await target.store.save(offlineIssuerDocument("KO"), expectedRevision: target.store.writeRevision())
        await #expect(throws: SnapshotError.stalePlan) { try await target.store.commit(offlineApproval(stale)) }
        await #expect(throws: SnapshotError.unknownPlan) { try await target.store.commit(offlineApproval(stale)) }
    }

    @Test func invalidApprovalCancellationAndRecreatedStoreNeverAuthorizeCommit() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        try await source.store.save(offlineIssuerDocument(), expectedRevision: source.store.writeRevision())
        let archive = try await source.store.exportBackup()
        let plan = try await target.store.prepareRestore(archive, mode: .merge, expectedRevision: target.store.writeRevision())
        await #expect(throws: SnapshotError.approvalMismatch) {
            try await target.store.commit(.init(planID: plan.id, digest: String(repeating: "0", count: 64)))
        }
        let recreated = try OfflineIssuerResearchStore(database: target.db)
        await #expect(throws: SnapshotError.unknownPlan) { try await recreated.commit(offlineApproval(plan)) }
        await target.store.cancel(planID: plan.id)
        await #expect(throws: SnapshotError.unknownPlan) { try await target.store.commit(offlineApproval(plan)) }
        #expect(try await target.store.savedResearch().isEmpty)
    }

    @Test func saveKeepsOriginalRevisionAcrossRestore() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        let staleRevision = try await target.store.writeRevision()
        let oldWrite = try await offlineIssuerDocument("KO")
        try await source.store.save(offlineIssuerDocument(), expectedRevision: source.store.writeRevision())
        let archive = try await source.store.exportBackup()
        let plan = try await target.store.prepareRestore(archive, mode: .replace, expectedRevision: staleRevision)
        _ = try await target.store.commit(offlineApproval(plan))
        await #expect(throws: SnapshotError.stalePlan) { try await target.store.save(oldWrite, expectedRevision: staleRevision) }
        #expect(try await target.store.savedResearch().count == 1)
    }

    @Test func databasePurposeRejectsBothWrongEntrypointsWithoutChangingBusinessData() async throws {
        let directory = try offlineTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let businessPath = directory.appendingPathComponent("business.sqlite").path
        let business = try DatabaseStore(path: businessPath), snapshots = try BusinessDataStore(database: business)
        let research = ResearchStore(database: business, snapshots: snapshots)
        let transfer = ResearchTransferStore(database: business)
        try await research.save(SyntheticResearchFactory.make(symbol: "DEMO", executionDate: Date(timeIntervalSince1970: 1_800_000_000)))
        try await research.setWatchlist(WatchlistEntry(symbol: "USER", riskNote: "local fixture"), expectedRevision: nil)
        let before = try await transfer.exportBackup(), revision = await snapshots.revision()
        #expect(throws: (any Error).self) { try OfflineIssuerResearchStore(path: businessPath) }
        #expect(throws: (any Error).self) { try OfflineIssuerResearchStore(database: business) }
        let offlinePath = directory.appendingPathComponent("offline.sqlite").path
        let offline = try OfflineIssuerResearchStore(path: offlinePath)
        try await offline.save(offlineIssuerDocument(), expectedRevision: offline.writeRevision())
        #expect(throws: (any Error).self) { try DatabaseStore(path: offlinePath) }
        #expect(try await transfer.exportBackup() == before)
        #expect(await snapshots.revision() == revision)
        // A legacy, unmarked business schema must not be adopted by the new profile.
        try business.transaction { try $0.execute(sql: "PRAGMA application_id = 0") }
        #expect(throws: (any Error).self) { try OfflineIssuerResearchStore(path: businessPath) }
        #expect(try await transfer.exportBackup() == before)
    }

    @Test func newAndSyntheticArchiveProfilesCannotBeInterchanged() async throws {
        let offline = try OfflineArchiveFixture()
        try await offline.store.save(offlineIssuerDocument(), expectedRevision: offline.store.writeRevision())
        let realArchive = try await offline.store.exportBackup()
        let business = try DatabaseStore(path: ":memory:"), oldTransfer = ResearchTransferStore(database: business)
        let oldArchive = try await oldTransfer.exportBackup()
        await #expect(throws: (any Error).self) { try await oldTransfer.prepare(realArchive, mode: .replace) }
        await #expect(throws: (any Error).self) {
            try await offline.store.prepareRestore(oldArchive, mode: .replace, expectedRevision: offline.store.writeRevision())
        }
        #expect(try await offline.store.savedResearch().count == 1)
    }

    @Test func localRetentionDoesNotImplyBackupPermission() async throws {
        let f = try OfflineArchiveFixture(), excerpt = try offlineIssuerExcerpt("MSFT")
        let document = try await OfflineIssuerResearchDocument.make(excerptData: excerpt,
            asOf: Date(timeIntervalSince1970: 1_800_000_000), executionDate: Date(timeIntervalSince1970: 1_800_000_060),
            retention: .init(mayStore: true, mayBackup: false, evidenceReference: "LOCAL_ONLY_EXCERPT_PERMISSION"))
        try await f.store.save(document, expectedRevision: f.store.writeRevision())
        #expect(try await f.store.savedResearch().count == 1)
        await #expect(throws: SnapshotError.retentionDenied) { try await f.store.exportBackup() }
    }

    @Test func unrelatedBusinessRowsAndUnknownTablesAreNeverSilentlyOmitted() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        try await source.store.save(offlineIssuerDocument(), expectedRevision: source.store.writeRevision())
        let archive = try await source.store.exportBackup(), revision = try await target.store.writeRevision()
        try target.db.transaction { try $0.execute(sql: "CREATE TABLE unexpected_business (value TEXT)") }
        await #expect(throws: (any Error).self) { try await target.store.exportBackup() }
        await #expect(throws: (any Error).self) {
            try await target.store.prepareRestore(archive, mode: .replace, expectedRevision: revision)
        }
        try target.db.transaction { try $0.execute(sql: "DROP TABLE unexpected_business") }
        let entry = try WatchlistEntry(symbol: "USER", riskNote: "not in offline issuer scope")
        let row = try ResearchDocument.encoded(entry)
        try target.db.transaction {
            try $0.execute(sql: "INSERT INTO p1_watchlist (symbol,revision,content_hash,entry_json) VALUES(?,?,?,?)",
                arguments: [entry.symbol, entry.revision.uuidString, digest(row), row])
        }
        await #expect(throws: (any Error).self) { try await target.store.exportBackup() }
        await #expect(throws: (any Error).self) {
            try await target.store.prepareRestore(archive, mode: .replace, expectedRevision: revision)
        }
        #expect(try target.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_watchlist") } == 1)
    }

    @Test func corruptStoredObjectCannotBeReadOrExported() async throws {
        let f = try OfflineArchiveFixture()
        try await f.store.save(offlineIssuerDocument(), expectedRevision: f.store.writeRevision())
        try f.db.transaction { try $0.execute(sql: "UPDATE p1_snapshot_objects SET content_hash = ?", arguments: [String(repeating: "0", count: 64)]) }
        await #expect(throws: (any Error).self) { try await f.store.savedResearch() }
        await #expect(throws: (any Error).self) { try await f.store.exportBackup() }
    }

    @Test func validReplaceRepairsCorruptTargetsButMergeAndBadMetadataStillReject() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        try await source.store.save(offlineIssuerDocument("WMT"), expectedRevision: source.store.writeRevision())
        try await target.store.save(offlineIssuerDocument(), expectedRevision: target.store.writeRevision())
        let archive = try await source.store.exportBackup(), revision = try await target.store.writeRevision()
        try target.db.transaction { try $0.execute(sql: "UPDATE p1_snapshot_objects SET object_json = X'00'") }
        let reopened = try OfflineIssuerResearchStore(database: target.db)
        await #expect(throws: (any Error).self) {
            try await reopened.prepareRestore(archive, mode: .merge, expectedRevision: revision)
        }
        let plan = try await reopened.prepareRestore(archive, mode: .replace, expectedRevision: revision)
        #expect(!plan.removedObjects.isEmpty && !plan.removedRoots.isEmpty)
        try target.db.transaction { try $0.execute(sql: "CREATE TRIGGER fail_repair BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT,'fixture'); END") }
        await #expect(throws: (any Error).self) { try await reopened.commit(offlineApproval(plan)) }
        #expect(try target.db.read { try Data.fetchOne($0, sql: "SELECT object_json FROM p1_snapshot_objects LIMIT 1") } == Data([0]))
        #expect(try await reopened.writeRevision() == revision)
        try target.db.transaction { try $0.execute(sql: "DROP TRIGGER fail_repair") }
        _ = try await reopened.commit(offlineApproval(plan))
        #expect(try await reopened.savedResearch().count == 1)
        try target.db.transaction { try $0.execute(sql: "UPDATE p1_store_metadata SET revision = 'invalid'") }
        await #expect(throws: (any Error).self) { try await reopened.writeRevision() }
        await #expect(throws: (any Error).self) {
            try await reopened.prepareRestore(archive, mode: .replace, expectedRevision: revision)
        }
    }

    @Test func recomputingOuterArchiveHashesCannotHideGraphOrScopeDamage() async throws {
        let source = try OfflineArchiveFixture(), target = try OfflineArchiveFixture()
        try await source.store.save(offlineIssuerDocument(), expectedRevision: source.store.writeRevision())
        let archive = try await source.store.exportBackup(), revision = try await target.store.writeRevision()
        for mutation in 0..<5 {
            var files = try ResearchZIP.decode(archive)
            var state = try #require(JSONSerialization.jsonObject(with: files["research-state.json"]!) as? [String: Any])
            var objects = try #require(state["objects"] as? [[String: Any]])
            switch mutation {
            case 0: objects.removeLast()
            case 1:
                var origin = try #require(objects[0]["origin"] as? [String: Any])
                origin["namespace"] = UUID().uuidString; objects[0]["origin"] = origin
            case 2:
                var roots = try #require(state["roots"] as? [[String: Any]])
                var root = try #require(roots[0]["root"] as? [String: Any])
                root["kind"] = "ledger"; roots[0]["root"] = root; state["roots"] = roots
            case 3: state["credentials"] = ["unexpected": "fixture"]
            default: state["profile"] = "offline-issuer-research.v999"
            }
            state["objects"] = objects
            let payload = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            var manifest = try #require(JSONSerialization.jsonObject(with: files["manifest.json"]!) as? [String: Any])
            manifest["sha256"] = digest(payload); manifest["size"] = payload.count; manifest["objects"] = objects.count
            files["research-state.json"] = payload
            files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            let damaged = try ResearchZIP.encode(files)
            await #expect(throws: (any Error).self) {
                try await target.store.prepareRestore(damaged, mode: .replace, expectedRevision: revision)
            }
            #expect(try await target.store.writeRevision() == revision)
            #expect(try await target.store.savedResearch().isEmpty)
        }
    }
}
