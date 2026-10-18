import Foundation
import CoreDomain
import DataContracts

/// CALC-026 plus the existing local BSM inversion. This does not admit a provider,
/// establish retrospective availability, or turn a declared scope into a full market chain.
public enum OptionDailyEngine {
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let p = ParameterSet(id: "options.iv-daily.parameters", version: "PARAMETERS_V1.iv-daily.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000001")!,
            values: ["targetDays": .integer(30), "yearDays": .integer(365), "exactSecondsTolerance": .integer(1),
                "bracketMaxDays": .integer(30), "maxSkewSeconds": .integer(5), "maxAgeSeconds": .integer(60),
                "atm": .text("min abs(log(K/S)); floating-point tie lower K; same K call+put local IV mean"),
                "interpolation": .text("linear total variance, no extrapolation or single-expiry proxy"),
                "OI": .text("own asOf/release and explicit latest-published declaration; offline calendar, age <=2 sessions"),
                "delta25": .text("unavailable: selection/interpolation model not implemented"),
                "scope": .text("manual or synthetic declared chain; research only; no PIT admission")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-022,024,026,029;DC-009,017")
        let m = ModelDefinition(id: "options.iv-daily", version: OptionDailyInput.currentMethodVersion,
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000002")!, owner: "OptionsAnalytics",
            purpose: "Offline declared-chain daily summaries and local-IV 30-day total variance",
            inputs: [.init(name: "completeFrozenDailyInput", unit: "USD+seconds+contracts", role: .required)],
            outputs: [.init(name: "contractAndChainSummary", unit: "ratio+contracts")],
            formula: "ATM by log moneyness, same strike call-put local IV mean; IV30=sqrt(linearly interpolated sigma^2*T/(30/365))",
            formulaVersion: OptionDailyInput.currentMethodVersion, implementationReference: "OptionsAnalytics/OptionDailyEngine.v1",
            defaultParameters: p.reference, numericPolicyVersion: OptionBSM.numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1", knownLimitations: limitations, testFixtures: ["OptionDailyTests"],
            introducedAt: try MillisecondInstant(iso8601: "2026-10-18T00:00:00.000Z"))
        try p.validate(); try m.validate(); return (p, m)
    }
    public static func calculate(_ input: OptionDailyInput) throws -> OptionDailyReport {
        try Task.checkCancellation(); try validate(input); try OptionChainEvidence.validate(input)
        let s = validMid(input.underlying.bid, input.underlying.ask)
        let r = try number(input.rate), q = try number(input.dividendYield)
        let underlyingState = quoteState(bid: input.underlying.bid, ask: input.underlying.ask,
            quote: input.underlying.quoteTime, received: input.underlying.receivedAt, asOf: input.asOf)
        let allTimes = [input.underlying.quoteTime] + input.contracts.map(\.quoteTime)
        let times = allTimes.compactMap { $0 }
        let maxSkew: Double? = times.count == allTimes.count ? times.max().flatMap { latest in times.min().map { latest.timeIntervalSince($0) } } : nil
        var summaries: [OptionDailyContractSummary] = []
        for item in input.contracts.sorted(by: { $0.contractID < $1.contractID }) {
            try Task.checkCancellation()
            var state = underlyingState
            if state == .available {
                state = quoteState(bid: item.bid, ask: item.ask, quote: item.quoteTime, received: item.receivedAt, asOf: input.asOf)
            }
            if state == .available, let u = input.underlying.quoteTime, let c = item.quoteTime, abs(u.timeIntervalSince(c)) > 5 { state = .quoteSkew }
            if state == .available, item.bidSize <= 0 || item.askSize <= 0 { state = .invalidQuote }
            if state == .available {
                if let tick = item.tick, tick.amount > 0 {
                    if !isTickMultiple(item.bid, tick: tick) || !isTickMultiple(item.ask, tick: tick) { state = .invalidQuote }
                } else { state = .missingTick }
            }
            let mid = validMid(item.bid, item.ask)
            var iv: OptionLabIVResult?, delta: Double?
            if state == .available, let spot = s, let mid {
                let market = OptionBSMMarket(right: item.right, spot: try number(spot), strike: try number(item.strike),
                    rate: r, dividendYield: q, timeYears: item.expiry.settlementAt.timeIntervalSince(input.asOf) / 31_536_000)
                iv = try OptionIVSolver.solve(market, price: number(mid))
                if iv?.state == .available, let sigma = iv?.volatility {
                    let priced = OptionBSM.evaluate(market, volatility: sigma)
                    if priced.state == .available { delta = priced.greeks?.delta }
                }
                if iv?.state != .available || delta == nil { state = .missingCanonicalIV }
            }
            let volume = item.activity.volumeSession == input.session ? item.activity.volume : nil
            var oi: Int?
            if item.activity.openInterestLatestPublished == true, let value = item.activity.openInterest, let date = item.activity.openInterestAsOf,
               let release = item.activity.openInterestReleasedAt, release <= input.asOf,
               let sessions = input.calendar?.sessions, let current = sessions.firstIndex(of: input.session),
               let observation = sessions.firstIndex(of: date), observation <= current, current - observation <= 2 { oi = value }
            summaries.append(.init(contractID: item.contractID, closingBid: item.bid, closingAsk: item.ask, closingMid: mid,
                state: state, localIV: iv, canonicalIV: state == .available ? iv?.volatility : nil,
                canonicalDelta: state == .available ? delta : nil, eligibleVolume: volume, eligibleOpenInterest: oi,
                pricingModelVersion: OptionLabPricingInput.currentMethodVersion))
        }
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.contractID, $0) })
        let grouped = Dictionary(grouping: input.contracts, by: { $0.expiry.settlementAt })
        var expiries: [OptionDailyExpirySummary] = []
        for settlement in grouped.keys.sorted() {
            try Task.checkCancellation()
            let contracts = grouped[settlement] ?? []
            let seconds = settlement.timeIntervalSince(input.asOf)
            var selectedStrike: Money?
            if let s, let spot = Double(s.decimalString), spot > 0 {
                for strike in contracts.map(\.strike).sorted() {
                    guard let k = Double(strike.decimalString), k > 0 else { continue }
                    guard let selected = selectedStrike, let oldK = Double(selected.decimalString) else { selectedStrike = strike; continue }
                    let candidate = abs(log(k / spot)), old = abs(log(oldK / spot))
                    // Only round-off sized ties. Does not group distinct economic distances.
                    let tolerance = max(candidate.ulp, old.ulp) * 8
                    if candidate < old - tolerance || (abs(candidate - old) <= tolerance && strike < selected) { selectedStrike = strike }
                }
            }
            let call = contracts.first { $0.strike == selectedStrike && $0.right == .call }
            let put = contracts.first { $0.strike == selectedStrike && $0.right == .put }
            let callIV = call.flatMap { byID[$0.contractID]?.canonicalIV }, putIV = put.flatMap { byID[$0.contractID]?.canonicalIV }
            let atm: Double? = callIV.flatMap { c in putIV.map { (c + $0) / 2 } }
            let state: OptionDailyState = call == nil || put == nil ? .missingATMCallOrPut : (atm == nil ? .missingCanonicalIV : .available)
            expiries.append(.init(settlementAt: settlement, timeYears: seconds / 31_536_000, strike: selectedStrike,
                callContractID: call?.contractID, putContractID: put?.contractID, callIV: callIV, putIV: putIV, atmIV: atm, state: state))
        }
        let targetSeconds = 30.0 * 86_400, targetT = 30.0 / 365
        var value: Double?, used: [Date] = [], state: OptionDailyState = .noBracket
        let valid = expiries.filter { $0.state == .available && $0.atmIV != nil && $0.timeYears > 0 }
        if input.sessionCloseAt != input.asOf { state = .unverifiedSessionClose }
        else if input.coverage == .partial { state = .partialChain }
        else if maxSkew == nil { state = .unknownQuoteTime }
        else if let maxSkew, maxSkew > 5 { state = .quoteSkew }
        else if let exact = valid.filter({ abs($0.settlementAt.timeIntervalSince(input.asOf) - targetSeconds) <= 1 }).min(by: {
            let a = abs($0.settlementAt.timeIntervalSince(input.asOf) - targetSeconds)
            let b = abs($1.settlementAt.timeIntervalSince(input.asOf) - targetSeconds)
            return a == b ? $0.settlementAt < $1.settlementAt : a < b
        }) { value = exact.atmIV; used = [exact.settlementAt]; state = .available }
        else if let below = valid.last(where: { $0.timeYears < targetT }), let above = valid.first(where: { $0.timeYears > targetT }),
                targetSeconds - below.settlementAt.timeIntervalSince(input.asOf) <= targetSeconds,
                above.settlementAt.timeIntervalSince(input.asOf) - targetSeconds <= targetSeconds,
                let low = below.atmIV, let high = above.atmIV {
            let weight = (targetT - below.timeYears) / (above.timeYears - below.timeYears)
            let variance = (low * low * below.timeYears * (1 - weight) + high * high * above.timeYears * weight) / targetT
            if variance.isFinite, variance >= 0 { value = sqrt(variance); used = [below.settlementAt, above.settlementAt]; state = .available }
            else { state = .numericFailure }
        }
        let chain = OptionDailyChainSummary(symbol: input.symbol, feedID: input.feedID, session: input.session,
            underlyingQuoteID: input.underlying.quoteID, underlyingMid: s, coverage: input.coverage,
            observedContractCount: summaries.count, totalVolume: total(summaries.map(\.eligibleVolume), complete: input.coverage == .complete),
            totalOpenInterest: total(summaries.map(\.eligibleOpenInterest), complete: input.coverage == .complete), maxSkewSeconds: maxSkew,
            rate: input.rate, dividendYield: input.dividendYield, iv30: value, put25DeltaIV: nil, call25DeltaIV: nil,
            delta25UnavailableReason: "25-Delta selection/interpolation not implemented; no proxy substituted")
        let (parameters, model) = try definitions(), (pricingParameters, pricingModel) = try OptionLabPricingEngine.definitions()
        return .init(schemaVersion: input.chainEvidence == nil ? "option-daily-report.v1" : "option-daily-report.v2.chain", input: input, model: model, parameters: parameters,
            pricingModel: pricingModel, pricingParameters: pricingParameters, chainSummary: chain, contractSummaries: summaries,
            expiries: expiries, iv30: value, state: state, iv30ExpiryInstants: used, containsSynthetic: synthetic(input), researchOnly: true, limitations: limitations)
    }
    public static func replay(_ report: OptionDailyReport) throws -> OptionDailyReport {
        let result = try calculate(report.input)
        guard result == report else { throw OptionDailyError.incompatibleReport }
        return result
    }
    static func validateSource(_ source: OptionLabSource, createdAt: Date) throws {
        guard validText(source.reference), source.enteredAt.timeIntervalSince1970.isFinite,
              source.enteredAt <= createdAt else { throw OptionDailyError.invalidIdentity }
    }
    static func validateCalendar(_ calendar: OptionDailyCalendar, createdAt: Date) throws {
        guard validText(calendar.id), validText(calendar.version), !calendar.sessions.isEmpty, calendar.sessions.count <= 10_000,
              calendar.sessions == calendar.sessions.sorted(), Set(calendar.sessions).count == calendar.sessions.count
        else { throw OptionDailyError.invalidCalendar }
        try validateSource(calendar.source, createdAt: createdAt)
        for day in calendar.sessions { _ = try day.start(in: TimeZone(secondsFromGMT: 0)!) }
    }
    static func validText(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func number(_ amount: Money) throws -> Double {
        guard let value = Double(amount.decimalString), value.isFinite else { throw OptionDailyError.invalidInput }; return value
    }
    private static func validate(_ input: OptionDailyInput) throws {
        guard input.methodVersion == OptionDailyInput.currentMethodVersion, validText(input.symbol), validText(input.feedID), validText(input.declaredScope),
              validText(input.underlying.quoteID), !input.contracts.isEmpty, input.contracts.count <= 10_000,
              input.dividendYield.amount >= 0 else { throw OptionDailyError.invalidInput }
        guard input.createdAt.timeIntervalSince1970.isFinite, input.asOf.timeIntervalSince1970.isFinite, input.asOf <= input.createdAt,
              let zone = TimeZone(identifier: input.sessionTimeZoneID) else { throw OptionDailyError.invalidTime }
        let start = try input.session.start(in: zone)
        let end = try input.session.addingDays(1).start(in: zone)
        guard input.asOf >= start, input.asOf < end else { throw OptionDailyError.invalidTime }
        if let close = input.sessionCloseAt {
            guard close.timeIntervalSince1970.isFinite, close >= start, close < end, close <= input.createdAt else { throw OptionDailyError.invalidTime }
        }
        try validateSource(input.source, createdAt: input.createdAt); try validateSource(input.underlying.source, createdAt: input.createdAt)
        if let calendar = input.calendar {
            try validateCalendar(calendar, createdAt: input.createdAt)
            guard calendar.sessions.contains(input.session) else { throw OptionDailyError.invalidCalendar }
        }
        guard input.underlying.symbol == input.symbol, input.underlying.feedID == input.feedID, input.underlying.session == input.session else { throw OptionDailyError.mismatchedSource }
        var ids = Set<String>(), keys = Set<String>()
        for item in input.contracts {
            guard validText(item.contractID), validText(item.specificationVersion), item.multiplier == 100,
                  item.strike.amount > 0, item.bidSize >= 0, item.askSize >= 0 else { throw OptionDailyError.invalidInput }
            guard item.symbol == input.symbol, item.feedID == input.feedID, item.session == input.session,
                  item.underlyingQuoteID == input.underlying.quoteID else { throw OptionDailyError.mismatchedSource }
            let key = "\(item.expiry.settlementAt.timeIntervalSince1970)|\(item.strike.decimalString)|\(item.right.rawValue)"
            guard ids.insert(item.contractID).inserted, keys.insert(key).inserted else { throw OptionDailyError.duplicateContract }
            try validateSource(item.source, createdAt: input.createdAt); try validateSource(item.activity.source, createdAt: input.createdAt)
            try validateSource(item.expiry.source, createdAt: input.createdAt)
            guard item.expiry.settlementAt.timeIntervalSince1970.isFinite else { throw OptionDailyError.invalidTime }
            _ = try item.expiry.date.start(in: zone)
            var c = Calendar(identifier: .gregorian); c.timeZone = zone
            let d = c.dateComponents([.year, .month, .day], from: item.expiry.settlementAt)
            guard d.year == item.expiry.date.year, d.month == item.expiry.date.month, d.day == item.expiry.date.day else { throw OptionDailyError.invalidTime }
            for time in [item.quoteTime, item.receivedAt, item.activity.openInterestReleasedAt].compactMap({ $0 }) {
                guard time.timeIntervalSince1970.isFinite, time <= input.createdAt else { throw OptionDailyError.invalidTime }
            }
            if let quote = item.quoteTime, let received = item.receivedAt, quote > received { throw OptionDailyError.invalidTime }
            if let oi = item.activity.openInterest, oi < 0 { throw OptionDailyError.invalidInput }
            if let volume = item.activity.volume, volume < 0 { throw OptionDailyError.invalidInput }
            if let day = item.activity.openInterestAsOf { _ = try day.start(in: zone) }
            if let day = item.activity.volumeSession { _ = try day.start(in: zone) }
        }
        for time in [input.underlying.quoteTime, input.underlying.receivedAt].compactMap({ $0 }) {
            guard time.timeIntervalSince1970.isFinite, time <= input.createdAt else { throw OptionDailyError.invalidTime }
        }
        if let quote = input.underlying.quoteTime, let received = input.underlying.receivedAt, quote > received { throw OptionDailyError.invalidTime }
    }
    private static func isTickMultiple(_ price: Money, tick: Money) -> Bool {
        // Division can round, so verify the exact product as well. A value just
        // below an integer tick must never pass because the quotient rounded up.
        guard let steps = try? price.divided(by: tick.decimalString), !steps.decimalString.contains("."),
              let reconstructed = try? tick.multiplied(by: steps.decimalString) else { return false }
        return reconstructed == price
    }
    private static func validMid(_ bid: Money, _ ask: Money) -> Money? {
        guard bid.amount >= 0, ask.amount > 0, bid <= ask else { return nil }
        return try? bid.adding(ask).multiplied(by: "0.5")
    }
    private static func quoteState(bid: Money, ask: Money, quote: Date?, received: Date?, asOf: Date) -> OptionDailyState {
        guard validMid(bid, ask) != nil else { return .invalidQuote }
        guard let quote, let received, received <= asOf, quote <= asOf else { return .unknownQuoteTime }
        guard asOf.timeIntervalSince(quote) <= 60 else { return .staleQuote }
        return .available
    }
    private static func total(_ values: [Int?], complete: Bool) -> Int? {
        guard complete, values.allSatisfy({ $0 != nil }) else { return nil }
        var sum = 0
        for value in values { guard let value else { return nil }; let result = sum.addingReportingOverflow(value); if result.overflow { return nil }; sum = result.partialValue }
        return sum
    }
    private static func synthetic(_ input: OptionDailyInput) -> Bool {
        if input.source.origin == .synthetic || input.underlying.source.origin == .synthetic || input.calendar?.source.origin == .synthetic { return true }
        return input.contracts.contains { $0.source.origin == .synthetic || $0.activity.source.origin == .synthetic || $0.expiry.source.origin == .synthetic }
    }
    public static let limitations = [
        "仅手工／合成离线声明；不授予真实行情、PIT、供应商、交易日历或历史研究资格。",
        "COMPLETE 只覆盖输入明确声明的到期与行权价范围，不代表市场全链。部分链不能生成规范 IV30。",
        "IV30 仅使用同到期同K Call/Put Mid本地反解IV；失败不回退供应商、手工sigma或单到期代理。",
        "欧式连续股息 BSM 参考；美式提前行权和离散股息未建模。",
        "25-Delta IV 尚无本批已实现的选择模型，明确保留缺值。OI独立发布时间和会话不能由报价代填。",
        "Float64 数值重放依赖当前实现与平台；不是跨CPU/libm形式化证明。"
    ]
}
