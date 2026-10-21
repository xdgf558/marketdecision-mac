import Foundation
import Testing
import GRDB
import CoreDomain
import MacroProviders
import MarketAnalytics
import PortfolioEngine
@testable import Persistence

private func macroDB() throws -> DatabaseStore { try DatabaseStore(path: ":memory:", purpose: .marketState) }
private func macroPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("macro-source-" + UUID().uuidString + ".sqlite") }
private func changedMacro(_ p: MacroImportInput, id: UUID? = nil, createdAt: Date? = nil, asOf: Date? = nil,
                          descriptor: MacroSourceDescriptor? = nil, raw: Data? = nil, releases: [MacroReleaseEvidence]? = nil) -> MacroImportInput {
    .init(id: id ?? p.id, createdAt: createdAt ?? p.createdAt, retrievedAt: p.retrievedAt, asOf: asOf ?? p.asOf,
        origin: p.origin, descriptor: descriptor ?? p.descriptor, rawData: raw ?? p.rawData, releases: releases ?? p.releases)
}
private func macroRevision(_ input: MacroImportInput, revision: String) -> MacroImportInput {
    let d = input.descriptor
    let descriptor = MacroSourceDescriptor(format: d.format, series: d.series, sourceID: d.sourceID, feedID: d.feedID,
        basisVersion: d.basisVersion, population: d.population, revisionID: revision, sourceReference: d.sourceReference,
        licenseEvidence: d.licenseEvidence, cftcContractCode: d.cftcContractCode, cftcScope: d.cftcScope)
    let releases = input.releases.map { MacroReleaseEvidence(series: $0.series, observationDate: $0.observationDate, vintageID: revision,
        releasedAt: $0.releasedAt, availableAt: $0.availableAt, evidenceReference: $0.evidenceReference) }
    return changedMacro(input, id: UUID(), descriptor: descriptor, releases: releases)
}
private func macroBridge(_ source: MacroSourceReport, id: UUID = UUID()) -> MacroMarketBridgeInput {
    let now = source.input.createdAt
    let base = MarketStateInput(id: UUID(), createdAt: now, asOf: now, sessionDate: "2026-10-19",
        sessions: [.init(date: "2026-10-19", closeAt: now)], calendarEvidence: "SYNTHETIC calendar for persistence", series: [])
    return .init(id: id, createdAt: now, base: base, sources: [source])
}
private func macroArchive(_ input: MacroImportInput) async throws -> Data {
    let db = try macroDB(), store = try MacroSourceStore(database: db)
    _ = try await store.save(input, expectedRevision: store.revision())
    return try await MarketStateArchiveStore(database: db).exportArchive()
}
private func macroCache() -> MarketSourceCacheEntry {
    .init(id: UUID(), sourceID: "SYNTHETIC", feedID: "SYNTHETIC", evidenceReference: "synthetic fixture",
        retrievedAt: Date(timeIntervalSince1970: 1_792_443_600), payload: Data("unrelated purgeable cache".utf8))
}

@Suite("Macro source frozen byte, vintage and archive persistence")
struct MacroSourcePersistenceTests {
    @Test func purposeIsolationAndAdditiveV1MigrationPreserveFrozenBytesAndRevision() async throws {
        for purpose in [DatabasePurpose.business, .secResearch, .portfolioLedger, .optionsLab] {
            let db = try DatabaseStore(path: ":memory:", purpose: purpose), before = try db.migrationVersions()
            #expect(throws: MarketStateStorageError.incompatiblePurpose) { _ = try MacroSourceStore(database: db) }
            #expect(try db.migrationVersions() == before)
        }
        let path = macroPath(); defer { try? FileManager.default.removeItem(at: path) }
        let source = try MacroSourceDemo.input(format: .cboeIndexHistoryCSV)
        let base = macroBridge(try MacroSourceEngine.evaluate(source)).base
        let report = try MarketStateEngine.calculate(base)
        let entry = try MarketStoredEntry.make(id: base.id, createdAt: base.createdAt, kind: .marketState, synthetic: report.containsSynthetic,
            input: MarketStateStore.encode(base), report: MarketStateStore.encode(report))
        let revision = UUID()
        do {
            let queue = try DatabaseQueue(path: path.path)
            try await queue.write { try $0.execute(sql: "PRAGMA application_id=1296321841") }
            var migrator = DatabaseMigrator()
            migrator.registerMigration("foundation.v1") { _ in }
            migrator.registerMigration("market-state.v1", migrate: DatabaseStore.marketStateMigration.migrate)
            try migrator.migrate(queue)
            try await queue.write { db in
                try entry.insert(db)
                try db.execute(sql: "UPDATE market_state_metadata SET revision=?", arguments: [revision.uuidString])
            }
        }
        let upgraded = try DatabaseStore(path: path.path, purpose: .marketState)
        #expect(try upgraded.migrationVersions() == ["foundation.v1", "market-state.v1", "market-state.v2"])
        #expect(try await MacroSourceStore(database: upgraded).revision() == revision)
        #expect(try upgraded.read { try MarketStateStore.load(base.id, $0) } == entry)
        #expect(try await MarketStateStore(database: upgraded).open(id: base.id).report == report)
    }
    @Test func exactRawAndTypedVintagesSurvivePurgeAndReopen() async throws {
        let path = macroPath(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try MacroSourceStore(path: path.path), state = try MarketStateStore(path: path.path)
        let input = try MacroSourceDemo.input(format: .alfredObservationsJSON)
        let saved = try await store.save(input, expectedRevision: store.revision())
        try await state.cache(macroCache(), expectedRevision: state.revision()); try await state.purgeCache(expectedRevision: state.revision())
        let reopened = try MacroSourceStore(path: path.path)
        #expect(try await reopened.open(id: saved.id) == saved)
        #expect(saved.report.observations.count == 2 && saved.report.selectedObservations.count == 1)
        let db = try DatabaseStore(path: path.path, purpose: .marketState)
        #expect(try db.read { try Data.fetchOne($0, sql: "SELECT payload FROM market_macro_sources") } == input.rawData)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM market_macro_observations") } == 2)
        #expect(try await MarketStateArchiveStore(database: db).status().counts.cachedSources == 0)
    }
    @Test func repeatedImportAcrossNewUUIDAndCreationTimeReusesOriginalFrozenIdentity() async throws {
        let store = try MacroSourceStore(database: macroDB()), input = try MacroSourceDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision()), revision = try await store.revision()
        let repeated = changedMacro(input, id: UUID(), createdAt: input.createdAt.addingTimeInterval(123))
        #expect(try MacroSourceContentIdentity.hash(input) == MacroSourceContentIdentity.hash(repeated))
        #expect(try await store.save(repeated, expectedRevision: revision) == saved)
        #expect(saved.report.input.id == input.id && saved.report.input.createdAt == input.createdAt)
        #expect(try await store.revision() == revision)
        #expect(try await store.summaries().count == 1)
    }
    @Test func cutoffAndReleaseEvidenceAreMaterialEvenWhenSourceBytesAreIdentical() async throws {
        let store = try MacroSourceStore(database: macroDB()), original = try MacroSourceDemo.input(format: .alfredObservationsJSON)
        let undated = changedMacro(original, id: UUID(), releases: [])
        let first = try await store.save(undated, expectedRevision: store.revision())
        #expect(first.report.selectedObservations.isEmpty)
        let verified = try await store.save(original, expectedRevision: store.revision())
        let earlier = changedMacro(original, id: UUID(), asOf: original.asOf.addingTimeInterval(-86_400))
        let historical = try await store.save(earlier, expectedRevision: store.revision())
        #expect(first.id != verified.id && verified.id != historical.id)
        #expect(verified.report.selectedObservations.first?.value == (try Money("3.750")))
        #expect(historical.report.selectedObservations.first?.value == (try Money("3.500")))
        #expect(try await store.summaries().count == 3)
    }
    @Test func newFileVintagesRemainAvailableWithoutOverwritingOldRawBytes() async throws {
        let store = try MacroSourceStore(database: macroDB()), input = try MacroSourceDemo.input(format: .cboeIndexHistoryCSV)
        let first = try await store.save(input, expectedRevision: store.revision())
        let secondInput = macroRevision(input, revision: "SYNTHETIC-file-v2")
        let second = try await store.save(secondInput, expectedRevision: store.revision())
        #expect(first.id != second.id && first.report.contentSHA256 == second.report.contentSHA256)
        #expect(try await store.open(id: first.id) == first)
        #expect(second.report.observations.allSatisfy { $0.vintageID == "SYNTHETIC-file-v2" })
    }
    @Test func conflictingSameVintageValuesAndExplicitReleaseClocksAreRejected() async throws {
        let store = try MacroSourceStore(database: macroDB()), input = try MacroSourceDemo.input(format: .cboeIndexHistoryCSV)
        _ = try await store.save(input, expectedRevision: store.revision()); let revision = try await store.revision()
        let changed = Data(try #require(String(data: input.rawData, encoding: .utf8)).replacingOccurrences(of: ",18.00\r\n", with: ",19.00\r\n").utf8)
        await #expect(throws: MarketStateStorageError.identityConflict) { try await store.save(changedMacro(input, id: UUID(), raw: changed), expectedRevision: revision) }
        let releases = input.releases.map { MacroReleaseEvidence(series: $0.series, observationDate: $0.observationDate, vintageID: $0.vintageID,
            releasedAt: $0.releasedAt.addingTimeInterval(-1), availableAt: $0.availableAt, evidenceReference: $0.evidenceReference) }
        await #expect(throws: MarketStateStorageError.identityConflict) { try await store.save(changedMacro(input, id: UUID(), releases: releases), expectedRevision: revision) }
        #expect(try await store.revision() == revision)
        #expect(try await store.summaries().count == 1)
    }
    @Test func sourceDirectoryNeverPublishesValuesAndDoesNotDecodeBodies() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), input = try MacroSourceDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision()), summaries = try await store.summaries()
        let bytes = try #require(try db.read { try Data.fetchOne($0, sql: "SELECT summary_json FROM market_macro_catalog") })
        let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(fields["observations"] == nil && fields["selectedObservations"] == nil && fields["value"] == nil)
        try db.transaction { try $0.execute(sql: "UPDATE market_macro_documents SET report_json=x'00'") }
        #expect(try await store.summaries() == summaries)
        await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.open(id: saved.id) }
    }
    @Test func rawTypedAndIndexCorruptionRejectOpenDuplicateAndArchive() async throws {
        let corruptions = ["UPDATE market_macro_sources SET payload=x'00'", "UPDATE market_macro_sources SET source_id='other'",
            "UPDATE market_macro_sources SET feed_id='other'", "UPDATE market_macro_sources SET source_format='other'",
            "UPDATE market_macro_sources SET revision_id='other'", "UPDATE market_macro_observations SET observation_date='2020-01-01'",
            "UPDATE market_macro_observations SET version_key=printf('%064d',0)", "UPDATE market_macro_observations SET record_json=x'00'",
            "DELETE FROM market_macro_observations", "UPDATE market_macro_catalog SET content_key=printf('%064d',0)"]
        for sql in corruptions {
            let db = try macroDB(), store = try MacroSourceStore(database: db), input = try MacroSourceDemo.input()
            let saved = try await store.save(input, expectedRevision: store.revision()), revision = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.open(id: saved.id) }
            await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.save(input, expectedRevision: revision) }
            await #expect(throws: MarketStateStorageError.corruptedStorage) { try await MarketStateArchiveStore(database: db).exportArchive() }
        }
    }
    @Test func selfConsistentOuterHashesCannotTurnAlteredReportIntoVerifiedResults() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), input = try MacroSourceDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision())
        try db.transaction { connection in
            let bytes = try #require(try Data.fetchOne(connection, sql: "SELECT report_json FROM market_macro_documents"))
            var fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); fields["selectedObservations"] = []
            let report = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
            let old = try #require(try Data.fetchOne(connection, sql: "SELECT summary_json FROM market_macro_catalog"))
            var summary = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any]); summary["reportHash"] = LedgerCSV.hash(report)
            let updated = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
            try connection.execute(sql: "UPDATE market_macro_documents SET report_json=?", arguments: [report])
            try connection.execute(sql: "UPDATE market_macro_catalog SET report_hash=?,summary_hash=?,summary_json=?", arguments: [LedgerCSV.hash(report), LedgerCSV.hash(updated), updated])
        }
        #expect(try await store.summaries().count == 1)
        await #expect(throws: MarketStateStorageError.corruptedStorage) { try await store.open(id: saved.id) }
    }
    @Test func saveFailureAndSQLiteAbortRollBackRawTypedReportAndRevisionTogether() async throws {
        for trigger in [false, true] {
            let db = try macroDB(), store = try MacroSourceStore(database: db), input = try MacroSourceDemo.input(), revision = try await store.revision()
            if trigger { try db.transaction { try $0.execute(sql: "CREATE TRIGGER reject_macro_revision BEFORE UPDATE ON market_state_metadata BEGIN SELECT RAISE(ABORT,'synthetic'); END") } }
            else { await store.injectFailureOnNextSave() }
            await #expect(throws: (any Error).self) { try await store.save(input, expectedRevision: revision) }
            #expect(try await store.revision() == revision)
        #expect(try await store.summaries().isEmpty)
            for table in ["market_macro_sources", "market_macro_observations", "market_macro_documents"] {
                #expect(try db.read { try MarketStateStore.count(table, $0) } == 0)
            }
            if trigger { try db.transaction { try $0.execute(sql: "DROP TRIGGER reject_macro_revision") } }
            #expect(try await store.save(input, expectedRevision: revision).replayMatched)
        }
    }
    @Test func bridgeFreezesOriginalSourcesAndDoesNotDependOnSourceDirectoryOrCache() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), market = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let source = try await store.save(MacroSourceDemo.input(format: .cboeIndexHistoryCSV), expectedRevision: store.revision())
        let bridge = try await store.saveBridge(macroBridge(source.report), expectedRevision: store.revision())
        let plan = try await transfer.prepareDelete(ids: [source.id], expectedRevision: store.revision())
        _ = try await transfer.commit(.init(plan: plan))
        try await market.cache(macroCache(), expectedRevision: market.revision()); try await market.purgeCache(expectedRevision: market.revision())
        #expect(try await store.openBridge(id: bridge.id) == bridge)
        #expect(bridge.report.input.sources.first?.input.rawData == source.report.input.rawData)
        await #expect(throws: MarketStateStorageError.notFound) { try await store.open(id: source.id) }
        #expect(try await transfer.status().counts.frozenSources == 1)
    }
    @Test func bridgeSaveIsIdempotentAcrossNewDirectoryIdentity() async throws {
        let store = try MacroSourceStore(database: macroDB()), source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        let input = macroBridge(source), saved = try await store.saveBridge(input, expectedRevision: store.revision()), revision = try await store.revision()
        let repeated = MacroMarketBridgeInput(createdAt: input.createdAt.addingTimeInterval(3), base: input.base, sources: input.sources)
        #expect(try await store.saveBridge(repeated, expectedRevision: revision) == saved)
        #expect(try await store.revision() == revision)
        await #expect(throws: MarketStateStorageError.unsupportedFormat) { try await store.open(id: saved.id) }
    }
    @Test func v2ArchiveContainsMacroAndBridgeBodiesButNoPurgeableCache() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), market = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let source = try await store.save(MacroSourceDemo.input(format: .cboeIndexHistoryCSV), expectedRevision: store.revision())
        let bridge = try await store.saveBridge(macroBridge(source.report), expectedRevision: store.revision())
        try await market.cache(macroCache(), expectedRevision: market.revision())
        let archive = try await transfer.exportArchive(), files = try ResearchZIP.decode(archive)
        let manifest = try JSONDecoder().decode(MarketStateArchiveCodec.Manifest.self, from: #require(files["manifest.json"]))
        #expect(manifest.format == "market-state-archive.v2" && manifest.macroReports == 1 && manifest.bridgeReports == 1 && manifest.frozenSources == 2)
        let target = try macroDB(), restore = try MarketStateArchiveStore(database: target), reader = try MacroSourceStore(database: target)
        let plan = try await restore.prepareRestore(archive, mode: .replace, expectedRevision: reader.revision())
        _ = try await restore.commit(.init(plan: plan))
        #expect(try await reader.open(id: source.id) == source)
        #expect(try await reader.openBridge(id: bridge.id) == bridge)
        #expect(try await restore.status().counts.cachedSources == 0)
    }
    @Test func exactLegacyV1ArchiveRemainsReadableWithoutRewritingFrozenInputBytes() async throws {
        let db = try macroDB(), store = try MarketStateStore(database: db)
        let base = macroBridge(try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))).base
        let saved = try await store.save(base, expectedRevision: store.revision())
        let entry = try #require(try db.read { try MarketStateStore.load(saved.id, $0) })
        let old = MarketArchiveState(format: MarketArchiveState.legacyFormat, entries: [entry]), stateBytes = try MarketStateStore.encode(old)
        let manifest = MarketStateArchiveCodec.Manifest(format: MarketStateArchiveCodec.legacyFormat, purpose: "MDM1", encrypted: false,
            stateBytes: stateBytes.count, stateHash: LedgerCSV.hash(stateBytes), marketReports: 1, attributionReports: 0,
            macroReports: nil, bridgeReports: nil, frozenSources: nil, sourceObservations: nil, scope: MarketStateArchiveCodec.legacyScope)
        let bytes = try ResearchZIP.encode(["manifest.json": MarketStateStore.encode(manifest), "research-state.json": stateBytes])
        let upgraded = try MarketStateArchiveCodec.decode(bytes)
        #expect(upgraded.format == MarketArchiveState.format && upgraded.macroEntries.isEmpty && upgraded.entries == [entry])
        let target = try macroDB(), transfer = try MarketStateArchiveStore(database: target), reader = try MarketStateStore(database: target)
        let plan = try await transfer.prepareRestore(bytes, mode: .merge, expectedRevision: reader.revision())
        _ = try await transfer.commit(.init(plan: plan))
        #expect(try await reader.open(id: saved.id) == saved)
        #expect(try target.read { try MarketStateStore.load(saved.id, $0) }?.input == entry.input)
    }
    @Test func replaceRepairsCorruptMacroRowsWhileMergeRefusesAndCacheRemains() async throws {
        let input = try MacroSourceDemo.input(), archive = try await macroArchive(input)
        for sql in ["UPDATE market_macro_documents SET input_json=x'00'", "UPDATE market_macro_sources SET payload=x'00'",
                    "UPDATE market_macro_observations SET record_json=x'00'", "DELETE FROM market_macro_observations", "UPDATE market_macro_catalog SET summary_json=x'00'"] {
            let db = try macroDB(), store = try MacroSourceStore(database: db), market = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
            _ = try await store.save(MacroSourceDemo.input(), expectedRevision: store.revision()); try await market.cache(macroCache(), expectedRevision: market.revision())
            let revision = try await store.revision(); try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: MarketStateStorageError.corruptedStorage) { try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: revision) }
            let plan = try await transfer.prepareRestore(archive, mode: .replace, expectedRevision: revision)
            _ = try await transfer.commit(.init(plan: plan))
            #expect(try await store.open(id: input.id).report.input == input)
            #expect(try await transfer.status().counts.cachedSources == 1)
        }
    }
    @Test func sourceConflictCopiesKeepOriginalBytesAndRepeatMergeDoesNotBumpRevision() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), transfer = try MarketStateArchiveStore(database: db), input = try MacroSourceDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision())
        let changed = changedMacro(input, asOf: input.asOf.addingTimeInterval(-86_400)), archive = try await macroArchive(changed)
        let incoming = try #require(MarketStateArchiveCodec.decode(archive).macroEntries.first)
        let plan = try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: store.revision())
        #expect(plan.result.conflictCopies == 1 && plan.result.macroReports == 2)
        _ = try await transfer.commit(.init(plan: plan))
        let copy = try #require(try await store.summaries().first { $0.id != input.id }), revision = try await store.revision()
        let entry = try #require(try db.read { try MacroSourceStore.load(copy.id, $0) })
        #expect(entry.input == incoming.input && entry.report == incoming.report && copy.originalID == input.id)
        #expect(try await store.save(changedMacro(changed, id: UUID()), expectedRevision: revision).id == copy.id)
        let repeated = try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: revision)
        _ = try await transfer.commit(.init(plan: repeated))
        #expect(try await store.revision() == revision)
        #expect(try await store.open(id: saved.id) == saved)
    }
    @Test func crossKindIdentityConflictIsRetainedWithoutChangingEitherFrozenIdentity() async throws {
        let input = try MacroSourceDemo.input(format: .cboeIndexHistoryCSV), archive = try await macroArchive(input)
        let db = try macroDB(), market = try MarketStateStore(database: db), macro = try MacroSourceStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let base = macroBridge(try MacroSourceEngine.evaluate(input)).base
        let matching = MarketStateInput(id: input.id, createdAt: base.createdAt, asOf: base.asOf, sessionDate: base.sessionDate,
            sessions: base.sessions, calendarEvidence: base.calendarEvidence, series: base.series)
        let saved = try await market.save(matching, expectedRevision: market.revision())
        await #expect(throws: MarketStateStorageError.identityConflict) { try await macro.save(input, expectedRevision: macro.revision()) }
        let plan = try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: macro.revision())
        _ = try await transfer.commit(.init(plan: plan))
        let copy = try #require(try await macro.summaries().first)
        #expect(copy.id != input.id && copy.originalID == input.id)
        #expect(try await macro.open(id: copy.id).report.input == input)
        #expect(try await market.open(id: saved.id) == saved)
    }
    @Test func destructiveCommitFailureRetainsPlanAndRollsBackAllMacroTables() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        _ = try await store.save(MacroSourceDemo.input(), expectedRevision: store.revision())
        let before = try await transfer.exportArchive(), status = try await transfer.status(), plan = try await transfer.prepareClear(expectedRevision: status.revision)
        await transfer.injectFailureOnNextCommit()
        await #expect(throws: MarketStateStorageError.injectedFailure) { try await transfer.commit(.init(plan: plan)) }
        #expect(try await transfer.status() == status)
        #expect(try await transfer.exportArchive() == before)
        _ = try await transfer.commit(.init(plan: plan))
        #expect(try await transfer.status().counts.totalReports == 0)
        #expect(try await store.summaries().isEmpty)
    }
    @Test func oldSourceWriterCannotAcquirePostClearOrPostReplaceRevision() async throws {
        for replacing in [false, true] {
            let path = macroPath(); defer { try? FileManager.default.removeItem(at: path) }
            let store = try MacroSourceStore(path: path.path), transfer = try MarketStateArchiveStore(path: path.path), input = try MacroSourceDemo.input()
            _ = try await store.save(input, expectedRevision: store.revision()); let oldRevision = try await store.revision()
            let plan: MarketStateTransferPlan
            if replacing { plan = try await transfer.prepareRestore(MarketStateArchiveCodec.encode(.empty), mode: .replace, expectedRevision: oldRevision) }
            else { plan = try await transfer.prepareClear(expectedRevision: oldRevision) }
            _ = try await transfer.commit(.init(plan: plan))
            await #expect(throws: MarketStateStorageError.staleRevision) { try await store.save(changedMacro(input, id: UUID()), expectedRevision: oldRevision) }
            #expect(try await store.summaries().isEmpty)
        }
    }
    @Test func crossPageWritesInvalidatePreparedMacroRestoreAndConsumeApproval() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), market = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let archive = try await macroArchive(MacroSourceDemo.input())
        let plan = try await transfer.prepareRestore(archive, mode: .merge, expectedRevision: store.revision())
        try await market.cache(macroCache(), expectedRevision: market.revision())
        await #expect(throws: MarketStateStorageError.staleRevision) { try await transfer.commit(.init(plan: plan)) }
        await #expect(throws: MarketStateStorageError.invalidPlan) { try await transfer.commit(.init(plan: plan)) }
        #expect(try await store.summaries().isEmpty)
    }
    @Test func explicitMacroDeletionKeepsOtherMarketReportsAndIndependentDatabases() async throws {
        let db = try macroDB(), store = try MacroSourceStore(database: db), market = try MarketStateStore(database: db), transfer = try MarketStateArchiveStore(database: db)
        let source = try await store.save(MacroSourceDemo.input(format: .cboeIndexHistoryCSV), expectedRevision: store.revision())
        let other = try await market.save(macroBridge(source.report).base, expectedRevision: market.revision())
        let plan = try await transfer.prepareDelete(ids: [source.id], expectedRevision: store.revision())
        #expect(plan.result.macroReports == 0 && plan.result.marketReports == 1)
        _ = try await transfer.commit(.init(plan: plan))
        #expect(try await market.open(id: other.id) == other)
        let names = try db.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        #expect(names.allSatisfy { !$0.hasPrefix("ledger_") && !$0.hasPrefix("p1_") && !$0.hasPrefix("option_") })
    }
    @Test func unknownPurposeOrVersionAndCorruptIncomingSourcesNeverReachCommit() async throws {
        let input = try MacroSourceDemo.input(), bytes = try await macroArchive(input), files = try ResearchZIP.decode(bytes)
        let manifest = try #require(files["manifest.json"]), state = try #require(files["research-state.json"])
        for field in ["purpose", "format", "scope"] {
            var fields = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any]); fields[field] = "other"
            let bad = try ResearchZIP.encode(["manifest.json": JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]), "research-state.json": state])
            #expect(throws: MarketStateStorageError.unsupportedFormat) { try MarketStateArchiveCodec.decode(bad) }
        }
        var stateFields = try #require(JSONSerialization.jsonObject(with: state) as? [String: Any])
        var entries = try #require(stateFields["macroEntries"] as? [[String: Any]]); entries[0]["report"] = Data("bad".utf8).base64EncodedString(); stateFields["macroEntries"] = entries
        let corrupt = try JSONSerialization.data(withJSONObject: stateFields, options: [.sortedKeys, .withoutEscapingSlashes])
        var fields = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any]); fields["stateHash"] = LedgerCSV.hash(corrupt); fields["stateBytes"] = corrupt.count
        let bad = try ResearchZIP.encode(["manifest.json": JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]), "research-state.json": corrupt])
        #expect(throws: MarketStateStorageError.corruptedStorage) { try MarketStateArchiveCodec.decode(bad) }
    }
    @Test func cancelledSourceSaveCannotLeavePartialRowsOrChangeRevision() async throws {
        let store = try MacroSourceStore(database: macroDB()), input = try MacroSourceDemo.input(), revision = try await store.revision()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await store.save(input, expectedRevision: revision) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.revision() == revision)
        #expect(try await store.summaries().isEmpty)
    }
}
