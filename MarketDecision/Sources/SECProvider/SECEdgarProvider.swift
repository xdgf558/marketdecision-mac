import Foundation
import CoreDomain
import DataContracts
import DataProviders

public enum SECAdapterError: Error, Equatable {
    case invalidConfiguration
    case invalidResource
    case malformedResponse
    case incompleteColumns
}

public protocol SECRequestGate: Sendable { func wait() async throws }

/// SEC fair-access limit is at most ten aggregate requests per second. All application
/// callers must share a gate; other applications/machines need their own coordinated budget.
public actor SECRateLimiter: SECRequestGate {
    public let requestsPerSecond: Int
    private let minimumInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var nextRequestAt: ContinuousClock.Instant?
    public init(requestsPerSecond: Int = 10) throws {
        let clock = ContinuousClock()
        try self.init(requestsPerSecond: requestsPerSecond, now: { clock.now },
                      sleepUntil: { try await clock.sleep(until: $0) })
    }
    // Internal deterministic clock injection exercises reentrant/late wakeups without wall-time waits.
    init(requestsPerSecond: Int, now: @escaping @Sendable () -> ContinuousClock.Instant,
         sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) throws {
        guard (1...10).contains(requestsPerSecond) else { throw SECAdapterError.invalidConfiguration }
        self.requestsPerSecond = requestsPerSecond
        let rate = Int64(requestsPerSecond)
        self.minimumInterval = .nanoseconds((1_000_000_000 + rate - 1) / rate)
        self.now = now; self.sleepUntil = sleepUntil
    }
    public func wait() async throws {
        try Task.checkCancellation()
        // An actor is reentrant across sleep. Recheck after *every* wake: another waiter may
        // have taken the slot, or several overdue sleepers may have resumed together.
        while let deadline = nextRequestAt, now() < deadline {
            try await sleepUntil(deadline)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        nextRequestAt = now().advanced(by: minimumInterval)
    }
}

/// Public EDGAR adapter. It requires no API key, but it does require an explicit identifying
/// User-Agent and a request gate. Construction does not qualify SEC data for any application use.
public struct SECEdgarProvider<Transport: HTTPTransport, Gate: SECRequestGate>: FundamentalsProvider {
    public static var providerID: String { "sec-edgar" }
    public static var feedID: String { "public-edgar" }
    public static var configurationVersion: String { "sec-edgar.v1" }

    public typealias Identity = SECCompanyIdentityRecord
    public typealias Submission = SECSubmissionRecord
    public typealias Facts = SECCompanyFactRecord
    public typealias FilingIndex = SECFilingIndexRecord
    public typealias FilingDocument = SECFilingDocumentRecord

    public let id = Self.providerID
    public let capabilitySnapshot: CapabilitySnapshot
    private let userAgent: String
    private let transport: Transport
    private let gate: Gate
    private let evidenceRef: String
    private let licenseRef: String
    private let now: @Sendable () -> Date

    public init(userAgent: String, transport: Transport, gate: Gate, evidenceRef: String,
                licenseRef: String, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard Self.validUserAgent(userAgent), !evidenceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !licenseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SECAdapterError.invalidConfiguration
        }
        self.userAgent = userAgent; self.transport = transport; self.gate = gate
        self.evidenceRef = evidenceRef; self.licenseRef = licenseRef; self.now = now
        capabilitySnapshot = CapabilitySnapshot(providerID: Self.providerID, version: Self.configurationVersion,
            feeds: [Self.feedID], capabilities: [.companyIdentity, .submissions, .companyFacts, .filingIndex, .filingDocument])
    }

    public func companyIdentity(request: ProviderRequest) async throws -> ProviderPayloadResponse<SECCompanyIdentityRecord> {
        try await fetch(request, capability: .companyIdentity, mediaType: "application/json") { data, raw, receivedAt in
            try parseIdentity(data, request: request, raw: raw, receivedAt: receivedAt)
        }
    }
    public func submissions(request: ProviderRequest) async throws -> ProviderPayloadResponse<SECSubmissionRecord> {
        try await fetch(request, capability: .submissions, mediaType: "application/json") { data, raw, receivedAt in
            try parseSubmissions(data, request: request, raw: raw, receivedAt: receivedAt)
        }
    }
    public func companyFacts(request: ProviderRequest) async throws -> ProviderPayloadResponse<SECCompanyFactRecord> {
        try await fetch(request, capability: .companyFacts, mediaType: "application/json") { data, raw, receivedAt in
            (try parseFacts(data, request: request, raw: raw, receivedAt: receivedAt), [])
        }
    }
    public func filingIndex(request: ProviderRequest) async throws -> ProviderPayloadResponse<SECFilingIndexRecord> {
        try await fetch(request, capability: .filingIndex, mediaType: "application/json") { data, raw, receivedAt in
            ([try parseFilingIndex(data, request: request, raw: raw, receivedAt: receivedAt)], [])
        }
    }
    public func filingDocument(request: ProviderRequest) async throws -> ProviderPayloadResponse<SECFilingDocumentRecord> {
        try await fetch(request, capability: .filingDocument, mediaType: nil) { _, raw, receivedAt in
            ([try filingDocumentMetadata(request: request, raw: raw, receivedAt: receivedAt)], [])
        }
    }

    private func fetch<Item: ProviderRecord>(_ request: ProviderRequest, capability: ProviderCapability,
        mediaType: String?, parse: (Data, ProviderRawPayload, Date) throws -> ([Item], [String])) async throws
        -> ProviderPayloadResponse<Item> {
        try Task.checkCancellation()
        guard request.providerID == id, request.feedID == Self.feedID, request.capability == capability,
              case .latest = request.mode else { throw ContractError.mismatchedRequest }
        let url = try endpoint(for: request)
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json, text/html, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        try await gate.wait()
        let payload = try await transport.send(urlRequest)
        try Task.checkCancellation()
        guard (200...299).contains(payload.statusCode) else {
            if payload.statusCode == 404 { throw ProviderFailure.symbolUnavailable }
            throw ProviderFailure.fromHTTP(payload.statusCode)
        }
        let receivedAt = max(now(), request.requestedAt)
        let actualMediaType = mediaType ?? payload.mediaType ?? "application/octet-stream"
        let raw = try ProviderRawPayload(reference: "provider/sec-edgar/" + request.id.uuidString.lowercased(),
            mediaType: actualMediaType, bytes: payload.body, storageAvailableAt: receivedAt,
            evidenceRef: evidenceRef, licenseRef: licenseRef)
        let (parsed, continuations) = try parse(raw.bytes, raw, receivedAt)
        let items = parsed.filter { item in
            guard let window = request.range else { return true }
            return window.contains(item.provenance)
        }
        let result = try ProviderResult(request: request, receivedAt: receivedAt, items: items,
            coverage: .init(expectedCount: items.count, truncated: !continuations.isEmpty), nextPageToken: continuations.first,
            emptyReason: items.isEmpty && continuations.isEmpty ? .noResults : nil)
        return ProviderPayloadResponse(result: result, rawPayload: raw, continuationTokens: continuations)
    }

    private func endpoint(for request: ProviderRequest) throws -> URL {
        let path: String, host: String
        switch request.capability {
        case .companyIdentity:
            guard Self.validTicker(request.resourceID), request.pageToken == nil else { throw SECAdapterError.invalidResource }
            host = "www.sec.gov"; path = "/files/company_tickers_exchange.json"
        case .submissions:
            guard SECCompanyIdentityRecord.validCIK(request.resourceID) else { throw SECAdapterError.invalidResource }
            host = "data.sec.gov"
            if let page = request.pageToken {
                guard Self.validContinuation(page, cik: request.resourceID)
                else { throw SECAdapterError.invalidResource }
                path = "/submissions/" + page
            } else { path = "/submissions/CIK" + request.resourceID + ".json" }
        case .companyFacts:
            guard SECCompanyIdentityRecord.validCIK(request.resourceID), request.pageToken == nil else { throw SECAdapterError.invalidResource }
            host = "data.sec.gov"; path = "/api/xbrl/companyfacts/CIK" + request.resourceID + ".json"
        case .filingIndex, .filingDocument:
            let resource = try SECArchiveResource(request.resourceID, expectsDocument: request.capability == .filingDocument)
            host = "www.sec.gov"; path = resource.archivePath
        default: throw SECAdapterError.invalidResource
        }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path
        guard let url = components.url, url.user == nil, url.password == nil, url.query == nil else {
            throw SECAdapterError.invalidResource
        }
        return url
    }

    private func provenance(request: ProviderRequest, raw: ProviderRawPayload, receivedAt: Date,
        sourceEventAt: Date?, observationDate: MarketDate?, availability: AvailabilityEvidence,
        version: String) -> Provenance {
        Provenance(providerID: id, feedID: Self.feedID, sourceEventAt: sourceEventAt,
            receivedAt: receivedAt, availableAt: nil, evidenceRef: evidenceRef, origin: .filing,
            endpointDescriptor: request.capability.endpointDescriptor.rawValue, requestedAt: request.requestedAt,
            requestID: request.id, observationDate: observationDate, versionID: version,
            versionKind: .sourceVersion, availability: availability, rawObjectRef: raw.reference,
            rawHash: raw.contentHash, normalizationVersion: "sec-edgar.decode.v1", licenseRef: licenseRef,
            attribution: "U.S. Securities and Exchange Commission")
    }

    private func parseIdentity(_ data: Data, request: ProviderRequest, raw: ProviderRawPayload,
        receivedAt: Date) throws -> ([SECCompanyIdentityRecord], [String]) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = object["fields"] as? [String], let rows = object["data"] as? [[Any]],
              Set(fields).count == fields.count,
              let cikIndex = fields.firstIndex(of: "cik"), let nameIndex = fields.firstIndex(of: "name"),
              let tickerIndex = fields.firstIndex(of: "ticker"), let exchangeIndex = fields.firstIndex(of: "exchange")
        else { throw SECAdapterError.malformedResponse }
        var grouped: [String: (String, [SECTickerListing])] = [:]
        for row in rows {
            guard row.indices.contains(tickerIndex), let ticker = row[tickerIndex] as? String else {
                throw SECAdapterError.incompleteColumns
            }
            guard ticker.uppercased() == request.resourceID else { continue }
            // Exchange may be null on unrelated mappings. Never invent an exchange for the
            // selected ticker or let an unrelated incomplete listing poison a valid lookup.
            guard row.indices.contains(cikIndex), row.indices.contains(nameIndex), row.indices.contains(exchangeIndex),
                  let name = row[nameIndex] as? String, let exchange = row[exchangeIndex] as? String,
                  !exchange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SECAdapterError.incompleteColumns
            }
            let encodedCIK = try JSONSerialization.data(withJSONObject: [row[cikIndex]])
            let decodedCIK = try JSONDecoder().decode([LosslessText].self, from: encodedCIK)
            guard let sourceCIK = decodedCIK.first?.text else { throw SECAdapterError.malformedResponse }
            let cik = try Self.strictCIK(sourceCIK)
            let listing = try SECTickerListing(ticker: ticker.uppercased(), exchange: exchange)
            if let prior = grouped[cik] {
                guard prior.0 == name, prior.1 == [listing] else { throw SECAdapterError.malformedResponse }
            } else { grouped[cik] = (name, [listing]) }
        }
        // SEC describes this as a search association file, not an authoritative security
        // master. An ambiguous ticker must not silently select one issuer.
        guard grouped.count <= 1 else { throw SECAdapterError.malformedResponse }
        let availability = AvailabilityEvidence.instant(receivedAt, evidence: "SEC mapping retrieval time")
        let records = try grouped.keys.sorted().map { cik in
            let entry = grouped[cik]!
            let listings = entry.1.sorted { ($0.ticker, $0.exchange) < ($1.ticker, $1.exchange) }
            let version = try Self.sourceVersion("sec.identity", [
                .init("cik", .string(cik)), .init("name", .string(entry.0)),
                .init("listings", .array(listings.map {
                    .object([.init("ticker", .string($0.ticker)), .init("exchange", .string($0.exchange))])
                }))
            ])
            return try SECCompanyIdentityRecord(recordID: "sec/issuer/" + cik, cik: cik, name: entry.0,
                listings: listings, status: .unknown,
                provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                    sourceEventAt: request.requestedAt, observationDate: nil, availability: availability,
                    version: version))
        }
        return (records, [])
    }

    private func parseSubmissions(_ data: Data, request: ProviderRequest, raw: ProviderRawPayload,
        receivedAt: Date) throws -> ([SECSubmissionRecord], [String]) {
        let decoder = JSONDecoder()
        let envelope: SECSubmissionsEnvelope
        do { envelope = try decoder.decode(SECSubmissionsEnvelope.self, from: data) }
        catch { throw SECAdapterError.malformedResponse }
        let responseCIK = try envelope.cik.map { try Self.strictCIK($0.text) }
        guard (responseCIK ?? request.resourceID) == request.resourceID,
              responseCIK != nil || request.pageToken != nil else {
            throw SECAdapterError.invalidResource
        }
        let columns = envelope.filings?.recent ?? envelope.recent ?? envelope.topLevelRecent
        guard let columns else { throw SECAdapterError.malformedResponse }
        let count = columns.accessionNumber.count
        guard columns.hasUniformCount(count) else { throw SECAdapterError.incompleteColumns }
        var records: [SECSubmissionRecord] = []
        for index in 0..<count {
            let accession = columns.accessionNumber[index]
            let filingDate = try MarketDate(iso8601: columns.filingDate[index])
            let reportDate = columns.reportDate[index].isEmpty ? nil : try MarketDate(iso8601: columns.reportDate[index])
            let accepted = try Self.optionalInstant(columns.acceptanceDateTime[index])
            let sourceEvent = try accepted ?? filingDate.start(in: TimeZone(identifier: "America/New_York")!)
            let availability: AvailabilityEvidence = accepted.map { .instant($0, evidence: "SEC acceptanceDateTime") }
                ?? .dateOnly(filingDate, timeZoneID: "America/New_York", evidence: "SEC filingDate only")
            let version = try Self.sourceVersion("sec.submission", [
                .init("cik", .string(request.resourceID)), .init("accession", .string(accession)),
                .init("form", .string(columns.form[index])), .init("filingDate", .string(filingDate.iso8601)),
                .init("reportDate", reportDate.map { .string($0.iso8601) } ?? .null),
                // Preserve the exact timestamp token, including fractions finer than Date or
                // millisecond storage, in source identity. Never merge distinct source revisions.
                .init("acceptedAt", accepted == nil ? .null : .string(columns.acceptanceDateTime[index])),
                .init("primaryDocument", .string(columns.primaryDocument[index]))
            ])
            let item = try SECSubmissionRecord(recordID: "sec/submission/" + accession,
                cik: request.resourceID, accessionNumber: accession, form: columns.form[index],
                filingDate: filingDate, reportDate: reportDate, acceptedAt: accepted,
                primaryDocument: columns.primaryDocument[index],
                isAmendment: columns.form[index].hasSuffix("/A"),
                provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                    sourceEventAt: sourceEvent, observationDate: nil, availability: availability, version: version))
            records.append(item)
        }
        let continuations = request.pageToken == nil ? (envelope.filings?.files?.map(\.name) ?? []) : []
        guard continuations.allSatisfy({ Self.validContinuation($0, cik: request.resourceID) }),
              Set(continuations).count == continuations.count else { throw SECAdapterError.malformedResponse }
        return (records, continuations)
    }

    private func parseFacts(_ data: Data, request: ProviderRequest, raw: ProviderRawPayload,
        receivedAt: Date) throws -> [SECCompanyFactRecord] {
        let envelope: SECCompanyFactsEnvelope
        do { envelope = try JSONDecoder().decode(SECCompanyFactsEnvelope.self, from: data) }
        catch { throw SECAdapterError.malformedResponse }
        guard Self.paddedCIK(envelope.cik.text) == request.resourceID else { throw ContractError.mismatchedSource }
        var records: [SECCompanyFactRecord] = []
        for taxonomy in envelope.facts.keys.sorted() {
            for concept in (envelope.facts[taxonomy] ?? [:]).keys.sorted() {
                let definition = envelope.facts[taxonomy]![concept]!
                for unit in definition.units.keys.sorted() {
                    for source in definition.units[unit]! {
                        let end = try MarketDate(iso8601: source.end)
                        let start = try source.start.map(MarketDate.init(iso8601:))
                        let kind: SECFactPeriodKind = start == nil ? .instant : .duration
                        let filed = try MarketDate(iso8601: source.filed)
                        let value = try Money(source.value.text)
                        // SEC frame is aggregation metadata and may change across amendments; the
                        // reporting context identity is the issuer, concept, unit and explicit dates.
                        let context = [request.resourceID, taxonomy, concept, unit, source.start ?? "instant", source.end]
                            .joined(separator: "/")
                        let factID = "sec/fact/" + String(digest(Data(context.utf8)).prefix(24))
                        let version = try Self.sourceVersion("sec.fact", [
                            .init("cik", .string(request.resourceID)), .init("taxonomy", .string(taxonomy)),
                            .init("concept", .string(concept)), .init("unit", .string(unit)),
                            .init("value", .string(value.decimalString)),
                            .init("start", start.map { .string($0.iso8601) } ?? .null),
                            .init("end", .string(end.iso8601)), .init("accession", .string(source.accn)),
                            .init("form", .string(source.form)), .init("filed", .string(filed.iso8601)),
                            .init("fiscalYear", source.fy.map { .integer(Int64($0)) } ?? .null),
                            .init("fiscalPeriod", source.fp.map(CanonicalValue.string) ?? .null),
                            .init("frame", source.frame.map(CanonicalValue.string) ?? .null)
                        ])
                        let recordID = factID + "/" + version
                        let availability = AvailabilityEvidence.dateOnly(filed, timeZoneID: "America/New_York",
                            evidence: "SEC companyfacts filed date; intraday time unavailable")
                        records.append(try SECCompanyFactRecord(recordID: recordID, factID: factID,
                            cik: request.resourceID, taxonomy: taxonomy, concept: concept,
                            label: definition.label ?? "", description: definition.description ?? "",
                            unit: unit, sourceValue: source.value.text, value: value,
                            startDate: start, endDate: end, periodKind: kind,
                            accessionNumber: source.accn, form: source.form, filedDate: filed,
                            fiscalYear: source.fy, fiscalPeriod: source.fp, frame: source.frame,
                            provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                                sourceEventAt: nil, observationDate: end, availability: availability, version: version)))
                    }
                }
            }
        }
        return records
    }

    private func parseFilingIndex(_ data: Data, request: ProviderRequest, raw: ProviderRawPayload,
        receivedAt: Date) throws -> SECFilingIndexRecord {
        let envelope: SECFilingIndexEnvelope
        do { envelope = try JSONDecoder().decode(SECFilingIndexEnvelope.self, from: data) }
        catch { throw SECAdapterError.malformedResponse }
        let resource = try SECArchiveResource(request.resourceID, expectsDocument: false)
        let files = try envelope.directory.item.map { try SECFilingFile(name: $0.name, type: $0.type, size: $0.size) }
            .sorted { $0.name < $1.name }
        let availability = AvailabilityEvidence.instant(receivedAt, evidence: "SEC filing index retrieval time")
        let version = try Self.sourceVersion("sec.index", [
            .init("cik", .string(resource.cik)), .init("accession", .string(resource.accession)),
            .init("files", .array(files.map {
                .object([.init("name", .string($0.name)), .init("type", .string($0.type)),
                         .init("size", $0.size.map { .integer(Int64($0)) } ?? .null)])
            }))
        ])
        return try SECFilingIndexRecord(recordID: "sec/filing-index/" + resource.accession,
            cik: resource.cik, accessionNumber: resource.accession, files: files,
            provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                sourceEventAt: request.requestedAt, observationDate: nil, availability: availability,
                version: version))
    }

    private func filingDocumentMetadata(request: ProviderRequest, raw: ProviderRawPayload,
        receivedAt: Date) throws -> SECFilingDocumentRecord {
        let resource = try SECArchiveResource(request.resourceID, expectsDocument: true)
        let availability = AvailabilityEvidence.instant(receivedAt, evidence: "SEC filing document retrieval time")
        return try SECFilingDocumentRecord(recordID: "sec/filing-document/" + resource.accession + "/" + resource.fileName!,
            cik: resource.cik, accessionNumber: resource.accession, fileName: resource.fileName!,
            mediaType: raw.mediaType, provenance: provenance(request: request, raw: raw, receivedAt: receivedAt,
                sourceEventAt: request.requestedAt, observationDate: nil, availability: availability,
                version: "sec.document." + raw.contentHash))
    }

    private static func validUserAgent(_ value: String) -> Bool {
        value.count <= 200 && value.range(of: #"^[A-Za-z0-9][^\r\n]{7,199}\z"#, options: .regularExpression) != nil
            && value.contains("/") && value.contains("@") && !value.contains("://")
    }
    private static func validTicker(_ value: String) -> Bool {
        value.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}\z"#, options: .regularExpression) != nil
    }
    private static func paddedCIK(_ value: String) -> String {
        guard let number = Int64(value) else { return value }
        return String(format: "%010lld", number)
    }
    private static func strictCIK(_ value: String) throws -> String {
        guard value.range(of: #"^[0-9]{1,10}\z"#, options: .regularExpression) != nil,
              let number = Int64(value), number > 0 else { throw SECAdapterError.malformedResponse }
        return String(format: "%010lld", number)
    }
    private static func validContinuation(_ value: String, cik: String) -> Bool {
        value.hasPrefix("CIK" + cik + "-submissions-")
            && value.range(of: #"^CIK[0-9]{10}-submissions-[0-9]{3}\.json\z"#, options: .regularExpression) != nil
    }
    private static func optionalInstant(_ value: String) throws -> Date? {
        guard !value.isEmpty else { return nil }
        // ISO8601DateFormatter's fractional mode can truncate below milliseconds. Parse
        // integral seconds independently, retaining the original token in the version hash.
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                          options: .regularExpression) != nil,
              (try? MarketDate(iso8601: String(value.prefix(10)))) != nil else { throw SECAdapterError.malformedResponse }
        let clock = value.dropFirst(11).prefix(8).split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3, clock[0] < 24, clock[1] < 60, clock[2] < 60 else {
            throw SECAdapterError.malformedResponse
        }
        let suffix = String(value.dropFirst(19))
        let zone = suffix.hasSuffix("Z") ? "Z" : String(suffix.suffix(6))
        if zone != "Z" {
            let offset = zone.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard offset.count == 2, offset[0] < 24, offset[1] < 60 else { throw SECAdapterError.malformedResponse }
        }
        let fractionText = String(suffix.dropLast(zone.count))
        let fraction: Double? = fractionText.isEmpty ? 0 : Double("0" + fractionText)
        guard let fraction, fraction >= 0, fraction < 1 else { throw SECAdapterError.malformedResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: String(value.prefix(19)) + zone) else { throw SECAdapterError.malformedResponse }
        return whole.addingTimeInterval(fraction)
    }

    private static func sourceVersion(_ prefix: String, _ members: [CanonicalMember]) throws -> String {
        prefix + "." + digest(try CanonicalValue.object(members).canonicalData())
    }
}

private struct SECArchiveResource {
    let cik: String
    let accession: String
    let fileName: String?
    let archivePath: String
    init(_ value: String, expectsDocument: Bool) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == (expectsDocument ? 3 : 2), SECCompanyIdentityRecord.validCIK(parts[0]),
              SECSubmissionRecord.validAccession(parts[1]),
              !expectsDocument || SECSubmissionRecord.validFileName(parts[2]) else { throw SECAdapterError.invalidResource }
        cik = parts[0]; accession = parts[1]; fileName = expectsDocument ? parts[2] : nil
        let unpadded = String(Int64(cik)!)
        let compact = accession.replacingOccurrences(of: "-", with: "")
        archivePath = "/Archives/edgar/data/" + unpadded + "/" + compact + "/" + (fileName ?? "index.json")
    }
}

private struct SECSubmissionsEnvelope: Decodable {
    let cik: LosslessText?
    let filings: Filings?
    let recent: Recent?
    let accessionNumber, filingDate, reportDate, acceptanceDateTime, form, primaryDocument: [String]?
    var topLevelRecent: Recent? {
        guard let accessionNumber, let filingDate, let reportDate, let acceptanceDateTime, let form, let primaryDocument else { return nil }
        return Recent(accessionNumber: accessionNumber, filingDate: filingDate, reportDate: reportDate,
                      acceptanceDateTime: acceptanceDateTime, form: form, primaryDocument: primaryDocument)
    }
    struct Filings: Decodable { let recent: Recent; let files: [Page]? }
    struct Page: Decodable { let name: String }
    struct Recent: Decodable {
        let accessionNumber, filingDate, reportDate, acceptanceDateTime, form, primaryDocument: [String]
        func hasUniformCount(_ count: Int) -> Bool {
            [accessionNumber, filingDate, reportDate, acceptanceDateTime, form, primaryDocument]
                .allSatisfy { $0.count == count }
        }
    }
}

private struct SECCompanyFactsEnvelope: Decodable {
    let cik: LosslessText
    let entityName: String
    let facts: [String: [String: Definition]]
    struct Definition: Decodable {
        let label: String?
        let description: String?
        let units: [String: [Fact]]
    }
    struct Fact: Decodable {
        let value: DecimalText
        let accn, filed, form, end: String
        let start: String?
        let fy: Int?
        let fp, frame: String?
        enum CodingKeys: String, CodingKey { case value = "val", accn, filed, form, end, start, fy, fp, frame }
    }
}

private struct LosslessText: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { text = string; return }
        if let integer = try? container.decode(Int64.self) { text = String(integer); return }
        throw SECAdapterError.malformedResponse
    }
}

private struct DecimalText: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { text = string; return }
        guard var decimal = try? container.decode(Decimal.self), !decimal.isNaN else {
            throw SECAdapterError.malformedResponse
        }
        text = NSDecimalString(&decimal, Locale(identifier: "en_US_POSIX"))
    }
}

private struct SECFilingIndexEnvelope: Decodable {
    let directory: Directory
    struct Directory: Decodable { let item: [Item] }
    struct Item: Decodable {
        let name, type: String
        let size: Int?
        enum CodingKeys: String, CodingKey { case name, type, size }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(String.self, forKey: .type)
            guard let source = try container.decodeIfPresent(LosslessText.self, forKey: .size), !source.text.isEmpty else {
                size = nil; return
            }
            guard source.text.range(of: #"^[0-9]+\z"#, options: .regularExpression) != nil,
                  let value = Int(source.text), value >= 0 else { throw SECAdapterError.malformedResponse }
            size = value
        }
    }
}
