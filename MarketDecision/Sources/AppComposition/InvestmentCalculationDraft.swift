import Foundation
import CoreDomain
import PortfolioEngine

public enum InvestmentDraftError: Error, Equatable, Sendable {
    case accountMismatch, syntheticEvidence, invalidCalendar, invalidDay, reusedValuationChanged
    case duplicateIdentity, conflictingSession, missingFlowEvidence
}

/// Preparation status, not a claim that a recorded quote passes the pricing engine.
public struct InvestmentDayRequirement: Equatable, Sendable, Identifiable {
    public var id: String { day }
    public let day: String
    public let valuationAt: Date?
    public let instrumentIDs: [String]
    public let reusedSessionInstrumentIDs: [String]
    public let recordedPriceInstrumentIDs: [String]
    public let missingInstrumentIDs: [String]
    public let reason: String?
}

/// Keeps already replay-checked evidence as typed, immutable values. This type
/// neither loads saved records nor proves their provenance: the workspace may
/// supply `reusing` only after its normal stored-report integrity/replay checks.
/// New rows are additions, never a lossy conversion of the original request.
public struct InvestmentCalculationDraft: Equatable, Sendable {
    public let accountID: String
    public let reusedRequest: PerformanceRequest?
    // Flow completeness is an assertion for this exact selected calendar/range.
    // Keep invalidation in the draft so every editing surface has the same rule.
    public var startDay: String {
        didSet { if startDay != oldValue { externalFlowsComplete = false } }
    }
    public var endDay: String {
        didSet { if endDay != oldValue { externalFlowsComplete = false } }
    }
    public var replacesCalendar = false {
        didSet { if replacesCalendar != oldValue { externalFlowsComplete = false } }
    }
    public var replacementTradingDays = "" {
        didSet { if replacementTradingDays != oldValue { externalFlowsComplete = false } }
    }
    public var replacementCalendarEvidence = PortfolioEvidenceDraft() {
        didSet { if replacementCalendarEvidence != oldValue { externalFlowsComplete = false } }
    }
    /// On a reused day, blank valuationAt keeps the exact original Date. An
    /// existing instrument's session is likewise retained when its session fields
    /// are blank. Supplied conflicting fields are rejected, never ignored.
    public var supplementalDays: [PortfolioDayDraft] = [] {
        didSet {
            if Self.valuationEntries(supplementalDays) != Self.valuationEntries(oldValue) { externalFlowsComplete = false }
        }
    }
    public var externalFlowsComplete = false
    public var usesNewFlowEvidence = false
    public var flowEvidence = PortfolioEvidenceDraft()

    public init(accountID: String, reusing request: PerformanceRequest? = nil) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.map({ $0.accountID == accountID }) ?? true else { throw InvestmentDraftError.accountMismatch }
        self.accountID = accountID; reusedRequest = request
        startDay = request?.calendar.tradingDays.first ?? ""
        endDay = request?.calendar.tradingDays.last ?? ""
        usesNewFlowEvidence = request?.flowCompletenessEvidence == nil
        if let request {
            try Self.checkSources(request)
            try Self.validateCalendar(request.calendar.tradingDays)
            guard Set(request.days.map(\.day)).count == request.days.count else { throw InvestmentDraftError.duplicateIdentity }
        }
    }

    /// Only a declared complete calendar supplies dates. A narrower interval may
    /// crop it; extending it requires a new complete calendar and its own evidence.
    public func selectedCalendar() throws -> PerformanceCalendar {
        let source: PerformanceCalendar
        if replacesCalendar {
            let days = replacementTradingDays.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            source = try .init(tradingDays: days, evidence: replacementCalendarEvidence.build())
        } else if let reusedRequest { source = reusedRequest.calendar }
        else { throw InvestmentDraftError.invalidCalendar }
        try Self.validateCalendar(source.tradingDays)
        guard let first = source.tradingDays.first, let last = source.tradingDays.last else { throw InvestmentDraftError.invalidCalendar }
        let from = startDay.isEmpty ? first : startDay, through = endDay.isEmpty ? last : endDay
        try Self.validateDay(from); try Self.validateDay(through)
        guard from <= through, from >= first, through <= last else { throw InvestmentDraftError.invalidCalendar }
        let selected = source.tradingDays.filter { $0 >= from && $0 <= through }
        guard !selected.isEmpty else { throw InvestmentDraftError.invalidCalendar }
        return .init(tradingDays: selected, evidence: source.evidence)
    }

    /// Active corrections and full roll/multileg membership are validated first.
    /// The per-date replay removes navigation groups only after that validation,
    /// exactly as the existing performance engine does. Closed current positions
    /// therefore remain required when they were open at an earlier valuation.
    public func requirements(accounts: [LedgerAccount], events: [LedgerEvent]) throws -> [InvestmentDayRequirement] {
        let calendar = try selectedCalendar()
        guard accounts.contains(where: { $0.id == accountID }) else { throw InvestmentDraftError.accountMismatch }
        let complete = try LedgerEngine.replay(accounts: accounts, events: events)
        let activeIDs = Set(complete.activeEventIDs)
        let active = events.filter { activeIDs.contains($0.id) && $0.accountID == accountID }
        try validateSupplementalRows()
        return try calendar.tradingDays.map { day in
            let original = reusedRequest?.days.first { $0.day == day }
            let extra = supplementalDays.first { $0.day == day }
            let at: Date
            do { at = try valuation(original: original, extra: extra, day: day) }
            catch {
                return .init(day: day, valuationAt: nil, instrumentIDs: [], reusedSessionInstrumentIDs: [],
                             recordedPriceInstrumentIDs: [], missingInstrumentIDs: [],
                             reason: original == nil && (extra?.valuationAt.isEmpty ?? true)
                                ? "请填写该日估值时刻；不会从今天、报价或自然日推断。"
                                : "估值时刻无效或与复用时刻不同；旧证据未被改写。")
            }
            let cut = active.filter { $0.effectiveAt <= at }.map {
                LedgerEvent(id: $0.id, accountID: $0.accountID, effectiveAt: $0.effectiveAt,
                            providerSequence: $0.providerSequence, source: $0.source, payload: $0.payload, notes: $0.notes)
            }
            let state = try LedgerEngine.replay(accounts: accounts, events: cut)
            let required = Set(state.lots.filter { $0.accountID == accountID && !$0.isClosed }.map { $0.instrument.identity })
            let sessions = Set(original?.sessions.map(\.instrumentID) ?? [])
            let prices = Set(original?.prices.map(\.instrumentID) ?? [])
            // Pending manual rows are not counted as usable evidence. The engine
            // will validate their complete contents when the user previews.
            return .init(day: day, valuationAt: at, instrumentIDs: required.sorted(),
                         reusedSessionInstrumentIDs: sessions.sorted(), recordedPriceInstrumentIDs: prices.sorted(),
                         missingInstrumentIDs: required.subtracting(sessions.intersection(prices)).sorted(), reason: nil)
        }
    }

    /// Inserts empty inputs only for declared dates and actual historical holdings.
    /// No timestamp, price, source assertion or flow-completeness value is guessed.
    public mutating func fillMissingQuotes(accounts: [LedgerAccount], events: [LedgerEvent]) throws {
        let needed = try requirements(accounts: accounts, events: events)
        for row in needed {
            if !supplementalDays.contains(where: { $0.day == row.day }) {
                var day = PortfolioDayDraft(); day.day = row.day
                supplementalDays.append(day)
            }
            guard let index = supplementalDays.firstIndex(where: { $0.day == row.day }) else { continue }
            for instrument in row.missingInstrumentIDs where !supplementalDays[index].quotes.contains(where: { $0.instrumentID == instrument }) {
                var quote = PortfolioQuoteDraft(); quote.instrumentID = instrument
                supplementalDays[index].quotes.append(quote)
            }
        }
    }

    /// Out-of-period supplemental rows remain in the editable draft and are not
    /// consumed; changing the interval back restores them without retyping.
    /// Construction only. The normal storage.prepare -> PerformanceEngine path
    /// still validates all evidence, instruments, times, prices and financial rules.
    public func build(calculatedAt: Date) throws -> PerformanceRequest {
        let calendar = try selectedCalendar()
        try validateSupplementalRows()
        var days: [PerformanceDayInput] = []
        for day in calendar.tradingDays {
            let original = reusedRequest?.days.first { $0.day == day }
            let extra = supplementalDays.first { $0.day == day }
            guard original != nil || extra != nil else { continue }
            let at = try valuation(original: original, extra: extra, day: day)
            var sessions = original?.sessions ?? [], prices = original?.prices ?? []
            for quote in extra?.quotes ?? [] {
                if let session = sessions.first(where: { $0.instrumentID == quote.instrumentID }) {
                    guard quote.opensAt.isEmpty, quote.closesAt.isEmpty, Self.isBlank(quote.sessionEvidence) else {
                        throw InvestmentDraftError.conflictingSession
                    }
                    prices.append(try .init(id: "price/" + quote.id, instrumentID: quote.instrumentID, sessionID: session.id,
                        quoteAt: LedgerCSV.timestamp(quote.quoteAt), bid: Self.money(quote.bid), ask: Self.money(quote.ask),
                        last: Self.money(quote.last), basis: .raw, quality: [], timeliness: .endOfDay, evidence: quote.priceEvidence.build()))
                } else {
                    let (session, price) = try quote.build(); sessions.append(session); prices.append(price)
                }
            }
            guard Set(sessions.map(\.id)).count == sessions.count,
                  Set(sessions.map(\.instrumentID)).count == sessions.count,
                  Set(prices.map(\.id)).count == prices.count else { throw InvestmentDraftError.duplicateIdentity }
            days.append(.init(day: day, valuationAt: at, sessions: sessions, prices: prices))
        }
        let flow: PerformanceEvidence?
        if externalFlowsComplete {
            if usesNewFlowEvidence { flow = try flowEvidence.build() }
            else if let old = reusedRequest?.flowCompletenessEvidence { flow = old }
            else { throw InvestmentDraftError.missingFlowEvidence }
        } else { flow = nil }
        let request = PerformanceRequest(accountID: accountID, calculatedAt: calculatedAt, calendar: calendar, days: days,
            accruals: reusedRequest?.accruals ?? [], rateCurves: reusedRequest?.rateCurves ?? [], benchmark: reusedRequest?.benchmark,
            externalFlowsComplete: externalFlowsComplete, flowCompletenessEvidence: flow,
            roundAllocations: reusedRequest?.roundAllocations ?? [], incomeAllocations: reusedRequest?.incomeAllocations ?? [],
            purposeEvidence: reusedRequest?.purposeEvidence ?? [])
        try Self.checkSources(request)
        // Identity is immutable even when a period crop hides the old item.
        try Self.checkIdentity(original: reusedRequest, candidate: request)
        return request
    }

    /// Empty placeholders and quote-only edits do not change valuation endpoints.
    /// Keep nonempty date/time entries (including invalid drafts) so replacing or
    /// removing an explicit endpoint always requires the user to confirm again.
    private static func valuationEntries(_ rows: [PortfolioDayDraft]) -> [[String]] {
        rows.filter { !$0.valuationAt.isEmpty }
            .map { [$0.day, $0.valuationAt] }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func validateSupplementalRows() throws {
        guard Set(supplementalDays.map(\.day)).count == supplementalDays.count,
              Set(supplementalDays.map(\.id)).count == supplementalDays.count else { throw InvestmentDraftError.duplicateIdentity }
        let quotes = supplementalDays.flatMap(\.quotes)
        guard Set(quotes.map(\.id)).count == quotes.count else { throw InvestmentDraftError.duplicateIdentity }
        for row in supplementalDays { try Self.validateDay(row.day) }
    }

    private func valuation(original: PerformanceDayInput?, extra: PortfolioDayDraft?, day: String) throws -> Date {
        let at: Date
        if let original {
            if let extra, !extra.valuationAt.isEmpty,
               try LedgerCSV.timestamp(extra.valuationAt) != original.valuationAt { throw InvestmentDraftError.reusedValuationChanged }
            at = original.valuationAt
        } else {
            guard let extra else { throw InvestmentDraftError.invalidDay }
            at = try LedgerCSV.timestamp(extra.valuationAt)
        }
        guard at.timeIntervalSinceReferenceDate.isFinite else { throw InvestmentDraftError.invalidDay }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "America/New_York") else { throw InvestmentDraftError.invalidDay }
        calendar.timeZone = zone
        let fields = calendar.dateComponents([.year, .month, .day], from: at)
        guard let year = fields.year, let month = fields.month, let date = fields.day,
              String(format: "%04d-%02d-%02d", year, month, date) == day else { throw InvestmentDraftError.invalidDay }
        return at
    }
    private static func validateDay(_ day: String) throws {
        guard day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              (try? LedgerCSV.timestamp(day + "T00:00:00Z")) != nil else { throw InvestmentDraftError.invalidCalendar }
    }
    private static func validateCalendar(_ days: [String]) throws {
        guard !days.isEmpty, days == days.sorted(), Set(days).count == days.count else { throw InvestmentDraftError.invalidCalendar }
        for day in days { try validateDay(day) }
    }
    private static func money(_ value: String) throws -> Money? { value.isEmpty ? nil : try Money(value) }
    private static func isBlank(_ evidence: PortfolioEvidenceDraft) -> Bool {
        evidence.source.isEmpty && evidence.reference.isEmpty && evidence.availableAt.isEmpty && evidence.text.isEmpty && evidence.kind != .synthetic
    }
    private static func sources(_ request: PerformanceRequest) -> [PerformanceEvidence] {
        var result = [request.calendar.evidence]
        if let flow = request.flowCompletenessEvidence { result.append(flow) }
        for day in request.days { result += day.sessions.map(\.evidence); result += day.prices.map(\.evidence) }
        result += request.accruals.map(\.evidence)
        result += request.rateCurves.map(\.evidence)
        result += request.benchmark?.points.map(\.evidence) ?? []
        result += request.roundAllocations.map(\.evidence)
        result += request.incomeAllocations.map(\.evidence)
        result += request.purposeEvidence.map(\.evidence)
        return result
    }
    private static func checkSources(_ request: PerformanceRequest) throws {
        guard !sources(request).contains(where: { $0.kind == .synthetic }),
              !request.days.flatMap(\.prices).contains(where: { $0.quality.contains(.synthetic) }) else {
            throw InvestmentDraftError.syntheticEvidence
        }
    }
    private static func checkIdentity(original: PerformanceRequest?, candidate: PerformanceRequest) throws {
        var evidence: [String: PerformanceEvidence] = [:]
        var sessions: [String: PerformanceSession] = [:]
        var prices: [String: PerformancePrice] = [:]
        for request in [original, candidate].compactMap({ $0 }) {
            for value in sources(request) {
                if let previous = evidence[value.id], previous != value { throw InvestmentDraftError.duplicateIdentity }
                evidence[value.id] = value
            }
            for value in request.days.flatMap(\.sessions) {
                if let previous = sessions[value.id], previous != value { throw InvestmentDraftError.duplicateIdentity }
                sessions[value.id] = value
            }
            for value in request.days.flatMap(\.prices) {
                if let previous = prices[value.id], previous != value { throw InvestmentDraftError.duplicateIdentity }
                prices[value.id] = value
            }
        }
    }
}
