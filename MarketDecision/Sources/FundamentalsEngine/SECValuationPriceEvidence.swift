import Foundation
import CoreDomain
import DataContracts

public enum SECReferencePriceSide: String, Sendable, Codable, CaseIterable { case bid, ask }
public enum SECReferenceCaptureOrigin: String, Sendable, Codable { case providerCapture, syntheticFixture }

/// A local user's recorded rights assertion for this bounded use, never provider certification.
/// Exact supporting bytes and their hash are retained. This scope cannot grant PIT, live analysis,
/// redistribution, ledger marking or fills; neither a paid tier nor subscription is inferred.
public struct SECCapturedPriceRights: Sendable, Codable {
    public let scope: String
    public let providerID, feedID, entitlementVersion, evidenceReference, licenseReference: String
    public let recordedAt, validFrom, validThrough: Date
    public let assertion: String
    public let evidenceBytes: Data
    public let evidenceHash: String
    public init(entitlementVersion: String, evidenceReference: String, licenseReference: String,
                recordedAt: Date, validFrom: Date, validThrough: Date, assertion: String, evidenceBytes: Data) throws {
        scope = "personal-local-captured-reference-and-retention.v1"; providerID = "alpaca"; feedID = "iex"
        self.entitlementVersion = entitlementVersion; self.evidenceReference = evidenceReference; self.licenseReference = licenseReference
        self.recordedAt = recordedAt; self.validFrom = validFrom; self.validThrough = validThrough
        self.assertion = assertion; self.evidenceBytes = evidenceBytes; evidenceHash = digest(evidenceBytes); try validate()
    }
    func validate() throws {
        guard scope == "personal-local-captured-reference-and-retention.v1", providerID == "alpaca", feedID == "iex",
              valuationText(entitlementVersion, 512), valuationText(evidenceReference, 1_024), valuationText(licenseReference, 1_024),
              [recordedAt, validFrom, validThrough].allSatisfy({ $0.timeIntervalSince1970.isFinite }), validFrom <= validThrough,
              valuationText(assertion, 4_096), !evidenceBytes.isEmpty, evidenceBytes.count <= 65_536,
              String(data: evidenceBytes, encoding: .utf8) != nil, evidenceHash == digest(evidenceBytes)
        else { throw SECValuationError.invalidEvidence }
    }
}

/// The unchanged IEX record has UNKNOWN market availability. Explicit bid/ask selection supports
/// only a frozen captured-reference scenario. Receipt establishes possession for that scenario,
/// not the historical public availability of the underlying market observation.
public struct SECValuationPriceEvidence: Sendable, Codable {
    public let classID: String
    public let record: EquityRecord
    public let request: ProviderRequest
    public let rawSource: SECValuationSourceMaterial
    public let rights: SECCapturedPriceRights
    public let selectedSide: SECReferencePriceSide
    public let captureOrigin: SECReferenceCaptureOrigin
    public init(classID: String, record: EquityRecord, request: ProviderRequest,
                rawSource: SECValuationSourceMaterial, rights: SECCapturedPriceRights,
                selectedSide: SECReferencePriceSide, captureOrigin: SECReferenceCaptureOrigin) throws {
        self.classID = classID; self.record = record; self.request = request; self.rawSource = rawSource
        self.rights = rights; self.selectedSide = selectedSide; self.captureOrigin = captureOrigin
        try validate(executionDate: record.provenance.receivedAt)
    }
    public var selectedPrice: Money? { record.quote.map { selectedSide == .bid ? $0.bid : $0.ask } }
    public var capturedAt: Date { record.provenance.receivedAt }
    func validate(executionDate: Date) throws {
        try record.validate(); try request.validate(); try rawSource.validate(); try rights.validate()
        let p = record.provenance
        guard let quote = record.quote, valuationText(classID, 128), record.kind == .quote,
              request.providerID == "alpaca", request.feedID == "iex", request.resourceID == record.symbol,
              request.capability == .quote, request.mode == .latest, request.range == nil, request.pageToken == nil,
              request.usage == .replay, request.configurationVersion == "alpaca-iex-raw-daily.v1",
              request.entitlementVersion == rights.entitlementVersion,
              request.id == p.requestID, request.requestedAt == p.requestedAt,
              rawSource.reference == p.rawObjectRef, rawSource.contentHash == p.rawHash,
              rawSource.bytes.count <= 4 * 1_024 * 1_024,
              p.evidenceRef == rights.evidenceReference, p.licenseRef == rights.licenseReference,
              rights.recordedAt <= request.requestedAt, rights.validFrom <= request.requestedAt,
              capturedAt <= rights.validThrough, capturedAt <= executionDate,
              record.quality(at: capturedAt).isEmpty,
              p.availability == .unknown else { throw SECValuationError.unsupportedPrice }
        let markers = [rawSource.reference, rights.assertion, rights.evidenceReference, rights.licenseReference,
                       String(data: rights.evidenceBytes, encoding: .utf8) ?? ""].joined(separator: " ").lowercased()
        if captureOrigin == .providerCapture && (markers.contains("synthetic") || markers.contains("fixture")) {
            throw SECValuationError.unsupportedPrice
        }
        guard let root = try ExactMarketJSON.parse(rawSource.bytes).object,
              root["symbol"]?.string == record.symbol, let q = root["quote"]?.object,
              q["t"]?.string == record.sourceTimestamp, q["bx"]?.string == quote.bidExchange,
              q["ax"]?.string == quote.askExchange,
              try q["bp"]?.money() == quote.bid, try q["ap"]?.money() == quote.ask,
              try q["bs"]?.money() == quote.bidSize, try q["as"]?.money() == quote.askSize
        else { throw SECValuationError.sourceMismatch }
    }
}
