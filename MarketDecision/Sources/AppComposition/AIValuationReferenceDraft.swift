import Foundation
import CoreDomain
import DataContracts

public enum AIValuationReferenceError: Error, Equatable, Sendable {
    case invalidPrice, invalidShares, invalidReferenceDate, invalidSharesDate
    case unconfirmedShareBasis, sendingNotAllowed
}

/// Editable, local-only reference assumptions. Neither an imported quote nor a detected
/// SEC share count silently grants consent to include it in an external AI request.
public struct AIValuationReferenceDraft: Equatable, Sendable {
    public var price: String
    public var referenceAt: Date
    public var shares: String
    public var sharesAsOf: String
    public var confirmedSingleClassSameBasis: Bool
    public var maySendReferenceData: Bool

    public init(now: Date = Date()) {
        price = ""; referenceAt = now; shares = ""; sharesAsOf = ""
        confirmedSingleClassSameBasis = false; maySendReferenceData = false
    }

    public func validated(now: Date = Date()) throws -> AIValuationReferenceInput {
        guard confirmedSingleClassSameBasis else { throw AIValuationReferenceError.unconfirmedShareBasis }
        guard maySendReferenceData else { throw AIValuationReferenceError.sendingNotAllowed }
        guard let price = try? Money(price.trimmingCharacters(in: .whitespacesAndNewlines)),
              price.amount > 0 else { throw AIValuationReferenceError.invalidPrice }
        guard let shares = try? Money(shares.trimmingCharacters(in: .whitespacesAndNewlines)),
              shares.amount > 0, !shares.decimalString.contains(".") else {
            throw AIValuationReferenceError.invalidShares
        }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              referenceAt.timeIntervalSinceReferenceDate.isFinite, referenceAt <= now,
              let cutoff = try? AIInsightReportAdapter.utcCutoff(referenceAt),
              let referenceDay = try? MarketDate(iso8601: String(cutoff.prefix(10))) else {
            throw AIValuationReferenceError.invalidReferenceDate
        }
        let dayText = sharesAsOf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dayText.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let day = try? MarketDate(iso8601: dayText), day.iso8601 == dayText,
              day <= referenceDay else { throw AIValuationReferenceError.invalidSharesDate }
        return AIValuationReferenceInput(price: price, referenceAt: referenceAt,
            shares: shares, sharesAsOf: day)
    }
}

/// An immutable user assertion, not authenticated market data or verified capital.
/// There is intentionally no Codable/public initializer or free-form source text.
public struct AIValuationReferenceInput: Equatable, Sendable {
    public let price: Money
    public let referenceAt: Date
    public let shares: Money
    public let sharesAsOf: MarketDate

    fileprivate init(price: Money, referenceAt: Date, shares: Money, sharesAsOf: MarketDate) {
        self.price = price; self.referenceAt = referenceAt; self.shares = shares; self.sharesAsOf = sharesAsOf
    }
}
