import Foundation
import Testing
import CoreDomain
import DataContracts
@testable import FundamentalsEngine

// Annual evidence/units and arithmetic checks only. These ten cases are not ten
// qualified, four-quarter inputs to the valuation/scoring or SEC ingestion pipeline.
private struct AnnualCollection: Decodable {
    struct Fixture: Decodable {
        struct Issuer: Decodable { let ticker,cik: String; let financialCompany: Bool }
        struct Period: Decodable { let fiscalYear: Int; let start,end,kind: String }
        struct Source: Decodable {
            struct Availability: Decodable { let kind,observedAt: String; let firstPublicAt: String?; let historicalPITEligible: Bool }
            let url,sha256,retrievedAt,documentKind: String
            let accessionNumber,filedDate,acceptedAt: String?
            let availability: Availability
        }
        struct Fact: Decodable {
            let fieldID,unit,sourceHash,sourceURL,sourceLocator,periodStart,periodEnd,periodKind,state: String
            let decimalValue,reportedValue,reportedScale,taxonomy,concept: String?
        }
        struct Expected: Decodable {
            let annualFCFArithmetic: String?
            let annualNetMarginRounded: String
            let modelFCFApplicable: Bool
            let modelFCFNotApplicableReason: String?
        }
        struct Supporting: Decodable { let decimalMagnitude,sourceHash,sourceLabel: String; let mappingAccepted: Bool }
        let id: String
        let issuer: Issuer
        let period: Period
        let source: Source
        let facts: [Fact]
        let expected: Expected
        let supportingDisclosures: [Supporting]
        func amount(_ id: String) throws -> Money? { try facts.first { $0.fieldID == id }?.decimalValue.map(Money.init) }
    }
    let schemaVersion: String
    let fixtures: [Fixture]
    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource:"issuer-annual-golden",withExtension:"json"))
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
    }
}

@Suite struct IssuerAnnualGoldenTests {
    @Test(arguments:["AAPL-FY2024","MSFT-FY2024","META-FY2024","AMZN-FY2024","NVDA-FY2025",
                     "COST-FY2024","WMT-FY2025","KO-FY2024","JPM-FY2024","BRK.B-FY2024"])
    func tenIssuerAnnualFactsMatchScalesAndIndependentArithmetic(id: String) throws {
        let f = try #require(AnnualCollection.load().fixtures.first { $0.id == id })
        #expect(f.facts.count == 4 && Set(f.facts.map(\.fieldID)).count == 4)
        for row in f.facts {
            #expect(row.unit == "USD" && row.periodKind == "annual")
            #expect(row.sourceHash == f.source.sha256 && row.sourceURL == f.source.url)
            #expect(row.periodStart == f.period.start && row.periodEnd == f.period.end)
            #expect(!row.sourceLocator.isEmpty && row.taxonomy == nil && row.concept == nil)
            if row.state == "present" {
                let text = try #require(row.reportedValue), scale = try #require(row.reportedScale)
                #expect(try Money(text).multiplied(by:scale) == Money(#require(row.decimalValue)))
            } else { #expect(row.decimalValue == nil) }
        }
        // Production precision and ratio kernel versus independent Python Decimal oracle.
        let margin = try fratio(f.amount("income.net-income"),f.amount("income.revenue"))
        #expect(try margin.value == Money(f.expected.annualNetMarginRounded))
        if let ocf = try f.amount("cash-flow.operating-cash-flow"), let capex = try f.amount("cash-flow.capex") {
            #expect(capex.amount >= 0)
            #expect(try ocf.subtracting(capex) == Money(#require(f.expected.annualFCFArithmetic)))
        } else { #expect(f.expected.annualFCFArithmetic == nil) }
        if f.issuer.financialCompany { #expect(!f.expected.modelFCFApplicable) }
    }
    @Test func allTenSourcesRemainRetrievalOnlyAndNeverMasqueradeAsSECResponses() throws {
        let c = try AnnualCollection.load()
        #expect(c.schemaVersion == "issuer-annual-golden-collection.v1" && c.fixtures.count == 10)
        #expect(Set(c.fixtures.map(\.issuer.cik)).count == 10)
        for f in c.fixtures {
            #expect(f.source.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil)
            #expect(URL(string:f.source.url)?.scheme == "https")
            #expect(f.source.acceptedAt == nil)
            if let accession = f.source.accessionNumber {
                #expect(["AMZN-FY2024","WMT-FY2025","KO-FY2024"].contains(f.id))
                #expect(accession.range(of:"^[0-9]{10}-[0-9]{2}-[0-9]{6}$",options:.regularExpression) != nil)
                _ = try MarketDate(iso8601:#require(f.source.filedDate))
            } else { #expect(f.source.filedDate == nil) }
            #expect(f.source.availability.kind == "retrieval-only" && !f.source.availability.historicalPITEligible)
            #expect(f.source.availability.firstPublicAt == nil && f.source.availability.observedAt == f.source.retrievedAt)
            _ = try FiscalYearWindow(start:MarketDate(iso8601:f.period.start),end:MarketDate(iso8601:f.period.end))
        }
        let meta = try #require(c.fixtures.first { $0.issuer.ticker == "META" })
        #expect(meta.source.documentKind.contains("release"))
    }
    @Test func annualOnlyRealCasesCannotManufactureQuarterlyOrTTMInputs() throws {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        for f in try AnnualCollection.load().fixtures {
            let observed = try #require(parser.date(from:f.source.retrievedAt))
            let rows: [NormalizedFinancialFact] = try f.facts.filter { $0.state == "present" }.map { row in
                .init(id:f.id+row.fieldID,cik:f.issuer.cik,fieldID:row.fieldID,statement:.other,nature:.additiveFlow,
                    periodType:.annual,periodStart:try MarketDate(iso8601:f.period.start),periodEnd:try MarketDate(iso8601:f.period.end),
                    fiscalYear:f.period.fiscalYear,fiscalPeriod:"FY",unit:row.unit,value:try Money(#require(row.decimalValue)),
                    sourceValue:row.reportedValue,derivation:.reported,sourceFactIDs:[f.id+row.fieldID],sourceVersions:[row.sourceHash],
                    accessionNumbers:[],dictionaryVersion:"issuer-golden.manual.v1",availableAt:observed,
                    confidence:.medium,limitations:["ANNUAL_ONLY_NO_QUARTER_BRIDGE"])
            }
            let quarters = try FinancialNormalizer.discreteQuarters(from:rows)
            #expect(quarters.values.isEmpty && !quarters.issues.isEmpty)
            #expect(try FinancialNormalizer.trailingTwelveMonths(from:quarters.values).values.isEmpty)
        }
    }
    @Test func mixedCapexFinancialSectorAndParentIncomeAmbiguitiesStayExplicit() throws {
        let c = try AnnualCollection.load()
        let nvidia = try #require(c.fixtures.first { $0.issuer.ticker == "NVDA" })
        #expect(try nvidia.amount("cash-flow.capex") == nil && nvidia.expected.annualFCFArithmetic == nil)
        #expect(nvidia.supportingDisclosures.contains { $0.decimalMagnitude == "3236000000" && !$0.mappingAccepted })
        let bank = try #require(c.fixtures.first { $0.issuer.ticker == "JPM" })
        #expect(try bank.amount("cash-flow.operating-cash-flow") == Money("-42012000000"))
        #expect(try bank.amount("cash-flow.capex") == nil && !bank.expected.modelFCFApplicable)
        for ticker in ["WMT","KO","BRK.B"] {
            let f = try #require(c.fixtures.first { $0.issuer.ticker == ticker })
            let total = try #require(f.supportingDisclosures.first { $0.sourceLabel.lowercased().contains("noncontrolling") })
            #expect(try f.amount("income.net-income") != Money(total.decimalMagnitude))
            #expect(!total.mappingAccepted)
        }
    }
}
