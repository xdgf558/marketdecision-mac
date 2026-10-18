import Foundation
import CoreDomain
import DataContracts

public enum OptionVolatilityHistoryState: String, Codable, Sendable {
    case available, insufficientSessions, missingDay, unavailableDailyIV, excessiveSpan, currentIVUnavailable, constantHistory
}
public struct OptionVolatilityHistoryInput: Codable, Equatable, Sendable {
    public static let currentMethodVersion = "options.iv-history.v1"
    public let id: UUID
    public let createdAt: Date
    public let current: OptionDailyReport
    public let history: [OptionDailyReport]
    public let calendar: OptionDailyCalendar
    public let methodVersion: String
    public init(id: UUID = UUID(), createdAt: Date, current: OptionDailyReport, history: [OptionDailyReport],
                calendar: OptionDailyCalendar, methodVersion: String = currentMethodVersion) {
        self.id = id; self.createdAt = createdAt; self.current = current; self.history = history
        self.calendar = calendar; self.methodVersion = methodVersion
    }
}
public struct OptionVolatilityHistoryPoint: Codable, Equatable, Sendable {
    public let session: MarketDate
    public let dailyInputID: UUID?
    public let iv30: Double?
}
public struct OptionVolatilityHistoryReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let input: OptionVolatilityHistoryInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    /// Percent units, intentionally not clamped if current IV is outside prior range.
    public let ivRank: Double?
    /// Percent units: strictly-less count / 252 * 100. Ties never count as lower.
    public let ivPercentile: Double?
    public let state: OptionVolatilityHistoryState
    public let currentIV30: Double?
    public let historicalMinimum: Double?
    public let historicalMaximum: Double?
    public let validDays: Int
    public let requiredDays: Int
    public let window: [OptionVolatilityHistoryPoint]
    public let containsSynthetic: Bool
    public let researchOnly: Bool
    public let limitations: [String]
    public var modelReference: RegistryReference { model.reference }
    public var parameterReference: RegistryReference { parameters.reference }
}
public enum OptionVolatilityHistoryEngine {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let p = ParameterSet(id: "options.iv-history.parameters", version: "PARAMETERS_V1.iv-history.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000003")!,
            values: ["priorTradingSessions": .integer(252), "maximumCalendarSpanDays": .integer(400),
                "percentile": .text("100*count(historyIV<currentIV)/252"), "rank": .text("100*(currentIV30-min)/(max-min); no clamping; constant history rank nil"),
                "window": .text("immediately preceding declared sessions, excludes current; no skipping invalid days or proxy IV")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-026,031;DC-017")
        let m = ModelDefinition(id: "options.iv-history", version: OptionVolatilityHistoryInput.currentMethodVersion,
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000004")!, owner: "OptionsAnalytics",
            purpose: "Offline IV30 relative position over 252 complete declared prior sessions",
            inputs: [.init(name: "frozenDailyReportsAndDeclaredSessionCalendar", unit: "ratio+date", role: .required)],
            outputs: [.init(name: "IVRankAndStrictPercentile", unit: "percent")],
            formula: "IVRank=100*(currentIV30-min)/(max-min); Percentile=100*strictLess/252; previous252 declared sessions; span<=400 days",
            formulaVersion: OptionVolatilityHistoryInput.currentMethodVersion, implementationReference: "OptionsAnalytics/OptionVolatilityHistoryEngine.v1",
            defaultParameters: p.reference, numericPolicyVersion: OptionBSM.numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1", knownLimitations: limitations, testFixtures: ["OptionVolatilityHistoryTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-18T00:00:00.000Z"))
        try p.validate(); try m.validate(); return (p,m)
    }
    public static func calculate(_ input: OptionVolatilityHistoryInput) throws -> OptionVolatilityHistoryReport {
        try Task.checkCancellation()
        guard input.methodVersion == OptionVolatilityHistoryInput.currentMethodVersion,
              input.createdAt.timeIntervalSince1970.isFinite, input.history.count <= 10_000,
              input.createdAt >= input.current.input.createdAt else { throw OptionDailyError.invalidInput }
        try OptionDailyEngine.validateCalendar(input.calendar, createdAt: input.createdAt)
        _ = try OptionDailyEngine.replay(input.current)
        let today = input.current.input.session
        guard let currentIndex = input.calendar.sessions.firstIndex(of: today) else { throw OptionDailyError.invalidCalendar }
        guard input.calendar.source.origin == input.current.input.source.origin else { throw OptionDailyError.mismatchedSource }
        var days: [MarketDate: OptionDailyReport] = [:], ids = Set<UUID>()
        for report in input.history {
            try Task.checkCancellation()
            guard report.input.session < today, report.input.asOf < input.current.input.asOf,
                  report.input.createdAt <= input.createdAt else { throw OptionDailyError.invalidTime }
            guard report.input.symbol == input.current.input.symbol, report.input.feedID == input.current.input.feedID,
                  report.input.sessionTimeZoneID == input.current.input.sessionTimeZoneID,
                  report.input.declaredScope == input.current.input.declaredScope,
                  report.input.source.origin == input.current.input.source.origin,
                  report.containsSynthetic == input.current.containsSynthetic,
                  report.modelReference == input.current.modelReference,
                  input.calendar.sessions.contains(report.input.session) else { throw OptionDailyError.mismatchedSource }
            guard days.updateValue(report, forKey: report.input.session) == nil, ids.insert(report.input.id).inserted,
                  report.input.id != input.current.input.id else { throw OptionDailyError.duplicateContract }
            _ = try OptionDailyEngine.replay(report)
        }
        let sessions = Array(input.calendar.sessions[..<currentIndex].suffix(252))
        let window = sessions.map { day in
            let report = days[day]
            return OptionVolatilityHistoryPoint(session: day, dailyInputID: report?.input.id,
                iv30: report?.state == .available ? report?.iv30 : nil)
        }
        let values = window.compactMap(\.iv30)
        var state: OptionVolatilityHistoryState = .available
        var rank: Double?, percentile: Double?, minimum: Double?, maximum: Double?
        let current = input.current.state == .available ? input.current.iv30 : nil
        if current == nil { state = .currentIVUnavailable }
        else if sessions.count < 252 { state = .insufficientSessions }
        else if let first = sessions.first, try calendarSpan(first, today) > 400 { state = .excessiveSpan }
        else if window.contains(where: { $0.dailyInputID == nil }) { state = .missingDay }
        else if values.count != 252 { state = .unavailableDailyIV }
        else if let current, let low = values.min(), let high = values.max() {
            minimum = low; maximum = high
            percentile = 100 * Double(values.filter { $0 < current }.count) / 252
            if high == low { state = .constantHistory }
            else { rank = 100 * (current - low) / (high - low) }
            if let rank, !rank.isFinite { throw OptionDailyError.invalidInput }
        }
        let (parameters, model) = try definitions()
        return .init(schemaVersion: "option-iv-history-report.v1", input: input, model: model, parameters: parameters,
            ivRank: rank, ivPercentile: percentile, state: state, currentIV30: current, historicalMinimum: minimum,
            historicalMaximum: maximum, validDays: values.count, requiredDays: 252, window: window,
            containsSynthetic: input.calendar.source.origin == .synthetic || input.current.containsSynthetic || input.history.contains(where: \.containsSynthetic),
            researchOnly: true, limitations: limitations)
    }
    public static func replay(_ report: OptionVolatilityHistoryReport) throws -> OptionVolatilityHistoryReport {
        let result = try calculate(report.input)
        guard result == report else { throw OptionDailyError.incompatibleReport }; return result
    }
    private static func calendarSpan(_ first: MarketDate, _ last: MarketDate) throws -> Int {
        let zone = TimeZone(secondsFromGMT: 0)!
        return Int(try last.start(in: zone).timeIntervalSince(first.start(in: zone)) / 86_400)
    }
    public static let limitations = [
        "前252个明确声明的会话，不含当前；全部须有有效IV30，最早日距当前不超过400日历日。缺日不以更早日补足。",
        "IVR不夹截到0–100；历史极差为0时IVR缺失，但严格小于分位可独立计算。",
        "手工日历与合成工作日仅为离线假设，不是官方交易日历或真实历史可得性证据。",
        "所存完整日报输入用于重算；存在摘要或得到分位不授予历史回测、真实世界概率或供应商资格。"
    ]
}
