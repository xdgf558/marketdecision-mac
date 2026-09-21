import Foundation
import CoreDomain
import DataContracts

public enum ResearchError: Error, Equatable { case invalidDocument, unsupportedFormat, inconsistentEvidence, staleWatchlist }

/// Local synthetic evidence, not an SEC download. Exact source text and its semantic mapping are frozen.
public struct ResearchRawFact: Sendable, Codable, Equatable {
    public let field: FundamentalField
    public let value: String
    public let start: MarketDate?
    public let end: MarketDate
    public let fiscalPeriod: String?
    public var id: String { field.rawValue + "/" + (start?.iso8601 ?? "instant") + "/" + end.iso8601 }
    public init(field: FundamentalField, value: String, start: MarketDate?, end: MarketDate, fiscalPeriod: String?) {
        self.field = field; self.value = value; self.start = start; self.end = end; self.fiscalPeriod = fiscalPeriod
    }
}

/// This first research workflow accepts only generated evidence. A real source needs its own
/// reviewed admission path; Codable decoding is never an authorization grant.
public struct ResearchDocument: Sendable, Codable, Identifiable {
    public let format: String
    public let id: UUID
    public let symbol: String
    public let name: String
    public let rawData: Data
    public let rawHash: String
    public let capitalData: Data
    public let sourceAvailableAt: Date
    public let dictionaryRules: [FinancialMappingRule]
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let score: FundamentalScore
    public var report: FundamentalReport { score.valuation.current }
    public var synthetic: Bool { true }

    init(id: UUID, symbol: String, name: String, rawData: Data, sourceAvailableAt: Date,
         dictionary: FinancialFieldDictionary, model: ResolvedModel, score: FundamentalScore) {
        format = "research-demo.v1"; self.id = id; self.symbol = symbol; self.name = name
        self.rawData = rawData; rawHash = digest(rawData); capitalData = Data((symbol == "DEMO" ? "price=10;shares=10000000" : "unavailable").utf8); self.sourceAvailableAt = sourceAvailableAt
        dictionaryRules = dictionary.rules; self.model = model.definition; parameters = model.parameters; self.score = score
    }
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public func rawFacts() throws -> [ResearchRawFact] { try JSONDecoder().decode([ResearchRawFact].self, from: rawData) }
    public func validate() async throws {
        guard format == "research-demo.v1" else { throw ResearchError.unsupportedFormat }
        guard ["DEMO", "GAP"].contains(symbol), name == (symbol == "DEMO" ? "示例工业" : "缺失数据示例"),
              rawData.count <= 5 * 1_024 * 1_024, digest(rawData) == rawHash,
              report.cik == "0000000000", report.researchOnly, score.valuation.historyInputs.isEmpty,
              report.inputSnapshot.input.inputLimitations.contains("SYNTHETIC_DEMO_NOT_INVESTMENT_DATA"),
              sourceAvailableAt <= report.inputSnapshot.input.normalization.asOf,
              model.reference == report.model, parameters.reference == report.parameters else { throw ResearchError.invalidDocument }
        let dictionary = try FinancialFieldDictionary(version: report.dictionaryVersion, rules: dictionaryRules)
        let facts = try Self.sourceFacts(rawFacts(), rawHash: rawHash, availableAt: sourceAvailableAt)
        let normalized = try FinancialNormalizer.normalizeComplete(facts, dictionary: dictionary, asOf: report.inputSnapshot.input.normalization.asOf)
        guard normalized == report.inputSnapshot.input.normalization,
              report.capitalInputs.allSatisfy({ $0.priceProvenance.origin == .derived && $0.shareProvenance.origin == .derived }) else {
            throw ResearchError.inconsistentEvidence
        }
        if symbol == "DEMO" {
            guard capitalData == Data("price=10;shares=10000000".utf8), report.capitalInputs.count == 1,
                  let capital = report.capitalInputs.first, capital.classID == "A",
                  capital.price == (try Money("10")), capital.shares == (try Money("10000000")),
                  capital.priceProvenance.providerID == "demo", capital.shareProvenance.providerID == "demo",
                  capital.priceProvenance.rawHash == digest(capitalData), capital.shareProvenance.rawHash == digest(capitalData)
            else { throw ResearchError.inconsistentEvidence }
        } else {
            guard report.capitalInputs.isEmpty, capitalData == Data("unavailable".utf8) else { throw ResearchError.inconsistentEvidence }
        }
        let replay = try await recompute()
        guard try Self.encoded(replay) == Self.encoded(score) else { throw ResearchError.inconsistentEvidence }
    }
    public func recompute() async throws -> FundamentalScore {
        let registry = ModelRegistry()
        try await registry.register(parameters); try await registry.register(model)
        let resolved = try await registry.resolve(reference: report.model, at: report.inputSnapshot.executionDate)
        return try score.recompute(using: resolved)
    }
    static func sourceFacts(_ rows: [ResearchRawFact], rawHash: String, availableAt: Date) throws -> [SECCompanyFactRecord] {
        guard Set(rows.map(\.id)).count == rows.count else { throw ResearchError.inconsistentEvidence }
        return try rows.map { row in
            try SECCompanyFactRecord(recordID: row.id + "/v1", factID: row.id, cik: "0000000000", taxonomy: "demo",
                concept: row.field.rawValue, label: row.field.rawValue, description: "Generated demonstration field; not an SEC filing",
                unit: row.field.unit, sourceValue: row.value, value: Money(row.value), startDate: row.start, endDate: row.end,
                periodKind: row.start == nil ? .instant : .duration, accessionNumber: "0000000000-24-000001", form: "DEMO",
                filedDate: MarketDate(iso8601: "2024-01-31"), fiscalYear: row.end.year, fiscalPeriod: row.fiscalPeriod, frame: nil,
                provenance: Provenance(providerID: "demo", feedID: "demo-financials", sourceEventAt: availableAt, receivedAt: availableAt,
                    availableAt: nil, evidenceRef: "generated-demo.v1", origin: .derived,
                    endpointDescriptor: EndpointDescriptor.companyFacts.rawValue, requestedAt: availableAt,
                    requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, observationDate: row.end,
                    versionID: row.id + "/v1", versionKind: .sourceVersion, availability: .instant(availableAt, evidence: "generated-demo.v1"),
                    rawObjectRef: "demo-financials.v1", rawHash: rawHash, normalizationVersion: "demo-fields.v1", licenseRef: "generated-demo"))
        }
    }
}

/// Deliberately limited catalog: no company lookup, account, live prices or inferred SEC identity.
public enum SyntheticResearchFactory {
    public static func make(symbol: String, executionDate: Date = Date(), id: UUID = UUID()) async throws -> ResearchDocument {
        guard ["DEMO", "GAP"].contains(symbol) else { throw ResearchError.invalidDocument }
        func day(_ text: String) throws -> MarketDate { try MarketDate(iso8601: text) }
        let priceDay = try day("2024-02-01"), cutoff = try MillisecondInstant(iso8601: "2024-02-01T21:00:00.000Z").date
        let available = try MillisecondInstant(iso8601: "2024-01-31T21:00:00.000Z").date
        var quarters: [FiscalQuarter] = [], rows: [ResearchRawFact] = []
        for year in [2022, 2023] {
            for (index, dates) in [("01-01", "03-31"), ("04-01", "06-30"), ("07-01", "09-30"), ("10-01", "12-31")].enumerated() {
                let q = try FiscalQuarter(start: day("\(year)-" + dates.0), end: day("\(year)-" + dates.1)); quarters.append(q)
                let flows: [(FundamentalField, String)] = [(.revenue, year == 2022 ? "80000000" : "100000000"),
                    (.grossProfit,"40000000"), (.operatingIncome,"20000000"), (.netIncome,"10000000"), (.commonIncome,"8000000"),
                    (.ocf,"15000000"), (.capex,"5000000"), (.sbc,"2000000"), (.depreciation,"3000000"), (.interest,"2000000"),
                    (.buybacks,"4000000"), (.issuance,"1000000"), (.dividends,"2000000"), (.dilutedEPS,year == 2022 ? "0.8":"1")]
                for (field, value) in flows where symbol != "GAP" || ![FundamentalField.ocf, .capex, .dilutedEPS].contains(field) {
                    rows.append(.init(field:field,value:value,start:q.start,end:q.end,fiscalPeriod:"Q\(index+1)"))
                }
            }
        }
        for end in [try day("2021-12-31")] + quarters.map(\.end) {
            let balances: [(FundamentalField, String)] = [(.assets,"500000000"),(.currentAssets,"200000000"),(.currentLiabilities,"100000000"),
                (.commonEquity,"180000000"),(.totalEquity,"200000000"),(.preferred,"10000000"),(.nci,"10000000"),(.cash,"50000000"),
                (.shortDebt,"10000000"),(.currentDebt,"10000000"),(.longDebt,"50000000"),(.financeLease,"20000000"),(.operatingLease,"10000000"),
                (.actualShares,end.year < 2023 ? "11000000":"10000000"),(.leaseRate,"0.05")]
            for (field,value) in balances { rows.append(.init(field:field,value:value,start:nil,end:end,fiscalPeriod:nil)) }
        }
        var years: [FiscalYearWindow] = []
        for year in [2021,2022,2023] {
            let y = try FiscalYearWindow(start:day("\(year)-01-01"),end:day("\(year)-12-31")); years.append(y)
            for (field,value) in [(FundamentalField.pretaxIncome,"100000000"),(.tax,"20000000")] {
                rows.append(.init(field:field,value:value,start:y.start,end:y.end,fiscalPeriod:"FY"))
            }
        }
        let bytes = try ResearchDocument.encoded(rows)
        let fields = Set(rows.map(\.field)).sorted { $0.rawValue < $1.rawValue }
        let dictionary = try FinancialFieldDictionary(version:"demo-fields.v1",rules:fields.map {
            try .init(taxonomy:"demo",concept:$0.rawValue,sourceUnit:$0.unit,fieldID:$0.rawValue,statement:.other,
                      nature:$0.isInstant ? .instant : $0 == .dilutedEPS ? .perShare : .additiveFlow)
        })
        let normalized = try FinancialNormalizer.normalizeComplete(ResearchDocument.sourceFacts(rows,rawHash:digest(bytes),availableAt:available),dictionary:dictionary,asOf:cutoff)
        let provenance = Provenance(providerID:"demo",feedID:"demo-close",sourceEventAt:cutoff,receivedAt:cutoff,availableAt:nil,
            evidenceRef:"generated-demo-price-shares",origin:.derived,endpointDescriptor:EndpointDescriptor.bars.rawValue,
            requestedAt:cutoff,requestID:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,observationDate:priceDay,
            versionID:"demo-capital.v1",versionKind:.sourceVersion,availability:.instant(cutoff,evidence:"generated-demo"),
            rawObjectRef:"demo-capital.v1",rawHash:digest(Data("price=10;shares=10000000".utf8)),normalizationVersion:"demo-capital.v1",licenseRef:"generated-demo")
        let classes: [EquityClassInput] = symbol == "GAP" ? [] : [.init(classID:"A",price:try Money("10"),shares:try Money("10000000"),
            priceProvenance:provenance,shareProvenance:provenance,shareBasisEvidence:"Generated same-basis outstanding shares")]
        let input = try FundamentalInput(cik:"0000000000",normalization:normalized,quarters:quarters,fiscalYears:years,priceDay:priceDay,
            expectedClassIDs:["A"],classes:classes,splitBasisEvidence:"Generated no-split fixture",inputLimitations:["SYNTHETIC_DEMO_NOT_INVESTMENT_DATA"])
        let resolved = try await FundamentalModelV1.resolve(in:ModelRegistry(),at:executionDate)
        return ResearchDocument(id:id,symbol:symbol,name:symbol == "DEMO" ? "示例工业":"缺失数据示例",rawData:bytes,sourceAvailableAt:available,
            dictionary:dictionary,model:resolved,score:try FundamentalScoring.calculate(input,model:resolved,executionDate:executionDate))
    }
}
