import Foundation
import Testing
import Persistence
import AppComposition

@Suite struct SECStockDailyCatalogTests {
    @Test func selectedTickerIsNormalizedAndDoesNotSelectAnotherCompany() throws {
        let msft = try source(1, ticker: "MSFT", cutoff: 10)
        let aapl = try source(2, ticker: "AAPL", cutoff: 20)
        let msftReport = try report(3, ticker: "MSFT", cutoff: 10, createdAt: 15)
        let aaplReport = try report(4, ticker: "AAPL", cutoff: 20, createdAt: 25)
        let value = SECStockDailyCatalog(ticker: " \nmsft\t", research: [aapl, msft], reports: [aaplReport, msftReport])
        #expect(value.research == [msft])
        #expect(value.reports == [msftReport])
        #expect(value.conflictingRecordCount == 0)

        let empty = SECStockDailyCatalog(ticker: " \n", research: [msft], reports: [msftReport])
        #expect(empty.research.isEmpty && empty.reports.isEmpty)
        #expect(empty.companies.map(\.ticker) == ["MSFT"])
    }

    @Test func companyMenuUnitesBothCatalogsAndUsesLatestMetadataName() throws {
        let older = try source(1, ticker: "MSFT", name: "Earlier name", cutoff: 10)
        let newer = try source(2, ticker: "MSFT", name: "Latest name", cutoff: 30)
        let onlySource = try source(3, ticker: "AAPL", cutoff: 20)
        let oldReport = try report(4, ticker: "MSFT", name: "Old report name", cutoff: 10, createdAt: 40)
        let onlyReport = try report(5, ticker: "GOOG", name: "Report-only company", cutoff: 20, createdAt: 25)
        let value = SECStockDailyCatalog(ticker: "MSFT", research: [older, onlySource, newer], reports: [oldReport, onlyReport])
        #expect(value.companies.map(\.ticker) == ["MSFT", "AAPL", "GOOG"])
        #expect(value.companies.map(\.id) == value.companies.map(\.ticker))
        #expect(value.companies.map(\.hasReport) == [true, false, true])
        #expect(value.companies.first?.companyName == "Latest name")
        #expect(value.companies.first?.cutoff == instant(30))
    }

    @Test func sourceAndReportOrderingIsStableAcrossInputPermutation() throws {
        let sources = try [source(2, cutoff: 10), source(1, cutoff: 10), source(3, cutoff: 20)]
        let reports = try [report(8, cutoff: 20, createdAt: 30), report(7, cutoff: 20, createdAt: 30),
                           report(6, cutoff: 20, createdAt: 25), report(9, cutoff: 10, createdAt: 50)]
        let first = SECStockDailyCatalog(ticker: "MSFT", research: sources, reports: reports)
        let second = SECStockDailyCatalog(ticker: "MSFT", research: Array(sources.reversed()), reports: Array(reports.reversed()))
        #expect(first.research.map(\.id) == [sources[2].id, sources[1].id, sources[0].id])
        #expect(first.reports.map(\.id) == [reports[1].id, reports[0].id, reports[2].id, reports[3].id])
        #expect(first.research == second.research)
        #expect(first.reports == second.reports)
        #expect(first.companies == second.companies)
    }

    @Test func identicalMetadataCollapsesWithoutFlaggingAConflict() throws {
        let source = try self.source(1, cutoff: 10)
        let report = try self.report(2, cutoff: 10, createdAt: 20)
        let value = SECStockDailyCatalog(ticker: "MSFT", research: [source, source, source], reports: [report, report])
        #expect(value.research == [source])
        #expect(value.reports == [report])
        #expect(value.companies.count == 1)
        #expect(value.conflictingRecordCount == 0)
    }

    @Test func conflictingIDsRemoveEveryVariantWithoutDroppingHealthyRows() throws {
        let source = try self.source(1, name: "First name", cutoff: 10)
        let conflict = try self.source(1, name: "Conflicting name", cutoff: 10)
        let healthy = try self.source(2, ticker: "AAPL", cutoff: 20)
        let report = try self.report(3, cutoff: 10, createdAt: 20)
        let reportConflict = try self.report(3, cutoff: 10, createdAt: 21)
        let healthyReport = try self.report(4, ticker: "AAPL", cutoff: 20, createdAt: 30)
        let value = SECStockDailyCatalog(ticker: "AAPL", research: [source, conflict, source, healthy],
                                        reports: [report, reportConflict, report, healthyReport])
        #expect(value.conflictingRecordCount == 2)
        #expect(value.research == [healthy])
        #expect(value.reports == [healthyReport])
        #expect(value.companies.map(\.ticker) == ["AAPL"])
    }

    @Test func duplicateIdentityConflictAcrossTickersIsDetectedBeforeFiltering() throws {
        let msft = try source(1, ticker: "MSFT", cutoff: 10)
        let aapl = try source(1, ticker: "AAPL", cutoff: 10)
        let reportMSFT = try report(2, ticker: "MSFT", cutoff: 10, createdAt: 20)
        let reportAAPL = try report(2, ticker: "AAPL", cutoff: 10, createdAt: 20)
        for ticker in ["MSFT", "AAPL"] {
            let value = SECStockDailyCatalog(ticker: ticker, research: [msft, aapl], reports: [reportMSFT, reportAAPL])
            #expect(value.research.isEmpty && value.reports.isEmpty && value.companies.isEmpty)
            #expect(value.conflictingRecordCount == 2)
        }
    }

    private func source(_ id: Int, ticker: String = "MSFT", name: String = "Company", cutoff: TimeInterval) throws -> SECResearchSummary {
        try decode(["id": uuid(id), "ticker": ticker, "companyName": name,
                    "cutoff": cutoff, "sourceCount": 1, "factCount": 2])
    }

    private func report(_ id: Int, ticker: String = "MSFT", name: String = "Company", cutoff: TimeInterval,
                        createdAt: TimeInterval) throws -> SECFinancialReportSummary {
        try decode(["id": uuid(id), "parentDocumentID": uuid(100), "ticker": ticker, "companyName": name,
                    "cutoff": cutoff, "createdAt": createdAt])
    }

    private func uuid(_ id: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", id) }
    private func instant(_ value: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: value) }
    private func decode<Value: Decodable>(_ object: [String: Any]) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
