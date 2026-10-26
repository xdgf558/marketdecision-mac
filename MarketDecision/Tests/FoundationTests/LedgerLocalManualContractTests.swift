import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics
import PortfolioEngine

@Suite("Local manual option terms and evidence boundaries")
struct LedgerLocalManualContractTests {
    private let account = LedgerAccount(id: "manual-account", name: "Manual fixture")
    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
    private func local(_ occ: String = "ABC   261120P00100000") throws -> LedgerOptionVersion {
        .init(occSymbol: occ, versionID: "local-manual-standard.v1", effectiveFrom: nil,
            quoteMultiplier: try Money("100"), exerciseConsideration: try Money("10000"),
            deliverables: [.init(security: .init(id: "manual-ABC", symbol: "ABC"),
                quantity: try Money("100"), basisWeight: try Money("1"))], deliverableCash: try Money("0"),
            tradingEndsAt: nil, exerciseDeadline: nil, settlementAt: nil,
            memoReferences: ["User-declared standard contract; no official schedule evidence"],
            termsBasis: .localManualStandard)
    }
    private func object(_ value: LedgerOptionVersion) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func contract(_ object: [String: Any]) throws -> LedgerOptionVersion {
        try JSONDecoder().decode(LedgerOptionVersion.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private var strategy: LedgerStrategy {
        .init(id: "manual-strategy", purpose: .premiumIncome, successDefinition: "Net realized result is positive")
    }
    private func event(_ id: String, at: Date, _ payload: LedgerPayload) -> LedgerEvent {
        .init(id: id, accountID: account.id, effectiveAt: at,
            source: .init(sourceSystem: "manual-fixture", externalTransactionID: id,
                evidence: "Explicitly entered transaction or confirmed zero settlement"), payload: payload)
    }
    private func opening(_ terms: LedgerOptionVersion, at: Date) throws -> LedgerEvent {
        event("open", at: at, .trade(.init(instrument: .option(terms), side: .sell, effect: .open,
            quantity: try Money("1"), unitPrice: try Money("2"), fee: try Money("1"),
            openingLotID: "manual-lot", strategy: strategy)))
    }
    private func settlement(_ terms: LedgerOptionVersion, at: Date, action: LedgerSettlementAction = .expiration,
                            side: LedgerPositionSide = .short, evidence: String = "User confirmed zero settlement",
                            lotID: String = "manual-lot") throws -> LedgerEvent {
        event("settle", at: at, .optionSettlement(.init(contract: terms, action: action, side: side,
            quantity: try Money("1"), fee: try Money("0"),
            optionSelections: [.init(lotID: lotID, quantity: try Money("1"))], evidence: evidence)))
    }
    private func asLocal(_ terms: LedgerOptionVersion) -> LedgerOptionVersion {
        .init(occSymbol: terms.occSymbol, versionID: terms.versionID, effectiveFrom: nil,
            quoteMultiplier: terms.quoteMultiplier, exerciseConsideration: terms.exerciseConsideration,
            deliverables: terms.deliverables, deliverableCash: terms.deliverableCash,
            settlementType: terms.settlementType, exerciseStyle: terms.exerciseStyle,
            tradingEndsAt: nil, exerciseDeadline: nil, settlementAt: nil,
            memoReferences: terms.memoReferences, termsBasis: .localManualStandard)
    }
    private func localOptionTrades(_ events: [LedgerEvent]) -> [LedgerEvent] {
        events.map { value in
            guard case .trade(let trade) = value.payload, case .option(let terms) = trade.instrument else { return value }
            return .init(id: value.id, accountID: value.accountID, effectiveAt: value.effectiveAt,
                providerSequence: value.providerSequence, source: value.source,
                payload: .trade(.init(instrument: .option(asLocal(terms)), side: trade.side, effect: trade.effect,
                    quantity: trade.quantity, unitPrice: trade.unitPrice, fee: trade.fee,
                    openingLotID: trade.openingLotID, selections: trade.selections, strategy: trade.strategy)),
                rollGroupID: value.rollGroupID, multiLegGroupID: value.multiLegGroupID, notes: value.notes)
        }
    }
    private func legacyObject() throws -> [String: Any] {
        let source = #"{"occSymbol":"ABC   261120P00100000","versionID":"legacy.v1","effectiveFrom":0,"quoteMultiplier":"100","exerciseConsideration":"10000","deliverables":[{"security":{"id":"manual-ABC","symbol":"ABC","kind":"stock"},"quantity":"100","basisWeight":"1"}],"deliverableCash":"0","settlementType":"physicalEquity","exerciseStyle":"american","tradingEndsAt":1,"exerciseDeadline":2,"settlementAt":3,"memoReferences":["legacy-evidence"]}"#
        return try #require(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }

    @Test func localAndLegacyEncodingPreserveTheirDistinctEvidenceShapes() throws {
        let manual = try local()
        try manual.validate()
        let encoded = try object(manual)
        #expect(encoded["termsBasis"] as? String == "localManualStandard")
        for field in ["effectiveFrom", "effectiveTo", "tradingEndsAt", "exerciseDeadline", "settlementAt"] {
            #expect(encoded[field] == nil)
        }
        #expect(try contract(encoded) == manual)

        let oldShape = try legacyObject(), legacy = try contract(oldShape)
        try legacy.validate()
        #expect(!legacy.isLocalManualStandard && legacy.termsBasis == nil)
        let encodedLegacy = try object(legacy)
        #expect(encodedLegacy["termsBasis"] == nil)
        #expect(try JSONSerialization.data(withJSONObject: encodedLegacy, options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: oldShape, options: [.sortedKeys]))
    }

    @Test func missingLegacyDatesCannotDecodeIntoLocalPermission() throws {
        for field in ["effectiveFrom", "tradingEndsAt", "exerciseDeadline", "settlementAt"] {
            var oldShape = try legacyObject(); oldShape.removeValue(forKey: field)
            let incomplete = try contract(oldShape)
            #expect(!incomplete.isLocalManualStandard)
            #expect(throws: LedgerError.invalidContract) { try incomplete.validate() }
        }
        var lostMarker = try object(local()); lostMarker.removeValue(forKey: "termsBasis")
        #expect(throws: LedgerError.invalidContract) { try contract(lostMarker).validate() }
        var unknownMarker = try object(local()); unknownMarker["termsBasis"] = "officially-confirmed-by-software"
        #expect(throws: (any Error).self) { try contract(unknownMarker) }
    }

    @Test func localTermsRejectNonstandardDeliveryAndInventedOfficialTimes() throws {
        let base = try object(local())
        for (field, value) in [("quoteMultiplier", "10"), ("exerciseConsideration", "9999"),
                               ("deliverableCash", "1"), ("exerciseStyle", "european")] {
            var changed = base; changed[field] = value
            #expect(throws: LedgerError.invalidContract) { try contract(changed).validate() }
        }
        for field in ["effectiveFrom", "effectiveTo", "tradingEndsAt", "exerciseDeadline", "settlementAt"] {
            var changed = base; changed[field] = 1
            #expect(throws: LedgerError.invalidContract) { try contract(changed).validate() }
        }
        for (field, value) in [("quantity", "10"), ("basisWeight", "0.5")] {
            var changed = base
            var deliveries = try #require(changed["deliverables"] as? [[String: Any]])
            deliveries[0][field] = value; changed["deliverables"] = deliveries
            #expect(throws: LedgerError.invalidContract) { try contract(changed).validate() }
        }
        var wrongSymbol = base
        var deliveries = try #require(wrongSymbol["deliverables"] as? [[String: Any]])
        var security = try #require(deliveries[0]["security"] as? [String: Any])
        security["symbol"] = "XYZ"; deliveries[0]["security"] = security; wrongSymbol["deliverables"] = deliveries
        #expect(throws: LedgerError.invalidContract) { try contract(wrongSymbol).validate() }
        var cashSettled = base; cashSettled["settlementType"] = "cash"
        #expect(throws: LedgerError.unsupportedSettlement) { try contract(cashSettled).validate() }
        #expect(throws: LedgerError.invalidContract) { try local("ABC   260230P00100000").validate() }
    }

    @Test func newYorkCivilDateBoundsRespectSummerAndWinterOffsets() throws {
        for (occ, start, next) in [
            ("ABC   260717P00100000", "2026-07-17T04:00:00Z", "2026-07-18T04:00:00Z"),
            ("ABC   261120P00100000", "2026-11-20T05:00:00Z", "2026-11-21T05:00:00Z")
        ] {
            let terms = try local(occ), first = try date(start), following = try date(next)
            #expect(terms.allowsLocalManualTrade(at: first.addingTimeInterval(-0.001)))
            #expect(!terms.allowsLocalManualExpiration(at: first.addingTimeInterval(-0.001)))
            // The same civil day permits an explicitly confirmed zero-settlement
            // event; this is deliberately not a claim about official cutoff time.
            #expect(terms.allowsLocalManualTrade(at: first) && terms.allowsLocalManualExpiration(at: first))
            #expect(terms.allowsLocalManualTrade(at: following.addingTimeInterval(-0.001)))
            #expect(!terms.allowsLocalManualTrade(at: following))
            #expect(terms.allowsLocalManualExpiration(at: following))
            #expect(!terms.allowsLocalManualTrade(at: Date(timeIntervalSince1970: .infinity)))
        }
    }

    @Test func manualTradeAndExplicitZeroSettlementReplayWithoutAutomaticExpiry() throws {
        let terms = try local(), openAt = try date("2026-11-19T15:00:00Z")
        let open = try opening(terms, at: openAt)
        let retained = try LedgerEngine.replay(accounts: [account], events: [open])
        #expect(retained.lots.count == 1 && retained.lots[0].quantityRemaining == (try Money("1")))
        #expect(retained.realizations.isEmpty)
        let close = event("close", at: try date("2026-11-20T15:00:00Z"), .trade(.init(
            instrument: .option(terms), side: .buy, effect: .close, quantity: try Money("1"),
            unitPrice: try Money("0.5"), fee: try Money("1"),
            selections: [.init(lotID: "manual-lot", quantity: try Money("1"))])))
        let closed = try LedgerEngine.replay(accounts: [account], events: [open, close])
        #expect(closed.lots[0].isClosed && closed.realizations[0].pnl == (try Money("148")))
        let expired = try settlement(terms, at: date("2026-11-20T05:00:00Z"))
        let settled = try LedgerEngine.replay(accounts: [account], events: [open, expired])
        #expect(settled.lots[0].isClosed && settled.realizations[0].pnl == (try Money("199")))
        #expect(throws: LedgerError.invalidContract) {
            try settlement(terms, at: date("2026-11-20T04:59:59Z")).validate()
        }
        #expect(throws: LedgerError.invalidEvidence) {
            try settlement(terms, at: date("2026-11-20T05:00:00Z"), evidence: "").validate()
        }
        #expect(throws: LedgerError.invalidLotSelection) {
            try LedgerEngine.replay(accounts: [account], events: [open,
                settlement(terms, at: date("2026-11-20T05:00:00Z"), lotID: "unrelated-lot")])
        }
        #expect(throws: LedgerError.invalidContract) {
            try opening(terms, at: date("2026-11-21T05:00:00Z")).validate()
        }
    }

    @Test func localTermsCannotAuthorizeDeliveryTransferOrAdjustment() throws {
        let terms = try local(), at = try date("2026-11-19T15:00:00Z")
        for (action, side) in [(LedgerSettlementAction.assignment, LedgerPositionSide.short), (.exercise, .long)] {
            #expect(throws: LedgerError.invalidContract) { try settlement(terms, at: at, action: action, side: side).validate() }
        }
        let transfer = event("transfer", at: at, .transferIn(.init(lotID: "transferred", instrument: .option(terms),
            quantity: try Money("1"), historicalCost: try Money("200"), acquiredAt: at.addingTimeInterval(-3600),
            eventMarketValue: try Money("150"), strategy: strategy, evidence: "Actual transfer record")))
        #expect(throws: LedgerError.invalidContract) { try transfer.validate() }
        let full = try contract(legacyObject())
        for (previous, replacement) in [(terms, full), (full, terms)] {
            let adjustment = event("adjust", at: at, .contractAdjustment(.init(previous: previous,
                replacement: replacement, contractQuantityRatio: try Money("1"),
                evidence: "Adjustment request", confirmedBy: "user")))
            #expect(throws: LedgerError.invalidCorporateAction) { try adjustment.validate() }
        }
    }

    @Test func localTermsCannotBecomePortfolioGreeksOrValuationEvidence() throws {
        let source = try PortfolioGreeksDemo.input(includeMissing: false)
        let input = PortfolioGreeksInput(id: source.id, createdAt: source.createdAt, asOf: source.asOf,
            mode: source.mode, accountID: source.accountID, ledgerRevision: source.ledgerRevision,
            accounts: source.accounts, events: localOptionTrades(source.events), reports: source.reports, bindings: source.bindings)
        let report = try PortfolioGreeksEngine.calculate(input)
        let options = report.rows.filter { if case .option = $0.instrument { return true }; return false }
        #expect(options.count == 3 && options.allSatisfy { $0.values == nil && $0.gap == .mismatchedContract })
        #expect(report.completeTotals == nil)

        let vectors = PerformanceVectors(), day = "2026-11-19", close = vectors.close(day)
        let terms = try local(), identity = LedgerInstrument.option(terms).identity
        let session = PerformanceSession(id: "session", instrumentID: identity,
            opensAt: close.addingTimeInterval(-23400), closesAt: close, evidence: vectors.evidence())
        let price = PerformancePrice(id: "fresh-price", instrumentID: identity, sessionID: session.id,
            quoteAt: close, bid: try Money("1"), ask: try Money("1.2"), evidence: vectors.evidence())
        let trade = try opening(terms, at: close.addingTimeInterval(-3600))
        let eventForAccount = LedgerEvent(id: trade.id, accountID: vectors.account.id, effectiveAt: trade.effectiveAt,
            source: trade.source, payload: trade.payload)
        let performance = try PerformanceEngine.calculate(vectors.input([day],
            definitions: [vectors.day(day, prices: [price], sessions: [session])], events: [eventForAccount]))
        let valuedDay = try #require(performance.daily.first), position = try #require(valuedDay.positions.first)
        #expect(position.priceKind == .missing && position.marketValue == nil && valuedDay.nav == nil)
    }

    @Test func localTermsCannotBecomeTradeObservationEvidence() throws {
        let source = try TradeOptionAttributionDemo.input(includeMissing: false)
        let performance = PerformanceInput(request: source.performance.request, ledgerRevision: source.performance.ledgerRevision,
            accounts: source.performance.accounts, events: localOptionTrades(source.performance.events))
        let input = TradeOptionAttributionInput(id: source.id, createdAt: source.createdAt, mode: source.mode,
            performance: performance, observations: source.observations)
        #expect(throws: TradeOptionAttributionError.mismatchedContract) { try TradeOptionAttributionEngine.calculate(input) }
    }
}
