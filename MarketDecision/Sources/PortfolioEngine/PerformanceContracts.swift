import Foundation
import CoreDomain

public enum PerformanceError: Error, Equatable, Sendable {
    case invalidInput, invalidCalendar, duplicateIdentity, invalidEvidence, invalidAccrual, incompatibleVersion, arithmeticFailure
}
public enum PerformanceEvidenceKind: String, Codable, Sendable { case synthetic, localDocument, userConfirmed }
public struct PerformanceEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let kind: PerformanceEvidenceKind
    public let availableAt: Date
    public let reference: String
    public let rawDocument: Data
    public init(id: String, source: String, kind: PerformanceEvidenceKind, availableAt: Date, reference: String, rawDocument: Data) {
        self.id = id; self.source = source; self.kind = kind; self.availableAt = availableAt; self.reference = reference; self.rawDocument = rawDocument
    }
}
public struct PerformanceCalendar: Codable, Equatable, Sendable {
    public let tradingDays: [String]
    public let evidence: PerformanceEvidence
    public init(tradingDays: [String], evidence: PerformanceEvidence) { self.tradingDays = tradingDays; self.evidence = evidence }
}
public struct PerformanceSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let instrumentID: String
    public let opensAt: Date
    public let closesAt: Date
    public let evidence: PerformanceEvidence
    public init(id: String, instrumentID: String, opensAt: Date, closesAt: Date, evidence: PerformanceEvidence) {
        self.id = id; self.instrumentID = instrumentID; self.opensAt = opensAt; self.closesAt = closesAt; self.evidence = evidence
    }
}
public enum PerformancePriceBasis: String, Codable, Sendable { case raw, splitAdjusted, totalReturn }
public enum PerformancePriceQuality: String, Codable, Sendable { case indicative, invalid, stale, synthetic, missing }
public enum PerformancePriceTimeliness: String, Codable, Sendable { case endOfDay, realtime, delayed, unknown }
public struct PerformancePrice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let instrumentID: String
    public let sessionID: String
    public let quoteAt: Date
    public let bid: Money?
    public let ask: Money?
    public let last: Money?
    public let basis: PerformancePriceBasis
    public let quality: [PerformancePriceQuality]
    public let timeliness: PerformancePriceTimeliness
    public let evidence: PerformanceEvidence
    public init(id: String, instrumentID: String, sessionID: String, quoteAt: Date, bid: Money? = nil, ask: Money? = nil, last: Money? = nil, basis: PerformancePriceBasis = .raw, quality: [PerformancePriceQuality] = [], timeliness: PerformancePriceTimeliness = .endOfDay, evidence: PerformanceEvidence) {
        self.id = id; self.instrumentID = instrumentID; self.sessionID = sessionID; self.quoteAt = quoteAt
        self.bid = bid; self.ask = ask; self.last = last; self.basis = basis; self.quality = quality; self.timeliness = timeliness; self.evidence = evidence
    }
}
public struct PerformanceDayInput: Codable, Equatable, Sendable {
    public let day: String
    public let valuationAt: Date
    public let sessions: [PerformanceSession]
    public let prices: [PerformancePrice]
    public init(day: String, valuationAt: Date, sessions: [PerformanceSession], prices: [PerformancePrice]) {
        self.day = day; self.valuationAt = valuationAt; self.sessions = sessions; self.prices = prices
    }
}
public enum PerformanceAccrualKind: String, Codable, Sendable { case dividendReceivable, interestReceivable, feePayable, otherReceivable, otherPayable }
public struct PerformanceAccrualSettlement: Codable, Equatable, Sendable {
    public let ledgerEventID: String
    public let amount: Money
    public init(ledgerEventID: String, amount: Money) { self.ledgerEventID = ledgerEventID; self.amount = amount }
}
public struct PerformanceAccrual: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: PerformanceAccrualKind
    public let recognizedAt: Date
    public let amount: Money
    public let settlements: [PerformanceAccrualSettlement]
    public let evidence: PerformanceEvidence
    public init(id: String, kind: PerformanceAccrualKind, recognizedAt: Date, amount: Money, settlements: [PerformanceAccrualSettlement], evidence: PerformanceEvidence) {
        self.id = id; self.kind = kind; self.recognizedAt = recognizedAt; self.amount = amount; self.settlements = settlements; self.evidence = evidence
    }
}
public enum PerformanceRateUnit: String, Codable, Sendable { case annualPercent, annualDecimal }
public struct PerformanceRatePoint: Codable, Equatable, Sendable {
    public let termYears: Double
    public let annualRate: Money
    public let unit: PerformanceRateUnit
    public init(termYears: Double, annualRate: Money, unit: PerformanceRateUnit) { self.termYears = termYears; self.annualRate = annualRate; self.unit = unit }
}
public enum PerformanceRateSource: String, Codable, Sendable { case fredDGS3MO, fredTreasuryCurve, explicitUserConstant }
public struct PerformanceRateCurve: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: PerformanceRateSource
    public let observationAt: Date
    public let validFrom: Date
    public let validThrough: Date
    public let points: [PerformanceRatePoint]
    public let evidence: PerformanceEvidence
    public let sourceInput: Data?
    public let sourceVersion: String?
    public init(id: String, source: PerformanceRateSource, observationAt: Date, validFrom: Date, validThrough: Date, points: [PerformanceRatePoint], evidence: PerformanceEvidence, sourceInput: Data? = nil, sourceVersion: String? = nil) {
        self.id = id; self.source = source; self.observationAt = observationAt; self.validFrom = validFrom; self.validThrough = validThrough
        self.points = points; self.evidence = evidence
        self.sourceInput = sourceInput; self.sourceVersion = sourceVersion
    }
}
public struct PerformanceBenchmarkPoint: Codable, Equatable, Sendable {
    public let day: String
    public let totalReturnIndex: Money
    public let evidence: PerformanceEvidence
    public init(day: String, totalReturnIndex: Money, evidence: PerformanceEvidence) {
        self.day = day; self.totalReturnIndex = totalReturnIndex; self.evidence = evidence
    }
}
public struct PerformanceBenchmark: Codable, Equatable, Sendable {
    public let symbol: String
    public let points: [PerformanceBenchmarkPoint]
    public let isTotalReturn: Bool
    public let sourceInput: Data?
    public let sourceVersion: String?
    public init(symbol: String = "SPY", points: [PerformanceBenchmarkPoint], isTotalReturn: Bool, sourceInput: Data? = nil, sourceVersion: String? = nil) {
        self.symbol = symbol; self.points = points; self.isTotalReturn = isTotalReturn
        self.sourceInput = sourceInput; self.sourceVersion = sourceVersion
    }
}
public struct PerformanceRoundAllocation: Codable, Equatable, Sendable {
    public let lotID: String
    public let roundLotID: String
    public let fraction: Money
    public let evidence: PerformanceEvidence
    public init(lotID: String, roundLotID: String, fraction: Money, evidence: PerformanceEvidence) {
        self.lotID = lotID; self.roundLotID = roundLotID; self.fraction = fraction; self.evidence = evidence
    }
}
public struct PerformanceIncomeAllocation: Codable, Equatable, Sendable {
    public let ledgerEventID: String
    public let roundLotID: String
    public let amount: Money
    public let evidence: PerformanceEvidence
    public init(ledgerEventID: String, roundLotID: String, amount: Money, evidence: PerformanceEvidence) {
        self.ledgerEventID = ledgerEventID; self.roundLotID = roundLotID; self.amount = amount; self.evidence = evidence
    }
}
public enum PerformancePurposeState: String, Codable, Sendable { case success, failure, unassigned, pending, unverified }
public struct PerformancePurposeEvidence: Codable, Equatable, Sendable {
    public let roundLotID: String
    public let outcome: PerformancePurposeState
    public let evidence: PerformanceEvidence
    public init(roundLotID: String, outcome: PerformancePurposeState, evidence: PerformanceEvidence) {
        self.roundLotID = roundLotID; self.outcome = outcome; self.evidence = evidence
    }
}
public struct PerformanceRequest: Codable, Equatable, Sendable {
    public let accountID: String
    public let calculatedAt: Date
    public let calendar: PerformanceCalendar
    public let days: [PerformanceDayInput]
    public let accruals: [PerformanceAccrual]
    public let rateCurves: [PerformanceRateCurve]
    public let benchmark: PerformanceBenchmark?
    /// An explicit assertion about external flows over the requested endpoints, with its evidence.
    public let externalFlowsComplete: Bool
    public let flowCompletenessEvidence: PerformanceEvidence?
    public let roundAllocations: [PerformanceRoundAllocation]
    public let incomeAllocations: [PerformanceIncomeAllocation]
    public let purposeEvidence: [PerformancePurposeEvidence]
    public init(accountID: String, calculatedAt: Date, calendar: PerformanceCalendar, days: [PerformanceDayInput],
                accruals: [PerformanceAccrual] = [], rateCurves: [PerformanceRateCurve] = [], benchmark: PerformanceBenchmark? = nil,
                externalFlowsComplete: Bool = false, flowCompletenessEvidence: PerformanceEvidence? = nil,
                roundAllocations: [PerformanceRoundAllocation] = [], incomeAllocations: [PerformanceIncomeAllocation] = [], purposeEvidence: [PerformancePurposeEvidence] = []) {
        self.accountID = accountID; self.calculatedAt = calculatedAt; self.calendar = calendar; self.days = days
        self.accruals = accruals; self.rateCurves = rateCurves; self.benchmark = benchmark
        self.externalFlowsComplete = externalFlowsComplete; self.flowCompletenessEvidence = flowCompletenessEvidence
        self.roundAllocations = roundAllocations; self.incomeAllocations = incomeAllocations; self.purposeEvidence = purposeEvidence
    }
}
public struct PerformanceInput: Codable, Equatable, Sendable {
    public let request: PerformanceRequest
    public let ledgerRevision: UUID
    public let accounts: [LedgerAccount]
    public let events: [LedgerEvent]
    public init(request: PerformanceRequest, ledgerRevision: UUID, accounts: [LedgerAccount], events: [LedgerEvent]) {
        self.request = request; self.ledgerRevision = ledgerRevision; self.accounts = accounts; self.events = events
    }
}
public enum PerformanceStatus: String, Codable, Sendable {
    case available, missingInput, insufficientSample, shortSample, zeroDenominator, negativeNAV, segmented, unresolved, multipleRoots, notApplicable, outsideRange, invalidInput
}
public struct PerformanceNumber: Codable, Equatable, Sendable {
    public let value: Double?
    public let status: PerformanceStatus
    public let reason: String
    public let sampleCount: Int
    public let evidenceIDs: [String]
    public init(value: Double?, status: PerformanceStatus, reason: String = "", sampleCount: Int = 0, evidenceIDs: [String] = []) {
        self.value = value; self.status = status; self.reason = reason; self.sampleCount = sampleCount; self.evidenceIDs = evidenceIDs
    }
}
public enum PerformancePriceKind: String, Codable, Sendable { case mid, lastStale, missing }
public struct PerformancePosition: Codable, Equatable, Sendable, Identifiable {
    public var id: String { lotID }
    public let lotID: String
    public let instrumentID: String
    public let side: LedgerPositionSide
    public let quantity: Money
    public let managementCost: Money
    public let marketValue: Money?
    public let unrealizedPnL: Money?
    public let price: Money?
    public let priceKind: PerformancePriceKind
    public let sessionClose: Date?
    public let quoteAt: Date?
    public let sourceIDs: [String]
    public let reason: String
}
public struct PerformanceDailyValue: Codable, Equatable, Sendable {
    public let day: String
    public let valuationAt: Date?
    public let cash: Money?
    public let positions: [PerformancePosition]
    public let receivables: Money?
    public let payables: Money?
    public let nav: Money?
    public let externalFlow: Money
    public let status: PerformanceStatus
    public let reason: String
}
public struct PerformanceDailyReturn: Codable, Equatable, Sendable {
    public let day: String
    public let startDay: String
    public let value: Double
    public let index: Double
}
public struct PerformanceSegment: Codable, Equatable, Sendable {
    public let startDay: String
    public let endDay: String
    public let returns: [PerformanceDailyReturn]
    public let cumulativeReturn: Double
}
public struct PerformanceXIRR: Codable, Equatable, Sendable {
    public let value: Double?
    public let roots: [Double]
    public let status: PerformanceStatus
    public let residuals: [Double]
    public let searchLower: Double
    public let searchUpper: Double
    public let reason: String
}
public struct PerformanceDrawdown: Codable, Equatable, Sendable {
    public let value: Double
    public let peakDay: String
    public let troughDay: String
    public let recoveredDay: String?
}
public struct PerformanceRisk: Codable, Equatable, Sendable {
    public let annualizedVolatility: PerformanceNumber
    public let annualizedTWR: PerformanceNumber
    public let annualizedRiskFree: PerformanceNumber
    public let sharpe: PerformanceNumber
    public let sortino: PerformanceNumber
    public let beta: PerformanceNumber
    public let calmar: PerformanceNumber
    public let drawdown: PerformanceDrawdown?
    public let navDrawdown: PerformanceDrawdown?
}
public struct PerformanceRollingReturn: Codable, Equatable, Sendable {
    public let calendarDays: Int
    public let anchorDay: String?
    public let endDay: String
    public let result: PerformanceNumber
}
public struct PerformanceMonthlyReturn: Codable, Equatable, Sendable {
    public let month: String
    public let result: PerformanceNumber
    public let endDay: String
}
public struct PerformanceAttribution: Codable, Equatable, Sendable {
    public let startDay: String
    public let endDay: String
    public let realizedPnL: Money
    public let changeInUnrealizedPnL: Money?
    public let dividends: Money
    public let interest: Money
    public let unallocatedFees: Money
    public let taxes: Money
    public let changeInAccruals: Money?
    public let transferEmbeddedGain: Money
    public let navChangeLessExternalFlows: Money?
    public let explainedPnL: Money?
    public let reconciliationDifference: Money?
}
public enum PerformanceEconomicState: String, Codable, Sendable { case open, closed, transferredUnresolved, allocationRequired }
public struct PerformanceRound: Codable, Equatable, Sendable, Identifiable {
    public var id: String { roundLotID }
    public let roundLotID: String
    public let strategy: LedgerStrategy?
    public let familyID: String?
    public let economicState: PerformanceEconomicState
    public let accountingState: PerformanceStatus
    public let purposeState: PerformancePurposeState
    public let netPnL: Money?
    public let relatedLotIDs: [String]
    public let closedAt: Date?
    public let reason: String
}
public struct PerformanceInterval: Codable, Equatable, Sendable {
    public let low: Double?
    public let high: Double?
    public let status: PerformanceStatus
    public let sampleCount: Int
    public let reason: String
}
public struct PerformanceTradeStatistics: Codable, Equatable, Sendable {
    public let displayN: Int
    public let eligibleN: Int
    public let wins: Int
    public let losses: Int
    public let zeros: Int
    public let successes: Int
    public let failures: Int
    public let unassigned: Int
    public let winRate: PerformanceNumber
    public let lossRate: PerformanceNumber
    public let purposeSuccessRate: PerformanceNumber
    public let winRateInterval: PerformanceInterval
    public let purposeSuccessInterval: PerformanceInterval
    public let averageWin: PerformanceNumber
    public let averageLoss: PerformanceNumber
    public let expectancy: PerformanceNumber
    public let profitFactor: PerformanceNumber
    public let profitFactorInfinite: Bool
    public let maximumConsecutiveLosses: Int
}
public struct PerformanceReport: Codable, Equatable, Sendable {
    public let engineVersion: String
    public let parametersVersion: String
    public let numericPolicyVersion: String
    public let input: PerformanceInput
    public let daily: [PerformanceDailyValue]
    public let segments: [PerformanceSegment]
    public let twr: PerformanceNumber
    public let xirr: PerformanceXIRR
    public let cagr: PerformanceNumber
    public let risk: PerformanceRisk
    public let rolling: [PerformanceRollingReturn]
    public let monthly: [PerformanceMonthlyReturn]
    public let attribution: PerformanceAttribution?
    public let rounds: [PerformanceRound]
    public let tradeStatistics: PerformanceTradeStatistics
    public let groupedStatistics: [PerformanceGroupedStatistics]
    public let researchOnly: Bool
    public let limitations: [String]
}
