import Foundation
import CoreDomain

public enum SECContractError: Error, Equatable {
    case invalidCIK
    case invalidAccession
    case invalidSymbol
    case invalidFiling
    case invalidFact
}

public struct SECTickerListing: Sendable, Codable, Equatable, Hashable {
    public let ticker: String
    public let exchange: String
    public init(ticker: String, exchange: String) throws {
        guard ticker.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,15}\z"#, options: .regularExpression) != nil,
              nonblank(exchange) else { throw SECContractError.invalidSymbol }
        self.ticker = ticker; self.exchange = exchange
    }
}

public enum SECIdentityStatus: String, Sendable, Codable { case active, historical, unknown }

/// A versioned issuer identity. CIK is an external identifier, not the application's issuer key.
public struct SECCompanyIdentityRecord: ProviderRecord, Sendable, Codable, Equatable {
    public let recordID: String
    public let cik: String
    public let name: String
    public let listings: [SECTickerListing]
    public let status: SECIdentityStatus
    public let provenance: Provenance

    public init(recordID: String, cik: String, name: String, listings: [SECTickerListing],
                status: SECIdentityStatus, provenance: Provenance) throws {
        guard Self.validCIK(cik), nonblank(recordID), nonblank(name), !listings.isEmpty,
              Set(listings).count == listings.count else { throw SECContractError.invalidCIK }
        try provenance.validate()
        guard provenance.endpointDescriptor == EndpointDescriptor.companyIdentity.rawValue else {
            throw ContractError.mismatchedSource
        }
        self.recordID = recordID; self.cik = cik; self.name = name
        self.listings = listings; self.status = status; self.provenance = provenance
    }

    public static func validCIK(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{10}\z"#, options: .regularExpression) != nil
    }
}

public struct SECSubmissionRecord: ProviderRecord, Sendable, Codable, Equatable {
    public let recordID: String
    public let cik: String
    public let accessionNumber: String
    public let form: String
    public let filingDate: MarketDate
    public let reportDate: MarketDate?
    public let acceptedAt: Date?
    public let primaryDocument: String
    public let isAmendment: Bool
    public let provenance: Provenance

    public init(recordID: String, cik: String, accessionNumber: String, form: String,
                filingDate: MarketDate, reportDate: MarketDate?, acceptedAt: Date?,
                primaryDocument: String, isAmendment: Bool, provenance: Provenance) throws {
        guard SECCompanyIdentityRecord.validCIK(cik), Self.validAccession(accessionNumber),
              nonblank(recordID), form.range(of: #"^[A-Za-z0-9][A-Za-z0-9\-]{0,15}(/A)?\z"#, options: .regularExpression) != nil,
              Self.validFileName(primaryDocument), acceptedAt.map(finite) ?? true else {
            throw SECContractError.invalidFiling
        }
        _ = try filingDate.start(in: TimeZone(secondsFromGMT: 0)!)
        if let reportDate { _ = try reportDate.start(in: TimeZone(secondsFromGMT: 0)!) }
        try provenance.validate()
        guard provenance.endpointDescriptor == EndpointDescriptor.submissions.rawValue,
              acceptedAt == nil || provenance.sourceEventAt == acceptedAt else { throw ContractError.mismatchedSource }
        self.recordID = recordID; self.cik = cik; self.accessionNumber = accessionNumber
        self.form = form; self.filingDate = filingDate; self.reportDate = reportDate
        self.acceptedAt = acceptedAt; self.primaryDocument = primaryDocument
        self.isAmendment = isAmendment; self.provenance = provenance
    }

    public static func validAccession(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{10}-[0-9]{2}-[0-9]{6}\z"#, options: .regularExpression) != nil
    }
    public static func validFileName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._\-]{0,255}\z"#, options: .regularExpression) != nil
            && !value.contains("..")
    }
}

public struct SECFilingFile: Sendable, Codable, Equatable, Hashable {
    public let name: String
    public let type: String
    public let size: Int
    public init(name: String, type: String, size: Int) throws {
        guard SECSubmissionRecord.validFileName(name), nonblank(type), size >= 0 else {
            throw SECContractError.invalidFiling
        }
        self.name = name; self.type = type; self.size = size
    }
}

public struct SECFilingIndexRecord: ProviderRecord, Sendable, Codable, Equatable {
    public let recordID: String
    public let cik: String
    public let accessionNumber: String
    public let files: [SECFilingFile]
    public let provenance: Provenance
    public init(recordID: String, cik: String, accessionNumber: String, files: [SECFilingFile],
                provenance: Provenance) throws {
        guard SECCompanyIdentityRecord.validCIK(cik), SECSubmissionRecord.validAccession(accessionNumber),
              nonblank(recordID), !files.isEmpty, Set(files.map(\.name)).count == files.count else {
            throw SECContractError.invalidFiling
        }
        try provenance.validate()
        guard provenance.endpointDescriptor == EndpointDescriptor.filingIndex.rawValue else {
            throw ContractError.mismatchedSource
        }
        self.recordID = recordID; self.cik = cik; self.accessionNumber = accessionNumber
        self.files = files; self.provenance = provenance
    }
}

public struct SECFilingDocumentRecord: ProviderRecord, Sendable, Codable, Equatable {
    public let recordID: String
    public let cik: String
    public let accessionNumber: String
    public let fileName: String
    public let mediaType: String
    public let provenance: Provenance
    public init(recordID: String, cik: String, accessionNumber: String, fileName: String,
                mediaType: String, provenance: Provenance) throws {
        guard SECCompanyIdentityRecord.validCIK(cik), SECSubmissionRecord.validAccession(accessionNumber),
              SECSubmissionRecord.validFileName(fileName), nonblank(recordID),
              mediaType.range(of: #"^[A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*\z"#,
                              options: .regularExpression) != nil else { throw SECContractError.invalidFiling }
        try provenance.validate()
        guard provenance.endpointDescriptor == EndpointDescriptor.filingDocument.rawValue else {
            throw ContractError.mismatchedSource
        }
        self.recordID = recordID; self.cik = cik; self.accessionNumber = accessionNumber
        self.fileName = fileName; self.mediaType = mediaType; self.provenance = provenance
    }
}

public enum SECFactPeriodKind: String, Sendable, Codable { case instant, duration }

/// One immutable numeric fact version. The raw aggregate response remains separately preserved.
/// `factID` identifies the reporting context; `recordID` plus provenance `versionID` identify a revision.
public struct SECCompanyFactRecord: ProviderRecord, Sendable, Codable, Equatable {
    public let recordID: String
    public let factID: String
    public let cik: String
    public let taxonomy: String
    public let concept: String
    public let label: String
    public let description: String
    public let unit: String
    public let sourceValue: String
    public let value: Money
    public let startDate: MarketDate?
    public let endDate: MarketDate
    public let periodKind: SECFactPeriodKind
    public let accessionNumber: String
    public let form: String
    public let filedDate: MarketDate
    public let fiscalYear: Int?
    public let fiscalPeriod: String?
    public let frame: String?
    public let dimensions: [String: String]
    public let provenance: Provenance

    public init(recordID: String, factID: String, cik: String, taxonomy: String, concept: String, label: String,
                description: String, unit: String, sourceValue: String, value: Money,
                startDate: MarketDate?, endDate: MarketDate, periodKind: SECFactPeriodKind,
                accessionNumber: String, form: String, filedDate: MarketDate, fiscalYear: Int?,
                fiscalPeriod: String?, frame: String?, dimensions: [String: String] = [:],
                provenance: Provenance) throws {
        guard SECCompanyIdentityRecord.validCIK(cik), SECSubmissionRecord.validAccession(accessionNumber),
              nonblank(recordID), nonblank(factID), Self.validName(taxonomy), Self.validName(concept), nonblank(label),
              nonblank(unit), try Money(sourceValue) == value, nonblank(form),
              fiscalYear.map({ (1900...3000).contains($0) }) ?? true,
              dimensions.allSatisfy({ nonblank($0.key) && nonblank($0.value) }) else {
            throw SECContractError.invalidFact
        }
        _ = try endDate.start(in: TimeZone(secondsFromGMT: 0)!)
        _ = try filedDate.start(in: TimeZone(secondsFromGMT: 0)!)
        switch (periodKind, startDate) {
        case (.instant, nil): break
        case let (.duration, start?): guard start <= endDate else { throw SECContractError.invalidFact }
        default: throw SECContractError.invalidFact
        }
        try provenance.validate()
        guard provenance.endpointDescriptor == EndpointDescriptor.companyFacts.rawValue,
              provenance.observationDate == endDate else { throw ContractError.mismatchedSource }
        self.recordID = recordID; self.factID = factID; self.cik = cik; self.taxonomy = taxonomy; self.concept = concept
        self.label = label; self.description = description; self.unit = unit
        self.sourceValue = sourceValue; self.value = value; self.startDate = startDate
        self.endDate = endDate; self.periodKind = periodKind; self.accessionNumber = accessionNumber
        self.form = form; self.filedDate = filedDate; self.fiscalYear = fiscalYear
        self.fiscalPeriod = fiscalPeriod; self.frame = frame; self.dimensions = dimensions
        self.provenance = provenance
    }

    private static func validName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9._\-]{0,255}\z"#, options: .regularExpression) != nil
    }
}
