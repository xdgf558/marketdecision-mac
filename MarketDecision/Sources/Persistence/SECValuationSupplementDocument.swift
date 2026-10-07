import Foundation
import CoreDomain
import DataContracts
import FundamentalsEngine

/// Independent immutable calculation supplement. Both retained parent encodings are
/// bound byte-for-byte; the original accounting report and SEC responses never change.
public struct SECValuationSupplementDocument: Sendable, Codable, Identifiable {
    public let format: String
    public let id: UUID
    public let parentFinancialReportID: UUID
    public let parentFinancialReportHash: String
    public let parentResearchID: UUID
    public let parentResearchHash: String
    public let ticker: String
    public let companyName: String
    public let cutoff: Date
    public let createdAt: Date
    public let valuation: SECValuationReport

    static func make(parent: SECFinancialReportDocument, parentBytes: Data,
                     research: SECResearchDocument, researchBytes: Data,
                     evidence: SECValuationInputEvidence, executionDate: Date) async throws -> Self {
        try parent.validate(parent: research, parentBytes: researchBytes)
        try Task.checkCancellation()
        let valuation = try await SECValuationReport.make(accounting: parent.financials, evidence: evidence,
            sources: sourceMaterials(research), executionDate: executionDate)
        try Task.checkCancellation()
        let result = Self(format: "sec-valuation-supplement.v1", id: UUID(), parentFinancialReportID: parent.id,
            parentFinancialReportHash: digest(parentBytes), parentResearchID: research.id,
            parentResearchHash: digest(researchBytes), ticker: parent.ticker, companyName: parent.companyName,
            cutoff: parent.cutoff, createdAt: executionDate, valuation: valuation)
        try result.validate(parent: parent, parentBytes: parentBytes, research: research, researchBytes: researchBytes)
        return result
    }

    /// Structural checking does not verify cached values. Every reopened supplement
    /// requires explicit formula replay before its result values may be displayed.
    public func validate() throws {
        try EquityRecord.validateSymbol(ticker)
        guard format == "sec-valuation-supplement.v1", !companyName.isEmpty,
              cutoff.timeIntervalSinceReferenceDate.isFinite, createdAt.timeIntervalSinceReferenceDate.isFinite,
              cutoff <= createdAt, valuation.cutoff == cutoff, valuation.executionDate == createdAt,
              [parentFinancialReportHash, parentResearchHash].allSatisfy({
                  $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
              }) else { throw SECFinancialError.inconsistentEvidence }
        try valuation.validate()
    }

    func validate(parent: SECFinancialReportDocument, parentBytes: Data,
                  research: SECResearchDocument, researchBytes: Data) throws {
        try validate()
        try parent.validate(parent: research, parentBytes: researchBytes)
        guard parent.id == parentFinancialReportID, digest(parentBytes) == parentFinancialReportHash,
              research.id == parentResearchID, parent.parentDocumentID == parentResearchID,
              digest(researchBytes) == parentResearchHash, parent.parentDocumentHash == parentResearchHash,
              parent.ticker == ticker, parent.companyName == companyName, parent.cutoff == cutoff,
              parent.createdAt <= createdAt else { throw SECFinancialError.inconsistentEvidence }
        try valuation.validateAccounting(parent.financials)
        try valuation.validateSources(Self.sourceMaterials(research))
    }

    private static func sourceMaterials(_ research: SECResearchDocument) throws -> [SECValuationSourceMaterial] {
        try research.sources.map { try .init(reference: $0.reference, contentHash: $0.contentHash, bytes: $0.bytes) }
    }
}
