import Foundation
import CoreDomain

/// Foundation subset of DC-002/003; no general historical-fill/PIT qualification is inferred.
public struct Quote: Sendable, ProviderRecord {
    public var recordID: String { symbol }
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
    public func eligibility(for usage: Usage, at now: Date, entitlement: EntitlementSnapshot? = nil) -> Result<Void, UnavailableReason> {
        guard !quality.contains(.synthetic) else { return .failure(.syntheticData) }
        guard usage == .liveAnalysis, qualifiedUsages.contains(usage) else { return .failure(.unqualifiedUsage) }
        guard (try? provenance.validate()) != nil else { return .failure(.incompleteProvenance) }
        guard let entitlement, entitlement.capabilities.contains(.quote), entitlement.licenseRef == provenance.licenseRef,
              entitlement.permits(provider: provenance.providerID, feed: provenance.feedID, usage: usage, at: now)
        else { return .failure(.notEntitled) }
        guard timeliness == .realtime, !quality.contains(.indicative) else { return .failure(.unsuitableTier) }
        guard !quality.contains(.missing), !quality.contains(.invalid), bid.amount >= 0, ask.amount > 0, bid.amount <= ask.amount else { return .failure(.invalidQuote) }
        guard finite(now), provenance.receivedAt <= now else { return .failure(.invalidTime) }
        guard let source = provenance.sourceEventAt else { return .failure(.missingSourceTime) }
        let age = now.timeIntervalSince(source)
        guard age >= 0 else { return .failure(.futureSourceTime) }
        guard age <= FreshnessPolicy.foundationV1.realtimeMaxAge, !quality.contains(.stale) else { return .failure(.staleQuote) }
        return .success(())
    }
    /// A compatibility display label only. Never use it to authorize an analysis.
    public var legacyDataTier: LegacyDataTier {
        if quality.contains(.stale) { return .stale }
        switch provenance.origin {
        case .derived: return .derived
        case .userImport: return .userImport
        case .filing: return .filing
        case .provider:
            switch timeliness {
            case .realtime: return .realtime
            case .delayed: return .delayed
            case .endOfDay: return .endOfDay
            case .notApplicable, .unknown: return .unknown
            }
        }
    }
}
