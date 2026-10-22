import Foundation
import MarketAnalytics

/// A bridge owns its original market template and the complete checked source
/// reports, including raw files. It never depends on a mutable source cache.
public struct MacroMarketBridgeInput: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let base: MarketStateInput
    public let sources: [MacroSourceReport]
    public init(id: UUID = UUID(), createdAt: Date, base: MarketStateInput, sources: [MacroSourceReport]) {
        self.id = id; self.createdAt = createdAt; self.base = base; self.sources = sources
    }
}

public struct MacroMarketBridgeReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let input: MacroMarketBridgeInput
    public let bridge: MacroSourceBridgeResult
    public let replacedKeys: [MarketSeriesKey]
    public let market: MarketStateReport
    public var id: UUID { input.id }
    public var createdAt: Date { input.createdAt }
    public var containsSynthetic: Bool { market.containsSynthetic || input.sources.contains(where: \.containsSynthetic) }
    public var researchOnly: Bool { true }
}

public enum MacroMarketBridgeEngine {
    public static let version = "macro-market-bridge.v1"
    public static let maximumSources = 40
    public static let maximumInputBytes = 32 * 1_024 * 1_024

    public static func evaluate(_ input: MacroMarketBridgeInput) throws -> MacroMarketBridgeReport {
        guard input.createdAt.timeIntervalSinceReferenceDate.isFinite,
              input.createdAt >= input.base.createdAt,
              !input.sources.isEmpty, input.sources.count <= maximumSources,
              Set(input.sources.map(\.id)).count == input.sources.count,
              input.sources.allSatisfy({ $0.createdAt <= input.createdAt }),
              try JSONEncoder().encode(input).count <= maximumInputBytes else { throw MacroSourceError.invalidInput }
        // Validate the complete template before replacing anything. This also
        // refuses ambiguous calendars and unsupported existing model versions.
        _ = try MarketStateEngine.calculate(input.base)
        let bridge = try MacroSourceBridge.build(reports: input.sources, asOf: input.base.asOf)
        let declared = Set(input.sources.flatMap { $0.input.descriptor.series.compactMap(\.marketKey) })
        guard !declared.isEmpty, bridge.series.allSatisfy({ declared.contains($0.key) }) else {
            throw MacroSourceError.unsupportedSeries
        }
        // A selected source with no usable publication must remove the old
        // value for its declared key. Keeping a previous template value here
        // would turn missing new evidence into an apparently valid fallback.
        let replaced = declared.sorted { $0.rawValue < $1.rawValue }
        let merged = (input.base.series.filter { !declared.contains($0.key) } + bridge.series)
            .sorted { $0.key.rawValue < $1.key.rawValue }
        let marketInput = MarketStateInput(id: input.id, createdAt: input.createdAt,
            asOf: input.base.asOf, sessionDate: input.base.sessionDate, sessions: input.base.sessions,
            calendarEvidence: input.base.calendarEvidence, series: merged, methodVersion: input.base.methodVersion)
        let result = try MarketStateEngine.calculate(marketInput)
        return .init(schemaVersion: version, input: input, bridge: bridge, replacedKeys: replaced, market: result)
    }

    public static func replay(_ report: MacroMarketBridgeReport) throws -> MacroMarketBridgeReport {
        guard report.schemaVersion == version else { throw MacroSourceError.incompatibleReport }
        let rebuilt = try evaluate(report.input)
        guard rebuilt == report else { throw MacroSourceError.incompatibleReport }
        return rebuilt
    }
}
