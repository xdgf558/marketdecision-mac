import Foundation
import CoreDomain

/// Closed reasons only; model text and arbitrary keys never escape through errors.
public enum AIPriceSalesScenarioIssue: String, CaseIterable, Equatable, Sendable {
    case missingProposal, ineligibleInput, unsupportedMethod
    case invalidMultiple, unorderedMultiples, missingBasisReferences
}

/// An AI-suggested dimensionless multiple, explicitly not a financial fact or price.
public struct AIPriceSalesScenarioAssumption: Codable, Equatable, Sendable {
    public let multiple: String
    public let rationale: AIInsightClaim

    public init(multiple: String, rationale: AIInsightClaim) {
        self.multiple = multiple; self.rationale = rationale
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case multiple, rationale }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AIPriceSalesCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AIInsightError.malformedResponse
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        multiple = try values.decode(String.self, forKey: .multiple)
        // Reject unadvertised fields inside the claim even when decoded outside parseResponse.
        let rationaleDecoder = try values.superDecoder(forKey: .rationale)
        let claimKeys = try rationaleDecoder.container(keyedBy: AIPriceSalesCodingKey.self)
        guard Set(claimKeys.allKeys.map(\.stringValue)) == Set(["text", "evidenceIDs"]) else {
            throw AIInsightError.malformedResponse
        }
        rationale = try AIInsightClaim(from: rationaleDecoder)
    }
}

/// Three unconfirmed price/sales assumptions. Neither decoding nor validation calculates
/// or approves prices. The composing layer binds confirmation to the exact input/result.
public struct AIPriceSalesScenarioProposal: Codable, Equatable, Sendable {
    public static let currentMethod = "ai-ps-scenarios.v1"
    public let method: String
    public let conservative: AIPriceSalesScenarioAssumption
    public let base: AIPriceSalesScenarioAssumption
    public let optimistic: AIPriceSalesScenarioAssumption

    public init(method: String = Self.currentMethod, conservative: AIPriceSalesScenarioAssumption,
                base: AIPriceSalesScenarioAssumption, optimistic: AIPriceSalesScenarioAssumption) {
        self.method = method; self.conservative = conservative; self.base = base; self.optimistic = optimistic
    }

    public func validate(for input: AIInsightInput) throws {
        try input.validate()
        guard input.supportsPriceSalesScenarios else { throw AIInsightError.scenarioProposal(.ineligibleInput) }
        guard method == Self.currentMethod else { throw AIInsightError.scenarioProposal(.unsupportedMethod) }
        let assumptions = [conservative, base, optimistic]
        let values = try assumptions.map { assumption -> Money in
            guard assumption.multiple.utf8.count <= 160,
                  let value = try? Money(assumption.multiple), value.amount > 0 else {
                throw AIInsightError.scenarioProposal(.invalidMultiple)
            }
            try AIInsightAnalysis.validate(assumption.rationale, section: .valuationAssumptions,
                                           byteLimit: 600, allowedIDs: input.evidenceIDs)
            guard Set(["base.revenue", "reference.shares"]).isSubset(of: Set(assumption.rationale.evidenceIDs)) else {
                throw AIInsightError.scenarioProposal(.missingBasisReferences)
            }
            return value
        }
        // All three slots above are fixed. Ordering is semantic, never auto-sorted or clamped.
        guard values[0] < values[1], values[1] < values[2] else {
            throw AIInsightError.scenarioProposal(.unorderedMultiples)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case method, conservative, base, optimistic }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AIPriceSalesCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AIInsightError.malformedResponse
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = try values.decode(String.self, forKey: .method)
        conservative = try values.decode(AIPriceSalesScenarioAssumption.self, forKey: .conservative)
        base = try values.decode(AIPriceSalesScenarioAssumption.self, forKey: .base)
        optimistic = try values.decode(AIPriceSalesScenarioAssumption.self, forKey: .optimistic)
    }
}

private struct AIPriceSalesCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
