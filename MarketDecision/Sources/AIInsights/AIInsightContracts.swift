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

/// A deliberately closed summary shape: it has no holdings, trades, credentials,
/// contact email, URLs, source documents, or arbitrary metadata fields.
/// The composing layer must first verify the selected local financial report.
public struct AIInsightInput: Codable, Equatable, Sendable {
    public static let currentFormat = "ai-financial-summary.v1"
    public let format: String
    public let ticker: String
    public let companyName: String
    public let periodEnd: String
    public let cutoff: String
    public let metrics: [AIInsightMetric]
    public let sources: [AIInsightSource]

    public init(format: String = Self.currentFormat, ticker: String, companyName: String,
                periodEnd: String, cutoff: String, metrics: [AIInsightMetric], sources: [AIInsightSource]) {
        self.format = format; self.ticker = ticker; self.companyName = companyName
        self.periodEnd = periodEnd; self.cutoff = cutoff; self.metrics = metrics; self.sources = sources
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
    private static func validDay(_ value: String) -> Bool {
        guard matches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#) else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
    private static func validCutoff(_ value: String) -> Bool {
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

public struct AIInsightAnalysis: Codable, Equatable, Sendable {
    public let summary: AIInsightClaim
    public let strengths: [AIInsightClaim]
    public let risks: [AIInsightClaim]
    public let questions: [AIInsightClaim]
    public let limitations: [AIInsightClaim]

    public init(summary: AIInsightClaim, strengths: [AIInsightClaim], risks: [AIInsightClaim],
                questions: [AIInsightClaim], limitations: [AIInsightClaim]) {
        self.summary = summary; self.strengths = strengths; self.risks = risks
        self.questions = questions; self.limitations = limitations
    }

    internal func validate(for input: AIInsightInput) throws {
        guard strengths.count <= 6, risks.count <= 6, questions.count <= 6,
              !limitations.isEmpty, limitations.count <= 6 else { throw AIInsightError.malformedResponse }
        for claim in [summary] + strengths + risks + questions + limitations {
            guard AIInsightInput.validText(claim.text, bytes: 2_000),
                  !claim.evidenceIDs.isEmpty, claim.evidenceIDs.count <= 12,
                  Set(claim.evidenceIDs).count == claim.evidenceIDs.count,
                  Set(claim.evidenceIDs).isSubset(of: input.evidenceIDs) else {
                throw AIInsightError.invalidEvidence
            }
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
