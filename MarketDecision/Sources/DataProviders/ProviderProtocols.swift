import Foundation
import DataContracts

public protocol ProviderIdentity: Sendable {
    var id: String { get }
    var capabilitySnapshot: CapabilitySnapshot { get }
}
/// Payload associated types are deliberately completed by their owning business phases.
/// Every payload must expose item-level provenance; option chains must embed an underlying quote.
public protocol MarketDataProvider: ProviderIdentity {
    associatedtype Bar: ProviderRecord
    associatedtype Expiration: ProviderRecord
    associatedtype Chain: OptionChainRecord
    func quote(request: ProviderRequest) async throws -> ProviderResult<Quote>
    func bars(request: ProviderRequest) async throws -> ProviderResult<Bar>
    func optionExpirations(request: ProviderRequest) async throws -> ProviderResult<Expiration>
    func optionChain(request: ProviderRequest) async throws -> ProviderResult<Chain>
}
public protocol FundamentalsProvider: ProviderIdentity {
    associatedtype Identity: ProviderRecord
    associatedtype Submission: ProviderRecord
    associatedtype Facts: ProviderRecord
    func companyIdentity(request: ProviderRequest) async throws -> ProviderResult<Identity>
    func submissions(request: ProviderRequest) async throws -> ProviderResult<Submission>
    func companyFacts(request: ProviderRequest) async throws -> ProviderResult<Facts>
}
public protocol MacroDataProvider: ProviderIdentity {
    var supportsVintages: Bool { get }
    func series(request: ProviderRequest) async throws -> ProviderResult<NumericObservation>
}
public protocol LedgerValuationProvider: ProviderIdentity {
    associatedtype Mark: ProviderRecord
    func marks(request: ProviderRequest) async throws -> ProviderResult<Mark>
}
/// No importer or write implementation is included in the foundation contracts.
public struct ImportPreviewToken: Sendable, Equatable {
    public let id: UUID, baseRevision: UUID
    public let contentHash: String, mappingVersion: String
    public init(id: UUID, baseRevision: UUID, contentHash: String, mappingVersion: String) {
        self.id = id; self.baseRevision = baseRevision; self.contentHash = contentHash; self.mappingVersion = mappingVersion
    }
    public func validate(expectedRevision: UUID, expectedHash: String) throws {
        guard baseRevision == expectedRevision, contentHash == expectedHash,
              contentHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !mappingVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContractError.mismatchedRequest }
    }
}
public protocol BrokerImportAdapter: Sendable {
    associatedtype Detection: Sendable
    associatedtype Preview: Sendable
    associatedtype Batch: Sendable
    func detect(file: URL) async throws -> Detection
    func preview(file: URL, mappingVersion: String) async throws -> (Preview, ImportPreviewToken)
    func commit(preview: Preview, token: ImportPreviewToken, expectedBaseRevision: UUID, expectedHash: String) async throws -> Batch
}
