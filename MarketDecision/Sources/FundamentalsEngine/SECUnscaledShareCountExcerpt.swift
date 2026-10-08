import CoreDomain

/// Parses a positive, unscaled count from an exact ASCII source excerpt. Only plain digits or
/// conventional comma groups are accepted. This never trims text, decodes HTML, guesses units,
/// applies an XBRL scale, or proves that the selected excerpt describes the full share universe.
/// Keep the original excerpt and its source anchor; the returned Money preserves the exact value.
public enum SECUnscaledShareCountExcerpt {
    static let plainPolicy = "unscaled-ascii-digits.v1"
    static let groupedPolicy = "unscaled-ascii-comma-groups.v1"

    public static func parse(_ excerpt: String) throws -> Money {
        try parse(excerpt, policy: policy(for: excerpt))
    }

    static func policy(for excerpt: String) -> String {
        excerpt.utf8.contains(44) ? groupedPolicy : plainPolicy
    }

    static func parse(_ excerpt: String, policy: String) throws -> Money {
        guard policy == plainPolicy || policy == groupedPolicy else { throw SECValuationError.unsupportedFormat }
        let bytes = Array(excerpt.utf8)
        guard let first = bytes.first, (49...57).contains(first) else { throw SECValuationError.invalidEvidence }
        let digits: [UInt8]
        if policy == plainPolicy {
            guard bytes.allSatisfy({ (48...57).contains($0) }) else { throw SECValuationError.invalidEvidence }
            digits = bytes
        } else {
            let groups = bytes.split(separator: 44, omittingEmptySubsequences: false)
            guard groups.count >= 2, let firstGroup = groups.first, (1...3).contains(firstGroup.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }),
                  groups.allSatisfy({ $0.allSatisfy({ (48...57).contains($0) }) })
            else { throw SECValuationError.invalidEvidence }
            digits = bytes.filter { $0 != 44 }
        }
        // Money rejects precision loss and unrepresentable integers; no floating-point path or
        // rounding is permitted just because the source used display grouping.
        do { return try Money(String(decoding: digits, as: UTF8.self)) }
        catch { throw SECValuationError.invalidEvidence }
    }
}
