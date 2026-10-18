import Foundation
import Testing
import GRDB
import CoreDomain
import PortfolioEngine
import OptionsAnalytics
@testable import Persistence

private func opsEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
private func opsInput(strategy: OptionLabStrategy = .putCreditSpread, id: UUID = UUID(),
                      rate: String = "0.05", sigma: String = "0.25") throws -> OptionLabInput {
    let base = try OptionLabDemo.input(strategy: strategy)
    return try .init(id: id, createdAt: base.createdAt, asOf: base.asOf, strategy: base.strategy,
        shortLeg: base.shortLeg, longLeg: base.longLeg, underlying: base.underlying, capital: base.capital,
        policy: base.policy, expiry: base.expiry, scenarioPrices: base.scenarioPrices,
        pricing: .init(rate: Money(rate), dividendYield: Money("0.01"), volatility: Money(sigma),
            source: .init(origin: .synthetic, reference: "SYNTHETIC pricing assumptions, no market source", enteredAt: base.createdAt)))
}
private func opsRows(_ database: DatabaseStore) throws -> [[Row]] {
    try database.read { db in try ["option_lab_metadata", "option_lab_catalog", "option_lab_documents"].map {
        try Row.fetchAll(db, sql: "SELECT * FROM " + $0 + " ORDER BY 1")
    } }
}

/// Rehashing corruption deliberately bypasses simple checksum detection so the
/// tests exercise semantic model/input replay, not only the outer hash guard.
private func opsRewriteReport(_ database: DatabaseStore, id: UUID,
                              mutate: (inout [String: Any]) throws -> Void) throws {
    try database.transaction { db in
        let storedBytes = try Data.fetchOne(db, sql: "SELECT report_json FROM option_lab_documents WHERE snapshot_id=?", arguments: [id.uuidString])
        let bytes = try #require(storedBytes)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try mutate(&object)
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let hash = LedgerCSV.hash(changed)
        let storedSummary = try Data.fetchOne(db, sql: "SELECT summary_json FROM option_lab_catalog WHERE snapshot_id=?", arguments: [id.uuidString])
        let summaryBytes = try #require(storedSummary)
        var summary = try #require(JSONSerialization.jsonObject(with: summaryBytes) as? [String: Any])
        summary["reportHash"] = hash
        let newSummary = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        try db.execute(sql: "UPDATE option_lab_documents SET report_json=? WHERE snapshot_id=?", arguments: [changed, id.uuidString])
        try db.execute(sql: "UPDATE option_lab_catalog SET report_hash=?,summary_json=?,summary_hash=? WHERE snapshot_id=?",
            arguments: [hash, newSummary, LedgerCSV.hash(newSummary), id.uuidString])
    }
}

@Suite("Pricing snapshots retain original model, inputs and replay")
struct OptionPricingStorageTests {
    @Test func previouslyBuiltV1FixtureReplaysAndPersistsWithoutUpgradeOrByteChanges() async throws {
        let url = try #require(Bundle.module.url(forResource: "options-legacy-v1", withExtension: "json"))
        let bytes = try Data(contentsOf: url)
        // Captured from the previously verified PR53 compiled engine, before this implementation.
        #expect(LedgerCSV.hash(bytes) == "9559a8bed93d90f72ea60bfd5f05d59873a38dc4839d68ea5b5bf2d8cb2552c3")
        let report = try JSONDecoder().decode(OptionLabReport.self, from: bytes)
        #expect(report.input.pricing == nil && report.pricing == nil)
        #expect(try OptionLabEngine.replay(report) == report)
        #expect(try opsEncode(report) == bytes)
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let saved = try await store.save(id: report.input.id, input: report.input, expectedRevision: store.revision())
        #expect(saved.report == report)
        let stored = try database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM option_lab_documents") }
        #expect(stored == bytes)
        #expect(try database.migrationVersions() == ["foundation.v1", "options-lab.v1", "options-lab.v2", "options-lab.v3", "options-lab.v4", "options-lab.v5"])
    }

    @Test func pricedSnapshotReopensFromDiskWithBothSigmaSourcesAndCompleteAssumptions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("option-pricing-" + UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try opsInput(), store = try OptionLabStore(path: url.path)
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let pricing = try #require(saved.report.pricing)
        #expect(pricing.distribution != nil && pricing.longLegSensitivity != nil)
        #expect(pricing.input == input.pricing)
        #expect(pricing.legs.count == 2)
        #expect(pricing.legs.allSatisfy { $0.impliedVolatility.state == .available })
        let reopened = try OptionLabStore(path: url.path), result = try await reopened.open(id: input.id)
        #expect(result == saved && result.replayMatched)
        #expect(result.report.pricing?.modelReference == pricing.modelReference)
        #expect(result.report.pricing?.parameterReference == pricing.parameterReference)
        #expect(try await reopened.summaries().count == 1)
    }

    @Test func syntheticPricingAloneKeepsCatalogSynthetic() async throws {
        let original = try opsInput()
        var object = try #require(JSONSerialization.jsonObject(with: opsEncode(original)) as? [String: Any])
        for name in ["underlying", "shortLeg", "longLeg", "expiry"] {
            var entry = try #require(object[name] as? [String: Any])
            var source = try #require(entry["source"] as? [String: Any])
            source["origin"] = "manual"; entry["source"] = source; object[name] = entry
        }
        var capital = try #require(object["capital"] as? [String: Any]); capital["origin"] = "manual"; object["capital"] = capital
        let input = try JSONDecoder().decode(OptionLabInput.self, from: JSONSerialization.data(withJSONObject: object))
        let store = try OptionLabStore(path: ":memory:")
        _ = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let summary = try #require(try await store.summaries().first)
        #expect(summary.origin == .synthetic)
    }

    @Test(arguments: ["theory", "solver", "distribution", "model", "parameters", "removed"])
    func rehashedPricingTamperStillFailsBeforePublishingValues(_ field: String) async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let input = try opsInput()
        _ = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        try opsRewriteReport(database, id: input.id) { report in
            if field == "removed" { report.removeValue(forKey: "pricing"); return }
            var pricing = try #require(report["pricing"] as? [String: Any])
            switch field {
            case "theory", "solver":
                var legs = try #require(pricing["legs"] as? [[String: Any]])
                try #require(!legs.isEmpty)
                if field == "theory" { legs[0]["theoreticalPrice"] = 987.5 }
                else {
                    var iv = try #require(legs[0]["impliedVolatility"] as? [String: Any])
                    iv["volatility"] = 0.9875; legs[0]["impliedVolatility"] = iv
                }
                pricing["legs"] = legs
            case "distribution": pricing.removeValue(forKey: "distribution")
            case "model":
                var model = try #require(pricing["model"] as? [String: Any])
                model["formulaVersion"] = "unregistered-model"; pricing["model"] = model
            default:
                var parameters = try #require(pricing["parameters"] as? [String: Any])
                parameters["version"] = "unapproved-parameters"; pricing["parameters"] = parameters
            }
            report["pricing"] = pricing
        }
        // Metadata-only listing never certifies or publishes the priced body.
        #expect(try await store.summaries().count == 1)
        await #expect(throws: OptionLabStoreError.corruptedStorage) { try await store.open(id: input.id) }
        await #expect(throws: OptionLabStoreError.corruptedStorage) {
            try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        }
    }

    @Test func changingPricingAssumptionsCannotOverwriteFrozenIDOrAcquireNewSaveBaseline() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let input = try opsInput(), baseline = try await store.revision()
        let first = try await store.save(id: input.id, input: input, expectedRevision: baseline)
        let changed = try opsInput(id: input.id, rate: "-0.01"), rows = try opsRows(database)
        await #expect(throws: OptionLabStoreError.staleRevision) {
            try await store.save(id: changed.id, input: changed, expectedRevision: baseline)
        }
        await #expect(throws: OptionLabStoreError.conflictingSnapshot) {
            try await store.save(id: changed.id, input: changed, expectedRevision: store.revision())
        }
        #expect(try opsRows(database) == rows)
        #expect(try await store.open(id: input.id) == first)
    }

    @Test func pricedSaveRollsBackAndRetriesSameOriginalRevisionWithoutPartialModelRows() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .optionsLab), store = try OptionLabStore(database: database)
        let input = try opsInput(), baseline = try await store.revision(), before = try opsRows(database)
        await store.injectFailureOnNextSave()
        await #expect(throws: OptionLabStoreError.injectedFailure) {
            try await store.save(id: input.id, input: input, expectedRevision: baseline)
        }
        #expect(try opsRows(database) == before)
        let saved = try await store.save(id: input.id, input: input, expectedRevision: baseline)
        #expect(saved.report.pricing != nil)
        let rows = try opsRows(database)
        #expect(try await store.save(id: input.id, input: input, expectedRevision: store.revision()) == saved)
        #expect(try opsRows(database) == rows)
    }

    @Test func unavailableCanonicalIVCanBeFrozenWithoutInventingGreeksOrProbability() async throws {
        // Large positive discount makes this put quote exceed its European upper bound.
        let input = try opsInput(strategy: .cashSecuredPut, rate: "100"), store = try OptionLabStore(path: ":memory:")
        let saved = try await store.save(id: input.id, input: input, expectedRevision: store.revision())
        let pricing = try #require(saved.report.pricing)
        #expect(pricing.legs[0].impliedVolatility.state != .available)
        #expect(pricing.aggregateGreeks == nil && pricing.distribution == nil)
        #expect(pricing.legs[0].canonicalGreeks == nil)
        #expect(try await store.open(id: input.id) == saved)
    }
}
