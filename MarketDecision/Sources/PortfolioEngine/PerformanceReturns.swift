import Foundation
import CoreDomain

public struct PerformanceCashFlow: Codable, Equatable, Sendable {
    public let day: String
    public let amount: Money
    public init(day: String, amount: Money) { self.day = day; self.amount = amount }
}

/// Actual/365, end-of-day cash-flow convention. A found root is never a claim of global uniqueness.
public enum PerformanceXIRRSolver {
    public static func solve(_ flows: [PerformanceCashFlow]) throws -> PerformanceXIRR {
        let lower = -0.9999, upper = 10.0, zero = try Money("0")
        var grouped: [String: Money] = [:]
        for flow in flows { _ = try PerformanceDates.parse(flow.day); grouped[flow.day] = try (grouped[flow.day] ?? zero).adding(flow.amount) }
        let dates = grouped.keys.sorted()
        func empty(_ status: PerformanceStatus, _ reason: String) -> PerformanceXIRR {
            PerformanceXIRR(value: nil, roots: [], status: status, residuals: [], searchLower: lower, searchUpper: upper, reason: reason)
        }
        guard let start = dates.first, let end = dates.last, start < end else { return empty(.missingInput, "至少两个不同日期") }
        let values = try dates.map { day -> (Double, Double) in
            guard let amount = grouped[day], let number = Double(amount.decimalString), number.isFinite else { throw PerformanceError.arithmeticFailure }
            return (Double(try PerformanceDates.difference(start, day)) / 365, number)
        }
        guard values.contains(where: { $0.1 < 0 }), values.contains(where: { $0.1 > 0 }) else { return empty(.missingInput, "需同时有正负投资者现金流") }
        let tolerance = max(1e-8, 1e-10 * values.reduce(0) { $0 + abs($1.1) })
        func npv(_ rate: Double) -> Double { values.reduce(0) { $0 + $1.1 * exp(-$1.0 * log1p(rate)) } }
        func derivative(_ rate: Double) -> Double { values.reduce(0) { $0 - $1.0 * $1.1 * exp(-($1.0 + 1) * log1p(rate)) } }
        func bisect(_ a: Double, _ b: Double) -> Double? {
            var l = a, u = b, f = npv(l)
            if f == 0 { return l }; if npv(u) == 0 { return u }
            guard f.isFinite, npv(u).isFinite, (f < 0) != (npv(u) < 0) else { return nil }
            for _ in 0..<200 {
                let m = (l + u) / 2, v = npv(m)
                guard v.isFinite else { return nil }
                if v == 0 { return m }
                if (v < 0) == (f < 0) { l = m; f = v } else { u = m }
                if u - l <= 1e-10, abs(npv((l + u) / 2)) <= tolerance { return (l + u) / 2 }
            }
            let result = (l + u) / 2
            return abs(npv(result)) <= tolerance ? result : nil
        }
        var candidates: [Double] = [], newton = 0.1
        for _ in 0..<200 {
            let value = npv(newton), slope = derivative(newton)
            if value == 0 { candidates.append(newton); break }
            guard value.isFinite, slope.isFinite, slope != 0 else { break }
            let next = newton - value / slope
            guard next.isFinite, next >= lower, next <= upper else { break }
            if abs(next - newton) <= 1e-10, abs(npv(next)) <= tolerance { candidates.append(next); break }
            newton = next
        }
        if let root = bisect(lower, upper) { candidates.append(root) }
        var previous = lower, priorNPV = npv(lower)
        for index in 1...4096 {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let current = expm1(log1p(lower) + Double(index) / 4096 * (log1p(upper) - log1p(lower)))
            let currentNPV = npv(current)
            if priorNPV == 0 { candidates.append(previous) }
            if currentNPV == 0 { candidates.append(current) }
            if priorNPV.isFinite, currentNPV.isFinite, (priorNPV < 0) != (currentNPV < 0), let root = bisect(previous, current) { candidates.append(root) }
            previous = current; priorNPV = currentNPV
        }
        var roots: [Double] = []
        for candidate in candidates.sorted() where candidate >= lower && candidate <= upper && abs(npv(candidate)) <= tolerance {
            if !roots.contains(where: { abs($0 - candidate) <= 1e-8 }) { roots.append(candidate) }
        }
        guard !roots.isEmpty else { return empty(.unresolved, "指定范围内未找到满足残差的根；不证明范围外无根") }
        return PerformanceXIRR(value: roots.count == 1 ? roots[0] : nil, roots: roots,
            status: roots.count == 1 ? .available : .multipleRoots, residuals: roots.map { abs(npv($0)) },
            searchLower: lower, searchUpper: upper, reason: roots.count == 1 ? "范围内找到单根；不证明全域唯一" : "多个根，不选择其中一个作为收益率")
    }
}

struct PerformanceReturnBundle {
    let segments: [PerformanceSegment]
    let twr: PerformanceNumber
    let xirr: PerformanceXIRR
    let cagr: PerformanceNumber
    let risk: PerformanceRisk
    let rolling: [PerformanceRollingReturn]
    let monthly: [PerformanceMonthlyReturn]
}

enum PerformanceReturns {
    static func calculate(daily: [PerformanceDailyValue], input: PerformanceInput, activeEvents: [LedgerEvent]) throws -> PerformanceReturnBundle {
        let zero = try Money("0")
        var segments: [PerformanceSegment] = [], current: [PerformanceDailyReturn] = []
        func finish() {
            if let first = current.first, let last = current.last {
                segments.append(PerformanceSegment(startDay: first.startDay, endDay: last.day, returns: current, cumulativeReturn: last.index - 1))
            }
            current = []
        }
        for i in daily.indices.dropFirst() {
            let a = daily[i - 1], b = daily[i]
            guard input.request.externalFlowsComplete, let prior = a.nav, let end = b.nav, prior > zero, end >= zero else { finish(); continue }
            let ratio = try end.subtracting(prior).subtracting(b.externalFlow).divided(by: prior.decimalString)
            guard let r = Double(ratio.decimalString), r.isFinite, r >= -1 else { finish(); continue }
            let index = (current.last?.index ?? 1) * (1 + r)
            guard index.isFinite else { throw PerformanceError.arithmeticFailure }
            current.append(PerformanceDailyReturn(day: b.day, startDay: a.day, value: r, index: index))
        }
        finish()
        let twr: PerformanceNumber
        if daily.count > 1, segments.count == 1, segments[0].returns.count == daily.count - 1 {
            twr = PerformanceNumber(value: segments[0].cumulativeReturn, status: .available, sampleCount: daily.count - 1)
        } else {
            twr = PerformanceNumber(value: nil, status: input.request.externalFlowsComplete ? .segmented : .missingInput,
                reason: "缺日、零/负期初 NAV 或现金流完整性不足；只保留连续段，不拼接", sampleCount: segments.reduce(0) { $0 + $1.returns.count })
        }
        let periodEvents: [LedgerEvent]
        if let a = daily.first?.valuationAt, let b = daily.last?.valuationAt { periodEvents = activeEvents.filter { $0.effectiveAt > a && $0.effectiveAt <= b } }
        else { periodEvents = [] }
        let ledger = try LedgerEngine.replay(accounts: input.accounts, events: input.events)
        let postingMap = Dictionary(uniqueKeysWithValues: ledger.postings.map { ($0.eventID, $0) })
        var external: [PerformanceCashFlow] = []
        for event in periodEvents {
            if let p = postingMap[event.id], p.externalFlow != zero {
                external.append(PerformanceCashFlow(day: PerformanceDates.marketDay(event.effectiveAt), amount: try p.externalFlow.multiplied(by: "-1")))
            }
        }
        let xirr: PerformanceXIRR
        if input.request.externalFlowsComplete, let first = daily.first, let last = daily.last,
           let a = first.nav, let b = last.nav, a >= zero, b >= zero, first.day < last.day {
            xirr = try PerformanceXIRRSolver.solve([PerformanceCashFlow(day: first.day, amount: a.multiplied(by: "-1"))] + external + [PerformanceCashFlow(day: last.day, amount: b)])
        } else {
            xirr = PerformanceXIRR(value: nil, roots: [], status: .missingInput, residuals: [], searchLower: -0.9999, searchUpper: 10,
                reason: "需可用首尾 NAV 及独立完整外部现金流；中间估值缺日不单独阻断 XIRR")
        }
        let cagr: PerformanceNumber
        if input.request.externalFlowsComplete, external.isEmpty, let first = daily.first, let last = daily.last,
           let a = first.nav, let b = last.nav, a > zero, b > zero, first.day < last.day {
            let ratio = try b.divided(by: a.decimalString)
            cagr = number(pow(Double(ratio.decimalString)!, 365 / Double(try PerformanceDates.difference(first.day, last.day))) - 1)
        } else { cagr = PerformanceNumber(value: nil, status: .notApplicable, reason: "CAGR 仅无外部现金流、正首尾 NAV 且跨度为正时定义") }
        let rolling = [30, 90, 365].map { interval -> PerformanceRollingReturn in
            let end = daily.last?.day ?? ""
            guard let endDate = try? PerformanceDates.parse(end), let target = PerformanceDates.calendar.date(byAdding: .day, value: -interval, to: endDate) else {
                return PerformanceRollingReturn(calendarDays: interval, anchorDay: nil, endDay: end, result: number(nil, .missingInput))
            }
            let anchor = daily.last(where: { $0.day <= PerformanceDates.text(target) })?.day
            return PerformanceRollingReturn(calendarDays: interval, anchorDay: anchor, endDay: end, result: intervalReturn(from: anchor, to: end, segments: segments))
        }
        let months = Set(daily.map { String($0.day.prefix(7)) }).sorted()
        let monthly = months.map { month -> PerformanceMonthlyReturn in
            let end = daily.last(where: { $0.day.hasPrefix(month) })!.day
            let anchor = daily.last(where: { $0.day < month + "-01" })?.day
            return PerformanceMonthlyReturn(month: month, result: intervalReturn(from: anchor, to: end, segments: segments), endDay: end)
        }
        return PerformanceReturnBundle(segments: segments, twr: twr, xirr: xirr, cagr: cagr,
            risk: try risk(daily: daily, segments: segments, input: input), rolling: rolling, monthly: monthly)
    }
    static func number(_ value: Double?, _ status: PerformanceStatus = .available, n: Int = 0, reason: String = "") -> PerformanceNumber {
        guard let value else { return PerformanceNumber(value: nil, status: status, reason: reason, sampleCount: n) }
        return PerformanceNumber(value: value.isFinite ? value : nil, status: value.isFinite ? status : .unresolved, reason: reason, sampleCount: n)
    }
    static func intervalReturn(from: String?, to: String, segments: [PerformanceSegment]) -> PerformanceNumber {
        guard let from, let segment = segments.first(where: { $0.startDay <= from && $0.endDay >= to }) else { return number(nil, .missingInput, reason: "缺锚点或跨越收益段") }
        let start = from == segment.startDay ? 1 : segment.returns.first(where: { $0.day == from })?.index
        let end = to == segment.startDay ? 1 : segment.returns.first(where: { $0.day == to })?.index
        guard let start, let end, start > 0 else { return number(nil, .zeroDenominator) }
        return number(end / start - 1)
    }
    static func drawdown(_ series: [(String, Double)]) -> PerformanceDrawdown? {
        guard let first = series.first, first.1 > 0 else { return nil }
        var peak = first, best = PerformanceDrawdown(value: 0, peakDay: first.0, troughDay: first.0, recoveredDay: nil)
        for (i, point) in series.enumerated() {
            if point.1 > peak.1 { peak = point }
            guard peak.1 > 0 else { continue }
            let dd = point.1 / peak.1 - 1
            if dd < best.value {
                let recovery = series.dropFirst(i + 1).first(where: { $0.1 >= peak.1 })?.0
                best = PerformanceDrawdown(value: dd, peakDay: peak.0, troughDay: point.0, recoveredDay: recovery)
            }
        }
        return best
    }
    static func risk(daily: [PerformanceDailyValue], segments: [PerformanceSegment], input: PerformanceInput) throws -> PerformanceRisk {
        // Only the segment ending on the final requested day is eligible for current risk statistics.
        let recent = segments.last.flatMap { $0.endDay == daily.last?.day ? $0 : nil }
        let observations = Array((recent?.returns ?? []).suffix(252)), n = observations.count
        let status: PerformanceStatus = n < 60 ? .insufficientSample : (n < 252 ? .shortSample : .available)
        let unavailable = number(nil, status, n: n, reason: "连续窗口最多 252 日，至少 60 个收益观测")
        var volatility = unavailable, annual = unavailable, rf = unavailable, sharpe = unavailable, sortino = unavailable, beta = unavailable
        if n >= 60 {
            let values = observations.map(\.value), mean = values.reduce(0, +) / Double(n)
            let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(n - 1)
            let sigma = sqrt(variance * 252)
            volatility = number(sigma, status, n: n)
            let factor = values.reduce(1) { $0 * (1 + $1) }
            annual = number(pow(factor, 252 / Double(n)) - 1, status, n: n)
            rf = try riskFree(from: observations[0].startDay, to: observations[n - 1].day, curves: input.request.rateCurves, status: status, n: n, endAt: daily.last?.valuationAt)
            if let ar = annual.value, let riskFree = rf.value {
                sharpe = sigma > 0 ? number((ar - riskFree) / sigma, status, n: n) : number(nil, .zeroDenominator, n: n)
                let mar = expm1(log1p(riskFree) / 252)
                let downside = sqrt(values.reduce(0) { $0 + pow(min($1 - mar, 0), 2) } / Double(n) * 252)
                sortino = downside > 0 ? number((ar - riskFree) / downside, status, n: n) : number(nil, .zeroDenominator, n: n)
            } else { sharpe = number(nil, .missingInput, n: n, reason: "缺同期已发布无风险利率"); sortino = sharpe }
            if let benchmark = input.request.benchmark, benchmark.isTotalReturn, benchmark.symbol == "SPY" {
                let points = Dictionary(uniqueKeysWithValues: benchmark.points.map { ($0.day, $0.totalReturnIndex) })
                var pairs: [(Double, Double)] = []
                for observation in observations {
                    guard let a = points[observation.startDay], let b = points[observation.day], a.amount > 0, b.amount > 0,
                          let ratio = Double(try b.divided(by: a.decimalString).decimalString) else { continue }
                    pairs.append((observation.value, ratio - 1))
                }
                if pairs.count >= 60 {
                    let count = Double(pairs.count), x = pairs.reduce(0) { $0 + $1.0 } / count, y = pairs.reduce(0) { $0 + $1.1 } / count
                    let covariance = pairs.reduce(0) { $0 + ($1.0 - x) * ($1.1 - y) } / (count - 1)
                    let v = pairs.reduce(0) { $0 + pow($1.1 - y, 2) } / (count - 1)
                    beta = v > 0 ? number(covariance / v, pairs.count < 252 ? .shortSample : .available, n: pairs.count) : number(nil, .zeroDenominator, n: pairs.count)
                } else { beta = number(nil, .insufficientSample, n: pairs.count) }
            } else { beta = number(nil, .missingInput, reason: "缺明确 SPY 总回报序列，不另加股息") }
        }
        let dd = segments.compactMap { drawdown([($0.startDay, 1)] + $0.returns.map { ($0.day, $0.index) }) }.min { $0.value < $1.value }
        var navSegments: [[(String, Double)]] = [], current: [(String, Double)] = []
        for day in daily {
            if let nav = day.nav, let value = Double(nav.decimalString), value >= 0 {
                if !current.isEmpty || value > 0 { current.append((day.day, value)) }
                if value == 0 { if !current.isEmpty { navSegments.append(current) }; current = [] }
            } else { if !current.isEmpty { navSegments.append(current) }; current = [] }
        }
        if !current.isEmpty { navSegments.append(current) }
        let navDD = navSegments.compactMap(drawdown).min { $0.value < $1.value }
        var calmar = number(nil, .insufficientSample, reason: "Calmar 需连续至少 12 个日历月，最多 36 个月")
        if let recent, let end = try? PerformanceDates.parse(recent.endDay),
           let threshold = PerformanceDates.calendar.date(byAdding: .month, value: -36, to: end) {
            let baseline = [recent.startDay] + recent.returns.map(\.day)
            let anchor = baseline.last(where: { $0 <= PerformanceDates.text(threshold) }) ?? recent.startDay
            let selected = recent.returns.filter { $0.day > anchor }
            if let start = try? PerformanceDates.parse(anchor), let minimumEnd = PerformanceDates.calendar.date(byAdding: .month, value: 12, to: start), end >= minimumEnd,
               !selected.isEmpty {
                let initial = anchor == recent.startDay ? 1 : recent.returns.first(where: { $0.day == anchor })!.index
                if initial > 0, let maximum = drawdown([(anchor, 1)] + selected.map { ($0.day, $0.index / initial) }) {
                    let rate = pow(selected.last!.index / initial, 252 / Double(selected.count)) - 1
                    calmar = maximum.value < 0 ? number(rate / abs(maximum.value), n: selected.count) : number(nil, .zeroDenominator)
                }
            }
        }
        return PerformanceRisk(annualizedVolatility: volatility, annualizedTWR: annual, annualizedRiskFree: rf,
            sharpe: sharpe, sortino: sortino, beta: beta, calmar: calmar, drawdown: dd, navDrawdown: navDD)
    }
    static func riskFree(from: String, to: String, curves: [PerformanceRateCurve], status: PerformanceStatus, n: Int, endAt: Date?) throws -> PerformanceNumber {
        let start = try PerformanceDates.parse(from), end = try PerformanceDates.parse(to)
        let days = try PerformanceDates.difference(from, to)
        guard days > 0 else { return number(nil, .missingInput) }
        var value = 1.0, ids = Set<String>()
        // Calendar-day accrual, including weekends. Each day's own published evidence
        // is selected; never apply the final day's rate retrospectively to the whole window.
        for index in 1...days {
            guard let day = PerformanceDates.calendar.date(byAdding: .day, value: index, to: start), day <= end else { throw PerformanceError.invalidCalendar }
            var ny = PerformanceDates.calendar; ny.timeZone = TimeZone(identifier: "America/New_York")!
            let components = PerformanceDates.calendar.dateComponents([.year, .month, .day], from: day)
            guard let cutoff = ny.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: 23, minute: 59, second: 59)) else { throw PerformanceError.invalidCalendar }
            let effectiveCutoff = endAt.map { min(cutoff, $0) } ?? cutoff
            let rate = PortfolioRates.dailyEffective(at: effectiveCutoff, curves: curves)
            guard let r = rate.value else { return number(nil, .missingInput, n: n, reason: "同期至少一个日历日无已发布且未过期利率") }
            value *= 1 + r; ids.formUnion(rate.evidenceIDs)
        }
        let annual = pow(value, 365 / Double(days)) - 1
        return PerformanceNumber(value: annual.isFinite ? annual : nil, status: annual.isFinite ? status : .unresolved, sampleCount: n, evidenceIDs: ids.sorted())
    }
}
