import Foundation
import DataContracts
import DataProviders

/// One accepted page and its atomic raw/typed persistence result. A stored page is not a
/// complete history, a licensed analysis feed, or a qualified price for valuation.
public struct AcquisitionPageReceipt: Sendable {
    public let capability: ProviderCapability
    public let status: ProviderResultStatus
    public let itemCount: Int
    public let nextPageToken: String?
    public let insertedDocuments: Int
    public let insertedRecords: Int
    public let revision: UUID

    init(capability: ProviderCapability, status: ProviderResultStatus, itemCount: Int,
         nextPageToken: String?, insertedDocuments: Int, insertedRecords: Int, revision: UUID) {
        self.capability = capability; self.status = status; self.itemCount = itemCount
        self.nextPageToken = nextPageToken; self.insertedDocuments = insertedDocuments
        self.insertedRecords = insertedRecords; self.revision = revision
    }
}

/// Pins the store revision before dispatch. A destructive restore or concurrent writer may
/// invalidate the request while it is in flight; it cannot silently acquire a new baseline.
/// No production transport or entitlement is constructed by this pipeline.
public struct SECAcquisitionPipeline<Provider: FundamentalsProvider>: Sendable
where Provider.Identity == SECCompanyIdentityRecord,
      Provider.Submission == SECSubmissionRecord,
      Provider.Facts == SECCompanyFactRecord,
      Provider.FilingIndex == SECFilingIndexRecord,
      Provider.FilingDocument == SECFilingDocumentRecord {
    public let client: FundamentalsDataClient<Provider>
    public let store: BusinessDataStore

    public init(client: FundamentalsDataClient<Provider>, store: BusinessDataStore) {
        self.client = client; self.store = store
    }

    /// Handles exactly one requested page. A continuation is returned explicitly and must be
    /// requested with a new pinned revision; PARTIAL never becomes COMPLETE by assumption.
    public func ingest(_ request: ProviderRequest) async throws -> AcquisitionPageReceipt {
        try Task.checkCancellation()
        let revision = await store.revision()
        switch request.capability {
        case .companyIdentity:
            let accepted = try await client.companyIdentity(request)
            try Task.checkCancellation()
            let receipt = try await store.ingestSECIdentities(accepted, expectedRevision: revision)
            return page(accepted, receipt)
        case .submissions:
            let accepted = try await client.submissions(request)
            try Task.checkCancellation()
            let receipt = try await store.ingestSECSubmissions(accepted, expectedRevision: revision)
            return page(accepted, receipt)
        case .companyFacts:
            let accepted = try await client.companyFacts(request)
            try Task.checkCancellation()
            let receipt = try await store.ingestSECCompanyFacts(accepted, expectedRevision: revision)
            return page(accepted, receipt)
        case .filingIndex:
            let accepted = try await client.filingIndex(request)
            try Task.checkCancellation()
            let receipt = try await store.ingestSECFilingIndex(accepted, expectedRevision: revision)
            return page(accepted, receipt)
        case .filingDocument:
            let accepted = try await client.filingDocument(request)
            try Task.checkCancellation()
            let receipt = try await store.ingestSECFilingDocument(accepted, expectedRevision: revision)
            return page(accepted, receipt)
        default:
            throw ContractError.mismatchedRequest
        }
    }

    private func page<Item: ProviderRecord>(_ accepted: AcceptedProviderPayload<Item>,
                                             _ receipt: SECIngestReceipt) -> AcquisitionPageReceipt {
        let result = accepted.exchange.result
        return AcquisitionPageReceipt(capability: result.request.capability, status: result.status,
            itemCount: result.items.count, nextPageToken: result.nextPageToken,
            insertedDocuments: receipt.insertedDocuments, insertedRecords: receipt.insertedRecords,
            revision: receipt.revision)
    }
}

/// Same acceptance and revision boundary for the explicitly supported Alpaca IEX stock page.
/// Its records retain unknown historical availability and no analysis qualification.
public struct EquityAcquisitionPipeline<Provider: EquityDataProvider>: Sendable {
    public let client: EquityDataClient<Provider>
    public let store: BusinessDataStore

    public init(client: EquityDataClient<Provider>, store: BusinessDataStore) {
        self.client = client; self.store = store
    }

    public func ingest(_ request: ProviderRequest) async throws -> AcquisitionPageReceipt {
        try Task.checkCancellation()
        let revision = await store.revision()
        let accepted = try await client.fetch(request)
        try Task.checkCancellation()
        let receipt = try await store.ingestEquity(accepted, expectedRevision: revision)
        let result = accepted.exchange.result
        return AcquisitionPageReceipt(capability: request.capability, status: result.status,
            itemCount: result.items.count, nextPageToken: result.nextPageToken,
            insertedDocuments: receipt.insertedDocuments, insertedRecords: receipt.insertedRecords,
            revision: receipt.revision)
    }
}
