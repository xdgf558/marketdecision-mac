import Foundation

/// Stable navigation targets for one explicit preparation/check action. An empty
/// checklist is not pricing, quote-quality, account or provider approval.
public enum OptionDailySection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case underlying, shortLeg, longLeg, timing, capital, costs, chart, pricing, risk, scenario
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .underlying: "标的与策略"
        case .shortLeg: "卖出合约"
        case .longLeg: "买入保护合约"
        case .timing: "报价与到期时间"
        case .capital: "资金与持股"
        case .costs: "费用与滑点"
        case .chart: "损益图采样"
        case .pricing: "模型假设"
        case .risk: "高级风险资料"
        case .scenario: "瞬时情景"
        }
    }
}

public struct OptionDailyIssue: Equatable, Sendable, Identifiable {
    public let id: String
    public let message: String
    public init(id: String, message: String) { self.id = id; self.message = message }
}

public struct OptionDailyIssueGroup: Equatable, Sendable, Identifiable {
    public var id: String { section.rawValue }
    public var title: String { section.title }
    public let section: OptionDailySection
    public let issues: [OptionDailyIssue]
    public init(section: OptionDailySection, issues: [OptionDailyIssue]) {
        self.section = section; self.issues = issues
    }
}

public struct OptionDailyChecklist: Equatable, Sendable {
    public let groups: [OptionDailyIssueGroup]
    public var issueCount: Int { groups.reduce(0) { $0 + $1.issues.count } }
    public var isEmpty: Bool { groups.isEmpty }
    public init(groups: [OptionDailyIssueGroup]) { self.groups = groups }
}

/// The caller supplies the user's explicitly confirmed common-time assumption.
/// No date/source is obtained from the clock, system settings or a provider.
public struct OptionDailyQuoteAssistance: Equatable, Sendable {
    public let quotedAt: Date
    public let settlementAt: Date
    public let quoteReference: String
    public let expiryReference: String
    public let confirmedCommonQuoteTime: Bool
    public init(quotedAt: Date, settlementAt: Date, quoteReference: String, expiryReference: String,
                confirmedCommonQuoteTime: Bool) {
        self.quotedAt = quotedAt; self.settlementAt = settlementAt
        self.quoteReference = quoteReference; self.expiryReference = expiryReference
        self.confirmedCommonQuoteTime = confirmedCommonQuoteTime
    }
}

/// Every convenience is opt-in. The default request only inspects current input,
/// so a complete copied report need not rewrite its timestamps or source claims.
public struct OptionDailyPreparationRequest: Equatable, Sendable {
    public var quoteAssistance: OptionDailyQuoteAssistance?
    public var synchronizeProtectionQuantity: Bool
    public var useEnteredPricesForChart: Bool
    public init(quoteAssistance: OptionDailyQuoteAssistance? = nil,
                synchronizeProtectionQuantity: Bool = false, useEnteredPricesForChart: Bool = false) {
        self.quoteAssistance = quoteAssistance
        self.synchronizeProtectionQuantity = synchronizeProtectionQuantity
        self.useEnteredPricesForChart = useEnteredPricesForChart
    }
}

public extension OptionLabInputDraft {
    /// Applies requested conveniences to a value copy before publishing any of
    /// them. Missing market values remain missing; the builder/engine still make
    /// all authoritative validation and calculation decisions afterwards.
    @discardableResult
    mutating func prepareDaily(_ request: OptionDailyPreparationRequest = .init()) throws -> OptionDailyChecklist {
        var prepared = self
        if let assistance = request.quoteAssistance {
            guard assistance.confirmedCommonQuoteTime else { throw OptionLabDraftError.missingField }
            try prepared.applyManualQuoteAssistance(quotedAt: assistance.quotedAt, settlementAt: assistance.settlementAt,
                quoteReference: assistance.quoteReference, expiryReference: assistance.expiryReference)
        }
        if request.synchronizeProtectionQuantity {
            guard prepared.hasLongLeg else { throw OptionLabDraftError.missingField }
            guard let quantity = Int(prepared.shortLeg.quantity), quantity > 0 else { throw OptionLabDraftError.invalidNumber }
            prepared.longLeg.quantity = prepared.shortLeg.quantity
        }
        if request.useEnteredPricesForChart { try prepared.useChartPricesFromEnteredInputs() }
        let checklist = prepared.dailyInputChecklist()
        self = prepared
        return checklist
    }
}
