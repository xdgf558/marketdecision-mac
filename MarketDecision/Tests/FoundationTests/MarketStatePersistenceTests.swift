import Foundation
import Testing
import GRDB
import CoreDomain
import MarketAnalytics
import PortfolioEngine
@testable import Persistence

private func marketDB() throws -> DatabaseStore { try DatabaseStore(path: ":memory:", purpose: .marketState) }
private func marketPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("market-state-" + UUID().uuidString + ".sqlite") }
private func frozenMarketInput(id: UUID = UUID(), offset: TimeInterval = 0) throws -> MarketStateInput {
    let time = Date(timeIntervalSince1970: 1_792_435_200.0004)
    let observation = MarketObservation(observationID: "SYNTHETIC-VIX-2026-10-19", vintageID: "v1", observationDate: "2026-10-19",
        releasedAt: time.addingTimeInterval(-1), availableAt: time.addingTimeInterval(-0.5), value: try Money("21.125"), rawValue: "21.125")
    let series = MarketSeries(key: .vix, unit: .volatilityPercent, origin: .synthetic, sourceID: "SYNTHETIC-LOCAL",
        feedID: "SYNTHETIC-VIX", methodology: "Declared sample only", basisVersion: "synthetic.v1", observations: [observation])
    return .init(id: id, createdAt: time.addingTimeInterval(offset + 1), asOf: time, sessionDate: "2026-10-19",
        sessions: [.init(date: "2026-10-19", closeAt: time)], calendarEvidence: "SYNTHETIC-ONE-SESSION", series: [series])
}
private func marketCache() -> MarketSourceCacheEntry {
    .init(id: UUID(), sourceID: "SYNTHETIC-LOCAL", feedID: "SYNTHETIC-VIX", evidenceReference: "Not licensed feed evidence",
        retrievedAt: Date(timeIntervalSince1970: 1_792_435_199.0004), payload: Data("exact synthetic response bytes".utf8))
}
private func marketArchive(_ input: MarketStateInput? = nil) async throws -> Data {
    let db = try marketDB()
    if let input { let store = try MarketStateStore(database: db); _ = try await store.save(input, expectedRevision: store.revision()) }
    return try await MarketStateArchiveStore(database: db).exportArchive()
}

@Suite("Market state independent frozen persistence and archives")
struct MarketStatePersistenceTests {
    @Test func independentPurposeDoesNotMigrateBusinessOptionsOrLedger() throws {
        for purpose in [DatabasePurpose.business, .optionsLab, .portfolioLedger, .secResearch] {
            let path = marketPath(); defer { try? FileManager.default.removeItem(at: path) }
            let database = try DatabaseStore(path: path.path, purpose: purpose)
            let history = try database.migrationVersions()
            #expect(throws: MigrationError.incompatiblePurpose) { _ = try MarketStateStore(path: path.path) }
            #expect(try database.migrationVersions() == history)
            #expect(throws: MarketStateStorageError.incompatiblePurpose) { _ = try MarketStateStore(database: database) }
        }
        let database = try marketDB()
        #expect(try database.migrationVersions() == ["foundation.v1", "market-state.v1", "market-state.v2"])
    }
    @Test func frozenInputSurvivesPurgeAndDatabaseReopen() async throws {
        let path = marketPath(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try MarketStateStore(path: path.path), input = try frozenMarketInput(), cache = marketCache()
        try await store.cache(cache, expectedRevision: store.revision())
        let frozen = try await store.save(input, expectedRevision: store.revision())
        try await store.purgeCache(expectedRevision: store.revision())
        let reopened = try MarketStateStore(path: path.path)
        #expect(try await reopened.open(id: input.id) == frozen)
        #expect(frozen.report.input == input && frozen.replayMatched)
        #expect(frozen.report.input.series[0].observations[0].rawValue == "21.125")
        #expect(try await MarketStateArchiveStore(path: path.path).status().counts.cachedSources == 0)
    }
    @Test func attributionAndMarketUseOneRevisionButSeparateKindsAndNoLedgerWrites() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), input = try frozenMarketInput()
        let market = try await store.save(input, expectedRevision: store.revision())
        let attributionInput = try MarketTradeAttributionDemo.input(snapshot: market.report)
        let attribution = try await store.saveAttribution(attributionInput, expectedRevision: store.revision())
        #expect(try await store.openAttribution(id: attribution.id) == attribution)
        #expect(Set(try await store.summaries().map(\.kind)) == Set([.marketState, .tradeAttribution]))
        await #expect(throws: MarketStateStorageError.unsupportedFormat) { try await store.open(id: attribution.id) }
        await #expect(throws: MarketStateStorageError.unsupportedFormat) { try await store.openAttribution(id: market.id) }
        let tables = try db.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        #expect(tables.allSatisfy { !$0.hasPrefix("ledger_") && !$0.hasPrefix("option_") && !$0.hasPrefix("p1_") })
    }
    @Test func repeatedExactInputIsIdempotentAndChangedIdentityRejected() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), input = try frozenMarketInput()
        let saved = try await store.save(input, expectedRevision: store.revision()), revision = try await store.revision()
        #expect(try await store.save(input, expectedRevision: revision) == saved)
        #expect(try await store.revision() == revision)
        await #expect(throws: MarketStateStorageError.identityConflict) { try await store.save(frozenMarketInput(id: input.id, offset: 1), expectedRevision: revision) }
        #expect(try await store.open(id: input.id) == saved)
    }
    @Test func metadataListingDoesNotReadOrPublishBodyValues() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), input = try frozenMarketInput()
        _ = try await store.save(input, expectedRevision: store.revision())
        let summaries = try await store.summaries()
        let bytes = try #require(try db.read { try Data.fetchOne($0, sql: "SELECT summary_json FROM market_state_catalog") })
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["heat"] == nil && object["current"] == nil && object["rows"] == nil)
        try db.transaction { try $0.execute(sql: "UPDATE market_state_documents SET report_json=x'00'") }
        #expect(try await store.summaries() == summaries)
        await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.open(id: input.id) }
    }
    @Test func allBodyIndexAndHashCorruptionRejectsOpenDuplicateAndExport() async throws {
        for sql in ["UPDATE market_state_catalog SET kind='tradeAttribution'",
                    "UPDATE market_state_catalog SET input_hash=printf('%064d',0)",
                    "UPDATE market_state_catalog SET summary_json=x'00'",
                    "UPDATE market_state_documents SET input_json=x'00'",
                    "UPDATE market_state_documents SET report_json=x'00'",
                    "DELETE FROM market_state_documents"] {
            let db = try marketDB(), store = try MarketStateStore(database: db), input = try frozenMarketInput()
            _ = try await store.save(input, expectedRevision: store.revision()); let revision = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: (any Error).self) { try await store.open(id: input.id) }
            await #expect(throws: (any Error).self) { try await store.save(input, expectedRevision: revision) }
            await #expect(throws: (any Error).self) { try await MarketStateArchiveStore(database: db).exportArchive() }
        }
    }
    @Test func recomputationRejectsAlteredResultsEvenWithConsistentOuterHashes() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), input = try frozenMarketInput()
        _ = try await store.save(input, expectedRevision: store.revision())
        try db.transaction { connection in
            let reportBytes = try #require(try Data.fetchOne(connection, sql: "SELECT report_json FROM market_state_documents"))
            var object = try #require(JSONSerialization.jsonObject(with: reportBytes) as? [String: Any]); object["researchOnly"] = false
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let summaryBytes = try #require(try Data.fetchOne(connection, sql: "SELECT summary_json FROM market_state_catalog"))
            var summary = try #require(JSONSerialization.jsonObject(with: summaryBytes) as? [String: Any]); summary["reportHash"] = LedgerCSV.hash(changed)
            let changedSummary = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
            try connection.execute(sql: "UPDATE market_state_documents SET report_json=?", arguments: [changed])
            try connection.execute(sql: "UPDATE market_state_catalog SET report_hash=?,summary_hash=?,summary_json=?", arguments: [LedgerCSV.hash(changed), LedgerCSV.hash(changedSummary), changedSummary])
        }
        #expect(try await store.summaries().count == 1)
        await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.open(id: input.id) }
        await #expect(throws: (any Error).self) { try await MarketStateArchiveStore(database: db).exportArchive() }
    }
    @Test func saveFailureRollsBackBothTablesAndCanRetryOriginalBaseline() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), revision = try await store.revision(), input = try frozenMarketInput()
        await store.injectFailureOnNextSave()
        await #expect(throws: MarketStateStorageError.injectedFailure) { try await store.save(input, expectedRevision: revision) }
        #expect(try await store.revision() == revision)
        #expect(try await store.summaries().isEmpty)
        #expect(try await store.save(input, expectedRevision: revision).replayMatched)
    }
    @Test func sqliteAbortAfterBodyWriteRollsBackEntireSave() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), revision = try await store.revision(), input = try frozenMarketInput()
        try db.transaction { try $0.execute(sql: "CREATE TRIGGER reject_market_revision BEFORE UPDATE ON market_state_metadata BEGIN SELECT RAISE(ABORT,'synthetic failure'); END") }
        await #expect(throws: (any Error).self) { try await store.save(input, expectedRevision: revision) }
        #expect(try await store.revision() == revision)
        #expect(try await store.summaries().isEmpty)
        try db.transaction { try $0.execute(sql: "DROP TRIGGER reject_market_revision") }
        #expect(try await store.save(input, expectedRevision: revision).replayMatched)
    }
    @Test func sourceCacheIdentitiesAreImmutableAndPurgeDoesNotNeedHealthyBodies() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), cache = marketCache()
        try await store.cache(cache, expectedRevision: store.revision()); let revision = try await store.revision()
        try await store.cache(cache, expectedRevision: revision)
        #expect(try await store.revision() == revision)
        let other = MarketSourceCacheEntry(id: cache.id, sourceID: cache.sourceID, feedID: cache.feedID, evidenceReference: cache.evidenceReference,
            retrievedAt: cache.retrievedAt, payload: Data("changed".utf8))
        await #expect(throws: MarketStateStorageError.identityConflict) { try await store.cache(other, expectedRevision: revision) }
        try db.transaction { try $0.execute(sql: "UPDATE market_state_source_cache SET source_json=x'00'") }
        try await store.purgeCache(expectedRevision: revision)
        #expect(try await MarketStateArchiveStore(database: db).status().counts.cachedSources == 0)
    }
    @Test func archiveRoundtripPreservesBothKindsAndExcludesCache() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), input = try frozenMarketInput()
        let state = try await store.save(input, expectedRevision: store.revision())
        let attribution = try await store.saveAttribution(MarketTradeAttributionDemo.input(snapshot: state.report), expectedRevision: store.revision())
        try await store.cache(marketCache(), expectedRevision: store.revision())
        let archive = try await MarketStateArchiveStore(database: db).exportArchive()
        let files = try ResearchZIP.decode(archive)
        let manifest = try JSONDecoder().decode(MarketStateArchiveCodec.Manifest.self, from: #require(files["manifest.json"]))
        #expect(manifest.format == "market-state-archive.v2" && manifest.purpose == "MDM1" && !manifest.encrypted)
        #expect(manifest.marketReports == 1 && manifest.attributionReports == 1)
        let target = try marketDB(), targetStore = try MarketStateStore(database: target), transfer = try MarketStateArchiveStore(database: target)
        let plan = try await transfer.prepareRestore(archive, mode: .replace, expectedRevision: targetStore.revision())
        #expect(try await targetStore.summaries().isEmpty)
        _ = try await transfer.commit(.init(plan: plan))
        #expect(try await targetStore.open(id: state.id) == state)
        #expect(try await targetStore.openAttribution(id: attribution.id) == attribution)
        #expect(try await transfer.status().counts.cachedSources == 0)
    }
    @Test func replaceRepairsCorruptBodiesButMergeRejectsAndCacheSurvives() async throws {
        for sql in ["UPDATE market_state_catalog SET summary_json=x'00'", "UPDATE market_state_documents SET report_json=x'00'", "DELETE FROM market_state_documents"] {
            let input = try frozenMarketInput(), incoming = try await marketArchive(input)
            let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
            _ = try await store.save(frozenMarketInput(), expectedRevision: store.revision())
            try await store.cache(marketCache(), expectedRevision: store.revision())
            let revision = try await store.revision(); try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: (any Error).self) { try await transfer.prepareRestore(incoming, mode: .merge, expectedRevision: revision) }
            let plan = try await transfer.prepareRestore(incoming, mode: .replace, expectedRevision: revision)
            _ = try await transfer.commit(.init(plan: plan))
            #expect(try await store.open(id: input.id).report.input == input)
            #expect(try await transfer.status().counts.cachedSources == 1)
        }
    }
    @Test func failedTransferRetainsExactApprovalAndRestoresAllRowsAndRevision() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db), input = try frozenMarketInput()
        _ = try await store.save(input, expectedRevision: store.revision()); try await store.cache(marketCache(), expectedRevision: store.revision())
        let before = try await transfer.exportArchive(), status = try await transfer.status()
        let plan = try await transfer.prepareClear(expectedRevision: status.revision)
        await transfer.injectFailureOnNextCommit()
        await #expect(throws: MarketStateStorageError.injectedFailure) { try await transfer.commit(.init(plan: plan)) }
        #expect(try await transfer.status() == status)
        #expect(try await transfer.exportArchive() == before)
        let result = try await transfer.commit(.init(plan: plan))
        #expect(result.counts.totalReports == 0 && result.counts.cachedSources == 0)
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await transfer.commit(.init(plan: plan)) }
    }
    @Test func staleApprovalsAreConsumedAndCannotReturnAfterRevisionChanges() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let plan = try await transfer.prepareClear(expectedRevision: store.revision())
        _ = try await store.save(frozenMarketInput(), expectedRevision: store.revision())
        await #expect(throws: MarketStateStorageError.staleRevision) { try await transfer.commit(.init(plan: plan)) }
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await transfer.commit(.init(plan: plan)) }
        #expect(try await store.summaries().count == 1)
    }
    @Test func oldWriterBaselineCannotCrossClearOrReplaceAcrossConnections() async throws {
        for replace in [false, true] {
            let path = marketPath(); defer { try? FileManager.default.removeItem(at: path) }
            let store = try MarketStateStore(path: path.path), transfer = try MarketStateArchiveStore(path: path.path)
            _ = try await store.save(frozenMarketInput(), expectedRevision: store.revision())
            let revision = try await store.revision(), oldInput = try frozenMarketInput()
            let plan: MarketStateTransferPlan
            if replace {
                let empty = try await marketArchive()
                plan = try await transfer.prepareRestore(empty, mode: .replace, expectedRevision: revision)
            } else { plan = try await transfer.prepareClear(expectedRevision: revision) }
            _ = try await transfer.commit(.init(plan: plan))
            await #expect(throws: MarketStateStorageError.staleRevision) { try await store.save(oldInput, expectedRevision: revision) }
            #expect(try await store.summaries().isEmpty)
        }
    }
    @Test func exactApprovalCancelAndRestartNeverAuthorizeACommit() async throws {
        let db = try marketDB(), transfer = try MarketStateArchiveStore(database: db), revision = try await transfer.status().revision
        let plan = try await transfer.prepareClear(expectedRevision: revision)
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await transfer.commit(.init(planID: plan.id, digest: "changed", revision: revision)) }
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await transfer.commit(.init(planID: plan.id, digest: plan.digest, revision: UUID())) }
        let reopened = try MarketStateArchiveStore(database: db)
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await reopened.commit(.init(plan: plan)) }
        await transfer.cancel(plan.id)
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await transfer.commit(.init(plan: plan)) }
        #expect(try await transfer.status().revision == revision)
    }
    @Test func mergeRetainsConflictBytesAndRepeatImportIsIdempotent() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db), input = try frozenMarketInput()
        _ = try await store.save(input, expectedRevision: store.revision())
        let bytes = try await marketArchive(input), revision = try await store.revision()
        let duplicate = try await transfer.prepareRestore(bytes, mode: .merge, expectedRevision: revision)
        #expect(duplicate.result.totalReports == 1)
        _ = try await transfer.commit(.init(plan: duplicate))
        let conflict = try await marketArchive(frozenMarketInput(id: input.id, offset: 1))
        let originalIncoming = try #require(MarketStateArchiveCodec.decode(conflict).entries.first)
        let conflictPlan = try await transfer.prepareRestore(conflict, mode: .merge, expectedRevision: store.revision())
        #expect(conflictPlan.result.totalReports == 2 && conflictPlan.result.conflictCopies == 1)
        _ = try await transfer.commit(.init(plan: conflictPlan))
        let copies = try await store.summaries(), copy = try #require(copies.first { $0.id != input.id })
        #expect(copy.originalID == input.id)
        #expect(try await store.open(id: copy.id).report.input == frozenMarketInput(id: input.id, offset: 1))
        let persisted = try #require(try db.read { try MarketStateStore.load(copy.id, $0) })
        #expect(persisted.input == originalIncoming.input && persisted.report == originalIncoming.report)
        let repeated = try await transfer.prepareRestore(conflict, mode: .merge, expectedRevision: store.revision())
        #expect(repeated.result.totalReports == 2 && repeated.result.conflictCopies == 1)
        _ = try await transfer.commit(.init(plan: repeated))
        #expect(try await store.open(id: input.id).report.input == input)
    }
    @Test func conflictAcrossDocumentKindsPreservesBothOriginalInputs() async throws {
        let input = try frozenMarketInput(), db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let state = try await store.save(input, expectedRevision: store.revision())
        let source = try marketDB(), sourceStore = try MarketStateStore(database: source)
        let demo = try MarketTradeAttributionDemo.input(snapshot: state.report)
        let attribution = MarketTradeAttributionInput(id: input.id, createdAt: demo.createdAt, mode: demo.mode,
            performance: demo.performance, observations: demo.observations)
        _ = try await sourceStore.saveAttribution(attribution, expectedRevision: sourceStore.revision())
        let incoming = try await MarketStateArchiveStore(database: source).exportArchive()
        let plan = try await transfer.prepareRestore(incoming, mode: .merge, expectedRevision: store.revision())
        _ = try await transfer.commit(.init(plan: plan))
        let summaries = try await store.summaries(), retained = try #require(summaries.first { $0.kind == .tradeAttribution })
        #expect(retained.originalID == input.id && retained.id != input.id)
        #expect(try await store.openAttribution(id: retained.id).report.input == attribution)
        #expect(try await store.open(id: input.id) == state)
    }
    @Test func savingAConflictAfterDeletingOriginalReusesRetainedDirectoryIdentity() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db), input = try frozenMarketInput()
        _ = try await store.save(input, expectedRevision: store.revision())
        let changed = try frozenMarketInput(id: input.id, offset: 1), archive = try await marketArchive(changed)
        let merge = try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: store.revision())
        _ = try await transfer.commit(.init(plan: merge))
        let retained = try #require(try await store.summaries().first { $0.id != input.id })
        let deletion = try await transfer.prepareDelete(ids: [input.id], expectedRevision: store.revision())
        _ = try await transfer.commit(.init(plan: deletion))
        let before = try await store.revision()
        let saved = try await store.save(changed, expectedRevision: before)
        #expect(saved.id == retained.id && saved.report.input == changed)
        #expect(try await store.summaries().count == 1)
        #expect(try await store.revision() == before)
        #expect(try await transfer.exportArchive().count > 0)
    }
    @Test func savingRetainedConflictWhileOriginalExistsReusesOnlyVerifiedMatchingBytes() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db), input = try frozenMarketInput()
        let original = try await store.save(input, expectedRevision: store.revision())
        let changed = try frozenMarketInput(id: input.id, offset: 1), archive = try await marketArchive(changed)
        let merge = try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: store.revision())
        _ = try await transfer.commit(.init(plan: merge))
        let retained = try #require(try await store.summaries().first { $0.id != input.id }), revision = try await store.revision()
        #expect(try await store.save(changed, expectedRevision: revision).id == retained.id)
        #expect(try await store.revision() == revision)
        #expect(try await store.open(id: input.id) == original)
        #expect(try await store.summaries().count == 2)
        try db.transaction { try $0.execute(sql: "UPDATE market_state_documents SET report_json=x'00' WHERE document_id=?", arguments: [retained.id.uuidString]) }
        await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.save(changed, expectedRevision: revision) }
        #expect(try await store.revision() == revision)
        #expect(try await store.open(id: input.id) == original)
    }
    @Test func explicitDeletionRetainsOtherReportsAndCacheAndRequiresConfirmation() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let first = try frozenMarketInput(), second = try frozenMarketInput()
        _ = try await store.save(first, expectedRevision: store.revision()); _ = try await store.save(second, expectedRevision: store.revision())
        try await store.cache(marketCache(), expectedRevision: store.revision())
        let plan = try await transfer.prepareDelete(ids: [first.id], expectedRevision: store.revision())
        #expect(try await store.summaries().count == 2 && plan.result.totalReports == 1)
        _ = try await transfer.commit(.init(plan: plan))
        #expect(try await store.summaries().map(\.id) == [second.id])
        #expect(try await transfer.status().counts.cachedSources == 1)
        await #expect(throws: MarketStateStorageError.notFound) { try await store.open(id: first.id) }
    }
    @Test func archiveFormatPurposeTamperingTruncationAndNonZIPAreRejected() async throws {
        let bytes = try await marketArchive(frozenMarketInput()), files = try ResearchZIP.decode(bytes)
        let manifestBytes = try #require(files["manifest.json"]), body = try #require(files["research-state.json"])
        for field in ["format", "purpose", "stateHash", "scope"] {
            var manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any]); manifest[field] = "other"
            let changed = try ResearchZIP.encode(["manifest.json": JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]), "research-state.json": body])
            #expect(throws: (any Error).self) { try MarketStateArchiveCodec.decode(changed) }
        }
        for bad in [Data(bytes.dropLast()), Data("# Markdown export".utf8), Data("symbol,score\nDEMO,35".utf8)] {
            #expect(throws: (any Error).self) { try MarketStateArchiveCodec.decode(bad) }
        }
        let options = try await OptionLabArchiveStore(database: DatabaseStore(path: ":memory:", purpose: .optionsLab)).exportArchive()
        #expect(throws: MarketStateStorageError.unsupportedFormat) { try MarketStateArchiveCodec.decode(options) }
        #expect(throws: (any Error).self) { try OptionLabArchiveCodec.decode(bytes) }
    }
    @Test func badMetadataAndUnknownTablesCannotBeOverwrittenByRestore() async throws {
        let incoming = try await marketArchive()
        for sql in ["UPDATE market_state_metadata SET revision='not-a-uuid'", "CREATE TABLE unexpected_ownership(id TEXT)"] {
            let db = try marketDB(), transfer = try MarketStateArchiveStore(database: db), revision = try await transfer.status().revision
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: (any Error).self) { try await transfer.prepareRestore(incoming, mode: .replace, expectedRevision: revision) }
        }
    }
    @Test func pendingPlanBudgetIsBoundedAndCancellationReleasesCapacity() async throws {
        let db = try marketDB(), transfer = try MarketStateArchiveStore(database: db), revision = try await transfer.status().revision
        var plans: [MarketStateTransferPlan] = []
        for _ in 0..<8 { plans.append(try await transfer.prepareClear(expectedRevision: revision)) }
        await #expect(throws: MarketStateStorageError.budgetExceeded) { try await transfer.prepareClear(expectedRevision: revision) }
        await transfer.cancel(try #require(plans.first).id)
        #expect(try await transfer.prepareClear(expectedRevision: revision).canCommit)
    }
    @Test func alreadyCancelledWritesAndCommitsLeaveNoMutationAndApprovalCanRetry() async throws {
        let db = try marketDB(), store = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let revision = try await store.revision(), input = try frozenMarketInput()
        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(input, expectedRevision: revision)
        }
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(try await store.summaries().isEmpty)
        #expect(try await store.revision() == revision)
        _ = try await store.save(input, expectedRevision: revision)
        let plan = try await transfer.prepareClear(expectedRevision: store.revision())
        let commit = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transfer.commit(.init(plan: plan))
        }
        await #expect(throws: CancellationError.self) { try await commit.value }
        #expect(try await store.summaries().count == 1)
        _ = try await transfer.commit(.init(plan: plan))
        #expect(try await store.summaries().isEmpty)
    }
}
