import Foundation

public enum MoneyError: Error, Equatable {
    case invalidDecimal, precisionExceeded, arithmeticFailure, divisionByZero, invalidLots
}

/// Explicit output boundaries; intermediate values are never automatically posted.
public enum DecimalScale: Int, Sendable, Codable {
    case accounting = 2, unitPrice = 6, shares = 8, division = 18
}

/// Exact decimal used for USD amounts and observations with an explicit external unit.
/// Factors/divisors are dimensionless strings. No binary floating-point initializer.
/// Canonical encoding preserves value, not source spelling (keep rawValue separately).
public struct Money: Equatable, Comparable, Sendable, Codable {
    public static let numericPolicyVersion = "decimal38-halfEven18.v1"
    public let amount: Decimal

    public init(_ text: String) throws {
        guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw MoneyError.invalidDecimal
        }
        let canonical = Self.canonical(text)
        let significant = canonical.filter(\.isNumber).drop(while: { $0 == "0" }).reversed().drop(while: { $0 == "0" })
        guard significant.count <= 38 else { throw MoneyError.precisionExceeded }
        guard var value = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN,
              Self.canonical(NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))) == canonical else {
            // Decimal(string:) may silently underflow or round. Require an exact round trip.
            throw MoneyError.invalidDecimal
        }
        self.amount = value
    }
    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.amount < rhs.amount }
    public var decimalString: String {
        var value = amount
        return Self.canonical(NSDecimalString(&value, Locale(identifier: "en_US_POSIX")))
    }
    public func rounded(to scale: DecimalScale) throws -> Money {
        let parts = DecimalDigits.parts(decimalString)
        guard parts.scale > scale.rawValue else { return self }
        let denominator = "1" + String(repeating: "0", count: parts.scale - scale.rawValue)
        let coefficient = DecimalDigits.roundedQuotient(parts.digits, by: denominator)
        return try Money(DecimalDigits.decimal(coefficient, scale: scale.rawValue, negative: amount < 0))
    }
    public func posted() throws -> Money { try rounded(to: .accounting) }
    /// Locale-independent fixed-scale presentation; stored amount remains unchanged.
    public func fixedString(at scale: DecimalScale = .accounting) throws -> String {
        let text = try rounded(to: scale).decimalString
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: scale.rawValue - fraction.count)
    }
    public func adding(_ other: Money) throws -> Money { try combined(with: other, subtract: false) }
    public func subtracting(_ other: Money) throws -> Money { try combined(with: other, subtract: true) }
    public func multiplied(by factor: String) throws -> Money {
        let factor = try Money(factor)
        let a = DecimalDigits.parts(decimalString), b = DecimalDigits.parts(factor.decimalString)
        return try Money(DecimalDigits.decimal(DecimalDigits.multiply(a.digits, b.digits), scale: a.scale + b.scale,
                                              negative: (amount < 0) != (factor.amount < 0)))
    }

    /// Exact long division, rounded once at 18 fractional digits using half-even.
    /// A rounded Foundation quotient never decides a tie. A nonzero result below this
    /// explicit output scale may round to zero; unrepresentable inputs never do.
    public func divided(by divisor: String) throws -> Money {
        let rhs = try Money(divisor)
        guard rhs.amount != 0 else { throw MoneyError.divisionByZero }
        let lhsParts = DecimalDigits.parts(decimalString), rhsParts = DecimalDigits.parts(rhs.decimalString)
        let numerator = lhsParts.digits + String(repeating: "0", count: rhsParts.scale + 18)
        let denominator = rhsParts.digits + String(repeating: "0", count: lhsParts.scale)
        let rounded = DecimalDigits.roundedQuotient(numerator, by: denominator)
        return try Money(DecimalDigits.decimal(rounded, scale: 18, negative: (amount < 0) != (rhs.amount < 0)))
    }

    /// Post total once. Ascending lot IDs receive cents truncated toward zero;
    /// the final ID receives the exact remainder. No rounded decimal quotient is used.
    public func allocatedEqually(to lotIDs: [String]) throws -> [String: Money] {
        guard !lotIDs.isEmpty, Set(lotIDs).count == lotIDs.count,
              lotIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MoneyError.invalidLots
        }
        let keys = lotIDs.sorted(), total = try posted()
        let parts = DecimalDigits.parts(total.decimalString)
        let cents = parts.digits + String(repeating: "0", count: 2 - parts.scale)
        let (quotient, _) = DecimalDigits.divide(cents, by: String(keys.count))
        let part = try Money(DecimalDigits.decimal(quotient, scale: 2, negative: total.amount < 0))
        var remainder = total; var result: [String: Money] = [:]
        for key in keys.dropLast() { result[key] = part; remainder = try remainder.subtracting(part) }
        result[keys.last!] = remainder
        return result
    }
    // Foundation decimal arithmetic can lose a final digit without reporting lossOfPrecision.
    // Compute the exact coefficient first, then enforce the representation/precision policy.
    private func combined(with other: Money, subtract: Bool) throws -> Money {
        let a = DecimalDigits.parts(decimalString), b = DecimalDigits.parts(other.decimalString)
        let scale = max(a.scale, b.scale)
        let lhs = a.digits + String(repeating: "0", count: scale - a.scale)
        let rhs = b.digits + String(repeating: "0", count: scale - b.scale)
        let lhsNegative = amount < 0, rhsNegative = (other.amount < 0) != subtract
        let digits: String, negative: Bool
        if lhsNegative == rhsNegative {
            digits = DecimalDigits.add(lhs, rhs); negative = lhsNegative
        } else if DecimalDigits.compare(lhs, rhs) >= 0 {
            digits = DecimalDigits.subtract(lhs, rhs); negative = lhsNegative
        } else {
            digits = DecimalDigits.subtract(rhs, lhs); negative = rhsNegative
        }
        return try Money(DecimalDigits.decimal(digits, scale: scale, negative: negative))
    }
    private static func canonical(_ text: String) -> String {
        var result = text
        if result.contains(".") {
            while result.last == "0" { result.removeLast() }
            if result.last == "." { result.removeLast() }
        }
        return result == "-0" ? "0" : result
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(decimalString) }
}

/// Unsigned base-10 arithmetic on validated coefficients, for exact arithmetic and quotient/remainder.
private enum DecimalDigits {
    static func trim(_ text: String) -> String {
        let value = text.drop(while: { $0 == "0" }); return value.isEmpty ? "0" : String(value)
    }
    static func parts(_ text: String) -> (digits: String, scale: Int) {
        let unsigned = text.hasPrefix("-") ? String(text.dropFirst()) : text
        let parts = unsigned.split(separator: ".")
        return (trim(parts.joined()), parts.count == 2 ? parts[1].count : 0)
    }
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = trim(lhs), b = trim(rhs)
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }
    static func add(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs.utf8.reversed()), b = Array(rhs.utf8.reversed())
        var carry = 0; var digits: [UInt8] = []
        for i in 0..<max(a.count, b.count) {
            let sum = (i < a.count ? Int(a[i] - 48) : 0) + (i < b.count ? Int(b[i] - 48) : 0) + carry
            digits.append(UInt8(sum % 10 + 48)); carry = sum / 10
        }
        if carry > 0 { digits.append(UInt8(carry + 48)) }
        return trim(String(decoding: digits.reversed(), as: UTF8.self))
    }
    static func subtract(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs.utf8.reversed()), b = Array(rhs.utf8.reversed())
        var borrow = 0; var digits: [UInt8] = []
        for i in a.indices {
            var digit = Int(a[i] - 48) - (i < b.count ? Int(b[i] - 48) : 0) - borrow
            borrow = digit < 0 ? 1 : 0
            if digit < 0 { digit += 10 }
            digits.append(UInt8(digit + 48))
        }
        return trim(String(decoding: digits.reversed(), as: UTF8.self))
    }
    static func multiply(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs.utf8.reversed()).map { Int($0 - 48) }
        let b = Array(rhs.utf8.reversed()).map { Int($0 - 48) }
        var digits = Array(repeating: 0, count: a.count + b.count)
        for i in a.indices { for j in b.indices { digits[i + j] += a[i] * b[j] } }
        for i in 0..<(digits.count - 1) { digits[i + 1] += digits[i] / 10; digits[i] %= 10 }
        return trim(digits.reversed().map(String.init).joined())
    }
    static func divide(_ numerator: String, by denominator: String) -> (String, String) {
        let denominator = trim(denominator)
        var remainder = "0", quotient = ""
        for digit in trim(numerator) {
            remainder = trim(remainder + String(digit)); var q = 0
            while compare(remainder, denominator) >= 0 { remainder = subtract(remainder, denominator); q += 1 }
            quotient += String(q)
        }
        return (trim(quotient), remainder)
    }
    static func roundedQuotient(_ numerator: String, by denominator: String) -> String {
        let (quotient, remainder) = divide(numerator, by: denominator)
        let comparison = compare(add(remainder, remainder), denominator)
        let odd = quotient.last!.wholeNumberValue! % 2 == 1
        return comparison > 0 || (comparison == 0 && odd) ? add(quotient, "1") : quotient
    }
    static func decimal(_ digits: String, scale: Int, negative: Bool) -> String {
        let padded = String(repeating: "0", count: max(0, scale + 1 - digits.count)) + digits
        let index = padded.index(padded.endIndex, offsetBy: -scale)
        return (negative && trim(digits) != "0" ? "-" : "") + padded[..<index] + (scale == 0 ? "" : ".") + padded[index...]
    }
}
