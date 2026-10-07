import Foundation
import CoreFoundation
import CoreDomain
import DataContracts
import FundamentalsEngine

/// A separately frozen calculation, bound to the exact original SEC acquisition bytes.
/// It does not mutate the acquisition, grant prices/industry eligibility, or form a backup.
public struct SECFinancialReportDocument: Sendable, Codable, Identifiable {
    public let format: String
    public let id: UUID
    public let parentDocumentID: UUID
    public let parentDocumentHash: String
    public let ticker: String
    public let companyName: String
    public let cutoff: Date
    public let createdAt: Date
    public let financials: SECFinancialReport
    public var mayRunValuation: Bool { false }

    static func make(parent: SECResearchDocument, parentBytes: Data,
                     executionDate: Date) async throws -> Self {
        try parent.validate()
        try Task.checkCancellation()
        let financials = try await SECFinancialReport.make(cik: parent.identity.cik,
            facts: parent.facts, submissions: parent.submissions, cutoff: parent.cutoff,
            executionDate: executionDate, classification: observedClassification(parent))
        try Task.checkCancellation()
        let result = Self(format: "sec-financial-report.v1", id: UUID(), parentDocumentID: parent.id,
            parentDocumentHash: digest(parentBytes), ticker: parent.ticker, companyName: parent.identity.name,
            cutoff: parent.cutoff, createdAt: executionDate, financials: financials)
        try result.validate(parent: parent, parentBytes: parentBytes)
        return result
    }

    /// Structural validation does not verify cached metric values. Display after opening
    /// additionally requires explicit recomputation against the frozen calculation context.
    public func validate() throws {
        try EquityRecord.validateSymbol(ticker)
        guard format == "sec-financial-report.v1", !companyName.isEmpty,
              cutoff.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite, cutoff <= createdAt,
              parentDocumentHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              financials.evidence.cutoff == cutoff,
              financials.inputSnapshot.financials.executionDate == createdAt
        else { throw SECFinancialError.inconsistentEvidence }
        try financials.validate()
    }

    /// Rebuild the adapter context from ALL retained parent facts, so omitting a newer
    /// revision or a conflicting alias cannot turn an incomplete report into a valid one.
    func validate(parent: SECResearchDocument, parentBytes: Data) throws {
        try validate()
        guard parent.id == parentDocumentID, parent.ticker == ticker,
              parent.identity.name == companyName, parent.identity.cik == financials.evidence.cik,
              parent.cutoff == cutoff, digest(parentBytes) == parentDocumentHash
        else { throw SECFinancialError.inconsistentEvidence }
        try financials.validateEvidence(facts: parent.facts, submissions: parent.submissions,
                                       classification: Self.observedClassification(parent))
    }

    /// The root submissions response carries observed SIC. It is retained only as source
    /// metadata: this policy does not classify an issuer as financial or non-financial.
    static func observedClassification(_ parent: SECResearchDocument) throws -> SECFinancialClassificationEvidence? {
        let roots = parent.sources.filter {
            $0.endpoint == .submissions && $0.request.pageToken == nil && $0.request.resourceID == parent.identity.cik
        }
        guard roots.count <= 1 else { throw SECFinancialError.inconsistentEvidence }
        guard let root = roots.first else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: root.bytes) as? [String: Any] else {
            throw SECFinancialError.inconsistentEvidence
        }
        guard let raw = object["sic"] else { return nil }
        let text: String
        if let value = raw as? String { text = value }
        else if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { text = value.stringValue }
        else { return nil }
        guard text.range(of: #"^[0-9]{3,4}$"#, options: .regularExpression) != nil,
              let sic = Int(text), (100...9999).contains(sic) else { return nil }
        return try .init(sic: sic, sourceReference: root.reference,
                         sourceVersion: "sha256:" + root.contentHash, sourceHash: root.contentHash)
    }
}
