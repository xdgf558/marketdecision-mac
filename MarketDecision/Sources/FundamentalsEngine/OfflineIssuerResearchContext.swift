import Foundation
import CoreDomain
import DataContracts

public enum OfflineIssuerResearchError: Error, Equatable {
    case unsupportedFormat, invalidExcerpt, inconsistentEvidence, invalidDocument, unsupportedMapping, invalidRetention
}

/// Permission for the retained manual excerpt only. This is not a license for the referenced
/// PDF/HTML, a provider entitlement, or permission to obtain additional data.
public struct OfflineIssuerResearchRetention: Sendable, Codable, Equatable {
    public let mayStore: Bool, mayBackup: Bool
    public let evidenceReference: String
    public init(mayStore: Bool, mayBackup: Bool, evidenceReference: String) throws {
        self.mayStore = mayStore; self.mayBackup = mayBackup; self.evidenceReference = evidenceReference
        try validate()
    }
    public func validate() throws {
        guard issuerText(evidenceReference, maximum: 512) else { throw OfflineIssuerResearchError.invalidRetention }
    }
}

/// A projection of a manually reviewed issuer-table cell. originalSourceHash identifies a
/// referenced document that is NOT contained in the archive. The archive hashes excerptData separately.
public struct OfflineIssuerFact: Sendable, Decodable {
    public let fieldID, statement, periodType, nature, unit: String
    public let start, fiscalPeriod: String?
    public let end: String
    public let fiscalYear: Int
    public let decimalValue, reportedValue, reportedScale, signConvention: String
    public let sourceHash, sourceURL, observedAt, sourceLocator: String
    public var originalSourceHash: String { sourceHash }

    public var sourceCellID: String {
        // fieldID deliberately does not participate: relabelling the same cell is not new evidence.
        [sourceHash, sourceLocator, start ?? "instant", end, unit].joined(separator: "/")
    }
    func reported(cik: String) throws -> NormalizedFinancialFact {
        guard issuerText(fieldID, maximum: 128),
              fieldID.range(of: #"^[a-z][a-z0-9._\-]*\z"#, options: .regularExpression) != nil,
              let statement = FinancialStatement(rawValue: statement),
              let period = FinancialPeriodType(rawValue: periodType),
              [.instant, .quarter, .yearToDate, .annual].contains(period),
              let nature = nature == "weightedAverageShares" ? .some(FinancialMetricNature.nonadditive)
                : FinancialMetricNature(rawValue: nature),
              ["USD", "USD/shares", "shares", "pure"].contains(unit),
              (1900...2200).contains(fiscalYear) else { throw OfflineIssuerResearchError.unsupportedMapping }
        try issuerSource(hash: sourceHash, url: sourceURL, locator: sourceLocator)
        let available = try issuerDate(observedAt)
        let begin = try start.map { try MarketDate(iso8601: $0) }, end = try MarketDate(iso8601: end)
        guard begin.map({ $0 <= end }) ?? true,
              (period == .instant) == (begin == nil),
              (nature == .instant) == (period == .instant),
              period != .annual || fiscalPeriod == "FY",
              ![.quarter, .yearToDate].contains(period) || ["Q1", "Q2", "Q3", "Q4"].contains(fiscalPeriod ?? "")
        else { throw OfflineIssuerResearchError.inconsistentEvidence }
        let value = try convertedValue()
        return .init(id: sourceCellID, cik: cik, fieldID: fieldID, statement: statement, nature: nature,
            periodType: period, periodStart: begin, periodEnd: end, fiscalYear: fiscalYear, fiscalPeriod: fiscalPeriod,
            unit: unit, value: value, sourceValue: reportedValue, derivation: .reported,
            sourceFactIDs: [sourceCellID], sourceVersions: [sourceHash], accessionNumbers: [],
            dictionaryVersion: OfflineIssuerResearchContext.mappingVersion, availableAt: available,
            confidence: .medium, limitations: OfflineIssuerResearchContext.factLimitations)
    }
    public func convertedValue() throws -> Money {
        guard issuerText(reportedValue, maximum: 128), issuerText(decimalValue, maximum: 128),
              issuerText(reportedScale, maximum: 64) else { throw OfflineIssuerResearchError.invalidExcerpt }
        let scale = try Money(reportedScale)
        guard scale.amount > 0 else { throw OfflineIssuerResearchError.inconsistentEvidence }
        var text = reportedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        // The reviewed MSFT tables retain a leading dollar label. Accept that one
        // presentation marker only for dollar units; other symbols remain invalid.
        if text.hasPrefix("$") {
            guard ["USD", "USD/shares"].contains(unit) else { throw OfflineIssuerResearchError.inconsistentEvidence }
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let dash = ["—", "–", "-"].contains(text)
        if dash {
            guard signConvention == "explicit-dash-zero-supported-by-no-preferred-issued" else {
                throw OfflineIssuerResearchError.inconsistentEvidence
            }
            text = "0"
        }
        else {
            guard text.range(of: #"^(?:-?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?|\((?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?\))\z"#,
                             options: .regularExpression) != nil else { throw OfflineIssuerResearchError.invalidExcerpt }
            if text.hasPrefix("(") { text = "-" + text.dropFirst().dropLast() }
            text = text.replacingOccurrences(of: ",", with: "")
        }
        let displayed = try Money(text)
        var transformed = displayed
        switch signConvention {
        // These legacy labels mean no sign transform. "reported-positive" also accompanies
        // an explicitly negative tax benefit in the reviewed excerpt; the display wins.
        case "reported-positive", "reported-signed", "reported-value", "iXBRL-sign-and-scale": break
        case "cash-outflow-magnitude", "cash-outflow-display-negative-to-positive-expenditure":
            guard fieldID.hasPrefix("cash-flow.") else { throw OfflineIssuerResearchError.unsupportedMapping }
            if displayed.amount < 0 { transformed = try displayed.multiplied(by: "-1") }
        case "cash-outflow-sign-inverted", "negative-interest-expense-inverted":
            guard displayed.amount <= 0,
                  signConvention == "cash-outflow-sign-inverted" ? fieldID.hasPrefix("cash-flow.")
                    : fieldID == "income.interest"
            else { throw OfflineIssuerResearchError.unsupportedMapping }
            transformed = try displayed.multiplied(by: "-1")
        case "negative-expense-presentation-inverted":
            // A tax benefit is a positive source-table credit and a negative tax
            // expense. This rule reverses that sign as well; it never takes abs().
            guard ["income.interest", "income.tax"].contains(fieldID),
                  displayed.amount <= 0 || fieldID == "income.tax" else {
                throw OfflineIssuerResearchError.unsupportedMapping
            }
            transformed = try displayed.multiplied(by: "-1")
        case "explicit-dash-zero-supported-by-no-preferred-issued":
            guard displayed.amount == 0, fieldID == "balance.preferred-equity" else {
                throw OfflineIssuerResearchError.inconsistentEvidence
            }
        default: throw OfflineIssuerResearchError.unsupportedMapping
        }
        let result = try transformed.multiplied(by: scale.decimalString)
        guard result == (try Money(decimalValue)) else { throw OfflineIssuerResearchError.inconsistentEvidence }
        return result
    }
}

public struct OfflineIssuerEvidenceReference: Sendable, Decodable {
    public let sourceHash, sourceURL, observedAt, sourceLocator, evidence: String
}

/// Projection of the fixed manual-excerpt profile. Auxiliary disclosures, mapping notes and
/// independent test oracles remain in the exact excerptData but never enter this calculation API.
public struct OfflineIssuerResearchContext: Sendable, Decodable {
    public static let mappingVersion = "issuer-completion.manual.v1"
    public static let factLimitations = ["MANUAL_ISSUER_TABLE_MAPPING", "RETRIEVAL_ONLY_NOT_HISTORICAL_PIT"]
    public static let requiredLimitations = ["OFFLINE_MANUAL_EXCERPT_RESEARCH_ONLY", "NO_PROVIDER_ADMISSION",
        "NO_HISTORICAL_PIT", "NO_MARKET_PRICE_OR_CAPITAL_INPUT", "REFERENCED_ORIGINAL_DOCUMENTS_NOT_EMBEDDED"]
    public struct Window: Sendable, Decodable { public let start, end: String }
    public let ticker, cik: String
    public let financialCompany: Bool
    public let quarters, fiscalYears: [Window]
    public let revenueYears: [Window]?
    public let facts: [OfflineIssuerFact]
    public let expectedClassIDs, knownMissing: [String]
    public let splitBasisEvidence: String?
    public let splitBasisSources: [OfflineIssuerEvidenceReference]?

    public static func decode(excerptData: Data) throws -> Self {
        guard !excerptData.isEmpty, excerptData.count <= 8 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: excerptData) as? [String: Any]
        else { throw OfflineIssuerResearchError.invalidExcerpt }
        let fields: Set<String> = ["ticker", "cik", "financialCompany", "quarters", "fiscalYears", "revenueYears", "facts",
            "expectedClassIDs", "knownMissing", "splitBasisEvidence", "splitBasisSources", "auxiliaryEvidence",
            "evidencePolicy", "mappingEvidenceNotes"]
        guard object.keys.allSatisfy({ fields.contains($0) || $0.hasPrefix("expected") }),
              let rows = object["facts"] as? [[String: Any]] else { throw OfflineIssuerResearchError.invalidExcerpt }
        let factFields: Set<String> = ["fieldID", "statement", "periodType", "nature", "unit", "start", "end", "fiscalYear",
            "fiscalPeriod", "decimalValue", "reportedValue", "reportedScale", "signConvention", "sourceHash", "sourceURL",
            "observedAt", "sourceLocator", "concept", "id", "sourceRow", "reportedLabel", "acceptedAt"]
        for row in rows {
            guard Set(row.keys).isSubset(of: factFields), row["acceptedAt"] == nil || row["acceptedAt"] is NSNull else {
                throw OfflineIssuerResearchError.invalidExcerpt
            }
        }
        let context = try JSONDecoder().decode(Self.self, from: excerptData)
        try context.validate()
        return context
    }
    public func validate() throws {
        let identities = ["AAPL":"0000320193", "MSFT":"0000789019", "META":"0001326801", "AMZN":"0001018724",
            "NVDA":"0001045810", "COST":"0000909832", "WMT":"0000104169", "KO":"0000021344",
            "JPM":"0000019617", "BRK.B":"0001067983"]
        guard identities[ticker] == cik, financialCompany == ["JPM", "BRK.B"].contains(ticker),
              (4...8).contains(quarters.count), (1...3).contains(fiscalYears.count),
              (1...6).contains((revenueYears ?? fiscalYears).count), (1...10_000).contains(facts.count),
              !expectedClassIDs.isEmpty, expectedClassIDs.count <= 8,
              Set(expectedClassIDs).count == expectedClassIDs.count,
              expectedClassIDs.allSatisfy({ issuerText($0, maximum: 64) }),
              !knownMissing.isEmpty, knownMissing.count <= 256,
              knownMissing.allSatisfy({ issuerText($0, maximum: 4_096) }) else { throw OfflineIssuerResearchError.invalidExcerpt }
        let physicalCells = facts.map { [$0.sourceHash, $0.sourceLocator, $0.start ?? "instant", $0.end].joined(separator: "/") }
        guard Set(physicalCells).count == facts.count else { throw OfflineIssuerResearchError.inconsistentEvidence }
        for fact in facts { _ = try fact.reported(cik: cik) }
        for group in Dictionary(grouping: facts, by: \.fieldID).values {
            let first = group[0]
            guard group.allSatisfy({ $0.nature == first.nature && $0.unit == first.unit && $0.statement == first.statement }) else {
                throw OfflineIssuerResearchError.unsupportedMapping
            }
        }
        if let evidence = splitBasisEvidence {
            guard ticker == "WMT", issuerText(evidence, maximum: 4_096), let sources = splitBasisSources, sources.count == 5,
                  Set(sources.map(\.sourceHash)) == Set(facts.map(\.sourceHash)) else { throw OfflineIssuerResearchError.inconsistentEvidence }
            for source in sources {
                try issuerSource(hash: source.sourceHash, url: source.sourceURL, locator: source.sourceLocator)
                let acquired = try issuerDate(source.observedAt)
                guard issuerText(source.evidence, maximum: 4_096),
                      facts.contains(where: { $0.sourceHash == source.sourceHash && $0.sourceURL == source.sourceURL
                          && (try? issuerDate($0.observedAt)) == acquired }) else { throw OfflineIssuerResearchError.inconsistentEvidence }
            }
        } else if let sources = splitBasisSources, !sources.isEmpty { throw OfflineIssuerResearchError.inconsistentEvidence }
    }
    public func input(asOf: Date) throws -> FundamentalCompletionInput {
        try validate()
        _ = try MillisecondInstant(rounding: asOf)
        let original = try facts.map { try $0.reported(cik: cik) }
        guard original.allSatisfy({ $0.availableAt <= asOf }) else { throw OfflineIssuerResearchError.inconsistentEvidence }
        let bridge = try FinancialNormalizer.discreteQuarters(from: original)
        let ttm = try FinancialNormalizer.trailingTwelveMonths(from: bridge.values)
        let normalized = FinancialNormalizationResult(asOf: asOf, dictionaryVersion: Self.mappingVersion,
            values: original + bridge.values.filter { $0.derivation != .reported } + ttm.values,
            issues: bridge.issues + ttm.issues, selectedSourceFacts: [], unmappedSourceFacts: [])
        let q = try quarters.map { try FiscalQuarter(start: MarketDate(iso8601: $0.start), end: MarketDate(iso8601: $0.end)) }
        let years = try fiscalYears.map { try FiscalYearWindow(start: MarketDate(iso8601: $0.start), end: MarketDate(iso8601: $0.end)) }
        let input = try FundamentalInput(cik: cik, normalization: normalized, quarters: q, fiscalYears: years,
            priceDay: q.last!.end, expectedClassIDs: Set(expectedClassIDs), classes: [], financialCompany: financialCompany,
            splitBasisEvidence: splitBasisEvidence, inputLimitations: knownMissing + Self.requiredLimitations)
        return try .init(financials: input, revenueYears: (revenueYears ?? fiscalYears).map {
            try FiscalYearWindow(start: MarketDate(iso8601: $0.start), end: MarketDate(iso8601: $0.end))
        })
    }
}

func issuerText(_ value: String, maximum: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum
        && !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 })
}
func issuerDate(_ value: String) throws -> Date {
    // ISO8601DateFormatter's fractional mode can truncate to milliseconds. Preserve the
    // original string and add its independent fraction to an exact integral-second parse.
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z"#,
                      options: .regularExpression) != nil else { throw OfflineIssuerResearchError.invalidExcerpt }
    _ = try MarketDate(iso8601: String(value.prefix(10)))
    let clock = String(value.dropFirst(11).prefix(8)).split(separator: ":").compactMap { Int($0) }
    guard clock.count == 3, clock[0] < 24, clock[1] < 60, clock[2] < 60 else {
        throw OfflineIssuerResearchError.invalidExcerpt
    }
    let suffix = String(value.dropFirst(19))
    let zone = suffix.hasSuffix("Z") ? "Z" : String(suffix.suffix(6))
    if zone != "Z" {
        let fields = zone.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard fields.count == 2, fields[0] < 24, fields[1] < 60 else { throw OfflineIssuerResearchError.invalidExcerpt }
    }
    let fractionText = String(suffix.dropLast(zone.count))
    let fraction: Double
    if fractionText.isEmpty { fraction = 0 }
    else {
        guard let parsed = Double("0" + fractionText), parsed >= 0, parsed < 1 else {
            throw OfflineIssuerResearchError.invalidExcerpt
        }
        fraction = parsed
    }
    let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime]
    guard let whole = parser.date(from: String(value.prefix(19)) + zone) else { throw OfflineIssuerResearchError.invalidExcerpt }
    let date = whole.addingTimeInterval(fraction)
    _ = try MillisecondInstant(rounding: date)
    return date
}
func issuerSource(hash: String, url: String, locator: String) throws {
    guard hash.range(of: #"^[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
          issuerText(locator, maximum: 4_096), url.utf8.count <= 4_096,
          let parts = URLComponents(string: url), parts.scheme == "https", parts.host?.isEmpty == false,
          parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
          parts.port == nil || parts.port == 443 else { throw OfflineIssuerResearchError.inconsistentEvidence }
}
