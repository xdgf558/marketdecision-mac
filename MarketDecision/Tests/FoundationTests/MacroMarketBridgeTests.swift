import Foundation
import Testing
import CoreDomain
import MarketAnalytics
import MacroProviders

@Suite struct MacroMarketBridgeTests {
    @Test func frozenBundleOwnsSourceBytesAndReplaysAfterJSONRoundTrip() throws {
        let source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        let input = try bundle([source])
        let report = try MacroMarketBridgeEngine.evaluate(input)
        let bytes = try JSONEncoder().encode(report)
        let reopened = try JSONDecoder().decode(MacroMarketBridgeReport.self, from: bytes)
        #expect(try MacroMarketBridgeEngine.replay(reopened) == report)
        #expect(reopened.input.sources.first?.input.rawData == source.input.rawData)
        #expect(report.researchOnly && report.containsSynthetic)
        #expect(report.market.input.id == input.id)
        #expect(report.market.input.asOf == input.base.asOf)
    }

    @Test func selectedUnverifiedSourceRemovesOldTemplateValueInsteadOfFallingBack() throws {
        let complete = try MacroSourceDemo.input(format: .cboeIndexHistoryCSV)
        let missing = MacroImportInput(id: complete.id, createdAt: complete.createdAt,
            retrievedAt: complete.retrievedAt, asOf: complete.asOf, origin: complete.origin,
            descriptor: complete.descriptor, rawData: complete.rawData, releases: [])
        let source = try MacroSourceEngine.evaluate(missing)
        let input = try bundle([source])
        #expect(input.base.series.contains { $0.key == .vix && !$0.observations.isEmpty })
        let result = try MacroMarketBridgeEngine.evaluate(input)
        #expect(result.replacedKeys.contains(.vix))
        #expect(result.market.input.series.first(where: { $0.key == .vix })?.observations.isEmpty ?? true)
        #expect(result.market.current.stress.components.first(where: { $0.id == "stress.implied" })?.value == nil)
        #expect(!result.bridge.gaps.isEmpty)
    }

    @Test func existingPriceTotalReturnAndCalendarInputsRemainDistinctAndUnchanged() throws {
        let source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        let input = try bundle([source]), result = try MacroMarketBridgeEngine.evaluate(input)
        for key in MarketSeriesKey.allCases where !result.replacedKeys.contains(key) {
            #expect(result.market.input.series.first(where: { $0.key == key }) == input.base.series.first(where: { $0.key == key }))
        }
        #expect(result.market.input.calendarEvidence == input.base.calendarEvidence)
        #expect(result.market.input.sessions == input.base.sessions)
        #expect(result.market.input.methodVersion == input.base.methodVersion)
    }

    @Test func releaseCycleOnlySourceCannotSilentlyCreateUnchangedMarketReport() throws {
        let base = try MarketStateDemo.input(sessionCount: 5)
        let source = try MacroSourceEngine.evaluate(cpiInput(at: base.asOf))
        #expect(source.input.descriptor.series == [.cpi])
        #expect(throws: MacroSourceError.unsupportedSeries) {
            try MacroMarketBridgeEngine.evaluate(bundle([source]))
        }
    }

    @Test func sourceIdentityDuplicatesAndEmptySelectionAreRejected() throws {
        let source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        #expect(throws: MacroSourceError.invalidInput) { try MacroMarketBridgeEngine.evaluate(bundle([source, source])) }
        #expect(throws: MacroSourceError.invalidInput) { try MacroMarketBridgeEngine.evaluate(bundle([])) }
    }

    @Test func futureCreatedSourceCannotBeFrozenByEarlierBundle() throws {
        let source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        let input = try bundle([source])
        let invalid = MacroMarketBridgeInput(createdAt: source.createdAt.addingTimeInterval(-1), base: input.base, sources: [source])
        #expect(throws: MacroSourceError.invalidInput) { try MacroMarketBridgeEngine.evaluate(invalid) }
    }

    @Test func tamperingSelectedSourceRawFileIsRejectedBeforeMarketReplay() throws {
        let source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        let report = try MacroMarketBridgeEngine.evaluate(bundle([source]))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var input = try #require(object["input"] as? [String: Any])
        var sources = try #require(input["sources"] as? [[String: Any]])
        var sourceInput = try #require(sources[0]["input"] as? [String: Any])
        sourceInput["rawData"] = Data("unrelated bytes".utf8).base64EncodedString()
        sources[0]["input"] = sourceInput; input["sources"] = sources; object["input"] = input
        let damaged = try JSONDecoder().decode(MacroMarketBridgeReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try MacroMarketBridgeEngine.replay(damaged) }
    }

    @Test func alteredMarketResultOrBridgeVersionCannotPassReopening() throws {
        let source = try MacroSourceEngine.evaluate(MacroSourceDemo.input(format: .cboeIndexHistoryCSV))
        let report = try MacroMarketBridgeEngine.evaluate(bundle([source]))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object["schemaVersion"] = "macro-market-bridge.future"
        let damaged = try JSONDecoder().decode(MacroMarketBridgeReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: MacroSourceError.incompatibleReport) { try MacroMarketBridgeEngine.replay(damaged) }
        object["schemaVersion"] = report.schemaVersion
        var market = try #require(object["market"] as? [String: Any]); market["researchOnly"] = false; object["market"] = market
        let modified = try JSONDecoder().decode(MacroMarketBridgeReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: MacroSourceError.incompatibleReport) { try MacroMarketBridgeEngine.replay(modified) }
    }

    private func bundle(_ sources: [MacroSourceReport]) throws -> MacroMarketBridgeInput {
        let base = try MarketStateDemo.input(sessionCount: 5)
        let created = max(base.createdAt, sources.map(\.createdAt).max() ?? base.createdAt)
        return .init(createdAt: created, base: base, sources: sources)
    }
    private func cpiInput(at date: Date) throws -> MacroImportInput {
        let raw = Data(#"{"realtime_start":"2026-10-01","realtime_end":"2026-10-19","observation_start":"2026-09-01","observation_end":"2026-09-01","units":"lin","output_type":1,"file_type":"json","order_by":"observation_date","sort_order":"asc","count":1,"offset":0,"limit":100000,"observations":[{"realtime_start":"2026-10-01","realtime_end":"9999-12-31","date":"2026-09-01","value":"330.0"}]}"#.utf8)
        return .init(createdAt: date, retrievedAt: date, asOf: date, origin: .synthetic,
            descriptor: .init(format: .fredObservationsJSON, series: [.cpi], sourceID: "SYNTHETIC-fred",
                feedID: "SYNTHETIC-macro", basisVersion: "SYNTHETIC-source-units",
                revisionID: "SYNTHETIC-1", sourceReference: "SYNTHETIC-fixture", licenseEvidence: "SYNTHETIC-only"), rawData: raw)
    }
}
