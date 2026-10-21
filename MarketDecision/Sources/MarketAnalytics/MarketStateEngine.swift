import Foundation
import CoreDomain

/// MARKET_PARAMETERS_V1 is an offline descriptive model. Declared observations
/// are evidence, not licensed feeds, trading advice or a prediction probability.
public enum MarketStateEngine {
    public static let numericPolicy = "market-float64-pit-strictLess.v1"
    public static let limitations = [
        "Offline synthetic/manual inputs only; no supplier admission, real-time status or investment advice.",
        "Scores describe inputs. Coverage is not a statistical confidence interval or a success probability.",
        "Heat trend/risk appetite overlap stress drawdown/credit; internal structure reuses breadth and fixed ETF proxies. Actual |rho| > 0.7 is reported in diagnostics.",
        "Historical atoms are reconstructed at each declared session close using only then-available vintages. Repeated observation IDs never create independent percentile samples.",
        "The supplied exchange calendar and source methodology are declared evidence, not verified production PIT; manual and synthetic snapshots cannot establish real-world history. Snapshot asOf must belong to its New York session date; daily freshness requires a source date in the supplied calendar.",
        "Float64 log, square root and correlation are not a cross-CPU/libm bitwise replay guarantee. Input budgets are not process memory limits."
    ]
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "market.state.parameters", version: "MARKET_PARAMETERS_V1",
            revisionID: UUID(uuidString: "40000000-2026-4019-8000-000000000001")!,
            values: ["heatWeightsBps": .text("3000,2500,1500,1500,1500"),
                "stressWeightsBps": .text("3000,2000,1500,1500,2000"),
                "sentimentWeightsBps": .text("3000,2000,1500,1500,2000"),
                "minimumCoverageBps": .integer(7000), "minimumIndependentHistory": .integer(252),
                "calendarYears": .integer(5), "lowThreshold": .integer(35), "highThreshold": .integer(65),
                "confirmationSessions": .integer(2), "correlationWarning": .decimal(try Money("0.7")),
                "percentile": .text("strictLess/N; exclude current; independent observations; no forward-fill sample inflation"),
                "dailyMaxAgeSessions": .integer(3), "weeklyMaxAgeCalendarDays": .integer(10),
                "formulaVersion": .text("MARKET_DRAFT_1:15-components;CALC-030/031/032")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-030,CALC-031,CALC-032")
        let model = ModelDefinition(id: "market.state", version: MarketStateInput.currentMethodVersion,
            revisionID: UUID(uuidString: "40000000-2026-4019-8000-000000000002")!, owner: "MarketAnalytics",
            purpose: "Offline market heat, stress, sentiment and confirmed descriptive regimes",
            inputs: [.init(name: "frozenVintageSeriesAndCalendar", unit: "ratio+price+volume+UTC", role: .required)],
            outputs: [.init(name: "marketState", unit: "score0to100+label")],
            formula: "MARKET_DRAFT_1 fifteen fixed components; equal atoms; both levels >=70%; P=strictLess/N over 5 calendar years, >=252 independent samples; MRL_v1 35/65, two-session confirmation",
            formulaVersion: MarketStateInput.currentMethodVersion, implementationReference: "MarketAnalytics/MarketStateEngine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: numericPolicy,
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-030,CALC-031,CALC-032",
            knownLimitations: limitations, testFixtures: ["MarketStateEngineTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-19T00:00:00.000Z"))
        try parameters.validate(); try model.validate(); return (parameters, model)
    }

    public static func calculate(_ input: MarketStateInput) throws -> MarketStateReport {
        try validate(input)
        let reader = Reader(input)
        let specs = components
        let atoms = specs.flatMap(\.atoms)
        var rawHistory: [String: [(date: String, value: Raw)]] = [:]
        var days: [MarketStateDay] = []
        let floorDate = fiveYearsBefore(input.sessionDate)
        var previous: MarketStateDay?
        for (index, session) in input.sessions.enumerated() {
            try Task.checkCancellation()
            let cutoff = index == input.sessions.count - 1 ? input.asOf : session.closeAt
            let closed = cutoff >= session.closeAt
            var resolved: [String: MarketAtomResult] = [:]
            var rawToday: [String: Raw] = [:]
            for atom in atoms {
                let raw = reader.evaluate(atom.formula, index: index, cutoff: cutoff)
                rawToday[atom.id] = raw
                var historyCount = 0
                var score: Double?
                var missing = raw.reason
                if let value = raw.value {
                    if atom.percentile {
                        let earliest = fiveYearsBefore(session.date)
                        var seen = Set<String>()
                        let past = (rawHistory[atom.id] ?? []).filter { item in
                            item.date >= earliest && item.date < session.date && item.value.identity != raw.identity
                                && seen.insert(item.value.identity).inserted
                        }.compactMap { $0.value.value }
                        historyCount = past.count
                        if past.count >= 252 { score = Double(past.filter { $0 < value }.count) / Double(past.count) * 100 }
                        else { missing = .insufficientHistory }
                    } else { score = value * 100 }
                    if let existing = score { score = atom.reverse ? 100 - existing : existing }
                }
                if let value = score, !value.isFinite || value < 0 || value > 100 { score = nil; missing = .nonFinite }
                resolved[atom.id] = .init(id: atom.id, rawValue: raw.value, score: score,
                    independentHistoryCount: historyCount, observationReferences: raw.references.sorted(), consumedWindows: raw.windows, missingReason: score == nil ? missing : nil)
            }
            for atom in atoms {
                if let raw = rawToday[atom.id], raw.value != nil, closed {
                    // Each historical formula was independently evaluated at its historical cutoff.
                    rawHistory[atom.id, default: []].append((session.date, raw))
                }
            }
            let heat = aggregate(.heat, specs: specs, results: resolved)
            let stress = aggregate(.stress, specs: specs, results: resolved)
            let sentiment = aggregate(.sentiment, specs: specs, results: resolved)
            let rawLabel = classify(heat: heat.value, stress: stress.value)
            let confirmation = confirm(raw: rawLabel, previous: previous, closed: closed)
            let day = MarketStateDay(sessionDate: session.date, asOf: cutoff, heat: heat, stress: stress,
                sentiment: sentiment, rawLabel: rawLabel, confirmedLabel: confirmation.label,
                confirmationStreak: confirmation.streak, isClosedSession: closed)
            if session.date >= floorDate { days.append(day) }
            if closed { previous = day }
        }
        guard let current = days.last else { throw MarketStateError.invalidInput }
        let diagnostics = diagnostics(days)
        let (parameters, model) = try definitions()
        let warnings = diagnostics.correlations.filter(\.overlapWarning).map {
            "Observed overlap: \($0.first.rawValue)/\($0.second.rawValue) absolute correlation exceeds 0.7; shared components are not independent evidence."
        }
        return .init(schemaVersion: "market-state-report.v1", input: input, model: model, parameters: parameters,
            history: days, current: current, diagnostics: diagnostics,
            containsSynthetic: input.series.contains { $0.origin == .synthetic }, researchOnly: true,
            limitations: limitations + warnings)
    }

    public static func replay(_ report: MarketStateReport) throws -> MarketStateReport {
        let rebuilt = try calculate(report.input)
        guard rebuilt == report else { throw MarketStateError.incompatibleReport }
        return rebuilt
    }

    static func classify(heat: Double?, stress: Double?) -> MarketRegimeLabel {
        guard let heat, let stress else { return .unreliable }
        if (heat > 35 && heat < 65) || (stress > 35 && stress < 65) { return .transition }
        if heat >= 65 { return stress <= 35 ? .expansion : .volatileRally }
        return stress >= 65 ? .contraction : .quietConsolidation
    }

    static func confirm(raw: MarketRegimeLabel, previous: MarketStateDay?, closed: Bool) -> (label: MarketRegimeLabel, streak: Int) {
        guard closed else { return (previous?.confirmedLabel ?? .unreliable, 0) }
        guard let previous else { return (raw, 1) }
        if raw == .unreliable { return (.unreliable, 0) }
        let streak = previous.rawLabel == raw ? min(previous.confirmationStreak + 1, 2) : 1
        if previous.confirmedLabel == raw { return (raw, streak) }
        return (streak >= 2 ? raw : previous.confirmedLabel, streak)
    }

    static func aggregate(_ kind: MarketScoreKind, specs: [Component], results: [String: MarketAtomResult]) -> MarketScoreResult {
        let selected = specs.filter { $0.kind == kind }
        let pieces = selected.map { spec -> (Component, [MarketAtomResult], Double?) in
            let values = spec.atoms.compactMap { results[$0.id] }
            let valid = values.compactMap(\.score)
            let value = valid.count * 10000 >= spec.atoms.count * 7000 && !valid.isEmpty
                ? valid.reduce(0, +) / Double(valid.count) : nil
            return (spec, values, value)
        }
        let effective = pieces.reduce(0) { $0 + ($1.2 == nil ? 0 : $1.0.weight) }
        let total = effective >= 7000 ? pieces.reduce(0.0) { $0 + ($1.2 ?? 0) * Double($1.0.weight) } / Double(effective) : nil
        return .init(kind: kind, value: total, effectiveWeightBps: effective, components: pieces.map { spec, atoms, value in
            .init(id: spec.id, title: spec.title, originalWeightBps: spec.weight, atoms: atoms, value: value,
                contribution: total == nil ? nil : value.map { $0 * Double(spec.weight) / Double(effective) },
                validAtomCount: atoms.filter { $0.score != nil }.count, missingReason: value == nil ? .insufficientCoverage : nil)
        })
    }

    static func diagnostics(_ days: [MarketStateDay]) -> MarketHistoryDiagnostics {
        let eligible = days.filter(\.isClosedSession)
        let valid = eligible.filter { $0.heat.value != nil && $0.stress.value != nil && $0.sentiment.value != nil }
        let pairs: [(MarketScoreKind, MarketScoreKind)] = [(.heat, .stress), (.heat, .sentiment), (.stress, .sentiment)]
        let correlations = pairs.map { a, b -> MarketCorrelation in
            let x = valid.compactMap { score($0, a) }, y = valid.compactMap { score($0, b) }
            let rho = x.count >= 252 ? pearson(x, y) : nil
            return .init(first: a, second: b, commonCount: valid.count, coefficient: rho, overlapWarning: rho.map { abs($0) > 0.7 } ?? false)
        }
        return .init(eligibleSessionCount: eligible.count, commonValidDayCount: valid.count,
            coverage: eligible.isEmpty ? nil : Double(valid.count) / Double(eligible.count), correlations: correlations,
            frequencies: MarketRegimeLabel.allCases.map { label in
                let count = valid.filter { $0.confirmedLabel == label }.count
                return .init(label: label, count: count, fraction: valid.isEmpty ? nil : Double(count) / Double(valid.count))
            })
    }
    private static func score(_ day: MarketStateDay, _ kind: MarketScoreKind) -> Double? {
        switch kind { case .heat: day.heat.value; case .stress: day.stress.value; case .sentiment: day.sentiment.value }
    }
    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        let aa = a.map { $0 - ma }, bb = b.map { $0 - mb }
        let denominator = sqrt(aa.reduce(0) { $0 + $1 * $1 } * bb.reduce(0) { $0 + $1 * $1 })
        guard denominator > 0, denominator.isFinite else { return nil }
        let value = zip(aa, bb).reduce(0) { $0 + $1.0 * $1.1 } / denominator
        return value.isFinite ? min(1, max(-1, value)) : nil
    }

    static func fiveYearsBefore(_ date: String) -> String {
        guard let day = parseDay(date), let earlier = utcCalendar.date(byAdding: .year, value: -5, to: day) else { return date }
        return dayText(earlier)
    }
    static var utcCalendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar }
    static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-"); guard parts.count == 3, text.count == 10,
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
            let date = utcCalendar.date(from: DateComponents(year: y, month: m, day: d)), dayText(date) == text else { return nil }
        return date
    }
    /// Exchange session labels are New York civil dates, independent of machine locale.
    static func marketDayText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func dayText(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func validate(_ input: MarketStateInput) throws {
        guard input.methodVersion == MarketStateInput.currentMethodVersion else { throw MarketStateError.unsupportedVersion }
        guard input.createdAt.timeIntervalSince1970.isFinite, input.asOf.timeIntervalSince1970.isFinite,
              input.createdAt >= input.asOf, input.createdAt >= Date(timeIntervalSince1970:1792368000), !input.sessions.isEmpty, input.sessions.count <= 3000,
              input.sessions.last?.date == input.sessionDate, parseDay(input.sessionDate) != nil, marketDayText(input.asOf) == input.sessionDate,
              !input.calendarEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(input.series.map(\.key)).count == input.series.count else { throw MarketStateError.invalidInput }
        for (i, session) in input.sessions.enumerated() {
            guard parseDay(session.date) != nil, session.closeAt.timeIntervalSince1970.isFinite,
                  marketDayText(session.closeAt) == session.date,
                  i == 0 || (input.sessions[i-1].date < session.date && input.sessions[i-1].closeAt < session.closeAt),
                  i == input.sessions.count-1 || session.closeAt <= input.asOf else { throw MarketStateError.invalidInput }
        }
        for series in input.series {
            guard series.unit == series.key.unit, !series.sourceID.isEmpty, !series.feedID.isEmpty,
                  !series.methodology.isEmpty, !series.basisVersion.isEmpty,
                  !series.key.requiresPopulation || !(series.population ?? "").isEmpty,
                  series.observations.count <= 12000 else { throw MarketStateError.invalidInput }
            let weekly = series.key == .naaim || series.key == .assetManagerNetOverOI || series.key == .leveragedFundsNetOverOI
            guard series.frequency == (weekly ? .weekly : .daily) else { throw MarketStateError.invalidInput }
            var identities: [String: String] = [:], dates: [String: String] = [:], versions = Set<String>(), clocks = Set<String>()
            for value in series.observations {
                guard !value.observationID.isEmpty, !value.vintageID.isEmpty, parseDay(value.observationDate) != nil,
                      value.releasedAt.timeIntervalSince1970.isFinite, value.availableAt.timeIntervalSince1970.isFinite,
                      value.releasedAt <= value.availableAt, (try? Money(value.rawValue)) == value.value,
                      versions.insert(value.vintageID).inserted,
                      clocks.insert(value.observationID + ":" + String(value.availableAt.timeIntervalSinceReferenceDate)).inserted,
                      identities[value.observationID] == nil || identities[value.observationID] == value.observationDate,
                      dates[value.observationDate] == nil || dates[value.observationDate] == value.observationID else { throw MarketStateError.invalidInput }
                identities[value.observationID] = value.observationDate; dates[value.observationDate] = value.observationID
                if let until = value.validUntil { guard until.timeIntervalSince1970.isFinite, until >= value.availableAt else { throw MarketStateError.invalidInput } }
                let number = NSDecimalNumber(decimal: value.value.amount).doubleValue
                guard number.isFinite else { throw MarketStateError.invalidInput }
                switch series.key {
                case .spyPrice, .qqqPrice, .iwmPrice, .rspPrice, .spyTotalReturn, .rspTotalReturn, .iwmTotalReturn, .hygTotalReturn, .iefTotalReturn, .lqdTotalReturn:
                    guard number > 0 else { throw MarketStateError.invalidInput }
                case .advancingFraction, .aboveMA50Fraction, .aboveMA200Fraction, .advancingVolumeFraction:
                    guard (0...1).contains(number) else { throw MarketStateError.invalidInput }
                case .newHighMinusLowFraction: guard (-1...1).contains(number) else { throw MarketStateError.invalidInput }
                case .assetManagerNetOverOI, .leveragedFundsNetOverOI, .naaim, .put25MinusATM30: break
                default: guard number >= 0 else { throw MarketStateError.invalidInput }
                }
            }
        }
        // Breadth legs must describe one declared population/feed, never assembled
        // from incompatible universes. PCR's four populations must remain distinct.
        let prices = input.series.filter { $0.unit == .price }
        guard Set(prices.map(\.basisVersion)).count <= 1 else { throw MarketStateError.invalidInput }
        let breadth: Set<MarketSeriesKey> = [.advancingFraction,.aboveMA50Fraction,.aboveMA200Fraction,.newHighMinusLowFraction,.advancingVolumeFraction]
        let broad = input.series.filter { breadth.contains($0.key) }
        guard Set(broad.compactMap(\.population)).count <= 1, Set(broad.map(\.feedID)).count <= 1 else { throw MarketStateError.invalidInput }
        let pcr: Set<MarketSeriesKey> = [.totalPutCall,.indexPutCall,.etfPutCall,.equityPutCall]
        let puts = input.series.filter { pcr.contains($0.key) }
        guard Set(puts.compactMap(\.population)).count == puts.count else { throw MarketStateError.invalidInput }
        let tff = input.series.filter { $0.key == .assetManagerNetOverOI || $0.key == .leveragedFundsNetOverOI }
        guard Set(tff.compactMap(\.population)).count <= 1, Set(tff.map(\.feedID)).count <= 1 else { throw MarketStateError.invalidInput }
    }
}
