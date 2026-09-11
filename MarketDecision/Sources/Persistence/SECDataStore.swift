import Foundation
import GRDB
import CoreDomain
import DataContracts
import DataProviders
import FundamentalsEngine

public struct SECIngestReceipt: Sendable, Equatable {
    public let insertedDocuments: Int
    public let insertedRecords: Int
    public let revision: UUID
}

public struct FinancialPersistenceReceipt: Sendable, Equatable {
    public let runID: String
    public let insertedDictionary: Bool
    public let insertedValues: Int
    public let revision: UUID
}

public extension BusinessDataStore {
    @discardableResult
    func ingestSECIdentities(_ accepted: AcceptedProviderPayload<SECCompanyIdentityRecord>,
                             expectedRevision: UUID) throws -> SECIngestReceipt {
        try ingestSEC(accepted, capability: .companyIdentity, expectedRevision: expectedRevision) { item, version, available, bytes, document, db in
            try Self.insertSECRecord(table: "p1_sec_identities", key: [item.recordID, version], bytes: bytes, db: db) {
                try db.execute(sql: """
                    INSERT INTO p1_sec_identities
                    (record_id, version_id, cik, available_at_ms, source_reference, record_hash, record_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.recordID, version, item.cik, available.milliseconds,
                                      document.reference, digest(bytes), bytes])
                for listing in item.listings {
                    try db.execute(sql: """
                        INSERT INTO p1_sec_identity_listings (record_id, version_id, ticker, exchange)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [item.recordID, version, listing.ticker, listing.exchange])
                }
            }
        }
    }

    @discardableResult
    func ingestSECSubmissions(_ accepted: AcceptedProviderPayload<SECSubmissionRecord>,
                              expectedRevision: UUID) throws -> SECIngestReceipt {
        try ingestSEC(accepted, capability: .submissions, expectedRevision: expectedRevision) { item, version, available, bytes, document, db in
            try Self.insertSECRecord(table: "p1_sec_submissions", key: [item.recordID, version], bytes: bytes, db: db) {
                try db.execute(sql: """
                    INSERT INTO p1_sec_submissions
                    (record_id, version_id, cik, accession_number, filing_date, accepted_at_ms, available_at_ms,
                     source_reference, record_hash, record_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.recordID, version, item.cik, item.accessionNumber,
                                      item.filingDate.iso8601, try item.acceptedAt.map { try MillisecondInstant(rounding: $0).milliseconds },
                                      available.milliseconds, document.reference, digest(bytes), bytes])
            }
        }
    }

    @discardableResult
    func ingestSECCompanyFacts(_ accepted: AcceptedProviderPayload<SECCompanyFactRecord>,
                               expectedRevision: UUID) throws -> SECIngestReceipt {
        try ingestSEC(accepted, capability: .companyFacts, expectedRevision: expectedRevision) { item, version, available, bytes, document, db in
            try Self.insertSECRecord(table: "p1_sec_facts", key: [item.recordID, version], bytes: bytes, db: db) {
                try db.execute(sql: """
                    INSERT INTO p1_sec_facts
                    (record_id, fact_id, version_id, cik, taxonomy, concept, source_unit, period_start,
                     period_end, accession_number, filed_date, available_at_ms, canonical_value,
                     source_reference, record_hash, record_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.recordID, item.factID, version, item.cik, item.taxonomy, item.concept,
                                      item.unit, item.startDate?.iso8601, item.endDate.iso8601, item.accessionNumber,
                                      item.filedDate.iso8601, available.milliseconds, item.value.decimalString,
                                      document.reference, digest(bytes), bytes])
            }
        }
    }

    @discardableResult
    func ingestSECFilingIndex(_ accepted: AcceptedProviderPayload<SECFilingIndexRecord>,
                              expectedRevision: UUID) throws -> SECIngestReceipt {
        try ingestSEC(accepted, capability: .filingIndex, expectedRevision: expectedRevision) { item, version, available, bytes, document, db in
            try Self.insertSECRecord(table: "p1_sec_filing_indexes", key: [item.recordID, version], bytes: bytes, db: db) {
                try db.execute(sql: """
                    INSERT INTO p1_sec_filing_indexes
                    (record_id, version_id, cik, accession_number, available_at_ms, source_reference, record_hash, record_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.recordID, version, item.cik, item.accessionNumber,
                                      available.milliseconds, document.reference, digest(bytes), bytes])
            }
        }
    }

    @discardableResult
    func ingestSECFilingDocument(_ accepted: AcceptedProviderPayload<SECFilingDocumentRecord>,
                                 expectedRevision: UUID) throws -> SECIngestReceipt {
        try ingestSEC(accepted, capability: .filingDocument, expectedRevision: expectedRevision) { item, version, available, bytes, document, db in
            try Self.insertSECRecord(table: "p1_sec_filing_documents", key: [item.recordID, version], bytes: bytes, db: db) {
                try db.execute(sql: """
                    INSERT INTO p1_sec_filing_documents
                    (record_id, version_id, cik, accession_number, file_name, available_at_ms,
                     source_reference, record_hash, record_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.recordID, version, item.cik, item.accessionNumber, item.fileName,
                                      available.milliseconds, document.reference, digest(bytes), bytes])
            }
        }
    }

    /// Returns every stored fact version that was available by the cutoff. Revision choice and
    /// mapping are performed by FinancialNormalizer; current/latest rows are never substituted.
    func secFactVersions(cik: String, asOf cutoff: Date) throws -> [SECCompanyFactRecord] {
        guard SECCompanyIdentityRecord.validCIK(cik) else { throw BusinessStoreError.sourceMismatch }
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_sec_facts f JOIN p1_source_documents d ON d.reference = f.source_reference
                WHERE f.cik = ? AND f.available_at_ms <= ?
                ORDER BY f.fact_id, f.available_at_ms, f.record_id, f.version_id
                """, arguments: [cik, cutoffMS])
        }
        return try rows.map { row in
            let item = try Self.decodeSEC(SECCompanyFactRecord.self, row: row)
            guard row["record_id"] == item.recordID, row["fact_id"] == item.factID,
                  row["version_id"] == item.provenance.versionID, row["cik"] == item.cik,
                  row["taxonomy"] == item.taxonomy, row["concept"] == item.concept,
                  row["source_unit"] == item.unit, row["period_start"] == item.startDate?.iso8601,
                  row["period_end"] == item.endDate.iso8601, row["accession_number"] == item.accessionNumber,
                  row["filed_date"] == item.filedDate.iso8601, row["canonical_value"] == item.value.decimalString
            else { throw BusinessStoreError.corruptedStorage }
            return item
        }
    }

    func secIdentity(ticker: String, asOf cutoff: Date) throws -> SECCompanyIdentityRecord {
        guard ticker.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}\z"#, options: .regularExpression) != nil else {
            throw BusinessStoreError.sourceMismatch
        }
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT i.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_sec_identities i
                JOIN p1_sec_identity_listings l ON l.record_id = i.record_id AND l.version_id = i.version_id
                JOIN p1_source_documents d ON d.reference = i.source_reference
                WHERE l.ticker = ? AND i.available_at_ms <= ?
                ORDER BY i.record_id, i.available_at_ms, i.version_id
                """, arguments: [ticker, cutoffMS])
        }
        var versions: [String: [SECCompanyIdentityRecord]] = [:]
        for row in rows {
            let item = try Self.decodeSEC(SECCompanyIdentityRecord.self, row: row)
            guard row["record_id"] == item.recordID, row["version_id"] == item.provenance.versionID,
                  row["cik"] == item.cik, item.listings.contains(where: { $0.ticker == ticker }) else {
                throw BusinessStoreError.corruptedStorage
            }
            versions[item.recordID, default: []].append(item)
        }
        let selected = try versions.keys.sorted().map { try AsOfSelector.select(versions[$0]!, cutoff: cutoff) }
        guard selected.count == 1, let identity = selected.first else {
            if selected.isEmpty { throw SnapshotError.missingReference }
            throw ContractError.ambiguousVersion
        }
        return identity
    }

    func secSubmissions(cik: String, asOf cutoff: Date) throws -> [SECSubmissionRecord] {
        guard SECCompanyIdentityRecord.validCIK(cik) else { throw BusinessStoreError.sourceMismatch }
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_sec_submissions s JOIN p1_source_documents d ON d.reference = s.source_reference
                WHERE s.cik = ? AND s.available_at_ms <= ? ORDER BY s.record_id, s.available_at_ms, s.version_id
                """, arguments: [cik, cutoffMS])
        }
        var versions: [String: [SECSubmissionRecord]] = [:]
        for row in rows {
            let item = try Self.decodeSEC(SECSubmissionRecord.self, row: row)
            guard row["record_id"] == item.recordID, row["version_id"] == item.provenance.versionID,
                  row["cik"] == item.cik, row["accession_number"] == item.accessionNumber,
                  row["filing_date"] == item.filingDate.iso8601 else { throw BusinessStoreError.corruptedStorage }
            versions[item.recordID, default: []].append(item)
        }
        return try versions.keys.sorted().map { try AsOfSelector.select(versions[$0]!, cutoff: cutoff) }
    }

    func secFilingDocument(cik: String, accessionNumber: String, fileName: String,
                           asOf cutoff: Date) throws -> SECFilingDocumentRecord {
        guard SECCompanyIdentityRecord.validCIK(cik), SECSubmissionRecord.validAccession(accessionNumber),
              SECSubmissionRecord.validFileName(fileName) else { throw BusinessStoreError.sourceMismatch }
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_sec_filing_documents f JOIN p1_source_documents d ON d.reference = f.source_reference
                WHERE f.cik = ? AND f.accession_number = ? AND f.file_name = ? AND f.available_at_ms <= ?
                ORDER BY f.available_at_ms, f.version_id
                """, arguments: [cik, accessionNumber, fileName, cutoffMS])
        }
        let versions = try rows.map { row -> SECFilingDocumentRecord in
            let item = try Self.decodeSEC(SECFilingDocumentRecord.self, row: row)
            guard row["record_id"] == item.recordID, row["version_id"] == item.provenance.versionID,
                  row["cik"] == item.cik, row["accession_number"] == item.accessionNumber,
                  row["file_name"] == item.fileName else { throw BusinessStoreError.corruptedStorage }
            return item
        }
        guard !versions.isEmpty else { throw SnapshotError.missingReference }
        return try AsOfSelector.select(versions, cutoff: cutoff)
    }

    func secFilingIndex(cik: String, accessionNumber: String,
                        asOf cutoff: Date) throws -> SECFilingIndexRecord {
        guard SECCompanyIdentityRecord.validCIK(cik), SECSubmissionRecord.validAccession(accessionNumber) else {
            throw BusinessStoreError.sourceMismatch
        }
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_sec_filing_indexes f JOIN p1_source_documents d ON d.reference = f.source_reference
                WHERE f.cik = ? AND f.accession_number = ? AND f.available_at_ms <= ?
                ORDER BY f.available_at_ms, f.version_id
                """, arguments: [cik, accessionNumber, cutoffMS])
        }
        let versions = try rows.map { row -> SECFilingIndexRecord in
            let item = try Self.decodeSEC(SECFilingIndexRecord.self, row: row)
            guard row["record_id"] == item.recordID, row["version_id"] == item.provenance.versionID,
                  row["cik"] == item.cik, row["accession_number"] == item.accessionNumber else {
                throw BusinessStoreError.corruptedStorage
            }
            return item
        }
        guard !versions.isEmpty else { throw SnapshotError.missingReference }
        return try AsOfSelector.select(versions, cutoff: cutoff)
    }

    /// Persists the reviewed dictionary and one deterministic normalization result atomically.
    /// All source versions referenced by reported or derived outputs must already exist in SQLite.
    @discardableResult
    func persistNormalization(_ result: FinancialNormalizationResult, dictionary: FinancialFieldDictionary,
                              expectedRevision: UUID) throws -> FinancialPersistenceReceipt {
        try Self.validateNormalization(result, dictionary: dictionary)
        let rules = dictionary.rules.sorted { $0.sourceKey < $1.sourceKey }
        let ruleBytes = try Self.encodeSEC(rules), ruleHash = digest(ruleBytes)
        let resultBytes = try Self.encodeSEC(result), resultHash = digest(resultBytes)
        let cutoffInstant = try MillisecondInstant(rounding: result.asOf)
        let runID = "normalize/" + String(digest(Data((dictionary.version + "|" + cutoffInstant.iso8601 + "|" + resultHash).utf8)).prefix(32))
        let nextRevision = UUID()
        let changes = try database.transaction { db -> (Bool, Int) in
            try Self.secCheckRevision(expectedRevision, db: db)
            let dictionaryInserted: Bool
            if let existing = try String.fetchOne(db, sql: "SELECT content_hash FROM p1_financial_dictionaries WHERE version = ?",
                                                  arguments: [dictionary.version]) {
                guard existing == ruleHash else { throw BusinessStoreError.immutableConflict }
                dictionaryInserted = false
            } else {
                try db.execute(sql: "INSERT INTO p1_financial_dictionaries (version, content_hash, rules_json) VALUES (?, ?, ?)",
                               arguments: [dictionary.version, ruleHash, ruleBytes])
                dictionaryInserted = true
            }
            for version in Set(result.values.flatMap(\.sourceVersions)) {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM p1_sec_facts WHERE version_id = ?", arguments: [version])! > 0
                else { throw BusinessStoreError.sourceMismatch }
            }
            for fact in result.selectedSourceFacts {
                let bytes = try Self.encodeSEC(fact)
                guard let stored = try String.fetchOne(db, sql: """
                    SELECT record_hash FROM p1_sec_facts WHERE record_id = ? AND version_id = ?
                    """, arguments: [fact.recordID, fact.provenance.versionID!]), stored == digest(bytes)
                else { throw BusinessStoreError.sourceMismatch }
            }
            let insertedValues: Int
            if let existing = try String.fetchOne(db, sql: "SELECT result_hash FROM p1_financial_normalization_runs WHERE run_id = ?",
                                                  arguments: [runID]) {
                guard existing == resultHash else { throw BusinessStoreError.immutableConflict }
                insertedValues = 0
            } else {
                try db.execute(sql: """
                    INSERT INTO p1_financial_normalization_runs
                    (run_id, dictionary_version, cutoff_ms, result_hash, result_json) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [runID, dictionary.version, cutoffInstant.milliseconds, resultHash, resultBytes])
                for item in result.values {
                    let bytes = try Self.encodeSEC(item)
                    try db.execute(sql: """
                        INSERT INTO p1_normalized_financial_facts
                        (run_id, normalized_id, field_id, period_type, period_end, available_at_ms,
                         canonical_value, fact_json, fact_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [runID, item.id, item.fieldID, item.periodType.rawValue,
                                          item.periodEnd.iso8601, try MillisecondInstant(rounding: item.availableAt).milliseconds,
                                          item.value.decimalString, bytes, digest(bytes)])
                }
                insertedValues = result.values.count
            }
            if dictionaryInserted || insertedValues > 0 { try Self.secWriteRevision(nextRevision, db: db) }
            return (dictionaryInserted, insertedValues)
        }
        if changes.0 || changes.1 > 0 { currentRevision = nextRevision }
        return FinancialPersistenceReceipt(runID: runID, insertedDictionary: changes.0,
                                           insertedValues: changes.1, revision: currentRevision)
    }

    func normalization(runID: String) throws -> FinancialNormalizationResult {
        guard let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT dictionary_version, cutoff_ms, result_hash, result_json FROM p1_financial_normalization_runs WHERE run_id = ?",
                             arguments: [runID])
        }) else { throw SnapshotError.missingReference }
        let bytes: Data = row["result_json"]
        guard digest(bytes) == row["result_hash"] else { throw BusinessStoreError.corruptedStorage }
        let result = try Self.decodeSEC(FinancialNormalizationResult.self, bytes: bytes)
        guard result.dictionaryVersion == row["dictionary_version"],
              try MillisecondInstant(rounding: result.asOf).milliseconds == row["cutoff_ms"] else {
            throw BusinessStoreError.corruptedStorage
        }
        return result
    }

    func financialDictionary(version: String) throws -> FinancialFieldDictionary {
        guard let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT content_hash, rules_json FROM p1_financial_dictionaries WHERE version = ?",
                             arguments: [version])
        }) else { throw SnapshotError.missingReference }
        let bytes: Data = row["rules_json"]
        guard digest(bytes) == row["content_hash"] else { throw BusinessStoreError.corruptedStorage }
        return try FinancialFieldDictionary(version: version,
            rules: Self.decodeSEC([FinancialMappingRule].self, bytes: bytes))
    }

    private func ingestSEC<Item: ProviderRecord & Codable>(_ accepted: AcceptedProviderPayload<Item>,
        capability: ProviderCapability, expectedRevision: UUID,
        insert: (Item, String, MillisecondInstant, Data, SourceDocument, Database) throws -> Bool) throws -> SECIngestReceipt {
        let result = accepted.exchange.result, raw = accepted.rawPayload
        guard result.request.capability == capability, [.complete, .partial, .empty].contains(result.status) else {
            throw ContractError.invalidCoverage
        }
        let document = try SourceDocument(reference: raw.reference, providerID: result.request.providerID,
            feedID: result.request.feedID, endpoint: capability.endpointDescriptor,
            receivedAt: MillisecondInstant(rounding: raw.storageAvailableAt),
            availableAt: MillisecondInstant(rounding: raw.storageAvailableAt), mediaType: raw.mediaType,
            evidenceRef: raw.evidenceRef, licenseRef: raw.licenseRef, payload: raw.bytes)
        let encoded = try result.items.map { item -> (Item, String, MillisecondInstant, Data) in
            try Self.validateSECSource(item.provenance, document: document)
            guard let version = item.provenance.versionID else { throw BusinessStoreError.sourceMismatch }
            return (item, version, try MillisecondInstant(rounding: item.provenance.availability.upperBound()), try Self.encodeSEC(item))
        }
        let nextRevision = UUID()
        let changes = try database.transaction { db -> (Int, Int) in
            try Self.secCheckRevision(expectedRevision, db: db)
            var documentInserted = try Self.insertSECDocument(document, db: db)
            var records = 0
            for value in encoded where try insert(value.0, value.1, value.2, value.3, document, db) { records += 1 }
            // A repeated retrieval can have a new request ID and timestamp while carrying no new
            // source records. Do not retain that transient aggregate or advance business history.
            if documentInserted && records == 0 && !encoded.isEmpty {
                try db.execute(sql: "DELETE FROM p1_source_documents WHERE reference = ?",
                               arguments: [document.reference])
                documentInserted = false
            }
            if documentInserted || records > 0 { try Self.secWriteRevision(nextRevision, db: db) }
            return (documentInserted ? 1 : 0, records)
        }
        if changes.0 + changes.1 > 0 { currentRevision = nextRevision }
        return SECIngestReceipt(insertedDocuments: changes.0, insertedRecords: changes.1, revision: currentRevision)
    }

    private static func insertSECRecord(table: String, key: [String], bytes: Data, db: Database,
        insert: () throws -> Void) throws -> Bool {
        let keyColumns = table == "p1_sec_facts" ? ["record_id", "version_id"] : ["record_id", "version_id"]
        let predicate = zip(keyColumns, key).map { $0.0 + " = ?" }.joined(separator: " AND ")
        guard ["p1_sec_identities", "p1_sec_submissions", "p1_sec_facts", "p1_sec_filing_indexes", "p1_sec_filing_documents"].contains(table)
        else { throw BusinessStoreError.sourceMismatch }
        if let existing = try Row.fetchOne(db, sql: "SELECT record_hash, record_json FROM " + table + " WHERE " + predicate,
                                           arguments: StatementArguments(key)) {
            let existingBytes: Data = existing["record_json"]
            guard digest(existingBytes) == existing["record_hash"] else { throw BusinessStoreError.corruptedStorage }
            guard try sourceRecordHash(existingBytes) == sourceRecordHash(bytes) else {
                throw BusinessStoreError.immutableConflict
            }
            return false
        }
        try insert(); return true
    }

    /// Hashes the SEC source record while excluding retrieval-only exchange identity. Source
    /// fields and stable provider/rights metadata remain covered, so a changed value cannot be
    /// hidden as a duplicate, while refetching identical source content is idempotent.
    private static func sourceRecordHash(_ bytes: Data) throws -> String {
        guard var record = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let provenance = record["provenance"] as? [String: Any] else {
            throw BusinessStoreError.corruptedStorage
        }
        let stableKeys: Set<String> = ["providerID", "feedID", "evidenceRef", "origin",
            "endpointDescriptor", "versionID", "versionKind", "normalizationVersion",
            "licenseRef", "attribution"]
        record["provenance"] = provenance.filter { stableKeys.contains($0.key) }
        let canonical = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return digest(canonical)
    }
    private static func validateNormalization(_ result: FinancialNormalizationResult,
        dictionary: FinancialFieldDictionary) throws {
        let cutoff = result.asOf
        guard cutoff.timeIntervalSince1970.isFinite, result.dictionaryVersion == dictionary.version,
              Set(result.values.map(\.id)).count == result.values.count,
              Set(result.selectedSourceFacts.map(\.recordID)).count == result.selectedSourceFacts.count else {
            throw BusinessStoreError.sourceMismatch
        }
        let selectedFactIDs = Set(result.selectedSourceFacts.map(\.factID))
        let selectedVersions = Set(result.selectedSourceFacts.compactMap(\.provenance.versionID))
        let selectedRecords = Set(result.selectedSourceFacts.map(\.recordID))
        guard Set(result.unmappedSourceFacts.map(\.recordID)).isSubset(of: selectedRecords) else {
            throw BusinessStoreError.sourceMismatch
        }
        for fact in result.selectedSourceFacts {
            guard fact.provenance.isAvailable(asOf: cutoff) else { throw BusinessStoreError.sourceMismatch }
        }
        for value in result.values {
            guard value.dictionaryVersion == dictionary.version, value.availableAt <= cutoff,
                  !value.sourceFactIDs.isEmpty, !value.sourceVersions.isEmpty,
                  Set(value.sourceFactIDs).isSubset(of: selectedFactIDs),
                  Set(value.sourceVersions).isSubset(of: selectedVersions) else {
                throw BusinessStoreError.sourceMismatch
            }
        }
        guard try FinancialNormalizer.normalizeComplete(result.selectedSourceFacts,
                                                         dictionary: dictionary, asOf: cutoff) == result else {
            throw BusinessStoreError.sourceMismatch
        }
    }

    private static func insertSECDocument(_ document: SourceDocument, db: Database) throws -> Bool {
        let metadata = try document.metadataHash
        if let existing = try String.fetchOne(db, sql: "SELECT metadata_hash FROM p1_source_documents WHERE reference = ?",
                                              arguments: [document.reference]) {
            guard existing == metadata else { throw BusinessStoreError.immutableConflict }
            return false
        }
        try db.execute(sql: """
            INSERT INTO p1_source_documents
            (reference, metadata_hash, content_hash, provider_id, feed_id, endpoint_descriptor,
             received_at_ms, available_at_ms, media_type, evidence_ref, license_ref, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [document.reference, metadata, document.contentHash, document.providerID,
                              document.feedID, document.endpoint.rawValue, document.receivedAt.milliseconds,
                              document.availableAt.milliseconds, document.mediaType, document.evidenceRef,
                              document.licenseRef, document.payload])
        return true
    }
    private static func validateSECSource(_ provenance: Provenance, document: SourceDocument) throws {
        guard provenance.providerID == document.providerID, provenance.feedID == document.feedID,
              provenance.endpointDescriptor == document.endpoint.rawValue,
              provenance.rawObjectRef == document.reference, provenance.rawHash == document.contentHash,
              provenance.evidenceRef == document.evidenceRef, provenance.licenseRef == document.licenseRef,
              try MillisecondInstant(rounding: provenance.receivedAt) <= document.receivedAt
        else { throw BusinessStoreError.sourceMismatch }
    }
    private static func encodeSEC<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer(); try value.encode(MillisecondInstant(rounding: date).iso8601)
        }
        return try encoder.encode(value)
    }
    private static func decodeSEC<T: Decodable>(_ type: T.Type, bytes: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try MillisecondInstant(iso8601: decoder.singleValueContainer().decode(String.self)).date
        }
        return try decoder.decode(type, from: bytes)
    }
    private static func decodeSEC<T: Decodable>(_ type: T.Type, row: Row) throws -> T {
        let bytes: Data = row["record_json"]
        guard digest(bytes) == row["record_hash"] else { throw BusinessStoreError.corruptedStorage }
        let item = try decodeSEC(type, bytes: bytes)
        if let record = item as? any ProviderRecord {
            guard record.provenance.rawHash == row["source_content_hash"],
                  record.provenance.providerID == row["source_provider_id"],
                  record.provenance.feedID == row["source_feed_id"],
                  record.provenance.endpointDescriptor == row["source_endpoint"],
                  record.provenance.evidenceRef == row["source_evidence"],
                  record.provenance.licenseRef == row["source_license"] else {
                throw BusinessStoreError.corruptedStorage
            }
        }
        return item
    }
    private static func secCheckRevision(_ expected: UUID, db: Database) throws {
        guard let value = try String.fetchOne(db, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1"),
              UUID(uuidString: value) == expected else { throw SnapshotError.stalePlan }
    }
    private static func secWriteRevision(_ revision: UUID, db: Database) throws {
        try db.execute(sql: "UPDATE p1_store_metadata SET revision = ? WHERE singleton = 1",
                       arguments: [revision.uuidString.lowercased()])
    }
}
