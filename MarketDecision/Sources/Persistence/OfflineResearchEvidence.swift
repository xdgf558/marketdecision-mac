import Foundation
import CoreDomain
import DataContracts
import FundamentalsEngine

public enum ResearchEvidenceGap: String, Sendable, Codable, Hashable {
    case missingIdentity
    case missingFinancialFacts
    case unmappedFinancialFacts
    case missingDailyBar
    case unqualifiedDailyBar
    case missingCapitalAndSplitBasis
    case supplierAndLicenseNotQualified
    case modelCalibrationNotApproved
}

/// A replayable inspection of locally stored source evidence. It is intentionally not a
/// ResearchDocument, valuation, supplier qualification, or live-analysis permission.
public struct OfflineResearchEvidence: Sendable, Codable {
    public let symbol: String
    public let cutoff: MillisecondInstant
    public let storeRevision: UUID
    public let identity: SECCompanyIdentityRecord?
    public let normalization: FinancialNormalizationResult?
    public let dailyBarCount: Int
    public let sourceHashes: [String: String]
    public let gaps: [ResearchEvidenceGap]
    public var mayRunValuation: Bool { false }
}

public struct OfflineResearchEvidenceReader: Sendable {
    public let store: BusinessDataStore
    public init(store: BusinessDataStore) { self.store = store }

    /// Reads only records with independent availability by `cutoff`; the daily bars are
    /// inventoried but never used as PIT or qualified current prices. No network is invoked.
    public func inspect(symbol: String, cutoff: Date, barWindow: DateRange,
                        dictionary: FinancialFieldDictionary) async throws -> OfflineResearchEvidence {
        try EquityRecord.validateSymbol(symbol)
        try barWindow.validate()
        let instant = try MillisecondInstant(rounding: cutoff)
        guard barWindow.end <= instant.date else { throw ContractError.invalidRange }
        let revision = await store.revision()
        let identity: SECCompanyIdentityRecord?
        do { identity = try await store.secIdentity(ticker: symbol, asOf: instant.date) }
        catch SnapshotError.missingReference { identity = nil }

        let normalization: FinancialNormalizationResult?
        if let identity {
            let facts = try await store.secFactVersions(cik: identity.cik, asOf: instant.date)
            normalization = try FinancialNormalizer.normalizeComplete(facts, dictionary: dictionary, asOf: instant.date)
        } else { normalization = nil }
        let bars = try await store.equityRecords(symbol: symbol, kind: .dailyBar, range: barWindow)

        // The row joins check source metadata; read each original blob as well so this report
        // cannot cite a hash whose source payload is absent or damaged in the current store.
        var sourceHashes: [String: String] = [:]
        var provenance = identity.map { [$0.provenance] } ?? []
        provenance += normalization?.selectedSourceFacts.map(\.provenance) ?? []
        provenance += bars.map(\.provenance)
        for item in provenance {
            try Task.checkCancellation()
            guard let reference = item.rawObjectRef, let expectedHash = item.rawHash else {
                throw BusinessStoreError.corruptedStorage
            }
            if let old = sourceHashes[reference] {
                guard old == expectedHash else { throw BusinessStoreError.corruptedStorage }
                continue
            }
            let source = try await store.sourceDocument(reference: reference)
            guard source.contentHash == expectedHash, source.providerID == item.providerID,
                  source.feedID == item.feedID, source.endpoint.rawValue == item.endpointDescriptor,
                  source.evidenceRef == item.evidenceRef, source.licenseRef == item.licenseRef else {
                throw BusinessStoreError.corruptedStorage
            }
            sourceHashes[reference] = expectedHash
        }
        guard await store.revision() == revision else { throw SnapshotError.stalePlan }

        var gaps: [ResearchEvidenceGap] = []
        if identity == nil { gaps.append(.missingIdentity) }
        if normalization?.values.isEmpty ?? true { gaps.append(.missingFinancialFacts) }
        if normalization?.unmappedSourceFacts.isEmpty == false { gaps.append(.unmappedFinancialFacts) }
        if bars.isEmpty { gaps.append(.missingDailyBar) }
        else { gaps.append(.unqualifiedDailyBar) }
        gaps += [.missingCapitalAndSplitBasis, .supplierAndLicenseNotQualified,
                 .modelCalibrationNotApproved]
        return OfflineResearchEvidence(symbol: symbol, cutoff: instant, storeRevision: revision,
            identity: identity, normalization: normalization, dailyBarCount: bars.count,
            sourceHashes: sourceHashes, gaps: gaps)
    }
}
