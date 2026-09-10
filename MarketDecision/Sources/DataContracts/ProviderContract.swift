import Foundation

public enum ProviderCapability: String, Sendable, Codable, CaseIterable {
    case quote, bars, optionExpirations, optionChain, companyIdentity, submissions, companyFacts, macroSeries, ledgerMarks
}
public enum ProviderFailure: String, Error, Sendable, Codable {
    case authInvalid, notEntitled, rateLimited, unsupported, pitUnavailable, offline, malformedResponse, symbolUnavailable
    public static func fromHTTP(_ status: Int) -> Self {
        switch status { case 401: .authInvalid; case 403: .notEntitled; case 429: .rateLimited; default: .malformedResponse }
    }
}
public struct DateRange: Sendable, Codable, Equatable {
    public let start: Date, end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public func validate() throws {
        guard finite(start), finite(end), start <= end else { throw ContractError.invalidRange }
    }
}
public enum QueryMode: Sendable, Codable, Equatable { case latest, asOf(Date) }
public struct ProviderRequest: Sendable, Codable, Equatable {
    public let id: UUID
    public let providerID: String, feedID: String, resourceID: String
    public let capability: ProviderCapability
    public let mode: QueryMode
    public let range: DateRange?
    public let usage: Usage
    public let configurationVersion: String, entitlementVersion: String
    public let requestedAt: Date
    public let pageToken: String?
    public init(id: UUID = UUID(), providerID: String, feedID: String, resourceID: String, capability: ProviderCapability,
                mode: QueryMode, range: DateRange? = nil, usage: Usage, configurationVersion: String,
                entitlementVersion: String, requestedAt: Date, pageToken: String? = nil) {
        self.id = id; self.providerID = providerID; self.feedID = feedID; self.resourceID = resourceID
        self.capability = capability; self.mode = mode; self.range = range; self.usage = usage
        self.configurationVersion = configurationVersion; self.entitlementVersion = entitlementVersion
        self.requestedAt = requestedAt; self.pageToken = pageToken
    }
    public func validate() throws {
        guard nonblank(providerID), nonblank(feedID), nonblank(resourceID), nonblank(configurationVersion),
              nonblank(entitlementVersion), finite(requestedAt), pageToken == nil || nonblank(pageToken) else { throw ContractError.invalidRequest }
        try range?.validate()
        if case let .asOf(cutoff) = mode {
            guard finite(cutoff), cutoff <= requestedAt, range != nil else { throw ContractError.invalidRequest }
        }
    }
}
/// Capability is technical support, not a subscription or data-quality qualification.
public struct CapabilitySnapshot: Sendable {
    public let providerID: String, version: String
    public let feeds: Set<String>, capabilities: Set<ProviderCapability>, asOfCapabilities: Set<ProviderCapability>
    public let vintageResourceIDs: Set<String>
    public init(providerID: String, version: String, feeds: Set<String>, capabilities: Set<ProviderCapability>,
                asOfCapabilities: Set<ProviderCapability> = [], vintageResourceIDs: Set<String> = []) {
        self.providerID = providerID; self.version = version; self.feeds = feeds; self.capabilities = capabilities
        self.asOfCapabilities = asOfCapabilities; self.vintageResourceIDs = vintageResourceIDs
    }
}
/// A supplied rights-evidence record, not proof that a provider or subscription was verified.
/// Callers must obtain this from their separately verified entitlement configuration.
public struct EntitlementSnapshot: Sendable {
    public let providerID: String, feedID: String, version: String, evidenceRef: String, licenseRef: String
    public let capabilities: Set<ProviderCapability>, usages: Set<Usage>
    public let validFrom: Date, validThrough: Date
    public init(providerID: String, feedID: String, version: String, evidenceRef: String, licenseRef: String,
                capabilities: Set<ProviderCapability>, usages: Set<Usage>, validFrom: Date, validThrough: Date) {
        self.providerID = providerID; self.feedID = feedID; self.version = version; self.evidenceRef = evidenceRef; self.licenseRef = licenseRef
        self.capabilities = capabilities; self.usages = usages; self.validFrom = validFrom; self.validThrough = validThrough
    }
    public func permits(provider: String, feed: String, usage: Usage, at date: Date) -> Bool {
        providerID == provider && feedID == feed && usages.contains(usage) && nonblank(version) && nonblank(evidenceRef) && nonblank(licenseRef)
            && finite(date) && finite(validFrom) && finite(validThrough) && validFrom <= date && date <= validThrough
    }
}
public enum ProviderAccess {
    public static func validate(_ request: ProviderRequest, capabilities: CapabilitySnapshot, entitlement: EntitlementSnapshot?) throws {
        try request.validate()
        guard capabilities.providerID == request.providerID, nonblank(capabilities.version),
              capabilities.feeds.contains(request.feedID), capabilities.capabilities.contains(request.capability) else { throw ProviderFailure.unsupported }
        if case .asOf = request.mode {
            guard capabilities.asOfCapabilities.contains(request.capability),
                  capabilities.vintageResourceIDs.contains(request.resourceID) else { throw ProviderFailure.unsupported }
        }
        guard let entitlement, entitlement.version == request.entitlementVersion,
              entitlement.capabilities.contains(request.capability),
              entitlement.permits(provider: request.providerID, feed: request.feedID, usage: request.usage, at: request.requestedAt)
        else { throw ProviderFailure.notEntitled }
    }
}
public enum ProviderResultStatus: String, Sendable { case complete, partial, empty, error }
public enum EmptyReason: String, Sendable { case noResults, marketClosed, noListedContracts }
public struct MissingItem: Sendable {
    public let resourceID: String
    public let reason: ProviderFailure
    public init(resourceID: String, reason: ProviderFailure) { self.resourceID = resourceID; self.reason = reason }
}
public struct ResponseCoverage: Sendable {
    public let expectedCount: Int?
    public let missing: [MissingItem]
    public let truncated: Bool
    public init(expectedCount: Int?, missing: [MissingItem] = [], truncated: Bool = false) {
        self.expectedCount = expectedCount; self.missing = missing; self.truncated = truncated
    }
}
/// A response to one exact request/page. COMPLETE refers to this declared request scope only.
/// Transport success never grants any item permission to participate in analysis.
public struct ProviderResult<Item: ProviderRecord>: Sendable {
    public let request: ProviderRequest
    public let receivedAt: Date
    public let items: [Item]
    public let coverage: ResponseCoverage
    public let nextPageToken: String?
    public let errors: [ProviderFailure]
    public let emptyReason: EmptyReason?
    public let retryAfter: TimeInterval?
    public let status: ProviderResultStatus
    public var sourceManifest: [Provenance] { items.map(\.provenance) }
    public init(request: ProviderRequest, receivedAt: Date, items: [Item], coverage: ResponseCoverage,
                nextPageToken: String? = nil, errors: [ProviderFailure] = [], emptyReason: EmptyReason? = nil,
                retryAfter: TimeInterval? = nil) throws {
        try request.validate()
        guard finite(receivedAt), request.requestedAt <= receivedAt,
              retryAfter.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw ContractError.invalidTime }
        guard coverage.expectedCount.map({ $0 >= items.count && $0 >= 0 }) ?? true,
              coverage.missing.allSatisfy({ nonblank($0.resourceID) }),
              nextPageToken == nil || (nonblank(nextPageToken) && nextPageToken != request.pageToken) else { throw ContractError.invalidCoverage }
        guard Set(items.map(\.recordID)).count == items.count else { throw ContractError.duplicateRecord }
        for item in items {
            guard nonblank(item.recordID) else { throw ContractError.invalidIdentity }
            try item.provenance.validate()
            guard item.provenance.providerID == request.providerID, item.provenance.feedID == request.feedID,
                  item.provenance.requestID == request.id, item.provenance.requestedAt == request.requestedAt,
                  item.provenance.receivedAt <= receivedAt else { throw ContractError.mismatchedSource }
            if case let .asOf(cutoff) = request.mode {
                guard item.provenance.isAvailable(asOf: cutoff) else { throw ProviderFailure.pitUnavailable }
            }
        }
        let incomplete = coverage.truncated || nextPageToken != nil || !coverage.missing.isEmpty
            || coverage.expectedCount.map({ $0 != items.count }) == true
        if !items.isEmpty {
            guard emptyReason == nil else { throw ContractError.invalidCoverage }
            status = incomplete || !errors.isEmpty ? .partial : .complete
        } else if !errors.isEmpty {
            guard emptyReason == nil else { throw ContractError.invalidCoverage }; status = .error
        } else if incomplete {
            guard emptyReason == nil else { throw ContractError.invalidCoverage }; status = .partial
        } else {
            guard emptyReason != nil else { throw ContractError.invalidCoverage }; status = .empty
        }
        self.request = request; self.receivedAt = receivedAt; self.items = items; self.coverage = coverage
        self.nextPageToken = nextPageToken; self.errors = errors; self.emptyReason = emptyReason; self.retryAfter = retryAfter
    }
    public func validate(matching original: ProviderRequest) throws {
        guard request == original else { throw ContractError.mismatchedRequest }
    }
}

/// Captures the capability and rights versions actually used for this exchange.
/// Validation here is request/transport validation, not financial usability or vendor certification.
public struct ProviderExchange<Item: ProviderRecord>: Sendable {
    public let result: ProviderResult<Item>
    public let capabilities: CapabilitySnapshot
    public let entitlement: EntitlementSnapshot
    fileprivate init(result: ProviderResult<Item>, capabilities: CapabilitySnapshot, entitlement: EntitlementSnapshot) {
        self.result = result; self.capabilities = capabilities; self.entitlement = entitlement
    }
}
public struct ProviderSession: Sendable {
    public let request: ProviderRequest
    public let capabilities: CapabilitySnapshot
    public let entitlement: EntitlementSnapshot
    public init(request: ProviderRequest, capabilities: CapabilitySnapshot, entitlement: EntitlementSnapshot?) throws {
        try ProviderAccess.validate(request, capabilities: capabilities, entitlement: entitlement)
        guard let entitlement else { throw ProviderFailure.notEntitled }
        self.request = request; self.capabilities = capabilities; self.entitlement = entitlement
    }
    public func accept<T>(_ result: ProviderResult<T>) throws -> ProviderExchange<T> {
        try result.validate(matching: request)
        guard result.items.allSatisfy({ $0.provenance.licenseRef == entitlement.licenseRef }) else { throw ProviderFailure.notEntitled }
        if request.capability == .quote {
            guard result.items.count <= 1, result.items.allSatisfy({ $0.recordID == request.resourceID }) else { throw ContractError.mismatchedSource }
        }
        return ProviderExchange(result: result, capabilities: capabilities, entitlement: entitlement)
    }
}
