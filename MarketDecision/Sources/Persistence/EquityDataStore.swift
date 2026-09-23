import Foundation
import GRDB
import CoreDomain
import DataContracts
import DataProviders

public struct EquityIngestReceipt: Sendable, Equatable {
    public let insertedDocuments: Int, insertedRecords: Int, insertedPages: Int
    public let revision: UUID
}
/// A single accepted response page, never a claim that every trading day is present.
public struct EquityStoredPage: Sendable, Codable {
    public let request: ProviderRequest
    public let status: String
    public let nextPageToken: String?
    public let sourceReference: String
    public let contentHash: String
    public let evidenceRef: String, licenseRef: String
    public let recordVersions: [String: String]
}

public extension BusinessDataStore {
    /// Raw + typed + page coverage commit atomically. The accepted wrapper is not publicly
    /// constructible; quote/bars capability, rights and exact request are checked before this API.
    @discardableResult
    internal func ingestEquity(_ accepted: AcceptedProviderPayload<EquityRecord>, expectedRevision: UUID) throws -> EquityIngestReceipt {
        let result = accepted.exchange.result, raw = accepted.rawPayload, request = result.request
        guard case .latest = request.mode, request.providerID == "alpaca", request.feedID == "iex" else { throw ContractError.invalidRequest }
        guard [.quote, .bars].contains(request.capability), [.complete, .partial, .empty].contains(result.status),
              result.errors.isEmpty, result.coverage.missing.isEmpty, !result.coverage.truncated,
              result.coverage.expectedCount == nil else { throw ContractError.invalidCoverage }
        let document = try SourceDocument(reference: raw.reference, providerID: request.providerID, feedID: request.feedID,
            endpoint: request.capability.endpointDescriptor, receivedAt: MillisecondInstant(rounding: result.receivedAt),
            availableAt: MillisecondInstant(rounding: raw.storageAvailableAt), mediaType: raw.mediaType,
            evidenceRef: raw.evidenceRef, licenseRef: raw.licenseRef, payload: raw.bytes)
        for item in result.items {
            try item.validate()
            guard item.symbol == request.resourceID, item.kind == (request.capability == .quote ? .quote : .dailyBar),
                  item.provenance.rawHash == document.contentHash, item.provenance.rawObjectRef == document.reference,
                  item.provenance.licenseRef == document.licenseRef, item.provenance.evidenceRef == document.evidenceRef else {
                throw BusinessStoreError.sourceMismatch
            }
        }
        let page = EquityStoredPage(request: request, status: result.status.rawValue, nextPageToken: result.nextPageToken,
            sourceReference: raw.reference, contentHash: raw.contentHash,
            evidenceRef: raw.evidenceRef, licenseRef: raw.licenseRef,
            recordVersions: Dictionary(uniqueKeysWithValues: result.items.map { ($0.recordID, $0.contentVersion()) }))
        let pageID = try Self.equityPageID(page), pageBytes = try Self.encodeEquity(page)
        let encoded = try result.items.map { ($0, try Self.encodeEquity($0)) }
        let nextRevision = UUID()
        let changes = try database.transaction { db -> (Int, Int, Int) in
            guard try String.fetchOne(db, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1") == expectedRevision.uuidString.lowercased() else {
                throw SnapshotError.stalePlan
            }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM p1_equity_pages WHERE page_id = ?", arguments: [pageID]) {
                let old = try Self.decodeStoredEquityPage(row, db: db)
                guard try Self.equityPageID(old) == pageID, old.recordVersions == page.recordVersions,
                      old.status == page.status, old.nextPageToken == page.nextPageToken else { throw BusinessStoreError.immutableConflict }
                return (0, 0, 0)
            }
            let metadata = try document.metadataHash
            var documents = 0
            if let old = try String.fetchOne(db, sql: "SELECT metadata_hash FROM p1_source_documents WHERE reference = ?", arguments: [document.reference]) {
                guard old == metadata else { throw BusinessStoreError.immutableConflict }
            } else {
                try db.execute(sql: """
                    INSERT INTO p1_source_documents
                    (reference, metadata_hash, content_hash, provider_id, feed_id, endpoint_descriptor,
                     received_at_ms, available_at_ms, media_type, evidence_ref, license_ref, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [document.reference, metadata, document.contentHash, document.providerID, document.feedID,
                                      document.endpoint.rawValue, document.receivedAt.milliseconds, document.availableAt.milliseconds,
                                      document.mediaType, document.evidenceRef, document.licenseRef, document.payload])
                documents = 1
            }
            var count = 0
            for (item, bytes) in encoded {
                if let stored = try Row.fetchOne(db, sql: "SELECT * FROM p1_equity_records WHERE record_id = ? AND version_id = ?",
                                                  arguments: [item.recordID, item.contentVersion()]) {
                    let old = try Self.decodeStoredEquityRecord(stored, db: db)
                    guard old.contentVersion() == item.contentVersion() else { throw BusinessStoreError.immutableConflict }
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO p1_equity_records
                    (record_id, version_id, symbol, kind, source_event_ms, received_at_ms, source_reference, record_hash, record_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.recordID, item.contentVersion(), item.symbol, item.kind.rawValue,
                                      try MillisecondInstant(rounding: item.provenance.sourceEventAt!).milliseconds,
                                      try MillisecondInstant(rounding: item.provenance.receivedAt).milliseconds,
                                      document.reference, digest(bytes), bytes])
                count += 1
            }
            try db.execute(sql: "INSERT INTO p1_equity_pages (page_id, symbol, source_reference, page_hash, page_json) VALUES (?, ?, ?, ?, ?)",
                           arguments: [pageID, request.resourceID, document.reference, digest(pageBytes), pageBytes])
            try db.execute(sql: "UPDATE p1_store_metadata SET revision = ? WHERE singleton = 1", arguments: [nextRevision.uuidString.lowercased()])
            return (documents, count, 1)
        }
        if changes.0 + changes.1 + changes.2 > 0 { currentRevision = nextRevision }
        else { currentRevision = expectedRevision }
        return EquityIngestReceipt(insertedDocuments: changes.0, insertedRecords: changes.1, insertedPages: changes.2, revision: currentRevision)
    }

    /// Returns all locally collected versions. This is not an AS_OF selector and does not infer
    /// historical availability from either the source bar date or local reception time.
    func equityRecords(symbol: String, kind: EquityKind, range: DateRange) throws -> [EquityRecord] {
        try EquityRecord.validateSymbol(symbol); try range.validate()
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM p1_equity_records WHERE symbol = ? AND kind = ? AND source_event_ms >= ? AND source_event_ms <= ?
                ORDER BY source_event_ms, received_at_ms, version_id
                """, arguments: [symbol, kind.rawValue, try MillisecondInstant(rounding: range.start).milliseconds,
                                  try MillisecondInstant(rounding: range.end).milliseconds])
                .map { try Self.decodeStoredEquityRecord($0, db: db) }
        }
    }
    /// Every read and deduplication path verifies the same row and its own original source,
    /// in the caller's transaction. A different page may legitimately reuse this content version.
    private static func decodeStoredEquityRecord(_ row: Row, db: Database) throws -> EquityRecord {
        do {
            let bytes: Data = row["record_json"]
            guard digest(bytes) == row["record_hash"],
                  let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM p1_source_documents WHERE reference = ?",
                    arguments: [row["source_reference"] as String]) else { throw BusinessStoreError.corruptedStorage }
            let item = try decodeEquity(EquityRecord.self, bytes: bytes); try item.validate()
            let document = try decodeSourceDocument(sourceRow)
            guard item.recordID == row["record_id"], item.contentVersion() == row["version_id"],
                  item.symbol == row["symbol"], item.kind.rawValue == row["kind"],
                  try MillisecondInstant(rounding: item.provenance.sourceEventAt!).milliseconds == row["source_event_ms"],
                  try MillisecondInstant(rounding: item.provenance.receivedAt).milliseconds == row["received_at_ms"],
                  item.provenance.rawObjectRef == document.reference, item.provenance.rawHash == document.contentHash,
                  item.provenance.providerID == document.providerID, item.provenance.feedID == document.feedID,
                  item.provenance.endpointDescriptor == document.endpoint.rawValue,
                  item.provenance.evidenceRef == document.evidenceRef, item.provenance.licenseRef == document.licenseRef else {
                throw BusinessStoreError.corruptedStorage
            }
            return item
        } catch { throw BusinessStoreError.corruptedStorage }
    }
    func equityPages(symbol: String) throws -> [EquityStoredPage] {
        try EquityRecord.validateSymbol(symbol)
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM p1_equity_pages WHERE symbol = ? ORDER BY page_id", arguments: [symbol])
                .map { try Self.decodeStoredEquityPage($0, db: db) }
        }
    }
    private static func decodeStoredEquityPage(_ row: Row, db: Database) throws -> EquityStoredPage {
        do {
            let bytes: Data = row["page_json"]
            guard digest(bytes) == row["page_hash"],
                  let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM p1_source_documents WHERE reference = ?", arguments: [row["source_reference"] as String])
            else { throw BusinessStoreError.corruptedStorage }
            let source = try decodeSourceDocument(sourceRow)
            let page = try decodeEquity(EquityStoredPage.self, bytes: bytes); try page.request.validate()
            guard try equityPageID(page) == row["page_id"], page.request.resourceID == row["symbol"],
                  page.sourceReference == source.reference, page.contentHash == source.contentHash,
                  page.evidenceRef == source.evidenceRef, page.licenseRef == source.licenseRef,
                  page.request.providerID == source.providerID, page.request.feedID == source.feedID,
                  page.request.capability.endpointDescriptor == source.endpoint else { throw BusinessStoreError.corruptedStorage }
            for (id, version) in page.recordVersions {
                guard let record = try Row.fetchOne(db, sql: "SELECT * FROM p1_equity_records WHERE record_id = ? AND version_id = ?",
                    arguments: [id, version]) else { throw BusinessStoreError.corruptedStorage }
                let item = try decodeStoredEquityRecord(record, db: db)
                guard item.recordID == id, item.contentVersion() == version, item.symbol == page.request.resourceID,
                      item.provenance.endpointDescriptor == page.request.capability.endpointDescriptor.rawValue else {
                    throw BusinessStoreError.corruptedStorage
                }
            }
            return page
        } catch { throw BusinessStoreError.corruptedStorage }
    }
    private static func equityPageID(_ page: EquityStoredPage) throws -> String {
        // Preserve exact request scope, but not transient request IDs or collection time.
        struct Identity: Encodable {
            let provider, feed, symbol, capability, configuration, entitlement, usage, hash, evidence, license: String
            let range: DataWindow?
            let token: String?
        }
        let r = page.request
        return digest(try encodeEquity(Identity(provider: r.providerID, feed: r.feedID, symbol: r.resourceID,
            capability: r.capability.rawValue, configuration: r.configurationVersion, entitlement: r.entitlementVersion,
            usage: r.usage.rawValue, hash: page.contentHash, evidence: page.evidenceRef, license: page.licenseRef, range: r.range, token: r.pageToken)))
    }
    private static func encodeEquity<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(MillisecondInstant(rounding: date).iso8601)
        }
        return try encoder.encode(value)
    }
    private static func decodeEquity<T: Decodable>(_ type: T.Type, bytes: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in try MillisecondInstant(iso8601: decoder.singleValueContainer().decode(String.self)).date }
        return try decoder.decode(type, from: bytes)
    }
}
