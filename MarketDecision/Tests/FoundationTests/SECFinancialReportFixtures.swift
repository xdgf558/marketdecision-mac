import Foundation
import CoreDomain
import DataContracts
import DataProviders
import SECProvider
import FundamentalsEngine
@testable import Persistence

private actor FinancialFixtureGate: SECRequestGate {
    func wait() async throws { try Task.checkCancellation() }
}
private actor FinancialFixtureTransport: HTTPTransport {
    var payloads: [HTTPPayload]
    init(_ payloads: [HTTPPayload]) { self.payloads = payloads }
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        try Task.checkCancellation()
        guard !payloads.isEmpty else { throw ProviderFailure.offline }
        return payloads.removeFirst()
    }
}

/// Real accept pipeline over synthetic response bytes; no network or answer-key fixture.
func secFinancialReportFixtureParent(sic: String? = "7372") async throws -> SECResearchDocument {
    let now = Date(timeIntervalSince1970: 1_791_072_000)
    var accessions: [String] = [], dates: [String] = [], reportDates: [String] = []
    var forms: [String] = [], documents: [String] = [], accepted: [String] = []
    var units: [String: [[String: Any]]] = [:]
    let concepts: [(String, Int)] = [
        ("RevenueFromContractWithCustomerExcludingAssessedTax", 100),
        ("OperatingIncomeLoss", 20), ("NetIncomeLoss", 10),
        ("NetCashProvidedByUsedInOperatingActivities", 25),
        ("PaymentsToAcquirePropertyPlantAndEquipment", 5)]
    for year in 2023...2024 {
        for (index, bounds) in [("01-01", "03-31"), ("04-01", "06-30"), ("07-01", "09-30"), ("10-01", "12-31")].enumerated() {
            let end = String(year) + "-" + bounds.1
            let date = try MarketDate(iso8601: end).addingDays(32).iso8601
            let acc = "0000320193-" + String(year % 100) + "-00000" + String(index + 1)
            let form = index == 3 ? "10-K" : "10-Q"
            accessions.append(acc); dates.append(date); reportDates.append(end); forms.append(form)
            documents.append(index == 3 ? "annual.htm" : "quarter.htm"); accepted.append(date + "T21:00:00Z")
            for (concept, value) in concepts {
                // fp/fy are deliberately the enclosing filing metadata, not our quarter contract.
                var observations = units[concept] ?? []
                observations.append(["start": String(year) + "-" + bounds.0, "end": end, "val": value,
                    "accn": acc, "fy": year, "fp": index == 3 ? "FY" : "Q" + String(index + 1),
                    "form": form, "filed": date])
                if index == 3 {
                    observations.append(["start": String(year) + "-01-01", "end": end, "val": value * 4,
                        "accn": acc, "fy": year, "fp": "FY", "form": form, "filed": date])
                }
                units[concept] = observations
            }
        }
    }
    var facts: [String: Any] = [:]
    for (concept, _) in concepts {
        facts[concept] = ["label": concept, "description": "Synthetic report inputs", "units": ["USD": units[concept] ?? []]]
    }
    func payload(_ object: [String: Any]) throws -> HTTPPayload {
        HTTPPayload(statusCode: 200, mediaType: "application/json", body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    let identity: [String: Any] = ["fields": ["cik", "name", "ticker", "exchange"], "data": [[320193, "Synthetic Report Company", "AAPL", "Nasdaq"]]]
    var submissions: [String: Any] = ["cik": "0000320193", "filings": ["recent": [
        "accessionNumber": accessions, "filingDate": dates, "reportDate": reportDates,
        "acceptanceDateTime": accepted, "form": forms, "primaryDocument": documents], "files": []]]
    if let sic { submissions["sic"] = sic }
    let transport = try FinancialFixtureTransport([
        payload(identity), payload(submissions), payload(["cik": 320193, "entityName": "Synthetic Report Company", "facts": ["us-gaap": facts]]),
        payload(["directory": ["item": [["name": "annual.htm", "type": "text/html", "size": 9]]]]),
        HTTPPayload(statusCode: 200, mediaType: "text/html", body: Data("<p>QA</p>".utf8)),
        payload(["directory": ["item": [["name": "quarter.htm", "type": "text/html", "size": 9]]]]),
        HTTPPayload(statusCode: 200, mediaType: "text/html", body: Data("<p>QA</p>".utf8))])
    let provider = try SECEdgarProvider(userAgent: "MarketDecisionTests/1.0 synthetic@example.invalid", transport: transport,
        gate: FinancialFixtureGate(), evidenceRef: "synthetic-sec-report", licenseRef: "synthetic-sec-report-rights", now: { now })
    let entitlement = EntitlementSnapshot(providerID: provider.id, feedID: "public-edgar", version: "synthetic.report.v1",
        evidenceRef: "synthetic-sec-report", licenseRef: "synthetic-sec-report-rights", capabilities: provider.capabilitySnapshot.capabilities,
        usages: [.replay], validFrom: now.addingTimeInterval(-100), validThrough: now.addingTimeInterval(100))
    let store = try SECResearchStore(path: ":memory:")
    let service = SECResearchService(client: FundamentalsDataClient(provider: provider, entitlement: entitlement), store: store, now: { now })
    return try await service.importCompany(ticker: "AAPL", progress: { _ in })
}
