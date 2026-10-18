import Foundation
import OptionsAnalytics

/// Closed offline document family. Each case owns its original inputs and model
/// definitions; old pricing, daily and performance documents are never upgraded.
public enum OptionEvidenceKind: String, Codable, CaseIterable, Sendable {
    case providerComparison, delta25, tradeAttribution
    public var title: String {
        switch self {
        case .providerComparison: "IV / Greeks 对照"
        case .delta25: "25-Delta 波动率"
        case .tradeAttribution: "交易时点归因"
        }
    }
}
public enum OptionEvidenceInput: Codable, Equatable, Sendable {
    case providerComparison(OptionProviderComparisonInput)
    case delta25(OptionDelta25Input)
    case tradeAttribution(TradeOptionAttributionInput)
    public var id: UUID {
        switch self { case .providerComparison(let x): x.id; case .delta25(let x): x.id; case .tradeAttribution(let x): x.id }
    }
    public var createdAt: Date {
        switch self { case .providerComparison(let x): x.createdAt; case .delta25(let x): x.createdAt; case .tradeAttribution(let x): x.createdAt }
    }
    public var kind: OptionEvidenceKind {
        switch self { case .providerComparison: .providerComparison; case .delta25: .delta25; case .tradeAttribution: .tradeAttribution }
    }
}
public enum OptionEvidenceReport: Codable, Equatable, Sendable {
    case providerComparison(OptionProviderComparisonReport)
    case delta25(OptionDelta25Report)
    case tradeAttribution(TradeOptionAttributionReport)
    public var input: OptionEvidenceInput {
        switch self { case .providerComparison(let x): .providerComparison(x.input); case .delta25(let x): .delta25(x.input); case .tradeAttribution(let x): .tradeAttribution(x.input) }
    }
    public var id: UUID { input.id }
    public var containsSynthetic: Bool {
        switch self { case .providerComparison(let x): x.containsSynthetic; case .delta25(let x): x.containsSynthetic; case .tradeAttribution(let x): x.containsSynthetic }
    }
}
public enum OptionEvidenceEngine {
    public static func calculate(_ input: OptionEvidenceInput) throws -> OptionEvidenceReport {
        try Task.checkCancellation()
        switch input {
        case .providerComparison(let x): return .providerComparison(try OptionProviderComparisonEngine.calculate(x))
        case .delta25(let x): return .delta25(try OptionDelta25Engine.calculate(x))
        case .tradeAttribution(let x): return .tradeAttribution(try TradeOptionAttributionEngine.calculate(x))
        }
    }
    public static func replay(_ report: OptionEvidenceReport) throws -> OptionEvidenceReport {
        try Task.checkCancellation()
        switch report {
        case .providerComparison(let x): return .providerComparison(try OptionProviderComparisonEngine.replay(x))
        case .delta25(let x): return .delta25(try OptionDelta25Engine.replay(x))
        case .tradeAttribution(let x): return .tradeAttribution(try TradeOptionAttributionEngine.replay(x))
        }
    }
}
