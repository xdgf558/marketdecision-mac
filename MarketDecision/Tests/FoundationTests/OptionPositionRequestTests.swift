import Foundation
import Testing
import CoreDomain
import PortfolioEngine
import Persistence
@testable import AppComposition

// Local fixtures exercise navigation and actual-entry guards only; these are
// not broker receipts or evidence that any real contract was obtained.
@Suite("Option position navigation retains its original account lot and revision")
struct OptionPositionRequestTests {
    private let account = LedgerAccount(id: "A", name: "Account A")
    private let other = LedgerAccount(id: "B", name: "Account B")
    private let security = LedgerSecurity(id: "XYZ", symbol: "XYZ")

    private func date(_ text: String) throws -> Date { try LedgerCSV.timestamp(text) }
    private func contract(version: String = "v1", memo: String = "Local retained terms") throws -> LedgerOptionVersion {
        try .init(occSymbol: "XYZ   261120P00100000", versionID: version,
                  effectiveFrom: date("2026-01-01T00:00:00Z"), quoteMultiplier: Money("100"),
                  exerciseConsideration: Money("10000"),
                  deliverables: [.init(security: security, quantity: Money("100"), basisWeight: Money("1"))],
                  deliverableCash: Money("0"), tradingEndsAt: date("2026-11-20T21:00:00Z"),
                  exerciseDeadline: date("2026-11-20T22:00:00Z"), settlementAt: date("2026-11-23T14:00:00Z"),
                  memoReferences: [memo])
    }
    private func opening(_ id: String, at text: String = "2026-10-01T14:00:00Z",
                         accountID: String = "A", side: LedgerSide = .sell, quantity: String = "1",
                         version: String = "v1", memo: String = "Local retained terms") throws -> LedgerEvent {
        try .init(id: id, accountID: accountID, effectiveAt: date(text),
                  source: .init(sourceSystem: "local-record", externalTransactionID: id,
                                evidence: "Retained opening fixture"),
                  payload: .trade(.init(instrument: .option(contract(version: version, memo: memo)),
                    side: side, effect: .open, quantity: Money(quantity), unitPrice: Money("2"),
                    fee: Money("0.65"), openingLotID: id + "-lot")))
    }
    private func close(_ id: String, lotID: String, quantity: String = "1") throws -> LedgerEvent {
        try .init(id: id, accountID: account.id, effectiveAt: date("2026-10-20T14:00:00Z"),
                  source: .init(sourceSystem: "local-record", externalTransactionID: id,
                                evidence: "Retained closing fixture"),
                  payload: .trade(.init(instrument: .option(contract()), side: .buy, effect: .close,
                    quantity: Money(quantity), unitPrice: Money("1"), fee: Money("0.65"),
                    selections: [.init(lotID: lotID, quantity: Money(quantity))])))
    }
    private func snapshot(_ events: [LedgerEvent], revision: UUID = UUID(),
                          accounts: [LedgerAccount]? = nil) throws -> LedgerSnapshot {
        let accounts = accounts ?? [account, other]
        return try .init(revision: revision, accounts: accounts, events: events,
                         state: LedgerEngine.replay(accounts: accounts, events: events))
    }

    @Test func selectedPositionCreatesABlankActualClosingDraftWithoutChangingTheLedger() throws {
        let ledger = try snapshot([opening("first", quantity: "2")])
        let lot = try #require(ledger.state.lots.first)
        let request = try OptionPositionRequest(lot: lot, action: .closing, ledgerRevision: ledger.revision)
        let draft = try request.draft(in: ledger), leg = try #require(draft.legs.first)
        #expect(request.accountID == account.id && request.lotID == lot.id)
        #expect(request.ledgerRevision == ledger.revision && request.action == .closing)
        #expect(draft.accountID == account.id && draft.action == .closing)
        #expect(draft.closingAllocations == [lot.id: "2"])
        let expectedContract = try contract()
        #expect(leg.form.quantity == "2" && leg.form.existingOption == expectedContract)
        #expect(leg.form.side == .buy && leg.form.effect == .close)
        #expect(draft.timestamp.isEmpty && draft.sourceSystem.isEmpty && draft.externalID.isEmpty)
        #expect(draft.evidence.isEmpty && draft.notes.isEmpty)
        #expect(leg.form.unitPrice.isEmpty && leg.form.fee.isEmpty && leg.form.sourceSystem.isEmpty)
        #expect(throws: OptionTradeEntryError.missingExecution) { try draft.events(in: ledger) }
        #expect(ledger.state.lots.first == lot && ledger.events.count == 1)
    }

    @Test func compatibleClosingCandidatesKeepAccountDirectionAndCompleteContractVersion() throws {
        let ledger = try snapshot([
            opening("first"),
            opening("second", at: "2026-10-02T14:00:00Z"),
            opening("long", at: "2026-10-03T14:00:00Z", side: .buy),
            opening("other-account", at: "2026-10-04T14:00:00Z", accountID: other.id),
            opening("other-version", at: "2026-10-05T14:00:00Z", version: "v2")
        ])
        let lot = try #require(ledger.state.lots.first { $0.id == "first-lot" })
        let request = try OptionPositionRequest(lot: lot, action: .closing, ledgerRevision: ledger.revision)
        var draft = try request.draft(in: ledger)
        #expect(draft.closingCandidates.map(\.id) == ["first-lot", "second-lot"])
        #expect(draft.closingAllocations == ["first-lot": "1"])
        // The suggested compatible lot is not silently selected. The user can
        // explicitly allocate one real fill across both retained batches.
        draft.closingAllocations = ["first-lot": "1", "second-lot": "1"]
        draft.legs[0].form.quantity = "2"
        draft.timestamp = "2026-10-20T14:00:00Z"; draft.sourceSystem = "local-record"
        draft.externalID = "single-close-fill"; draft.evidence = "User confirmed one actual closing receipt"
        draft.legs[0].form.unitPrice = "1"; draft.legs[0].form.fee = "1.3"
        let events = try draft.events(in: ledger)
        try #require(events.count == 1)
        #expect(events[0].source.externalTransactionID == "single-close-fill")
        guard case .trade(let trade) = events[0].payload else { Issue.record("Expected one closing event"); return }
        let expectedQuantity = try Money("2"), expectedFee = try Money("1.3")
        #expect(trade.quantity == expectedQuantity && trade.fee == expectedFee)
        #expect(trade.selections.map(\.lotID) == ["first-lot", "second-lot"])
    }

    @Test func expirationOnlyPreparesTheSelectedLotAndLeavesConfirmationFieldsBlank() throws {
        let ledger = try snapshot([opening("first"), opening("second", at: "2026-10-02T14:00:00Z")])
        let lot = try #require(ledger.state.lots.first { $0.id == "first-lot" })
        let request = try OptionPositionRequest(lot: lot, action: .expiration, ledgerRevision: ledger.revision)
        let draft = try request.draft(in: ledger), leg = try #require(draft.legs.first)
        #expect(draft.action == .expiration && draft.closingCandidates.isEmpty && draft.closingAllocations.isEmpty)
        #expect(leg.form.lots == [lot.id: "1"] && leg.form.settlementAction == .expiration)
        #expect(draft.timestamp.isEmpty && draft.sourceSystem.isEmpty && draft.externalID.isEmpty && draft.evidence.isEmpty)
        #expect(leg.form.fee.isEmpty && leg.form.unitPrice.isEmpty)
        #expect(throws: OptionTradeEntryError.missingExecution) { try draft.events(in: ledger) }
    }

    @Test func aChangedRevisionNeverRebasesEvenWhenThePositionLooksIdentical() throws {
        let events = try [opening("first")], ledger = try snapshot(events)
        let lot = try #require(ledger.state.lots.first)
        let request = try OptionPositionRequest(lot: lot, action: .closing, ledgerRevision: ledger.revision)
        let newer = try snapshot(events)
        #expect(newer.state.lots == ledger.state.lots)
        #expect(throws: OptionTradeEntryError.changedLot) { try request.draft(in: newer) }
    }

    @Test func originalLotQuantityCostOrContractChangesAreRejectedEvenAtAnEqualRevision() throws {
        let original = try opening("first", quantity: "2"), ledger = try snapshot([original])
        let lot = try #require(ledger.state.lots.first)
        let request = try OptionPositionRequest(lot: lot, action: .closing, ledgerRevision: ledger.revision)
        let partiallyClosed = try snapshot([original, close("partial", lotID: lot.id)], revision: ledger.revision)
        #expect(throws: OptionTradeEntryError.changedLot) { try request.draft(in: partiallyClosed) }
        let differentTerms = try snapshot([opening("first", quantity: "2", memo: "Different retained contract terms")],
                                          revision: ledger.revision)
        #expect(throws: OptionTradeEntryError.changedLot) { try request.draft(in: differentTerms) }
        let absent = try snapshot([], revision: ledger.revision)
        #expect(throws: OptionTradeEntryError.changedLot) { try request.draft(in: absent) }
    }

    @Test func otherAccountCannotSupplyAnIdenticallyNamedLotAndMissingAccountsAreRejected() throws {
        let ledger = try snapshot([opening("first")]), lot = try #require(ledger.state.lots.first)
        let request = try OptionPositionRequest(lot: lot, action: .closing, ledgerRevision: ledger.revision)
        let moved = try snapshot([opening("first", accountID: other.id)], revision: ledger.revision)
        #expect(throws: OptionTradeEntryError.changedLot) { try request.draft(in: moved) }
        let removedAccount = try snapshot([], revision: ledger.revision, accounts: [other])
        #expect(throws: OptionTradeEntryError.invalidAccount) { try request.draft(in: removedAccount) }
    }

    @Test func corruptedSnapshotCannotAuthorizeNavigationThroughItsStoredLot() throws {
        let ledger = try snapshot([opening("first")]), lot = try #require(ledger.state.lots.first)
        let request = try OptionPositionRequest(lot: lot, action: .closing, ledgerRevision: ledger.revision)
        let corrupted = LedgerSnapshot(revision: ledger.revision, accounts: ledger.accounts,
                                        events: [], state: ledger.state)
        #expect(throws: OptionTradeEntryError.inconsistentSnapshot) { try request.draft(in: corrupted) }
    }

    @Test func openingEquityAndAlreadyClosedLotsCannotStartAClosingRequest() throws {
        let open = try opening("first"), ledger = try snapshot([open])
        let lot = try #require(ledger.state.lots.first)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionPositionRequest(lot: lot, action: .opening, ledgerRevision: ledger.revision)
        }
        var equity = lot; equity.instrument = .equity(security)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionPositionRequest(lot: equity, action: .closing, ledgerRevision: ledger.revision)
        }
        let closed = try snapshot([open, close("close", lotID: lot.id)])
        let closedLot = try #require(closed.state.lots.first)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionPositionRequest(lot: closedLot, action: .expiration, ledgerRevision: closed.revision)
        }
    }

    @Test func statusUsesSettlementBoundaryAndNeverChangesPositionOrRecognizesProfit() throws {
        let open = try opening("first"), ledger = try snapshot([open])
        let lot = try #require(ledger.state.lots.first), terms = try contract()
        let tradingEndsAt = try #require(terms.tradingEndsAt)
        let exerciseDeadline = try #require(terms.exerciseDeadline)
        let settlementAt = try #require(terms.settlementAt)
        #expect(OptionPositionRequest.status(for: lot, at: tradingEndsAt) == "持有中")
        #expect(OptionPositionRequest.status(for: lot, at: exerciseDeadline) == "持有中")
        #expect(OptionPositionRequest.status(for: lot, at: settlementAt.addingTimeInterval(-0.001)) == "持有中")
        #expect(OptionPositionRequest.status(for: lot, at: settlementAt) == "已到期待确认")
        #expect(OptionPositionRequest.status(for: lot, at: settlementAt.addingTimeInterval(86400)) == "已到期待确认")
        #expect(ledger.state.realizations.isEmpty && ledger.state.lots.first == lot && !lot.isClosed)
        let closed = try snapshot([open, close("close", lotID: lot.id)])
        let closedLot = try #require(closed.state.lots.first)
        #expect(OptionPositionRequest.status(for: closedLot, at: tradingEndsAt) == "已结清")
    }
}
