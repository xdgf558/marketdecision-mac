import Foundation
import CoreDomain
import DataContracts

/// Small bounded JSON reader for source financial numbers. Never routes a number through Double
/// or Decimal decoding (which may round before Money's precision check). Duplicate keys fail.
indirect enum MarketJSON {
    case object([String: MarketJSON]), array([MarketJSON]), string(String), number(String), null, boolean
    var object: [String: MarketJSON]? { if case let .object(value) = self { value } else { nil } }
    var array: [MarketJSON]? { if case let .array(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var isNull: Bool { if case .null = self { true } else { false } }
    func money() throws -> Money {
        guard case let .number(text) = self else { throw ProviderFailure.malformedResponse }
        // JSON exponents are expanded using decimal characters only; hostile exponents are bounded.
        let parts = text.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ProviderFailure.malformedResponse }
        let exponent: Int
        if parts.count == 2 {
            guard let value = Int(parts[1]), (-128...127).contains(value) else { throw ProviderFailure.malformedResponse }
            exponent = value
        } else { exponent = 0 }
        var coefficient = String(parts[0]); let negative = coefficient.hasPrefix("-")
        if negative { coefficient.removeFirst() }
        let decimalParts = coefficient.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = decimalParts.count == 2 ? decimalParts[1].count : 0
        var digits = coefficient.replacingOccurrences(of: ".", with: "")
        let scale = fraction - exponent
        if scale < 0 { digits += String(repeating: "0", count: -scale) }
        if scale > 0 {
            if digits.count <= scale { digits = String(repeating: "0", count: scale + 1 - digits.count) + digits }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        }
        while digits.count > 1, digits.first == "0", digits.dropFirst().first != "." { digits.removeFirst() }
        do { return try Money((negative ? "-" : "") + digits) }
        catch { throw ProviderFailure.malformedResponse }
    }
    func integer() throws -> Int {
        let value = try money().decimalString
        guard let number = Int(value), number >= 0 else { throw ProviderFailure.malformedResponse }
        return number
    }
    static func parse(_ data: Data) throws -> MarketJSON {
        guard !data.isEmpty, data.count <= 4 * 1_024 * 1_024 else { throw ProviderFailure.malformedResponse }
        var parser = Parser(bytes: Array(data)); let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw ProviderFailure.malformedResponse }
        return value
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws {
            whitespace(); guard index < bytes.count, bytes[index] == byte else { throw ProviderFailure.malformedResponse }
            index += 1
        }
        mutating func string() throws -> String {
            let start = index; try take(34)
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                        throw ProviderFailure.malformedResponse
                    }
                    return result
                }
            }
            throw ProviderFailure.malformedResponse
        }
        mutating func value(depth: Int) throws -> MarketJSON {
            whitespace()
            guard depth < 32, index < bytes.count else { throw ProviderFailure.malformedResponse }
            switch bytes[index] {
            case 34: return .string(try string())
            case 123:
                index += 1; whitespace(); var object: [String: MarketJSON] = [:]
                if index < bytes.count, bytes[index] == 125 { index += 1; return .object(object) }
                while true {
                    whitespace(); let key = try string(); try take(58)
                    guard object[key] == nil else { throw ProviderFailure.malformedResponse }
                    object[key] = try value(depth: depth + 1); whitespace()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return .object(object) }
                    try take(44)
                }
            case 91:
                index += 1; whitespace(); var array: [MarketJSON] = []
                if index < bytes.count, bytes[index] == 93 { index += 1; return .array(array) }
                while true {
                    array.append(try value(depth: depth + 1)); whitespace()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return .array(array) }
                    try take(44)
                }
            case 110, 116, 102:
                let literal = bytes[index] == 110 ? "null" : (bytes[index] == 116 ? "true" : "false")
                guard bytes[index...].starts(with: literal.utf8) else { throw ProviderFailure.malformedResponse }
                index += literal.utf8.count; return literal == "null" ? .null : .boolean
            default:
                let start = index
                while index < bytes.count, [45, 43, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index]) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard token.count <= 256,
                      token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil
                else { throw ProviderFailure.malformedResponse }
                return .number(token)
            }
        }
    }
}
