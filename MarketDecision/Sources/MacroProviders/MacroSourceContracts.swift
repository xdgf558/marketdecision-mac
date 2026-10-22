import Foundation
import CoreDomain
import MarketAnalytics

public enum MacroSourceError: Error, Equatable { case invalidInput, unsupportedFormat, unsupportedSeries, malformedSource, conflictingVersion, invalidReleaseEvidence, incompatibleReport }
public enum MacroSourceFormat: String, Codable, CaseIterable, Sendable {
    case fredObservationsJSON, alfredObservationsJSON, cboeIndexHistoryCSV, cboePutCallHistoryCSV, cftcFinancialFuturesCSV
}
public enum MacroSourceOrigin: String, Codable, Sendable { case synthetic, localFile }
public enum MacroSourceUnit: String, Codable, Sendable { case percent, percentagePoints, indexLevel, thousandsPersons, billionsChainedDollars, ratio }
public enum MacroSourceFrequency: String, Codable, Sendable { case daily, weekly, releaseCycle }
public enum CFTCReportScope: String, Codable, Sendable { case futuresOnly, futuresAndOptionsCombined }
public enum MacroSeriesID: String, Codable, CaseIterable, Sendable {
    case fedFunds = "FEDFUNDS", sofr = "SOFR", dgs2 = "DGS2", dgs10 = "DGS10", treasury10y2y = "T10Y2Y"
    case cpi = "CPIAUCSL", pce = "PCEPI", corePCE = "PCEPILFE", unemployment = "UNRATE", payrolls = "PAYEMS", realGDP = "GDPC1", highYieldOAS = "BAMLH0A0HYM2"
    case vix = "CBOE_VIX", vix3m = "CBOE_VIX3M"
    case totalPutCall = "CBOE_TOTAL_PCR", indexPutCall = "CBOE_INDEX_PCR", equityPutCall = "CBOE_EQUITY_PCR", etfPutCall = "CBOE_ETP_PCR"
    case assetManagerNetOverOI = "CFTC_TFF_AM_NET_OI", leveragedFundsNetOverOI = "CFTC_TFF_LF_NET_OI"
    public var unit: MacroSourceUnit {
        switch self {
        case .cpi, .pce, .corePCE: .indexLevel
        case .payrolls: .thousandsPersons
        case .realGDP: .billionsChainedDollars
        case .treasury10y2y: .percentagePoints
        case .totalPutCall, .indexPutCall, .equityPutCall, .etfPutCall, .assetManagerNetOverOI, .leveragedFundsNetOverOI: .ratio
        default: .percent
        }
    }
    public var frequency: MacroSourceFrequency {
        switch self {
        case .fedFunds, .cpi, .pce, .corePCE, .unemployment, .payrolls, .realGDP: .releaseCycle
        case .assetManagerNetOverOI, .leveragedFundsNetOverOI: .weekly
        default: .daily
        }
    }
    public var marketKey: MarketSeriesKey? {
        switch self {
        case .highYieldOAS: .highYieldOAS
        case .vix: .vix
        case .vix3m: .vix3m
        case .totalPutCall: .totalPutCall
        case .indexPutCall: .indexPutCall
        case .equityPutCall: .equityPutCall
        case .etfPutCall: .etfPutCall
        case .assetManagerNetOverOI: .assetManagerNetOverOI
        case .leveragedFundsNetOverOI: .leveragedFundsNetOverOI
        default: nil
        }
    }
}

/// A local format declaration, never a transport configuration or supplier authorization.
/// FRED files contain no series ID: this declaration is deliberately retained as evidence.
public struct MacroSourceDescriptor: Codable, Equatable, Sendable {
    public let format: MacroSourceFormat
    public let series: [MacroSeriesID]
    public let sourceID: String
    public let feedID: String
    public let basisVersion: String
    public let population: String?
    /// CSV revisions have no source vintage field; the caller must identify their file revision.
    public let revisionID: String
    public let sourceReference: String
    public let licenseEvidence: String
    public let cftcContractCode: String?
    public let cftcScope: CFTCReportScope?
    public init(format: MacroSourceFormat, series: [MacroSeriesID], sourceID: String, feedID: String,
                basisVersion: String, population: String? = nil, revisionID: String,
                sourceReference: String, licenseEvidence: String, cftcContractCode: String? = nil,
                cftcScope: CFTCReportScope? = nil) {
        self.format = format; self.series = series; self.sourceID = sourceID; self.feedID = feedID
        self.basisVersion = basisVersion; self.population = population; self.revisionID = revisionID
        self.sourceReference = sourceReference; self.licenseEvidence = licenseEvidence
        self.cftcContractCode = cftcContractCode; self.cftcScope = cftcScope
    }
}

/// Binds one version of one observation to explicitly supplied publication evidence.
/// ALFRED realtime_start/end and a retrieval timestamp are not publication timestamps.
public struct MacroReleaseEvidence: Codable, Equatable, Sendable {
    public let series: MacroSeriesID
    public let observationDate: String
    public let vintageID: String
    public let releasedAt: Date
    public let availableAt: Date
    public let evidenceReference: String
    public init(series: MacroSeriesID, observationDate: String, vintageID: String, releasedAt: Date,
                availableAt: Date, evidenceReference: String) {
        self.series = series; self.observationDate = observationDate; self.vintageID = vintageID
        self.releasedAt = releasedAt; self.availableAt = availableAt; self.evidenceReference = evidenceReference
    }
}
public struct MacroImportInput: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let retrievedAt: Date
    public let asOf: Date
    public let origin: MacroSourceOrigin
    public let descriptor: MacroSourceDescriptor
    public let rawData: Data
    public let releases: [MacroReleaseEvidence]
    public init(id: UUID = UUID(), createdAt: Date, retrievedAt: Date, asOf: Date,
                origin: MacroSourceOrigin, descriptor: MacroSourceDescriptor, rawData: Data,
                releases: [MacroReleaseEvidence] = []) {
        self.id = id; self.createdAt = createdAt; self.retrievedAt = retrievedAt; self.asOf = asOf
        self.origin = origin; self.descriptor = descriptor; self.rawData = rawData; self.releases = releases
    }
}
public enum MacroSourceGapReason: String, Codable, Sendable {
    case sourceMissingValue, unverifiedRelease, notAvailableAtCutoff, zeroOpenInterest, noMarketMapping
}
public struct MacroSourceGap: Codable, Equatable, Sendable {
    public let series: MacroSeriesID
    public let observationDate: String
    public let vintageID: String
    public let reason: MacroSourceGapReason
}
public struct MacroSourceObservation: Codable, Equatable, Sendable {
    public let series: MacroSeriesID
    public let observationID: String
    public let observationDate: String
    public let vintageID: String
    /// Native real-time dates may be clipped to the source query's date range.
    /// They neither establish exact publication/expiry instants nor certify that
    /// this imported file contains every subsequent revision.
    public let vintageStart: String?
    public let vintageEnd: String?
    public let unit: MacroSourceUnit
    public let value: Money?
    /// Exact source tokens. Derived ratios retain their long/short/OI operands, not a fictional raw ratio.
    public let rawFields: [String: String]
    public let transformation: String
    public let release: MacroReleaseEvidence?
    public let missingReason: MacroSourceGapReason?
}
public struct MacroSourceReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let decoderVersion: String
    public let input: MacroImportInput
    public let contentSHA256: String
    public let observations: [MacroSourceObservation]
    /// Latest explicitly available vintage within this imported collection at
    /// input.asOf; missing source values remain explicit. This does not certify
    /// complete source-side revision coverage or strict historical PIT eligibility.
    public let selectedObservations: [MacroSourceObservation]
    public let gaps: [MacroSourceGap]
    public let limitations: [String]
    public var id: UUID { input.id }
    public var createdAt: Date { input.createdAt }
    public var containsSynthetic: Bool { input.origin == .synthetic }
    public var researchOnly: Bool { true }
}
public struct MacroSourceBridgeResult: Codable, Equatable, Sendable {
    /// Only the selected imported evidence is bridged; completeness of the source's
    /// real-time history is not established, including beyond a clipped vintageEnd.
    public let series: [MarketSeries]
    public let gaps: [MacroSourceGap]
    /// All bridged inputs remain synthetic/manual. No transport or provider/PIT qualification is granted.
    public let transformations: [String]
}
