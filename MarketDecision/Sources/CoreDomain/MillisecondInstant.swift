import Foundation

public enum InstantError: Error, Equatable { case invalidFormat, outOfRange }

/// Stable UTC millisecond value. Codable is exactly yyyy-MM-dd'T'HH:mm:ss.SSS'Z'.
/// Date conversion is an explicit nearest-millisecond (ties-to-even) boundary, never a hash input.
public struct MillisecondInstant: Sendable, Equatable, Comparable, Hashable, Codable {
    public let milliseconds: Int64
    public init(milliseconds: Int64) throws {
        guard (-62_135_596_800_000...253_402_300_799_999).contains(milliseconds) else { throw InstantError.outOfRange }
        self.milliseconds = milliseconds
    }
    public init(rounding date: Date) throws {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.toNearestOrEven)
        guard value.isFinite, let milliseconds = Int64(exactly: value) else { throw InstantError.outOfRange }
        try self.init(milliseconds: milliseconds)
    }
    public init(iso8601 text: String) throws {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\z"#, options: .regularExpression) != nil,
              let seconds = Self.formatter().date(from: String(text.prefix(19))),
              let fraction = Int64(text.dropFirst(20).prefix(3)) else { throw InstantError.invalidFormat }
        let whole = Int64(seconds.timeIntervalSince1970)
        try self.init(milliseconds: whole * 1000 + fraction)
        guard iso8601 == text else { throw InstantError.invalidFormat }
    }
    public var iso8601: String {
        var seconds = milliseconds / 1000, fraction = milliseconds % 1000
        if fraction < 0 { seconds -= 1; fraction += 1000 }
        return Self.formatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) + String(format: ".%03dZ", fraction)
    }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.milliseconds < rhs.milliseconds }
    public init(from decoder: any Decoder) throws { try self.init(iso8601: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(iso8601) }
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        // Proleptic Gregorian throughout the supported range, without the 1582 cutover.
        formatter.gregorianStartDate = Date(timeIntervalSince1970: -62_135_596_800)
        formatter.isLenient = false
        return formatter
    }
}
