import Foundation
import CoreDomain

/// A separate versioned derivation. The older daily report and its intentionally
/// unavailable 25-Delta fields remain byte-for-byte replay compatible.
public struct OptionDelta25Input: Codable, Equatable, Sendable {
    public static let currentMethodVersion = "options.delta25.v1"
    public let id: UUID
    public let createdAt: Date
    public let daily: OptionDailyReport
    public let methodVersion: String
    public init(id: UUID = UUID(), createdAt: Date, daily: OptionDailyReport,
                methodVersion: String = currentMethodVersion) {
        self.id = id; self.createdAt = createdAt; self.daily = daily; self.methodVersion = methodVersion
    }
}

public enum OptionDelta25State: String, Codable, Sendable {
    case available, partialChain, unverifiedSessionClose, unknownQuoteTime, quoteSkew
    case missingCanonicalIV, nonMonotoneDelta, noDeltaBracket, noExpiryBracket, numericFailure, missingSide, mismatchedContractBasis
}

/// Signed local spot Delta, not absolute or premium-adjusted Delta. Point identity
/// and values are retained so a displayed interpolation cannot hide its contracts.
public struct OptionDelta25Point: Codable, Equatable, Sendable {
    public let contractID: String
    public let strike: Money
    public let delta: Double
    public let iv: Double
}

public struct OptionDelta25Selection: Codable, Equatable, Sendable {
    public let right: OptionLabRight
    public let targetDelta: Double
    public let state: OptionDelta25State
    /// One point for an exact match; two points for interpolation. Nil IV is never
    /// substituted with another side, expiry, provider field or hand-entered sigma.
    public let points: [OptionDelta25Point]
    /// Weight of the second point. Exact-match selections have weight zero.
    public let secondPointWeight: Double?
    public let iv: Double?
}

public struct OptionDelta25ExpirySummary: Codable, Equatable, Sendable {
    public let settlementAt: Date
    public let timeYears: Double
    public let call: OptionDelta25Selection
    public let put: OptionDelta25Selection
    public let state: OptionDelta25State
    public let putMinusCallSkew: Double?
}

public struct OptionDelta25Report: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let input: OptionDelta25Input
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let expiries: [OptionDelta25ExpirySummary]
    public let call25DeltaIV: Double?
    public let put25DeltaIV: Double?
    /// Put IV minus Call IV, in decimal volatility units, at the same 30-day tenor.
    public let putMinusCallSkew: Double?
    /// Both sides always use this same exact expiry or bracketing expiry pair.
    public let selectedExpiryInstants: [Date]
    public let state: OptionDelta25State
    public let containsSynthetic: Bool
    public let researchOnly: Bool
    public let limitations: [String]
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
}
