import Foundation
import CoreDomain
import DataContracts

/// Source selection retains only the original response bytes and their parent binding.
/// The store validates the complete parent chain before constructing this projection.
/// This is neither a saved research document nor permission to skip that validation
/// when preparing, saving or reopening a calculation.
public struct SECValuationSourceDocument: Sendable, Identifiable {
    public let id: UUID
    public let ticker: String
    public let cutoff: Date
    public let parentResearchHash: String
    public let sources: [SECResearchSource]

    init(validatedResearch: SECResearchDocument, originalHash: String) throws {
        id = validatedResearch.id
        ticker = validatedResearch.ticker
        cutoff = validatedResearch.cutoff
        parentResearchHash = originalHash
        sources = validatedResearch.sources
        try validate()
    }

    /// Checks the projection's own fields and exact source bytes. It does not claim
    /// to revalidate facts that this deliberately smaller value does not retain.
    public func validate() throws {
        try EquityRecord.validateSymbol(ticker)
        guard cutoff.timeIntervalSinceReferenceDate.isFinite,
              parentResearchHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              !sources.isEmpty, sources.count <= 40,
              Set(sources.map(\.reference)).count == sources.count
        else { throw SECResearchError.invalidDocument }
        var byteCount = 0
        for source in sources {
            guard source.bytes.count <= 128 * 1024 * 1024 - byteCount,
                  source.receivedAt <= cutoff else { throw SECResearchError.invalidDocument }
            byteCount += source.bytes.count
            try source.validate()
        }
    }
}
