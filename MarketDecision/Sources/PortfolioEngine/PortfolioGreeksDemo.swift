import Foundation
import CoreDomain
import DataContracts
import OptionsAnalytics

/// Explicit isolated ledger and report evidence. It is never written into a user's ledger.
public enum PortfolioGreeksDemo {
    public static let accountID = "SYNTHETIC-PORTFOLIO-GREEKS"
    public static func input(includeMissing: Bool = true, at: Date = Date(timeIntervalSince1970: 1_791_903_600)) throws -> PortfolioGreeksInput {
        let first = try sourceReport(symbol: "DEMO", strike: "100", right: .call, at: at,
            id: UUID(uuidString: "C035AA00-2026-4018-8000-000000000101")!)
        let second = try sourceReport(symbol: "ALT", strike: "50", right: .put, at: at,
            id: UUID(uuidString: "C035AA00-2026-4018-8000-000000000102")!)
        let stock = LedgerSecurity(id: "SYNTHETIC-DEMO", symbol: "DEMO"), alt = LedgerSecurity(id: "SYNTHETIC-ALT", symbol: "ALT")
        let firstOption = try option(first, security: stock), secondOption = try option(second, security: alt)
        var events: [LedgerEvent] = []
        func add(_ id: String, _ instrument: LedgerInstrument, side: LedgerSide, quantity: String, price: String) throws {
            let strategy: LedgerStrategy?
            if case .option = instrument {
                strategy = .init(id: "SYNTHETIC-EXPOSURE", purpose: .hedgeOrManage, successDefinition: "Synthetic sensitivity weighting only")
            } else { strategy = nil }
            events.append(.init(id: id, accountID: accountID, effectiveAt: at.addingTimeInterval(-3600),
                source: .init(sourceSystem: "SYNTHETIC-PORTFOLIO-GREEKS", externalTransactionID: id, evidence: "Synthetic position, not a broker transaction"),
                payload: .trade(.init(instrument: instrument, side: side, effect: .open, quantity: try Money(quantity),
                    unitPrice: try Money(price), fee: try Money("0"), openingLotID: id + "-lot", strategy: strategy))))
        }
        try add("stock-long", .equity(stock), side: .buy, quantity: "12.5", price: "100")
        try add("stock-alt", .equity(alt), side: .buy, quantity: "3.25", price: "50")
        try add("call-long", .option(firstOption), side: .buy, quantity: "2", price: "2.2")
        try add("call-short", .option(firstOption), side: .sell, quantity: "1", price: "2.2")
        try add("put-short", .option(secondOption), side: .sell, quantity: "1", price: "2.2")
        if includeMissing { try add("uncovered", .equity(.init(id: "SYNTHETIC-GAP", symbol: "GAP")), side: .buy, quantity: "4.25", price: "20") }
        return .init(id: UUID(uuidString: includeMissing ? "C035AA00-2026-4018-8000-000000000104" : "C035AA00-2026-4018-8000-000000000100")!, createdAt: at.addingTimeInterval(2), asOf: at,
            mode: .synthetic, accountID: accountID, ledgerRevision: UUID(uuidString: "C035AA00-2026-4018-8000-000000000103")!,
            accounts: [.init(id: accountID, name: "合成组合示例")], events: events, reports: [first, second],
            bindings: [.init(instrumentIdentity: LedgerInstrument.equity(stock).identity, reportID: first.input.id),
                       .init(instrumentIdentity: LedgerInstrument.equity(alt).identity, reportID: second.input.id),
                       .init(instrumentIdentity: LedgerInstrument.option(firstOption).identity, reportID: first.input.id, contractID: first.input.shortLeg.contractID),
                       .init(instrumentIdentity: LedgerInstrument.option(secondOption).identity, reportID: second.input.id, contractID: second.input.shortLeg.contractID)])
    }
    private static func sourceReport(symbol: String, strike: String, right: OptionLabRight, at: Date, id: UUID) throws -> OptionLabReport {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        guard let settlement = cal.date(byAdding: .day, value: 30, to: at) else { throw PortfolioGreeksError.invalidInput }
        let expiry = MarketDate(year: cal.component(.year, from: settlement), month: cal.component(.month, from: settlement), day: cal.component(.day, from: settlement))
        let source = OptionLabSource(origin: .synthetic, reference: "SYNTHETIC-PORTFOLIO-GREEKS; explicit quotes and contract assumptions", enteredAt: at)
        let strikeMoney = try Money(strike)
        guard let wholeStrike = Int(strike) else { throw PortfolioGreeksError.invalidInput }
        let strikeInt = wholeStrike * 1000
        let occ = symbol.padding(toLength: 6, withPad: " ", startingAt: 0) + String(format: "%02d%02d%02d", expiry.year % 100, expiry.month, expiry.day) + (right == .call ? "C" : "P") + String(format: "%08d", strikeInt)
        let leg = OptionLabLeg(contractID: occ, symbol: symbol, right: right, strike: strikeMoney,
            specificationVersion: "assumed-us-equity-standard.v1", quantity: 9, expirationDate: expiry,
            bid: try Money("2"), ask: try Money("2.4"), bidSize: 100, askSize: 100, tick: try Money("0.01"),
            quotedAt: at, receivedAt: at, source: source)
        let input = OptionLabInput(id: id, createdAt: at.addingTimeInterval(1), asOf: at,
            strategy: right == .call ? .coveredCall : .cashSecuredPut, shortLeg: leg, longLeg: nil,
            underlying: .init(symbol: symbol, bid: try strikeMoney.subtracting(Money("0.1")), ask: try strikeMoney.adding(Money("0.1")), quotedAt: at, receivedAt: at, source: source),
            capital: .init(origin: .synthetic, reference: "SYNTHETIC-CAPITAL; never extra portfolio stock", asOf: at,
                cashBeforeTrade: try Money("200000"), committedCash: try Money("0"), availableShares: try Money("1000"), committedShares: try Money("0")),
            policy: try .defaults(), expiry: .init(date: expiry, settlementAt: settlement, source: source),
            scenarioPrices: try ["0", "50", "100", "150", "200"].map { try Money($0) },
            pricing: .init(rate: try Money("0.03"), dividendYield: try Money("0.01"), volatility: try Money("0.2"), source: source))
        return try OptionLabEngine.calculate(input)
    }
    private static func option(_ report: OptionLabReport, security: LedgerSecurity) throws -> LedgerOptionVersion {
        let leg = report.input.shortLeg
        return .init(occSymbol: leg.contractID, versionID: leg.specificationVersion,
            effectiveFrom: report.input.asOf.addingTimeInterval(-86400), quoteMultiplier: try Money("100"),
            exerciseConsideration: try leg.strike.multiplied(by: "100"),
            deliverables: [.init(security: security, quantity: try Money("100"), basisWeight: try Money("1"))],
            deliverableCash: try Money("0"), exerciseStyle: .american,
            tradingEndsAt: report.input.expiry.settlementAt, exerciseDeadline: report.input.expiry.settlementAt,
            settlementAt: report.input.expiry.settlementAt, memoReferences: ["SYNTHETIC-STANDARD-CONTRACT; no OCC admission"])
    }
}
