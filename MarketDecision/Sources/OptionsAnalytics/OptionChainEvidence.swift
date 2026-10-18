import Foundation
import CoreDomain
import DataContracts

/// Frozen acquisition is evidence for synthetic pipeline replay only. A successful
/// request or a caller's entitlement declaration never admits a real-feed model.
public struct OptionChainSelectionEvidence: Codable, Equatable, Sendable {
    public let capture: OptionChainCapture
    public let shortContractID: String
    public let longContractID: String?
    public init(capture: OptionChainCapture, shortContractID: String, longContractID: String?) {
        self.capture = capture; self.shortContractID = shortContractID; self.longContractID = longContractID
    }
}

public enum OptionChainEvidence {
    public static func reference(_ capture: OptionChainCapture) -> String {
        "SYNTHETIC-TRADIER-CAPTURE:" + capture.id.uuidString
    }
    public static func scope(_ capture: OptionChainCapture) -> String {
        "tradier candidate; explicitly requested expirations: " + capture.requestedExpirations.map(\.iso8601).joined(separator: ",")
    }
    public static func validateForLab(_ capture: OptionChainCapture) throws {
        try capture.validate()
        guard capture.synthetic, capture.snapshot.status == .complete, let underlying = capture.snapshot.underlying,
              !capture.snapshot.contracts.isEmpty else { throw OptionLabError.invalidIdentity }
        guard ([underlying] + capture.snapshot.contracts.map(\.quote)).allSatisfy({ !$0.quality.contains(.invalid) })
        else { throw OptionLabError.invalidQuote }
        // This checks a frozen synthetic scenario, not real-time feed eligibility.
        try validateClocks([underlying] + capture.snapshot.contracts.map(\.quote), asOf: capture.createdAt)
    }
    public static func validate(_ input: OptionLabInput) throws {
        guard let evidence = input.chainEvidence else { return }
        let capture = evidence.capture
        try validateForLab(capture)
        guard let underlying = capture.snapshot.underlying,
              input.asOf == capture.createdAt, input.underlying.symbol == capture.symbol,
              input.underlying.bid == underlying.bid, input.underlying.ask == underlying.ask,
              input.underlying.quotedAt == underlying.quoteTime,
              input.underlying.receivedAt == underlying.provenance.receivedAt,
              input.underlying.source.origin == .synthetic,
              input.underlying.source.reference == reference(capture),
              input.shortLeg.contractID == evidence.shortContractID,
              input.longLeg?.contractID == evidence.longContractID else { throw OptionLabError.incompatibleReport }
        for leg in [input.shortLeg] + (input.longLeg.map { [$0] } ?? []) {
            guard let contract = capture.snapshot.contracts.first(where: { $0.recordID == leg.contractID }),
                  contract.underlyingSymbol == leg.symbol, contract.expiration == leg.expirationDate,
                  contract.right.rawValue == leg.right.rawValue, contract.strike == leg.strike,
                  contract.multiplier == leg.multiplier, contract.quote.bid == leg.bid, contract.quote.ask == leg.ask,
                  contract.quote.bidSize == leg.bidSize, contract.quote.askSize == leg.askSize,
                  contract.quote.quoteTime == leg.quotedAt, contract.quote.provenance.receivedAt == leg.receivedAt,
                  leg.source.origin == .synthetic, leg.source.reference == reference(capture)
            else { throw OptionLabError.incompatibleReport }
        }
    }
    public static func validate(_ input: OptionDailyInput) throws {
        guard let capture = input.chainEvidence else { return }
        try capture.validate()
        guard capture.synthetic, let underlying = capture.snapshot.underlying,
              capture.snapshot.status == .complete || capture.snapshot.status == .partial,
              input.asOf == capture.createdAt, input.symbol == capture.symbol, input.feedID == capture.feedID,
              input.declaredScope == scope(capture), input.source.origin == .synthetic,
              input.source.reference == reference(capture), input.underlying.source == input.source,
              input.underlying.bid == underlying.bid, input.underlying.ask == underlying.ask,
              input.underlying.quoteTime == underlying.quoteTime,
              input.underlying.receivedAt == underlying.provenance.receivedAt,
              input.coverage == (capture.snapshot.status == .complete ? .complete : .partial),
              Set(input.contracts.map(\.contractID)) == Set(capture.snapshot.contracts.map(\.recordID)),
              input.contracts.count == capture.snapshot.contracts.count else { throw OptionDailyError.incompatibleReport }
        // A single quoteTime cannot prove that both sides were synchronized.
        // Recheck the frozen bid AND ask clocks before producing daily analytics.
        guard ([underlying] + capture.snapshot.contracts.map(\.quote)).allSatisfy({ !$0.quality.contains(.invalid) })
        else { throw OptionDailyError.invalidInput }
        do { try validateClocks([underlying] + capture.snapshot.contracts.map(\.quote), asOf: capture.createdAt) }
        catch { throw OptionDailyError.invalidTime }
        for item in input.contracts {
            guard let contract = capture.snapshot.contracts.first(where: { $0.recordID == item.contractID }),
                  item.strike == contract.strike, item.expiry.date == contract.expiration,
                  item.right.rawValue == contract.right.rawValue, item.multiplier == contract.multiplier,
                  item.bid == contract.quote.bid, item.ask == contract.quote.ask,
                  item.bidSize == contract.quote.bidSize, item.askSize == contract.quote.askSize,
                  item.quoteTime == contract.quote.quoteTime, item.receivedAt == contract.provenance.receivedAt,
                  item.source == input.source, item.activity.source == input.source,
                  item.activity.volume == nil, item.activity.openInterest == nil,
                  item.activity.volumeSession == nil, item.activity.openInterestAsOf == nil,
                  item.activity.openInterestReleasedAt == nil, item.activity.openInterestLatestPublished == nil
            else { throw OptionDailyError.incompatibleReport }
        }
    }
    private static func validateClocks(_ quotes: [OptionChainQuote], asOf: Date) throws {
        var times: [Date] = []
        for quote in quotes {
            guard let bid = quote.bidAt, let ask = quote.askAt,
                  quote.provenance.receivedAt <= asOf else { throw OptionLabError.invalidTime }
            for time in [bid, ask] {
                let age = asOf.timeIntervalSince(time)
                guard age.isFinite, age >= 0 else { throw OptionLabError.invalidTime }
                guard age <= 60 else { throw OptionLabError.staleQuote }
                times.append(time)
            }
        }
        guard let low = times.min(), let high = times.max(), high.timeIntervalSince(low) <= 5 else { throw OptionLabError.quoteSkew }
    }
}
