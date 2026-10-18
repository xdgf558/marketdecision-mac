import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

/// CALC-034 offline aggregation. Ledger replay owns quantities/directions; local-IV
/// source reports own per-share derivatives. This does not admit market data or trading.
public enum PortfolioGreeksEngine {
    public static let schemaVersion = "portfolio-greeks-report.v1"
    public static let numericPolicyVersion = "portfolio-greeks.float64-weighted.v1"
    public static func definitions() throws -> (ParameterSet, ModelDefinition) {
        let parameters = ParameterSet(id: "portfolio.greeks.parameters", version: "PARAMETERS_V1.CALC034.v1",
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000001")!,
            values: ["maxQuoteAgeSeconds": .integer(60), "maxQuoteSkewSeconds": .integer(5),
                     "coverage": .text("Missing required row prevents complete summary; covered portion remains explicit"),
                     "weight": .text("signed ledger quantity times evidenced multiplier; equity delta equals shares"),
                     "crossUnderlying": .text("No raw Delta or Gamma total; delta dollars use own underlying spot"),
                     "theta": .text("USD per calendar day"), "vegaRho": .text("USD per simultaneous one percentage-point own sigma/rate shock")],
            state: .approved, dispositionReference: "PARAMETERS_V1:CALC-034;RISK-001")
        let model = ModelDefinition(id: "portfolio.greeks", version: schemaVersion,
            revisionID: UUID(uuidString: "C035AA00-2026-4018-8000-000000000002")!, owner: "PortfolioEngine",
            purpose: "Frozen ledger and replayed local-IV references; offline covered-position risk research",
            inputs: [.init(name: "ledgerAndExplicitOptionReportBindings", unit: "shares+contracts+USD", role: .required)],
            outputs: [.init(name: "coveredAndCompleteGreeks", unit: "explicit-unit-greeks")],
            formula: "units=signedLedgerQuantity*multiplier; rowGreek=units*canonicalPerShareGreek; equityDelta=signedShares; deltaUSD=deltaShares*ownSpot; grossDeltaUSD=sum(abs(rowDeltaUSD)); rawDelta/Gamma grouped by security and expiry only",
            formulaVersion: schemaVersion, implementationReference: "PortfolioEngine/PortfolioGreeksEngine.v1",
            defaultParameters: parameters.reference, numericPolicyVersion: numericPolicyVersion, state: .approved,
            dispositionReference: "PARAMETERS_V1:CALC-034", knownLimitations: limitations,
            testFixtures: ["PortfolioGreeksEngineTests"], introducedAt: try MillisecondInstant(iso8601: "2026-10-18T00:00:00.000Z"))
        try parameters.validate(); try model.validate(); return (parameters, model)
    }
    public static func calculate(_ input: PortfolioGreeksInput) throws -> PortfolioGreeksReport {
        try Task.checkCancellation()
        guard ledgerDate(input.createdAt), ledgerDate(input.asOf), input.createdAt >= input.asOf,
              input.accounts.count == 1, input.accounts.first?.id == input.accountID,
              input.events.allSatisfy({ $0.accountID == input.accountID }),
              input.reports.allSatisfy({ $0.input.createdAt <= input.createdAt }) else { throw PortfolioGreeksError.invalidInput }
        guard Set(input.bindings.map(\.instrumentIdentity)).count == input.bindings.count else { throw PortfolioGreeksError.duplicateBinding }
        guard Set(input.reports.map { $0.input.id }).count == input.reports.count else { throw PortfolioGreeksError.duplicateReport }
        guard input.bindings.allSatisfy({ ledgerText($0.instrumentIdentity) && ($0.contractID.map(ledgerText) ?? true) }) else { throw PortfolioGreeksError.invalidInput }
        // Validate the frozen append log, including later events, before deriving this effective-time view.
        _ = try LedgerEngine.replay(accounts: input.accounts, events: input.events)
        let state = try LedgerEngine.replay(accounts: input.accounts, events: input.events.filter { $0.effectiveAt <= input.asOf })
        let lots = state.lots.filter { !$0.isClosed }.sorted { $0.id < $1.id }
        let identities = Set(lots.map { $0.instrument.identity })
        guard input.bindings.allSatisfy({ identities.contains($0.instrumentIdentity) }) else { throw PortfolioGreeksError.unknownBinding }
        var reports: [UUID: OptionLabReport] = [:]
        for report in input.reports {
            try Task.checkCancellation()
            if input.mode == .ledger, try containsSynthetic(report) { throw PortfolioGreeksError.syntheticEvidence }
            do { reports[report.input.id] = try OptionLabEngine.replay(report) }
            catch is CancellationError { throw CancellationError() }
            catch { throw PortfolioGreeksError.incompatibleReport }
        }
        let bindings = Dictionary(uniqueKeysWithValues: input.bindings.map { ($0.instrumentIdentity, $0) })
        var rows = try lots.map { try row($0, input: input, binding: bindings[$0.instrument.identity], reports: reports) }
        // One underlying cannot silently carry two spots or independently timed quotes in one report.
        let underlyings = Dictionary(grouping: rows, by: \.underlyingID)
        for (id, sameUnderlying) in underlyings {
            let quotes = sameUnderlying.compactMap { row -> OptionLabUnderlying? in
                guard row.values != nil, let reportID = row.reportID else { return nil }
                return reports[reportID]?.input.underlying
            }
            guard let first = quotes.first else { continue }
            let coherent = quotes.allSatisfy { $0.symbol == first.symbol && $0.asset == first.asset && $0.bid == first.bid && $0.ask == first.ask && $0.quotedAt == first.quotedAt && $0.receivedAt == first.receivedAt }
            if !coherent {
                rows = rows.map { $0.underlyingID == id && $0.values != nil ? gapRow($0, gap: .inconsistentUnderlying) : $0 }
            }
        }
        let groups = try Dictionary(grouping: rows, by: groupKey).sorted { $0.key < $1.key }.map { key, entries in
            let first = entries[0], coverage = coverage(entries)
            let covered = try sum(entries.compactMap(\.values))
            return PortfolioGreeksGroup(id: key, underlyingID: first.underlyingID, underlyingSymbol: first.underlyingSymbol,
                expirationDate: first.expirationDate, coverage: coverage, covered: covered, complete: coverage.isComplete ? covered : nil)
        }
        let coverage = coverage(rows), totals = try totals(rows.compactMap(\.values))
        let (parameters, model) = try definitions()
        return PortfolioGreeksReport(schemaVersion: schemaVersion, input: input, model: model, parameters: parameters,
            ledgerState: state, rows: rows, groups: groups, coverage: coverage, coveredTotals: totals,
            completeTotals: coverage.isComplete ? totals : nil, researchOnly: true, limitations: limitations)
    }
    public static func replay(_ report: PortfolioGreeksReport) throws -> PortfolioGreeksReport {
        guard report.schemaVersion == schemaVersion else { throw PortfolioGreeksError.incompatibleReport }
        let expected = try calculate(report.input)
        guard expected == report else { throw PortfolioGreeksError.incompatibleReport }
        return expected
    }
    private static func row(_ lot: LedgerLot, input: PortfolioGreeksInput, binding: PortfolioGreeksBinding?, reports: [UUID: OptionLabReport]) throws -> PortfolioGreeksRow {
        let signed = try lot.quantityRemaining.multiplied(by: lot.side == .long ? "1" : "-1")
        let underlyingID: String, symbol: String, expiry: MarketDate?, multiplier: Money
        switch lot.instrument {
        case .equity(let security): underlyingID = security.id; symbol = security.symbol; expiry = nil; multiplier = try Money("1")
        case .option(let option):
            underlyingID = option.deliverables.count == 1 ? option.deliverables[0].security.id : "unsupported:" + lot.instrument.identity
            symbol = option.deliverables.count == 1 ? option.deliverables[0].security.symbol : lot.instrument.label
            expiry = occExpiry(option.occSymbol); multiplier = option.quoteMultiplier
        }
        func result(_ gap: PortfolioGreeksGap?, _ values: PortfolioGreeksValues? = nil, _ spot: Money? = nil) -> PortfolioGreeksRow {
            .init(id: lot.id, instrument: lot.instrument, underlyingID: underlyingID, underlyingSymbol: symbol,
                expirationDate: expiry, signedQuantity: signed, multiplier: multiplier, reportID: binding?.reportID,
                contractID: binding?.contractID, underlyingMid: spot, values: values, gap: gap)
        }
        guard let binding else { return result(.missingBinding) }
        guard let report = reports[binding.reportID] else { return result(.missingReport) }
        guard report.input.asOf == input.asOf else { return result(.mismatchedAsOf) }
        let underlying = report.input.underlying
        guard underlying.symbol == symbol else { return result(.mismatchedContract) }
        guard validClock(underlying.quotedAt, received: underlying.receivedAt, asOf: input.asOf) else { return result(.staleQuote) }
        let spot = report.underlyingMid
        let values: PortfolioGreeksValues
        switch lot.instrument {
        case .equity(let security):
            guard binding.contractID == nil, (security.kind == .stock ? OptionLabAsset.stock : .etf) == underlying.asset else { return result(.mismatchedContract) }
            let delta = try number(signed)
            values = .init(deltaShares: delta, gammaSharesPerDollar: 0, thetaDollarsPerDay: 0,
                vegaDollarsPerPercentagePoint: 0, rhoDollarsPerPercentagePoint: 0, deltaDollars: delta * (try number(spot)))
        case .option(let option):
            guard option.deliverables.count == 1, option.settlementType == .physicalEquity,
                  option.deliverableCash.amount == 0, option.deliverables[0].quantity == (try Money("100")),
                  option.deliverables[0].basisWeight == (try Money("1")), option.quoteMultiplier == (try Money("100")) else { return result(.unsupportedContract) }
            guard let contractID = binding.contractID,
                  let leg = ([report.input.shortLeg] + (report.input.longLeg.map { [$0] } ?? [])).first(where: { $0.contractID == contractID }) else { return result(.missingContract) }
            let occ = leg.contractID.replacingOccurrences(of: " ", with: "")
            let expectedOCC = option.occSymbol.replacingOccurrences(of: " ", with: "")
            guard occ == expectedOCC, leg.symbol == symbol, leg.expirationDate == expiry,
                  leg.strike == (try occStrike(option.occSymbol)), leg.multiplier == 100,
                  (leg.right == .call ? LedgerOptionRight.call : .put) == option.right,
                  (leg.exerciseStyle == .american ? LedgerExerciseStyle.american : .european) == option.exerciseStyle,
                  leg.delivery == .standardPhysical100Shares, leg.specificationVersion == option.versionID,
                  report.input.expiry.settlementAt == option.settlementAt,
                  option.effectiveFrom <= input.asOf, option.effectiveTo.map({ input.asOf < $0 }) ?? true,
                  option.tradingEndsAt > input.asOf, option.exerciseConsideration == (try leg.strike.multiplied(by: option.quoteMultiplier.decimalString)),
                  (option.deliverables[0].security.kind == .stock ? OptionLabAsset.stock : .etf) == underlying.asset else { return result(.mismatchedContract) }
            guard validClock(leg.quotedAt, received: leg.receivedAt, asOf: input.asOf), abs(leg.quotedAt.timeIntervalSince(underlying.quotedAt)) <= 5 else { return result(.staleQuote) }
            guard let pricing = report.pricing else { return result(.missingPricing) }
            guard let price = pricing.legs.first(where: { $0.contractID == contractID }), price.impliedVolatility.state == .available,
                  let greek = price.canonicalGreeks else { return result(.missingIV) }
            let weight = try number(signed.multiplied(by: multiplier.decimalString))
            values = .init(deltaShares: greek.delta * weight, gammaSharesPerDollar: greek.gamma * weight,
                thetaDollarsPerDay: greek.thetaPerDay * weight, vegaDollarsPerPercentagePoint: greek.vegaPerPercentagePoint * weight,
                rhoDollarsPerPercentagePoint: greek.rhoPerPercentagePoint * weight, deltaDollars: greek.delta * weight * (try number(spot)))
        }
        guard finite(values) else { throw PortfolioGreeksError.numericFailure }
        return result(nil, values, spot)
    }
    private static func validClock(_ quote: Date, received: Date, asOf: Date) -> Bool {
        ledgerDate(quote) && ledgerDate(received) && quote <= received && received <= asOf && asOf.timeIntervalSince(quote) <= 60
    }
    private static func occExpiry(_ occ: String) -> MarketDate? {
        let s = String(occ.dropFirst(6).prefix(6))
        guard let y = Int(s.prefix(2)), let m = Int(s.dropFirst(2).prefix(2)), let d = Int(s.suffix(2)) else { return nil }
        return .init(year: 2000 + y, month: m, day: d)
    }
    private static func occStrike(_ occ: String) throws -> Money {
        guard let units = Int(occ.suffix(8)) else { throw PortfolioGreeksError.invalidInput }
        return try Money(String(units)).divided(by: "1000")
    }
    private static func number(_ money: Money) throws -> Double {
        guard let d = Double(money.decimalString), d.isFinite else { throw PortfolioGreeksError.numericFailure }; return d
    }
    private static func coverage(_ rows: [PortfolioGreeksRow]) -> PortfolioGreeksCoverage { .init(coveredPositions: rows.filter { $0.values != nil }.count, totalPositions: rows.count) }
    private static func groupKey(_ row: PortfolioGreeksRow) -> String {
        let e = row.expirationDate.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } ?? "equity"
        return "\(row.underlyingID.utf8.count):\(row.underlyingID):\(e)"
    }
    private static func gapRow(_ row: PortfolioGreeksRow, gap: PortfolioGreeksGap) -> PortfolioGreeksRow {
        .init(id: row.id, instrument: row.instrument, underlyingID: row.underlyingID, underlyingSymbol: row.underlyingSymbol,
            expirationDate: row.expirationDate, signedQuantity: row.signedQuantity, multiplier: row.multiplier,
            reportID: row.reportID, contractID: row.contractID, underlyingMid: nil, values: nil, gap: gap)
    }
    private static func finite(_ v: PortfolioGreeksValues) -> Bool { [v.deltaShares,v.gammaSharesPerDollar,v.thetaDollarsPerDay,v.vegaDollarsPerPercentagePoint,v.rhoDollarsPerPercentagePoint,v.deltaDollars].allSatisfy(\.isFinite) }
    private static func sum(_ values: [PortfolioGreeksValues]) throws -> PortfolioGreeksValues? {
        guard !values.isEmpty else { return nil }
        let result = PortfolioGreeksValues(deltaShares: values.reduce(0) { $0 + $1.deltaShares }, gammaSharesPerDollar: values.reduce(0) { $0 + $1.gammaSharesPerDollar },
            thetaDollarsPerDay: values.reduce(0) { $0 + $1.thetaDollarsPerDay }, vegaDollarsPerPercentagePoint: values.reduce(0) { $0 + $1.vegaDollarsPerPercentagePoint },
            rhoDollarsPerPercentagePoint: values.reduce(0) { $0 + $1.rhoDollarsPerPercentagePoint }, deltaDollars: values.reduce(0) { $0 + $1.deltaDollars })
        guard finite(result) else { throw PortfolioGreeksError.numericFailure }; return result
    }
    private static func totals(_ values: [PortfolioGreeksValues]) throws -> PortfolioGreeksTotals? {
        guard !values.isEmpty else { return nil }
        let result = PortfolioGreeksTotals(netDeltaDollars: values.reduce(0) { $0 + $1.deltaDollars }, grossDeltaDollars: values.reduce(0) { $0 + abs($1.deltaDollars) },
            thetaDollarsPerDay: values.reduce(0) { $0 + $1.thetaDollarsPerDay }, vegaDollarsPerPercentagePoint: values.reduce(0) { $0 + $1.vegaDollarsPerPercentagePoint }, rhoDollarsPerPercentagePoint: values.reduce(0) { $0 + $1.rhoDollarsPerPercentagePoint })
        guard [result.netDeltaDollars,result.grossDeltaDollars,result.thetaDollarsPerDay,result.vegaDollarsPerPercentagePoint,result.rhoDollarsPerPercentagePoint].allSatisfy(\.isFinite) else { throw PortfolioGreeksError.numericFailure }; return result
    }
    private static func containsSynthetic(_ report: OptionLabReport) throws -> Bool {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.input))
        func inspect(_ node: Any) -> Bool {
            if let d = node as? [String: Any] { return d["origin"] as? String == "synthetic" || d.values.contains(where: inspect) }
            if let a = node as? [Any] { return a.contains(where: inspect) }; return false
        }
        return inspect(json)
    }
    public static let limitations = [
        "仅离线研究：普通账本可使用明确的手动证据；合成示例独立，不授予实时、供应商、PIT、交易或风险限额资格。",
        "持仓由冻结账本修订按 effectiveAt 截止重放；没有原始 recordedAt，可含事后修订，不能称为历史可得快照。",
        "每腿 Greeks 只来自原报告本地 Mid 反解 IV；不采用策略总 Greeks、报告方向/张数、手工 sigma 或供应商 Greeks。",
        "只支持已精确对应的标准 100 股实物交割合约；美式仍是既有欧式连续股息参考，不含 CRR、离散股息或真实指派概率。",
        "各证据共用评估 asOf；每条报价须在此前 60 秒内，标的与各腿偏差至多 5 秒。同标的价格与报价时刻须一致；不同标的未承诺完全同步。",
        "覆盖按未平仓 lot 数计算，不是资金覆盖比例；缺证据不当零。完整汇总须全部持仓可算，已覆盖部分单列。",
        "不同标的不提供原始 Delta/Gamma 总数；delta dollars 按各自标的价格折算，gross 为各 lot 绝对值之和。",
        "Theta 为每自然日；Vega/Rho 为所有已覆盖持仓各自波动率/利率同时变化一个百分点的美元敏感度，不是协方差风险。",
        "无合格 NAV，故无 NAV 百分比；无 Beta、VaR、保证金或可执行限额。浮点重放不承诺跨 CPU/libm 逐位一致。"
    ]
}
