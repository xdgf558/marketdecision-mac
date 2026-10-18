import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import OptionsAnalytics

@Suite struct OptionLabRiskTests {
    @Test func sixComponentsKeepOriginalCoverageAndIndependentWeightedScore() throws {
        let input = try riskBase(), assumptions = try OptionLabRiskDemo.input(for: input)
        let result = try riskCalculate(input, assumptions)
        // 18.18% spread ->30 *30%; remaining five ->100 *70% =79.
        #expect(result.liquidity.score == (try Money("79")))
        #expect(result.liquidity.grade == .acceptable)
        #expect(result.liquidity.legs[0].coverageBasisPoints == 10000)
        #expect(result.liquidity.legs[0].components.count == 6)
        #expect(result.liquidity.researchOnly && !result.liquidity.mayRankLive)
    }
    @Test(arguments: ["absent","oldOI","notLatest","intradayUnverified","oneNeighbor","undeclaredNeighbors"])
    func missingEvidenceDoesNotBecomeZeroOrRenormalize(_ kind: String) throws {
        let input = try riskBase(), demo = try OptionLabRiskDemo.input(for: input), base = demo.liquidity[0]
        let e = OptionLabLiquidityInput(contractID: base.contractID, openInterest: kind == "absent" ? nil : 1500,
            oiSessionsAgo: kind == "oldOI" ? 3 : 2, oiIsLatestPublished: kind != "notLatest", volume: 200,
            volumeBasis: kind == "intradayUnverified" ? .unverified : .fullSession,
            neighbors: kind == "oneNeighbor" ? [base.neighbors[0]] : base.neighbors,
            neighborsComplete: kind != "undeclaredNeighbors")
        let result = try riskCalculate(input, .init(source: demo.source, liquidity: [e])).liquidity
        #expect(result.grade == .dataInsufficient && result.score == nil)
        #expect(result.legs[0].coverageBasisPoints < 10000)
    }
    @Test(arguments: ["0","9","10","99","100","999","1000"])
    func openInterestThresholdsIncludeBoundaries(_ raw: String) throws {
        let value = try #require(Int(raw)), input = try riskBase(), demo = try OptionLabRiskDemo.input(for: input)
        let e = riskEvidence(demo.liquidity[0], oi: value)
        let component = try #require(riskCalculate(input, .init(source: demo.source, liquidity: [e])).liquidity.legs[0].components.first { $0.factor == .openInterest })
        let expected = value >= 1000 ? 100 : value >= 100 ? 70 : value >= 10 ? 30 : 0
        #expect(component.score == expected)
    }
    @Test(arguments: ["15","15.001","30","30.001","60","60.001"])
    func quoteAgeUsesSourceTimeAndHardAvoidOverridesMissing(_ raw: String) throws {
        let seconds = try #require(Double(raw)), base = try riskBase()
        let input = riskCopy(base, short: riskLeg(base.shortLeg, quoteAt: base.asOf.addingTimeInterval(-seconds)))
        let r = try riskCalculate(input, .init(source: base.shortLeg.source)).liquidity
        let age = try #require(r.legs[0].components.first { $0.factor == .quoteAge })
        #expect(age.score == (seconds <= 15 ? 100 : seconds <= 30 ? 70 : seconds <= 60 ? 30 : 0))
        #expect(r.grade == (seconds > 60 ? .avoid : .dataInsufficient))
    }
    @Test func hardInsufficientSizeCannotBeHiddenByGoodScoreOrMissingOI() throws {
        let base = try riskBase(), input = riskCopy(base, short: riskLeg(base.shortLeg, size: 2, quantity: 3))
        let result = try riskCalculate(input, .init(source: base.shortLeg.source)).liquidity
        #expect(result.grade == .avoid && result.score == nil)
        #expect(result.legs[0].hardDowngrades.contains { $0.contains("张数") })
    }
    @Test func crossedMarketIsAvoidRatherThanNegativeSpreadExcellent() throws {
        let base = try riskBase(), input = riskCopy(base, short: riskLeg(base.shortLeg, bid: try Money("3"), ask: try Money("2")))
        let result = try riskCalculate(input, .init(source: base.shortLeg.source)).liquidity
        #expect(result.grade == .avoid)
        #expect(result.legs[0].components[0].grade == .avoid)
    }
    @Test func spreadUsesExactBoundaryComparisonBeforeRatioRounding() throws {
        let base = try riskBase()
        // spread/Mid is infinitesimally greater than .05; rounded ratio may equal .05.
        let input = riskCopy(base, short: riskLeg(base.shortLeg, bid: try Money("39"), ask: try Money("41.00000000000000000001")))
        let grade = try riskCalculate(input, .init(source: base.shortLeg.source)).liquidity.legs[0].components[0].grade
        #expect(grade == .acceptable)
    }
    @Test func worstLegAndLowestScoreAreKeptWithoutAveraging() throws {
        let input = try riskBase(strategy: .putCreditSpread), demo = try OptionLabRiskDemo.input(for: input)
        let second = riskEvidence(demo.liquidity[1], oi: 0)
        let result = try riskCalculate(input, .init(source: demo.source, liquidity: [demo.liquidity[0],second])).liquidity
        #expect(result.grade == .avoid)
        #expect(result.score == result.legs.compactMap(\.score).min())
        #expect(result.legs[0].grade == .acceptable && result.legs[1].grade == .avoid)
    }
    @Test func continuityRequiresTwoSidesAndUsesNearestValidStrikes() throws {
        let input = try riskBase(), demo = try OptionLabRiskDemo.input(for: input), e = demo.liquidity[0]
        // Put: lower strike may not exceed current Mid by more than one tick.
        let lower = riskLeg(e.neighbors[0], bid: try Money("3"), ask: try Money("3"))
        let modified = OptionLabLiquidityInput(contractID:e.contractID,openInterest:1500,oiSessionsAgo:1,oiIsLatestPublished:true,
            volume:200,volumeBasis:.sameElapsedTime,neighbors:[lower,e.neighbors[1]],neighborsComplete:true)
        let r = try riskCalculate(input,.init(source:demo.source,liquidity:[modified])).liquidity.legs[0]
        #expect(r.components.last?.value == (try Money("0.5")))
        #expect(r.components.last?.grade == .weak)
    }
    @Test func wrongNeighborIdentityAndDuplicateRiskLegAreRejected() throws {
        let input = try riskBase(), demo = try OptionLabRiskDemo.input(for:input), e = demo.liquidity[0]
        let wrong = riskLeg(e.neighbors[0], symbol:"OTHER")
        let bad = OptionLabLiquidityInput(contractID:e.contractID,neighbors:[wrong,e.neighbors[1]],neighborsComplete:true)
        #expect(throws: OptionLabRiskError.invalidNeighbor) { try riskCalculate(input,.init(source:demo.source,liquidity:[bad])) }
        #expect(throws: OptionLabRiskError.invalidInput) { try riskCalculate(input,.init(source:demo.source,liquidity:[e,e])) }
    }
    @Test func futureNeighborIsUnavailableNotAQualifiedPair() throws {
        let input = try riskBase(), demo = try OptionLabRiskDemo.input(for:input), e = demo.liquidity[0]
        let future = riskLeg(e.neighbors[0], quoteAt:input.asOf.addingTimeInterval(1),receivedAt:input.asOf.addingTimeInterval(1))
        let modified = OptionLabLiquidityInput(contractID:e.contractID,neighbors:[future,e.neighbors[1]],neighborsComplete:true)
        #expect(try riskCalculate(input,.init(source:demo.source,liquidity:[modified])).liquidity.legs[0].components.last?.grade == .dataInsufficient)
    }
    @Test(arguments:["beforeMarket","duringMarket","afterMarket"])
    func eventWindowsUseDeclaredHolidayAndEarlyCloseCalendar(_ raw:String) throws {
        let timing = try #require(CorporateEventTiming(rawValue:raw)), input=try riskBase()
        let event=try riskEarnings(input,timing:timing)
        let r=try riskCalculate(input,.init(source:input.shortLeg.source,earnings:event)).earnings
        let before=riskDate("2026-10-15T20:00:00Z"), current=riskDate("2026-10-16T20:00:00Z"), after=riskDate("2026-10-19T17:00:00Z")
        #expect(r.windowStart == (timing == .afterMarket ? current : before))
        #expect(r.windowEnd == (timing == .afterMarket ? after : current))
        #expect(r.holdingOverlaps == true && r.historicalFrequency == nil && r.historicalEventCount == 0)
    }
    @Test func missingUnknownOrEstimatedEventDoesNotMeanNoRisk() throws {
        let input=try riskBase()
        for event in [nil,try riskEarnings(input,timing:.unknown),try riskEarnings(input,timing:.beforeMarket,certainty:.estimated)] {
            let r=try riskCalculate(input,.init(source:input.shortLeg.source,earnings:event)).earnings
            #expect(r.state == .dataInsufficient && r.holdingOverlaps == nil && r.expectedMove == nil)
        }
    }
    @Test func incompleteCalendarAndFutureEventVersionAreRejected() throws {
        let input=try riskBase(), c=try riskCalendar(input)
        let missing=OptionLabRiskCalendar(version:c.version,source:c.source,from:c.from,through:c.through,sessions:Array(c.sessions.dropLast()))
        #expect(throws: OptionLabRiskError.invalidCalendar) { try riskCalculate(input,.init(source:input.shortLeg.source,earnings:riskEarnings(input,timing:.beforeMarket,calendar:missing))) }
        #expect(throws: OptionLabRiskError.invalidEvent) { try riskCalculate(input,.init(source:input.shortLeg.source,earnings:riskEarnings(input,timing:.beforeMarket,announcedAt:input.asOf.addingTimeInterval(1)))) }
    }
    @Test func expectedMoveSelectsEarliestExpiryAfterBMOAndThenATM() throws {
        let input=try riskBase()
        // The event is BMO. A noon expiry remains valid after the opening upper bound,
        // even though it is before the event-return window's closing endpoint.
        let near=riskDate("2026-10-16T16:00:00Z"), far=riskDate("2026-10-23T20:00:00Z")
        let quotes=try [riskStraddle(input,strike:"90",at:near,call:"8",put:"1"),riskStraddle(input,strike:"100",at:near,call:"3",put:"2"),riskStraddle(input,strike:"100",at:far,call:"9",put:"9")]
        let r=try riskCalculate(input,.init(source:input.shortLeg.source,earnings:riskEarnings(input,timing:.beforeMarket,straddles:quotes))).earnings
        #expect(r.selectedStraddle?.settlementAt == near)
        #expect(r.selectedStraddle?.strike == (try Money("100")))
        #expect(r.expectedMove == (try Money("5")))
        #expect(r.expectedMoveFraction == (try Money("0.05")))
    }
    @Test func amcSameDayCloseExpiryCannotCoverTheEvent() throws {
        let input=try riskBase()
        let same=riskDate("2026-10-16T20:00:00Z"), next=riskDate("2026-10-19T16:00:00Z")
        let quotes=try [riskStraddle(input,strike:"100",at:same,call:"1",put:"1"),riskStraddle(input,strike:"100",at:next,call:"3",put:"3")]
        let r=try riskCalculate(input,.init(source:input.shortLeg.source,earnings:riskEarnings(input,timing:.afterMarket,straddles:quotes))).earnings
        #expect(r.selectedStraddle?.settlementAt == next)
        #expect(r.expectedMove == (try Money("6")))
    }
    @Test func atmGeometricTieSelectsLowerStrike() throws {
        let input=try riskBase(), expiry=riskDate("2026-10-16T16:00:00Z")
        let quotes=try [riskStraddle(input,strike:"125",at:expiry,call:"3",put:"2"),riskStraddle(input,strike:"80",at:expiry,call:"1",put:"1")]
        let r=try riskCalculate(input,.init(source:input.shortLeg.source,earnings:riskEarnings(input,timing:.beforeMarket,straddles:quotes))).earnings
        #expect(r.selectedStraddle?.strike == (try Money("80")))
    }
    @Test func noExplicitChainCoverageMeansNoExpectedMove() throws {
        let input=try riskBase(), q=try riskStraddle(input,strike:"100",at:riskDate("2026-10-16T16:00:00Z"),call:"3",put:"2")
        let event=try riskEarnings(input,timing:.beforeMarket,straddles:[q],coverage:false)
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source,earnings:event)).earnings.expectedMove == nil)
    }
    @Test func putUsesExactPricingTimeNotDTEAndNegativeRateFloorsAtZero() throws {
        let base=try riskBase(rate:"0.05"), input=riskCopy(base,short:riskLeg(base.shortLeg,bid:try Money("0.01"),ask:try Money("0.01")))
        let positive=try riskCalculate(input,.init(source:input.shortLeg.source)).assignment
        let expected=100 * 0.05 * input.expiry.settlementAt.timeIntervalSince(input.asOf)/31_536_000
        #expect(positive.level == .elevated && positive.threshold == expected)
        let negative=try riskBase(rate:"-0.01")
        let r=try riskCalculate(negative,.init(source:negative.shortLeg.source)).assignment
        #expect(r.threshold == 0 && r.level == .noTrigger)
    }
    @Test func callRequiresKnownDividendAndPriorSessionBeforeComparingPV() throws {
        let base=try riskBase(strategy:.coveredCall,rate:"0"), input=riskCopy(base,short:riskLeg(base.shortLeg,bid:try Money("0.8"),ask:try Money("0.8")))
        let event=try OptionLabDividendInput(eventVersion:"div.v1",source:input.shortLeg.source,announcedAt:input.asOf,
            exDate:.init(year:2026,month:10,day:16),paymentAt:riskDate("2026-10-30T16:00:00Z"),amountPerShare:Money("1"),certainty:.confirmed,calendar:riskCalendar(input))
        let r=try riskCalculate(input,.init(source:input.shortLeg.source,dividend:event)).assignment
        #expect(r.level == .high && r.threshold == 0.9 && r.dividendPresentValue == 1)
        #expect(r.priorExDividendSession == MarketDate(year:2026,month:10,day:15))
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source)).assignment.level == .dataInsufficient)
    }
    @Test func equalityDoesNotTriggerStrictCallThresholdAndContinuousQIsNotEvidence() throws {
        let base=try riskBase(strategy:.coveredCall,rate:"0"), input=riskCopy(base,short:riskLeg(base.shortLeg,bid:try Money("0.9"),ask:try Money("0.9")))
        let dividend=try OptionLabDividendInput(eventVersion:"div.v1",source:input.shortLeg.source,announcedAt:input.asOf,
            exDate:.init(year:2026,month:10,day:16),paymentAt:riskDate("2026-10-30T16:00:00Z"),amountPerShare:Money("1"),certainty:.confirmed,calendar:riskCalendar(input))
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source,dividend:dividend)).assignment.level == .noTrigger)
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source)).assignment.level == .dataInsufficient)
    }
    @Test func europeanContractIsExplicitlyNotApplicableAndNegativeExtrinsicRemainsSigned() throws {
        let base=try riskBase(rate:"0.05"), european=riskCopy(base,short:riskLeg(base.shortLeg,strike:try Money("110"),style:.european))
        let r=try riskCalculate(european,.init(source:base.shortLeg.source)).assignment
        #expect(r.level == .notApplicable && r.extrinsicValue.amount < 0 && r.deepInTheMoney)
    }
    @Test func staleNearestNeighborCannotBeReplacedWithDistantGoodQuote() throws {
        let input=try riskBase(),demo=try OptionLabRiskDemo.input(for:input),e=demo.liquidity[0]
        let far=e.neighbors[0]
        let near=OptionLabLeg(contractID:"NEAREST-STALE",symbol:far.symbol,right:far.right,strike:try Money("99"),
            quantity:1,expirationDate:far.expirationDate,bid:try Money("1"),ask:try Money("1"),bidSize:10,askSize:10,
            tick:try Money("0.01"),quotedAt:input.asOf.addingTimeInterval(-61),receivedAt:input.asOf,source:far.source)
        let evidence=OptionLabLiquidityInput(contractID:e.contractID,neighbors:[far,near,e.neighbors[1]],neighborsComplete:true)
        #expect(try riskCalculate(input,.init(source:demo.source,liquidity:[evidence])).liquidity.legs[0].components.last?.grade == .dataInsufficient)
    }
    @Test func nearestATMWithStaleQuoteDoesNotFallBackToRemoteExpiry() throws {
        let input=try riskBase(),near=riskDate("2026-10-16T16:00:00Z"),far=riskDate("2026-10-23T20:00:00Z")
        let stale=try OptionLabStraddleQuote(strike:Money("100"),settlementAt:near,callBid:Money("1"),callAsk:Money("1"),
            putBid:Money("1"),putAsk:Money("1"),quotedAt:input.asOf.addingTimeInterval(-61),source:input.shortLeg.source)
        let other=try riskStraddle(input,strike:"100",at:far,call:"2",put:"2")
        let event=try riskEarnings(input,timing:.beforeMarket,straddles:[stale,other])
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source,earnings:event)).earnings.expectedMove == nil)
    }
    @Test func expiryBeforeExDividendOpenDoesNotTriggerCallRisk() throws {
        let base=try riskBase(strategy:.coveredCall,rate:"0")
        let expiry=OptionLabExpiry(date:.init(year:2026,month:10,day:16),settlementAt:riskDate("2026-10-16T12:00:00Z"),source:base.expiry.source)
        let input=OptionLabInput(id:base.id,createdAt:base.createdAt,asOf:base.asOf,strategy:base.strategy,
            shortLeg:base.shortLeg,longLeg:nil,underlying:base.underlying,capital:base.capital,policy:base.policy,
            expiry:expiry,scenarioPrices:base.scenarioPrices,pricing:base.pricing)
        let dividend=try OptionLabDividendInput(eventVersion:"div.v1",source:input.shortLeg.source,announcedAt:input.asOf,
            exDate:.init(year:2026,month:10,day:16),paymentAt:riskDate("2026-10-30T16:00:00Z"),amountPerShare:Money("10"),certainty:.confirmed,calendar:riskCalendar(input))
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source,dividend:dividend)).assignment.level == .notApplicable)
    }
    @Test(arguments:["7","8","60","61"])
    func nearExpiryAndLongDTEThresholdsKeepTheirExactBoundaries(_ raw:String)throws {
        let dte=try #require(Int(raw)),input=try riskBase(rate:"0.049999")
        let r=try OptionLabRiskEngine.calculate(input:input,assumptions:.init(source:input.shortLeg.source),pricing:nil,underlyingMid:Money("100"),dte:dte).assignment
        #expect(r.nearExpiry == (dte <= 7))
        #expect(r.europeanApproximationLimited == (dte > 60))
    }
    @Test func deepITMAndHighRateAreInclusiveBoundaries()throws {
        let base=try riskBase(rate:"0.05")
        let deep=riskCopy(base,short:riskLeg(base.shortLeg,strike:try Money("110")))
        #expect(try riskCalculate(deep,.init(source:deep.shortLeg.source)).assignment.deepInTheMoney)
        #expect(try riskCalculate(base,.init(source:base.shortLeg.source)).assignment.europeanApproximationLimited)
        let justBelow=riskCopy(base,short:riskLeg(base.shortLeg,strike:try Money("109.999999")))
        #expect(try !riskCalculate(justBelow,.init(source:justBelow.shortLeg.source)).assignment.deepInTheMoney)
    }
    @Test func apparentlyFreshStraddleWithUnderlyingSkewIsNotExpectedMove()throws {
        let input=try riskBase()
        let quote=try OptionLabStraddleQuote(strike:Money("100"),settlementAt:riskDate("2026-10-16T16:00:00Z"),
            callBid:Money("1"),callAsk:Money("1"),putBid:Money("1"),putAsk:Money("1"),
            quotedAt:input.asOf.addingTimeInterval(-6),source:input.shortLeg.source)
        let event=try riskEarnings(input,timing:.beforeMarket,straddles:[quote])
        #expect(try riskCalculate(input,.init(source:input.shortLeg.source,earnings:event)).earnings.expectedMove == nil)
    }
    @Test func nestedSyntheticSourcesCannotBeRelabeledByManualTopLevelSource() throws {
        let input=try riskBase(), demo=try OptionLabRiskDemo.input(for:input)
        let manual=OptionLabSource(origin:.manual,reference:"manual wrapper",enteredAt:input.createdAt)
        let copied=OptionLabRiskInput(source:manual,liquidity:demo.liquidity,earnings:demo.earnings,dividend:demo.dividend)
        #expect(copied.containsSyntheticInput)
        let restored=try JSONDecoder().decode(OptionLabRiskInput.self,from:JSONEncoder().encode(copied))
        #expect(restored == copied && restored.containsSyntheticInput)
        let r=try riskCalculate(input,restored)
        #expect(r.model.defaultParameters == r.parameterReference)
    }
}

private func riskDate(_ s:String)->Date { ISO8601DateFormatter().date(from:s)! }
private func riskBase(strategy:OptionLabStrategy = .cashSecuredPut,rate:String? = nil)throws->OptionLabInput {
    let b=try OptionLabDemo.input(strategy:strategy,at:riskDate("2026-10-15T19:00:00Z"))
    let pricing=try rate.map { try OptionLabPricingInput(rate:Money($0),dividendYield:Money("0.01"),volatility:Money("0.2"),source:b.shortLeg.source) }
    return .init(id:b.id,createdAt:b.createdAt,asOf:b.asOf,strategy:b.strategy,shortLeg:b.shortLeg,longLeg:b.longLeg,
        underlying:b.underlying,capital:b.capital,policy:b.policy,expiry:b.expiry,scenarioPrices:b.scenarioPrices,pricing:pricing)
}
private func riskCopy(_ b:OptionLabInput,short:OptionLabLeg)->OptionLabInput {
    .init(id:b.id,createdAt:b.createdAt,asOf:b.asOf,strategy:b.strategy,shortLeg:short,longLeg:b.longLeg,
        underlying:b.underlying,capital:b.capital,policy:b.policy,expiry:b.expiry,scenarioPrices:b.scenarioPrices,pricing:b.pricing)
}
private func riskLeg(_ b:OptionLabLeg,bid:Money?=nil,ask:Money?=nil,size:Int?=nil,quantity:Int?=nil,
                     quoteAt:Date?=nil,receivedAt:Date?=nil,symbol:String?=nil,strike:Money?=nil,style:OptionLabExerciseStyle?=nil)->OptionLabLeg {
    .init(contractID:b.contractID,symbol:symbol ?? b.symbol,right:b.right,strike:strike ?? b.strike,multiplier:b.multiplier,
        exerciseStyle:style ?? b.exerciseStyle,delivery:b.delivery,specificationVersion:b.specificationVersion,
        quantity:quantity ?? b.quantity,expirationDate:b.expirationDate,bid:bid ?? b.bid,ask:ask ?? b.ask,
        bidSize:size ?? b.bidSize,askSize:size ?? b.askSize,tick:b.tick,quotedAt:quoteAt ?? b.quotedAt,
        receivedAt:receivedAt ?? b.receivedAt,source:b.source)
}
private func riskEvidence(_ b:OptionLabLiquidityInput,oi:Int)->OptionLabLiquidityInput {
    .init(contractID:b.contractID,openInterest:oi,oiSessionsAgo:1,oiIsLatestPublished:true,volume:200,volumeBasis:.fullSession,
        neighbors:b.neighbors,neighborsComplete:true)
}
private func riskCalculate(_ input:OptionLabInput,_ risk:OptionLabRiskInput)throws->OptionLabRiskReport {
    try OptionLabRiskEngine.calculate(input:input,assumptions:risk,pricing:nil,underlyingMid:Money("100"),dte:30)
}
private func riskCalendar(_ input:OptionLabInput)throws->OptionLabRiskCalendar {
    let dates=(14...20).map { MarketDate(year:2026,month:10,day:$0) }
    let sessions=dates.map { date->OptionLabRiskSession in
        if [17,18].contains(date.day) { return .init(date:date,state:.closed) }
        let prefix="2026-10-\(date.day)T"
        return .init(date:date,state:date.day == 19 ? .earlyClose:.regular,
            opensAt:riskDate(prefix+"13:30:00Z"),closesAt:riskDate(prefix+(date.day == 19 ? "17:00:00Z":"20:00:00Z")))
    }
    return .init(version:"SYNTHETIC-CAL.v1",source:input.shortLeg.source,from:dates[0],through:dates[6],sessions:sessions)
}
private func riskEarnings(_ input:OptionLabInput,timing:CorporateEventTiming,certainty:CorporateEventCertainty = .confirmed,
                          calendar:OptionLabRiskCalendar?=nil,announcedAt:Date?=nil,
                          straddles:[OptionLabStraddleQuote]=[],coverage:Bool=true)throws->OptionLabEarningsInput {
    try .init(eventVersion:"SYNTHETIC-EVENT.v1",source:input.shortLeg.source,announcedAt:announcedAt ?? input.asOf,
        eventDate:.init(year:2026,month:10,day:16),timing:timing,certainty:certainty,calendar:calendar ?? riskCalendar(input),
        allowsHoldingAcrossEvent:false,straddles:straddles,straddleCoverageComplete:coverage)
}
private func riskStraddle(_ input:OptionLabInput,strike:String,at:Date,call:String,put:String)throws->OptionLabStraddleQuote {
    try .init(strike:Money(strike),settlementAt:at,callBid:Money(call),callAsk:Money(call),putBid:Money(put),putAsk:Money(put),quotedAt:input.asOf,source:input.shortLeg.source)
}
