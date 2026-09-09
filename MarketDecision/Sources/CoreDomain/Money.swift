import Foundation

public enum MoneyError: Error, Equatable { case invalidDecimal, precisionExceeded, arithmeticFailure, invalidLots }

/// USD accounting decimal. No binary floating-point conversion is permitted.
public struct Money: Equatable, Sendable, Codable {
    public let amount: Decimal
    public init(_ text: String) throws {
        guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else { throw MoneyError.invalidDecimal }
        let digits = text.filter(\.isNumber).drop(while: { $0 == "0" })
        guard digits.count <= 38 else { throw MoneyError.precisionExceeded }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw MoneyError.invalidDecimal }
        self.amount = value
    }
    private init(validated amount: Decimal) { self.amount = amount }
    public var decimalString: String { var value = amount; return NSDecimalString(&value, Locale(identifier: "en_US_POSIX")) }
    public func posted() -> Money {
        var value = amount; var result = Decimal()
        NSDecimalRound(&result, &value, 2, .bankers)
        return Money(validated: result)
    }
    public func adding(_ other: Money) throws -> Money {
        var lhs = amount; var rhs = other.amount; var result = Decimal()
        guard NSDecimalAdd(&result, &lhs, &rhs, .bankers) == .noError else { throw MoneyError.arithmeticFailure }
        return Money(validated: result)
    }
    /// Input is posted once; sorted lot IDs receive truncated cents, last gets exact remainder.
    public func allocatedEqually(to lotIDs: [String]) throws -> [String: Money] {
        guard !lotIDs.isEmpty, Set(lotIDs).count == lotIDs.count, !lotIDs.contains("") else { throw MoneyError.invalidLots }
        let keys = lotIDs.sorted(); var total = posted().amount; var count = Decimal(keys.count); var quotient = Decimal()
        let error = NSDecimalDivide(&quotient, &total, &count, .bankers)
        guard error == .noError || error == .lossOfPrecision else { throw MoneyError.arithmeticFailure }
        var part = Decimal(); NSDecimalRound(&part, &quotient, 2, total < 0 ? .up : .down)
        var remainder = total; var result: [String: Money] = [:]
        for key in keys.dropLast() {
            var next = Decimal(); var value = part
            guard NSDecimalSubtract(&next, &remainder, &value, .bankers) == .noError else { throw MoneyError.arithmeticFailure }
            result[key] = Money(validated: part); remainder = next
        }
        result[keys[keys.count - 1]] = Money(validated: remainder)
        return result
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(decimalString) }
}
