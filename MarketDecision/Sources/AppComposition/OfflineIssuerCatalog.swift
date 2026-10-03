import Foundation
import FundamentalsEngine

public enum OfflineIssuerCatalogError: Error, Equatable, Sendable {
    case invalidResource, unknownTicker
}

/// Reviewed manual excerpts available without networking. This separate runtime resource
/// contains factual inputs and limitations, never the independent test answers.
public struct OfflineIssuerCatalog: Sendable {
    public struct Entry: Sendable, Identifiable {
        public let ticker: String
        public let cik: String
        public var id: String { ticker }
    }

    public let entries: [Entry]
    private let excerpts: [String: Data]
    private static let tickers: Set<String> = ["AAPL", "MSFT", "META", "AMZN", "NVDA", "COST", "WMT", "KO", "JPM", "BRK.B"]

    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "offline-issuer-excerpts", withExtension: "json") else {
            throw OfflineIssuerCatalogError.invalidResource
        }
        return try Self(data: Data(contentsOf: url))
    }

    public func excerpt(for ticker: String) throws -> Data {
        guard let data = excerpts[ticker] else { throw OfflineIssuerCatalogError.unknownTicker }
        return data
    }

    // Kept internal: this is a fixed bundled catalogue, not an external-file admission API.
    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 24 * 1_024 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["format", "provenancePolicy", "issuers"],
              root["format"] as? String == "offline-issuer-excerpts.v1",
              let policy = root["provenancePolicy"] as? String, !policy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let issuers = root["issuers"] as? [[String: Any]], issuers.count == Self.tickers.count,
              !Self.containsTestAnswers(root) else { throw OfflineIssuerCatalogError.invalidResource }
        var entries: [Entry] = [], excerpts: [String: Data] = [:]
        for issuer in issuers {
            let bytes = try JSONSerialization.data(withJSONObject: issuer, options: [.sortedKeys, .withoutEscapingSlashes])
            let context = try OfflineIssuerResearchContext.decode(excerptData: bytes)
            guard Self.tickers.contains(context.ticker), excerpts[context.ticker] == nil else {
                throw OfflineIssuerCatalogError.invalidResource
            }
            entries.append(Entry(ticker: context.ticker, cik: context.cik))
            excerpts[context.ticker] = bytes
        }
        guard Set(excerpts.keys) == Self.tickers else { throw OfflineIssuerCatalogError.invalidResource }
        self.entries = entries; self.excerpts = excerpts
    }

    private static func containsTestAnswers(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object.contains { key, child in
                (key.hasPrefix("expected") && key != "expectedClassIDs") || containsTestAnswers(child)
            }
        }
        if let array = value as? [Any] { return array.contains(where: containsTestAnswers) }
        return false
    }
}
