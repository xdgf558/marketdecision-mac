import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine
import OptionsAnalytics
import AppComposition
@testable import Persistence

private func ocsVariant(_ original: OptionChainCapture, pages: [OptionChainRawPage]) throws -> OptionChainCapture {
    try .init(id: original.id, createdAt: original.createdAt, requestedAt: original.requestedAt, symbol: original.symbol,
              environment: original.environment, timestampUnit: original.timestampUnit, synthetic: original.synthetic,
              rights: original.rights, requestedExpirations: original.requestedExpirations, pages: pages)
}
private func ocsLegacyArchive(_ database: DatabaseStore) throws -> Data {
    let state = try database.read(OptionLabArchiveState.capture)
    let legacy = OptionLabArchiveState(format: OptionLabArchiveState.legacyFormat, revision: state.revision,
                                      tables: Array(state.tables.prefix(OptionLabArchiveState.legacyDefinitions.count)))
    let bytes = try OptionLabArchiveCodec.canonical(legacy)
    let manifest = OptionLabArchiveCodec.Manifest(format: OptionLabArchiveCodec.legacyFormat, purpose: "MDQ1", encrypted: false,
        stateHash: LedgerCSV.hash(bytes), stateBytes: bytes.count, embeddedLedgerBases: legacy.counts.embeddedLedgerBases,
        ledgerBasisScope: OptionLabArchiveCodec.ledgerBasisScope)
    return try ResearchZIP.encode(["manifest.json": OptionLabArchiveCodec.canonical(manifest), "research-state.json": bytes])
}
/// Recompute outer storage hashes so the source replay, not only the BLOB checksum,
/// must detect an untrusted normalized projection or changed source-page evidence.
private func ocsReplaceBody(_ db: DatabaseStore, change: (inout [String: Any]) throws -> Void) throws {
    try db.transaction { connection in
        let old = try #require(try Data.fetchOne(connection, sql: "SELECT capture_json FROM option_chain_documents"))
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any]); try change(&object)
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let raw = try #require(try Data.fetchOne(connection, sql: "SELECT summary_json FROM option_chain_catalog"))
        var summary = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any]); summary["contentHash"] = LedgerCSV.hash(changed)
        let metadata = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        try connection.execute(sql: "UPDATE option_chain_documents SET capture_json=?", arguments: [changed])
        try connection.execute(sql: "UPDATE option_chain_catalog SET content_hash=?,summary_hash=?,summary_json=?",
                               arguments: [LedgerCSV.hash(changed), LedgerCSV.hash(metadata), metadata])
    }
}

@Suite("Option chain immutable source storage and archive isolation")
struct OptionChainStorageTests {
    @Test func exactRawPagesAndNormalizedSnapshotSurviveReopenWithCatalogOnlyListing() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try OptionChainStore(path: path.path), capture = try OptionChainDemo.capture()
        let saved = try await store.save(capture, expectedRevision: store.revision())
        let reopened = try OptionChainStore(path: path.path), loaded = try await reopened.open(id: capture.id)
        #expect(loaded == saved && loaded.replayMatched)
        #expect(loaded.capture.pages.map(\.bytes) == capture.pages.map(\.bytes))
        #expect(loaded.capture.pages.map(\.contentHash) == capture.pages.map(\.contentHash))
        #expect(!loaded.capture.snapshot.qualifiedForLiveAnalysis && !loaded.capture.snapshot.qualifiedForPIT)
        let summary = try #require(try await reopened.summaries().first)
        #expect(summary.id == capture.id && summary.contentHash == saved.contentHash)
        #expect(summary.synthetic && summary.status == .complete && summary.contractCount == 8 && summary.pageCount == 4)
    }
    @Test func repeatCaptureDoesNotChangeBytesOrRevisionAndConflictingIdentityRejects() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        let saved = try await store.save(capture, expectedRevision: store.revision())
        let before = try db.read(OptionLabArchiveState.capture), token = try await store.revision()
        #expect(try await store.save(capture, expectedRevision: token) == saved)
        let encoded = try OptionLabArchiveCodec.canonical(capture)
        let roundtrip = try JSONDecoder().decode(OptionChainCapture.self, from: encoded)
        #expect(try OptionLabArchiveCodec.canonical(roundtrip) == encoded)
        #expect(try await store.save(roundtrip, expectedRevision: token) == saved)
        let different = try ocsVariant(capture, pages: Array(capture.pages.prefix(3)))
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(different, expectedRevision: token) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
    }
    @Test func partialAndProviderErrorCapturesRemainExplicitAfterSaveAndReopen() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db)
        let original = try OptionChainDemo.capture(), partial = try ocsVariant(original, pages: Array(original.pages.prefix(3)))
        #expect(partial.snapshot.status == .partial)
        let partialSaved = try await store.save(partial, expectedRevision: store.revision())
        let other = try OptionChainDemo.capture(), first = try #require(other.pages.first)
        let errorPage = OptionChainRawPage(request: first.request, receivedAt: first.receivedAt,
                                          statusCode: 429, bytes: Data(#"{"error":"synthetic rate limit"}"#.utf8))
        let error = try ocsVariant(other, pages: [errorPage])
        #expect(error.snapshot.status == .error && error.snapshot.contracts.isEmpty)
        let errorSaved = try await store.save(error, expectedRevision: store.revision())
        #expect(try await store.open(id: partial.id) == partialSaved)
        #expect(try await store.open(id: error.id) == errorSaved)
        #expect(Set(try await store.summaries().map(\.status)) == [.partial, .error])
    }
    @Test func saveRejectsUntrustedDecodedProjectionBeforeWritingAnything() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        var object = try #require(JSONSerialization.jsonObject(with: OptionLabArchiveCodec.canonical(capture)) as? [String: Any])
        var snapshot = try #require(object["snapshot"] as? [String: Any]); snapshot["status"] = "empty"; object["snapshot"] = snapshot
        let bad = try JSONDecoder().decode(OptionChainCapture.self, from: JSONSerialization.data(withJSONObject: object))
        let before = try db.read(OptionLabArchiveState.capture)
        await #expect(throws: (any Error).self) { try await store.save(bad, expectedRevision: store.revision()) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
    }
    @Test func damagedColumnsOrMissingBodyFailOpenAndDuplicateValidationConsistently() async throws {
        let mutations = [
            "UPDATE option_chain_catalog SET symbol='WRONG'",
            "UPDATE option_chain_catalog SET provider_id='WRONG'",
            "UPDATE option_chain_catalog SET feed_id='WRONG'",
            "UPDATE option_chain_catalog SET summary_json=x'00'",
            "UPDATE option_chain_documents SET capture_json=x'00'",
            "DELETE FROM option_chain_documents"
        ]
        for sql in mutations {
            let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
            _ = try await store.save(capture, expectedRevision: store.revision()); let token = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: capture.id) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.save(capture, expectedRevision: token) }
        }
    }
    @Test func rehashedNormalizedProjectionDoesNotPassFullRawReplay() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        _ = try await store.save(capture, expectedRevision: store.revision())
        try ocsReplaceBody(db) { object in
            var snapshot = try #require(object["snapshot"] as? [String: Any]); snapshot["status"] = "empty"; object["snapshot"] = snapshot
        }
        #expect(try await store.summaries().count == 1) // A catalog is not a verified quote.
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: capture.id) }
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.save(capture, expectedRevision: store.revision()) }
        await #expect(throws: (any Error).self) { try await OptionLabArchiveStore(database: db).exportArchive() }
    }
    @Test func rehashedRawPageEvidenceMustStillAgreeWithNormalizedSnapshot() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        _ = try await store.save(capture, expectedRevision: store.revision())
        try ocsReplaceBody(db) { object in
            var pages = try #require(object["pages"] as? [[String: Any]])
            let encoded = try #require(pages[0]["bytes"] as? String)
            let raw = try #require(Data(base64Encoded: encoded))
            let changed = Data(try #require(String(data: raw, encoding: .utf8)).replacingOccurrences(of: "99.95", with: "88.95").utf8)
            pages[0]["bytes"] = changed.base64EncodedString(); pages[0]["contentHash"] = LedgerCSV.hash(changed); object["pages"] = pages
        }
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: capture.id) }
    }
    @Test func insertedCatalogBodyAndRevisionRollbackTogetherAndSameBaselineRetries() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        let before = try db.read(OptionLabArchiveState.capture), token = try await store.revision()
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) { try await store.save(capture, expectedRevision: token) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        #expect(try await store.save(capture, expectedRevision: token).replayMatched)
    }
    @Test func actualSQLiteFailureAfterBodyWriteDoesNotLeaveHalfCapture() async throws {
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        let before = try db.read(OptionLabArchiveState.capture), token = try await store.revision()
        try db.transaction { try $0.execute(sql: "CREATE TRIGGER reject_chain_revision BEFORE UPDATE ON option_lab_metadata BEGIN SELECT RAISE(ABORT,'synthetic failure'); END") }
        await #expect(throws: (any Error).self) { try await store.save(capture, expectedRevision: token) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        try db.transaction { try $0.execute(sql: "DROP TRIGGER reject_chain_revision") }
        #expect(try await store.save(capture, expectedRevision: token).replayMatched)
    }
    @Test func newArchiveRestoresExactSourceBytesAndReplaysOnOpening() async throws {
        let db = try odsDB(), source = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        let saved = try await source.save(capture, expectedRevision: source.revision())
        let raw = try await OptionLabArchiveStore(database: db).exportArchive(), files = try ResearchZIP.decode(raw)
        let manifest = try JSONDecoder().decode(OptionLabArchiveCodec.Manifest.self, from: #require(files["manifest.json"]))
        #expect(manifest.format == "options-lab-archive.v3" && !manifest.encrypted)
        let target = try odsDB(), restore = try OptionLabArchiveStore(database: target)
        let plan = try await restore.prepareRestore(raw, mode: .replace, expectedRevision: restore.status().revision)
        #expect(plan.result.chainCaptures == 1)
        _ = try await restore.commit(.init(plan: plan))
        #expect(try target.read(OptionLabArchiveState.capture).tables == db.read(OptionLabArchiveState.capture).tables)
        #expect(try await OptionChainStore(database: target).open(id: capture.id) == saved)
    }
    @Test func chainBoundExperimentAndDailyArchiveRetainFullRawEvidenceAndReplayAfterReopen() async throws {
        let capture = try OptionChainDemo.capture()
        let short = try #require(capture.snapshot.contracts.first { $0.right == .put })
        var draft = try OptionChainLabBridge.draft(capture, strategy: .cashSecuredPut, shortID: short.recordID, longID: nil, quantity: 1)
        draft.settlementAt = short.expiration.iso8601 + "T21:00:00.000Z"
        draft.expiryReference = "synthetic-explicit-settlement"
        draft.shortLeg.tick = "0.01"
        draft.cashBeforeTrade = "20000"; draft.committedCash = "0"
        draft.availableShares = "100"; draft.committedShares = "0"
        draft.capitalReference = "synthetic-explicit-capital"; draft.scenarioPrices = "90\n100\n110"
        try draft.useSyntheticRiskScenarioAssumptions()
        let input = try draft.build(createdAt: capture.createdAt)
        let formatter = ISO8601DateFormatter()
        let settlements = try Dictionary(uniqueKeysWithValues: capture.requestedExpirations.map { date in
            (date.iso8601, try #require(formatter.date(from: date.iso8601 + "T21:00:00Z")))
        })
        let dailyInput = try OptionChainLabBridge.daily(capture, rate: Money("0.05"), dividendYield: Money("0.01"),
            settlements: settlements, tick: Money("0.01"), assumptionReference: "synthetic-explicit-daily-assumptions", declaredClose: true)
        let source = try odsDB(), lab = try OptionLabStore(database: source), daily = try OptionDailyStore(database: source)
        let experiment = try await lab.save(id: input.id, input: input, expectedRevision: lab.revision())
        let savedDaily = try await daily.saveDaily(dailyInput, expectedRevision: daily.revision())
        #expect(experiment.report.schemaVersion == "option-lab-report.v4.chain")
        #expect(savedDaily.report.schemaVersion == "option-daily-report.v2.chain")
        #expect(experiment.report.pricing != nil && experiment.report.risk != nil && experiment.report.scenario != nil)
        // The frozen experiment/daily input is self-contained: no separately saved
        // chain catalog row or external source cache is needed for archive replay.
        #expect(try await lab.makeChainStore().summaries().isEmpty)
        let raw = try await lab.makeArchiveStore().exportArchive()
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let restore = try OptionLabArchiveStore(path: path.path)
        let plan = try await restore.prepareRestore(raw, mode: .replace, expectedRevision: restore.status().revision)
        _ = try await restore.commit(.init(plan: plan))
        let reopened = try OptionLabStore(path: path.path), reopenedDaily = try OptionDailyStore(path: path.path)
        let replayed = try await reopened.open(id: input.id), replayedDaily = try await reopenedDaily.openDaily(id: dailyInput.id)
        #expect(replayed == experiment && replayedDaily == savedDaily)
        #expect(replayed.report.input.chainEvidence?.capture.pages.map(\.bytes) == capture.pages.map(\.bytes))
        #expect(replayedDaily.report.input.chainEvidence?.pages.map(\.bytes) == capture.pages.map(\.bytes))
    }
    @Test func legacyArchiveUpgradePreservesOldBodiesAndExplicitlyHasNoChainCaptures() async throws {
        let source = try odsDB(), lab = try OptionLabStore(database: source), input = try OptionLabDemo.input()
        let saved = try await lab.save(id: input.id, input: input, expectedRevision: lab.revision())
        let raw = try ocsLegacyArchive(source), decoded = try OptionLabArchiveCodec.decode(raw)
        #expect(decoded.format == "options-lab-state.v3" && decoded.counts.chainCaptures == 0)
        #expect(try decoded.rows("option_chain_catalog").isEmpty && decoded.rows("option_chain_documents").isEmpty)
        for mode in [OptionLabRestoreMode.merge, .replace] {
            let target = try odsDB(), chain = try OptionChainStore(database: target), restore = try OptionLabArchiveStore(database: target)
            let capture = try OptionChainDemo.capture(); _ = try await chain.save(capture, expectedRevision: chain.revision())
            let plan = try await restore.prepareRestore(raw, mode: mode, expectedRevision: restore.status().revision)
            #expect(plan.previous.chainCaptures == 1 && plan.result.chainCaptures == (mode == .merge ? 1 : 0))
            _ = try await restore.commit(.init(plan: plan))
            #expect(try await OptionLabStore(database: target).open(id: saved.id) == saved)
            #expect(try target.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") }
                == source.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") })
            #expect(try await chain.summaries().count == (mode == .merge ? 1 : 0))
        }
    }
    @Test func archiveVersionCannotRelabelCurrentTablesAsLegacyToBypassClosedCatalog() async throws {
        let db = try odsDB(), archive = try OptionLabArchiveStore(database: db), raw = try await archive.exportArchive()
        var files = try ResearchZIP.decode(raw)
        let manifestBytes = try #require(files["manifest.json"])
        var manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        manifest["format"] = "options-lab-archive.v1"
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
        await #expect(throws: OptionLabArchiveError.unsupportedFormat) {
            try await archive.prepareRestore(ResearchZIP.encode(files), mode: .replace, expectedRevision: archive.status().revision)
        }
    }
    @Test func mergeConflictRejectsEntirePlanAndIdenticalSourceImportIsIdempotent() async throws {
        let a = try odsDB(), b = try odsDB(), left = try OptionChainStore(database: a), right = try OptionChainStore(database: b)
        let capture = try OptionChainDemo.capture()
        _ = try await left.save(capture, expectedRevision: left.revision()); _ = try await right.save(capture, expectedRevision: right.revision())
        let archive = try OptionLabArchiveStore(database: a), raw = try await OptionLabArchiveStore(database: b).exportArchive()
        let plan = try await archive.prepareRestore(raw, mode: .merge, expectedRevision: archive.status().revision)
        let before = try a.read(OptionLabArchiveState.capture).tables
        _ = try await archive.commit(.init(plan: plan)); #expect(try a.read(OptionLabArchiveState.capture).tables == before)
        let conflict = try odsDB(), conflictStore = try OptionChainStore(database: conflict)
        _ = try await conflictStore.save(ocsVariant(capture, pages: Array(capture.pages.prefix(3))), expectedRevision: conflictStore.revision())
        let conflictingBytes = try await OptionLabArchiveStore(database: conflict).exportArchive()
        await #expect(throws: OptionLabArchiveError.identityConflict) {
            try await archive.prepareRestore(conflictingBytes, mode: .merge, expectedRevision: archive.status().revision)
        }
        #expect(try a.read(OptionLabArchiveState.capture).tables == before)
    }
    @Test func replaceRepairsCorruptChainButMergeRequiresCurrentSourceIntegrity() async throws {
        let source = try odsDB(), chain = try OptionChainStore(database: source), capture = try OptionChainDemo.capture()
        let saved = try await chain.save(capture, expectedRevision: chain.revision())
        let raw = try await OptionLabArchiveStore(database: source).exportArchive()
        let target = try odsDB(), targetChain = try OptionChainStore(database: target), restore = try OptionLabArchiveStore(database: target)
        _ = try await targetChain.save(OptionChainDemo.capture(), expectedRevision: targetChain.revision())
        try target.transaction { try $0.execute(sql: "UPDATE option_chain_documents SET capture_json=x'00'") }
        await #expect(throws: (any Error).self) { try await restore.prepareRestore(raw, mode: .merge, expectedRevision: restore.status().revision) }
        let plan = try await restore.prepareRestore(raw, mode: .replace, expectedRevision: restore.status().revision)
        _ = try await restore.commit(.init(plan: plan))
        #expect(try await targetChain.open(id: saved.id) == saved)
    }
    @Test func clearAndReplaceInvalidatePreexistingChainWritersAcrossConnections() async throws {
        for replace in [false, true] {
            let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
            let oldWriter = try OptionChainStore(path: path.path), archive = try OptionLabArchiveStore(path: path.path)
            _ = try await oldWriter.save(OptionChainDemo.capture(), expectedRevision: oldWriter.revision())
            let token = try await oldWriter.revision(), late = try OptionChainDemo.capture()
            let plan: OptionLabTransferPlan
            if replace {
                let empty = try await OptionLabArchiveStore(database: odsDB()).exportArchive()
                plan = try await archive.prepareRestore(empty, mode: .replace, expectedRevision: token)
            } else { plan = try await archive.prepareClear(expectedRevision: token) }
            #expect(plan.previous.chainCaptures == 1 && plan.result.chainCaptures == 0)
            _ = try await archive.commit(.init(plan: plan))
            await #expect(throws: OptionLabStoreError.staleRevision) { try await oldWriter.save(late, expectedRevision: token) }
            #expect(try await oldWriter.summaries().isEmpty)
        }
    }
    @Test func chainWriteInvalidatesAlreadyPreparedArchiveApproval() async throws {
        let db = try odsDB(), chain = try OptionChainStore(database: db), archive = try OptionLabArchiveStore(database: db)
        let plan = try await archive.prepareClear(expectedRevision: chain.revision())
        let saved = try await chain.save(OptionChainDemo.capture(), expectedRevision: chain.revision())
        await #expect(throws: OptionLabArchiveError.stalePlan) { try await archive.commit(.init(plan: plan)) }
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await archive.commit(.init(plan: plan)) }
        #expect(try await chain.open(id: saved.id) == saved)
    }
    @Test func clearFailureRetainsAllChainBytesAndOriginalPlanCanRetry() async throws {
        let db = try odsDB(), chain = try OptionChainStore(database: db), archive = try OptionLabArchiveStore(database: db)
        _ = try await chain.save(OptionChainDemo.capture(), expectedRevision: chain.revision())
        let before = try db.read(OptionLabArchiveState.capture), plan = try await archive.prepareClear(expectedRevision: chain.revision())
        await archive.injectFailureOnNextCommit()
        await #expect(throws: OptionLabArchiveError.injectedFailure) { try await archive.commit(.init(plan: plan)) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        _ = try await archive.commit(.init(plan: plan)); #expect(try await chain.summaries().isEmpty)
    }
    @Test func v3MigrationPreservesExistingExperimentDailyHistoryBytesAndSharedRevision() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let db = try DatabaseStore(path: path.path, purpose: .optionsLab), lab = try OptionLabStore(database: db)
        let daily = try OptionDailyStore(database: db), input = try OptionLabDemo.input()
        _ = try await lab.save(id: input.id, input: input, expectedRevision: lab.revision())
        _ = try await daily.saveDaily(odsInput(), expectedRevision: daily.revision())
        _ = try await daily.saveHistory(odsHistory(), expectedRevision: daily.revision())
        let before = try db.read(OptionLabArchiveState.capture)
        try db.transaction { connection in
            try connection.execute(sql: "DROP TABLE portfolio_greeks_documents; DROP TABLE portfolio_greeks_catalog; DROP TABLE option_chain_documents; DROP TABLE option_chain_catalog;")
            try connection.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('options-lab.v3','options-lab.v4')")
        }
        let upgraded = try DatabaseStore(path: path.path, purpose: .optionsLab)
        #expect(try upgraded.read(OptionLabArchiveState.capture) == before)
        #expect(try await OptionLabStore(database: upgraded).makeChainStore().summaries().isEmpty)
        #expect(try upgraded.migrationVersions() == ["foundation.v1", "options-lab.v1", "options-lab.v2", "options-lab.v3", "options-lab.v4"])
    }
    @Test func chainStoreCannotUseResearchOrLedgerDatabaseAndCancelledSaveDoesNotWrite() async throws {
        for purpose in [DatabasePurpose.business, .offlineIssuerResearch, .secResearch, .portfolioLedger] {
            #expect(throws: OptionLabStoreError.incompatiblePurpose) { try OptionChainStore(database: DatabaseStore(path: ":memory:", purpose: purpose)) }
        }
        let db = try odsDB(), store = try OptionChainStore(database: db), capture = try OptionChainDemo.capture()
        let gate = OCSGate(), token = try await store.revision(), task = Task {
            await gate.wait(); return try await store.save(capture, expectedRevision: token)
        }
        await gate.arrived(); task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.revision() == token)
        #expect(try await store.summaries().isEmpty)
    }
}

private actor OCSGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; arrival?.resume(); arrival = nil; await withCheckedContinuation { waiter = $0 } }
    func arrived() async { if entered { return }; await withCheckedContinuation { arrival = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
