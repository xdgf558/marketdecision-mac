import Foundation
import Testing
import CoreDomain
import MarketAnalytics
@testable import MacroProviders

@Suite struct MacroSourceEngineTests {
    @Test(arguments: MacroSourceFormat.allCases)
    func syntheticFormatsPreserveRawBytesAndReplayAfterJSON(_ format: MacroSourceFormat) throws {
        let input=try MacroSourceDemo.input(format:format)
        let report=try MacroSourceEngine.evaluate(input)
        #expect(report.input.rawData == input.rawData && report.containsSynthetic && report.researchOnly)
        #expect(report.contentSHA256 == MacroSourceEngine.contentHash(input.rawData))
        #expect(!report.observations.isEmpty && report.selectedObservations.allSatisfy { $0.release != nil })
        let restored=try JSONDecoder().decode(MacroSourceReport.self,from:JSONEncoder().encode(report))
        #expect(try MacroSourceEngine.replay(restored) == report)
    }
    @Test func undatedRowsRemainVisibleButNeverBecomeAvailableFromRetrieval() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV)
        let report=try MacroSourceEngine.evaluate(copy(input,releases:[]))
        #expect(report.observations.count == 2 && report.observations.allSatisfy { $0.value != nil })
        #expect(report.selectedObservations.isEmpty && report.gaps.allSatisfy { $0.reason == .unverifiedRelease })
        #expect(try MacroSourceBridge.build(reports:[report],asOf:input.asOf).series.isEmpty)
    }
    @Test func alfredSelectsExactKnownRevisionRatherThanCurrentValue() throws {
        let input=try MacroSourceDemo.input(format:.alfredObservationsJSON)
        let early=try MacroSourceEngine.evaluate(copy(input,asOf:instant("2026-10-18T21:00:00Z")))
        let latest=try MacroSourceEngine.evaluate(input)
        #expect(early.selectedObservations.map(\.value) == [try Money("3.5")])
        #expect(latest.selectedObservations.map(\.value) == [try Money("3.75")])
        #expect(Set(latest.observations.map(\.observationID)).count == 1 && latest.observations.count == 2)
        #expect(latest.observations[0].vintageStart == "2026-10-16")
    }
    @Test(arguments: [MacroSourceFormat.fredObservationsJSON, .alfredObservationsJSON])
    func clippedRealtimeEndDoesNotInventExpiryOrPublication(_ format: MacroSourceFormat) throws {
        let fixture = try MacroSourceDemo.input(format: .alfredObservationsJSON)
        let d = fixture.descriptor, release = fixture.releases[0]
        let descriptor = MacroSourceDescriptor(format: format, series: d.series, sourceID: d.sourceID,
            feedID: d.feedID, basisVersion: d.basisVersion, revisionID: d.revisionID,
            sourceReference: d.sourceReference, licenseEvidence: d.licenseEvidence)
        let raw = Data(#"{"units":"lin","output_type":1,"offset":0,"count":1,"observations":[{"date":"2026-10-16","realtime_start":"2026-10-16","realtime_end":"2026-10-18","value":"3.500"}]}"#.utf8)
        let sourceValue = try Money("3.5"), bridgedValue = try Money("350")
        for origin in [MacroSourceOrigin.synthetic, .localFile] {
            let input = MacroImportInput(createdAt: fixture.createdAt, retrievedAt: fixture.retrievedAt,
                asOf: fixture.asOf, origin: origin, descriptor: descriptor, rawData: raw, releases: [release])
            let beforeRelease = release.availableAt.addingTimeInterval(-0.0002)
            let unavailable = try MacroSourceEngine.evaluate(copy(input, asOf: beforeRelease))
            #expect(unavailable.selectedObservations.isEmpty)
            #expect(try MacroSourceBridge.build(reports: [unavailable], asOf: beforeRelease).series.isEmpty)
            // A query ending on the 18th cannot certify a revision on the 19th.
            // The result remains only the last explicitly known imported evidence.
            for cutoff in [try instant("2026-10-18T21:00:00Z"), fixture.asOf] {
                let report = try MacroSourceEngine.evaluate(copy(input, asOf: cutoff))
                let restored = try JSONDecoder().decode(MacroSourceReport.self, from: JSONEncoder().encode(report))
                #expect(try MacroSourceEngine.replay(restored) == report)
                let selected = try #require(restored.selectedObservations.first)
                #expect(restored.selectedObservations.count == 1 && selected.value == sourceValue)
                #expect(selected.vintageEnd == "2026-10-18" && selected.release == release)
                let bridge = try MacroSourceBridge.build(reports: [restored], asOf: cutoff)
                let series = try #require(bridge.series.first)
                #expect(series.origin == (origin == .synthetic ? .synthetic : .manual))
                let observation = try #require(series.observations.first)
                #expect(observation.value == bridgedValue && observation.validUntil == nil)
                #expect(observation.availableAt == release.availableAt && observation.releasedAt == release.releasedAt)
            }
        }
    }
    @Test func submillisecondPublicationDoesNotMoveBeforeCutoffOnRoundTrip() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV)
        let base=input.asOf.addingTimeInterval(-1)
        let r=input.releases[1]
        let changed=MacroReleaseEvidence(series:r.series,observationDate:r.observationDate,vintageID:r.vintageID,
            releasedAt:base.addingTimeInterval(0.0004),availableAt:base.addingTimeInterval(0.0004),evidenceReference:r.evidenceReference)
        let before=try MacroSourceEngine.evaluate(copy(input,asOf:base.addingTimeInterval(0.0002),releases:[input.releases[0],changed]))
        let restored=try JSONDecoder().decode(MacroSourceReport.self,from:JSONEncoder().encode(before))
        #expect(try MacroSourceEngine.replay(restored) == before)
        #expect(before.selectedObservations.count == 1)
        let after=try MacroSourceEngine.evaluate(copy(input,asOf:base.addingTimeInterval(0.0006),releases:[input.releases[0],changed]))
        #expect(after.selectedObservations.count == 2)
    }
    @Test func currentVintageCannotBeGivenEarlierAvailability() throws {
        let input=try MacroSourceDemo.input(format:.alfredObservationsJSON), r=input.releases[1]
        let old=try instant("2026-10-17T12:00:00Z")
        let release=MacroReleaseEvidence(series:r.series,observationDate:r.observationDate,vintageID:r.vintageID,releasedAt:old,availableAt:old,evidenceReference:"explicit but invalid")
        #expect(throws:MacroSourceError.invalidReleaseEvidence) { try MacroSourceEngine.evaluate(copy(input,releases:[input.releases[0],release])) }
    }
    @Test func sourceMissingValueIsNotNumericZero() throws {
        let input=try MacroSourceDemo.input(format:.alfredObservationsJSON)
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:"3.500",with:"0").replacingOccurrences(of:"3.750",with:".")
        let report=try MacroSourceEngine.evaluate(copy(input,raw:raw))
        #expect(report.observations[0].value == (try Money("0")))
        #expect(report.selectedObservations[0].value == nil && report.selectedObservations[0].missingReason == .sourceMissingValue)
        // Existing market input has no missing-value tombstone: omit every version
        // of the affected observation instead of reviving its old zero/value.
        #expect(try MacroSourceBridge.build(reports:[report],asOf:input.asOf).series.isEmpty)
    }
    @Test(arguments:["\"units\":\"pch\"","\"output_type\":2","\"offset\":1","\"count\":3"])
    func transformedPartialAndOtherFREDShapesFail(_ replacement:String) throws {
        let input=try MacroSourceDemo.input()
        let old: String
        if replacement.contains("units") { old="\"units\":\"lin\"" }
        else if replacement.contains("output") { old="\"output_type\":1" }
        else if replacement.contains("offset") { old="\"offset\":0" }
        else { old="\"count\":2" }
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:old,with:replacement)
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw)) }
    }
    @Test func duplicateJSONKeysCannotChangeSourceInterpretation() throws {
        let input=try MacroSourceDemo.input()
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:"\"units\":\"lin\"",with:"\"units\":\"lin\",\"units\":\"lin\"")
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw)) }
    }
    @Test func fredNumericTokenMustRemainOfficialDecimalString() throws {
        let input=try MacroSourceDemo.input()
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:"\"321.100\"",with:"321.100")
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw)) }
    }
    @Test func excessiveDecimalPrecisionIsNotRoundedByJSON() throws {
        let input=try MacroSourceDemo.input()
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:"321.100",with:"1.123456789012345678901234567890123456789")
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw)) }
    }
    @Test func duplicateObservationVintageIsRejected() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV)
        let raw=String(decoding:input.rawData,as:UTF8.self)+"10/19/2026,19.00,21.00,17.00,18.00\r\n"
        #expect(throws:MacroSourceError.conflictingVersion) { try MacroSourceEngine.evaluate(copy(input,raw:raw)) }
    }
    @Test func unrelatedAndDuplicatedReleaseEvidenceIsRejected() throws {
        let input=try MacroSourceDemo.input(), r=input.releases[0]
        let alien=MacroReleaseEvidence(series:r.series,observationDate:"2020-01-01",vintageID:r.vintageID,releasedAt:r.releasedAt,availableAt:r.availableAt,evidenceReference:r.evidenceReference)
        #expect(throws:MacroSourceError.invalidReleaseEvidence) { try MacroSourceEngine.evaluate(copy(input,releases:[alien])) }
        #expect(throws:MacroSourceError.invalidReleaseEvidence) { try MacroSourceEngine.evaluate(copy(input,releases:[r,r])) }
    }
    @Test func releaseAfterRetrievalAndObservationBeforeItsDayAreRejected() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV), r=input.releases[1]
        for at in [input.retrievedAt.addingTimeInterval(0.1),try instant("2020-01-01T00:00:00Z")] {
            let changed=MacroReleaseEvidence(series:r.series,observationDate:r.observationDate,vintageID:r.vintageID,releasedAt:at,availableAt:at,evidenceReference:"SYNTHETIC")
            #expect(throws:MacroSourceError.invalidReleaseEvidence) { try MacroSourceEngine.evaluate(copy(input,releases:[changed])) }
        }
    }
    @Test func cboeHeaderAndOHLCContractAreClosed() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV),raw=String(decoding:input.rawData,as:UTF8.self)
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:"CLOSE",with:"PRICE"))) }
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:"22.00",with:"2.00"))) }
    }
    @Test func cboePCRPreservesPublishedRoundingAndSeparatePopulation() throws {
        let input=try MacroSourceDemo.input(format:.cboePutCallHistoryCSV)
        let report=try MacroSourceEngine.evaluate(input)
        #expect(report.observations[0].rawFields["P/C Ratio"] == "0.75")
        let bridge=try MacroSourceBridge.build(reports:[report],asOf:input.asOf)
        #expect(bridge.series[0].population == "CBOE:C1:EQUITY" && bridge.series[0].key == .equityPutCall)
        let d=input.descriptor
        let wrong=descriptor(d,population:"ALL_US_OPTIONS")
        #expect(throws:MacroSourceError.unsupportedSeries) { try MacroSourceEngine.evaluate(copy(input,descriptor:wrong)) }
    }
    @Test func cboeFractionalCountsAndInconsistentTotalsFail() throws {
        let input=try MacroSourceDemo.input(format:.cboePutCallHistoryCSV),raw=String(decoding:input.rawData,as:UTF8.self)
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:",100,75,175,",with:",100.5,75,175.5,"))) }
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:",100,75,175,",with:",100,75,170,"))) }
    }
    @Test func cftcQuotedCommaAndIndependentPositionClassesArePreserved() throws {
        let input=try MacroSourceDemo.input(format:.cftcFinancialFuturesCSV),report=try MacroSourceEngine.evaluate(input)
        #expect(report.observations.map(\.value) == [try Money("0.4"),try Money("-0.2")])
        #expect(report.observations[0].rawFields["Market_and_Exchange_Names"] == "SYNTHETIC INDEX, EXCHANGE")
        #expect(report.observations[0].rawFields["Open_Interest_All"] == "1000")
        #expect(report.observations.allSatisfy { $0.observationDate == "2026-10-13" && $0.release?.releasedAt == input.releases[0].releasedAt })
        let bridge=try MacroSourceBridge.build(reports:[report],asOf:input.asOf)
        #expect(bridge.series.count == 2 && bridge.series.allSatisfy { $0.frequency == .weekly })
    }
    @Test func cftcContractScopeAndReportDateMustMatch() throws {
        let input=try MacroSourceDemo.input(format:.cftcFinancialFuturesCSV),raw=String(decoding:input.rawData,as:UTF8.self)
        #expect(throws:MacroSourceError.unsupportedSeries) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:"13874A",with:"999999"))) }
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:",FutOnly",with:",Combined"))) }
        #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:"261013",with:"261014"))) }
    }
    @Test func cftcZeroOIIsAnExplicitGapAndNegativeOrFractionalCountsFail() throws {
        let input=try MacroSourceDemo.input(format:.cftcFinancialFuturesCSV),raw=String(decoding:input.rawData,as:UTF8.self)
        let empty=raw.replacingOccurrences(of:",1000,600,200,100,300,",with:",0,0,0,0,0,")
        let report=try MacroSourceEngine.evaluate(copy(input,raw:empty))
        #expect(report.observations.allSatisfy { $0.value == nil && $0.missingReason == .zeroOpenInterest })
        for value in ["-600","0.5"] {
            #expect(throws:MacroSourceError.malformedSource) { try MacroSourceEngine.evaluate(copy(input,raw:raw.replacingOccurrences(of:",600,",with:","+value+","))) }
        }
    }
    @Test(arguments:["a,a\n1,2\n","a,b\n1\n","a,b\n\"unterminated,2\n","a,b\n\"closed\"junk,2\n"])
    func malformedCSVNeverSilentlyDropsOrReassignsColumns(_ raw:String) {
        #expect(throws:MacroSourceError.malformedSource) { try MacroCSV.parse(Data(raw.utf8)) }
    }
    @Test func sourceHashAndDerivedAnswersAreRecomputedOnReplay() throws {
        let report=try MacroSourceEngine.evaluate(MacroSourceDemo.input())
        var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(report)) as? [String:Any])
        json["contentSHA256"]=String(repeating:"0",count:64)
        let changed=try JSONDecoder().decode(MacroSourceReport.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(throws:MacroSourceError.incompatibleReport) { try MacroSourceEngine.replay(changed) }
    }
    @Test func sourceUnitConversionIsExplicitAndMacroReleaseCycleStaysSeparate() throws {
        let rate=try MacroSourceEngine.evaluate(MacroSourceDemo.input(format:.alfredObservationsJSON))
        let macro=try MacroSourceEngine.evaluate(MacroSourceDemo.input())
        let bridge=try MacroSourceBridge.build(reports:[rate,macro],asOf:rate.input.asOf)
        #expect(rate.observations[1].value == (try Money("3.75")) && rate.observations[1].unit == .percent)
        #expect(bridge.series.count == 1 && bridge.series[0].unit == .basisPoints)
        #expect(bridge.series[0].observations.last?.value == (try Money("375")))
        #expect(bridge.transformations == ["BAMLH0A0HYM2:percent-to-basis-points:x100"])
        #expect(bridge.gaps.contains { $0.series == .cpi && $0.reason == .noMarketMapping })
    }
    @Test func identicalReportsDoNotInflateSampleCount() throws {
        let report=try MacroSourceEngine.evaluate(MacroSourceDemo.input(format:.alfredObservationsJSON))
        let bridge=try MacroSourceBridge.build(reports:[report,report],asOf:report.input.asOf)
        #expect(bridge.series[0].observations.count == 2 && Set(bridge.series[0].observations.map(\.observationID)).count == 1)
    }
    @Test func crossFeedAndConflictingSameVintageValuesCannotBeMerged() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV),first=try MacroSourceEngine.evaluate(input)
        let changedFeed=try MacroSourceEngine.evaluate(copy(input,descriptor:descriptor(input.descriptor,feedID:"other")))
        #expect(throws:MacroSourceError.conflictingVersion) { try MacroSourceBridge.build(reports:[first,changedFeed],asOf:input.asOf) }
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:",18.00\r",with:",18.50\r")
        let changedValue=try MacroSourceEngine.evaluate(copy(input,raw:raw))
        #expect(throws:MacroSourceError.conflictingVersion) { try MacroSourceBridge.build(reports:[first,changedValue],asOf:input.asOf) }
    }
    @Test func sameRawCanAcquireExplicitReleaseWithoutDuplicatingVersions() throws {
        let input=try MacroSourceDemo.input(format:.cboeIndexHistoryCSV)
        let undated=try MacroSourceEngine.evaluate(copy(input,releases:[])),dated=try MacroSourceEngine.evaluate(input)
        #expect(undated.contentSHA256 == dated.contentSHA256 && undated.selectedObservations.isEmpty)
        let bridge=try MacroSourceBridge.build(reports:[undated,dated],asOf:input.asOf)
        #expect(bridge.series[0].observations.count == 2)
    }
    @Test func newerUndatedAlfredVersionDoesNotReviveOlderValue() throws {
        let input=try MacroSourceDemo.input(format:.alfredObservationsJSON)
        let report=try MacroSourceEngine.evaluate(copy(input,releases:[input.releases[0]]))
        #expect(report.selectedObservations.isEmpty)
        #expect(try MacroSourceBridge.build(reports:[report],asOf:input.asOf).series.isEmpty)
        let early=try MacroSourceBridge.build(reports:[report],asOf:instant("2026-10-18T21:00:00Z"))
        #expect(early.series.first?.observations.count == 1)
    }
    @Test func unknownSeriesDeclarationFailsDecodingRatherThanBeingGuessed() throws {
        let input=try MacroSourceDemo.input()
        let text=String(decoding:try JSONEncoder().encode(input),as:UTF8.self).replacingOccurrences(of:"CPIAUCSL",with:"UNKNOWN_SERIES")
        #expect(throws:(any Error).self) { try JSONDecoder().decode(MacroImportInput.self,from:Data(text.utf8)) }
    }
    @Test func emptyBridgeDoesNotInventAnySeries() throws {
        let result=try MacroSourceBridge.build(reports:[],asOf:instant("2026-10-19T21:00:00Z"))
        #expect(result.series.isEmpty && result.gaps.isEmpty)
    }
    @Test func singleFredResponseRejectsOverlappingIntervalsButKeepsAdjacentVersions() throws {
        let input=try MacroSourceDemo.input(format:.alfredObservationsJSON)
        #expect(try MacroSourceEngine.evaluate(input).observations.count == 2)
        let raw=String(decoding:input.rawData,as:UTF8.self).replacingOccurrences(of:"2026-10-18",with:"9999-12-31")
        #expect(throws:MacroSourceError.conflictingVersion) { try MacroSourceEngine.evaluate(copy(input,raw:raw,releases:[])) }
    }
    @Test func optionalFredSeriesIdentityMustMatchWhenPresent() throws {
        let input=try MacroSourceDemo.input(), raw=String(decoding:input.rawData,as:UTF8.self)
        for field in ["\"series_id\":\"UNRATE\",", "\"series_id\":42,"] {
            let altered="{"+field+raw.dropFirst()
            #expect(throws:MacroSourceError.unsupportedSeries) { try MacroSourceEngine.evaluate(copy(input,raw:altered)) }
        }
    }
    @Test func sourceReportCutoffNeverOverridesTheMarketTemplateCutoff() throws {
        let source=try MacroSourceEngine.evaluate(MacroSourceDemo.input(format:.cboeIndexHistoryCSV))
        let template=try MarketStateDemo.input(sessionCount:5)
        let sessions=template.sessions.filter { $0.date <= "2026-10-16" }
        let close=try #require(sessions.last?.closeAt)
        let base=MarketStateInput(createdAt:template.createdAt,asOf:close,sessionDate:"2026-10-16",sessions:sessions,
            calendarEvidence:template.calendarEvidence,series:template.series)
        let result=try MacroMarketBridgeEngine.evaluate(.init(createdAt:template.createdAt,base:base,sources:[source]))
        #expect(result.input.sources[0].input.asOf > close && result.market.current.asOf == close)
        let rows=try #require(result.bridge.series.first).observations
        try #require(rows.count == 1)
        let expected = try Money("19")
        #expect(rows[0].observationDate == "2026-10-16" && rows[0].value == expected)
    }
    @Test func tamperingFrozenTypedValueFailsBeforeMarketBridge() throws {
        let source=try MacroSourceEngine.evaluate(MacroSourceDemo.input(format:.cboeIndexHistoryCSV))
        var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any])
        var rows=try #require(json["observations"] as? [[String:Any]])
        rows[0]["value"]="999"; json["observations"]=rows
        let altered=try JSONDecoder().decode(MacroSourceReport.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(throws:MacroSourceError.incompatibleReport) { try MacroSourceBridge.build(reports:[altered],asOf:source.input.asOf) }
    }
    private func instant(_ text:String)throws->Date { try MacroSourceDemo.instant(text) }
    private func copy(_ input:MacroImportInput,raw:String?=nil,asOf:Date?=nil,releases:[MacroReleaseEvidence]?=nil,descriptor:MacroSourceDescriptor?=nil)->MacroImportInput {
        .init(id:input.id,createdAt:input.createdAt,retrievedAt:input.retrievedAt,asOf:asOf ?? input.asOf,origin:input.origin,
              descriptor:descriptor ?? input.descriptor,rawData:raw.map { Data($0.utf8) } ?? input.rawData,releases:releases ?? input.releases)
    }
    private func descriptor(_ d:MacroSourceDescriptor,feedID:String?=nil,population:String?=nil)->MacroSourceDescriptor {
        .init(format:d.format,series:d.series,sourceID:d.sourceID,feedID:feedID ?? d.feedID,basisVersion:d.basisVersion,
              population:population ?? d.population,revisionID:d.revisionID,sourceReference:d.sourceReference,licenseEvidence:d.licenseEvidence,
              cftcContractCode:d.cftcContractCode,cftcScope:d.cftcScope)
    }
}
