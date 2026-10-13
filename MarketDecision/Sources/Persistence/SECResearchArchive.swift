import Foundation
import CoreDomain
import DataContracts
import FundamentalsEngine

/// A local owner decision for this independent SEC archive. It does not change the
/// original frozen object's backup permission or grant redistribution/market-data rights.
public enum SECLocalArchiveConsent: String, Codable, Sendable {
    case personalLocalBackup = "personal-local-sec-backup.v1"
}

public enum SECArchiveError: Error, Equatable {
    case identifierConflict, scopeDenied, invalidArchive
}

public struct SECArchiveRestorePlan: Sendable, Identifiable {
    public let id: UUID
    public let digest: String
    public let baseRevision: UUID
    public let mode: RestoreMode
    public let details: [String]
    public let researchCount: Int
    public let reportCount: Int
    public let supplementCount: Int
    public let removedResearchCount: Int

    public init(id: UUID, digest: String, baseRevision: UUID, mode: RestoreMode,
                details: [String], researchCount: Int, reportCount: Int,
                supplementCount: Int, removedResearchCount: Int) {
        self.id = id; self.digest = digest; self.baseRevision = baseRevision; self.mode = mode
        self.details = details; self.researchCount = researchCount; self.reportCount = reportCount
        self.supplementCount = supplementCount; self.removedResearchCount = removedResearchCount
    }
}

public protocol SECArchiveStorage: Sendable {
    func exportArchive(researchID: UUID, consent: SECLocalArchiveConsent) async throws -> Data
    func prepareArchiveRestore(_ bytes: Data, mode: RestoreMode,
                               consent: SECLocalArchiveConsent) async throws -> SECArchiveRestorePlan
    func commitArchiveRestore(_ approval: PlanApproval) async throws
    func cancelArchiveRestore(_ id: UUID) async
}

/// Original JSON encodings are opaque payloads. Re-encoding a decoded document here
/// would invalidate the exact byte bindings in its immutable child documents.
struct SECArchiveState: Codable, Sendable {
    let format: String
    let research: Data
    let reports: [Data]
    let supplements: [Data]

    init(research: Data, reports: [Data], supplements: [Data]) {
        format = "sec-local-state.v1"
        self.research = research; self.reports = reports; self.supplements = supplements
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case format, research, reports, supplements }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: SECArchiveKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue))
        else { throw SECArchiveError.invalidArchive }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        research = try values.decode(Data.self, forKey: .research)
        reports = try values.decode([Data].self, forKey: .reports)
        supplements = try values.decode([Data].self, forKey: .supplements)
    }

    func validate() throws -> SECArchiveValidatedState {
        guard format == "sec-local-state.v1" else { throw SnapshotError.unsupportedFormat }
        try SECResearchArchiveCodec.validateLimits(self)
        try Task.checkCancellation()
        let parent = try SECResearchArchiveCodec.decodeDocument(SECResearchDocument.self, research)
        try parent.validate()
        var ids: Set<UUID> = [parent.id]
        var decodedReports: [(document: SECFinancialReportDocument, bytes: Data)] = []
        var reportIndex: [UUID: Int] = [:]
        for bytes in reports {
            try Task.checkCancellation()
            let report = try SECResearchArchiveCodec.decodeDocument(SECFinancialReportDocument.self, bytes)
            guard ids.insert(report.id).inserted else { throw SnapshotError.duplicateObject }
            guard report.parentDocumentID == parent.id else { throw SnapshotError.missingReference }
            try report.validate(parent: parent, parentBytes: research)
            reportIndex[report.id] = decodedReports.count
            decodedReports.append((report, bytes))
        }
        var decodedSupplements: [(document: SECValuationSupplementDocument, bytes: Data)] = []
        for bytes in supplements {
            try Task.checkCancellation()
            let supplement = try SECResearchArchiveCodec.decodeDocument(SECValuationSupplementDocument.self, bytes)
            // Even synthetic captured prices have a separate retention contract. Never
            // silently drop a priced supplement or interpret this consent as price rights.
            guard supplement.valuation.evidence.prices.isEmpty else { throw SECArchiveError.scopeDenied }
            guard ids.insert(supplement.id).inserted else { throw SnapshotError.duplicateObject }
            guard supplement.parentResearchID == parent.id,
                  let index = reportIndex[supplement.parentFinancialReportID]
            else { throw SnapshotError.missingReference }
            let report = decodedReports[index]
            try supplement.validate(parent: report.document, parentBytes: report.bytes,
                                    research: parent, researchBytes: research)
            decodedSupplements.append((supplement, bytes))
        }
        return SECArchiveValidatedState(state: self, research: (parent, research),
                                        reports: decodedReports, supplements: decodedSupplements)
    }
}

/// A proof for this operation only; no cross-operation validation cache. Cached model
/// outputs still need explicit replay after restore before they may be displayed.
struct SECArchiveValidatedState: Sendable {
    let state: SECArchiveState
    let research: (document: SECResearchDocument, bytes: Data)
    let reports: [(document: SECFinancialReportDocument, bytes: Data)]
    let supplements: [(document: SECValuationSupplementDocument, bytes: Data)]
    var documentCount: Int { 1 + reports.count + supplements.count }

    fileprivate init(state: SECArchiveState, research: (document: SECResearchDocument, bytes: Data),
                     reports: [(document: SECFinancialReportDocument, bytes: Data)],
                     supplements: [(document: SECValuationSupplementDocument, bytes: Data)]) {
        self.state = state; self.research = research; self.reports = reports; self.supplements = supplements
    }
}

private struct SECArchiveDocumentEntry: Codable, Equatable {
    let kind: String
    let id: UUID
    let sha256: String
    let size: Int
    let parentID: UUID?
    let parentHash: String?
}

private struct SECArchiveSourceEntry: Codable, Equatable {
    let reference: String
    let sha256: String
    let size: Int
}

private struct SECArchiveManifest: Codable, Equatable {
    let format: String
    let application: String
    let scope: String
    let consent: SECLocalArchiveConsent
    let file: String
    let sha256: String
    let size: Int
    let documents: [SECArchiveDocumentEntry]
    let sources: [SECArchiveSourceEntry]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, application, scope, consent, file, sha256, size, documents, sources
    }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: SECArchiveKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue))
        else { throw SECArchiveError.invalidArchive }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        application = try values.decode(String.self, forKey: .application)
        scope = try values.decode(String.self, forKey: .scope)
        consent = try values.decode(SECLocalArchiveConsent.self, forKey: .consent)
        file = try values.decode(String.self, forKey: .file)
        sha256 = try values.decode(String.self, forKey: .sha256)
        size = try values.decode(Int.self, forKey: .size)
        documents = try values.decode([SECArchiveDocumentEntry].self, forKey: .documents)
        sources = try values.decode([SECArchiveSourceEntry].self, forKey: .sources)
    }

    init(_ validated: SECArchiveValidatedState, stateBytes: Data, consent: SECLocalArchiveConsent) {
        format = SECResearchArchiveCodec.format; application = "MarketDecision"
        scope = "single-sec-research-with-price-free-calculations"
        self.consent = consent; file = "research-state.json"
        sha256 = digest(stateBytes); size = stateBytes.count
        var entries = [SECArchiveDocumentEntry(kind: "research", id: validated.research.document.id,
            sha256: digest(validated.research.bytes), size: validated.research.bytes.count, parentID: nil, parentHash: nil)]
        entries.append(contentsOf: validated.reports.map {
            SECArchiveDocumentEntry(kind: "financial-report", id: $0.document.id,
                sha256: digest($0.bytes), size: $0.bytes.count,
                parentID: $0.document.parentDocumentID, parentHash: $0.document.parentDocumentHash)
        })
        entries.append(contentsOf: validated.supplements.map {
            SECArchiveDocumentEntry(kind: "valuation-supplement", id: $0.document.id,
                sha256: digest($0.bytes), size: $0.bytes.count,
                parentID: $0.document.parentFinancialReportID, parentHash: $0.document.parentFinancialReportHash)
        })
        documents = entries.sorted { ($0.kind, $0.id.uuidString) < ($1.kind, $1.id.uuidString) }
        sources = validated.research.document.sources.map {
            SECArchiveSourceEntry(reference: $0.reference, sha256: $0.contentHash, size: $0.bytes.count)
        }.sorted { $0.reference < $1.reference }
    }
}

private struct SECArchiveKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// A bounded, stored-entry ZIP profile. Limits cover encoded payloads, not peak RSS;
/// original source bytes and JSON decoding still occupy memory during an operation.
enum SECResearchArchiveCodec {
    static let format = "sec-local-archive.v1"
    static let maximumReports = 64
    static let maximumSupplements = 64
    static let maximumRawBytes = 512 * 1_024 * 1_024
    static let maximumChildBytes = 64 * 1_024 * 1_024
    static let maximumStateBytes = 768 * 1_024 * 1_024
    static let maximumManifestBytes = 128 * 1_024
    static let maximumArchiveBytes = maximumStateBytes + maximumManifestBytes + 1_024

    static func validateLimits(_ state: SECArchiveState) throws {
        guard !state.research.isEmpty, state.reports.count <= maximumReports,
              state.supplements.count <= maximumSupplements else { throw SnapshotError.resourceLimit }
        var remaining = maximumRawBytes
        func consume(_ bytes: Data, limit: Int) throws {
            guard !bytes.isEmpty, bytes.count <= limit, bytes.count <= remaining
            else { throw SnapshotError.resourceLimit }
            remaining -= bytes.count
        }
        try consume(state.research, limit: maximumRawBytes)
        for bytes in state.reports { try consume(bytes, limit: maximumChildBytes) }
        for bytes in state.supplements { try consume(bytes, limit: maximumChildBytes) }
    }

    static func encode(_ state: SECArchiveState, consent: SECLocalArchiveConsent) throws -> Data {
        let validated = try state.validate()
        try Task.checkCancellation()
        let bytes = try ResearchDocument.encoded(state)
        guard bytes.count <= maximumStateBytes else { throw SnapshotError.resourceLimit }
        let manifest = try ResearchDocument.encoded(SECArchiveManifest(validated, stateBytes: bytes, consent: consent))
        guard manifest.count <= maximumManifestBytes else { throw SnapshotError.resourceLimit }
        try Task.checkCancellation()
        return try ResearchZIP.encode(["manifest.json": manifest, "research-state.json": bytes])
    }

    static func decode(_ bytes: Data, consent: SECLocalArchiveConsent) throws -> SECArchiveValidatedState {
        guard bytes.count <= maximumArchiveBytes else { throw SnapshotError.resourceLimit }
        try Task.checkCancellation()
        let files = try ResearchZIP.decode(bytes)
        guard let manifestBytes = files["manifest.json"], let stateBytes = files["research-state.json"]
        else { throw SECArchiveError.invalidArchive }
        guard manifestBytes.count <= maximumManifestBytes, stateBytes.count <= maximumStateBytes
        else { throw SnapshotError.resourceLimit }
        struct Header: Decodable { let format: String }
        let header = try decodeDocument(Header.self, manifestBytes)
        guard header.format == format else { throw SnapshotError.unsupportedFormat }
        let manifest = try decodeDocument(SECArchiveManifest.self, manifestBytes)
        guard manifest.consent == consent else { throw SECArchiveError.scopeDenied }
        guard manifest.sha256 == digest(stateBytes), manifest.size == stateBytes.count
        else { throw SnapshotError.hashMismatch }
        let state = try decodeDocument(SECArchiveState.self, stateBytes)
        let validated = try state.validate()
        guard manifest == SECArchiveManifest(validated, stateBytes: stateBytes, consent: consent)
        else { throw SECArchiveError.invalidArchive }
        return validated
    }

    fileprivate static func decodeDocument<Value: Decodable>(_ type: Value.Type, _ bytes: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch is DecodingError { throw SECArchiveError.invalidArchive }
    }
}
