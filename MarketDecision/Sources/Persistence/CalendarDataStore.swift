import Foundation
import GRDB
import CoreDomain
import DataContracts
import DataProviders

public enum TradingCalendarError: Error, Equatable {
    case incompleteCoverage
    case nonTradingDay
    case unknownSession
}
public struct CalendarIngestReceipt: Sendable, Equatable {
    public let insertedDocuments: Int
    public let insertedRecords: Int
    public let revision: UUID
}

public extension BusinessDataStore {
    /// Mandatory production entry: the exchange is constructible only after ProviderSession accepts
    /// the exact dispatched request/result. Persistence then rechecks raw bytes and record linkage.
    @discardableResult
    func ingestMarketCalendar(_ accepted: AcceptedProviderPayload<MarketSessionRecord>,
                              expectedRevision: UUID) throws -> CalendarIngestReceipt {
        let result = accepted.exchange.result
        guard result.status == .complete, result.request.capability == .marketCalendar,
              case let .observationDates(range)? = result.request.range else { throw TradingCalendarError.incompleteCoverage }
        let expected = Set(try range.start.days(through: range.end).flatMap { date in
            USEquityMarket.allCases.map { $0.rawValue + "/" + date.iso8601 }
        })
        guard result.items.count == expected.count, Set(result.items.map(\.recordID)) == expected else {
            throw TradingCalendarError.incompleteCoverage
        }
        try result.items.forEach { try $0.validate() }
        return try ingestAccepted(accepted, expectedRevision: expectedRevision) { item, bytes, document, db in
            try Self.validateCalendarSource(item.provenance, document: document)
            let version = item.provenance.versionID!, available = try MillisecondInstant(rounding: item.provenance.availability.upperBound())
            if let existing = try String.fetchOne(db, sql: "SELECT record_hash FROM p1_market_sessions WHERE market = ? AND session_date = ? AND version_id = ?",
                                                  arguments: [item.market.rawValue, item.date.iso8601, version]) {
                guard existing == digest(bytes) else { throw BusinessStoreError.immutableConflict }
                return false
            }
            try db.execute(sql: """
                INSERT INTO p1_market_sessions
                (market, session_date, record_id, version_id, available_at_ms, state, opens_at_ms, closes_at_ms,
                 source_reference, record_hash, record_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [item.market.rawValue, item.date.iso8601, item.recordID, version,
                                  available.milliseconds, item.state.rawValue,
                                  try item.opensAt.map { try MillisecondInstant(rounding: $0).milliseconds },
                                  try item.closesAt.map { try MillisecondInstant(rounding: $0).milliseconds },
                                  document.reference, digest(bytes), bytes])
            return true
        }
    }

    @discardableResult
    func ingestCorporateEvents(_ accepted: AcceptedProviderPayload<CorporateEventRecord>,
                               expectedRevision: UUID) throws -> CalendarIngestReceipt {
        let result = accepted.exchange.result
        guard [.earningsCalendar, .dividends].contains(result.request.capability),
              result.status == .complete || result.status == .empty else { throw ContractError.invalidCoverage }
        try result.items.forEach { try $0.validate() }
        return try ingestAccepted(accepted, expectedRevision: expectedRevision) { item, bytes, document, db in
            try Self.validateCalendarSource(item.provenance, document: document)
            let version = item.provenance.versionID!
            let available = try? MillisecondInstant(rounding: item.provenance.availability.upperBound())
            if let existing = try String.fetchOne(db, sql: "SELECT record_hash FROM p1_company_events WHERE record_id = ? AND version_id = ?",
                                                  arguments: [item.recordID, version]) {
                guard existing == digest(bytes) else { throw BusinessStoreError.immutableConflict }
                return false
            }
            try db.execute(sql: """
                INSERT INTO p1_company_events
                (record_id, version_id, symbol, kind, event_date, availability_known, available_at_ms,
                 source_reference, record_hash, record_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [item.recordID, version, item.symbol, item.kind.rawValue, item.eventDate?.iso8601,
                                  available == nil ? 0 : 1, available?.milliseconds,
                                  document.reference, digest(bytes), bytes])
            return true
        }
    }

    /// A complete day-by-day result or an error. Missing rows and unknown rows never become regular.
    func marketSessions(market: USEquityMarket, range: MarketDateRange, asOf cutoff: Date) throws -> [MarketSessionRecord] {
        try range.validate()
        let cutoffMS = try MillisecondInstant(rounding: cutoff).milliseconds
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_market_sessions s JOIN p1_source_documents d ON d.reference = s.source_reference
                WHERE s.market = ? AND s.session_date >= ? AND s.session_date <= ? AND s.available_at_ms <= ?
                ORDER BY s.session_date, s.available_at_ms, s.version_id
                """, arguments: [market.rawValue, range.start.iso8601, range.end.iso8601, cutoffMS])
        }
        var versions: [String: [MarketSessionRecord]] = [:]
        for row in rows {
            let item = try Self.decodeCalendar(MarketSessionRecord.self, row: row)
            guard row["market"] == item.market.rawValue, row["session_date"] == item.date.iso8601,
                  row["record_id"] == item.recordID, row["version_id"] == item.provenance.versionID,
                  row["state"] == item.state.rawValue,
                  Self.optionalMilliseconds(item.opensAt) == row["opens_at_ms"],
                  Self.optionalMilliseconds(item.closesAt) == row["closes_at_ms"]
            else { throw BusinessStoreError.corruptedStorage }
            versions[item.recordID, default: []].append(item)
        }
        let selected = try versions.keys.sorted().map { try AsOfSelector.select(versions[$0]!, cutoff: cutoff) }
        guard selected.count == (try range.start.days(through: range.end)).count else { throw TradingCalendarError.incompleteCoverage }
        return selected.sorted { $0.date < $1.date }
    }

    func marketSession(market: USEquityMarket, on date: MarketDate, asOf cutoff: Date) throws -> MarketSessionRecord {
        guard let session = try marketSessions(market: market, range: .init(start: date, end: date), asOf: cutoff).first
        else { throw TradingCalendarError.incompleteCoverage }
        return session
    }

    func validateExpiration(_ date: MarketDate, market: USEquityMarket, asOf cutoff: Date) throws {
        let session = try marketSession(market: market, on: date, asOf: cutoff)
        switch session.state {
        case .regular, .earlyClose: return
        case .closed: throw TradingCalendarError.nonTradingDay
        case .unknown: throw TradingCalendarError.unknownSession
        }
    }

    /// Selects one version per stable event identity before applying the event-date filter. This
    /// prevents an older date from resurfacing when a later revision moves an event out of range.
    func corporateEvents(symbol: String, kind: CorporateEventKind, range: MarketDateRange,
                         asOf cutoff: Date? = nil, includeUnknownDates: Bool = true) throws -> [CorporateEventRecord] {
        try range.validate()
        guard symbol.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}\z"#, options: .regularExpression) != nil
        else { throw BusinessStoreError.sourceMismatch }
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.*, d.received_at_ms AS source_received_at_ms,
                       d.content_hash AS source_content_hash, d.provider_id AS source_provider_id,
                       d.feed_id AS source_feed_id, d.endpoint_descriptor AS source_endpoint,
                       d.evidence_ref AS source_evidence, d.license_ref AS source_license
                FROM p1_company_events e JOIN p1_source_documents d ON d.reference = e.source_reference
                WHERE e.symbol = ? AND e.kind = ?
                ORDER BY e.record_id, e.available_at_ms, d.received_at_ms, e.version_id
                """, arguments: [symbol, kind.rawValue])
        }
        var versions: [String: [(CorporateEventRecord, Int64)]] = [:]
        for row in rows {
            let item = try Self.decodeCalendar(CorporateEventRecord.self, row: row)
            let known = (row["availability_known"] as Int) == 1
            let storedAvailable: Int64? = row["available_at_ms"]
            let actualAvailable = try? MillisecondInstant(rounding: item.provenance.availability.upperBound()).milliseconds
            guard row["record_id"] == item.recordID, row["version_id"] == item.provenance.versionID,
                  row["symbol"] == item.symbol, row["kind"] == item.kind.rawValue,
                  row["event_date"] == item.eventDate?.iso8601, known == (actualAvailable != nil),
                  storedAvailable == actualAvailable else { throw BusinessStoreError.corruptedStorage }
            versions[item.recordID, default: []].append((item, row["source_received_at_ms"]))
        }
        var selected: [CorporateEventRecord] = []
        for candidates in versions.values {
            if let cutoff {
                let eligible = candidates.compactMap { item -> (CorporateEventRecord, Date)? in
                    guard item.0.provenance.isAvailable(asOf: cutoff), let date = try? item.0.provenance.availability.upperBound() else { return nil }
                    return (item.0, date)
                }
                guard let latest = eligible.map(\.1).max() else { continue }
                let matches = eligible.filter { $0.1 == latest }
                guard matches.count == 1 else { throw ContractError.ambiguousVersion }
                selected.append(matches[0].0)
                continue
            }
            let scored = candidates.map { candidate -> (CorporateEventRecord, Int64) in
                let available = try? MillisecondInstant(rounding: candidate.0.provenance.availability.upperBound()).milliseconds
                return (candidate.0, available ?? candidate.1)
            }
            guard let latest = scored.map(\.1).max() else { throw BusinessStoreError.corruptedStorage }
            let matches = scored.filter { $0.1 == latest }
            guard matches.count == 1 else { throw ContractError.ambiguousVersion }
            selected.append(matches[0].0)
        }
        return selected.filter { item in
            guard let date = item.eventDate else { return includeUnknownDates }
            return range.start <= date && date <= range.end
        }.sorted { lhs, rhs in
            switch (lhs.eventDate, rhs.eventDate) {
            case let (left?, right?): return left == right ? lhs.recordID < rhs.recordID : left < right
            case (nil, nil): return lhs.recordID < rhs.recordID
            case (.some, nil): return true
            case (nil, .some): return false
            }
        }
    }

    private func ingestAccepted<Item: ProviderRecord>(_ accepted: AcceptedProviderPayload<Item>, expectedRevision: UUID,
        insert: (Item, Data, SourceDocument, Database) throws -> Bool) throws -> CalendarIngestReceipt where Item: Encodable {
        let result = accepted.exchange.result, raw = accepted.rawPayload
        let document = try SourceDocument(reference: raw.reference, providerID: result.request.providerID,
            feedID: result.request.feedID, endpoint: result.request.capability.endpointDescriptor,
            receivedAt: MillisecondInstant(rounding: raw.storageAvailableAt),
            availableAt: MillisecondInstant(rounding: raw.storageAvailableAt), mediaType: raw.mediaType,
            evidenceRef: raw.evidenceRef, licenseRef: raw.licenseRef, payload: raw.bytes)
        guard result.items.allSatisfy({ $0.provenance.rawObjectRef == document.reference && $0.provenance.rawHash == document.contentHash })
        else { throw BusinessStoreError.sourceMismatch }
        let encoded = try result.items.map { ($0, try Self.encodeCalendar($0)) }
        let nextRevision = UUID()
        let changes = try database.transaction { db -> (Int, Int) in
            try Self.calendarCheckRevision(expectedRevision, db: db)
            let documentInserted = try Self.insertCalendarDocument(document, db: db)
            var count = 0
            for (item, bytes) in encoded where try insert(item, bytes, document, db) { count += 1 }
            if documentInserted || count > 0 { try Self.calendarWriteRevision(nextRevision, db: db) }
            return (documentInserted ? 1 : 0, count)
        }
        if changes.0 + changes.1 > 0 { currentRevision = nextRevision }
        return CalendarIngestReceipt(insertedDocuments: changes.0, insertedRecords: changes.1, revision: currentRevision)
    }

    private static func insertCalendarDocument(_ document: SourceDocument, db: Database) throws -> Bool {
        let metadata = try document.metadataHash
        if let existing = try String.fetchOne(db, sql: "SELECT metadata_hash FROM p1_source_documents WHERE reference = ?", arguments: [document.reference]) {
            guard existing == metadata else { throw BusinessStoreError.immutableConflict }
            return false
        }
        try db.execute(sql: """
            INSERT INTO p1_source_documents
            (reference, metadata_hash, content_hash, provider_id, feed_id, endpoint_descriptor,
             received_at_ms, available_at_ms, media_type, evidence_ref, license_ref, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [document.reference, metadata, document.contentHash, document.providerID, document.feedID,
                              document.endpoint.rawValue, document.receivedAt.milliseconds, document.availableAt.milliseconds,
                              document.mediaType, document.evidenceRef, document.licenseRef, document.payload])
        return true
    }

    private static func validateCalendarSource(_ provenance: Provenance, document: SourceDocument) throws {
        guard provenance.providerID == document.providerID, provenance.feedID == document.feedID,
              provenance.endpointDescriptor == document.endpoint.rawValue,
              provenance.rawObjectRef == document.reference, provenance.rawHash == document.contentHash,
              provenance.evidenceRef == document.evidenceRef, provenance.licenseRef == document.licenseRef,
              try MillisecondInstant(rounding: provenance.receivedAt) <= document.receivedAt
        else { throw BusinessStoreError.sourceMismatch }
    }

    private static func encodeCalendar<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer(); try value.encode(MillisecondInstant(rounding: date).iso8601)
        }
        return try encoder.encode(value)
    }
    private static func decodeCalendar<T: Decodable>(_ type: T.Type, row: Row) throws -> T {
        let bytes: Data = row["record_json"]
        guard digest(bytes) == row["record_hash"], row["source_reference"] as String? != nil else { throw BusinessStoreError.corruptedStorage }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try MillisecondInstant(iso8601: decoder.singleValueContainer().decode(String.self)).date
        }
        let item = try decoder.decode(type, from: bytes)
        if let record = item as? any ProviderRecord {
            guard record.provenance.rawHash == row["source_content_hash"],
                  record.provenance.providerID == row["source_provider_id"],
                  record.provenance.feedID == row["source_feed_id"],
                  record.provenance.endpointDescriptor == row["source_endpoint"],
                  record.provenance.evidenceRef == row["source_evidence"],
                  record.provenance.licenseRef == row["source_license"] else { throw BusinessStoreError.corruptedStorage }
        }
        return item
    }
    private static func optionalMilliseconds(_ date: Date?) -> Int64? {
        try? date.map { try MillisecondInstant(rounding: $0).milliseconds }
    }
    private static func calendarCheckRevision(_ expected: UUID, db: Database) throws {
        guard let value = try String.fetchOne(db, sql: "SELECT revision FROM p1_store_metadata WHERE singleton = 1"),
              UUID(uuidString: value) == expected else { throw SnapshotError.stalePlan }
    }
    private static func calendarWriteRevision(_ revision: UUID, db: Database) throws {
        try db.execute(sql: "UPDATE p1_store_metadata SET revision = ? WHERE singleton = 1",
                       arguments: [revision.uuidString.lowercased()])
    }
}
