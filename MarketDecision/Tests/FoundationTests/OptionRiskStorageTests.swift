import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence

private func orsEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
private func orsInput(id: UUID = UUID(), shock: String = "0.1", pricing: Bool = true) throws -> OptionLabInput {
    let b = try OptionLabDemo.input(strategy: .putCreditSpread), source = b.underlying.source
    return try .init(id: id, createdAt: b.createdAt, asOf: b.asOf, strategy: b.strategy,
        shortLeg: b.shortLeg, longLeg: b.longLeg, underlying: b.underlying, capital: b.capital,
        policy: b.policy, expiry: b.expiry, scenarioPrices: b.scenarioPrices,
        pricing: pricing ? .init(rate: Money("0.05"), dividendYield: Money("0.01"), volatility: Money("0.25"), source: source) : nil,
        risk: .init(source: source),
        scenario: .init(source: source, spotShocks: [Money("-0.1"), Money("0"), Money(shock)],
            volatilityPointShocks: [Money("-10"), Money("0"), Money("10")]))
}
private func orsRows(_ database: DatabaseStore) throws -> [[Row]] {
    try database.read { db in try ["option_lab_metadata", "option_lab_catalog", "option_lab_documents"].map {
        try Row.fetchAll(db, sql: "SELECT * FROM " + $0 + " ORDER BY 1")
    } }
}
private func orsTamper(_ database: DatabaseStore, id: UUID, field: String) throws {
    try database.transaction { db in
        let bytes = try #require(try Data.fetchOne(db, sql: "SELECT report_json FROM option_lab_documents WHERE snapshot_id=?", arguments: [id.uuidString]))
        var report = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        if field == "schema" { report["schemaVersion"] = "option-lab-report.v2" }
        else if field == "removedRisk" { report.removeValue(forKey: "risk") }
        else if field == "removedScenario" { report.removeValue(forKey: "scenario") }
        else {
            let key = field.hasPrefix("risk") ? "risk" : "scenario"
            var child = try #require(report[key] as? [String: Any])
            if field.hasSuffix("Model") {
                var model = try #require(child["model"] as? [String: Any]); model["formulaVersion"] = "unregistered"; child["model"] = model
            } else if field == "riskScore" {
                var liquidity = try #require(child["liquidity"] as? [String: Any]); liquidity["grade"] = "excellent"; child["liquidity"] = liquidity
            } else {
                var cells = try #require(child["cells"] as? [[String: Any]]); try #require(!cells.isEmpty)
                cells[0]["state"] = "numericFailure"; child["cells"] = cells
            }
            report[key] = child
        }
        let changed = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        let hash = LedgerCSV.hash(changed)
        let summaryBytes = try #require(try Data.fetchOne(db, sql: "SELECT summary_json FROM option_lab_catalog WHERE snapshot_id=?", arguments: [id.uuidString]))
        var summary = try #require(JSONSerialization.jsonObject(with: summaryBytes) as? [String: Any]); summary["reportHash"] = hash
        let newSummary = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        try db.execute(sql: "UPDATE option_lab_documents SET report_json=? WHERE snapshot_id=?", arguments: [changed, id.uuidString])
        try db.execute(sql: "UPDATE option_lab_catalog SET report_hash=?,summary_json=?,summary_hash=? WHERE snapshot_id=?", arguments: [hash, newSummary, LedgerCSV.hash(newSummary), id.uuidString])
    }
}

@Suite struct OptionRiskStorageTests {
    @Test func priorV2ReportRetainsExactBytesAndDefinitions() async throws {
        let url = try #require(Bundle.module.url(forResource: "options-legacy-v2", withExtension: "json"))
        let bytes = try Data(contentsOf: url)
        // Captured from compiled PR54 a66d2b1 before adding risk/scenario fields.
        #expect(LedgerCSV.hash(bytes) == "ed4b2e00be3fd156b78562724a1439e237b48524eb1ab5b92bada929fbf2e029")
        let report = try JSONDecoder().decode(OptionLabReport.self, from: bytes)
        #expect(report.schemaVersion == "option-lab-report.v2")
        #expect(report.input.risk == nil && report.input.scenario == nil && report.risk == nil && report.scenario == nil)
        #expect(try OptionLabEngine.replay(report) == report)
        #expect(try orsEncode(report) == bytes)
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let saved = try await store.save(id: report.input.id, input: report.input, expectedRevision: store.revision())
        #expect(saved.report == report)
        let stored = try database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") }
        #expect(stored == bytes)
        #expect(try database.migrationVersions() == ["foundation.v1", "options-lab.v1", "options-lab.v2", "options-lab.v3", "options-lab.v4", "options-lab.v5"])
    }

    @Test func fullRiskAndGridReopenFromDiskUsingOnlyFrozenInputs() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("risk-storage-" + UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let input = try orsInput(), store = try OptionLabStore(path: path.path)
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        #expect(saved.report.schemaVersion == "option-lab-report.v3")
        // The synthetic long leg has spread 0.2 / Mid 0.9 > 20%; hard Avoid
        // survives even while missing OI/neighbors keep the score unavailable.
        #expect(saved.report.risk?.liquidity.grade == .avoid)
        #expect(saved.report.risk?.liquidity.score == nil)
        #expect(saved.report.risk?.liquidity.legs.allSatisfy { $0.components.contains { $0.factor == .openInterest && $0.grade == .dataInsufficient } } == true)
        #expect(saved.report.risk?.earnings.state == .dataInsufficient)
        #expect(saved.report.scenario?.cells.count == 9)
        let frozen = try orsEncode(saved.report)
        let decoded = try JSONDecoder().decode(OptionLabReport.self, from: frozen)
        #expect(try OptionLabEngine.replay(decoded) == saved.report)
        let reopened = try OptionLabStore(path: path.path)
        #expect(try await reopened.open(id: input.id) == saved)
        #expect(try await reopened.summaries().first?.origin == .synthetic)
        #expect(decoded.risk?.modelReference != decoded.modelReference)
        #expect(decoded.scenario?.modelReference != decoded.pricing?.modelReference)
    }

    @Test func nestedSyntheticEvidenceCannotBecomeAManualCatalogEntry() async throws {
        let original = try orsInput()
        var object = try #require(JSONSerialization.jsonObject(with: orsEncode(original)) as? [String: Any])
        func manual(_ value: Any) throws -> [String: Any] {
            var entry = try #require(value as? [String: Any]); var source = try #require(entry["source"] as? [String: Any])
            source["origin"] = "manual"; entry["source"] = source; return entry
        }
        for name in ["underlying", "shortLeg", "longLeg", "expiry", "pricing", "scenario", "risk"] {
            object[name] = try manual(#require(object[name]))
        }
        var capital = try #require(object["capital"] as? [String: Any]); capital["origin"] = "manual"; object["capital"] = capital
        var risk = try #require(object["risk"] as? [String: Any])
        var neighbor = try #require(JSONSerialization.jsonObject(with: orsEncode(original.shortLeg)) as? [String: Any])
        neighbor["contractID"] = "SYNTHETIC-NEIGHBOR"; neighbor["strike"] = "90"
        // A partial neighbor universe remains insufficient, but its source is retained.
        risk["liquidity"] = [["contractID": original.shortLeg.contractID, "oiIsLatestPublished": false,
            "volumeBasis": "unverified", "neighborsComplete": false, "neighbors": [neighbor]]]
        object["risk"] = risk
        let input = try JSONDecoder().decode(OptionLabInput.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(input.risk?.source.origin == .manual && input.risk?.containsSyntheticInput == true)
        let store = try OptionLabStore(path: ":memory:")
        _ = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        #expect(try await store.summaries().first?.origin == .synthetic)
    }

    @Test func missingIVRemainsMissingAfterSaveAndReopen() async throws {
        let input = try orsInput(pricing: false), store = try OptionLabStore(path: ":memory:")
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let cells = try #require(saved.report.scenario?.cells)
        #expect(cells.count == 9 && cells.allSatisfy { $0.state == .missingPricing && $0.mid == nil && $0.conservative == nil })
        #expect(try await store.open(id: input.id) == saved)
    }

    @Test(arguments: ["schema", "removedRisk", "removedScenario", "riskModel", "scenarioModel", "riskScore", "scenarioCells"])
    func rehashedTamperingCannotPublishCachedRiskOrScenario(_ field: String) async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let input = try orsInput()
        _ = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        try orsTamper(database, id: input.id, field: field)
        #expect(try await store.summaries().count == 1) // Metadata does not certify cached numbers.
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
        await #expect(throws: OptionLabStoreError.corruptedStorage) {
            try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        }
    }

    @Test func failureRollsBackAndChangedAxesCannotReuseSnapshotOrOldBaseline() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let input = try orsInput(), before = try orsRows(database), original = try await store.revision()
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) { try await store.save(id: input.id, input: input, expectedRevision: original) }
        #expect(try orsRows(database) == before)
        let saved = try await store.save(id: input.id, input: input, expectedRevision: original)
        let rows = try orsRows(database), changed = try orsInput(id: input.id, shock: "0.2")
        await #expect(throws: OptionLabStoreError.staleRevision) { try await store.save(id: input.id, input: changed, expectedRevision: original) }
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) { try await store.save(id: input.id, input: changed, expectedRevision: store.revision()) }
        #expect(try orsRows(database) == rows)
        #expect(try await store.open(id: input.id) == saved)
    }
}
