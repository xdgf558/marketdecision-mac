import Foundation
import CoreDomain

/// Candidate Tradier environments, not subscription or exchange entitlement assertions.
public enum OptionChainEnvironment: String, Codable, Sendable {
    case production, sandbox
    public var feedID: String { self == .sandbox ? "tradier-sandbox-delayed" : "tradier-production-unqualified" }
    public var host: String { self == .sandbox ? "sandbox.tradier.com" : "api.tradier.com" }
    public var timeliness: Timeliness { self == .sandbox ? .delayed : .unknown }
}
public enum OptionChainTimestampUnit: String, Codable, Sendable { case unixSeconds, unixMilliseconds }
public enum OptionChainCaptureStatus: String, Codable, Sendable { case complete, partial, empty, error }
public enum OptionChainRight: String, Codable, Sendable { case call, put }

/// No credential bytes, headers or URLs are frozen in the data envelope.
public struct OptionChainRights: Codable, Equatable, Sendable {
    public let version: String, evidenceRef: String, licenseRef: String
    public let validFrom: Date, validThrough: Date
    public let capabilities: Set<ProviderCapability>, usages: Set<Usage>
    public init(version: String, evidenceRef: String, licenseRef: String, validFrom: Date, validThrough: Date,
                capabilities: Set<ProviderCapability>, usages: Set<Usage>) {
        self.version = version; self.evidenceRef = evidenceRef; self.licenseRef = licenseRef
        self.validFrom = validFrom; self.validThrough = validThrough; self.capabilities = capabilities; self.usages = usages
    }
    public func entitlement(environment: OptionChainEnvironment) -> EntitlementSnapshot {
        .init(providerID: "tradier", feedID: environment.feedID, version: version, evidenceRef: evidenceRef,
              licenseRef: licenseRef, capabilities: capabilities, usages: usages, validFrom: validFrom, validThrough: validThrough)
    }
}

/// One HTTP page. Tradier chains are complete per expiration, not token-paginated.
/// Raw bytes include unsuccessful responses; error pages never become empty success.
public struct OptionChainRawPage: Codable, Equatable, Sendable {
    public let request: ProviderRequest
    public let expiration: MarketDate?
    public let receivedAt: Date
    public let statusCode: Int
    public let bytes: Data
    public let contentHash: String
    public init(request: ProviderRequest, expiration: MarketDate? = nil, receivedAt: Date, statusCode: Int, bytes: Data) {
        self.request = request; self.expiration = expiration; self.receivedAt = receivedAt; self.statusCode = statusCode
        let frozen = bytes.withUnsafeBytes { buffer -> Data in
            guard let base = buffer.baseAddress else { return Data() }
            return Data(bytes: base, count: buffer.count)
        }
        self.bytes = frozen; self.contentHash = digest(frozen)
    }
    public var reference: String {
        "tradier/" + request.id.uuidString.lowercased() + "/" + request.capability.rawValue + "/" + (expiration?.iso8601 ?? "single")
    }
}

public struct OptionChainQuote: Codable, Equatable, Sendable, ProviderRecord {
    public var recordID: String { symbol }
    public let symbol: String
    public let bid: Money, ask: Money
    public let bidSize: Int, askSize: Int
    public let bidAt: Date?, askAt: Date?
    public let provenance: Provenance
    public let timeliness: Timeliness
    public let quality: Set<QualityFlag>
    public var quote: Quote { .init(symbol: symbol, bid: bid, ask: ask, provenance: provenance,
                                   timeliness: timeliness, quality: quality, qualifiedUsages: []) }
    /// Both sides must carry clocks; conservatively retain the older side for quote-age checks.
    public var quoteTime: Date? { guard let bidAt, let askAt else { return nil }; return min(bidAt, askAt) }
}
public struct OptionChainContract: Codable, Equatable, Sendable, ProviderRecord {
    public var recordID: String { quote.symbol }
    public var provenance: Provenance { quote.provenance }
    public let underlyingSymbol: String
    public let expiration: MarketDate
    public let right: OptionChainRight
    public let strike: Money
    public let multiplier: Int
    public let quote: OptionChainQuote
    /// Raw observed totals only. No full-session or independent OI publication evidence is supplied by this endpoint.
    public let observedVolume: Int?
    public let observedOpenInterest: Int?
}
public struct OptionChainSnapshot: Codable, Equatable, Sendable {
    public let status: OptionChainCaptureStatus
    public let listedExpirations: [MarketDate]
    public let requestedExpirations: [MarketDate]
    public let completedExpirations: [MarketDate]
    public let underlying: OptionChainQuote?
    public let contracts: [OptionChainContract]
    public let failures: [ProviderFailure]
    public var qualifiedForLiveAnalysis: Bool { false }
    public var qualifiedForPIT: Bool { false }
}

/// Immutable source envelope. Decoding is untrusted until validate replays every raw page,
/// pins each request to capability/rights snapshots, and compares the complete normalized value.
/// A capture is not official contract specification, a trading calendar, or a daily close.
public struct OptionChainCapture: Codable, Equatable, Sendable {
    public static let schema = "options.chain-capture.v1"
    public static let configurationVersion = "tradier-chain-per-expiry.v1"
    public let schemaVersion: String
    public let id: UUID
    public let createdAt: Date, requestedAt: Date
    public let symbol: String
    public let environment: OptionChainEnvironment
    public let timestampUnit: OptionChainTimestampUnit
    public let synthetic: Bool
    public let rights: OptionChainRights
    public let requestedExpirations: [MarketDate]
    public let pages: [OptionChainRawPage]
    public let snapshot: OptionChainSnapshot
    public var providerID: String { "tradier" }
    public var feedID: String { environment.feedID }
    public static func capabilities(environment: OptionChainEnvironment) -> CapabilitySnapshot {
        .init(providerID: "tradier", version: configurationVersion, feeds: [environment.feedID],
              capabilities: [.quote, .optionExpirations, .optionChain])
    }
    public init(id: UUID, createdAt: Date, requestedAt: Date, symbol: String,
                environment: OptionChainEnvironment, timestampUnit: OptionChainTimestampUnit, synthetic: Bool,
                rights: OptionChainRights, requestedExpirations: [MarketDate], pages: [OptionChainRawPage]) throws {
        self.schemaVersion = Self.schema; self.id = id; self.createdAt = createdAt; self.requestedAt = requestedAt
        self.symbol = symbol; self.environment = environment; self.timestampUnit = timestampUnit; self.synthetic = synthetic
        self.rights = rights; self.requestedExpirations = requestedExpirations; self.pages = pages
        self.snapshot = try OptionChainDecoder.replay(id: id, createdAt: createdAt, requestedAt: requestedAt,
            symbol: symbol, environment: environment, timestampUnit: timestampUnit, synthetic: synthetic,
            rights: rights, requestedExpirations: requestedExpirations, pages: pages)
    }
    public func validate() throws {
        guard schemaVersion == Self.schema else { throw ContractError.invalidIdentity }
        let replay = try OptionChainDecoder.replay(id: id, createdAt: createdAt, requestedAt: requestedAt,
            symbol: symbol, environment: environment, timestampUnit: timestampUnit, synthetic: synthetic,
            rights: rights, requestedExpirations: requestedExpirations, pages: pages)
        guard snapshot == replay else { throw ContractError.invalidNormalization }
    }
}

extension OptionChainRights {
    private enum CodingKeys: String, CodingKey { case version, evidenceRef, licenseRef, validFrom, validThrough, capabilities, usages }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(version, forKey: .version); try value.encode(evidenceRef, forKey: .evidenceRef)
        try value.encode(licenseRef, forKey: .licenseRef); try value.encode(validFrom, forKey: .validFrom)
        try value.encode(validThrough, forKey: .validThrough)
        try value.encode(capabilities.sorted { $0.rawValue < $1.rawValue }, forKey: .capabilities)
        try value.encode(usages.sorted { $0.rawValue < $1.rawValue }, forKey: .usages)
    }
}
extension OptionChainQuote {
    private enum CodingKeys: String, CodingKey { case symbol, bid, ask, bidSize, askSize, bidAt, askAt, provenance, timeliness, quality }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(symbol, forKey: .symbol); try value.encode(bid, forKey: .bid); try value.encode(ask, forKey: .ask)
        try value.encode(bidSize, forKey: .bidSize); try value.encode(askSize, forKey: .askSize)
        try value.encodeIfPresent(bidAt, forKey: .bidAt); try value.encodeIfPresent(askAt, forKey: .askAt)
        try value.encode(provenance, forKey: .provenance); try value.encode(timeliness, forKey: .timeliness)
        try value.encode(quality.sorted { $0.rawValue < $1.rawValue }, forKey: .quality)
    }
}
