import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine
@testable import Persistence

private func oeDB() throws -> DatabaseStore { try DatabaseStore(path: ":memory:", purpose: .optionsLab) }
private func oePath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("option-evidence-" + UUID().uuidString + ".sqlite") }
private func oeInputs() throws -> [OptionEvidenceInput] {
    [.providerComparison(try OptionProviderComparisonDemo.input()), .delta25(try OptionDelta25Demo.input()),
     .tradeAttribution(try TradeOptionAttributionDemo.input())]
}
private func oeChanged(_ input: TradeOptionAttributionInput) -> TradeOptionAttributionInput {
    .init(id: input.id, createdAt: input.createdAt.addingTimeInterval(1), mode: input.mode, performance: input.performance, observations: input.observations)
}
private func oeLegacy(_ database: DatabaseStore, version: Int, extraTable: Bool = false) throws -> Data {
    let state = try database.read(OptionLabArchiveState.capture)
    let formats = [(OptionLabArchiveState.legacyFormat, OptionLabArchiveCodec.legacyFormat, 8),
                   (OptionLabArchiveState.chainFormat, OptionLabArchiveCodec.chainFormat, 10),
                   (OptionLabArchiveState.portfolioFormat, OptionLabArchiveCodec.portfolioFormat, 12)]
    let selected = formats[version - 1]
    let old = OptionLabArchiveState(format: selected.0, revision: state.revision, tables: Array(state.tables.prefix(selected.2 + (extraTable ? 1 : 0))))
    let bytes = try OptionLabArchiveCodec.canonical(old)
    let manifest = OptionLabArchiveCodec.Manifest(format: selected.1, purpose: "MDQ1", encrypted: false,
        stateHash: LedgerCSV.hash(bytes), stateBytes: bytes.count, embeddedLedgerBases: old.counts.embeddedLedgerBases,
        ledgerBasisScope: OptionLabArchiveCodec.ledgerBasisScope)
    return try ResearchZIP.encode(["manifest.json": OptionLabArchiveCodec.canonical(manifest), "research-state.json": bytes])
}

@Suite("Option evidence immutable storage and archive")
struct OptionEvidenceStorageTests {
    @Test func allThreeFamiliesSaveAndReopenByExactFrozenInput() async throws {
        let path = oePath(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try OptionEvidenceStore(path: path.path), inputs = try oeInputs()
        var saved: [SavedOptionEvidence] = []
        for input in inputs { saved.append(try await store.save(input, expectedRevision: store.revision())) }
        let reopened = try OptionEvidenceStore(path: path.path)
        let summaries = try await reopened.summaries()
        #expect(Set(summaries.map(\.kind)) == Set(OptionEvidenceKind.allCases))
        #expect(summaries.allSatisfy { $0.containsSynthetic })
        for (input, expected) in zip(inputs, saved) {
            let actual = try await reopened.open(id: input.id)
            #expect(actual == expected && actual.replayMatched && actual.report.input == input)
            #expect(try OptionEvidenceEngine.replay(actual.report) == actual.report)
        }
    }
    @Test func identicalSaveIsIdempotentAndSameIdentityDifferentInputRejected() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = try TradeOptionAttributionDemo.input()
        let saved = try await store.save(.tradeAttribution(input), expectedRevision: store.revision())
        let revision = try await store.revision(), before = try db.read(OptionLabArchiveState.capture)
        #expect(try await store.save(.tradeAttribution(input), expectedRevision: revision) == saved)
        #expect(try await store.revision() == revision)
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(.tradeAttribution(oeChanged(input)), expectedRevision: revision) }
        let otherKind = try OptionProviderComparisonDemo.input(id: input.id)
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(.providerComparison(otherKind), expectedRevision: revision) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
    }
    @Test func metadataOnlyCatalogCannotPublishCorruptBodyAsVerified() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = try TradeOptionAttributionDemo.input()
        _ = try await store.save(.tradeAttribution(input), expectedRevision: store.revision())
        let previous = try await store.summaries()
        try db.transaction { try $0.execute(sql: "UPDATE option_evidence_documents SET report_json=x'00'") }
        #expect(try await store.summaries() == previous)
        let bytes = try #require(try db.read { try Data.fetchOne($0, sql: "SELECT summary_json FROM option_evidence_catalog") })
        let summary = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(summary["rows"] == nil && summary["groupedStatistics"] == nil && summary["localValue"] == nil)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
    }
    @Test func changedIndexHashesBodiesAndMissingDocumentRejectOpenDuplicateAndExport() async throws {
        for sql in ["UPDATE option_evidence_catalog SET kind='delta25'",
                    "UPDATE option_evidence_catalog SET report_hash='0000000000000000000000000000000000000000000000000000000000000000'",
                    "UPDATE option_evidence_catalog SET summary_json=x'00'",
                    "UPDATE option_evidence_documents SET input_json=x'00'",
                    "UPDATE option_evidence_documents SET report_json=x'00'",
                    "DELETE FROM option_evidence_documents"] {
            let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
            _ = try await store.save(input, expectedRevision: store.revision()); let revision = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.save(input, expectedRevision: revision) }
            await #expect(throws: (any Error).self) { try await OptionLabArchiveStore(database: db).exportArchive() }
        }
    }
    @Test func consistentOuterHashesCannotHideChangedCalculatedResult() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
        _ = try await store.save(input, expectedRevision: store.revision())
        try db.transaction { connection in
            let old = try #require(try Data.fetchOne(connection, sql: "SELECT report_json FROM option_evidence_documents"))
            var wrapper = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
            var selected = try #require(wrapper["tradeAttribution"] as? [String: Any])
            var report = try #require(selected["_0"] as? [String: Any])
            report["researchOnly"] = false; selected["_0"] = report; wrapper["tradeAttribution"] = selected
            let bytes = try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys, .withoutEscapingSlashes])
            let oldSummary = try #require(try Data.fetchOne(connection, sql: "SELECT summary_json FROM option_evidence_catalog"))
            var summary = try #require(JSONSerialization.jsonObject(with: oldSummary) as? [String: Any]); summary["reportHash"] = LedgerCSV.hash(bytes)
            let summaryBytes = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
            try connection.execute(sql: "UPDATE option_evidence_documents SET report_json=?", arguments: [bytes])
            try connection.execute(sql: "UPDATE option_evidence_catalog SET report_hash=?,summary_hash=?,summary_json=?",
                arguments: [LedgerCSV.hash(bytes), LedgerCSV.hash(summaryBytes), summaryBytes])
        }
        #expect(try await store.summaries().count == 1)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
        await #expect(throws: (any Error).self) { try await OptionLabArchiveStore(database: db).exportArchive() }
    }
    @Test func injectedSaveFailureRollsBackCatalogBodyAndRevisionAndRetries() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
        let before = try db.read(OptionLabArchiveState.capture), revision = try await store.revision()
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) { try await store.save(input, expectedRevision: revision) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        #expect(try await store.save(input, expectedRevision: revision).replayMatched)
    }
    @Test func sqliteAbortAfterBothWritesAlsoLeavesNoHalfDocument() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
        let before = try db.read(OptionLabArchiveState.capture), revision = try await store.revision()
        try db.transaction { try $0.execute(sql: "CREATE TRIGGER reject_evidence_revision BEFORE UPDATE ON option_lab_metadata BEGIN SELECT RAISE(ABORT,'synthetic failure'); END") }
        await #expect(throws: (any Error).self) { try await store.save(input, expectedRevision: revision) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        try db.transaction { try $0.execute(sql: "DROP TRIGGER reject_evidence_revision") }
        #expect(try await store.save(input, expectedRevision: revision).replayMatched)
    }
    @Test func clearAndReplaceRejectOldWriterBaselineAcrossConnections() async throws {
        for replace in [false, true] {
            let path = oePath(); defer { try? FileManager.default.removeItem(at: path) }
            let store = try OptionEvidenceStore(path: path.path), archive = try OptionLabArchiveStore(path: path.path)
            _ = try await store.save(.tradeAttribution(TradeOptionAttributionDemo.input()), expectedRevision: store.revision())
            let before = try await store.revision(), next = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input()), plan: OptionLabTransferPlan
            if replace {
                let empty = try await OptionLabArchiveStore(database: oeDB()).exportArchive()
                plan = try await archive.prepareRestore(empty, mode: .replace, expectedRevision: before)
            } else { plan = try await archive.prepareClear(expectedRevision: before) }
            _ = try await archive.commit(.init(plan: plan))
            await #expect(throws: OptionLabStoreError.staleRevision) { try await store.save(next, expectedRevision: before) }
            #expect(try await store.summaries().isEmpty)
        }
    }
    @Test func archiveV4PreservesAllFamiliesAndNeverRestoresActualLedger() async throws {
        let source = try oeDB(), store = try OptionEvidenceStore(database: source)
        let inputs = try oeInputs()
        for input in inputs { _ = try await store.save(input, expectedRevision: store.revision()) }
        let bytes = try await OptionLabArchiveStore(database: source).exportArchive(), files = try ResearchZIP.decode(bytes)
        let manifest = try JSONDecoder().decode(OptionLabArchiveCodec.Manifest.self, from: #require(files["manifest.json"]))
        #expect(manifest.format == "options-lab-archive.v4" && !manifest.encrypted && manifest.embeddedLedgerBases == 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerPath = directory.appendingPathComponent("portfolio-ledger.sqlite"), optionsPath = directory.appendingPathComponent("options-lab.sqlite")
        let ledger = try LedgerStore(path: ledgerPath.path)
        _ = try await ledger.createAccount(.init(id: "outside", name: "Independent real ledger boundary"), expectedRevision: ledger.snapshot().revision)
        let actual = try await ledger.snapshot(), ledgerBytes = try Data(contentsOf: ledgerPath)
        let target = try DatabaseStore(path: optionsPath.path, purpose: .optionsLab), archive = try OptionLabArchiveStore(database: target)
        let plan = try await archive.prepareRestore(bytes, mode: .replace, expectedRevision: archive.status().revision)
        #expect(plan.result.evidenceReports == 3 && plan.result.embeddedLedgerBases == 1)
        _ = try await archive.commit(.init(plan: plan))
        #expect(try target.read(OptionLabArchiveState.capture).tables == source.read(OptionLabArchiveState.capture).tables)
        let reopened = try OptionEvidenceStore(path: optionsPath.path)
        for input in inputs { #expect(try await reopened.open(id: input.id).report.input == input) }
        #expect(try await ledger.snapshot() == actual)
        #expect(try Data(contentsOf: ledgerPath) == ledgerBytes)
    }
    @Test func v1V2V3UpgradeKeepsOldBodiesAndStartsEvidenceTablesEmpty() async throws {
        let source = try oeDB(), old = try OptionLabDemo.input(), lab = try OptionLabStore(database: source)
        let saved = try await lab.save(id: old.id, input: old, expectedRevision: lab.revision())
        let oldBytes = try source.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") }
        for version in [1, 2, 3] {
            let raw = try oeLegacy(source, version: version), decoded = try OptionLabArchiveCodec.decode(raw)
            #expect(decoded.format == OptionLabArchiveState.format && decoded.counts.evidenceReports == 0)
            for mode in [OptionLabRestoreMode.merge, .replace] {
                let target = try oeDB(), store = try OptionEvidenceStore(database: target), current = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
                _ = try await store.save(current, expectedRevision: store.revision())
                let archive = try OptionLabArchiveStore(database: target)
                let plan = try await archive.prepareRestore(raw, mode: mode, expectedRevision: archive.status().revision)
                _ = try await archive.commit(.init(plan: plan))
                #expect(try await OptionLabStore(database: target).open(id: old.id) == saved)
                #expect(try target.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") } == oldBytes)
                #expect(try await store.summaries().count == (mode == .merge ? 1 : 0))
            }
        }
    }
    @Test func oldFormatCannotSmuggleNewTablesEvenWhenHashIsValid() throws {
        let source = try oeDB()
        for version in [1, 2, 3] {
            let raw = try oeLegacy(source, version: version, extraTable: true)
            #expect(throws: (any Error).self) { try OptionLabArchiveCodec.decode(raw) }
        }
    }
    @Test func mergeConflictIsExplicitAndDoesNotModifyDestination() async throws {
        let source = try oeDB(), target = try oeDB(), original = try TradeOptionAttributionDemo.input()
        let sourceStore = try OptionEvidenceStore(database: source), targetStore = try OptionEvidenceStore(database: target)
        _ = try await sourceStore.save(.tradeAttribution(original), expectedRevision: sourceStore.revision())
        _ = try await targetStore.save(.tradeAttribution(oeChanged(original)), expectedRevision: targetStore.revision())
        let bytes = try await OptionLabArchiveStore(database: source).exportArchive(), archive = try OptionLabArchiveStore(database: target)
        let before = try target.read(OptionLabArchiveState.capture)
        await #expect(throws: OptionLabArchiveError.identityConflict) { try await archive.prepareRestore(bytes, mode: .merge, expectedRevision: archive.status().revision) }
        #expect(try target.read(OptionLabArchiveState.capture) == before)
    }
    @Test func identicalMergeKeepsBytesAndFailedRestoreRetriesSamePlan() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), input = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
        let saved = try await store.save(input, expectedRevision: store.revision()), archive = try OptionLabArchiveStore(database: db)
        let bytes = try await archive.exportArchive(), before = try db.read(OptionLabArchiveState.capture)
        let plan = try await archive.prepareRestore(bytes, mode: .merge, expectedRevision: archive.status().revision)
        await archive.injectFailureOnNextCommit()
        await #expect(throws: OptionLabArchiveError.injectedFailure) { try await archive.commit(.init(plan: plan)) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        _ = try await archive.commit(.init(plan: plan))
        #expect(try db.read(OptionLabArchiveState.capture).tables == before.tables)
        #expect(try await store.open(id: input.id) == saved)
    }
    @Test func evidenceSaveInvalidatesArchiveApprovalAndStaleApprovalConsumed() async throws {
        let db = try oeDB(), store = try OptionEvidenceStore(database: db), archive = try OptionLabArchiveStore(database: db)
        let plan = try await archive.prepareClear(expectedRevision: archive.status().revision)
        _ = try await store.save(.tradeAttribution(TradeOptionAttributionDemo.input()), expectedRevision: store.revision())
        await #expect(throws: OptionLabArchiveError.stalePlan) { try await archive.commit(.init(plan: plan)) }
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await archive.commit(.init(plan: plan)) }
        #expect(try await store.summaries().count == 1)
    }
    @Test func v5MigrationPreservesExistingLabAndPortfolioBytesAndRevision() async throws {
        let path = oePath(); defer { try? FileManager.default.removeItem(at: path) }
        let db = try DatabaseStore(path: path.path, purpose: .optionsLab), lab = try OptionLabStore(database: db)
        let old = try OptionLabDemo.input(); _ = try await lab.save(id: old.id, input: old, expectedRevision: lab.revision())
        let portfolio = try PortfolioGreeksStore(database: db)
        _ = try await portfolio.save(PortfolioGreeksDemo.input(), expectedRevision: portfolio.revision())
        let before = try db.read(OptionLabArchiveState.capture)
        try db.transaction { connection in
            try connection.execute(sql: "DROP TABLE option_evidence_documents; DROP TABLE option_evidence_catalog")
            try connection.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='options-lab.v5'")
        }
        let upgraded = try DatabaseStore(path: path.path, purpose: .optionsLab)
        #expect(try upgraded.read(OptionLabArchiveState.capture) == before)
        #expect(try await OptionEvidenceStore(database: upgraded).summaries().isEmpty)
        #expect(try upgraded.migrationVersions().last == "options-lab.v5")
    }
    @Test func wrongDatabasePurposeAndUnknownIDAreRejected() async throws {
        for purpose in [DatabasePurpose.business, .offlineIssuerResearch, .secResearch, .portfolioLedger] {
            #expect(throws: OptionLabStoreError.incompatiblePurpose) { try OptionEvidenceStore(database: DatabaseStore(path: ":memory:", purpose: purpose)) }
        }
        let store = try OptionEvidenceStore(database: oeDB())
        await #expect(throws: OptionLabStoreError.notFound) { try await store.open(id: UUID()) }
    }
    @Test func replacementRepairsCorruptEvidenceWhileMergeStillRequiresCurrentIntegrity() async throws {
        let source = try oeDB(), target = try oeDB(), input = OptionEvidenceInput.tradeAttribution(try TradeOptionAttributionDemo.input())
        let sourceStore = try OptionEvidenceStore(database: source), targetStore = try OptionEvidenceStore(database: target)
        let expected = try await sourceStore.save(input, expectedRevision: sourceStore.revision())
        _ = try await targetStore.save(input, expectedRevision: targetStore.revision())
        try target.transaction { try $0.execute(sql: "UPDATE option_evidence_documents SET report_json=x'00'") }
        let before = try target.read(OptionLabArchiveState.capture), archive = try OptionLabArchiveStore(database: target)
        let bytes = try await OptionLabArchiveStore(database: source).exportArchive()
        await #expect(throws: (any Error).self) { try await archive.prepareRestore(bytes, mode: .merge, expectedRevision: archive.status().revision) }
        let plan = try await archive.prepareRestore(bytes, mode: .replace, expectedRevision: archive.status().revision)
        await archive.injectFailureOnNextCommit()
        await #expect(throws: OptionLabArchiveError.injectedFailure) { try await archive.commit(.init(plan: plan)) }
        #expect(try target.read(OptionLabArchiveState.capture) == before)
        _ = try await archive.commit(.init(plan: plan))
        #expect(try await targetStore.open(id: input.id) == expected)
    }
}
