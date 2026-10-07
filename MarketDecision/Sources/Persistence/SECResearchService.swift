import Foundation
import GRDB
import CoreDomain
import DataContracts
import DataProviders
import FundamentalsEngine

public enum SECResearchError: Error, Equatable {
    case importInProgress, incompletePage, invalidContinuation, limitExceeded
    case identityUnavailable, mismatchedIssuer, missingPrimaryDocument, invalidDocument
}

public enum SECResearchStage: String, Sendable, Codable {
    case identity, submissions, companyFacts, filingIndex, filingDocument, normalizing, saving
}

public struct SECResearchProgress: Sendable, Equatable {
    public let stage: SECResearchStage
    public let acceptedPages: Int
    public let acceptedRecords: Int
    public init(stage: SECResearchStage, acceptedPages: Int, acceptedRecords: Int) {
        self.stage = stage; self.acceptedPages = acceptedPages; self.acceptedRecords = acceptedRecords
    }
}

public enum SECResearchGap: String, Sendable, Codable {
    case missingAnnualFiling, missingQuarterlyFiling, missingFacts, unmappedFacts
    case noQualifiedPricesOrCapital, financialClassificationNotSupplied, researchOnly
}

/// Exact accepted response bytes, independent of the mutable source cache. The local hash
/// proves retained-byte integrity, not SEC authenticity, historical completeness or a license.
public struct SECResearchSource: Sendable, Codable, Equatable {
    public let request: ProviderRequest
    public let reference: String
    public let providerID: String
    public let feedID: String
    public let endpoint: EndpointDescriptor
    public let receivedAt: Date
    public let storageAvailableAt: Date
    public let mediaType: String
    public let evidenceRef: String
    public let licenseRef: String
    public let bytes: Data
    public let contentHash: String

    init<Item>(_ accepted: AcceptedProviderPayload<Item>) {
        let raw = accepted.rawPayload, result = accepted.exchange.result
        request = result.request
        reference = raw.reference; providerID = result.request.providerID; feedID = result.request.feedID
        endpoint = result.request.capability.endpointDescriptor; receivedAt = result.receivedAt
        storageAvailableAt = raw.storageAvailableAt; mediaType = raw.mediaType
        evidenceRef = raw.evidenceRef; licenseRef = raw.licenseRef
        bytes = raw.bytes; contentHash = raw.contentHash
    }

    func validate() throws {
        let raw = try ProviderRawPayload(reference: reference, mediaType: mediaType, bytes: bytes,
            storageAvailableAt: storageAvailableAt, evidenceRef: evidenceRef, licenseRef: licenseRef)
        try request.validate()
        guard contentHash == raw.contentHash, storageAvailableAt <= receivedAt,
              receivedAt.timeIntervalSinceReferenceDate.isFinite, providerID == "sec-edgar", feedID == "public-edgar",
              request.providerID == providerID, request.feedID == feedID, request.requestedAt <= receivedAt,
              request.usage == .replay, request.mode == .latest, request.capability == endpoint.providerCapability,
              [.companyIdentity, .submissions, .companyFacts, .filingIndex, .filingDocument].contains(endpoint)
        else { throw SECResearchError.invalidDocument }
    }
}

/// A completed *bounded acquisition*, not a complete issuer model. Every fetched fact version
/// and its exact response bytes are frozen. Fiscal metadata is retained from SEC records;
/// quarters, sector classification, prices, share classes and split bases are never guessed.
public struct SECResearchDocument: Sendable, Codable, Identifiable {
    public let format: String
    public let id: UUID
    public let ticker: String
    public let cutoff: Date
    public let identity: SECCompanyIdentityRecord
    public let submissions: [SECSubmissionRecord]
    public let facts: [SECCompanyFactRecord]
    public let indexes: [SECFilingIndexRecord]
    public let filingDocuments: [SECFilingDocumentRecord]
    public let sources: [SECResearchSource]
    public let dictionaryVersion: String
    public let dictionaryRules: [FinancialMappingRule]
    public let normalizationPolicyVersion: String
    public let normalization: FinancialNormalizationResult
    public let gaps: [SECResearchGap]
    public var mayRunValuation: Bool { false }

    init(ticker: String, cutoff: Date, identity: SECCompanyIdentityRecord,
         submissions: [SECSubmissionRecord], facts: [SECCompanyFactRecord], indexes: [SECFilingIndexRecord],
         filingDocuments: [SECFilingDocumentRecord], sources: [SECResearchSource]) throws {
        format = "sec-research.v1"; id = UUID(); self.ticker = ticker; self.cutoff = cutoff
        self.identity = identity; self.submissions = submissions; self.facts = facts
        self.indexes = indexes; self.filingDocuments = filingDocuments; self.sources = sources
        let dictionary = try FinancialFieldDictionary.fundamentalsCompletionV1()
        dictionaryVersion = dictionary.version; dictionaryRules = dictionary.rules
        normalizationPolicyVersion = "sec-normalization.research.v1"
        normalization = try FinancialNormalizer.normalizeSECResearchV1(facts, dictionary: dictionary, asOf: cutoff)
        gaps = Self.expectedGaps(submissions: submissions, facts: facts, dictionary: dictionary, cutoff: cutoff)
        try validate()
    }

    /// Structural and retained-source validation only. Opening a cache is not formula replay.
    public func validate() throws {
        let dictionary = try FinancialFieldDictionary.fundamentalsCompletionV1()
        guard format == "sec-research.v1", dictionaryVersion == dictionary.version,
              normalizationPolicyVersion == "sec-normalization.research.v1",
              dictionaryRules == dictionary.rules, normalization.dictionaryVersion == dictionaryVersion,
              normalization.asOf == cutoff, cutoff.timeIntervalSinceReferenceDate.isFinite,
              gaps == Self.expectedGaps(submissions: submissions, facts: facts, dictionary: dictionary, cutoff: cutoff),
              identity.listings.contains(where: { $0.ticker == ticker }), identity.provenance.isAvailable(asOf: cutoff),
              sources.count <= 40, Set(sources.map(\.reference)).count == sources.count,
              sources.reduce(0, { $0 + $1.bytes.count }) <= 128 * 1_024 * 1_024,
              Set(submissions.map(\.recordID)).count == submissions.count,
              Set(facts.map(\.recordID)).count == facts.count,
              Set(indexes.map(\.recordID)).count == indexes.count,
              Set(filingDocuments.map(\.recordID)).count == filingDocuments.count,
              submissions.allSatisfy({ $0.cik == identity.cik }), facts.allSatisfy({ $0.cik == identity.cik }),
              indexes.allSatisfy({ $0.cik == identity.cik }), filingDocuments.allSatisfy({ $0.cik == identity.cik })
        else { throw SECResearchError.invalidDocument }
        try EquityRecord.validateSymbol(ticker)
        _ = try SECCompanyIdentityRecord(recordID: identity.recordID, cik: identity.cik, name: identity.name,
            listings: identity.listings, status: identity.status, provenance: identity.provenance)
        for item in facts {
            _ = try SECCompanyFactRecord(recordID: item.recordID, factID: item.factID, cik: item.cik,
                taxonomy: item.taxonomy, concept: item.concept, label: item.label, description: item.description,
                unit: item.unit, sourceValue: item.sourceValue, value: item.value, startDate: item.startDate,
                endDate: item.endDate, periodKind: item.periodKind, accessionNumber: item.accessionNumber,
                form: item.form, filedDate: item.filedDate, fiscalYear: item.fiscalYear,
                fiscalPeriod: item.fiscalPeriod, frame: item.frame, dimensions: item.dimensions, provenance: item.provenance)
        }
        for item in submissions {
            _ = try SECSubmissionRecord(recordID: item.recordID, cik: item.cik, accessionNumber: item.accessionNumber,
                form: item.form, filingDate: item.filingDate, reportDate: item.reportDate, acceptedAt: item.acceptedAt,
                primaryDocument: item.primaryDocument, isAmendment: item.isAmendment, provenance: item.provenance)
        }
        for item in indexes {
            _ = try SECFilingIndexRecord(recordID: item.recordID, cik: item.cik,
                accessionNumber: item.accessionNumber, files: item.files, provenance: item.provenance)
        }
        for item in filingDocuments {
            _ = try SECFilingDocumentRecord(recordID: item.recordID, cik: item.cik, accessionNumber: item.accessionNumber,
                fileName: item.fileName, mediaType: item.mediaType, provenance: item.provenance)
        }
        let byReference = Dictionary(uniqueKeysWithValues: sources.map { ($0.reference, $0) })
        try sources.forEach { try $0.validate() }
        guard sources.allSatisfy({ $0.receivedAt <= cutoff }),
              identity.provenance.endpointDescriptor == EndpointDescriptor.companyIdentity.rawValue,
              submissions.allSatisfy({ $0.provenance.endpointDescriptor == EndpointDescriptor.submissions.rawValue }),
              facts.allSatisfy({ $0.provenance.endpointDescriptor == EndpointDescriptor.companyFacts.rawValue }),
              indexes.allSatisfy({ $0.provenance.endpointDescriptor == EndpointDescriptor.filingIndex.rawValue }),
              filingDocuments.allSatisfy({ $0.provenance.endpointDescriptor == EndpointDescriptor.filingDocument.rawValue })
        else { throw SECResearchError.invalidDocument }
        let provenance = [identity.provenance] + submissions.map(\.provenance) + facts.map(\.provenance)
            + indexes.map(\.provenance) + filingDocuments.map(\.provenance)
        for item in provenance {
            try item.validate()
            guard let reference = item.rawObjectRef, let source = byReference[reference],
                  item.origin == .filing, item.versionKind == .sourceVersion,
                  item.rawHash == source.contentHash, item.providerID == source.providerID,
                  item.feedID == source.feedID, item.endpointDescriptor == source.endpoint.rawValue,
                  item.evidenceRef == source.evidenceRef, item.licenseRef == source.licenseRef,
                  item.receivedAt == source.receivedAt, item.requestID == source.request.id,
                  item.requestedAt == source.request.requestedAt else { throw SECResearchError.invalidDocument }
        }
        // A frozen primary document must have the corresponding accepted index entry.
        for document in filingDocuments {
            guard indexes.contains(where: { $0.accessionNumber == document.accessionNumber &&
                $0.files.contains(where: { $0.name == document.fileName }) }) else { throw SECResearchError.invalidDocument }
        }
        // Keep each tuple append simple enough for the supported Swift 6.1 compiler.
        var resources: [(Provenance, String)] = [(identity.provenance, ticker)]
        for submission in submissions { resources.append((submission.provenance, identity.cik)) }
        for fact in facts { resources.append((fact.provenance, identity.cik)) }
        for index in indexes {
            resources.append((index.provenance, identity.cik + "/" + index.accessionNumber))
        }
        for document in filingDocuments {
            resources.append((document.provenance, identity.cik + "/" + document.accessionNumber + "/" + document.fileName))
        }
        for (provenance, resource) in resources {
            guard let reference = provenance.rawObjectRef,
                  byReference[reference]?.request.resourceID == resource else { throw SECResearchError.invalidDocument }
        }
        // Cached calculations are not accepted as fresh output, but their references cannot
        // escape the frozen source context even before the user requests explicit replay.
        let factIDs = Set(facts.map(\.factID)), recordIDs = Set(facts.map(\.recordID))
        let allowedIssueIDs = recordIDs.union(factIDs)
        let versions = Set(facts.compactMap { $0.provenance.versionID })
        let byRecordID = Dictionary(uniqueKeysWithValues: facts.map { ($0.recordID, $0) })
        guard normalization.selectedSourceFacts.allSatisfy({ byRecordID[$0.recordID] == $0 }),
              normalization.unmappedSourceFacts.allSatisfy({ byRecordID[$0.recordID] == $0 }),
              normalization.values.allSatisfy({ value in
                  value.cik == identity.cik && value.dictionaryVersion == dictionaryVersion && value.availableAt <= cutoff &&
                  !value.sourceFactIDs.isEmpty && Set(value.sourceFactIDs).isSubset(of: factIDs) &&
                  !value.sourceVersions.isEmpty && Set(value.sourceVersions).isSubset(of: versions)
              }), normalization.issues.allSatisfy({ Set($0.factIDs).isSubset(of: allowedIssueIDs) })
        else { throw SECResearchError.invalidDocument }
    }

    /// Explicit replay ignores the cached normalization and reconstructs from source facts
    /// and the exact saved cutoff under the immutable reviewed dictionary.
    public func recompute() throws -> FinancialNormalizationResult {
        try validate()
        let dictionary = try FinancialFieldDictionary(version: dictionaryVersion, rules: dictionaryRules)
        return try FinancialNormalizer.normalizeSECResearchV1(facts, dictionary: dictionary, asOf: cutoff)
    }

    private static func expectedGaps(submissions: [SECSubmissionRecord], facts: [SECCompanyFactRecord],
                                     dictionary: FinancialFieldDictionary, cutoff: Date) -> [SECResearchGap] {
        var gaps: [SECResearchGap] = []
        if !submissions.contains(where: { $0.form == "10-K" || $0.form == "10-K/A" }) { gaps.append(.missingAnnualFiling) }
        if !submissions.contains(where: { $0.form == "10-Q" || $0.form == "10-Q/A" }) { gaps.append(.missingQuarterlyFiling) }
        let available = facts.filter { $0.provenance.isAvailable(asOf: cutoff) }
        if !available.contains(where: { dictionary.rule(for: $0) != nil }) { gaps.append(.missingFacts) }
        if available.contains(where: { dictionary.rule(for: $0) == nil }) { gaps.append(.unmappedFacts) }
        return gaps + [.noQualifiedPricesOrCapital, .financialClassificationNotSupplied, .researchOnly]
    }
}

/// A separate application-id-marked database. Neither the synthetic transfer API nor the
/// reviewed-excerpt archive may open it. No export/restore permission is granted here.
public actor SECResearchStore {
    let database: DatabaseStore
    let business: BusinessDataStore

    public init(path: String) throws {
        try self.init(database: DatabaseStore(path: path, purpose: .secResearch))
    }
    init(database: DatabaseStore) throws {
        guard database.purpose == .secResearch else { throw MigrationError.incompatiblePurpose }
        self.database = database; business = try BusinessDataStore(database: database)
        _ = try Self.revision(database)
    }
    func writeRevision() throws -> UUID { try Self.revision(database) }
    private static func revision(_ database: DatabaseStore) throws -> UUID {
        try database.read { db in
            guard try Int.fetchOne(db, sql: "PRAGMA application_id") == DatabasePurpose.secResearch.applicationID else {
                throw MigrationError.incompatiblePurpose
            }
            guard let text = try String.fetchOne(db, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1"),
                  let revision = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
            for table in ["p1_observations", "p1_market_sessions", "p1_company_events", "p1_equity_records", "p1_equity_pages",
                          "p1_watchlist", "p1_watchlist_conflicts", "p1_financial_dictionaries",
                          "p1_financial_normalization_runs", "p1_normalized_financial_facts"] {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM " + table) == 0 else { throw SnapshotError.unsupportedFormat }
            }
            return revision
        }
    }
    func save(_ document: SECResearchDocument, expectedRevision: UUID) async throws {
        try Task.checkCancellation()
        try document.validate()
        let bytes = try ResearchDocument.encoded(document)
        try Task.checkCancellation()
        try database.transaction { db in
            try Task.checkCancellation()
            try BusinessDataStore.checkRevision(expectedRevision, db: db)
            try SECResearchStorage.insert(document, bytes: bytes, db: db)
            try Task.checkCancellation()
            try BusinessDataStore.writeRevision(UUID(), db: db)
        }
    }

    /// Catalog summaries only; this is not a full-database integrity check. Previously
    /// unindexed PR42 records are validated individually before their summaries appear.
    public func savedResearch() throws -> [SECResearchSummary] {
        _ = try writeRevision()
        try SECResearchStorage.indexLegacyDocuments(database)
        return try database.read { db in try SECResearchStorage.summaries(db) }
    }

    /// Only the selected immutable version and its retained source bytes are decoded.
    public func open(id: UUID) throws -> SECResearchDocument {
        _ = try writeRevision()
        try Task.checkCancellation()
        return try database.read { db in try SECResearchStorage.open(id: id, db: db) }
    }

    /// No-op acquisitions keep the original row/reference. Check every requested record by
    /// its primary key so a broken JOIN or an altered availability index cannot silently
    /// remove it from a later as-of inventory. This new database has no legacy string dates.
    func validateCachedRecords(_ document: SECResearchDocument) async throws {
        struct Envelope: Decodable { let recordID: String; let provenance: Provenance }
        let groups: [(String, [(String, Provenance)])] = [
            ("p1_sec_identities", [(document.identity.recordID, document.identity.provenance)]),
            ("p1_sec_submissions", document.submissions.map { ($0.recordID, $0.provenance) }),
            ("p1_sec_facts", document.facts.map { ($0.recordID, $0.provenance) }),
            ("p1_sec_filing_indexes", document.indexes.map { ($0.recordID, $0.provenance) }),
            ("p1_sec_filing_documents", document.filingDocuments.map { ($0.recordID, $0.provenance) })
        ]
        let originals = try database.read { db -> [Provenance] in
            var sources: [Provenance] = []
            for (table, records) in groups {
                for (recordID, incoming) in records {
                    guard let version = incoming.versionID, let row = try Row.fetchOne(db,
                        sql: "SELECT * FROM " + table + " WHERE record_id = ? AND version_id = ?",
                        arguments: [recordID, version]) else { throw BusinessStoreError.corruptedStorage }
                    let bytes: Data = row["record_json"]
                    guard digest(bytes) == row["record_hash"] else { throw BusinessStoreError.corruptedStorage }
                    let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
                    try envelope.provenance.validate()
                    guard envelope.recordID == recordID, row["cik"] == document.identity.cik,
                          envelope.provenance.versionID == version,
                          row["source_reference"] == envelope.provenance.rawObjectRef,
                          row["available_at_ms"] == (try MillisecondInstant(flooring: envelope.provenance.availability.upperBound()).milliseconds)
                    else { throw BusinessStoreError.corruptedStorage }
                    sources.append(envelope.provenance)
                }
            }
            return sources
        }
        var checked = Set<String>()
        for provenance in originals {
            guard let reference = provenance.rawObjectRef else { throw BusinessStoreError.corruptedStorage }
            if checked.insert(reference).inserted {
                let source = try await business.sourceDocument(reference: reference)
                guard source.contentHash == provenance.rawHash, source.providerID == provenance.providerID,
                      source.feedID == provenance.feedID, source.endpoint.rawValue == provenance.endpointDescriptor,
                      source.evidenceRef == provenance.evidenceRef, source.licenseRef == provenance.licenseRef
                else { throw BusinessStoreError.corruptedStorage }
            }
        }
    }
}

public protocol SECResearchServicing: Sendable {
    func importCompany(ticker: String, progress: @escaping @Sendable (SECResearchProgress) async -> Void) async throws -> SECResearchDocument
    func savedResearch() async throws -> [SECResearchSummary]
    func open(id: UUID) async throws -> SECResearchDocument
}

/// Sequential, bounded orchestration through the existing acceptance pipeline. Already
/// accepted pages survive failure/cancellation; no successful snapshot is published until
/// all advertised submissions pages and each selected filing's primary document are stored.
/// Retrying is an explicit new operation, never an automatic unlimited network loop.
public actor SECResearchService<Provider: FundamentalsProvider>: SECResearchServicing
where Provider.Identity == SECCompanyIdentityRecord, Provider.Submission == SECSubmissionRecord,
      Provider.Facts == SECCompanyFactRecord, Provider.FilingIndex == SECFilingIndexRecord,
      Provider.FilingDocument == SECFilingDocumentRecord {
    private let client: FundamentalsDataClient<Provider>
    private let store: SECResearchStore
    private let now: @Sendable () -> Date
    private let sourceByteLimit: Int
    private var importing = false

    public init(client: FundamentalsDataClient<Provider>, store: SECResearchStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client; self.store = store; self.now = now
        self.sourceByteLimit = 128 * 1_024 * 1_024
    }
    /// Tests can lower the existing acquisition budget without allocating hundreds of MiB.
    /// This is not a public configuration and cannot raise the production limit.
    init(client: FundamentalsDataClient<Provider>, store: SECResearchStore,
         now: @escaping @Sendable () -> Date, sourceByteLimit: Int) throws {
        guard (1...(128 * 1_024 * 1_024)).contains(sourceByteLimit) else { throw SECResearchError.limitExceeded }
        self.client = client; self.store = store; self.now = now; self.sourceByteLimit = sourceByteLimit
    }
    public func savedResearch() async throws -> [SECResearchSummary] { try await store.savedResearch() }
    public func open(id: UUID) async throws -> SECResearchDocument { try await store.open(id: id) }

    public func importCompany(ticker: String, progress: @escaping @Sendable (SECResearchProgress) async -> Void) async throws -> SECResearchDocument {
        guard !importing else { throw SECResearchError.importInProgress }
        importing = true; defer { importing = false }
        try EquityRecord.validateSymbol(ticker)
        guard client.provider.id == "sec-edgar", client.entitlement?.feedID == "public-edgar" else {
            throw ContractError.mismatchedSource
        }
        try Task.checkCancellation()
        var revision = try await store.writeRevision()
        let business = store.business
        var pages = 0, records = 0, acceptedSourceBytes = 0
        var sources: [SECResearchSource] = []
        var newlyRetainedSources = Set<String>()
        func snapshot(_ stage: SECResearchStage) -> SECResearchProgress {
            .init(stage: stage, acceptedPages: pages, acceptedRecords: records)
        }
        // Check before ingest: a rejected page must not become an extra retained source.
        // Earlier committed pages remain. This is a per-acquisition source budget, not
        // a process-memory or lifetime database-size bound.
        func reserveSource<Item>(_ accepted: AcceptedProviderPayload<Item>) throws {
            let count = accepted.rawPayload.bytes.count
            guard pages < 40, count <= sourceByteLimit - acceptedSourceBytes else { throw SECResearchError.limitExceeded }
            acceptedSourceBytes += count
        }
        func received<Item>(_ accepted: AcceptedProviderPayload<Item>, receipt: SECIngestReceipt) throws {
            pages += 1; records += accepted.exchange.result.items.count; revision = receipt.revision
            sources.append(.init(accepted))
            if receipt.insertedDocuments > 0 { newlyRetainedSources.insert(accepted.rawPayload.reference) }
        }
        await progress(snapshot(.identity))
        let identityPage = try await client.companyIdentity(request(.companyIdentity, resource: ticker))
        try validatePage(identityPage, permitsContinuations: false)
        guard identityPage.exchange.result.items.count == 1, let identity = identityPage.exchange.result.items.first,
              identity.listings.contains(where: { $0.ticker == ticker }) else { throw SECResearchError.identityUnavailable }
        try Task.checkCancellation()
        try reserveSource(identityPage)
        try received(identityPage, receipt: await business.ingestSECIdentities(identityPage, expectedRevision: revision))

        var submissions: [SECSubmissionRecord] = [], submissionVersions: [String: String] = [:]
        var queue: [String?] = [nil], seen = Set<String>()
        while !queue.isEmpty {
            guard seen.count <= 31 else { throw SECResearchError.limitExceeded }
            let token = queue.removeFirst()
            await progress(snapshot(.submissions))
            let accepted = try await client.submissions(request(.submissions, resource: identity.cik, token: token))
            try validatePage(accepted, permitsContinuations: true)
            guard accepted.exchange.result.items.allSatisfy({ $0.cik == identity.cik }) else { throw SECResearchError.mismatchedIssuer }
            for continuation in accepted.continuationTokens {
                guard continuation.range(of: "^CIK" + identity.cik + #"-submissions-[0-9]{3}\.json\z"#, options: .regularExpression) != nil,
                      seen.insert(continuation).inserted else { throw SECResearchError.invalidContinuation }
                queue.append(continuation)
            }
            guard seen.count <= 31 else { throw SECResearchError.limitExceeded }
            // Repeated records across advertised pages must be byte-equivalent content versions.
            // Preserve one record, not two conflicting contexts under the same record id.
            for item in accepted.exchange.result.items {
                guard let version = item.provenance.versionID else { throw ContractError.invalidIdentity }
                if let previousVersion = submissionVersions[item.recordID] {
                    guard previousVersion == version else { throw ContractError.ambiguousVersion }
                } else {
                    submissionVersions[item.recordID] = version
                    submissions.append(item)
                }
            }
            try Task.checkCancellation()
            try reserveSource(accepted)
            try received(accepted, receipt: await business.ingestSECSubmissions(accepted, expectedRevision: revision))
        }
        await progress(snapshot(.companyFacts))
        let factPage = try await client.companyFacts(request(.companyFacts, resource: identity.cik))
        try validatePage(factPage, permitsContinuations: false)
        guard factPage.exchange.result.items.allSatisfy({ $0.cik == identity.cik }) else { throw SECResearchError.mismatchedIssuer }
        try Task.checkCancellation()
        try reserveSource(factPage)
        try received(factPage, receipt: await business.ingestSECCompanyFacts(factPage, expectedRevision: revision))
        var indexes: [SECFilingIndexRecord] = [], documents: [SECFilingDocumentRecord] = []
        // These are the most recently filed annual and quarterly reports, not every historical
        // filing or an assertion that amendments provide a standalone complete statement.
        let selected = ["10-K", "10-Q"].compactMap { form in
            submissions.filter { $0.form == form || $0.form == form + "/A" }.sorted {
                $0.filingDate == $1.filingDate ? $0.accessionNumber > $1.accessionNumber : $0.filingDate > $1.filingDate
            }.first
        }
        for submission in selected {
            // Older inventory entries can legitimately omit this field. Only the two
            // selected reports require a safe explicit primary filename before dispatch.
            guard SECSubmissionRecord.validFileName(submission.primaryDocument) else {
                throw SECResearchError.missingPrimaryDocument
            }
            let resource = identity.cik + "/" + submission.accessionNumber
            await progress(snapshot(.filingIndex))
            let indexPage = try await client.filingIndex(request(.filingIndex, resource: resource))
            try validatePage(indexPage, permitsContinuations: false)
            guard indexPage.exchange.result.items.count == 1, let index = indexPage.exchange.result.items.first,
                  index.cik == identity.cik, index.accessionNumber == submission.accessionNumber,
                  index.files.contains(where: { $0.name == submission.primaryDocument }) else { throw SECResearchError.missingPrimaryDocument }
            try Task.checkCancellation()
            try reserveSource(indexPage)
            try received(indexPage, receipt: await business.ingestSECFilingIndex(indexPage, expectedRevision: revision))
            indexes.append(index)
            await progress(snapshot(.filingDocument))
            let documentPage = try await client.filingDocument(request(.filingDocument, resource: resource + "/" + submission.primaryDocument))
            try validatePage(documentPage, permitsContinuations: false)
            guard documentPage.exchange.result.items.count == 1, let document = documentPage.exchange.result.items.first,
                  document.cik == identity.cik, document.accessionNumber == submission.accessionNumber,
                  document.fileName == submission.primaryDocument else { throw SECResearchError.missingPrimaryDocument }
            try Task.checkCancellation()
            try reserveSource(documentPage)
            try received(documentPage, receipt: await business.ingestSECFilingDocument(documentPage, expectedRevision: revision))
            documents.append(document)
        }
        await progress(snapshot(.normalizing))
        try Task.checkCancellation()
        let cutoff = now()
        // Check the physical source blobs as well as the accepted in-memory evidence before
        // freezing. Each subsequent page/freeze checks the original operation's CAS lineage.
        for source in sources where newlyRetainedSources.contains(source.reference) {
            let persisted = try await business.sourceDocument(reference: source.reference)
            guard persisted.payload == source.bytes, persisted.contentHash == source.contentHash else { throw BusinessStoreError.corruptedStorage }
        }
        // A no-op ingest intentionally discards the new transient aggregate. Validate the
        // surviving typed records along their own original sources, not the new page's ref.
        let cachedIdentity = try await business.secIdentity(ticker: ticker, asOf: cutoff)
        var cachedProvenance = [cachedIdentity.provenance]
        cachedProvenance += try await business.secSubmissions(cik: identity.cik, asOf: cutoff).map(\.provenance)
        cachedProvenance += try await business.secFactVersions(cik: identity.cik, asOf: cutoff).map(\.provenance)
        for item in selected {
            cachedProvenance.append(try await business.secFilingIndex(cik: identity.cik, accessionNumber: item.accessionNumber, asOf: cutoff).provenance)
            cachedProvenance.append(try await business.secFilingDocument(cik: identity.cik, accessionNumber: item.accessionNumber,
                fileName: item.primaryDocument, asOf: cutoff).provenance)
        }
        var checkedReferences = Set<String>()
        for provenance in cachedProvenance {
            guard let reference = provenance.rawObjectRef, let hash = provenance.rawHash else { throw BusinessStoreError.corruptedStorage }
            if checkedReferences.insert(reference).inserted {
                let persisted = try await business.sourceDocument(reference: reference)
                guard persisted.contentHash == hash else { throw BusinessStoreError.corruptedStorage }
            }
        }
        let document = try SECResearchDocument(ticker: ticker, cutoff: cutoff, identity: identity,
            submissions: submissions, facts: factPage.exchange.result.items, indexes: indexes,
            filingDocuments: documents, sources: sources)
        try await store.validateCachedRecords(document)
        await progress(snapshot(.saving))
        try Task.checkCancellation()
        try await store.save(document, expectedRevision: revision)
        return document
    }

    private func request(_ capability: ProviderCapability, resource: String, token: String? = nil) throws -> ProviderRequest {
        guard let rights = client.entitlement else { throw ProviderFailure.notEntitled }
        return ProviderRequest(providerID: client.provider.id, feedID: rights.feedID, resourceID: resource,
            capability: capability, mode: .latest, usage: .replay,
            configurationVersion: client.provider.capabilitySnapshot.version, entitlementVersion: rights.version,
            requestedAt: now(), pageToken: token)
    }

    private func validatePage<Item>(_ accepted: AcceptedProviderPayload<Item>, permitsContinuations: Bool) throws {
        let result = accepted.exchange.result
        guard result.errors.isEmpty, result.coverage.missing.isEmpty,
              result.coverage.expectedCount.map({ $0 == result.items.count }) ?? true,
              permitsContinuations || accepted.continuationTokens.isEmpty,
              !result.coverage.truncated || !accepted.continuationTokens.isEmpty,
              result.status != .error else { throw SECResearchError.incompletePage }
        if result.status == .partial, accepted.continuationTokens.isEmpty { throw SECResearchError.incompletePage }
    }
}
