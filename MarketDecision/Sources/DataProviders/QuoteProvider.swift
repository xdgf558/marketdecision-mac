import Foundation
import CoreDomain
import DataContracts

public protocol QuoteProvider: Sendable {
    var id: String { get }
    func quote(for symbol: String) async throws -> Quote
}
public enum ProviderError: Error { case symbolUnavailable }
/// Deterministic fixture. Never a real feed or a source of qualified analysis inputs.
public struct MockQuoteProvider: QuoteProvider {
    public let id = "mock.synthetic.v1"
    public init() {}
    public func quote(for symbol: String) async throws -> Quote {
        try Task.checkCancellation()
        guard symbol == "DEMO" else { throw ProviderError.symbolUnavailable }
        let instant = Date(timeIntervalSince1970: 1_783_000_000)
        return Quote(symbol: symbol, bid: try Money("99.50"), ask: try Money("100.50"),
                     provenance: Provenance(providerID: id, feedID: "synthetic", sourceEventAt: instant, receivedAt: instant, availableAt: nil, evidenceRef: nil, origin: .derived),
                     timeliness: .unknown, quality: [.synthetic])
    }
}
