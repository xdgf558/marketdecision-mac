import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence

func odsInput(id: UUID = UUID(), volatility: Double = 0.25) throws -> OptionDailyInput {
    let b = try OptionDailyDemo.input(volatility: volatility)
    return .init(id: id, createdAt: b.createdAt, asOf: b.asOf, session: b.session, sessionTimeZoneID: b.sessionTimeZoneID,
        symbol: b.symbol, feedID: b.feedID, coverage: b.coverage, declaredScope: b.declaredScope, underlying: b.underlying,
        contracts: b.contracts, rate: b.rate, dividendYield: b.dividendYield, source: b.source, calendar: b.calendar, sessionCloseAt: b.sessionCloseAt)
}
func odsHistory(id: UUID = UUID()) throws -> OptionVolatilityHistoryInput {
    let b = try OptionVolatilityHistoryDemo.input(priorSessions: 2)
    return .init(id: id, createdAt: b.createdAt, current: b.current, history: b.history, calendar: b.calendar)
}
func odsDB() throws -> DatabaseStore { try .init(path: ":memory:", purpose: .optionsLab) }
func odsPath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("option-history-" + UUID().uuidString + ".sqlite") }
func odsBytes<T: Encodable>(_ value: T) throws -> Data { try OptionLabArchiveCodec.canonical(value) }

@Suite("Daily option and volatility history immutable storage")
struct OptionDailyStorageTests {
    @Test func firstSaveIncludesChainEveryContractAndFrozenReplayAfterReopen() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let db = try DatabaseStore(path: path.path, purpose: .optionsLab), store = try OptionDailyStore(database: db)
        let input = try odsInput(), saved = try await store.saveDaily(input, expectedRevision: store.revision())
        #expect(saved.replayMatched); #expect(saved.report.iv30 != nil)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM option_daily_chains") } == 1)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM option_daily_contracts") } == input.contracts.count)
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT contract_id,summary_json FROM option_daily_contracts ORDER BY contract_id") }
        #expect(rows.count == saved.report.contractSummaries.count)
        for row in rows {
            let contract = try JSONDecoder().decode(OptionDailyContractSummary.self, from: row["summary_json"] as Data)
            #expect(contract.contractID == (row["contract_id"] as String))
            #expect(saved.report.contractSummaries.contains(contract))
        }
        let reopened = try OptionDailyStore(path: path.path)
        #expect(try await reopened.openDaily(id: input.id) == saved)
        #expect(try await reopened.dailySummaries().first?.origin == .synthetic)
        #expect(try await reopened.dailySummaries().first?.contractCount == 4)
    }
    @Test func duplicateIsIdempotentAndDifferentContentCannotReuseIdentity() async throws {
        let db = try odsDB(), store = try OptionDailyStore(database: db), input = try odsInput()
        let first = try await store.saveDaily(input, expectedRevision: store.revision())
        let before = try db.read(OptionLabArchiveState.capture), revision = try await store.revision()
        #expect(try await store.saveDaily(input, expectedRevision: revision) == first)
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        let conflict = try odsInput(id: input.id, volatility: 0.35)
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.saveDaily(conflict, expectedRevision: revision) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
    }
    @Test func chainAndContractWritesRollbackTogetherThenSameBaselineRetries() async throws {
        let db = try odsDB(), store = try OptionDailyStore(database: db), input = try odsInput()
        let before = try db.read(OptionLabArchiveState.capture), revision = try await store.revision()
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) { try await store.saveDaily(input, expectedRevision: revision) }
        #expect(try db.read(OptionLabArchiveState.capture) == before)
        #expect(try await store.saveDaily(input, expectedRevision: revision).replayMatched)
    }
    @Test func corruptIndexesBodyAndContractRowsRejectOpenAndDuplicate() async throws {
        let mutations = [
            "UPDATE option_daily_catalog SET symbol='WRONG'",
            "UPDATE option_daily_catalog SET session='2020-01-01'",
            "UPDATE option_daily_documents SET input_json=x'00'",
            "UPDATE option_daily_documents SET report_json=x'00'",
            "UPDATE option_daily_chains SET summary_json=x'00'",
            "UPDATE option_daily_contracts SET summary_hash='" + String(repeating: "0", count: 64) + "'",
            "DELETE FROM option_daily_contracts WHERE contract_id=(SELECT contract_id FROM option_daily_contracts LIMIT 1)",
            "DELETE FROM option_daily_chains"
        ]
        for sql in mutations {
            let db = try odsDB(), store = try OptionDailyStore(database: db), input = try odsInput()
            _ = try await store.saveDaily(input, expectedRevision: store.revision()); let revision = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.openDaily(id: input.id) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.saveDaily(input, expectedRevision: revision) }
        }
    }
    @Test func rehashedCachedIVStillFailsIndependentReplay() async throws {
        let db = try odsDB(), store = try OptionDailyStore(database: db), input = try odsInput()
        _ = try await store.saveDaily(input, expectedRevision: store.revision())
        try db.transaction { connection in
            let raw = try #require(try Data.fetchOne(connection, sql: "SELECT report_json FROM option_daily_documents"))
            var report = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any]); report["iv30"] = 4.9
            let changed = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
            let summaryRaw = try #require(try Data.fetchOne(connection, sql: "SELECT summary_json FROM option_daily_catalog"))
            var summary = try #require(JSONSerialization.jsonObject(with: summaryRaw) as? [String: Any]); summary["reportHash"] = LedgerCSV.hash(changed)
            let metadata = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
            try connection.execute(sql: "UPDATE option_daily_documents SET report_json=?", arguments: [changed])
            try connection.execute(sql: "UPDATE option_daily_catalog SET report_hash=?,summary_hash=?,summary_json=?", arguments: [LedgerCSV.hash(changed), LedgerCSV.hash(metadata), metadata])
        }
        #expect(try await store.dailySummaries().count == 1)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.openDaily(id: input.id) }
    }
    @Test func historyContainsItsOwnDailyInputsAndReplaysWithoutSeparateDailyRows() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try OptionDailyStore(path: path.path), input = try odsHistory()
        let saved = try await store.saveHistory(input, expectedRevision: store.revision())
        #expect(saved.report.state == .insufficientSessions); #expect(saved.report.ivRank == nil)
        #expect(try await store.dailySummaries().isEmpty)
        let reopened = try OptionDailyStore(path: path.path)
        #expect(try await reopened.openHistory(id: saved.id) == saved)
        #expect(try await reopened.historySummaries().first?.origin == .synthetic)
        #expect(try await reopened.historySummaries().first?.symbol == input.current.input.symbol)
    }
    @Test func corruptHistoryBodyOrIndexCannotPublishOrDeduplicate() async throws {
        for sql in ["UPDATE option_history_catalog SET symbol='WRONG'", "UPDATE option_history_catalog SET session='2000-01-01'", "UPDATE option_history_documents SET input_json=x'00'", "UPDATE option_history_documents SET report_json=x'00'"] {
            let db = try odsDB(), store = try OptionDailyStore(database: db), input = try odsHistory()
            _ = try await store.saveHistory(input, expectedRevision: store.revision()); let revision = try await store.revision()
            try db.transaction { try $0.execute(sql: sql) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.openHistory(id: input.id) }
            await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.saveHistory(input, expectedRevision: revision) }
        }
    }
    @Test func clearingSharedDatabaseRejectsEveryOldWriterBaselineAcrossConnections() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let daily = try OptionDailyStore(path: path.path), oldDaily = try OptionDailyStore(path: path.path)
        let oldLab = try OptionLabStore(path: path.path), archive = try OptionLabArchiveStore(path: path.path)
        let token = try await daily.revision(), input = try odsInput(), history = try odsHistory(), lab = try OptionLabDemo.input()
        let plan = try await archive.prepareClear(expectedRevision: token)
        _ = try await archive.commit(.init(plan: plan))
        await #expect(throws: OptionLabStoreError.staleRevision) { try await oldDaily.saveDaily(input, expectedRevision: token) }
        await #expect(throws: OptionLabStoreError.staleRevision) { try await oldDaily.saveHistory(history, expectedRevision: token) }
        await #expect(throws: OptionLabStoreError.staleRevision) { try await oldLab.save(id: lab.id, input: lab, expectedRevision: token) }
        #expect(try await daily.dailySummaries().isEmpty); #expect(try await daily.historySummaries().isEmpty)
        #expect(try await oldLab.summaries().isEmpty)
    }
    @Test func additiveMigrationPreservesOldExperimentBytesAndRevision() async throws {
        let path = odsPath(); defer { try? FileManager.default.removeItem(at: path) }
        let db = try DatabaseStore(path: path.path, purpose: .optionsLab), store = try OptionLabStore(database: db), input = try OptionLabDemo.input()
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let oldBytes = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM option_lab_documents") }, oldRevision = try await store.revision()
        try db.transaction { connection in
            for table in ["portfolio_greeks_documents", "portfolio_greeks_catalog", "option_chain_documents", "option_chain_catalog", "option_history_documents", "option_history_catalog", "option_daily_contracts", "option_daily_chains", "option_daily_documents", "option_daily_catalog"] {
                try connection.execute(sql: "DROP TABLE " + table)
            }
            try connection.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('options-lab.v2','options-lab.v3','options-lab.v4')")
        }
        let upgraded = try DatabaseStore(path: path.path, purpose: .optionsLab), reopened = try OptionLabStore(database: upgraded)
        #expect(try upgraded.read { try Row.fetchAll($0, sql: "SELECT * FROM option_lab_documents") } == oldBytes)
        #expect(try await reopened.revision() == oldRevision); #expect(try await reopened.open(id: input.id) == saved)
        #expect(try await reopened.makeDailyStore().dailySummaries().isEmpty)
    }
}
