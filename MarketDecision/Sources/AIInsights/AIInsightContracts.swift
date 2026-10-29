import Foundation
import CryptoKit
import CoreDomain

/// Payload budgets, not a process-memory or API-spending guarantee.
public enum AIInsightLimits {
    public static let inputBytes = 128 * 1024
    public static let requestBodyBytes = 192 * 1024
    public static let responseBytes = 512 * 1024
    public static let analysisBytes = 96 * 1024
}

public enum AIInsightError: Error, Equatable, Sendable {
    case invalidInput, invalidModel, budgetExceeded, malformedResponse
    case incompleteResponse, refused, unexpectedOutput, invalidEvidence
    case outputLimitReached, contentFiltered, responseFailed
    case formatValidation(AIInsightFormatIssue)
    case outputStructure(AIInsightOutputIssue)
    case evidenceValidation(AIInsightEvidenceIssue, section: AIInsightClaimSection)
    case scenarioProposal(AIPriceSalesScenarioIssue)
}

/// Parser locations only. Never include model-generated keys, text, IDs or tokens.
public enum AIInsightFormatIssue: String, CaseIterable, Equatable, Sendable {
    case responseJSON, responseEnvelope, responseModel, responseOutput
    case analysisJSON, analysisFields, valuationFields, scenarioFields
    case sectionFields, claimFields, analysisDecode, usage
}

/// Closed diagnostics only. Neither a failed claim nor its actual reference IDs
/// can escape through an error, UI message or log description.
public enum AIInsightEvidenceIssue: String, CaseIterable, Equatable, Sendable {
    case emptyText, textTooLong, controlCharacter
    case missingReferences, tooManyReferences, duplicateReferences, unknownReference
}

public enum AIInsightClaimSection: String, CaseIterable, Equatable, Sendable {
    case summary, strengths, risks, questions, limitations
    case valuationInterpretation, valuationLimitations, valuationAssumptions
}

/// Closed parser locations only: never carry response text, field values or IDs.
public enum AIInsightOutputIssue: String, CaseIterable, Equatable, Sendable {
    case itemType, reasoningMetadata, messageEnvelope, messagePhase
    case ambiguousMessage, contentBlock, annotations, missingText
}

public struct AIInsightMetric: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    /// Exact, same-unit decimal text. No binary floating-point conversion is used.
    public let value: String?
    public let unit: String
    public let unavailable: String?
    public let sourceIDs: [String]

    public init(id: String, label: String, value: String?, unit: String,
                unavailable: String?, sourceIDs: [String]) {
        self.id = id; self.label = label; self.value = value; self.unit = unit
        self.unavailable = unavailable; self.sourceIDs = sourceIDs
    }
}

public struct AIInsightSource: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// Explicit user-provided reference inputs, not provider market data or a certified
/// capital review. The adapter calculates the six closed metrics locally before sending.
/// No raw filing, license text, free-form assumptions or provider prices belong here.
public struct AIInsightReferenceValuationContext: Codable, Equatable, Sendable {
    public static let currentMethod = "user-reference-multiples.v1"
    public static let referenceSourceID = "local.userReference"
    public static let confirmedBasis = "user-confirmed-single-common-class"
    public static let authorizedOrigin = "user-provided-authorized-reference"
    public let method, sourceID, basis, origin: String
    public let referenceAt, sharesAsOf: String

    public init(referenceAt: String, sharesAsOf: String) {
        method = Self.currentMethod; sourceID = Self.referenceSourceID
        basis = Self.confirmedBasis; origin = Self.authorizedOrigin
        self.referenceAt = referenceAt; self.sharesAsOf = sharesAsOf
    }

    internal func validate() throws {
        guard method == Self.currentMethod, sourceID == Self.referenceSourceID,
              basis == Self.confirmedBasis, origin == Self.authorizedOrigin,
              AIInsightInput.validCutoff(referenceAt), AIInsightInput.validDay(sharesAsOf),
              sharesAsOf <= String(referenceAt.prefix(10)) else { throw AIInsightError.invalidInput }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case method, sourceID, basis, origin, referenceAt, sharesAsOf
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AIInsightReferenceCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AIInsightError.invalidInput
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = try values.decode(String.self, forKey: .method)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        basis = try values.decode(String.self, forKey: .basis)
        origin = try values.decode(String.self, forKey: .origin)
        referenceAt = try values.decode(String.self, forKey: .referenceAt)
        sharesAsOf = try values.decode(String.self, forKey: .sharesAsOf)
        try validate()
    }
}

private struct AIInsightReferenceCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A deliberately closed summary shape: it has no holdings, trades, credentials,
/// contact email, URLs, source documents, or arbitrary metadata fields.
/// The composing layer must first verify the selected local financial report.
public struct AIInsightInput: Codable, Equatable, Sendable {
    public static let currentFormat = "ai-financial-summary.v2"
    public let format: String
    public let ticker: String
    public let companyName: String
    public let periodEnd: String
    public let cutoff: String
    public let metrics: [AIInsightMetric]
    public let sources: [AIInsightSource]
    public let referenceValuation: AIInsightReferenceValuationContext?

    public init(format: String = Self.currentFormat, ticker: String, companyName: String,
                periodEnd: String, cutoff: String, metrics: [AIInsightMetric], sources: [AIInsightSource],
                referenceValuation: AIInsightReferenceValuationContext? = nil) {
        self.format = format; self.ticker = ticker; self.companyName = companyName
        self.periodEnd = periodEnd; self.cutoff = cutoff; self.metrics = metrics; self.sources = sources
        self.referenceValuation = referenceValuation
    }

    public func validate() throws {
        guard format == Self.currentFormat,
              Self.matches(ticker, #"^[A-Z0-9][A-Z0-9.\-]{0,23}$"#),
              Self.validText(companyName, bytes: 240), Self.validDay(periodEnd),
              Self.validCutoff(cutoff), !metrics.isEmpty, metrics.count <= 64,
              !sources.isEmpty, sources.count <= 64 else { throw AIInsightError.invalidInput }
        let identifiers = metrics.map(\.id) + sources.map(\.id)
        guard identifiers.allSatisfy(Self.validID), Set(identifiers).count == identifiers.count else {
            throw AIInsightError.invalidInput
        }
        let sourceIDs = Set(sources.map(\.id))
        guard sources.allSatisfy({ Self.validText($0.label, bytes: 240) }) else {
            throw AIInsightError.invalidInput
        }
        for metric in metrics {
            guard Self.validText(metric.label, bytes: 240), Self.validText(metric.unit, bytes: 48),
                  metric.sourceIDs.count <= 12,
                  Set(metric.sourceIDs).count == metric.sourceIDs.count,
                  Set(metric.sourceIDs).isSubset(of: sourceIDs) else { throw AIInsightError.invalidInput }
            if let value = metric.value {
                guard metric.unavailable == nil, !metric.sourceIDs.isEmpty,
                      value.utf8.count <= 160, (try? Money(value)) != nil else {
                    throw AIInsightError.invalidInput
                }
            } else {
                guard let reason = metric.unavailable, Self.validText(reason, bytes: 400) else {
                    throw AIInsightError.invalidInput
                }
            }
        }
        try validateReferenceValuation()
    }

    /// Availability for the one approved scenario method, after `validate()` has passed.
    /// A generic revenue label, quarterly revenue or an uncertified alternate source cannot
    /// silently substitute for the selected report's replayed TTM revenue.
    public var supportsPriceSalesScenarios: Bool {
        let revenues = metrics.filter { $0.id == "base.revenue" }
        let shares = metrics.filter { $0.id == "reference.shares" }
        guard referenceValuation != nil, revenues.count == 1, shares.count == 1,
              let revenue = revenues.first, revenue.unit == "USD", revenue.sourceIDs == ["local.base"],
              revenue.unavailable == nil, let revenueText = revenue.value,
              let amount = try? Money(revenueText), amount.amount > 0,
              let share = shares.first, share.unit == "shares",
              share.sourceIDs == [AIInsightReferenceValuationContext.referenceSourceID],
              share.unavailable == nil, let shareText = share.value,
              let count = try? Money(shareText), count.amount > 0,
              !count.decimalString.contains(".") else { return false }
        return true
    }

    /// The reference namespace cannot be used without its explicit user-reference scope.
    /// Arithmetic and citation checks do not authenticate a user's price or share assertion.
    private func validateReferenceValuation() throws {
        let rows = metrics.filter { $0.id.hasPrefix("reference.") }
        let sourceID = AIInsightReferenceValuationContext.referenceSourceID
        guard let context = referenceValuation else {
            guard rows.isEmpty, !sources.contains(where: { $0.id == sourceID }) else {
                throw AIInsightError.invalidInput
            }
            return
        }
        try context.validate()
        // Both UTC strings have already been validated. Compare all represented
        // fractional digits rather than losing a submillisecond boundary in Date parsing.
        guard Self.validatedUTCOrderingKey(context.referenceAt) >= Self.validatedUTCOrderingKey(cutoff) else {
            throw AIInsightError.invalidInput
        }
        let units = ["reference.price": "USD/share", "reference.shares": "shares", "reference.marketCap": "USD",
                     "reference.pe": "multiple", "reference.ps": "multiple", "reference.pfcf": "multiple"]
        guard rows.count == units.count, Set(rows.map(\.id)) == Set(units.keys),
              sources.contains(where: { $0.id == sourceID }),
              rows.allSatisfy({ $0.unit == units[$0.id] && $0.sourceIDs == [sourceID] }) else {
            throw AIInsightError.invalidInput
        }
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        guard let priceText = values["reference.price"]?.value, let price = try? Money(priceText), price.amount > 0,
              let sharesText = values["reference.shares"]?.value, let shares = try? Money(sharesText), shares.amount > 0,
              !shares.decimalString.contains("."),
              let capText = values["reference.marketCap"]?.value, let cap = try? Money(capText), cap.amount > 0,
              let calculatedCap = try? price.multiplied(by: shares.decimalString), calculatedCap == cap else {
            throw AIInsightError.invalidInput
        }
        for key in ["reference.pe", "reference.ps", "reference.pfcf"] {
            if let text = values[key]?.value {
                guard let value = try? Money(text), value.amount > 0 else { throw AIInsightError.invalidInput }
            }
            // A missing denominator stays an explicit missing metric; no zero fallback.
        }
    }

    private static func validatedUTCOrderingKey(_ value: String) -> String {
        let suffix = value.dropFirst(19).dropLast()
        let fraction = suffix.first == "." ? String(suffix.dropFirst()) : ""
        return String(value.prefix(19)) + "." + fraction + String(repeating: "0", count: 9 - fraction.count)
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= AIInsightLimits.inputBytes else { throw AIInsightError.budgetExceeded }
        return data
    }

    /// Versioned contract plus sorted-key JSON. This is not RFC 8785 canonical JSON.
    public func digest() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }

    internal var evidenceIDs: Set<String> { Set(metrics.map(\.id) + sources.map(\.id)) }
    internal static func validID(_ value: String) -> Bool {
        matches(value, #"^[A-Za-z0-9][A-Za-z0-9._\-]{0,95}$"#)
    }
    internal static func validText(_ text: String, bytes: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= bytes &&
        !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    internal static func matches(_ value: String, _ expression: String) -> Bool {
        value.range(of: expression, options: .regularExpression) != nil
    }
    internal static func validDay(_ value: String) -> Bool {
        guard matches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#) else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
    internal static func validCutoff(_ value: String) -> Bool {
        guard value.utf8.count <= 40,
              matches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$"#),
              validDay(String(value.prefix(10))) else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

public struct AIInsightClaim: Codable, Equatable, Sendable {
    public let text: String
    public let evidenceIDs: [String]
    public init(text: String, evidenceIDs: [String]) { self.text = text; self.evidenceIDs = evidenceIDs }
}

/// Neither scope grants market-data qualification, a fair-value model or price cheapness.
/// Reference multiples remain a user-supplied scenario calculated locally.
public enum AIInsightValuationScope: String, Codable, Equatable, Sendable {
    case financialContextOnly, referenceMultiples
}

public struct AIInsightValuation: Codable, Equatable, Sendable {
    public let scope: AIInsightValuationScope
    public let interpretation: AIInsightClaim
    public let limitations: [AIInsightClaim]
    /// Proposed assumptions only. This object contains no generated price and grants
    /// no permission to calculate until the user explicitly confirms this result.
    public let scenarioProposal: AIPriceSalesScenarioProposal?

    public init(scope: AIInsightValuationScope = .financialContextOnly,
                interpretation: AIInsightClaim, limitations: [AIInsightClaim],
                scenarioProposal: AIPriceSalesScenarioProposal? = nil) {
        self.scope = scope; self.interpretation = interpretation; self.limitations = limitations
        self.scenarioProposal = scenarioProposal
    }
}

public struct AIInsightAnalysis: Codable, Equatable, Sendable {
    public let summary: AIInsightClaim
    public let strengths: [AIInsightClaim]
    public let risks: [AIInsightClaim]
    public let questions: [AIInsightClaim]
    public let limitations: [AIInsightClaim]
    public let valuation: AIInsightValuation

    public init(summary: AIInsightClaim, strengths: [AIInsightClaim], risks: [AIInsightClaim],
                questions: [AIInsightClaim], limitations: [AIInsightClaim], valuation: AIInsightValuation) {
        self.summary = summary; self.strengths = strengths; self.risks = risks
        self.questions = questions; self.limitations = limitations; self.valuation = valuation
    }

    /// Checks structure, budgets and citation membership; it is not a semantic proof
    /// of generated prose or evidence of market valuation eligibility.
    public func validate(for input: AIInsightInput) throws {
        try input.validate()
        guard strengths.count <= 6, risks.count <= 6, questions.count <= 6,
              !limitations.isEmpty, limitations.count <= 6,
              valuation.scope == (input.referenceValuation == nil ? .financialContextOnly : .referenceMultiples),
              !valuation.limitations.isEmpty, valuation.limitations.count <= 3 else {
            throw AIInsightError.malformedResponse
        }
        if input.supportsPriceSalesScenarios {
            guard let proposal = valuation.scenarioProposal else {
                throw AIInsightError.scenarioProposal(.missingProposal)
            }
            try proposal.validate(for: input)
        } else if valuation.scenarioProposal != nil {
            throw AIInsightError.scenarioProposal(.ineligibleInput)
        }
        let groups: [(AIInsightClaimSection, [AIInsightClaim], Int)] = [
            (.summary, [summary], 2_000), (.strengths, strengths, 2_000),
            (.risks, risks, 2_000), (.questions, questions, 2_000),
            (.limitations, limitations, 2_000),
            (.valuationInterpretation, [valuation.interpretation], 900),
            (.valuationLimitations, valuation.limitations, 600)
        ]
        for (section, claims, byteLimit) in groups {
            for claim in claims {
                try Self.validate(claim, section: section, byteLimit: byteLimit, allowedIDs: input.evidenceIDs)
            }
        }
    }

    internal static func validate(_ claim: AIInsightClaim, section: AIInsightClaimSection,
                                 byteLimit: Int, allowedIDs: Set<String>) throws {
        guard !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIInsightError.evidenceValidation(.emptyText, section: section)
        }
        guard claim.text.utf8.count <= byteLimit else {
            throw AIInsightError.evidenceValidation(.textTooLong, section: section)
        }
        guard !claim.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AIInsightError.evidenceValidation(.controlCharacter, section: section)
        }
        guard !claim.evidenceIDs.isEmpty else {
            throw AIInsightError.evidenceValidation(.missingReferences, section: section)
        }
        guard claim.evidenceIDs.count <= 12 else {
            throw AIInsightError.evidenceValidation(.tooManyReferences, section: section)
        }
        let citations = Set(claim.evidenceIDs)
        guard citations.count == claim.evidenceIDs.count else {
            throw AIInsightError.evidenceValidation(.duplicateReferences, section: section)
        }
        guard citations.isSubset(of: allowedIDs) else {
            throw AIInsightError.evidenceValidation(.unknownReference, section: section)
        }
    }
}

public struct AIInsightUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
    }
}

/// A structurally checked AI interpretation, not verified calculations or advice.
/// Generated prose cannot replace or mutate the report whose digest is bound here.
public struct AIInsightResult: Codable, Equatable, Sendable {
    public let inputDigest: String
    public let requestedModel: String
    public let model: String
    public let promptVersion: String
    public let analysis: AIInsightAnalysis
    public let usage: AIInsightUsage?
}
