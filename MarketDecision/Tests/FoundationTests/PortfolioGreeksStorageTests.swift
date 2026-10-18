import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence

private func pgsDB() throws -> DatabaseStore { try DatabaseStore(path: ":memory:", purpose: .optionsLab) }
private func pgsPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("portfolio-greeks-" + UUID().uuidString + ".sqlite") }
private func pgsCopy(_ input: PortfolioGreeksInput, id: UUID? = nil, ledgerRevision: UUID? = nil, createdAt: Date? = nil) -> PortfolioGreeksInput {
    .init(id: id ?? input.id, createdAt: createdAt ?? input.createdAt, asOf: input.asOf, mode: input.mode,
          accountID: input.accountID, ledgerRevision: ledgerRevision ?? input.ledgerRevision,
          accounts: input.accounts, events: input.events, reports: input.reports, bindings: input.bindings)
}
private func pgsLegacyArchive(_ database: DatabaseStore, version: Int) throws -> Data {
    let state = try database.read(OptionLabArchiveState.capture)
    let old = OptionLabArchiveState(format: version == 1 ? OptionLabArchiveState.legacyFormat : OptionLabArchiveState.chainFormat,
        revision: state.revision, tables: Array(state.tables.prefix(version == 1 ? 8 : 10)))
    let bytes = try OptionLabArchiveCodec.canonical(old)
    let manifest = OptionLabArchiveCodec.Manifest(format: version == 1 ? OptionLabArchiveCodec.legacyFormat : OptionLabArchiveCodec.chainFormat,
        purpose: "MDQ1", encrypted: false, stateHash: LedgerCSV.hash(bytes), stateBytes: bytes.count,
        embeddedLedgerBases: old.counts.embeddedLedgerBases, ledgerBasisScope: OptionLabArchiveCodec.ledgerBasisScope)
    return try ResearchZIP.encode(["manifest.json": OptionLabArchiveCodec.canonical(manifest), "research-state.json": bytes])
}
/// Rehash the outer BLOB/catalog so tests must reach semantic replay, not only a checksum.
private func pgsRehashReport(_ database: DatabaseStore, mutation: (inout [String: Any]) throws -> Void) throws {
    try database.transaction { db in
        let old = try #require(try Data.fetchOne(db, sql: "SELECT report_json FROM portfolio_greeks_documents"))
        var report = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any]); try mutation(&report)
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        let original = try #require(try Data.fetchOne(db, sql: "SELECT summary_json FROM portfolio_greeks_catalog"))
        var summary = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); summary["reportHash"] = LedgerCSV.hash(bytes)
        let summaryBytes = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        try db.execute(sql: "UPDATE portfolio_greeks_documents SET report_json=?", arguments: [bytes])
        try db.execute(sql: "UPDATE portfolio_greeks_catalog SET report_hash=?,summary_hash=?,summary_json=?",
                       arguments: [LedgerCSV.hash(bytes), LedgerCSV.hash(summaryBytes), summaryBytes])
    }
}

@Suite("Frozen portfolio Greeks persistence and isolated archive")
struct PortfolioGreeksStorageTests {
    @Test func reopenReplaysExactFrozenLedgerSourcesAndPartialCoverage() async throws {
        let path = pgsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try PortfolioGreeksStore(path: path.path), input = try PortfolioGreeksDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision())
        let reopened = try PortfolioGreeksStore(path: path.path), replay = try await reopened.open(id: input.id)
        #expect(replay == saved && replay.replayMatched)
        #expect(replay.report.input.accounts == input.accounts && replay.report.input.events == input.events)
        #expect(replay.report.input.reports == input.reports && replay.report.input.ledgerRevision == input.ledgerRevision)
        #expect(replay.report.coverage.missingPositions > 0 && replay.report.completeTotals == nil)
        let summary = try #require(try await reopened.summaries().first)
        #expect(summary.accountID == input.accountID && summary.ledgerRevision == input.ledgerRevision)
        #expect(summary.mode == .synthetic && summary.positionCount == saved.report.rows.count)
        #expect(summary.inputHash == saved.inputHash && summary.reportHash == saved.reportHash)
    }
    @Test func repeatIdenticalInputIsIdempotentButSameIDNewLedgerBasisRejects() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision())
        let before = try db.read(OptionLabArchiveState.capture), token = try await store.revision()
        let bytes = try OptionLabArchiveCodec.canonical(input)
        let roundtrip = try JSONDecoder().decode(PortfolioGreeksInput.self, from: bytes)
        #expect(try await store.save(roundtrip, expectedRevision: token) == saved)
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) {
            try await store.save(pgsCopy(input, ledgerRevision: UUID()), expectedRevision: token)
        }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
    }
    @Test func catalogListsMetadataWithoutReadingOrPublishingBrokenReportValues() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        _ = try await store.save(input, expectedRevision: store.revision())
        let before = try await store.summaries()
        try db.transaction { try $0.execute(sql: "UPDATE portfolio_greeks_documents SET report_json=x'00'") }
        #expect(try await store.summaries() == before)
        let rawSummary = try #require(try db.read { try Data.fetchOne($0, sql: "SELECT summary_json FROM portfolio_greeks_catalog") })
        let json = try #require(JSONSerialization.jsonObject(with: rawSummary) as? [String: Any])
        #expect(json["coveredTotals"] == nil && json["rows"] == nil && json["coverage"] == nil)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
    }
    @Test func tamperedColumnsBodyOrMissingDocumentRejectOpenAndDuplicate() async throws {
        for sql in [
            "UPDATE portfolio_greeks_catalog SET ledger_revision='00000000-0000-0000-0000-000000000000'",
            "UPDATE portfolio_greeks_catalog SET model_version='wrong'",
            "UPDATE portfolio_greeks_catalog SET numeric_policy_version='wrong'",
            "UPDATE portfolio_greeks_catalog SET summary_json=x'00'",
            "UPDATE portfolio_greeks_documents SET input_json=x'00'",
            "UPDATE portfolio_greeks_documents SET report_json=x'00'",
            "DELETE FROM portfolio_greeks_documents"
        ] {
            let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
            _ = try await store.save(input, expectedRevision: store.revision()); let token = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.save(input, expectedRevision: token) }
            await #expect(throws: (any Error).self) { try await OptionLabArchiveStore(database: db).exportArchive() }
        }
    }
    @Test func rehashedOutputTamperingStillFailsFrozenReplay() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        _ = try await store.save(input, expectedRevision: store.revision())
        try pgsRehashReport(db) { report in
            var coverage = try #require(report["coverage"] as? [String: Any]); coverage["coveredPositions"] = 0; report["coverage"] = coverage
        }
        #expect(try await store.summaries().count == 1)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.save(input, expectedRevision: store.revision()) }
    }
    @Test func rehashedEmbeddedSourceCannotDisagreeWithStoredInput() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        _ = try await store.save(input, expectedRevision: store.revision())
        try pgsRehashReport(db) { report in
            var frozenInput = try #require(report["input"] as? [String: Any])
            frozenInput["ledgerRevision"] = UUID().uuidString; report["input"] = frozenInput
        }
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
    }
    @Test func consistentlyRehashedEmbeddedOptionReportStillRequiresItsOwnReplay() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        _ = try await store.save(input, expectedRevision: store.revision())
        try db.transaction { connection in
            let inputBytes = try #require(try Data.fetchOne(connection, sql: "SELECT input_json FROM portfolio_greeks_documents"))
            var frozen = try #require(JSONSerialization.jsonObject(with: inputBytes) as? [String: Any])
            var sources = try #require(frozen["reports"] as? [[String: Any]])
            sources[0]["schemaVersion"] = "untrusted-option-report"; frozen["reports"] = sources
            let badInput = try JSONSerialization.data(withJSONObject: frozen, options: [.sortedKeys, .withoutEscapingSlashes])
            let reportBytes = try #require(try Data.fetchOne(connection, sql: "SELECT report_json FROM portfolio_greeks_documents"))
            var report = try #require(JSONSerialization.jsonObject(with: reportBytes) as? [String: Any]); report["input"] = frozen
            let badReport = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
            let summaryBytes = try #require(try Data.fetchOne(connection, sql: "SELECT summary_json FROM portfolio_greeks_catalog"))
            var summary = try #require(JSONSerialization.jsonObject(with: summaryBytes) as? [String: Any])
            summary["inputHash"] = LedgerCSV.hash(badInput); summary["reportHash"] = LedgerCSV.hash(badReport)
            let badSummary = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
            try connection.execute(sql: "UPDATE portfolio_greeks_documents SET input_json=?,report_json=?", arguments: [badInput, badReport])
            try connection.execute(sql: "UPDATE portfolio_greeks_catalog SET input_hash=?,report_hash=?,summary_hash=?,summary_json=?",
                arguments: [LedgerCSV.hash(badInput), LedgerCSV.hash(badReport), LedgerCSV.hash(badSummary), badSummary])
        }
        #expect(try await store.summaries().count == 1)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
        await #expect(throws: (any Error).self) { try await OptionLabArchiveStore(database: db).exportArchive() }
    }
    @Test func injectedFailureRollsBackBothRowsAndRevisionAndSameBaselineRetries() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        let before = try db.read(OptionLabArchiveState.capture), token = try await store.revision()
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) { try await store.save(input, expectedRevision: token) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        #expect(try await store.save(input, expectedRevision: token).replayMatched)
    }
    @Test func realSQLiteFailureAfterBodyWriteLeavesNoHalfReport() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        let before = try db.read(OptionLabArchiveState.capture), token = try await store.revision()
        try db.transaction { try $0.execute(sql: "CREATE TRIGGER reject_portfolio_revision BEFORE UPDATE ON option_lab_metadata BEGIN SELECT RAISE(ABORT,'synthetic failure'); END") }
        await #expect(throws: (any Error).self) { try await store.save(input, expectedRevision: token) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        try db.transaction { try $0.execute(sql: "DROP TRIGGER reject_portfolio_revision") }
        #expect(try await store.save(input, expectedRevision: token).replayMatched)
    }
    @Test func currentArchiveRestoresExactReportAndLedgerInputBytesAfterReopen() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision())
        let raw = try await OptionLabArchiveStore(database: db).exportArchive(), files = try ResearchZIP.decode(raw)
        let manifest = try JSONDecoder().decode(OptionLabArchiveCodec.Manifest.self, from: #require(files["manifest.json"]))
        #expect(manifest.format == "options-lab-archive.v4" && !manifest.encrypted && manifest.embeddedLedgerBases == 1)
        let path = pgsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let target = try DatabaseStore(path: path.path, purpose: .optionsLab), archive = try OptionLabArchiveStore(database: target)
        let plan = try await archive.prepareRestore(raw, mode: .replace, expectedRevision: archive.status().revision)
        #expect(plan.result.portfolioReports == 1 && plan.result.embeddedLedgerBases == 1)
        #expect(plan.details.contains { $0.contains("portfolio-ledger.sqlite") })
        _ = try await archive.commit(.init(plan: plan))
        #expect(try target.read(OptionLabArchiveState.capture).tables == db.read(OptionLabArchiveState.capture).tables)
        #expect(try await PortfolioGreeksStore(path: path.path).open(id: input.id) == saved)
    }
    @Test func legacyV1V2UpgradeKeepsOldBodiesAndMergePreservesCurrentPortfolioReports() async throws {
        let source = try pgsDB(), lab = try OptionLabStore(database: source), experiment = try OptionLabDemo.input()
        let savedLab = try await lab.save(id: experiment.id, input: experiment, expectedRevision: lab.revision())
        let capture = try OptionChainDemo.capture(), chain = try await lab.makeChainStore()
        let savedCapture = try await chain.save(capture, expectedRevision: chain.revision())
        for version in [1, 2] {
            let raw = try pgsLegacyArchive(source, version: version), decoded = try OptionLabArchiveCodec.decode(raw)
            #expect(decoded.format == OptionLabArchiveState.format && decoded.counts.portfolioReports == 0)
            for mode in [OptionLabRestoreMode.merge, .replace] {
                let target = try pgsDB(), portfolio = try PortfolioGreeksStore(database: target), input = try PortfolioGreeksDemo.input()
                let saved = try await portfolio.save(input, expectedRevision: portfolio.revision())
                let archive = try OptionLabArchiveStore(database: target)
                let plan = try await archive.prepareRestore(raw, mode: mode, expectedRevision: archive.status().revision)
                #expect(plan.previous.portfolioReports == 1 && plan.result.portfolioReports == (mode == .merge ? 1 : 0))
                _ = try await archive.commit(.init(plan: plan))
                #expect(try await OptionLabStore(database: target).open(id: experiment.id) == savedLab)
                #expect(try target.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") }
                    == source.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") })
                if version == 2 { #expect(try await OptionChainStore(database: target).open(id: capture.id) == savedCapture) }
                else { #expect(try await OptionChainStore(database: target).summaries().isEmpty) }
                if mode == .merge { #expect(try await portfolio.open(id: input.id) == saved) }
                else { #expect(try await portfolio.summaries().isEmpty) }
            }
        }
    }
    @Test func legacyCannotSmugglePortfolioRowsOrRelabelCurrentState() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input()
        _ = try await store.save(input, expectedRevision: store.revision())
        let archive = try OptionLabArchiveStore(database: db), raw = try await archive.exportArchive()
        for version in [1, 2] {
            var files = try ResearchZIP.decode(raw)
            let manifestBytes = try #require(files["manifest.json"])
            var manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
            manifest["format"] = "options-lab-archive.v\(version)"
            files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            await #expect(throws: OptionLabArchiveError.unsupportedFormat) {
                try await archive.prepareRestore(ResearchZIP.encode(files), mode: .replace, expectedRevision: archive.status().revision)
            }
        }
    }
    @Test func mergeIdenticalPortfolioIsIdempotentButConflictingFrozenBasisRejectsWholePlan() async throws {
        let input = try PortfolioGreeksDemo.input(), a = try pgsDB(), b = try pgsDB()
        let left = try PortfolioGreeksStore(database: a), right = try PortfolioGreeksStore(database: b)
        _ = try await left.save(input, expectedRevision: left.revision()); _ = try await right.save(input, expectedRevision: right.revision())
        let archive = try OptionLabArchiveStore(database: a), raw = try await OptionLabArchiveStore(database: b).exportArchive()
        let before = try a.read(OptionLabArchiveState.capture).tables
        let plan = try await archive.prepareRestore(raw, mode: .merge, expectedRevision: archive.status().revision)
        _ = try await archive.commit(.init(plan: plan)); #expect(try a.read(OptionLabArchiveState.capture).tables == before)
        let c = try pgsDB(), conflict = try PortfolioGreeksStore(database: c)
        _ = try await conflict.save(pgsCopy(input, ledgerRevision: UUID()), expectedRevision: conflict.revision())
        let bad = try await OptionLabArchiveStore(database: c).exportArchive()
        await #expect(throws: OptionLabArchiveError.identityConflict) {
            try await archive.prepareRestore(bad, mode: .merge, expectedRevision: archive.status().revision)
        }
        #expect(try a.read(OptionLabArchiveState.capture).tables == before)
    }
    @Test func replaceRepairsBadPortfolioBodyWhileMergeRequiresIntegrity() async throws {
        let source = try pgsDB(), store = try PortfolioGreeksStore(database: source), input = try PortfolioGreeksDemo.input()
        let saved = try await store.save(input, expectedRevision: store.revision()), bytes = try await OptionLabArchiveStore(database: source).exportArchive()
        for sql in ["UPDATE portfolio_greeks_documents SET input_json=x'00'", "UPDATE portfolio_greeks_documents SET report_json=x'00'"] {
            let target = try pgsDB(), portfolio = try PortfolioGreeksStore(database: target), archive = try OptionLabArchiveStore(database: target)
            _ = try await portfolio.save(PortfolioGreeksDemo.input(), expectedRevision: portfolio.revision())
            try target.transaction { try $0.execute(sql: sql) }
            await #expect(throws: (any Error).self) { try await archive.prepareRestore(bytes, mode: .merge, expectedRevision: archive.status().revision) }
            let plan = try await archive.prepareRestore(bytes, mode: .replace, expectedRevision: archive.status().revision)
            await archive.injectFailureOnNextCommit(); let before = try target.read(OptionLabArchiveState.capture)
            await #expect(throws: OptionLabArchiveError.injectedFailure) { try await archive.commit(.init(plan: plan)) }
            #expect(try target.read(OptionLabArchiveState.capture) == before)
            _ = try await archive.commit(.init(plan: plan)); #expect(try await portfolio.open(id: input.id) == saved)
        }
    }
    @Test func clearAndReplaceBlockPreexistingPortfolioWritersAcrossConnections() async throws {
        for replace in [false, true] {
            let path = pgsPath(); defer { try? FileManager.default.removeItem(at: path) }
            let store = try PortfolioGreeksStore(path: path.path), archive = try OptionLabArchiveStore(path: path.path)
            _ = try await store.save(PortfolioGreeksDemo.input(), expectedRevision: store.revision())
            let old = try await store.revision(), late = try PortfolioGreeksDemo.input(), plan: OptionLabTransferPlan
            if replace {
                let empty = try await OptionLabArchiveStore(database: pgsDB()).exportArchive()
                plan = try await archive.prepareRestore(empty, mode: .replace, expectedRevision: old)
            } else { plan = try await archive.prepareClear(expectedRevision: old) }
            #expect(plan.previous.portfolioReports == 1 && plan.result.portfolioReports == 0)
            _ = try await archive.commit(.init(plan: plan))
            await #expect(throws: OptionLabStoreError.staleRevision) { try await store.save(late, expectedRevision: old) }
            #expect(try await store.summaries().isEmpty)
        }
    }
    @Test func portfolioWriteInvalidatesPreparedArchiveApprovalAndClearRollsBackOnFailure() async throws {
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), archive = try OptionLabArchiveStore(database: db)
        let old = try await archive.prepareClear(expectedRevision: archive.status().revision)
        let saved = try await store.save(PortfolioGreeksDemo.input(), expectedRevision: store.revision())
        await #expect(throws: OptionLabArchiveError.stalePlan) { try await archive.commit(.init(plan: old)) }
        await #expect(throws: OptionLabArchiveError.invalidPlan) { try await archive.commit(.init(plan: old)) }
        let plan = try await archive.prepareClear(expectedRevision: archive.status().revision), before = try db.read(OptionLabArchiveState.capture)
        await archive.injectFailureOnNextCommit()
        await #expect(throws: OptionLabArchiveError.injectedFailure) { try await archive.commit(.init(plan: plan)) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        #expect(try await store.open(id: saved.id) == saved)
        _ = try await archive.commit(.init(plan: plan)); #expect(try await store.summaries().isEmpty)
    }
    @Test func archiveWithEmbeddedLedgerNeverMutatesActualLedgerOrOtherDatabases() async throws {
        let ledgerDB = try DatabaseStore(path: ":memory:", purpose: .portfolioLedger), ledger = try LedgerStore(database: ledgerDB)
        _ = try await ledger.createAccount(.init(id: "independent-ledger", name: "Independent"), expectedRevision: ledger.snapshot().revision)
        let actual = try await ledger.snapshot(), options = try pgsDB(), store = try PortfolioGreeksStore(database: options)
        _ = try await store.save(PortfolioGreeksDemo.input(), expectedRevision: store.revision())
        let archive = try OptionLabArchiveStore(database: options), raw = try await archive.exportArchive()
        let clear = try await archive.prepareClear(expectedRevision: archive.status().revision); _ = try await archive.commit(.init(plan: clear))
        let restore = try await archive.prepareRestore(raw, mode: .replace, expectedRevision: archive.status().revision); _ = try await archive.commit(.init(plan: restore))
        #expect(try await ledger.snapshot() == actual)
        #expect(try await archive.status().counts.embeddedLedgerBases == 1)
        #expect(throws: OptionLabStoreError.incompatiblePurpose) { try PortfolioGreeksStore(database: ledgerDB) }
        #expect(throws: OptionLabArchiveError.incompatiblePurpose) { try OptionLabArchiveStore(database: ledgerDB) }
    }
    @Test func v4MigrationPreservesExistingExperimentAndChainBytesAndRevision() async throws {
        let path = pgsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let db = try DatabaseStore(path: path.path, purpose: .optionsLab), lab = try OptionLabStore(database: db), input = try OptionLabDemo.input()
        _ = try await lab.save(id: input.id, input: input, expectedRevision: lab.revision())
        let chain = try await lab.makeChainStore(); _ = try await chain.save(OptionChainDemo.capture(), expectedRevision: chain.revision())
        let before = try db.read(OptionLabArchiveState.capture)
        try db.transaction { connection in
            try connection.execute(sql: "DROP TABLE option_evidence_documents; DROP TABLE option_evidence_catalog; DROP TABLE portfolio_greeks_documents; DROP TABLE portfolio_greeks_catalog")
            try connection.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('options-lab.v4','options-lab.v5')")
        }
        let upgraded = try DatabaseStore(path: path.path, purpose: .optionsLab)
        #expect(try upgraded.read(OptionLabArchiveState.capture) == before)
        #expect(try await OptionLabStore(database: upgraded).makePortfolioGreeksStore().summaries().isEmpty)
        #expect(try upgraded.migrationVersions() == ["foundation.v1", "options-lab.v1", "options-lab.v2", "options-lab.v3", "options-lab.v4", "options-lab.v5"])
    }
    @Test func wrongPurposeUnknownIDAndPrecancelledSaveFailWithoutWrites() async throws {
        for purpose in [DatabasePurpose.business, .offlineIssuerResearch, .secResearch, .portfolioLedger] {
            #expect(throws: OptionLabStoreError.incompatiblePurpose) { try PortfolioGreeksStore(database: DatabaseStore(path: ":memory:", purpose: purpose)) }
        }
        let db = try pgsDB(), store = try PortfolioGreeksStore(database: db), input = try PortfolioGreeksDemo.input(), token = try await store.revision()
        await #expect(throws: OptionLabStoreError.notFound) { try await store.open(id: UUID()) }
        let gate = PGSGate(), task = Task { await gate.wait(); return try await store.save(input, expectedRevision: token) }
        await gate.arrived(); task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.revision() == token)
        #expect(try await store.summaries().isEmpty)
    }
}
private actor PGSGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; arrival?.resume(); arrival = nil; await withCheckedContinuation { waiter = $0 } }
    func arrived() async { if entered { return }; await withCheckedContinuation { arrival = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
