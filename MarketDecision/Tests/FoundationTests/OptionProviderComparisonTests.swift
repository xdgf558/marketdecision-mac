import Foundation
import Testing
import CoreDomain
import OptionsAnalytics
import PortfolioEngine
import Persistence

@Suite("Offline provider IV and Greeks comparison")
struct OptionProviderComparisonTests {
    @Test func syntheticCompleteComparisonPreservesCanonicalLocalValues() throws {
        let input = try OptionProviderComparisonDemo.input()
        let result = try OptionProviderComparisonEngine.calculate(input)
        let row = try #require(result.rows.first)
        #expect(row.fields.count == 6)
        #expect(row.modelComparison == .sameEuropeanReference)
        #expect(result.input.localReport == input.localReport)
        #expect(result.containsSynthetic && result.researchOnly)
        let iv = try field(.iv, in: result), delta = try field(.delta, in: result)
        #expect(iv.thresholdExceeded == true)
        #expect(abs(try #require(iv.difference) + 0.06) < 1e-12)
        #expect(delta.local == input.localReport.pricing?.legs.first?.canonicalGreeks?.delta)
        #expect(row.fields.allSatisfy { $0.state == .compared })
        #expect(row.fields.filter { [.gamma, .theta, .vega, .rho].contains($0.field) }.allSatisfy { $0.absoluteThreshold == nil && $0.thresholdExceeded == nil })
    }

    @Test func missingProviderObservationAndFieldsRemainUnavailableNotZero() throws {
        let input = try OptionProviderComparisonDemo.input()
        let absent = try OptionProviderComparisonEngine.calculate(copy(input, observations: []))
        #expect(absent.rows[0].fields.allSatisfy { $0.state == .missingProviderValue && $0.provider == nil && $0.difference == nil && $0.thresholdExceeded == nil })
        let item = input.observations[0]
        let onlyIV = copy(item, values: [.iv: try #require(item.values[.iv])])
        let partial = try OptionProviderComparisonEngine.calculate(copy(input, observations: [onlyIV]))
        #expect(try field(.iv, in: partial).state == .compared)
        #expect(try field(.delta, in: partial).state == .missingProviderValue)
    }

    @Test func missingLocalPricingDoesNotUseProviderOrManualSigma() throws {
        let input = try OptionProviderComparisonDemo.input()
        let bare = try mutate(input.localReport.input) { $0.removeValue(forKey: "pricing") }
        let report = try OptionLabEngine.calculate(bare)
        let result = try OptionProviderComparisonEngine.calculate(copy(input, localReport: report))
        #expect(result.rows[0].modelComparison == .missingLocalPricing)
        #expect(result.rows[0].fields.allSatisfy { $0.local == nil && $0.provider != nil && $0.difference == nil && $0.state == .missingLocalValue })
    }

    @Test func unavailableLocalIVNeverUsesIndependentManualSigmaOrProviderIV() throws {
        let input = try OptionProviderComparisonDemo.input()
        let changed = try mutate(input.localReport.input) { json in
            var leg = try #require(json["shortLeg"] as? [String: Any])
            leg["bid"] = "101"; leg["ask"] = "101.2"; json["shortLeg"] = leg
        }
        // The deterministic payoff rejects impossible credit before an IV report can exist.
        #expect(throws: OptionLabError.invalidCredit) { try OptionLabEngine.calculate(changed) }
        let near = try mutate(input.localReport.input) { json in
            var expiry = try #require(json["expiry"] as? [String: Any])
            let asOf = try #require(json["asOf"] as? Double)
            expiry["settlementAt"] = asOf + 30
            var date = try #require(expiry["date"] as? [String: Any])
            date["year"] = 2026; date["month"] = 10; date["day"] = 16; expiry["date"] = date
            json["expiry"] = expiry
            var leg = try #require(json["shortLeg"] as? [String: Any]); leg["expirationDate"] = date; json["shortLeg"] = leg
        }
        let local = try OptionLabEngine.calculate(near)
        let original = input.observations[0]
        let observation = OptionProviderObservation(id: original.id, providerID: original.providerID, feedID: original.feedID,
            contract: .init(leg: near.shortLeg, expiry: near.expiry), valuationAt: original.valuationAt,
            quoteTime: original.quoteTime, underlyingQuoteTime: original.underlyingQuoteTime, receivedAt: original.receivedAt,
            source: original.source, model: original.model, values: original.values)
        let result = try OptionProviderComparisonEngine.calculate(copy(input, localReport: local, observations: [observation]))
        #expect(local.pricing?.input.volatility.amount ?? 0 > 0)
        #expect(result.rows[0].fields.allSatisfy { $0.local == nil && $0.state == .missingLocalValue })
    }

    @Test func duplicateObservationAndDuplicateContractReject() throws {
        let input = try OptionProviderComparisonDemo.input(), item = input.observations[0]
        #expect(throws: OptionProviderComparisonError.duplicateObservation) {
            try OptionProviderComparisonEngine.calculate(copy(input, observations: [item, item]))
        }
        let distinctID = try mutate(item) { $0["id"] = "different-id" }
        #expect(throws: OptionProviderComparisonError.duplicateObservation) {
            try OptionProviderComparisonEngine.calculate(copy(input, observations: [item, distinctID]))
        }
    }

    @Test func exactContractIdentityAndSpecificationRequired() throws {
        let input = try OptionProviderComparisonDemo.input()
        let mutations: [(String, Any)] = [("contractID", "OTHER"), ("symbol", "OTHER"), ("right", "call"),
            ("strike", "101"), ("multiplier", 10), ("exerciseStyle", "european"),
            ("delivery", "cashSettled"), ("specificationVersion", "other.v1")]
        for (key, value) in mutations {
            let item = try mutate(input.observations[0]) { json in
                var contract = try #require(json["contract"] as? [String: Any]); contract[key] = value; json["contract"] = contract
            }
            #expect(throws: OptionProviderComparisonError.mismatchedContract) {
                try OptionProviderComparisonEngine.calculate(copy(input, observations: [item]))
            }
        }
        let settlement = try mutate(input.observations[0]) { json in
            var contract = try #require(json["contract"] as? [String: Any])
            contract["settlementAt"] = try #require(contract["settlementAt"] as? Double) + 1
            json["contract"] = contract
        }
        #expect(throws: OptionProviderComparisonError.mismatchedContract) {
            try OptionProviderComparisonEngine.calculate(copy(input, observations: [settlement]))
        }
    }

    @Test func differentFeedCannotCompareEvenIdenticalValues() throws {
        let input = try OptionProviderComparisonDemo.input()
        let item = try mutate(input.observations[0]) { $0["feedID"] = "another-feed" }
        #expect(throws: OptionProviderComparisonError.mismatchedFeed) {
            try OptionProviderComparisonEngine.calculate(copy(input, observations: [item]))
        }
    }

    @Test func exactClocksRejectFutureStaleAndSameMillisecondDifference() throws {
        let input = try OptionProviderComparisonDemo.input()
        for key in ["valuationAt", "quoteTime", "underlyingQuoteTime", "receivedAt"] {
            for offset in [-61.0, 0.0004, 1.0] {
                let item = try mutate(input.observations[0]) { json in
                    json[key] = try #require(json[key] as? Double) + offset
                }
                #expect(throws: OptionProviderComparisonError.mismatchedTime) {
                    try OptionProviderComparisonEngine.calculate(copy(input, observations: [item]))
                }
            }
        }
    }

    @Test func observationCannotBeReceivedBeforeItsClaimedValuationTime() throws {
        let input = try OptionProviderComparisonDemo.input()
        let localInput = try mutate(input.localReport.input) { json in
            for key in ["shortLeg", "underlying"] {
                var item = try #require(json[key] as? [String: Any])
                item["quotedAt"] = try #require(item["quotedAt"] as? Double) - 5
                item["receivedAt"] = try #require(item["receivedAt"] as? Double) - 5
                json[key] = item
            }
        }
        let local = try OptionLabEngine.calculate(localInput)
        let observation = try mutate(input.observations[0]) { json in
            for key in ["quoteTime", "underlyingQuoteTime", "receivedAt"] {
                json[key] = try #require(json[key] as? Double) - 5
            }
        }
        #expect(throws: OptionProviderComparisonError.mismatchedTime) {
            try OptionProviderComparisonEngine.calculate(copy(input, localReport: local, observations: [observation]))
        }
    }

    @Test func wrongUnitsRejectWithoutImplicitScaling() throws {
        let input = try OptionProviderComparisonDemo.input(), item = input.observations[0]
        let wrong: [(OptionProviderField, OptionProviderUnit)] = [(.iv, .volatilityPercent), (.delta, .perContract),
            (.gamma, .perContract), (.theta, .perShareThetaPerYear), (.vega, .perShareVegaPerUnit), (.rho, .perShareRhoPerUnit)]
        for (field, unit) in wrong {
            var values = item.values; values[field] = .init(value: try #require(values[field]).value, unit: unit)
            #expect(throws: OptionProviderComparisonError.invalidUnit) {
                try OptionProviderComparisonEngine.calculate(copy(input, observations: [copy(item, values: values)]))
            }
        }
    }

    @Test func nonfiniteAndInvalidSignsReject() throws {
        let input = try OptionProviderComparisonDemo.input(), item = input.observations[0]
        let cases: [(OptionProviderField, Double)] = [(.iv, -.infinity), (.iv, -0.1), (.delta, 0.1), (.delta, -1.1),
            (.gamma, -0.1), (.vega, -0.1), (.theta, .nan), (.rho, .infinity)]
        for (field, value) in cases {
            var values = item.values; values[field] = .init(value: value, unit: field.unit)
            #expect(throws: OptionProviderComparisonError.invalidValue) {
                try OptionProviderComparisonEngine.calculate(copy(input, observations: [copy(item, values: values)]))
            }
        }
    }

    @Test func unknownAndDifferentModelsRetainDiagnosticDifferenceWithoutAlert() throws {
        let input = try OptionProviderComparisonDemo.input()
        for family in ["unknown", "american", "other"] {
            let item = try mutate(input.observations[0]) { json in
                var model = try #require(json["model"] as? [String: Any]); model["family"] = family; json["model"] = model
            }
            let result = try OptionProviderComparisonEngine.calculate(copy(input, observations: [item]))
            #expect(try field(.iv, in: result).difference != nil)
            #expect(result.rows[0].fields.allSatisfy { $0.thresholdExceeded == nil })
            #expect(result.rows[0].modelComparison == (family == "unknown" ? .unknownModel : .differentModel))
        }
    }

    @Test func incompleteAndDifferentModelAssumptionsAreNotComparable() throws {
        let input = try OptionProviderComparisonDemo.input()
        let missing = try mutate(input.observations[0]) { json in
            var model = try #require(json["model"] as? [String: Any]); model.removeValue(forKey: "continuousRate"); json["model"] = model
        }
        let absentResult = try OptionProviderComparisonEngine.calculate(copy(input, observations: [missing]))
        #expect(absentResult.rows[0].modelComparison == .unknownModel)
        let differing = try mutate(input.observations[0]) { json in
            var model = try #require(json["model"] as? [String: Any]); model["spot"] = "101"; json["model"] = model
        }
        let changedResult = try OptionProviderComparisonEngine.calculate(copy(input, observations: [differing]))
        #expect(changedResult.rows[0].modelComparison == .differentAssumptions)
        #expect(try field(.iv, in: changedResult).thresholdExceeded == nil)
    }

    @Test func deltaUsesAbsolutePointThresholdAndOtherGreeksHaveNoInventedAlert() throws {
        let input = try OptionProviderComparisonDemo.input(), item = input.observations[0]
        let delta = try #require(input.localReport.pricing?.legs[0].canonicalGreeks?.delta)
        for (difference, expected) in [(0.02, false), (0.04, true)] {
            var values = item.values; values[.delta] = .init(value: delta + difference, unit: .perShareDelta)
            let result = try OptionProviderComparisonEngine.calculate(copy(input, observations: [copy(item, values: values)]))
            #expect(try field(.delta, in: result).thresholdExceeded == expected)
            #expect(try field(.delta, in: result).absoluteThreshold == 0.03)
        }
    }

    @Test func identicalProviderValuesAreComparedAsZeroNotMissing() throws {
        let input = try OptionProviderComparisonDemo.input(), item = input.observations[0]
        let delta = try #require(input.localReport.pricing?.legs[0].canonicalGreeks?.delta)
        var values = item.values; values[.delta] = .init(value: delta, unit: .perShareDelta)
        let result = try OptionProviderComparisonEngine.calculate(copy(input, observations: [copy(item, values: values)]))
        let value = try field(.delta, in: result)
        #expect(value.difference == 0 && value.thresholdExceeded == false && value.state == .compared)
    }

    @Test func providerIVAndDeclaredGreekSigmaCannotContradict() throws {
        let input = try OptionProviderComparisonDemo.input()
        let item = try mutate(input.observations[0]) { json in
            var model = try #require(json["model"] as? [String: Any]); model["volatilityUsedForGreeks"] = 0.9; json["model"] = model
        }
        #expect(throws: OptionProviderComparisonError.invalidValue) {
            try OptionProviderComparisonEngine.calculate(copy(input, observations: [item]))
        }
    }

    @Test func fullJSONRoundtripReplaysAndTamperedOutputRejects() throws {
        let report = try OptionProviderComparisonEngine.calculate(OptionProviderComparisonDemo.input())
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(OptionProviderComparisonReport.self, from: data)
        #expect(try OptionProviderComparisonEngine.replay(decoded) == report)
        let altered = try mutate(decoded) { json in
            var rows = try #require(json["rows"] as? [[String: Any]])
            var fields = try #require(rows[0]["fields"] as? [[String: Any]])
            fields[0]["difference"] = 99; rows[0]["fields"] = fields; json["rows"] = rows
        }
        #expect(throws: OptionProviderComparisonError.incompatibleReport) { try OptionProviderComparisonEngine.replay(altered) }
    }

    @Test func mutatedLocalCanonicalReportIsRejectedBeforeComparison() throws {
        let input = try OptionProviderComparisonDemo.input()
        let local = try mutate(input.localReport) { json in
            var pricing = try #require(json["pricing"] as? [String: Any])
            var legs = try #require(pricing["legs"] as? [[String: Any]])
            var greeks = try #require(legs[0]["canonicalGreeks"] as? [String: Any])
            greeks["delta"] = -0.99; legs[0]["canonicalGreeks"] = greeks; pricing["legs"] = legs; json["pricing"] = pricing
        }
        #expect(throws: OptionLabError.incompatibleReport) { try OptionProviderComparisonEngine.calculate(copy(input, localReport: local)) }
    }

    @Test func comparisonModelAndParameterMutationCannotReplay() throws {
        let report = try OptionProviderComparisonEngine.calculate(OptionProviderComparisonDemo.input())
        for key in ["model", "parameters"] {
            let changed = try mutate(report) { json in
                var value = try #require(json[key] as? [String: Any]); value["version"] = "changed"; json[key] = value
            }
            #expect(throws: OptionProviderComparisonError.incompatibleReport) { try OptionProviderComparisonEngine.replay(changed) }
        }
    }

    @Test func sortedObjectFieldEncodingIsStableAcrossRepeatedDecode() throws {
        let original = try OptionProviderComparisonDemo.input()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expected = try encoder.encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: expected) as? [String: Any])
        let observations = try #require(object["observations"] as? [[String: Any]])
        let values = try #require(observations[0]["values"] as? [String: Any])
        #expect(Set(values.keys) == Set(OptionProviderField.allCases.map(\.rawValue)))
        for _ in 0..<20 {
            let decoded = try JSONDecoder().decode(OptionProviderComparisonInput.self, from: expected)
            #expect(try encoder.encode(decoded) == expected)
        }
    }

    @Test func unknownProviderFieldCannotDecodeAsSilentlyIgnoredEvidence() throws {
        let item = try OptionProviderComparisonDemo.input().observations[0]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        var values = try #require(object["values"] as? [String: Any])
        values["unsupported"] = ["value": 1, "unit": "perShareDelta"]
        object["values"] = values
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OptionProviderObservation.self, from: bytes) }
    }

    @Test func redecodedProviderDocumentRemainsIdempotentAfterDatabaseReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("options.sqlite").path
        let store = try OptionEvidenceStore(path: path)
        let input = OptionEvidenceInput.providerComparison(try OptionProviderComparisonDemo.input())
        let initialRevision = try await store.revision()
        let first = try await store.save(input, expectedRevision: initialRevision)
        let decoded = try JSONDecoder().decode(OptionEvidenceInput.self, from: JSONEncoder().encode(first.report.input))
        let reopened = try OptionEvidenceStore(path: path)
        let revision = try await reopened.revision()
        let second = try await reopened.save(decoded, expectedRevision: revision)
        #expect(first.inputHash == second.inputHash && first.reportHash == second.reportHash)
        #expect(first.report == second.report && second.replayMatched)
        #expect(try await reopened.revision() == revision)
    }

    private func field(_ field: OptionProviderField, in report: OptionProviderComparisonReport) throws -> OptionProviderComparisonField {
        try #require(report.rows.first?.fields.first { $0.field == field })
    }
    private func copy(_ input: OptionProviderComparisonInput, localReport: OptionLabReport? = nil,
                      observations: [OptionProviderObservation]? = nil) -> OptionProviderComparisonInput {
        .init(id: input.id, createdAt: input.createdAt, localReport: localReport ?? input.localReport,
              localFeedID: input.localFeedID, observations: observations ?? input.observations)
    }
    private func copy(_ item: OptionProviderObservation, values: [OptionProviderField: OptionProviderValue]) -> OptionProviderObservation {
        .init(id: item.id, providerID: item.providerID, feedID: item.feedID, contract: item.contract,
              valuationAt: item.valuationAt, quoteTime: item.quoteTime, underlyingQuoteTime: item.underlyingQuoteTime,
              receivedAt: item.receivedAt, source: item.source, model: item.model, values: values)
    }
    private func mutate<T: Codable>(_ value: T, _ body: (inout [String: Any]) throws -> Void) throws -> T {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        try body(&json)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }
}
