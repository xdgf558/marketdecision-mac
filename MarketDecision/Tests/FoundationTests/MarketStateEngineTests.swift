import Foundation
import Testing
import CoreDomain
@testable import MarketAnalytics

@Suite struct MarketStateEngineTests {
    @Test func emptySourcesAreMissingNotZeroAndNeverQualified() throws {
        let input=try fixture(count:1,series:[])
        let report=try MarketStateEngine.calculate(input)
        #expect(report.current.heat.value == nil && report.current.stress.value == nil && report.current.sentiment.value == nil)
        #expect(report.current.heat.effectiveWeightBps == 0)
        #expect(report.current.rawLabel == .unreliable && report.current.confirmedLabel == .unreliable)
        #expect(report.researchOnly && report.history.count == 1)
        #expect(report.diagnostics.commonValidDayCount == 0 && report.diagnostics.frequencies.allSatisfy { $0.fraction == nil })
    }
    @Test func fixedDefinitionsPreserveApprovedVersionsAndAllFifteenWeights() throws {
        let (p,m)=try MarketStateEngine.definitions()
        #expect(p.version == "MARKET_PARAMETERS_V1" && m.defaultParameters == p.reference)
        #expect(MarketStateEngine.components.count == 15)
        for kind in MarketScoreKind.allCases {
            #expect(MarketStateEngine.components.filter { $0.kind == kind }.reduce(0) { $0+$1.weight } == 10000)
        }
        #expect(MarketStateEngine.components.first { $0.id == "heat.trend" }?.atoms.count == 9)
        #expect(MarketStateEngine.components.first { $0.id == "heat.momentum" }?.atoms.count == 12)
    }
    @Test func exactSeventyPercentTopCoverageProducesScoreAndContributions() throws {
        let specs=MarketStateEngine.components
        var results=allAtoms(score:80)
        for atom in specs.first(where:{$0.id == "heat.trend"})!.atoms { results[atom.id]=atomResult(atom.id,score:nil) }
        let score=MarketStateEngine.aggregate(.heat,specs:specs,results:results)
        #expect(score.effectiveWeightBps == 7000 && score.value == 80)
        #expect(score.droppedComponents.map(\.id) == ["heat.trend"])
        #expect(abs(score.components.compactMap(\.contribution).reduce(0,+)-80)<1e-12)
    }
    @Test func belowSeventyTopCoverageKeepsComponentsWithoutTotal() throws {
        var results=allAtoms(score:60)
        for spec in MarketStateEngine.components where ["stress.term","stress.drawdown"].contains(spec.id) {
            for atom in spec.atoms { results[atom.id]=atomResult(atom.id,score:nil) }
        }
        let score=MarketStateEngine.aggregate(.stress,specs:MarketStateEngine.components,results:results)
        #expect(score.effectiveWeightBps == 6500 && score.value == nil)
        #expect(score.components.allSatisfy { $0.contribution == nil })
    }
    @Test func atomCoverageUsesIntegerCountsAndCannotPromoteSixOfNine() throws {
        let trend=try #require(MarketStateEngine.components.first { $0.id == "heat.trend" })
        var results=allAtoms(score:50)
        for atom in trend.atoms.prefix(3) { results[atom.id]=atomResult(atom.id,score:nil) }
        #expect(MarketStateEngine.aggregate(.heat,specs:MarketStateEngine.components,results:results).components.first?.value == nil)
        results[trend.atoms[2].id]=atomResult(trend.atoms[2].id,score:50)
        #expect(MarketStateEngine.aggregate(.heat,specs:MarketStateEngine.components,results:results).components.first?.value == 50)
    }
    @Test func thresholdsHaveInclusiveLowAndHighAndSentimentIsNotAnInput() {
        #expect(MarketStateEngine.classify(heat:65,stress:35) == .expansion)
        #expect(MarketStateEngine.classify(heat:65,stress:65) == .volatileRally)
        #expect(MarketStateEngine.classify(heat:35,stress:65) == .contraction)
        #expect(MarketStateEngine.classify(heat:35,stress:35) == .quietConsolidation)
        #expect(MarketStateEngine.classify(heat:35.000001,stress:65) == .transition)
        #expect(MarketStateEngine.classify(heat:80,stress:64.999999) == .transition)
        #expect(MarketStateEngine.classify(heat:nil,stress:90) == .unreliable)
    }
    @Test func firstClosedSessionInitializesThenChangeRequiresTwoSessions() {
        let first=MarketStateEngine.confirm(raw:.expansion,previous:nil,closed:true)
        #expect(first.label == .expansion && first.streak == 1)
        let prior=day(raw:.expansion,confirmed:.expansion,streak:1)
        let pending=MarketStateEngine.confirm(raw:.contraction,previous:prior,closed:true)
        #expect(pending.label == .expansion && pending.streak == 1)
        let second=MarketStateEngine.confirm(raw:.contraction,previous:day(raw:.contraction,confirmed:.expansion,streak:1),closed:true)
        #expect(second.label == .contraction && second.streak == 2)
    }
    @Test func missingDayImmediatelyBecomesUnreliableAndBreaksStreak() {
        let missing=MarketStateEngine.confirm(raw:.unreliable,previous:day(raw:.expansion,confirmed:.expansion,streak:2),closed:true)
        #expect(missing.label == .unreliable && missing.streak == 0)
        let resumed=MarketStateEngine.confirm(raw:.expansion,previous:day(raw:.unreliable,confirmed:.unreliable,streak:0),closed:true)
        #expect(resumed.label == .unreliable && resumed.streak == 1)
    }
    @Test func intradayRefreshNeverCountsAsAnotherConfirmationDay() {
        let current=MarketStateEngine.confirm(raw:.contraction,previous:day(raw:.contraction,confirmed:.expansion,streak:1),closed:false)
        #expect(current.label == .expansion && current.streak == 0)
        #expect(MarketStateEngine.confirm(raw:.expansion,previous:nil,closed:false).label == .unreliable)
    }
    @Test func exactSubmillisecondAvailabilityNeverMovesEarlier() throws {
        let base=try fixture(count:1,series:[])
        let close=base.sessions[0].closeAt
        let value=try observation("same",day:base.sessionDate,value:"0.8",release:close.addingTimeInterval(0.0004))
        let source=series(.advancingFraction,[value],population:"universe")
        let before=copy(base,asOf:close.addingTimeInterval(0.0002),series:[source])
        let after=copy(base,asOf:close.addingTimeInterval(0.0006),series:[source])
        let first=try MarketStateEngine.calculate(before),second=try MarketStateEngine.calculate(after)
        #expect(first.current.heat.components[1].atoms[0].rawValue == nil)
        #expect(second.current.heat.components[1].atoms[0].rawValue == 0.8)
        let decoded=try JSONDecoder().decode(MarketStateReport.self,from:JSONEncoder().encode(first))
        #expect(decoded.input.asOf == before.asOf)
        #expect(try MarketStateEngine.replay(decoded) == first)
    }
    @Test func historicalFormulaUsesVintageAvailableAtThatSessionNotLatest() throws {
        let base=try fixture(count:3,series:[])
        let first=try observation("obs",day:base.sessions[0].date,value:"10",release:base.sessions[0].closeAt)
        let revised=MarketObservation(observationID:first.observationID,vintageID:"revision2",observationDate:first.observationDate,
            releasedAt:base.sessions[2].closeAt,availableAt:base.sessions[2].closeAt,value:try Money("99"),rawValue:"99")
        let input=copy(base,series:[series(.vix,[first,revised])])
        let report=try MarketStateEngine.calculate(input)
        #expect(report.history[0].stress.components[0].atoms[0].rawValue == 10)
        #expect(report.history[1].stress.components[0].atoms[0].rawValue == 10)
        #expect(report.history[2].stress.components[0].atoms[0].rawValue == 99)
    }
    @Test func strictLessCountsTiesAsZeroAndExcludesCurrent() throws {
        let base=try fixture(count:253,series:[])
        let values=try base.sessions.enumerated().map { index,s in try observation("o\(index)",day:s.date,value:"10",release:s.closeAt) }
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.vix,values)]))
        let atom=report.current.stress.components[0].atoms[0]
        #expect(atom.independentHistoryCount == 252 && atom.score == 0)
        #expect(report.history[251].stress.components[0].atoms[0].score == nil)
    }
    @Test func currentHighValueRanksAboveExactly252PastObservations() throws {
        let base=try fixture(count:253,series:[])
        let values=try base.sessions.enumerated().map { index,s in try observation("o\(index)",day:s.date,value:String(index+1),release:s.closeAt) }
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.vix,values)]))
        #expect(report.current.stress.components[0].atoms[0].score == 100)
        #expect(report.current.stress.components[0].atoms[0].independentHistoryCount == 252)
    }
    @Test func revisionsAndRepeatedDailyCarriesCannotCreateIndependentSamples() throws {
        let base=try fixture(count:253,series:[])
        var values:[MarketObservation]=[]
        for (i,s) in base.sessions.enumerated() where i % 2 == 0 {
            let first=try observation("o\(i)",day:s.date,value:"10",release:s.closeAt.addingTimeInterval(-1))
            values.append(first)
            values.append(.init(observationID:first.observationID,vintageID:"rev-\(i)",observationDate:s.date,
                releasedAt:s.closeAt,availableAt:s.closeAt,value:try Money("11"),rawValue:"11"))
        }
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.vix,values)]))
        let atom=report.current.stress.components[0].atoms[0]
        #expect(atom.independentHistoryCount == 126 && atom.score == nil && atom.missingReason == .insufficientHistory)
    }
    @Test func weeklyObservationsRemainWeeklyDespiteDailySnapshots() throws {
        let base=try fixture(count:300,series:[])
        let values=try base.sessions.enumerated().compactMap { i,s -> MarketObservation? in
            i % 5 == 0 ? try observation("w\(i)",day:s.date,value:String(i+1),release:s.closeAt) : nil
        }
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.naaim,values,frequency:.weekly)]))
        let atom=report.current.sentiment.components[2].atoms[0]
        #expect(atom.independentHistoryCount == 59 && atom.score == nil)
    }
    @Test func fiveCalendarYearWindowDoesNotExpandToMeetMinimumCount() throws {
        let base=try fixture(count:253,series:[],start:"2018-01-02")
        let finalDate=try #require(MarketStateEngine.parseDay("2026-01-02"))
        var sessions=base.sessions; sessions[sessions.count-1] = .init(date:"2026-01-02",closeAt:finalDate.addingTimeInterval(21*3600))
        let values=try sessions.enumerated().map { i,s in try observation("o\(i)",day:s.date,value:String(i+1),release:s.closeAt) }
        let input=MarketStateInput(createdAt:max(sessions.last!.closeAt,Date(timeIntervalSince1970:1792368000)),asOf:sessions.last!.closeAt,sessionDate:"2026-01-02",sessions:sessions,
            calendarEvidence:"synthetic gaps are fixture data, not production calendar",series:[series(.vix,values)])
        let report=try MarketStateEngine.calculate(input)
        #expect(report.current.stress.components[0].atoms[0].independentHistoryCount == 0)
        #expect(report.current.stress.components[0].atoms[0].score == nil)
    }
    @Test func dailyStalenessCountsDeclaredTradingSessionsNotWeekendDays() throws {
        let base=try fixture(count:5,series:[],start:"2026-10-02") // Friday; weekend omitted from declared sessions.
        let value=try observation("friday",day:base.sessions[0].date,value:"18",release:base.sessions[0].closeAt)
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.vix,[value])]))
        #expect(report.history[3].stress.components[0].atoms[0].rawValue == 18)
        #expect(report.history[4].stress.components[0].atoms[0].missingReason == .stale)
    }
    @Test func weeklyThreeMonthDelayNeverBecomesCurrentEvidence() throws {
        let base=try fixture(count:70,series:[])
        let source=try observation("delayed",day:base.sessions[0].date,value:"50",release:base.sessions.last!.closeAt)
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.naaim,[source],frequency:.weekly)]))
        #expect(report.current.sentiment.components[2].atoms[0].missingReason == .stale)
    }
    @Test func dailySeriesCannotDeclareReleaseCycleToBypassTradingDayStaleness() throws {
        let base=try fixture(count:1,series:[])
        let source=try observation("macro",day:base.sessionDate,value:"350",release:base.asOf)
        #expect(throws:MarketStateError.invalidInput) {
            try MarketStateEngine.calculate(copy(base,series:[series(.highYieldOAS,[source],frequency:.releaseCycle)]))
        }
    }
    @Test func dailyObservationOutsideCalendarCoverageCannotCountAsOneSessionOld() throws {
        let base=try fixture(count:1,series:[])
        let source=try observation("old",day:"2010-01-04",value:"20",release:Date(timeIntervalSince1970:1262642400))
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.vix,[source])]))
        #expect(report.current.stress.components[0].atoms[0].rawValue == nil)
        #expect(report.current.stress.components[0].atoms[0].missingReason == .insufficientWindow)
    }
    @Test func cutoffCannotKeepOldSessionCurrentYearsLater() throws {
        let base=try fixture(count:1,series:[])
        #expect(throws:MarketStateError.invalidInput) {
            try MarketStateEngine.calculate(copy(base,asOf:base.asOf.addingTimeInterval(86400*365),series:[]))
        }
    }
    @Test func newYorkSessionAllowsEveningAcrossUTCMidnightAndIntradayPreview() throws {
        let base=try fixture(count:1,series:[])
        let evening=try MarketStateEngine.calculate(copy(base,asOf:base.asOf.addingTimeInterval(4*3600),series:[]))
        #expect(evening.current.isClosedSession)
        let preview=try MarketStateEngine.calculate(copy(base,asOf:base.asOf.addingTimeInterval(-4*3600),series:[]))
        #expect(!preview.current.isClosedSession && preview.current.confirmedLabel == .unreliable)
    }
    @Test func zeroDenominatorsBecomeMissingNotZeroPressure() throws {
        let base=try fixture(count:1,series:[])
        let a=try observation("vix",day:base.sessionDate,value:"20",release:base.asOf)
        let b=try observation("vix3m",day:base.sessionDate,value:"0",release:base.asOf)
        let report=try MarketStateEngine.calculate(copy(base,series:[series(.vix,[a]),series(.vix3m,[b])]))
        #expect(report.current.stress.components[1].atoms[0].missingReason == .invalidDenominator)
    }
    @Test func rollingMeanRequiresEverySessionAndPreservesMemberDigest() throws {
        let base=try fixture(count:20,series:[])
        let values=try base.sessions.enumerated().map { i,s in try observation("p\(i)",day:s.date,value:String(i+1),release:s.closeAt) }
        let input=copy(base,series:[series(.spyPrice,values)])
        let raw=MarketStateEngine.Reader(input).evaluate(.trend(.spyPrice,20),index:19,cutoff:input.asOf)
        #expect(abs(try #require(raw.value)-(20/10.5-1)) < 1e-12)
        #expect(raw.windows.first?.sessionCount == 20 && raw.windows.first?.memberIdentitySHA256.count == 64)
        let missing=copy(base,series:[series(.spyPrice,Array(values.dropFirst()))])
        #expect(MarketStateEngine.Reader(missing).evaluate(.trend(.spyPrice,20),index:19,cutoff:missing.asOf).reason == .insufficientWindow)
    }
    @Test func realizedVolatilityUsesSampleLogReturnsAndAnnualization() throws {
        let base=try fixture(count:6,series:[])
        let prices=[100,110,100,105,108,111]
        let values=try base.sessions.enumerated().map { i,s in try observation("p\(i)",day:s.date,value:String(prices[i]),release:s.closeAt) }
        let input=copy(base,series:[series(.spyPrice,values)])
        let returns=zip(prices.dropFirst(),prices).map { log(Double($0.0)/Double($0.1)) }
        let mean=returns.reduce(0,+)/5
        let expected=sqrt(returns.reduce(0) { $0+pow($1-mean,2) }/4)*sqrt(252)
        let actual=try #require(MarketStateEngine.Reader(input).evaluate(.realizedVolatility(5),index:5,cutoff:input.asOf).value)
        #expect(abs(actual-expected)<1e-12)
    }
    @Test func relativeMomentumCannotMixPriceAndTotalReturnBasis() throws {
        let base=try fixture(count:22,series:[])
        let values=try base.sessions.enumerated().map { i,s in try observation("p\(i)",day:s.date,value:String(100+i),release:s.closeAt) }
        let input=copy(base,series:[series(.rspTotalReturn,values,basis:"TR-A"),series(.spyTotalReturn,values,basis:"TR-B")])
        let raw=MarketStateEngine.Reader(input).evaluate(.relativeMomentum(.rspTotalReturn,.spyTotalReturn,21),index:21,cutoff:input.asOf)
        #expect(raw.reason == .incompatibleBasis && raw.value == nil)
    }
    @Test func mismatchedPopulationAndPCRCloningAreRejected() throws {
        let base=try fixture(count:1,series:[])
        let value=try observation("a",day:base.sessionDate,value:"0.5",release:base.asOf)
        #expect(throws:MarketStateError.invalidInput) {
            try MarketStateEngine.calculate(copy(base,series:[series(.advancingFraction,[value],population:"A"),series(.aboveMA50Fraction,[value],population:"B")]))
        }
        #expect(throws:MarketStateError.invalidInput) {
            try MarketStateEngine.calculate(copy(base,series:[series(.totalPutCall,[value],population:"same"),series(.indexPutCall,[value],population:"same")]))
        }
    }
    @Test func priceBasisMismatchRawMismatchAndDuplicateSeriesFailClosed() throws {
        let base=try fixture(count:1,series:[])
        let value=try observation("a",day:base.sessionDate,value:"10",release:base.asOf)
        #expect(throws:MarketStateError.invalidInput) { try MarketStateEngine.calculate(copy(base,series:[series(.spyPrice,[value],basis:"A"),series(.qqqPrice,[value],basis:"B")])) }
        let mismatched=MarketObservation(observationID:"x",vintageID:"x-v1",observationDate:base.sessionDate,releasedAt:base.asOf,availableAt:base.asOf,value:try Money("10"),rawValue:"11")
        #expect(throws:MarketStateError.invalidInput) { try MarketStateEngine.calculate(copy(base,series:[series(.vix,[mismatched])])) }
        #expect(throws:MarketStateError.invalidInput) { try MarketStateEngine.calculate(copy(base,series:[series(.vix,[value]),series(.vix,[value])])) }
    }
    @Test func duplicateObservationDatesOrAvailabilityTiesCannotBeSilentlySelected() throws {
        let base=try fixture(count:1,series:[])
        let a=try observation("a",day:base.sessionDate,value:"10",release:base.asOf)
        let b=try observation("b",day:base.sessionDate,value:"11",release:base.asOf)
        #expect(throws:MarketStateError.invalidInput) { try MarketStateEngine.calculate(copy(base,series:[series(.vix,[a,b])])) }
        let revision=MarketObservation(observationID:a.observationID,vintageID:"r2",observationDate:a.observationDate,releasedAt:a.releasedAt,availableAt:a.availableAt,value:try Money("11"),rawValue:"11")
        #expect(throws:MarketStateError.invalidInput) { try MarketStateEngine.calculate(copy(base,series:[series(.vix,[a,revision])])) }
    }
    @Test func commonValidDatesDriveCorrelationAndFrequencyDenominator() {
        var values=(0..<252).map { i in day(raw:.expansion,confirmed:.expansion,streak:2,heat:Double(i)/3,stress:Double(i)/3,sentiment:100-Double(i)/3) }
        values.append(day(raw:.unreliable,confirmed:.unreliable,streak:0,heat:nil,stress:20,sentiment:20))
        let diagnostics=MarketStateEngine.diagnostics(values)
        #expect(diagnostics.commonValidDayCount == 252 && diagnostics.eligibleSessionCount == 253)
        #expect(diagnostics.coverage == 252.0/253.0)
        #expect(diagnostics.correlations.allSatisfy { $0.commonCount == 252 && $0.overlapWarning })
        #expect(diagnostics.frequencies.first { $0.label == .expansion }?.fraction == 1)
        #expect(diagnostics.frequencies.first { $0.label == .unreliable }?.count == 0)
    }
    @Test func correlationRequires252CommonDaysAndRejectsZeroVariance() {
        let short=(0..<251).map { i in day(raw:.expansion,confirmed:.expansion,streak:2,heat:Double(i)/3,stress:Double(i)/3,sentiment:Double(i)/3) }
        #expect(MarketStateEngine.diagnostics(short).correlations.allSatisfy { $0.coefficient == nil })
        #expect(MarketStateEngine.pearson([1,1,1],[2,3,4]) == nil)
        #expect(MarketStateEngine.pearson([1,2,3],[3,2,1]) == -1)
    }
    @Test func reportReplaysFromFrozenInputAndRejectsAlteredOutputOrModel() throws {
        let report=try MarketStateEngine.calculate(fixture(count:1,series:[]))
        let encoded=try JSONEncoder().encode(report)
        #expect(try MarketStateEngine.replay(JSONDecoder().decode(MarketStateReport.self,from:encoded)) == report)
        var object=try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        object["researchOnly"]=false
        let tampered=try JSONDecoder().decode(MarketStateReport.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(throws:MarketStateError.incompatibleReport) { try MarketStateEngine.replay(tampered) }
    }
    @Test func syntheticFullRecipeHasThreeScoresAndHonestWeeklyMissingness() throws {
        let input=try MarketStateDemo.input()
        let report=try MarketStateEngine.calculate(input)
        #expect(report.containsSynthetic && report.researchOnly)
        #expect(report.current.heat.value != nil && report.current.stress.value != nil && report.current.sentiment.value != nil)
        #expect(report.current.sentiment.effectiveWeightBps == 7000)
        #expect(report.current.sentiment.droppedComponents.map(\.id) == ["sentiment.exposure","sentiment.positioning"])
        #expect(report.diagnostics.commonValidDayCount >= 252)
        #expect(try JSONEncoder().encode(input).count < 10*1024*1024)
        #expect(try MarketStateEngine.replay(report) == report)
    }

    private func fixture(count:Int,series:[MarketSeries],start:String="2025-01-02") throws -> MarketStateInput {
        var date=try #require(MarketStateEngine.parseDay(start));var sessions:[MarketTradingSession]=[]
        while sessions.count<count {
            let weekday=MarketStateEngine.utcCalendar.component(.weekday,from:date)
            if weekday != 1 && weekday != 7 { sessions.append(.init(date:MarketStateEngine.dayText(date),closeAt:date.addingTimeInterval(21*3600))) }
            date=date.addingTimeInterval(86400)
        }
        let last=try #require(sessions.last)
        return .init(createdAt:max(last.closeAt,Date(timeIntervalSince1970:1792368000)),asOf:last.closeAt,sessionDate:last.date,sessions:sessions,calendarEvidence:"synthetic weekday fixture",series:series)
    }
    private func observation(_ id:String,day:String,value:String,release:Date) throws -> MarketObservation {
        .init(observationID:id,vintageID:id+"-v1",observationDate:day,releasedAt:release,availableAt:release,value:try Money(value),rawValue:value)
    }
    private func series(_ key:MarketSeriesKey,_ observations:[MarketObservation],frequency:MarketFrequency = .daily,population:String?=nil,basis:String="basis-v1") -> MarketSeries {
        .init(key:key,unit:key.unit,frequency:frequency,origin:.synthetic,sourceID:"synthetic-source",feedID:"synthetic-feed",methodology:"synthetic",population:population,basisVersion:basis,observations:observations)
    }
    private func copy(_ input:MarketStateInput,asOf:Date?=nil,series:[MarketSeries]) -> MarketStateInput {
        .init(id:input.id,createdAt:max(input.createdAt,asOf ?? input.asOf),asOf:asOf ?? input.asOf,sessionDate:input.sessionDate,sessions:input.sessions,calendarEvidence:input.calendarEvidence,series:series)
    }
    private func atomResult(_ id:String,score:Double?) -> MarketAtomResult {
        .init(id:id,rawValue:score,score:score,independentHistoryCount:252,observationReferences:[],consumedWindows:[],missingReason:score == nil ? .missingSeries:nil)
    }
    private func allAtoms(score:Double) -> [String:MarketAtomResult] {
        Dictionary(uniqueKeysWithValues:MarketStateEngine.components.flatMap(\.atoms).map { ($0.id,atomResult($0.id,score:score)) })
    }
    private func day(raw:MarketRegimeLabel,confirmed:MarketRegimeLabel,streak:Int,heat:Double?=80,stress:Double?=20,sentiment:Double?=60) -> MarketStateDay {
        .init(sessionDate:"2026-10-19",asOf:Date(timeIntervalSince1970:1_792_440_000),
            heat:.init(kind:.heat,value:heat,effectiveWeightBps:heat == nil ? 0:10000,components:[]),
            stress:.init(kind:.stress,value:stress,effectiveWeightBps:stress == nil ? 0:10000,components:[]),
            sentiment:.init(kind:.sentiment,value:sentiment,effectiveWeightBps:sentiment == nil ? 0:10000,components:[]),
            rawLabel:raw,confirmedLabel:confirmed,confirmationStreak:streak,isClosedSession:true)
    }
}
