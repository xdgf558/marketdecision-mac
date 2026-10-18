import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

public enum PortfolioGreeksMode: String, Codable, Sendable { case ledger, synthetic }
public struct PortfolioGreeksBinding: Codable, Equatable, Sendable {
    public let instrumentIdentity: String
    public let reportID: UUID
    /// Nil selects the report's underlying quote for an equity. Options require an exact leg ID.
    public let contractID: String?
    public init(instrumentIdentity: String, reportID: UUID, contractID: String? = nil) {
        self.instrumentIdentity = instrumentIdentity; self.reportID = reportID; self.contractID = contractID
    }
}
public struct PortfolioGreeksInput: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let asOf: Date
    public let mode: PortfolioGreeksMode
    public let accountID: String
    public let ledgerRevision: UUID
    public let accounts: [LedgerAccount]
    /// Exact append-order ledger evidence. Cutoff selects effective events, not a historical knowledge claim.
    public let events: [LedgerEvent]
    public let reports: [OptionLabReport]
    public let bindings: [PortfolioGreeksBinding]
    public init(id: UUID = UUID(), createdAt: Date, asOf: Date, mode: PortfolioGreeksMode,
                accountID: String, ledgerRevision: UUID, accounts: [LedgerAccount], events: [LedgerEvent],
                reports: [OptionLabReport], bindings: [PortfolioGreeksBinding]) {
        self.id = id; self.createdAt = createdAt; self.asOf = asOf; self.mode = mode
        self.accountID = accountID; self.ledgerRevision = ledgerRevision; self.accounts = accounts
        self.events = events; self.reports = reports; self.bindings = bindings
    }
}
public enum PortfolioGreeksGap: String, Codable, Sendable {
    case missingBinding, missingReport, missingContract, missingPricing, missingIV
    case unsupportedContract, mismatchedContract, mismatchedAsOf, staleQuote, inconsistentUnderlying
}
/// All values are weighted by signed ledger units. No strategy quantity/direction is reused.
public struct PortfolioGreeksValues: Codable, Equatable, Sendable {
    public let deltaShares: Double
    public let gammaSharesPerDollar: Double
    public let thetaDollarsPerDay: Double
    public let vegaDollarsPerPercentagePoint: Double
    public let rhoDollarsPerPercentagePoint: Double
    public let deltaDollars: Double
}
public struct PortfolioGreeksRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let instrument: LedgerInstrument
    public let underlyingID: String
    public let underlyingSymbol: String
    public let expirationDate: MarketDate?
    public let signedQuantity: Money
    public let multiplier: Money
    public let reportID: UUID?
    public let contractID: String?
    public let underlyingMid: Money?
    public let values: PortfolioGreeksValues?
    public let gap: PortfolioGreeksGap?
}
public struct PortfolioGreeksCoverage: Codable, Equatable, Sendable {
    public let coveredPositions: Int
    public let totalPositions: Int
    public var missingPositions: Int { totalPositions - coveredPositions }
    public var isComplete: Bool { totalPositions > 0 && totalPositions == coveredPositions }
}
/// This aggregate intentionally has no raw Delta/Gamma: different underlying shocks cannot be added.
/// Net/gross delta dollars use each instrument's underlying spot, gross sums absolute position exposure.
/// Theta assumes one calendar day; vega/rho assume a simultaneous +1 percentage-point change in every
/// covered position's own volatility/rate, not a correlated market forecast or risk limit.
public struct PortfolioGreeksTotals: Codable, Equatable, Sendable {
    public let netDeltaDollars: Double
    public let grossDeltaDollars: Double
    public let thetaDollarsPerDay: Double
    public let vegaDollarsPerPercentagePoint: Double
    public let rhoDollarsPerPercentagePoint: Double
}
public struct PortfolioGreeksGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let underlyingID: String
    public let underlyingSymbol: String
    /// Nil is the equity bucket, never an inferred expiration.
    public let expirationDate: MarketDate?
    public let coverage: PortfolioGreeksCoverage
    public let covered: PortfolioGreeksValues?
    public let complete: PortfolioGreeksValues?
}
public struct PortfolioGreeksReport: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { input.id }
    public let schemaVersion: String
    public let input: PortfolioGreeksInput
    public let model: ModelDefinition
    public let parameters: ParameterSet
    public let ledgerState: LedgerState
    public let rows: [PortfolioGreeksRow]
    public let groups: [PortfolioGreeksGroup]
    public let coverage: PortfolioGreeksCoverage
    public let coveredTotals: PortfolioGreeksTotals?
    public let completeTotals: PortfolioGreeksTotals?
    public let researchOnly: Bool
    public let limitations: [String]
}
public enum PortfolioGreeksError: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, duplicateBinding, duplicateReport, unknownBinding, syntheticEvidence, incompatibleReport, numericFailure
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "组合输入、账户、时间或冻结账本不完整。"
        case .duplicateBinding: "同一持仓不能绑定多份证据。"
        case .duplicateReport: "报告标识重复，不能确定唯一证据。"
        case .unknownBinding: "绑定的持仓不在该账户所选时刻的未平仓记录中。"
        case .syntheticEvidence: "合成证据只能用于独立合成示例，不能用于普通账本。"
        case .incompatibleReport: "冻结报告与原模型及完整输入重算不一致。"
        case .numericFailure: "组合加权出现不可表示数值，未生成汇总。"
        }
    }
}
