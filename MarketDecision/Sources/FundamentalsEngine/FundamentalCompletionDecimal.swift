import Foundation
import CoreDomain

/// Exact rational integer-root comparison. Only the final root is rounded to the
/// existing 18-place half-even boundary; no Float64 or rounded input ratio is used.
enum FundamentalCompletionDecimal {
    static func compoundGrowth(current: Money, prior: Money, years: Int) throws -> Money {
        guard [3, 5].contains(years), current.amount >= 0, prior.amount > 0 else {
            throw FundamentalError.incompatibleInput
        }
        let a = parts(current.decimalString), b = parts(prior.decimalString)
        // The scaled root satisfies k^years <= (current / prior) * 10^(18*years).
        let numerator = trim(a.digits + String(repeating: "0", count: b.scale + 18 * years))
        let denominator = trim(b.digits + String(repeating: "0", count: a.scale))
        let upperDigits = (max(numerator.count - denominator.count + 1, 1) + years - 1) / years
        var low = "0", high = "1" + String(repeating: "0", count: upperDigits)
        while compare(add(low, "1"), high) < 0 {
            let middle = half(add(low, high))
            if compare(multiply(power(middle, years), denominator), numerator) <= 0 { low = middle }
            else { high = middle }
        }
        // Compare to (low + 1/2)^years exactly. Equality chooses the even coefficient.
        let midpoint = multiply(power(add(multiply(low, "2"), "1"), years), denominator)
        let target = multiply(numerator, power("2", years))
        let ordering = compare(midpoint, target)
        if ordering < 0 || (ordering == 0 && low.last!.wholeNumberValue! % 2 == 1) { low = add(low, "1") }
        let padded = String(repeating: "0", count: max(0, 19 - low.count)) + low
        let boundary = padded.index(padded.endIndex, offsetBy: -18)
        let root = try Money(String(padded[..<boundary]) + "." + String(padded[boundary...]))
        return try root.subtracting(Money("1"))
    }

    private static func parts(_ text: String) -> (digits: String, scale: Int) {
        let values = text.split(separator: ".")
        return (trim(values.joined()), values.count == 2 ? values[1].count : 0)
    }
    private static func trim(_ text: String) -> String {
        let value = text.drop(while: { $0 == "0" }); return value.isEmpty ? "0" : String(value)
    }
    private static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = trim(lhs), b = trim(rhs)
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }
    private static func add(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs.utf8.reversed()), b = Array(rhs.utf8.reversed())
        var carry = 0, result: [UInt8] = []
        for index in 0..<max(a.count, b.count) {
            let sum = (index < a.count ? Int(a[index] - 48) : 0) + (index < b.count ? Int(b[index] - 48) : 0) + carry
            result.append(UInt8(sum % 10 + 48)); carry = sum / 10
        }
        if carry > 0 { result.append(UInt8(carry + 48)) }
        return trim(String(decoding: result.reversed(), as: UTF8.self))
    }
    private static func half(_ text: String) -> String {
        var remainder = 0, result = ""
        for digit in text.utf8 {
            let value = remainder * 10 + Int(digit - 48)
            result += String(value / 2); remainder = value % 2
        }
        return trim(result)
    }
    private static func multiply(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs.utf8.reversed()).map { Int($0 - 48) }, b = Array(rhs.utf8.reversed()).map { Int($0 - 48) }
        var result = Array(repeating: 0, count: a.count + b.count)
        for i in a.indices { for j in b.indices { result[i + j] += a[i] * b[j] } }
        for i in 0..<(result.count - 1) { result[i + 1] += result[i] / 10; result[i] %= 10 }
        return trim(result.reversed().map(String.init).joined())
    }
    private static func power(_ value: String, _ exponent: Int) -> String {
        (0..<exponent).reduce("1") { result, _ in multiply(result, value) }
    }
}
