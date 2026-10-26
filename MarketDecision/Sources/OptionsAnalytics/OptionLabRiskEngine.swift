import Foundation
import CoreDomain
import DataContracts

/// Offline, versioned heuristic assessment. No input is promoted to a provider
/// entitlement, executable liquidity ranking, event history or assignment probability.
public enum OptionLabRiskEngine {
    public static func definitions(enteredPrices: Bool = false) throws -> (ParameterSet, ModelDefinition) {
        let p = ParameterSet(id: "options.offline-risk.parameters", version: "PARAMETERS_V1.risk.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000001")!,
            values: ["liquidityWeightsBP": .text("spread:3000,OI:2000,volume:1500,age:1500,size:1000,neighbors:1000"),
                "liquidityScores": .text("100,70,30,0; all six required; any Avoid hard downgrade; worst leg"),
                "spread": .text("<=0.05,<=0.10,<=0.20,>0.20"), "OI": .text(">=1000,>=100,>=10,<10; latest published; <=2 sessions"),
                "volume": .text(">=100,>=10,>=1,0; full-session or same-elapsed-time"),
                "ageSeconds": .text("<=15,<=30,<=60,>60"), "sizeContracts": .text(">=10,>=5,>=1,0; covers intended quantity"),
                "neighborViolations": .text("0,<=0.25,<=0.50,>0.50; exactly two nearest qualified sides"),
                "totalGrade": .text(">=85,>=60,>=30,<30; missing never normalized"),
                "nearExpiryDTE": .integer(7), "deepITMFactor": .decimal(try Money("1.10")),
                "callDividendPVFactor": .decimal(try Money("0.9")), "putFactor": .decimal(try Money("1")),
                "longDTE": .integer(60), "highRate": .decimal(try Money("0.05")),
                "earningsWindow": .text("BMO/intraday previous-close to event-close; AMC event-close to next-close; UNKNOWN unavailable"),
                "expectedMove": .text("nearest expiry after conservative event-time upper bound (BMO open, AMC next open, intraday close); abs(log(K/S)) ATM, lower-K tie; callMid+putMid"),
                "eventHistoryMinimum": .integer(30), "history": .text("not implemented; no frequency or IV-crush estimate"),
                "dividendPV": .text("USD/share * exp(-r * actual seconds to explicit paymentAt / 31536000)")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-027,028,029;LIQ_DRAFT_1")
        let method = enteredPrices ? "options.offline-risk.entered.v1" : OptionLabRiskInput.currentMethodVersion
        let m = ModelDefinition(id: "options.offline-risk", version: method,
            revisionID: UUID(uuidString: enteredPrices ? "C035AA00-2026-4025-8000-000000000012" : "C035AA00-2026-4018-8000-000000000002")!, owner: "OptionsAnalytics",
            purpose: "Offline liquidity and event/early-assignment heuristics, not executable ranking or probability",
            inputs: [.init(name: "frozenOfflineRiskEvidence", unit: "USD+contracts+versioned-calendar", role: .required)],
            outputs: [.init(name: "liquidity", unit: "score+grade+coverage"), .init(name: "eventAndAssignment", unit: "evidence+heuristic")],
            formula: "LIQ_DRAFT_1 weighted six-factor score with hard downgrade and weakest-leg aggregation; CALC027 explicit calendar windows; CALC028 signed extrinsic threshold",
            formulaVersion: method, implementationReference: "OptionsAnalytics/OptionLabRiskEngine.v1",
            defaultParameters: p.reference, numericPolicyVersion: Money.numericPolicyVersion + "+Float64-exp-dividendPV.v1",
            state: .approved, dispositionReference: "PARAMETERS_V1", knownLimitations: notices(enteredPrices: enteredPrices),
            testFixtures: ["OptionLabRiskTests"], introducedAt: try MillisecondInstant(iso8601: enteredPrices ? "2026-10-25T00:00:00.000Z" : "2026-10-18T00:00:00.000Z"))
        try p.validate(); try m.validate(); return (p, m)
    }

    static func calculate(input: OptionLabInput, assumptions: OptionLabRiskInput,
                                 pricing: OptionLabPricingReport?, underlyingMid: Money, dte: Int) throws -> OptionLabRiskReport {
        try Task.checkCancellation()
        try validate(assumptions, input: input)
        guard underlyingMid.amount > 0, dte >= 0, input.expiry.settlementAt > input.asOf else { throw OptionLabRiskError.invalidInput }
        let legs = [input.shortLeg] + (input.longLeg.map { [$0] } ?? [])
        let assessments = try legs.map { leg in
            try liquidity(leg, evidence: assumptions.liquidity.first { $0.contractID == leg.contractID }, asOf: input.asOf)
        }
        let totalGrade: OptionLabLiquidityGrade
        if assessments.contains(where: { $0.grade == .avoid }) { totalGrade = .avoid }
        else if assessments.contains(where: { $0.grade == .dataInsufficient }) { totalGrade = .dataInsufficient }
        else { totalGrade = assessments.map(\.grade).max(by: { severity($0) < severity($1) }) ?? .dataInsufficient }
        let totalScore = assessments.allSatisfy { $0.score != nil } ? assessments.compactMap(\.score).min() : nil
        let (parameters, model) = try definitions(enteredPrices: input.usesEnteredPrices)
        return .init(input: assumptions, model: model, parameters: parameters,
            liquidity: .init(legs: assessments, grade: totalGrade, score: totalScore, researchOnly: true, mayRankLive: false),
            earnings: try earnings(assumptions.earnings, input: input, spot: underlyingMid),
            assignment: try assignment(assumptions.dividend, input: input, spot: underlyingMid, dte: dte), warnings: notices(enteredPrices: input.usesEnteredPrices))
    }

    public static func validate(_ assumptions: OptionLabRiskInput, input: OptionLabInput) throws {
        try source(assumptions.source, createdAt: input.createdAt)
        guard assumptions.methodVersion == OptionLabRiskInput.currentMethodVersion,
              assumptions.liquidity.count <= 2, Set(assumptions.liquidity.map(\.contractID)).count == assumptions.liquidity.count
        else { throw OptionLabRiskError.invalidInput }
        let ids = Set(([input.shortLeg] + (input.longLeg.map { [$0] } ?? [])).map(\.contractID))
        for evidence in assumptions.liquidity {
            guard ids.contains(evidence.contractID), evidence.neighbors.count <= 400,
                  evidence.openInterest.map({ $0 >= 0 }) ?? true, evidence.volume.map({ $0 >= 0 }) ?? true,
                  evidence.oiSessionsAgo.map({ $0 >= 0 }) ?? true,
                  Set(evidence.neighbors.map(\.contractID)).count == evidence.neighbors.count,
                  Set(evidence.neighbors.map { $0.strike.decimalString }).count == evidence.neighbors.count
            else { throw OptionLabRiskError.invalidInput }
            for leg in evidence.neighbors { try source(leg.source, createdAt: input.createdAt) }
        }
        if let e = assumptions.earnings {
            try source(e.source, createdAt: input.createdAt)
            try eventVersion(e.eventVersion, announcedAt: e.announcedAt, asOf: input.asOf)
            _ = try day(e.eventDate)
            guard e.timing != .notApplicable, e.straddles.count <= 1000 else { throw OptionLabRiskError.invalidEvent }
            if let c = e.calendar { try calendar(c, createdAt: input.createdAt) }
            var keys = Set<String>()
            for q in e.straddles {
                try source(q.source, createdAt: input.createdAt)
                guard q.strike.amount > 0, finite(q.settlementAt), finite(q.quotedAt),
                      q.callBid.amount >= 0, q.putBid.amount >= 0, q.callAsk.amount > 0, q.putAsk.amount > 0,
                      q.callAsk >= q.callBid, q.putAsk >= q.putBid,
                      keys.insert(String(q.settlementAt.timeIntervalSince1970) + "/" + q.strike.decimalString).inserted
                else { throw OptionLabRiskError.invalidStraddle }
            }
        }
        if let e = assumptions.dividend {
            try source(e.source, createdAt: input.createdAt)
            try eventVersion(e.eventVersion, announcedAt: e.announcedAt, asOf: input.asOf)
            _ = try day(e.exDate)
            guard e.currency == "USD", e.amountPerShare.map({ $0.amount >= 0 }) ?? true else { throw OptionLabRiskError.invalidEvent }
            if let date = e.paymentAt {
                guard finite(date), marketDate(date) >= e.exDate else { throw OptionLabRiskError.invalidEvent }
            }
            if let c = e.calendar { try calendar(c, createdAt: input.createdAt) }
        }
    }

    private static func liquidity(_ leg: OptionLabLeg, evidence: OptionLabLiquidityInput?, asOf: Date) throws -> OptionLabLegLiquidity {
        let weights = [3000,2000,1500,1500,1000,1000]
        var components: [OptionLabLiquidityComponent] = [], hard: [String] = []
        func component(_ f: OptionLabLiquidityFactor, _ value: Money?, _ tier: Int?, _ reason: String? = nil) {
            let index = OptionLabLiquidityFactor.allCases.firstIndex(of: f)!
            components.append(.init(factor: f, weightBasisPoints: weights[index], value: value,
                grade: tier.map { [.excellent,.acceptable,.weak,.avoid][$0] } ?? .dataInsufficient,
                score: tier.map { [100,70,30,0][$0] }, reason: reason))
        }
        guard leg.bid.map({ $0.amount >= 0 }) != false, leg.ask.map({ $0.amount > 0 }) != false,
              leg.bidSize.map({ $0 >= 0 }) != false, leg.askSize.map({ $0 >= 0 }) != false,
              leg.quantity > 0, finite(leg.quotedAt), finite(asOf), leg.quotedAt <= asOf
        else { throw OptionLabRiskError.invalidInput }
        if let bid = leg.bid, let ask = leg.ask {
            let mid = try bid.adding(ask).multiplied(by: "0.5")
            if bid > ask {
                hard.append("报价倒挂")
                component(.relativeSpread, nil, 3, "报价倒挂")
            } else {
                let spread = try ask.subtracting(bid)
                let tier = try spread <= mid.multiplied(by: "0.05") ? 0 : spread <= mid.multiplied(by: "0.10") ? 1 : spread <= mid.multiplied(by: "0.20") ? 2 : 3
                component(.relativeSpread, try spread.divided(by: mid.decimalString), tier)
            }
        } else { component(.relativeSpread, nil, nil, "未补充 Bid／Ask，单个成交价不能证明价差") }
        if let evidence, let oi = evidence.openInterest, let age = evidence.oiSessionsAgo,
           evidence.oiIsLatestPublished, age <= 2 {
            component(.openInterest, try Money(String(oi)), oi >= 1000 ? 0 : oi >= 100 ? 1 : oi >= 10 ? 2 : 3)
        } else { component(.openInterest, nil, nil, "缺少最近已发布且不超过两个交易会话的 OI 证据") }
        if let volume = evidence?.volume, evidence?.volumeBasis != .unverified {
            component(.volume, try Money(String(volume)), volume >= 100 ? 0 : volume >= 10 ? 1 : volume >= 1 ? 2 : 3)
        } else { component(.volume, nil, nil, "缺少同会话全日或同 elapsed-time 可比成交量") }
        let age = asOf.timeIntervalSince(leg.quotedAt)
        if leg.bid != nil, leg.ask != nil {
            component(.quoteAge, try decimal(age), age <= 15 ? 0 : age <= 30 ? 1 : age <= 60 ? 2 : 3)
            if age > 60 { hard.append("报价超过 60 秒") }
        } else { component(.quoteAge, nil, nil, "未补充双边报价，价格输入时刻不是双边报价新鲜度") }
        if let bidSize = leg.bidSize, let askSize = leg.askSize, leg.bid != nil, leg.ask != nil {
            let size = min(bidSize, askSize)
            component(.size, try Money(String(size)), size >= 10 ? 0 : size >= 5 ? 1 : size >= 1 ? 2 : 3)
            if size < leg.quantity { hard.append("双边数量未覆盖拟研究张数") }
        } else { component(.size, nil, nil, "未补充完整双边深度，未知张数不按零或足量处理") }
        let continuity = try continuity(leg, evidence: evidence, asOf: asOf)
        if let continuity { try component(.neighborContinuity, continuity, continuity.amount == 0 ? 0 : continuity <= Money("0.25") ? 1 : continuity <= Money("0.5") ? 2 : 3) }
        else { component(.neighborContinuity, nil, nil, "缺少已声明完整的同到期同方向左右最近有效邻点") }
        if components.contains(where: { $0.grade == .avoid }) { hard.append("至少一个分项为 Avoid") }
        let coverage = components.filter { $0.score != nil }.reduce(0) { $0 + $1.weightBasisPoints }
        let weighted = components.reduce(0) { $0 + ($1.score ?? 0) * $1.weightBasisPoints }
        let score = coverage == 10000 ? try Money(String(weighted)).divided(by: "10000") : nil
        let grade: OptionLabLiquidityGrade
        if !hard.isEmpty { grade = .avoid }
        else if let score { grade = score.amount >= 85 ? .excellent : score.amount >= 60 ? .acceptable : score.amount >= 30 ? .weak : .avoid }
        else { grade = .dataInsufficient }
        return .init(contractID: leg.contractID, components: components, coverageBasisPoints: coverage, score: score, grade: grade, hardDowngrades: hard)
    }

    private static func continuity(_ leg: OptionLabLeg, evidence: OptionLabLiquidityInput?, asOf: Date) throws -> Money? {
        guard let evidence else { return nil }
        for n in evidence.neighbors {
            guard n.contractID != leg.contractID, n.symbol == leg.symbol, n.right == leg.right,
                  n.expirationDate == leg.expirationDate, n.strike.amount > 0, n.strike != leg.strike,
                  n.multiplier == leg.multiplier, n.delivery == leg.delivery, n.exerciseStyle == leg.exerciseStyle,
                  n.specificationVersion == leg.specificationVersion,
                  n.enteredPrice == nil, let bid = n.bid, let ask = n.ask,
                  let bidSize = n.bidSize, let askSize = n.askSize,
                  bid.amount >= 0, ask.amount > 0, bidSize >= 0, askSize >= 0,
                  finite(n.quotedAt), finite(n.receivedAt), n.receivedAt >= n.quotedAt
            else { throw OptionLabRiskError.invalidNeighbor }
        }
        guard evidence.neighborsComplete, leg.bid != nil, leg.ask != nil,
              let currentTick = leg.tick, currentTick.amount > 0,
              let lower = evidence.neighbors.filter({ $0.strike < leg.strike }).max(by: { $0.strike < $1.strike }),
              let upper = evidence.neighbors.filter({ $0.strike > leg.strike }).min(by: { $0.strike < $1.strike }) else { return nil }
        // Choose true adjacent strikes before testing their quality; no distant replacement.
        for n in [lower,upper] {
            guard let tick = n.tick, tick.amount > 0, let bid = n.bid, let ask = n.ask,
                  let bidSize = n.bidSize, let askSize = n.askSize, ask >= bid, min(bidSize,askSize) > 0,
                  n.quotedAt <= asOf, n.receivedAt <= asOf, asOf.timeIntervalSince(n.quotedAt) <= 60,
                  abs(n.quotedAt.timeIntervalSince(leg.quotedAt)) <= 5 else { return nil }
        }
        let triplet = [lower,leg,upper]
        var violations = 0
        for index in 0..<2 {
            let left = triplet[index], right = triplet[index+1]
            guard let leftBid = left.bid, let leftAsk = left.ask, let rightBid = right.bid, let rightAsk = right.ask else { return nil }
            // Continuity always compares quote mids, including a manually priced
            // current leg; its entered premium never masquerades as a neighbor quote.
            let leftMid = try leftBid.adding(leftAsk).multiplied(by: "0.5"), rightMid = try rightBid.adding(rightAsk).multiplied(by: "0.5")
            guard let lt = left.tick, let rt = right.tick else { return nil }
            let tick = min(lt,rt)
            let change = try leg.right == .call ? rightMid.subtracting(leftMid) : leftMid.subtracting(rightMid)
            if change > tick { violations += 1 }
        }
        return try Money(String(violations)).divided(by: "2")
    }

    private static func earnings(_ e: OptionLabEarningsInput?, input: OptionLabInput, spot: Money) throws -> OptionLabEarningsReport {
        func result(_ state: OptionLabRiskEvidenceState, start: Date? = nil, end: Date? = nil,
                    overlap: Bool? = nil, quote: OptionLabStraddleQuote? = nil, move: Money? = nil,
                    notes: [String]) throws -> OptionLabEarningsReport {
            .init(state: state, eventVersion: e?.eventVersion, calendarVersion: e?.calendar?.version,
                windowStart: start, windowEnd: end, holdingOverlaps: overlap,
                allowsHoldingAcrossEvent: e?.allowsHoldingAcrossEvent,
                expectedMove: move, expectedMoveFraction: try move?.divided(by: spot.decimalString),
                selectedStraddle: quote, historicalEventCount: 0, historicalFrequency: nil,
                warnings: notes + ["仅核对所填事件，不代表完整财报事件覆盖；没有历史事件样本、IV 溢价或 IV Crush 统计。"])
        }
        guard let e, e.certainty == .confirmed, e.timing != .unknown, let c = e.calendar,
              let current = c.sessions.first(where: { $0.date == e.eventDate }), let close = current.closesAt,
              c.sessions.allSatisfy({ $0.state != .unknown }) else {
            return try result(.dataInsufficient, notes: ["缺少已确认事件时段或完整日历版本，不能推断没有财报风险。"])
        }
        let start: Date, end: Date, eventUpperBound: Date
        if e.timing == .afterMarket {
            guard let next = c.sessions.filter({ $0.date > e.eventDate && $0.closesAt != nil }).min(by: { $0.date < $1.date }), let nextClose = next.closesAt, let nextOpen = next.opensAt else {
                return try result(.dataInsufficient, notes: ["完整窗口缺少下一交易日收盘。"])
            }
            start = close; end = nextClose; eventUpperBound = nextOpen
        } else {
            guard let previous = c.sessions.filter({ $0.date < e.eventDate && $0.closesAt != nil }).max(by: { $0.date < $1.date }), let previousClose = previous.closesAt else {
                return try result(.dataInsufficient, notes: ["完整窗口缺少前一交易日收盘。"])
            }
            start = previousClose; end = close
            guard let open = current.opensAt else { throw OptionLabRiskError.invalidCalendar }
            eventUpperBound = e.timing == .beforeMarket ? open : close
        }
        let overlap = input.asOf < end && input.expiry.settlementAt > start
        var notes = [e.timing == .duringMarket ? "盘中财报单列；前收盘至当日收盘不是纯事件收益。" : "财报窗口按所填日历实际收盘建立。"]
        if overlap { notes.append(e.allowsHoldingAcrossEvent == false ? "持有期与事件分析窗口重叠，且用户未允许跨财报；不据此推断实际发布时间。" : "持有期与事件分析窗口重叠；实际发布时间仍按所填时段，隔夜跳空与 IV 回落需独立情景评估。") }
        guard e.straddleCoverageComplete, input.asOf <= start else {
            notes.append("缺少完整候选链或已进入事件窗口，不给事件前 Expected Move。")
            return try result(overlap ? .available : .outsideHoldingWindow, start: start, end: end, overlap: overlap, notes: notes)
        }
        let candidates = e.straddles.filter { $0.settlementAt > eventUpperBound }
        guard let expiry = candidates.map(\.settlementAt).min() else {
            notes.append("没有保守事件发生上界之后仍有效的近期期权双边报价。")
            return try result(overlap ? .available : .outsideHoldingWindow, start: start, end: end, overlap: overlap, notes: notes)
        }
        // Exact geometric midpoint comparison is equivalent to abs(log(K/S));
        // avoiding binary logs preserves the lower-strike tie rule.
        var selected: OptionLabStraddleQuote?
        for q in candidates.filter({ $0.settlementAt == expiry }).sorted(by: { $0.strike < $1.strike }) {
            guard let prior = selected else { selected = q; continue }
            let better: Bool
            if q.strike <= spot { better = true }
            else if prior.strike >= spot { better = false }
            else { better = try spot.multiplied(by: spot.decimalString) > prior.strike.multiplied(by: q.strike.decimalString) }
            if better { selected = q }
        }
        guard let selected else { throw OptionLabRiskError.invalidStraddle }
        guard selected.quotedAt <= input.asOf, input.asOf.timeIntervalSince(selected.quotedAt) <= 60,
              abs(selected.quotedAt.timeIntervalSince(input.underlying.quotedAt)) <= 5 else {
            notes.append("最近到期 ATM 报价未来或陈旧；不换用更远到期/行权价补出 Expected Move。")
            return try result(overlap ? .available : .outsideHoldingWindow, start: start, end: end, overlap: overlap, notes: notes)
        }
        let move = try selected.callBid.adding(selected.callAsk).adding(selected.putBid).adding(selected.putAsk).multiplied(by: "0.5")
        return try result(overlap ? .available : .outsideHoldingWindow, start: start, end: end, overlap: overlap, quote: selected, move: move, notes: notes)
    }

    private static func assignment(_ dividend: OptionLabDividendInput?, input: OptionLabInput,
                                   spot: Money, dte: Int) throws -> OptionLabAssignmentReport {
        let leg = input.shortLeg, zero = try Money("0")
        let intrinsic = max(zero, try leg.right == .call ? spot.subtracting(leg.strike) : leg.strike.subtracting(spot))
        let premium: Money
        if leg.isEnteredPrice { premium = try leg.valuationPrice() }
        else {
            // The risk module also diagnoses crossed quote evidence directly;
            // liquidity marks it Avoid. Preserve that legacy diagnostic path.
            guard let bid = leg.bid, let ask = leg.ask else { throw OptionLabRiskError.invalidInput }
            premium = try bid.adding(ask).multiplied(by: "0.5")
        }
        let extrinsic = try premium.subtracting(intrinsic)
        let deep = try leg.right == .put ? leg.strike >= spot.multiplied(by: "1.10") : spot >= leg.strike.multiplied(by: "1.10")
        let rate = try input.pricing.map { try number($0.rate) }
        let limited = deep || dte > 60 || (rate.map { $0 >= 0.05 } ?? false)
        var reasons = ["提前指派等级是启发式提示，不是实际行权概率；未实现美式 CRR 或离散股息定价。"]
        if dte <= 7 { reasons.append("DTE≤7，处于到期周。") }
        if deep { reasons.append("达到 1.10 深价内条件。") }
        if limited { reasons.append("深价内、长期限或高利率使欧式近似受限。") }
        if extrinsic.amount < 0 { reasons.append(input.usesEnteredPrices ? "所填成交价低于内在价值，外在价值为负；保留异常，不截成零。" : "Mid 低于内在价值，外在价值为负；保留异常，不截成零。") }
        func report(_ level: OptionLabAssignmentLevel, threshold: Double? = nil, pv: Double? = nil,
                    prior: MarketDate? = nil, note: String) -> OptionLabAssignmentReport {
            .init(contractID: leg.contractID, level: level, intrinsicValue: intrinsic, extrinsicValue: extrinsic,
                threshold: threshold, dividendPresentValue: pv, nearExpiry: dte <= 7, deepInTheMoney: deep,
                priorExDividendSession: prior, europeanApproximationLimited: limited, reasons: reasons + [note])
        }
        guard leg.exerciseStyle == .american else { return report(.notApplicable, note: "显式欧式合约没有美式提前行权路径。") }
        guard let rate else { return report(.dataInsufficient, note: "缺少明确无风险利率；不会代填利率判定阈值。") }
        if leg.right == .put {
            let t = input.expiry.settlementAt.timeIntervalSince(input.asOf) / 31_536_000
            let threshold = try number(leg.strike) * max(rate,0) * t
            guard threshold.isFinite else { throw OptionLabRiskError.invalidInput }
            return report(try number(extrinsic) < threshold ? .elevated : .noTrigger, threshold: threshold,
                note: "比较外在价值与 K×max(r,0)×精确定价 T；未触发不代表无风险。")
        }
        guard let dividend, dividend.certainty == .confirmed, let amount = dividend.amountPerShare,
              let payment = dividend.paymentAt, let c = dividend.calendar,
              c.sessions.allSatisfy({ $0.state != .unknown }),
              let ex = c.sessions.first(where: { $0.date == dividend.exDate }), let exOpen = ex.opensAt,
              let previous = c.sessions.filter({ $0.date < dividend.exDate && $0.closesAt != nil }).max(by: { $0.date < $1.date }) else {
            return report(.dataInsufficient, note: "缺少已知股息、支付日或完整除息前交易日日历；无证据不等于无风险。")
        }
        guard marketDate(input.asOf) == previous.date, input.expiry.settlementAt > exOpen,
              payment > input.asOf else { return report(.notApplicable, prior: previous.date, note: "不在所填除息日前一交易日/持有期内，此时不套用该 Call 判据。") }
        let pv = try number(amount) * exp(-rate * payment.timeIntervalSince(input.asOf) / 31_536_000)
        let threshold = pv * 0.9
        guard pv.isFinite, threshold.isFinite else { throw OptionLabRiskError.invalidInput }
        return report(try number(extrinsic) < threshold ? .high : .noTrigger, threshold: threshold, pv: pv,
            prior: previous.date, note: "除息前一交易日比较外在价值与 0.9×明确现金股息现值；连续股息率不代替现金股息证据。")
    }

    private static func calendar(_ c: OptionLabRiskCalendar, createdAt: Date) throws {
        try source(c.source, createdAt: createdAt)
        guard nonblank(c.version), c.from <= c.through, !c.sessions.isEmpty, c.sessions.count <= 800 else { throw OptionLabRiskError.invalidCalendar }
        let from = try day(c.from), through = try day(c.through)
        let count = Int(through.timeIntervalSince(from) / 86400) + 1
        guard count == c.sessions.count, Set(c.sessions.map(\.date)).count == count else { throw OptionLabRiskError.invalidCalendar }
        for (index, session) in c.sessions.sorted(by: { $0.date < $1.date }).enumerated() {
            guard try day(session.date) == from.addingTimeInterval(Double(index)*86400) else { throw OptionLabRiskError.invalidCalendar }
            switch session.state {
            case .regular, .earlyClose:
                guard let open = session.opensAt, let close = session.closesAt, finite(open), finite(close), open < close,
                      marketDate(open) == session.date, marketDate(close) == session.date else { throw OptionLabRiskError.invalidCalendar }
            case .closed, .unknown:
                guard session.opensAt == nil, session.closesAt == nil else { throw OptionLabRiskError.invalidCalendar }
            }
        }
    }
    private static func source(_ source: OptionLabSource, createdAt: Date) throws {
        guard nonblank(source.reference), source.reference.utf8.count <= 4096,
              finite(source.enteredAt), source.enteredAt <= createdAt else { throw OptionLabRiskError.invalidInput }
    }
    private static func eventVersion(_ version: String, announcedAt: Date, asOf: Date) throws {
        guard nonblank(version), finite(announcedAt), announcedAt <= asOf else { throw OptionLabRiskError.invalidEvent }
    }
    private static func nonblank(_ s: String) -> Bool { !s.isEmpty && s == s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func finite(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
    private static func day(_ value: MarketDate) throws -> Date { try value.start(in: TimeZone(secondsFromGMT: 0)!) }
    private static func marketDate(_ date: Date) -> MarketDate {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return .init(year: calendar.component(.year, from: date), month: calendar.component(.month, from: date), day: calendar.component(.day, from: date))
    }
    private static func decimal(_ value: Double) throws -> Money {
        guard value.isFinite else { throw OptionLabRiskError.invalidInput }
        return try Money(String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value))
    }
    private static func number(_ value: Money) throws -> Double {
        guard let result = Double(value.decimalString), result.isFinite else { throw OptionLabRiskError.invalidInput }
        return result
    }
    private static func severity(_ grade: OptionLabLiquidityGrade) -> Int {
        switch grade { case .excellent: 0; case .acceptable: 1; case .weak: 2; case .dataInsufficient: 3; case .avoid: 4 }
    }
    private static let warnings = [
        "手工/合成离线假设，不代表官方日历、PIT 可得性、供应商准入或实时可成交性。",
        "流动性阈值是 PARAMETERS_V1 启发式；缺项保持缺项，跨腿取最差等级与最低完整得分。",
        "没有历史财报分布、真实世界概率、Bootstrap、预测或自动交易；无事件证据不能解释为无风险。"
    ]
    private static func notices(enteredPrices: Bool) -> [String] {
        guard enteredPrices else { return warnings }
        return warnings + ["单价模式的外在价值使用所填权利金；流动性只读取额外提供的双边报价及证据，缺少价差、深度或邻点时不评分，不把计划价当作实际市场报价。"]
    }
}
