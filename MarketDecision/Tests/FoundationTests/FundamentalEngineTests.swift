import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

private let execution = Date(timeIntervalSince1970: 1_800_000_000)
private func day(_ text:String) throws -> MarketDate { try .init(iso8601:text) }
private func money(_ text:String) throws -> Money { try .init(text) }
private func near(_ actual:Money?,_ expected:String) throws {
    let a = try #require(actual), e = try money(expected)
    let delta = try a.subtracting(e)
    #expect(delta.amount.magnitude <= Decimal(string:"0.000000000001")!)
}
private func provenance(_ id:String,day:MarketDate,at:Date,endpoint:EndpointDescriptor = .bars,
                        feed:String = "synthetic-close",known:Bool = true) -> Provenance {
    .init(providerID:"fixture",feedID:feed,sourceEventAt:at,receivedAt:at,availableAt:nil,evidenceRef:"synthetic/"+id,origin:.provider,
          endpointDescriptor:endpoint.rawValue,requestedAt:at,requestID:UUID(),observationDate:day,versionID:id,versionKind:.sourceVersion,
          availability:known ? .instant(at,evidence:"synthetic-timestamp") : .unknown,
          rawObjectRef:"fixture/"+id,rawHash:String(repeating:"a",count:64),normalizationVersion:"fixture.v1",licenseRef:"synthetic")
}
private struct Fixture {
    var values:[NormalizedFinancialFact] = []
    var quarters:[FiscalQuarter] = []
    var years:[FiscalYearWindow] = []
    var classes:[EquityClassInput] = []
    var classIDs:Set<String> = ["A"]
    var date:MarketDate
    var cutoff:Date
    var company = "SYNTHETIC-A"
    var financial = false
    var splitEvidence:String? = "synthetic-no-split"
    init(price:String = "10",date:String = "2024-02-01",feed:String = "synthetic-close") throws {
        self.date = try day(date)
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"America/New_York")!
        cutoff = calendar.date(bySettingHour:16,minute:0,second:0,of:try self.date.start(in:calendar.timeZone))!
        // Independent, deliberately simple financial oracle: four identical current quarters.
        for year in [2022,2023] {
            for pair in [("01-01","03-31"),("04-01","06-30"),("07-01","09-30"),("10-01","12-31")] {
                quarters.append(try FiscalQuarter(start:day("\(year)-"+pair.0),end:day("\(year)-"+pair.1)))
            }
        }
        for q in quarters {
            let previous = q.end.year == 2022
            let fields:[FundamentalField:String] = [.revenue:previous ? "80":"100",.grossProfit:"40",.operatingIncome:previous ? "16":"20",
                .netIncome:"10",.commonIncome:"8",.ocf:previous ? "12":"15",.capex:previous ? "4":"5",.sbc:"2",.depreciation:"3",.interest:"2",
                .buybacks:"4",.issuance:"1",.dividends:"2",.dilutedEPS:previous ? "0.8":"1"]
            for (field,value) in fields { values.append(try fact(field,value,start:q.start,end:q.end,type:.quarter)) }
        }
        for end in [try day("2021-12-31")] + quarters.map(\.end) {
            let fields:[FundamentalField:String] = [.assets:"500",.currentAssets:"200",.currentLiabilities:"100",.commonEquity:"180",.totalEquity:"200",
                .preferred:"10",.nci:"10",.cash:"50",.shortDebt:"10",.currentDebt:"10",.longDebt:"50",.financeLease:"20",.operatingLease:"10",
                .actualShares:end.year < 2023 ? "110":"100",.leaseRate:"0.05"]
            for (field,value) in fields { values.append(try fact(field,value,start:nil,end:end,type:.instant)) }
        }
        for year in [2021,2022,2023] {
            let y = try FiscalYearWindow(start:day("\(year)-01-01"),end:day("\(year)-12-31")); years.append(y)
            for (field,value) in [(FundamentalField.pretaxIncome,"100"),(.tax,"20")] { values.append(try fact(field,value,start:y.start,end:y.end,type:.annual)) }
        }
        let p = provenance("price-"+date,day:self.date,at:cutoff,feed:feed)
        classes = [.init(classID:"A",price:try money(price),shares:try money("100"),priceProvenance:p,shareProvenance:p,shareBasisEvidence:"actual-outstanding-same-basis")]
    }
    func fact(_ field:FundamentalField,_ value:String,start:MarketDate?,end:MarketDate,type:FinancialPeriodType) throws -> NormalizedFinancialFact {
        let id = field.rawValue+"/"+end.iso8601+"/"+type.rawValue
        return .init(id:id,cik:company,fieldID:field.rawValue,statement:.other,
            nature:type == .instant ? .instant : field == .dilutedEPS ? .perShare : .additiveFlow,
            periodType:type,periodStart:start,periodEnd:end,fiscalYear:end.year,fiscalPeriod:nil,unit:field.unit,value:try money(value),sourceValue:value,
            derivation:.reported,sourceFactIDs:[id],sourceVersions:[id+"-v1"],accessionNumbers:["synthetic"],dictionaryVersion:"synthetic.semantic.v1",
            availableAt:try day("2024-01-15").start(in:TimeZone(secondsFromGMT:0)!),confidence:.high,limitations:[])
    }
    mutating func remove(_ field:FundamentalField) { values.removeAll {$0.fieldID == field.rawValue} }
    mutating func replace(_ field:FundamentalField,_ value:String) throws {
        values = try values.map { f in
            if f.fieldID == field.rawValue { return try fact(field,value,start:f.periodStart,end:f.periodEnd,type:f.periodType) }
            return f
        }
    }
    func input() throws -> FundamentalInput {
        try .init(cik:company,normalization:.init(asOf:cutoff,dictionaryVersion:"synthetic.semantic.v1",values:values,issues:[],selectedSourceFacts:[],unmappedSourceFacts:[]),
            quarters:quarters,fiscalYears:years,priceDay:date,expectedClassIDs:classIDs,classes:classes,financialCompany:financial,splitBasisEvidence:splitEvidence)
    }
    func session() throws -> MarketSessionRecord {
        let open = cutoff.addingTimeInterval(-6.5*3600)
        return try .init(market:.nyse,date:date,state:.regular,opensAt:open,closesAt:cutoff,reason:"Synthetic session",
                         provenance:provenance("calendar-"+date.iso8601,day:date,at:open,endpoint:.marketCalendar))
    }
}
private func model() async throws -> ResolvedModel { try await FundamentalModelV1.resolve(in:ModelRegistry(),at:execution) }
private func report(_ fixture:Fixture) async throws -> FundamentalReport {
    try await FundamentalCalculator.calculate(fixture.input(),model:model(),executionDate:execution)
}

@Suite struct FundamentalRatioTests {
    @Test func exactCashFlowLeaseTaxAndCapitalizationOracle() async throws {
        let r = try await report(Fixture())
        for (key,value) in [("fcf","40"),("fcfExSBC","32"),("ebitda","92"),("marketCap","1000"),("enterpriseValue","1070"),
                            ("nopat","64.4"),("roic","0.2576"),("roa","0.08"),("currentRatio","2"),("shareholderYield","0.02"),
                            ("peMarketCap","31.25"),("peEPS","2.5"),("fcfYield","0.04"),("revenueYoY","0.25"),("fcfYoY","0.25")] {
            try near(r.metrics[key]?.value,value)
        }
        #expect(r.researchOnly)
        #expect(!r.normalizedInputs.isEmpty)
        let decoded = try JSONDecoder().decode(FundamentalReport.self,from:JSONEncoder().encode(r))
        #expect(decoded.metrics == r.metrics && decoded.model == r.model)
    }
    @Test func missingQuarterEndCannotBecomeEndpointAverage() async throws {
        var f=try Fixture()
        f.values.removeAll { $0.fieldID == FundamentalField.assets.rawValue && $0.periodEnd.iso8601 == "2023-06-30" }
        let r=try await report(f)
        #expect(r.metrics["roa"]?.value == nil)
        #expect(r.metrics["roe"]?.value != nil)
    }
    @Test func missingDebtSlotOrNciDoesNotBecomeZero() async throws {
        var f=try Fixture(); f.remove(.financeLease)
        let r=try await report(f)
        #expect(r.metrics["debt"]?.value == nil && r.metrics["enterpriseValue"]?.value == nil && r.metrics["roic"]?.value == nil)
        f=try Fixture(); f.remove(.nci)
        let n=try await report(f)
        #expect(n.metrics["enterpriseValue"]?.value == nil)
        #expect(n.metrics["marketCap"]?.value != nil)
    }
    @Test func noFallbackBetweenNetIncomeAndCommonIncome() async throws {
        var f=try Fixture(); f.remove(.commonIncome)
        let r=try await report(f)
        #expect(r.metrics["peMarketCap"]?.value == nil && r.metrics["roe"]?.value == nil)
        try near(r.metrics["netIncome"]?.value,"40")
    }
    @Test func negativeFcfRetainsYieldButSuppressesMultiple() async throws {
        var f=try Fixture(); try f.replace(.capex,"20")
        let r=try await report(f)
        try near(r.metrics["fcfYield"]?.value,"-0.02")
        #expect(r.metrics["priceFCF"]?.unavailable == .nonpositiveDenominator)
    }
    @Test func unknownTaxIsNotStatutoryFallback() async throws {
        var f=try Fixture(); f.remove(.tax)
        #expect(try await report(f).metrics["normalizedTax"]?.value == nil)
        try f.replace(.pretaxIncome,"-100")
        let r=try await report(f)
        try near(r.metrics["normalizedTax"]?.value,"0.21")
        #expect(r.metrics["normalizedTax"]?.flags.contains("TAX_RATE_STATUTORY") == true)
    }
    @Test func taxClampsAndLeaseFallbackAreExplicit() async throws {
        var f=try Fixture(); try f.replace(.tax,"80"); f.remove(.leaseRate)
        let r=try await report(f)
        try near(r.metrics["normalizedTax"]?.value,"0.35")
        try near(r.metrics["nopat"]?.value,"52.325")
        #expect(r.metrics["leaseRate"]?.flags == ["LEASE_RATE_NORMALIZED"])
    }
    @Test func financialIndustryAndNonpositiveCapitalAreUnavailable() async throws {
        var f=try Fixture(); f.financial=true
        let r=try await report(f)
        #expect(r.metrics["roic"]?.unavailable == .notApplicable && r.metrics["netDebtEBITDA"]?.unavailable == .notApplicable)
        f.financial=false; try f.replace(.cash,"400")
        #expect(try await report(f).metrics["roic"]?.value == nil)
    }
    @Test func multiclassUsesEveryActualClassOrWithholdsMarketCap() async throws {
        var f=try Fixture(); f.classIDs=["A","B"]
        #expect(try await report(f).metrics["marketCap"]?.value == nil)
        let a=f.classes[0]
        f.classes.append(.init(classID:"B",price:try money("20"),shares:try money("50"),priceProvenance:a.priceProvenance,shareProvenance:a.shareProvenance,shareBasisEvidence:"actual"))
        let r=try await report(f)
        try near(r.metrics["marketCap"]?.value,"2000")
        #expect(r.metrics["peEPS"]?.value == nil)
    }
    @Test func buybackAndIssuanceRemainSignedWithoutDoubleSbc() async throws {
        var f=try Fixture(); try f.replace(.issuance,"10")
        let r=try await report(f)
        try near(r.metrics["netBuybacks"]?.value,"-24")
        try near(r.metrics["shareholderYield"]?.value,"-0.016")
        try near(r.metrics["fcfExSBC"]?.value,"32")
    }
    @Test func zeroBaseGrowthAndMissingSplitEvidenceHaveNoPercentage() async throws {
        var f=try Fixture(); try f.replace(.revenue,"0"); f.splitEvidence=nil
        let r=try await report(f)
        #expect(r.metrics["revenueYoY"]?.value == nil)
        try near(r.metrics["revenueYoYChange"]?.value,"0")
        #expect(r.metrics["epsYoY"]?.value == nil && r.metrics["sharesYoY"]?.value == nil)
    }
    @Test func duplicateFactsAndDiscontinuousQuartersAreRejected() throws {
        var f=try Fixture(); f.values.append(f.values[0])
        #expect(throws:FundamentalError.duplicateInput) { try f.input() }
        f=try Fixture(); f.quarters.remove(at:4)
        #expect(throws:FundamentalError.invalidWindow) { try f.input() }
    }
    @Test func futureAvailabilityAndUnknownPriceEvidenceAreRejected() throws {
        var f=try Fixture(date:"2024-01-10")
        #expect(throws:FundamentalError.incompatibleInput) { try f.input() }
        f=try Fixture();let p=provenance("unknown",day:f.date,at:f.cutoff,known:false)
        f.classes=[.init(classID:"A",price:try money("10"),shares:try money("100"),priceProvenance:p,shareProvenance:p,shareBasisEvidence:"actual")]
        #expect(throws:FundamentalError.missingEvidence) { try f.input() }
    }
    @Test func syntheticCapitalizationScaleVectorsDoNotGrantCompanyAcceptance() async throws {
        for (index,price) in ["1","2","4","5","8","10","16","20","25","50"].enumerated() {
            let f=try Fixture(price:price)
            let r=try await report(f)
            try near(r.metrics["marketCap"]?.value,String([100,200,400,500,800,1000,1600,2000,2500,5000][index]))
        }
    }
}

@Suite struct FundamentalIntegrationTests {
    @Test func sourceNormalizationFeedsRatiosWithoutFutureRestatement() async throws {
        let helper=PhaseOneFinancialNormalizationTests(), dictionary=try FinancialFieldDictionary.fundamentalsV1()
        #expect(try FinancialFieldDictionary.foundationV1().rules.count == 10)
        #expect(dictionary.rules.count == 22)
        var facts:[SECCompanyFactRecord]=[], quarters:[FiscalQuarter]=[]
        let pairs=[("01-01","03-31"),("04-01","06-30"),("07-01","09-30"),("10-01","12-31")]
        for (index,pair) in pairs.enumerated() {
            quarters.append(try .init(start:day("2024-"+pair.0),end:day("2024-"+pair.1)))
            for (concept,value) in [("RevenueFromContractWithCustomerExcludingAssessedTax","100"),("OperatingIncomeLoss","20"),("NetIncomeLossAvailableToCommonStockholdersBasic","8")] {
                facts.append(try helper.fact(id:concept+String(index),value:value,start:"2024-"+pair.0,end:"2024-"+pair.1,filed:"2025-01-15",fp:"Q"+String(index+1),concept:concept))
            }
        }
        let old=try #require(facts.first {$0.concept == "OperatingIncomeLoss"})
        facts.append(try helper.fact(id:"amendment",value:"40",start:"2024-01-01",end:"2024-03-31",filed:"2025-03-01",fp:"Q1",concept:"OperatingIncomeLoss",factID:old.factID))
        let m=try await model()
        func calculate(_ date:String) throws -> FundamentalReport {
            let cutoff=try day(date).start(in:TimeZone(secondsFromGMT:0)!)
            let n=try FinancialNormalizer.normalizeComplete(facts,dictionary:dictionary,asOf:cutoff)
            let input=try FundamentalInput(cik:"0000320193",normalization:n,quarters:quarters,priceDay:day(date))
            return try FundamentalCalculator.calculate(input,model:m,executionDate:execution)
        }
        let before=try calculate("2025-02-01"),after=try calculate("2025-04-01")
        try near(before.metrics["operatingMargin"]?.value,"0.2")
        try near(after.metrics["operatingMargin"]?.value,"0.25")
        #expect(!before.sourceVersions.contains("v-amendment"))
        #expect(after.sourceVersions.contains("v-amendment"))
        #expect(before.metrics["enterpriseValue"]?.value == nil)
    }
    @Test func unrecognizedResolvedModelCannotUseThisCalculator() async throws {
        let registry=ModelRegistry(),(p,m)=try FundamentalModelV1.definitions()
        let foreign=ModelDefinition(id:"other",version:m.version,revisionID:UUID(),owner:m.owner,purpose:m.purpose,
            inputs:m.inputs,outputs:m.outputs,formula:m.formula,formulaVersion:m.formulaVersion,implementationReference:m.implementationReference,
            defaultParameters:p.reference,numericPolicyVersion:m.numericPolicyVersion,state:.approved,dispositionReference:m.dispositionReference,
            knownLimitations:m.knownLimitations,testFixtures:m.testFixtures,introducedAt:m.introducedAt)
        try await registry.register(p);try await registry.register(foreign)
        let resolved=try await registry.resolve(reference:foreign.reference,at:execution)
        #expect(throws:FundamentalError.unsupportedModel) { try FundamentalCalculator.calculate(Fixture().input(),model:resolved,executionDate:execution) }
    }
    @Test func wrongUnitsAndDoubleCountedDebtSourceAreRejected() throws {
        var f=try Fixture()
        func replaceJSON(_ source:NormalizedFinancialFact,_ edits:[String:Any]) throws -> NormalizedFinancialFact {
            var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any])
            for (key,value) in edits {json[key]=value}
            return try JSONDecoder().decode(NormalizedFinancialFact.self,from:JSONSerialization.data(withJSONObject:json))
        }
        f.values[0]=try replaceJSON(f.values[0],["unit":"EUR"])
        #expect(throws:FundamentalError.incompatibleInput) { try f.input() }
        f=try Fixture()
        let a=try #require(f.values.first {$0.fieldID == FundamentalField.shortDebt.rawValue})
        let b=try #require(f.values.firstIndex {$0.fieldID == FundamentalField.currentDebt.rawValue && $0.periodEnd == a.periodEnd})
        f.values[b]=try replaceJSON(f.values[b],["sourceFactIDs":a.sourceFactIDs])
        #expect(throws:FundamentalError.incompatibleInput) {try f.input()}
    }
}

@Suite struct FundamentalScoringTests {
    @Test func missingValuationKeepsSixDimensionsAndCoverageExplicit() async throws {
        let score=try await FundamentalScoring.calculate(Fixture().input(),model:model(),executionDate:execution)
        #expect(score.dimensions["valuation"]?.value == nil)
        #expect(score.coveredWeightOf84 == 72)
        #expect(score.total != nil && score.confidence == .medium)
        try near(score.dimensions["growth"]?.value,"93.333333333333333333")
        try near(score.dimensions["earningsStability"]?.value,"100")
    }
    @Test func twoOfThreeLeavesCannotMasqueradeAsSeventyPercent() async throws {
        var f=try Fixture(); f.remove(.interest)
        let score=try await FundamentalScoring.calculate(f.input(),model:model(),executionDate:execution)
        #expect(score.dimensions["balanceSheet"]?.value == nil)
        #expect(score.total != nil) // Exactly five dimensions, still sufficient original leaf weight.
        f.remove(.depreciation); f.remove(.commonIncome); f.remove(.actualShares)
        let missing=try await FundamentalScoring.calculate(f.input(),model:model(),executionDate:execution)
        #expect(missing.total == nil)
    }
    @Test func knownZeroInterestScoresOneHundredButUnknownDoesNot() async throws {
        var f=try Fixture();try f.replace(.interest,"0")
        let known=try await FundamentalScoring.calculate(f.input(),model:model(),executionDate:execution)
        try near(known.dimensions["balanceSheet"]?.leaves["interest"]?.value,"100")
        f.remove(.interest)
        let unknown=try await FundamentalScoring.calculate(f.input(),model:model(),executionDate:execution)
        #expect(unknown.dimensions["balanceSheet"]?.leaves["interest"]?.value == nil)
    }
    @Test func populationDeviationAndLinearClampUseDecimalArithmetic() throws {
        try near(FundamentalScoring.squareRoot(money("0.0225")),"0.15")
        try near(FundamentalScoring.scale(money("-3"),low:"0",high:"1"),"0")
        try near(FundamentalScoring.scale(money("3"),low:"0",high:"1",inverse:true),"0")
    }
}

@Suite struct HistoricalValuationTests {
    @Test func sameDayAndFutureAreExcludedAndDuplicateDaysRejected() async throws {
        let f=try Fixture(), m=try await model()
        let sample=try HistoricalFundamentalSample(input:f.input(),session:f.session())
        let r=try HistoricalValuation.calculate(current:f.input(),history:[sample],model:m,executionDate:execution)
        #expect(r.excluded[f.date.iso8601] == "OUTSIDE_PRIOR_FIVE_YEARS")
        #expect(throws:FundamentalError.duplicateInput) {
            try HistoricalValuation.calculate(current:f.input(),history:[sample,sample],model:m,executionDate:execution)
        }
    }
    @Test func feedMixingAndTodaysNormalizationCannotFillHistory() async throws {
        let current=try Fixture(date:"2024-03-01"),m=try await model()
        let other=try Fixture(date:"2024-02-01",feed:"different")
        var late=try Fixture(date:"2024-02-02");late.cutoff=late.cutoff.addingTimeInterval(1)
        let original=try Fixture(date:"2024-02-02")
        let r=try HistoricalValuation.calculate(current:current.input(),history:[.init(input:other.input(),session:other.session()),.init(input:late.input(),session:original.session())],model:m,executionDate:execution)
        #expect(r.excluded[other.date.iso8601] == "FEED_MISMATCH_OR_MISSING")
        #expect(r.excluded[late.date.iso8601] == "SESSION_OR_CLOSE_CUTOFF_UNPROVEN")
    }
    @Test func fullHistoryUsesStrictLessNearestRankAndReversesYieldLabels() async throws {
        let m=try await model(), current=try Fixture(price:"300",date:"2026-03-01")
        var history:[HistoricalFundamentalSample]=[], cursor=try day("2024-02-01")
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(secondsFromGMT:0)!
        while history.count < 530 {
            let weekday=calendar.component(.weekday,from:try cursor.start(in:calendar.timeZone))
            if weekday != 1 && weekday != 7 {
                let f=try Fixture(price:String(history.count+1),date:cursor.iso8601)
                history.append(try .init(input:f.input(),session:f.session()))
            }
            cursor=try cursor.addingDays(1)
        }
        let r=try HistoricalValuation.calculate(current:current.input(),history:history,model:m,executionDate:execution)
        let pe=try #require(r.metrics["peMarketCap"])
        #expect(pe.validDays == 530)
        try near(pe.rangePercentile,"56.415094339622641509")
        #expect(pe.prices.map(\.price.decimalString) == ["106","265","424"])
        #expect(pe.prices.map(\.percentile) == [20,50,80])
        let yields=try #require(r.metrics["fcfYield"])
        #expect(yields.prices.map(\.percentile) == [80,50,20])
        for (point,expected) in zip(yields.prices,[107,266,425]) {
            let delta=try point.price.subtracting(money(String(expected)))
            #expect(delta.amount.magnitude < Decimal(string:"0.000000001")!)
        }
        let short=try HistoricalValuation.calculate(current:current.input(),history:Array(history.prefix(252)),model:m,executionDate:execution)
        #expect(short.metrics["peMarketCap"]?.scorePercentile != nil)
        #expect(short.metrics["peMarketCap"]?.rangePercentile == nil && short.metrics["peMarketCap"]?.prices.isEmpty == true)
        let tooShort=try HistoricalValuation.calculate(current:current.input(),history:Array(history.prefix(251)),model:m,executionDate:execution)
        #expect(tooShort.metrics["peMarketCap"]?.scorePercentile == nil)
        let tooNarrow=try HistoricalValuation.calculate(current:current.input(),history:Array(history.prefix(504)),model:m,executionDate:execution)
        #expect(tooNarrow.metrics["peMarketCap"]?.rangePercentile == nil)
        let score=try FundamentalScoring.calculate(current.input(),history:history,model:m,executionDate:execution)
        #expect(score.coveredWeightOf84 == 84 && score.confidence == .high)
        #expect(score.total != nil)
    }

}

@Suite struct FundamentalReviewRegressionTests {
    @Test func mismatchedCurrentClassCannotProduceHistoricalPrices() async throws {
        var current = try Fixture(price:"20",date:"2026-03-01")
        let m = try await model()
        var history: [HistoricalFundamentalSample] = [], cursor = try day("2024-02-01")
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        while history.count < 530 {
            let weekday = calendar.component(.weekday,from:try cursor.start(in:calendar.timeZone))
            if weekday != 1 && weekday != 7 {
                let f = try Fixture(price:"20",date:cursor.iso8601)
                history.append(try .init(input:f.input(),session:f.session()))
            }
            cursor = try cursor.addingDays(1)
        }
        let valid = try HistoricalValuation.calculate(current:current.input(),history:history,model:m,executionDate:execution)
        for key in ["peMarketCap","evEBITDA","priceFCF","fcfYield"] {
            #expect(valid.metrics[key]?.prices.count == 3)
        }
        let a = current.classes[0]
        current.classes = [.init(classID:"B",price:a.price,shares:a.shares,priceProvenance:a.priceProvenance,
                                 shareProvenance:a.shareProvenance,shareBasisEvidence:a.shareBasisEvidence)]
        let mismatch = try HistoricalValuation.calculate(current:current.input(),history:history,model:m,executionDate:execution)
        #expect(mismatch.current.metrics["marketCap"]?.unavailable == .missingClass)
        for key in ["peMarketCap","evEBITDA","priceFCF","fcfYield"] {
            #expect(mismatch.metrics[key]?.prices.isEmpty == true)
            #expect(mismatch.metrics[key]?.position == nil)
            #expect(mismatch.metrics[key]?.unavailable == .missingClass)
            #expect(mismatch.metrics[key]?.scorePercentile == nil)
        }
    }

    @Test func reportContextDistinguishesEveryCalculationChoice() async throws {
        var base = try Fixture()
        base.values = try base.values.map { f in
            guard f.fieldID == FundamentalField.tax.rawValue else { return f }
            return try base.fact(.tax, [2021:"10",2022:"20",2023:"30"][f.periodEnd.year]!,
                                 start:f.periodStart,end:f.periodEnd,type:f.periodType)
        }
        func context(_ report: FundamentalReport) throws -> Data {
            var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(report)) as? [String:Any])
            json.removeValue(forKey:"metrics")
            return try JSONSerialization.data(withJSONObject:json,options:.sortedKeys)
        }
        let baseline = try await report(base)
        var year = base; year.years = Array(year.years.suffix(1))
        var company = base; company.financial = true
        var split = base; split.splitEvidence = nil
        var quarter = base; quarter.quarters = Array(quarter.quarters.suffix(4))
        for variant in [year, company, split, quarter] {
            let changed = try await report(variant)
            #expect(changed.metrics != baseline.metrics)
            #expect(try context(changed) != context(baseline))
        }
    }

    @Test func repeatedResolutionReusesTheSameImmutableReferences() async throws {
        let registry = ModelRegistry()
        let first = try await FundamentalModelV1.resolve(in:registry,at:execution)
        let second = try await FundamentalModelV1.resolve(in:registry,at:execution)
        #expect(first.definition.reference == second.definition.reference)
        #expect(first.parameters.reference == second.parameters.reference)
    }
    @Test func savedSnapshotAloneRecreatesOutputsWithoutReadingCachedMetrics() async throws {
        let resolved = try await model()
        func saved(_ variant: Int) throws -> Data {
            var f = try Fixture()
            f.values = try f.values.map { row in
                guard row.fieldID == FundamentalField.tax.rawValue else { return row }
                return try f.fact(.tax,[2021:"10",2022:"20",2023:"30"][row.periodEnd.year]!,
                                  start:row.periodStart,end:row.periodEnd,type:row.periodType)
            }
            if variant == 1 { f.years = Array(f.years.suffix(1)) }
            if variant == 2 { f.financial = true }
            if variant == 3 { f.splitEvidence = nil }
            if variant == 4 { f.quarters = Array(f.quarters.suffix(4)) }
            let base = try f.input()
            let input = try FundamentalInput(cik:base.cik,normalization:base.normalization,quarters:base.quarters,
                fiscalYears:base.fiscalYears,priceDay:base.priceDay,expectedClassIDs:base.expectedClassIDs,classes:base.classes,
                financialCompany:base.financialCompany,splitBasisEvidence:base.splitBasisEvidence,inputLimitations:["retained-context"])
            return try JSONEncoder().encode(FundamentalCalculator.calculate(input,model:resolved,executionDate:execution))
        } // No Fixture or FundamentalInput escapes: only the encoded report survives.
        for variant in 0...4 {
            let data = try saved(variant)
            let decoded = try JSONDecoder().decode(FundamentalReport.self,from:data)
            let recomputed = try decoded.recompute(using:resolved)
            #expect(recomputed.metrics == decoded.metrics)
            #expect(recomputed.limitations == decoded.limitations)
            #expect(recomputed.sourceVersions == decoded.sourceVersions)
            #expect(recomputed.inputSnapshot.input.inputLimitations == ["retained-context"])
            #expect(recomputed.inputSnapshot.input.fiscalYears.count == (variant == 1 ? 1 : 3))
            #expect(recomputed.inputSnapshot.input.financialCompany == (variant == 2))
            #expect((recomputed.inputSnapshot.input.splitBasisEvidence == nil) == (variant == 3))
            #expect(recomputed.inputSnapshot.input.quarters.count == (variant == 4 ? 4 : 8))
            var json = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
            json["metrics"] = [String:Any]()
            let emptied = try JSONDecoder().decode(FundamentalReport.self,from:JSONSerialization.data(withJSONObject:json))
            #expect(emptied.metrics.isEmpty)
            #expect(try emptied.recompute(using:resolved).metrics == decoded.metrics)
        }
    }

    @Test func snapshotDecodingRejectsMissingContextUnknownVersionsAndInvalidWindows() async throws {
        let data = try JSONEncoder().encode(await report(Fixture()))
        let root = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var noSnapshot = root; noSnapshot.removeValue(forKey:"inputSnapshot")
        #expect(throws:(any Error).self) {
            try JSONDecoder().decode(FundamentalReport.self,from:JSONSerialization.data(withJSONObject:noSnapshot))
        }
        let snapshot = try #require(root["inputSnapshot"] as? [String:Any])
        let input = try #require(snapshot["input"] as? [String:Any])
        for key in ["quarters","fiscalYears","financialCompany","splitBasisEvidence","inputLimitations"] {
            var edited = input; edited.removeValue(forKey:key)
            var snap = snapshot; snap["input"] = edited
            var json = root; json["inputSnapshot"] = snap
            #expect(throws:(any Error).self) {
                try JSONDecoder().decode(FundamentalReport.self,from:JSONSerialization.data(withJSONObject:json))
            }
        }
        var unknown = snapshot; unknown["formatVersion"] = "future-format"
        var json = root; json["inputSnapshot"] = unknown
        #expect(throws:FundamentalError.incompatibleInput) {
            try JSONDecoder().decode(FundamentalReport.self,from:JSONSerialization.data(withJSONObject:json))
        }
        var invalid = input
        invalid["quarters"] = Array(try #require(input["quarters"] as? [[String:Any]]).reversed())
        var snap = snapshot; snap["input"] = invalid; json["inputSnapshot"] = snap
        #expect(throws:ContractError.invalidRange) {
            try JSONDecoder().decode(FundamentalReport.self,from:JSONSerialization.data(withJSONObject:json))
        }
    }

    @Test func historyAndScoreRetainTheInputsNeededForReplay() async throws {
        let resolved = try await model()
        func encoded() throws -> Data {
            let current = try Fixture(date:"2024-03-01")
            let previous = try Fixture(date:"2024-02-01")
            let today = try HistoricalFundamentalSample(input:current.input(),session:current.session())
            return try JSONEncoder().encode(FundamentalScoring.calculate(current.input(),
                history:[.init(input:previous.input(),session:previous.session()),today],model:resolved,executionDate:execution))
        }
        let decoded = try JSONDecoder().decode(FundamentalScore.self,from:encoded())
        let replay = try decoded.recompute(using:resolved)
        #expect(replay.total == decoded.total && replay.confidence == decoded.confidence)
        #expect(replay.coveredWeightOf84 == decoded.coveredWeightOf84)
        #expect(replay.valuation.excluded == decoded.valuation.excluded)
        #expect(replay.valuation.current.metrics == decoded.valuation.current.metrics)
        for key in HistoricalValuation.metricIDs {
            #expect(replay.valuation.metrics[key]?.validDays == decoded.valuation.metrics[key]?.validDays)
            #expect(replay.valuation.metrics[key]?.unavailable == decoded.valuation.metrics[key]?.unavailable)
        }
        let historical = try decoded.valuation.recompute(using:resolved)
        #expect(historical.excluded == decoded.valuation.excluded)
        var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded.valuation.current)) as? [String:Any])
        var parameterRef = try #require(json["parameters"] as? [String:Any])
        parameterRef["contentHash"] = String(repeating:"0",count:64); json["parameters"] = parameterRef
        let wrong = try JSONDecoder().decode(FundamentalReport.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(throws:RegistryError.referenceMismatch) { try wrong.recompute(using:resolved) }
    }

    @Test func concurrentResolutionDoesNotRelaxRegistryImmutability() async throws {
        let registry = ModelRegistry(), (_,definition) = try FundamentalModelV1.definitions()
        try await withThrowingTaskGroup(of:RegistryReference.self) { group in
            for _ in 0..<8 { group.addTask { try await FundamentalModelV1.resolve(in:registry,at:execution).definition.reference } }
            for try await reference in group { #expect(reference == definition.reference) }
        }
        // The general registry registration API remains strict, even for identical content.
        await #expect(throws:RegistryError.duplicateVersion) { try await registry.register(definition) }
    }

    @Test func conflictingParameterAndModelVersionsAreNeverOverwritten() async throws {
        let (p,m) = try FundamentalModelV1.definitions()
        let parametersRegistry = ModelRegistry()
        let other = ParameterSet(id:p.id,version:p.version,revisionID:p.revisionID,
            values:["different":.boolean(true)],state:p.state,dispositionReference:p.dispositionReference)
        try await parametersRegistry.register(other)
        await #expect(throws:RegistryError.referenceMismatch) { try await FundamentalModelV1.resolve(in:parametersRegistry,at:execution) }
        #expect(try await parametersRegistry.parameterSet(reference:other.reference).reference == other.reference)
        let modelRegistry = ModelRegistry()
        var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(m)) as? [String:Any])
        json["formula"] = "different formula"
        let conflict = try JSONDecoder().decode(ModelDefinition.self,from:JSONSerialization.data(withJSONObject:json))
        try await modelRegistry.register(p); try await modelRegistry.register(conflict)
        await #expect(throws:RegistryError.referenceMismatch) { try await FundamentalModelV1.resolve(in:modelRegistry,at:execution) }
        #expect(try await modelRegistry.definition(id:m.id,version:m.version).reference == conflict.reference)
    }

    @Test func subMillisecondCutoffRetainsExactExecutionTimeForReplay() async throws {
        let resolved = try await model()
        func encoded() throws -> Data {
            var f = try Fixture(date:"2026-09-21")
            f.cutoff = f.cutoff.addingTimeInterval(0.0004)
            return try JSONEncoder().encode(FundamentalCalculator.calculate(f.input(),model:resolved,executionDate:f.cutoff))
        }
        let decoded = try JSONDecoder().decode(FundamentalReport.self,from:encoded())
        #expect(decoded.inputSnapshot.executionDate == decoded.inputSnapshot.input.normalization.asOf)
        #expect(decoded.executionAt.date < decoded.inputSnapshot.executionDate)
        #expect(try decoded.recompute(using:resolved).metrics == decoded.metrics)
    }

}
