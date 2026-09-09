import Foundation
import CoreDomain

public enum OriginKind: String, Sendable, Codable { case provider, filing, userImport, derived }
public enum Timeliness: String, Sendable, Codable { case realtime, delayed, endOfDay, notApplicable, unknown }
public enum QualityFlag: String, Sendable, Codable { case stale, missing, invalid, indicative, synthetic, modelDifference }
public enum Usage: String, Sendable, Codable { case liveAnalysis, ledgerMark, historicalFill, pitResearch, replay }
public enum UnavailableReason: String, Error, Sendable { case syntheticData, unsuitableTier, invalidQuote, missingSourceTime, futureSourceTime, staleQuote, unqualifiedUsage }
public struct Provenance: Sendable {
    public let providerID: String
    public let feedID: String
    public let sourceEventAt: Date?
    public let receivedAt: Date
    public let availableAt: Date?
    public let evidenceRef: String?
    public let origin: OriginKind
    public init(providerID: String, feedID: String, sourceEventAt: Date?, receivedAt: Date, availableAt: Date?, evidenceRef: String?, origin: OriginKind) {
        self.providerID = providerID; self.feedID = feedID; self.sourceEventAt = sourceEventAt; self.receivedAt = receivedAt
        self.availableAt = availableAt; self.evidenceRef = evidenceRef; self.origin = origin
    }
}
/// Foundation subset of DC-002/003; no general historical-fill/PIT qualification is inferred.
public struct Quote: Sendable {
    public let symbol: String
    public let bid: Money
    public let ask: Money
    public let provenance: Provenance
    public let timeliness: Timeliness
    public let quality: Set<QualityFlag>
    public let qualifiedUsages: Set<Usage>
    public init(symbol: String, bid: Money, ask: Money, provenance: Provenance, timeliness: Timeliness, quality: Set<QualityFlag>, qualifiedUsages: Set<Usage> = []) {
        self.symbol = symbol; self.bid = bid; self.ask = ask; self.provenance = provenance; self.timeliness = timeliness; self.quality = quality; self.qualifiedUsages = qualifiedUsages
    }
    public func eligibility(for usage: Usage, at now: Date) -> Result<Void, UnavailableReason> {
        guard !quality.contains(.synthetic) else { return .failure(.syntheticData) }
        guard usage == .liveAnalysis, qualifiedUsages.contains(usage),
              !provenance.providerID.isEmpty, !provenance.feedID.isEmpty, provenance.evidenceRef != nil
        else { return .failure(.unqualifiedUsage) }
        guard timeliness == .realtime, !quality.contains(.indicative) else { return .failure(.unsuitableTier) }
        guard !quality.contains(.missing), !quality.contains(.invalid), bid.amount >= 0, ask.amount > 0, bid.amount <= ask.amount else { return .failure(.invalidQuote) }
        guard let source = provenance.sourceEventAt else { return .failure(.missingSourceTime) }
        let age = now.timeIntervalSince(source)
        guard age >= 0 else { return .failure(.futureSourceTime) }
        guard age <= 60, !quality.contains(.stale) else { return .failure(.staleQuote) }
        return .success(())
    }
}
