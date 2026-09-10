import Foundation

public enum ContractError: String, Error, Sendable {
    case invalidIdentity, invalidTime, invalidRange, invalidEndpoint, invalidAvailability
    case invalidRequest, mismatchedRequest, mismatchedSource, duplicateRecord, invalidCoverage, ambiguousVersion, invalidNormalization
}
func nonblank(_ value: String?) -> Bool { value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
func finite(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }

public enum OriginKind: String, Sendable, Codable { case provider, filing, userImport, derived }
public enum Timeliness: String, Sendable, Codable { case realtime, delayed, endOfDay, notApplicable, unknown }
public enum QualityFlag: String, Sendable, Codable { case stale, missing, invalid, indicative, synthetic, modelDifference }
public enum Usage: String, Sendable, Codable, CaseIterable { case liveAnalysis, ledgerMark, historicalFill, pitResearch, replay }
public enum UnavailableReason: String, Error, Sendable, Codable {
    case syntheticData, unsuitableTier, invalidQuote, missingSourceTime, futureSourceTime, staleQuote, unqualifiedUsage
    case incompleteProvenance, notEntitled, invalidTime, pitUnavailable, specializedPolicyRequired, missingDependency
}
public enum LegacyDataTier: String, Sendable { case realtime, delayed, endOfDay, filing, userImport, derived, stale, unknown }

/// Closed logical-operation identifiers, never service URLs or interpolated request paths.
/// Concrete endpoint configuration belongs to the adapter configuration version.
public enum EndpointDescriptor: String, Sendable, Codable, CaseIterable {
    case quote = "market/quote", bars = "market/bars"
    case optionExpirations = "market/option-expirations", optionChain = "market/option-chain"
    case companyIdentity = "fundamentals/company-identity", submissions = "fundamentals/submissions"
    case companyFacts = "fundamentals/company-facts", macroSeries = "macro/series", ledgerMarks = "ledger/marks"
    case brokerImport = "import/broker", calculation = "derived/calculation", syntheticQuote = "synthetic/quote"
}

/// Calendar date, not an instant. Construction and decoding do not imply validation.
public struct MarketDate: Sendable, Codable, Comparable {
    public let year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
    public func start(in zone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { throw ContractError.invalidTime }
        return date
    }
}

public enum AvailabilityEvidence: Sendable, Codable, Equatable {
    case unknown
    case instant(Date, evidence: String)
    case interval(earliest: Date, latest: Date, evidence: String)
    case dateOnly(MarketDate, timeZoneID: String, evidence: String)
    /// Conservative upper bound for this version; receivedAt is deliberately not consulted.
    public func upperBound() throws -> Date {
        switch self {
        case .unknown: throw UnavailableReason.pitUnavailable
        case let .instant(date, evidence):
            guard finite(date), nonblank(evidence) else { throw ContractError.invalidAvailability }
            return date
        case let .interval(earliest, latest, evidence):
            guard finite(earliest), finite(latest), earliest <= latest, nonblank(evidence) else { throw ContractError.invalidAvailability }
            return latest
        case let .dateOnly(day, timeZoneID, evidence):
            guard let zone = TimeZone(identifier: timeZoneID), nonblank(evidence) else { throw ContractError.invalidAvailability }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let start = try day.start(in: zone)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { throw ContractError.invalidAvailability }
            return next
        }
    }
}
public enum VersionKind: String, Sendable, Codable { case sourceVersion, localContent, unknown }

/// References only: never store credential-bearing URLs, headers or raw response bodies here.
/// Values decoded from storage remain untrusted until validate() / the usage evaluator runs.
public struct Provenance: Sendable, Codable, Equatable {
    public let providerID: String
    public let feedID: String
    public let sourceEventAt: Date?
    public let receivedAt: Date
    public let availableAt: Date? // Legacy value, never accepted as standalone PIT evidence.
    public let evidenceRef: String?
    public let origin: OriginKind
    public let endpointDescriptor: String?
    public let requestedAt: Date?
    public let requestID: UUID?
    public let observationDate: MarketDate?
    public let versionID: String?
    public let versionKind: VersionKind
    public let revisionOf: String?
    public let availability: AvailabilityEvidence
    public let rawObjectRef: String?
    public let rawHash: String?
    public let normalizationVersion: String?
    public let licenseRef: String?
    public let attribution: String?
    public let legacySourceTimestamp: Date?

    public init(providerID: String, feedID: String, sourceEventAt: Date?, receivedAt: Date, availableAt: Date?, evidenceRef: String?, origin: OriginKind,
                endpointDescriptor: String? = nil, requestedAt: Date? = nil, requestID: UUID? = nil,
                observationDate: MarketDate? = nil, versionID: String? = nil, versionKind: VersionKind = .unknown,
                revisionOf: String? = nil, availability: AvailabilityEvidence = .unknown,
                rawObjectRef: String? = nil, rawHash: String? = nil, normalizationVersion: String? = nil,
                licenseRef: String? = nil, attribution: String? = nil, legacySourceTimestamp: Date? = nil) {
        self.providerID = providerID; self.feedID = feedID; self.sourceEventAt = sourceEventAt; self.receivedAt = receivedAt
        self.availableAt = availableAt; self.evidenceRef = evidenceRef; self.origin = origin
        self.endpointDescriptor = endpointDescriptor; self.requestedAt = requestedAt; self.requestID = requestID
        self.observationDate = observationDate; self.versionID = versionID; self.versionKind = versionKind
        self.revisionOf = revisionOf; self.availability = availability; self.rawObjectRef = rawObjectRef
        self.rawHash = rawHash; self.normalizationVersion = normalizationVersion; self.licenseRef = licenseRef
        self.attribution = attribution; self.legacySourceTimestamp = legacySourceTimestamp
    }
    public func validate() throws {
        guard nonblank(providerID), nonblank(feedID), nonblank(versionID), nonblank(evidenceRef),
              nonblank(rawObjectRef), nonblank(normalizationVersion), nonblank(licenseRef), requestID != nil,
              let hash = rawHash, hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw ContractError.invalidIdentity }
        guard let endpoint = endpointDescriptor, EndpointDescriptor(rawValue: endpoint) != nil else { throw ContractError.invalidEndpoint }
        guard finite(receivedAt), let requestedAt, finite(requestedAt), requestedAt <= receivedAt,
              sourceEventAt.map(finite) ?? true, legacySourceTimestamp.map(finite) ?? true,
              availableAt.map(finite) ?? true else { throw ContractError.invalidTime }
        if let observationDate { _ = try observationDate.start(in: TimeZone(secondsFromGMT: 0)!) }
        if availability != .unknown { _ = try availability.upperBound() }
        guard revisionOf == nil || (nonblank(revisionOf) && revisionOf != versionID) else { throw ContractError.invalidIdentity }
    }
    public func isAvailable(asOf cutoff: Date) -> Bool {
        guard finite(cutoff), versionKind == .sourceVersion, (try? validate()) != nil,
              let upper = try? availability.upperBound() else { return false }
        return upper <= cutoff
    }
}

public protocol ProviderRecord: Sendable {
    var recordID: String { get }
    var provenance: Provenance { get }
}

/// Selection groups by stable observation identity, then uses each version's own evidence.
/// Equal latest availability with distinct versions is ambiguous, never a lexical tie-break.
public enum AsOfSelector {
    public static func select<T: ProviderRecord>(_ versions: [T], cutoff: Date) throws -> T {
        guard finite(cutoff), !versions.isEmpty else { throw UnavailableReason.pitUnavailable }
        guard versions.allSatisfy({ nonblank($0.recordID) }), Set(versions.map(\.recordID)).count == 1,
              Set(versions.map { $0.provenance.providerID }).count == 1,
              Set(versions.map { $0.provenance.feedID }).count == 1,
              versions.allSatisfy({ $0.provenance.observationDate == versions[0].provenance.observationDate })
        else { throw ContractError.mismatchedSource }
        for value in versions { try value.provenance.validate() }
        guard Set(versions.compactMap { $0.provenance.versionID }).count == versions.count else { throw ContractError.duplicateRecord }
        let eligible = versions.compactMap { value -> (T, Date)? in
            guard value.provenance.isAvailable(asOf: cutoff), let upper = try? value.provenance.availability.upperBound() else { return nil }
            return (value, upper)
        }
        guard let latest = eligible.map({ $0.1 }).max() else { throw UnavailableReason.pitUnavailable }
        let selected = eligible.filter { $0.1 == latest }
        guard selected.count == 1 else { throw ContractError.ambiguousVersion }
        return selected[0].0
    }
}
