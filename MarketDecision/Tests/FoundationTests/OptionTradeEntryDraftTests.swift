import Foundation
import Testing
import CoreDomain
import OptionsAnalytics
import PortfolioEngine
import Persistence
@testable import AppComposition

// Independent local fixtures exercise actual-entry semantics. These fixtures do
// not claim that a broker execution or an official contract was obtained.
private func optionEntryLab(spread: Bool = false) -> OptionLabInputDraft {
    var draft = OptionLabInputDraft()
    draft.strategy = spread ? .putCreditSpread : .cashSecuredPut
    draft.symbol = "XYZ"; draft.expirationDate = "2026-11-20"
    draft.shortLeg.strike = "100"; draft.shortLeg.quantity = "2"
    draft.shortLeg.bid = "9"; draft.shortLeg.ask = "11"
    draft.longLeg.strike = "95"; draft.longLeg.quantity = "2"
    draft.longLeg.bid = "7"; draft.longLeg.ask = "8"
    draft.openingFeePerContract = "99"; draft.ticketFee = "888"
    draft.settlementAt = "2026-11-20T21:00:00Z"
    draft.sourceReference = "User supplied quote observation"
    draft.expiryReference = "Unverified research expiry assumption"
    return draft
}

private func optionEntryPrepared(spread: Bool = false, externalID: String = "execution-42") throws -> OptionTradeEntryDraft {
    var draft = try OptionTradeEntryDraft(openingFrom: optionEntryLab(spread: spread))
    draft.accountID = "A"; draft.timestamp = "2026-10-24T14:00:00.0004Z"
    draft.sourceSystem = "broker-record"; draft.externalID = spread ? "" : externalID
    draft.evidence = "User confirmed execution receipt"; draft.notes = "Actual entry regression vector"
    for index in draft.legs.indices {
        if spread { draft.legs[index].form.externalID = externalID + (index == 0 ? "-short-fill" : "-long-fill") }
        draft.legs[index].form.unitPrice = index == 0 ? "2.5" : "1.0"
        draft.legs[index].form.fee = "1.3"
        draft.legs[index].form.securityID = "equity-XYZ"
        draft.legs[index].form.contractVersionID = "confirmed-standard-v1"
        draft.legs[index].form.effectiveFrom = "2026-01-01T00:00:00Z"
        draft.legs[index].form.tradingEndsAt = "2026-11-20T21:00:00Z"
        draft.legs[index].form.exerciseDeadline = "2026-11-20T22:00:00Z"
        draft.legs[index].form.settlementAt = "2026-11-23T14:00:00Z"
        draft.legs[index].form.memoReference = "User checked contract specification record"
        draft.legs[index].contractConfirmed = true
    }
    return draft
}

private func optionEntryAutomatic(spread: Bool = false) throws -> OptionTradeEntryDraft {
    var draft = try OptionTradeEntryDraft(openingFrom: optionEntryLab(spread: spread), automaticContractTerms: true)
    draft.accountID = "A"; draft.timestamp = "2026-10-24T14:00:00.0004Z"
    for index in draft.legs.indices {
        draft.legs[index].form.unitPrice = index == 0 ? "2.5" : "1.0"
        draft.legs[index].form.fee = "1.3"
    }
    return draft
}

private func optionEntryQuantitySource(_ strategy: OptionLabStrategy, retainedLongQuantity: String) -> OptionLabInputDraft {
    var source = OptionLabInputDraft()
    source.strategy = strategy; source.symbol = "XYZ"; source.underlyingPrice = "100"
    source.expirationDate = "2026-11-20"; source.settlementAt = "2026-11-20T21:00:00Z"
    source.shortLeg.strike = "100"; source.shortLeg.quantity = "5"; source.shortLeg.enteredPrice = "2.5"
    source.longLeg.strike = strategy == .putCreditSpread ? "95" : "105"
    source.longLeg.quantity = retainedLongQuantity; source.longLeg.enteredPrice = "1"
    return source
}

private func optionEntryContract(_ event: LedgerEvent) throws -> LedgerOptionVersion {
    guard case .trade(let trade) = event.payload, case .option(let contract) = trade.instrument else {
        throw LedgerError.invalidContract
    }
    return contract
}

private func optionEntrySnapshot(_ events: [LedgerEvent] = [], accounts: [LedgerAccount]? = nil) throws -> LedgerSnapshot {
    let accounts = accounts ?? [LedgerAccount(id: "A", name: "Account A"), LedgerAccount(id: "B", name: "Account B")]
    return try .init(revision: UUID(), accounts: accounts, events: events,
        state: LedgerEngine.replay(accounts: accounts, events: events))
}

private func optionEntryFinish(_ lot: LedgerLot, action: OptionTradeEntryAction, id: String,
                               otherClosingLots: [LedgerLot] = []) throws -> OptionTradeEntryDraft {
    var draft = try OptionTradeEntryDraft(lot: lot, action: action, otherClosingLots: otherClosingLots)
    draft.timestamp = action == .expiration ? "2026-11-20T22:00:00Z" : "2026-10-26T15:00:00Z"
    draft.sourceSystem = "broker-record"; draft.externalID = id
    draft.evidence = action == .expiration ? "Account activity confirms expired without exercise or assignment" : "User confirmed closing execution receipt"
    draft.legs[0].form.unitPrice = "1.1"; draft.legs[0].form.fee = "0.65"
    return draft
}

private func optionEntryTwoLots(quantity: String = "1") throws -> LedgerSnapshot {
    let empty = try optionEntrySnapshot()
    var first = try optionEntryPrepared(externalID: "open-first")
    first.legs[0].form.quantity = quantity; first.legs[0].form.fee = "0.65"
    var second = try optionEntryPrepared(externalID: "open-second")
    second.timestamp = "2026-10-25T14:00:00Z"
    second.legs[0].form.quantity = quantity; second.legs[0].form.unitPrice = "3"
    second.legs[0].form.fee = "0.65"
    return try optionEntrySnapshot(first.events(in: empty) + second.events(in: empty))
}

@Suite("Option executions share the ledger without importing research payoffs")
struct OptionTradeEntryDraftTests {
    @Test func openingCopiesOnlyContractProposalAndNeverQuotesFeesOrExpiryEvidence() throws {
        let source = optionEntryLab(), draft = try OptionTradeEntryDraft(openingFrom: source)
        let leg = try #require(draft.legs.first)
        #expect(draft.action == .opening && draft.accountID.isEmpty)
        #expect(draft.timestamp.isEmpty && draft.sourceSystem.isEmpty && draft.externalID.isEmpty && draft.evidence.isEmpty)
        #expect(leg.form.quantity == "2" && leg.form.occSymbol == "XYZ   261120P00100000")
        #expect(leg.form.unitPrice.isEmpty && leg.form.fee.isEmpty)
        #expect(leg.form.contractVersionID.isEmpty && leg.form.effectiveFrom.isEmpty)
        #expect(leg.form.tradingEndsAt.isEmpty && leg.form.exerciseDeadline.isEmpty && leg.form.settlementAt.isEmpty)
        #expect(leg.form.memoReference.isEmpty && !leg.contractConfirmed)
        #expect(leg.form.quoteMultiplier == "100" && leg.form.exerciseConsideration == "10000")
        #expect(leg.form.deliverableQuantity == "100" && leg.form.deliverableCash == "0")
        // The quote draft deliberately lacks fields required for calculation.
        #expect(source.asOf.isEmpty && source.underlyingBid.isEmpty)
    }

    @Test func explicitOpeningReferencePricesChangeOnlyUnitPrices() throws {
        var source = optionEntryLab(spread: true)
        source.shortLeg.enteredPrice = " 3.2500 "; source.longLeg.enteredPrice = "0.0000"
        let initial = try OptionTradeEntryDraft(openingFrom: source)
        #expect(initial.legs.allSatisfy { $0.form.unitPrice.isEmpty && $0.form.fee.isEmpty })
        var actual = try optionEntryPrepared(spread: true)
        var expected = actual
        expected.legs[0].form.unitPrice = "3.25"; expected.legs[1].form.unitPrice = "0"
        try actual.applyOpeningReferencePrices(from: source)
        // Equality covers IDs, actual times, actual fees, fill identifiers,
        // quantities, and confirmed contract fields as well as the copied price.
        #expect(actual == expected)
        #expect(actual.legs[0].form.unitPrice != "10") // Source Bid/Ask midpoint.
        #expect(actual.legs[1].contractConfirmed)
        #expect(actual.timestamp == "2026-10-24T14:00:00.0004Z")
    }

    @Test func referencePricesRejectMissingInvalidNegativeAndQuoteOnlyInputsAtomically() throws {
        var source = optionEntryLab(spread: true)
        source.shortLeg.enteredPrice = "3.25"
        for invalid in ["", " ", "not-a-price", "NaN", "-0.01", "1e2"] {
            source.longLeg.enteredPrice = invalid
            var actual = try optionEntryPrepared(spread: true)
            let original = actual
            #expect(throws: OptionTradeEntryError.missingExecution) {
                try actual.applyOpeningReferencePrices(from: source)
            }
            #expect(actual == original) // The valid first leg was not copied.
        }
        source.longLeg.enteredPrice = "1.25"; source.usesEnteredPrices = false
        var quoteMode = try optionEntryPrepared(spread: true)
        let original = quoteMode
        #expect(throws: OptionTradeEntryError.missingExecution) {
            try quoteMode.applyOpeningReferencePrices(from: source)
        }
        #expect(quoteMode == original) // Retained manual prices cannot impersonate the active Bid/Ask mode.
    }

    @Test func referencePricesRejectSyntheticAndDifferentContractLayouts() throws {
        var base = optionEntryLab(spread: true)
        base.shortLeg.enteredPrice = "3.25"; base.longLeg.enteredPrice = "1.25"
        for mismatch in ["symbol", "asset", "expiry", "short-strike", "long-strike", "right", "leg-order", "leg-count"] {
            var source = base
            switch mismatch {
            case "symbol": source.symbol = "ABC"
            case "asset": source.asset = .etf
            case "expiry": source.expirationDate = "2026-12-18"
            case "short-strike": source.shortLeg.strike = "105"
            case "long-strike": source.longLeg.strike = "90"
            case "right": source.strategy = .callCreditSpread
            case "leg-order":
                let oldShort = source.shortLeg; source.shortLeg = source.longLeg; source.longLeg = oldShort
            default: source.strategy = .cashSecuredPut
            }
            var actual = try optionEntryPrepared(spread: true)
            let original = actual
            #expect(throws: (any Error).self) { try actual.applyOpeningReferencePrices(from: source) }
            #expect(actual == original)
        }
        var marked = base; marked.sourceReference = "SYNTHETIC quote observation"
        for source in [OptionLabInputDraft.synthetic(strategy: .putCreditSpread), marked] {
            var actual = try optionEntryPrepared(spread: true)
            let original = actual
            #expect(throws: OptionTradeEntryError.syntheticEvidence) {
                try actual.applyOpeningReferencePrices(from: source)
            }
            #expect(actual == original)
        }
    }

    @Test func referencePricesRejectChangedLegOrderAndNonOpeningActions() throws {
        var source = optionEntryLab(spread: true)
        source.shortLeg.enteredPrice = "3.25"; source.longLeg.enteredPrice = "1.25"
        var reordered = try optionEntryPrepared(spread: true)
        reordered.legs.reverse()
        let reorderedOriginal = reordered
        #expect(throws: OptionTradeEntryError.changedLegs) {
            try reordered.applyOpeningReferencePrices(from: source)
        }
        #expect(reordered == reorderedOriginal)
        let ledger = try optionEntryTwoLots(), lot = try #require(ledger.state.lots.first)
        for action in [OptionTradeEntryAction.closing, .expiration] {
            var actual = try OptionTradeEntryDraft(lot: lot, action: action)
            let original = actual
            #expect(throws: OptionTradeEntryError.changedLegs) {
                try actual.applyOpeningReferencePrices(from: source)
            }
            #expect(actual == original)
        }
    }

    @Test func syntheticProvenanceAndNonrepresentableOCCProposalsAreRejected() throws {
        #expect(throws: OptionTradeEntryError.syntheticEvidence) {
            try OptionTradeEntryDraft(openingFrom: OptionLabInputDraft.synthetic(strategy: .cashSecuredPut))
        }
        var marked = optionEntryLab(); marked.shortLeg.sourceReference = "SYNTHETIC quoted value"
        #expect(throws: OptionTradeEntryError.syntheticEvidence) { try OptionTradeEntryDraft(openingFrom: marked) }
        for symbol in ["TOOLONG", "BRK.B"] {
            var source = optionEntryLab(); source.symbol = symbol
            #expect(throws: OptionTradeEntryError.invalidContract) { try OptionTradeEntryDraft(openingFrom: source) }
        }
        for strike in ["100.0001", "100000", "0", "-1"] {
            var source = optionEntryLab(); source.shortLeg.strike = strike
            #expect(throws: OptionTradeEntryError.invalidContract) { try OptionTradeEntryDraft(openingFrom: source) }
        }
        var source = optionEntryLab(); source.shortLeg.strike = "100.125"; source.symbol = "xyz"
        #expect(try OptionTradeEntryDraft(openingFrom: source).legs[0].form.occSymbol == "XYZ   261120P00100125")
        source.shortLeg.multiplier = "10"
        #expect(throws: OptionTradeEntryError.invalidContract) { try OptionTradeEntryDraft(openingFrom: source) }
    }

    @Test func actualFieldsAndContractConfirmationAreRequiredBeforeBuildingEvents() throws {
        let snapshot = try optionEntrySnapshot()
        var draft = try optionEntryPrepared(); draft.legs[0].contractConfirmed = false
        #expect(throws: OptionTradeEntryError.unconfirmedContract) { try draft.events(in: snapshot) }
        draft.legs[0].contractConfirmed = true; draft.legs[0].form.fee = ""
        #expect(throws: OptionTradeEntryError.missingExecution) { try draft.events(in: snapshot) }
        draft.legs[0].form.fee = "0"; draft.legs[0].form.unitPrice = ""
        #expect(throws: OptionTradeEntryError.missingExecution) { try draft.events(in: snapshot) }
        draft.legs[0].form.unitPrice = "2.5"; draft.timestamp = ""
        #expect(throws: OptionTradeEntryError.missingExecution) { try draft.events(in: snapshot) }
        draft.timestamp = "2026-10-24T14:00:00Z"; draft.legs[0].form.memoReference = ""
        #expect(throws: (any Error).self) { try draft.events(in: snapshot) }
    }

    @Test func automaticOpeningBuildsLocalStandardTermsWithoutManualContractDetails() throws {
        let snapshot = try optionEntrySnapshot()
        for spread in [false, true] {
            let draft = try optionEntryAutomatic(spread: spread), original = draft
            #expect(draft.legs.allSatisfy {
                !$0.contractConfirmed && $0.form.existingOption == nil && $0.form.contractVersionID.isEmpty
                    && $0.form.effectiveFrom.isEmpty && $0.form.tradingEndsAt.isEmpty
                    && $0.form.exerciseDeadline.isEmpty && $0.form.settlementAt.isEmpty && $0.form.memoReference.isEmpty
            })
            let events = try draft.events(in: snapshot)
            #expect(events.count == (spread ? 2 : 1) && draft == original)
            for (index, event) in events.enumerated() {
                let contract = try optionEntryContract(event)
                #expect(contract.termsBasis == .localManualStandard)
                #expect(contract.effectiveFrom == nil && contract.effectiveTo == nil && contract.tradingEndsAt == nil)
                #expect(contract.exerciseDeadline == nil && contract.settlementAt == nil)
                #expect(contract.quoteMultiplier == (try Money("100")) && contract.deliverableCash == (try Money("0")))
                #expect(contract.exerciseConsideration == (try Money(index == 0 ? "10000" : "9500")))
                #expect(contract.occSymbol == (index == 0 ? "XYZ   261120P00100000" : "XYZ   261120P00095000"))
                let delivery = try #require(contract.deliverables.first)
                #expect(contract.deliverables.count == 1 && delivery.security.symbol == "XYZ" && delivery.security.kind == .stock)
                #expect(delivery.quantity == (try Money("100")) && delivery.basisWeight == (try Money("1")))
                #expect(contract.settlementType == .physicalEquity && contract.exerciseStyle == .american)
                #expect(!contract.memoReferences.isEmpty && !contract.memoReferences.contains("Unverified research expiry assumption"))
            }
        }
    }

    @Test func contractParameterSpreadQuantityMatchesCalculationOpeningAndCommittedLots() async throws {
        let recordedAt = try LedgerCSV.timestamp("2026-10-24T14:00:00Z")
        for strategy in [OptionLabStrategy.putCreditSpread, .callCreditSpread] {
            for retainedLongQuantity in ["1", "old-invalid-quantity"] {
                let source = optionEntryQuantitySource(strategy, retainedLongQuantity: retainedLongQuantity), original = source
                #expect(source.usesContractParametersOnly && source.usesEnteredPrices)
                let calculation = try source.buildForCalculation(createdAt: recordedAt)
                #expect(calculation.shortLeg.quantity == 5 && calculation.longLeg?.quantity == 5)
                let report = try OptionLabEngine.calculate(calculation)
                #expect(report.selectedOutcome.grossCredit == (try Money("750")))
                #expect(report.selectedOutcome.totalFees == (try Money("6.5")))
                var draft = try OptionTradeEntryDraft(openingFrom: source, automaticContractTerms: true)
                #expect(draft.legs.map { $0.form.quantity } == ["5", "5"])
                draft.accountID = "A"; draft.timestamp = "2026-10-24T14:00:00Z"
                for index in draft.legs.indices {
                    draft.legs[index].form.unitPrice = index == 0 ? "2.5" : "1"
                    draft.legs[index].form.fee = "1.3"
                }
                let prepared = draft, store = try LedgerStore(path: ":memory:")
                let initial = try await store.snapshot()
                let account = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
                let events = try draft.events(in: account)
                let preview = try await store.previewManual(events: events, expectedRevision: account.revision)
                #expect(preview.canCommit && preview.rows.count == 2 && preview.rows.allSatisfy { $0.disposition == .new })
                let projected = try #require(preview.projectedState)
                #expect(projected.lots.count == 2)
                for side in [LedgerPositionSide.short, .long] {
                    let lot = try #require(projected.lots.first { $0.side == side })
                    #expect(lot.quantityOpened == (try Money("5")) && lot.quantityRemaining == (try Money("5")))
                }
                let committed = try await store.commit(planID: preview.id, expectedRevision: account.revision)
                #expect(committed.state == projected && committed.events.count == 2)
                let duplicate = try await store.previewManual(events: draft.events(in: committed), expectedRevision: committed.revision)
                #expect(duplicate.canCommit && duplicate.rows.count == 2 && duplicate.rows.allSatisfy { $0.disposition == .duplicate })
                #expect(try await store.commit(planID: duplicate.id, expectedRevision: committed.revision) == committed)
                #expect(draft == prepared && source == original && source.longLeg.quantity == retainedLongQuantity)
            }
        }
    }

    @Test func actualSpreadQuantityEditsAfterInitializationRemainIndependentThroughCommit() async throws {
        for strategy in [OptionLabStrategy.putCreditSpread, .callCreditSpread] {
            let source = optionEntryQuantitySource(strategy, retainedLongQuantity: "old-invalid-quantity"), original = source
            var draft = try OptionTradeEntryDraft(openingFrom: source, automaticContractTerms: true)
            #expect(draft.legs.map { $0.form.quantity } == ["5", "5"])
            draft.accountID = "A"; draft.timestamp = "2026-10-24T14:00:00Z"
            draft.legs[0].form.quantity = "3"; draft.legs[1].form.quantity = "2"
            draft.legs[0].form.fee = "1.95"; draft.legs[1].form.fee = "1.3"
            try draft.applyOpeningReferencePrices(from: source)
            #expect(draft.legs.map { $0.form.quantity } == ["3", "2"])
            let prepared = draft, store = try LedgerStore(path: ":memory:")
            let initial = try await store.snapshot()
            let account = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
            let events = try draft.events(in: account)
            try #require(events.count == 2)
            guard case .trade(let short) = events[0].payload, case .trade(let long) = events[1].payload else {
                Issue.record("Expected the two independently edited actual fills"); return
            }
            #expect(short.side == .sell && short.quantity == (try Money("3")))
            #expect(long.side == .buy && long.quantity == (try Money("2")))
            let preview = try await store.previewManual(events: events, expectedRevision: account.revision)
            #expect(preview.canCommit && preview.rows.count == 2)
            let projected = try #require(preview.projectedState)
            let projectedShort = try #require(projected.lots.first { $0.side == .short })
            let projectedLong = try #require(projected.lots.first { $0.side == .long })
            #expect(projectedShort.quantityRemaining == (try Money("3")) && projectedLong.quantityRemaining == (try Money("2")))
            let committed = try await store.commit(planID: preview.id, expectedRevision: account.revision)
            #expect(committed.state == projected && committed.state.lots.count == 2)
            #expect(try draft.events(in: committed) == events)
            #expect(draft == prepared && source == original && source.shortLeg.quantity == "5")
        }
    }

    @Test func fullModeOpeningPreservesEachLegQuantityAndRejectsInvalidProtectionQuantity() throws {
        let snapshot = try optionEntrySnapshot()
        for strategy in [OptionLabStrategy.putCreditSpread, .callCreditSpread] {
            var source = optionEntryQuantitySource(strategy, retainedLongQuantity: "1")
            source.usesContractParametersOnly = false
            let original = source
            var draft = try OptionTradeEntryDraft(openingFrom: source, automaticContractTerms: true)
            #expect(draft.legs.map { $0.form.quantity } == ["5", "1"])
            draft.accountID = "A"; draft.timestamp = "2026-10-24T14:00:00Z"
            for index in draft.legs.indices {
                draft.legs[index].form.unitPrice = index == 0 ? "2.5" : "1"
                draft.legs[index].form.fee = "0"
            }
            let events = try draft.events(in: snapshot), state = try optionEntrySnapshot(events).state
            #expect(state.lots.count == 2)
            #expect(state.lots.first { $0.side == .short }?.quantityRemaining == (try Money("5")))
            #expect(state.lots.first { $0.side == .long }?.quantityRemaining == (try Money("1")))
            #expect(source == original)
            source.longLeg.quantity = "old-invalid-quantity"
            #expect(throws: (any Error).self) {
                try OptionTradeEntryDraft(openingFrom: source, automaticContractTerms: true)
            }
        }
    }

    @Test func automaticOpeningContractsStayStableAcrossDraftsTimesAndDuplicatePreviews() async throws {
        let store = try LedgerStore(path: ":memory:")
        let initial = try await store.snapshot()
        let created = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
        let first = try optionEntryAutomatic(spread: true)
        var later = try optionEntryAutomatic(spread: true)
        later.timestamp = "2026-10-25T15:00:00Z"
        let events = try first.events(in: created), laterEvents = try later.events(in: created)
        #expect(try events.map(optionEntryContract) == laterEvents.map(optionEntryContract))
        #expect(events.map(\.id) != laterEvents.map(\.id))
        let firstPreview = try await store.previewManual(events: events, expectedRevision: created.revision)
        let secondPreview = try await store.previewManual(events: first.events(in: created), expectedRevision: created.revision)
        #expect(firstPreview.canCommit && firstPreview.rows == secondPreview.rows && firstPreview.projectedState == secondPreview.projectedState)
        await store.cancel(planID: secondPreview.id)
        let committed = try await store.commit(planID: firstPreview.id, expectedRevision: created.revision)
        #expect(try first.events(in: committed) == events)
        let duplicate = try await store.previewManual(events: first.events(in: committed), expectedRevision: committed.revision)
        #expect(duplicate.canCommit && duplicate.rows.allSatisfy { $0.disposition == .duplicate })
        #expect(try await store.commit(planID: duplicate.id, expectedRevision: committed.revision) == committed)
    }

    @Test func automaticOpeningReusesUniqueCompleteVersionOnlyFromSelectedAccount() throws {
        let existing = try optionEntryTwoLots(), original = try optionEntryContract(existing.events[0])
        let automatic = try optionEntryAutomatic()
        let reused = try optionEntryContract(automatic.events(in: existing)[0])
        #expect(reused == original)
        #expect(reused.effectiveFrom != nil && reused.tradingEndsAt != nil && reused.exerciseDeadline != nil && reused.settlementAt != nil)
        #expect(!automatic.legs[0].contractConfirmed && automatic.legs[0].form.existingOption == nil)
        let empty = try optionEntrySnapshot()
        var other = try optionEntryPrepared(externalID: "other-account-version")
        other.accountID = "B"; other.legs[0].form.contractVersionID = "account-b-only-version"
        let otherSnapshot = try optionEntrySnapshot(other.events(in: empty))
        let local = try optionEntryContract(automatic.events(in: otherSnapshot)[0])
        #expect(local.termsBasis == .localManualStandard && local != (try optionEntryContract(otherSnapshot.events[0])))
        #expect(local.exerciseDeadline == nil && local.settlementAt == nil)
        var explicit = automatic
        try explicit.legs[0].reuseContract(optionEntryContract(otherSnapshot.events[0]))
        #expect(throws: OptionTradeEntryError.invalidContract) { try explicit.events(in: otherSnapshot) }
        #expect(throws: OptionTradeEntryError.invalidContract) { try explicit.events(in: existing) }
        explicit = automatic
        try explicit.legs[0].reuseContract(original)
        #expect(try optionEntryContract(explicit.events(in: existing)[0]) == original)
    }

    @Test func automaticOpeningRejectsAmbiguousAndNonstandardExistingVersions() throws {
        let empty = try optionEntrySnapshot()
        let first = try optionEntryPrepared(externalID: "version-one")
        var second = try optionEntryPrepared(externalID: "version-two")
        second.legs[0].form.contractVersionID = "other-complete-version"
        second.timestamp = "2026-10-25T14:00:00Z"
        let ambiguous = try optionEntrySnapshot(first.events(in: empty) + second.events(in: empty))
        let automatic = try optionEntryAutomatic()
        #expect(throws: (any Error).self) { try automatic.events(in: ambiguous) }
        for mismatch in ["multiplier", "deliverable", "cash", "consideration", "symbol", "kind"] {
            var form = try optionEntryPrepared().legs[0].form
            form.id = "nonstandard-" + mismatch; form.openingLotID = form.id + "-lot"
            form.timestamp = "2026-10-23T14:00:00Z"; form.sourceSystem = "broker-record"
            form.externalID = form.id; form.evidence = "User retained adjusted contract record"
            form.strategyEnabled = true; form.strategyID = "retained-strategy-" + mismatch
            form.successDefinition = "Retained manual contract fixture"
            switch mismatch {
            case "multiplier": form.quoteMultiplier = "50"
            case "deliverable": form.deliverableQuantity = "50"
            case "cash": form.deliverableCash = "10"
            case "consideration": form.exerciseConsideration = "9500"
            case "symbol": form.symbol = "ABC"
            default: form.securityKind = .etf
            }
            let retained = try optionEntrySnapshot([form.event(accountID: "A")])
            #expect(throws: (any Error).self) { try automatic.events(in: retained) }
        }
    }

    @Test func automaticOpeningIgnoresHiddenContractFieldsButRejectsUnverifiedObjectReplacement() throws {
        let snapshot = try optionEntrySnapshot()
        var draft = try optionEntryAutomatic(spread: true)
        let original = try draft.events(in: snapshot)
        for index in draft.legs.indices {
            draft.legs[index].form.occSymbol = "ABC   261218C00050000"
            draft.legs[index].form.symbol = "ABC"; draft.legs[index].form.securityID = "unrelated-equity"
            draft.legs[index].form.securityKind = .etf; draft.legs[index].form.contractVersionID = "unconfirmed-version"
            draft.legs[index].form.quoteMultiplier = "10"; draft.legs[index].form.exerciseConsideration = "500"
            draft.legs[index].form.deliverableQuantity = "10"; draft.legs[index].form.deliverableCash = "20"
            draft.legs[index].form.effectiveFrom = "2027-01-01T00:00:00Z"
            draft.legs[index].form.tradingEndsAt = "2027-12-01T00:00:00Z"
            draft.legs[index].form.exerciseDeadline = "2027-12-02T00:00:00Z"
            draft.legs[index].form.settlementAt = "2027-12-03T00:00:00Z"
            draft.legs[index].form.memoReference = "Unverified hidden form text"
            draft.legs[index].form.exerciseStyle = .european; draft.legs[index].contractConfirmed = false
        }
        #expect(try draft.events(in: snapshot) == original)
        draft.legs[0].form.existingOption = try optionEntryContract(optionEntryPrepared().events(in: snapshot)[0])
        #expect(throws: OptionTradeEntryError.unconfirmedContract) { try draft.events(in: snapshot) }
    }

    @Test func automaticOpeningStillRequiresActualValuesAndVerifiedAccountSnapshot() throws {
        let snapshot = try optionEntrySnapshot()
        for field in ["time", "price", "fee", "quantity"] {
            var draft = try optionEntryAutomatic()
            switch field {
            case "time": draft.timestamp = ""
            case "price": draft.legs[0].form.unitPrice = ""
            case "fee": draft.legs[0].form.fee = ""
            default: draft.legs[0].form.quantity = ""
            }
            #expect(throws: (any Error).self) { try draft.events(in: snapshot) }
        }
        var draft = try optionEntryAutomatic(); draft.accountID = "unknown-account"
        #expect(throws: OptionTradeEntryError.invalidAccount) { try draft.events(in: snapshot) }
        draft.accountID = "A"
        let event = try optionEntryPrepared().events(in: snapshot)[0]
        let inconsistent = LedgerSnapshot(revision: UUID(), accounts: snapshot.accounts, events: [event], state: snapshot.state)
        #expect(throws: OptionTradeEntryError.inconsistentSnapshot) { try draft.events(in: inconsistent) }
        let marked = LedgerEvent(id: event.id, accountID: event.accountID, effectiveAt: event.effectiveAt,
            source: .init(sourceSystem: "SYNTHETIC retained source", externalTransactionID: event.source.externalTransactionID,
                evidence: "Synthetic contract illustration"), payload: event.payload)
        let retained = try optionEntrySnapshot([marked])
        #expect(throws: OptionTradeEntryError.syntheticEvidence) { try draft.events(in: retained) }
    }

    @Test func automaticOpeningPreviewStillRejectsAChangedLedgerRevision() async throws {
        let store = try LedgerStore(path: ":memory:")
        let initial = try await store.snapshot()
        let created = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
        let draft = try optionEntryAutomatic()
        let preview = try await store.previewManual(events: draft.events(in: created), expectedRevision: created.revision)
        #expect(preview.canCommit)
        let changed = try await store.createAccount(.init(id: "B", name: "Account B"), expectedRevision: created.revision)
        await #expect(throws: LedgerStoreError.stalePlan) {
            try await store.commit(planID: preview.id, expectedRevision: created.revision)
        }
        #expect(try await store.snapshot() == changed && changed.events.isEmpty)
    }

    @Test func automaticOpeningCloseRetainsTheExactLocalContractAndLot() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryAutomatic().events(in: empty)
        let opened = try optionEntrySnapshot(opening), lot = try #require(opened.state.lots.first)
        let contract = try optionEntryContract(opening[0])
        var draft = try optionEntryFinish(lot, action: .closing, id: "close-local-standard")
        draft.legs[0].form.quantity = "1"
        let closing = try draft.events(in: opened)
        #expect(try optionEntryContract(closing[0]) == contract)
        guard case .trade(let trade) = closing[0].payload else { Issue.record("Expected local contract close"); return }
        #expect(trade.selections == [.init(lotID: lot.id, quantity: try Money("1"))])
        let state = try optionEntrySnapshot(opening + closing).state
        #expect(state.lots.count == 1 && state.lots[0].id == lot.id && state.lots[0].quantityRemaining == (try Money("1")))
        #expect(state.lots[0].instrument == lot.instrument)
        draft.legs[0].form.existingOption = try optionEntryContract(optionEntryPrepared().events(in: empty)[0])
        #expect(throws: (any Error).self) { try draft.events(in: opened) }
    }

    @Test func localStandardExpirationNeedsActualEvidenceAndOCCNewYorkDateWithoutInventingSchedule() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryAutomatic().events(in: empty)
        let opened = try optionEntrySnapshot(opening), lot = try #require(opened.state.lots.first)
        let contract = try optionEntryContract(opening[0])
        #expect(contract.exerciseDeadline == nil && contract.settlementAt == nil && contract.tradingEndsAt == nil)
        var draft = try optionEntryFinish(lot, action: .expiration, id: "explicit-local-expiration")
        draft.legs[0].form.unitPrice = ""; draft.legs[0].form.fee = "0"
        // These are user-supplied event instants around New York's calendar
        // boundary, not inferred trading, exercise, or settlement schedules.
        draft.timestamp = "2026-11-20T04:59:59.999Z"
        #expect(throws: (any Error).self) { try draft.events(in: opened) }
        draft.timestamp = "2026-11-20T05:00:00Z"
        for field in ["source", "identifier", "evidence"] {
            var missing = draft
            switch field {
            case "source": missing.sourceSystem = ""
            case "identifier": missing.externalID = ""
            default: missing.evidence = ""
            }
            #expect(throws: OptionTradeEntryError.missingExecution) { try missing.events(in: opened) }
        }
        let events = try draft.events(in: opened)
        guard case .optionSettlement(let settlement) = events[0].payload else { Issue.record("Expected explicit local expiration"); return }
        #expect(settlement.contract == contract && settlement.action == .expiration)
        #expect(settlement.evidence == draft.evidence && events[0].effectiveAt == (try LedgerCSV.timestamp(draft.timestamp)))
        #expect(settlement.contract.exerciseDeadline == nil && settlement.contract.settlementAt == nil)
        #expect(opened.events == opening && !lot.isClosed)
        #expect(try optionEntrySnapshot(opening + events).state.lots.allSatisfy(\.isClosed))
    }

    @Test func spreadUsesTwoActualFillsAndOneCommonStrategyWithStableIdentities() throws {
        let snapshot = try optionEntrySnapshot()
        var first = try optionEntryPrepared(spread: true), second = try optionEntryPrepared(spread: true)
        first.strategyPurpose = .totalReturn; second.strategyPurpose = .totalReturn
        let events = try first.events(in: snapshot)
        #expect(events == (try second.events(in: snapshot)))
        #expect(events == (try first.events(in: snapshot)))
        #expect(events.count == 2 && Set(events.map(\.id)).count == 2)
        #expect(Set(try events.map { try $0.idempotencyKey }).count == 2)
        #expect(events.map { $0.source.externalTransactionID } == ["execution-42-short-fill", "execution-42-long-fill"])
        #expect(events[0].multiLegGroupID == events[1].multiLegGroupID && events[0].multiLegGroupID != nil)
        guard case .trade(let short) = events[0].payload, case .trade(let long) = events[1].payload else {
            Issue.record("Expected a two-leg opening batch"); return
        }
        #expect(short.side == .sell && long.side == .buy && short.effect == .open && long.effect == .open)
        #expect(short.unitPrice == (try Money("2.5")) && long.unitPrice == (try Money("1")))
        #expect(short.fee == (try Money("1.3")) && short.strategy == long.strategy)
        #expect(short.strategy?.purpose == .totalReturn)
        let state = try LedgerEngine.replay(accounts: snapshot.accounts, events: events)
        #expect(state.cashByAccount["A"] == (try Money("297.4")))
        #expect(state.realizations.isEmpty && state.lots.count == 2)
    }

    @Test func openingBlankMetadataUsesStableLocalIdentityWithoutMutatingDraft() throws {
        let snapshot = try optionEntrySnapshot()
        for blank in ["", " \t\n"] {
            var draft = try optionEntryPrepared()
            draft.sourceSystem = blank; draft.externalID = blank; draft.evidence = blank
            let original = draft
            let events = try draft.events(in: snapshot)
            let event = try #require(events.first)
            #expect(events.count == 1 && events == (try draft.events(in: snapshot)))
            #expect(draft == original)
            #expect(event.source.sourceSystem == "local-manual-option-opening.v1")
            #expect(event.source.externalTransactionID == "local-option-opening.v1:" + draft.id.uuidString + ":" + draft.legs[0].id)
            #expect(event.source.evidence.hasPrefix("用户手工录入开仓；未提供附加记录依据。"))
            #expect(event.source.evidence.hasSuffix("内部记录编号由软件生成，非券商成交编号。"))
            #expect(event.source.fileHash == nil && event.source.rowIndex == nil)
            #expect(event.effectiveAt == (try LedgerCSV.timestamp(draft.timestamp)) && event.notes == draft.notes)
            guard case .trade(let trade) = event.payload else { Issue.record("Expected opening trade"); return }
            #expect(trade.effect == .open && trade.unitPrice == (try Money("2.5")) && trade.fee == (try Money("1.3")))
        }
    }

    @Test func openingPartialMetadataPreservesEveryProvidedValue() throws {
        let snapshot = try optionEntrySnapshot()
        // Cover every partially supplied combination; surrounding whitespace in
        // nonblank source identities is retained rather than silently normalized.
        for supplied in 1..<7 {
            var draft = try optionEntryPrepared()
            let source = " broker-record ", executionID = " execution-42 ", evidence = " User supplied receipt reference "
            draft.sourceSystem = supplied & 1 != 0 ? source : " \t"
            draft.externalID = supplied & 2 != 0 ? executionID : " \n"
            draft.evidence = supplied & 4 != 0 ? evidence : " \t"
            let original = draft
            let event = try #require(draft.events(in: snapshot).first)
            #expect(draft == original)
            #expect(event.source.sourceSystem == (supplied & 1 != 0 ? source : "local-manual-option-opening.v1"))
            #expect(event.source.externalTransactionID == (supplied & 2 != 0 ? executionID
                : "local-option-opening.v1:" + draft.id.uuidString + ":" + draft.legs[0].id))
            let recordedEvidence = supplied & 4 != 0 ? evidence : "用户手工录入开仓；未提供附加记录依据。"
            if supplied & 2 != 0 {
                #expect(event.source.evidence == recordedEvidence)
            } else {
                #expect(event.source.evidence.hasPrefix(recordedEvidence))
                #expect(event.source.evidence.hasSuffix("内部记录编号由软件生成，非券商成交编号。"))
            }
        }
    }

    @Test func singleLegPreservesBrokerIDAndMultiLegKeepsExplicitAndInternalIDsDistinct() throws {
        let snapshot = try optionEntrySnapshot(), single = try optionEntryPrepared()
        #expect(try single.events(in: snapshot)[0].source.externalTransactionID == "execution-42")
        var spread = try optionEntryPrepared(spread: true)
        #expect(spread.externalID.isEmpty)
        #expect(try spread.events(in: snapshot).count == 2)
        spread.legs[1].form.externalID = ""
        let mixed = try spread.events(in: snapshot)
        #expect(mixed[0].source.externalTransactionID == "execution-42-short-fill")
        #expect(mixed[0].source.evidence == spread.evidence)
        #expect(mixed[1].source.externalTransactionID == "local-option-opening.v1:" + spread.id.uuidString + ":" + spread.legs[1].id)
        #expect(mixed[1].source.evidence.hasPrefix(spread.evidence))
        #expect(mixed[1].source.evidence.hasSuffix("内部记录编号由软件生成，非券商成交编号。"))
        spread.legs[1].form.externalID = spread.legs[0].form.externalID
        #expect(throws: OptionTradeEntryError.duplicateExecutionID) { try spread.events(in: snapshot) }
        // A shared order number is not repurposed as either leg's fill identity.
        spread.externalID = "one-order-number"
        spread.legs[0].form.externalID = ""; spread.legs[1].form.externalID = " \t\n"
        let original = spread, internalEvents = try spread.events(in: snapshot)
        #expect(spread == original && internalEvents == (try spread.events(in: snapshot)))
        #expect(internalEvents.map { $0.source.externalTransactionID } == spread.legs.map {
            "local-option-opening.v1:" + spread.id.uuidString + ":" + $0.id
        })
        #expect(Set(try internalEvents.map { try $0.idempotencyKey }).count == 2)
        #expect(internalEvents[0].multiLegGroupID == internalEvents[1].multiLegGroupID && internalEvents[0].multiLegGroupID != nil)
        #expect(internalEvents.allSatisfy { $0.source.evidence.hasSuffix("内部记录编号由软件生成，非券商成交编号。") })
        // An explicitly supplied identifier also cannot collide with another
        // leg's software-generated identity in the same draft.
        spread.legs[0].form.externalID = "local-option-opening.v1:" + spread.id.uuidString + ":" + spread.legs[1].id
        #expect(throws: OptionTradeEntryError.duplicateExecutionID) { try spread.events(in: snapshot) }
    }

    @Test func openingInternalIdentitiesRemainStableAcrossStorePreviewsAndPriceConflicts() async throws {
        for spread in [false, true] {
            let store = try LedgerStore(path: ":memory:")
            let initial = try await store.snapshot()
            let created = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
            var draft = try optionEntryPrepared(spread: spread)
            draft.sourceSystem = ""; draft.externalID = ""; draft.evidence = ""
            for index in draft.legs.indices { draft.legs[index].form.externalID = "" }
            let events = try draft.events(in: created)
            let first = try await store.previewManual(events: events, expectedRevision: created.revision)
            let retry = try await store.previewManual(events: draft.events(in: created), expectedRevision: created.revision)
            #expect(first.canCommit && first.rows == retry.rows && first.projectedState == retry.projectedState)
            await store.cancel(planID: retry.id)
            let committed = try await store.commit(planID: first.id, expectedRevision: created.revision)
            let duplicate = try await store.previewManual(events: draft.events(in: committed), expectedRevision: committed.revision)
            #expect(duplicate.canCommit && duplicate.rows.allSatisfy { $0.disposition == .duplicate })
            let unchanged = try await store.commit(planID: duplicate.id, expectedRevision: committed.revision)
            #expect(unchanged == committed && unchanged.events.count == draft.legs.count)
            draft.legs[0].form.unitPrice = "2.6"
            let changed = try draft.events(in: unchanged)
            #expect(changed.map(\.id) == events.map(\.id) && changed.map(\.source) == events.map(\.source))
            let conflict = try await store.previewManual(events: changed, expectedRevision: unchanged.revision)
            #expect(!conflict.canCommit && conflict.rows.contains { $0.disposition == .conflict })
            #expect(try await store.snapshot() == committed)
        }
    }

    @Test func freshOpeningDraftsWithoutBrokerIDsHaveDistinctInternalIdentities() throws {
        let snapshot = try optionEntrySnapshot()
        for spread in [false, true] {
            var first = try optionEntryPrepared(spread: spread), second = try optionEntryPrepared(spread: spread)
            first.sourceSystem = ""; first.externalID = ""; first.evidence = ""
            second.sourceSystem = ""; second.externalID = ""; second.evidence = ""
            for index in first.legs.indices {
                first.legs[index].form.externalID = ""; second.legs[index].form.externalID = ""
            }
            let firstEvents = try first.events(in: snapshot), secondEvents = try second.events(in: snapshot)
            #expect(first.id != second.id)
            #expect(Set(firstEvents.map(\.id)).isDisjoint(with: Set(secondEvents.map(\.id))))
            #expect(Set(try firstEvents.map { try $0.idempotencyKey }).isDisjoint(with: Set(try secondEvents.map { try $0.idempotencyKey })))
            // Without a shared external identity, separate manual declarations
            // cannot establish that they describe the same real-world fill.
        }
    }

    @Test func openingOptionalMetadataStillRejectsDeclaredSyntheticEvidence() throws {
        let snapshot = try optionEntrySnapshot()
        for spread in [false, true] {
            for markedField in ["source", "identifier", "evidence", "notes"] {
                var draft = try optionEntryPrepared(spread: spread)
                draft.sourceSystem = ""; draft.externalID = ""; draft.evidence = ""
                for index in draft.legs.indices { draft.legs[index].form.externalID = "" }
                switch markedField {
                case "source": draft.sourceSystem = "SYNTHETIC source"
                case "identifier":
                    if spread { draft.legs[1].form.externalID = "SYNTHETIC fill" }
                    else { draft.externalID = "SYNTHETIC fill" }
                case "evidence": draft.evidence = "SYNTHETIC receipt"
                default: draft.notes = "SYNTHETIC note"
                }
                let original = draft
                #expect(throws: OptionTradeEntryError.syntheticEvidence) { try draft.events(in: snapshot) }
                #expect(draft == original)
            }
        }
    }

    @Test func closingAndExpirationStillRequireAllExecutionMetadata() throws {
        let snapshot = try optionEntryTwoLots(), lot = try #require(snapshot.state.lots.first)
        for action in [OptionTradeEntryAction.closing, .expiration] {
            for blank in ["", " \t\n"] {
                for field in ["source", "identifier", "evidence"] {
                    var draft = try optionEntryFinish(lot, action: action, id: "finish-42")
                    switch field {
                    case "source": draft.sourceSystem = blank
                    case "identifier": draft.externalID = blank
                    default: draft.evidence = blank
                    }
                    let original = draft
                    #expect(throws: OptionTradeEntryError.missingExecution) { try draft.events(in: snapshot) }
                    #expect(draft == original)
                }
            }
        }
    }

    @Test func repeatedFreshDraftsDeduplicateAndChangedContentConflictsInExistingStore() async throws {
        let store = try LedgerStore(path: ":memory:")
        let initial = try await store.snapshot()
        let created = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
        let first = try optionEntryPrepared(spread: true)
        let preview = try await store.previewManual(events: first.events(in: created), expectedRevision: created.revision)
        #expect(preview.canCommit && preview.rows.allSatisfy { $0.disposition == .new })
        let committed = try await store.commit(planID: preview.id, expectedRevision: created.revision)
        var second = try optionEntryPrepared(spread: true)
        let duplicate = try await store.previewManual(events: second.events(in: committed), expectedRevision: committed.revision)
        #expect(duplicate.canCommit && duplicate.rows.allSatisfy { $0.disposition == .duplicate })
        let unchanged = try await store.commit(planID: duplicate.id, expectedRevision: committed.revision)
        #expect(unchanged.events == committed.events && unchanged.state == committed.state)
        second.legs[0].form.unitPrice = "2.6"
        let conflict = try await store.previewManual(events: second.events(in: unchanged), expectedRevision: unchanged.revision)
        #expect(!conflict.canCommit && conflict.rows.contains { $0.disposition == .conflict })
    }

    @Test func existingCSVAndLegacyManualExecutionsCannotReenterThroughOptionPage() async throws {
        for spread in [false, true] {
            for csv in [false, true] {
                let store = try LedgerStore(path: ":memory:")
                let initial = try await store.snapshot()
                let created = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
                let draft = try optionEntryPrepared(spread: spread), candidates = try draft.events(in: created)
                let imported: LedgerImportPreview
                if csv {
                    let rows = try candidates.map { event in
                        let json = String(decoding: try JSONEncoder().encode(event.payload), as: UTF8.self)
                            .replacingOccurrences(of: "\"", with: "\"\"")
                        return draft.timestamp + ",PAYLOAD," + (event.source.externalTransactionID ?? "")
                            + ",\"" + json + "\"," + (event.multiLegGroupID ?? "")
                    }
                    let bytes = Data(("time,action,execution_id,payload,group\n" + rows.joined(separator: "\n") + "\n").utf8)
                    let mapping = LedgerCSVMapping(fields: [.timestamp: "time", .type: "action", .externalID: "execution_id",
                        .payloadJSON: "payload", .multiLegGroupID: "group"])
                    imported = try await store.previewCSV(data: bytes, accountID: "A", sourceSystem: draft.sourceSystem,
                        mapping: mapping, excludedRows: [], expectedRevision: created.revision)
                } else {
                    let oldEvents = candidates.enumerated().map { index, event in
                        LedgerEvent(id: "legacy-manual-\(index)", accountID: event.accountID, effectiveAt: event.effectiveAt,
                            source: .init(sourceSystem: draft.sourceSystem, externalTransactionID: event.source.externalTransactionID,
                                evidence: "Original manually entered broker receipt"), payload: event.payload,
                            multiLegGroupID: event.multiLegGroupID)
                    }
                    imported = try await store.previewManual(events: oldEvents, expectedRevision: created.revision)
                }
                #expect(imported.canCommit)
                let recorded = try await store.commit(planID: imported.id, expectedRevision: created.revision)
                let retry = try await store.previewManual(events: draft.events(in: recorded), expectedRevision: recorded.revision)
                #expect(retry.rows.count == candidates.count)
                #expect(retry.rows.allSatisfy { $0.disposition == .duplicate || $0.disposition == .conflict })
                #expect(!retry.rows.contains { $0.disposition == .new })
                #expect(try await store.snapshot() == recorded)
            }
        }
    }

    @Test func partialCloseThenExplicitExpirationUseOriginalLotAndExactActualFees() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryPrepared().events(in: empty)
        let opened = try optionEntrySnapshot(opening), lot = try #require(opened.state.lots.first)
        var close = try optionEntryFinish(lot, action: .closing, id: "close-one")
        close.legs[0].form.quantity = "1"
        let closing = try close.events(in: opened)
        guard case .trade(let trade) = closing[0].payload else { Issue.record("Expected closing trade"); return }
        #expect(trade.side == .buy && trade.effect == .close && trade.openingLotID == nil)
        #expect(trade.selections == [.init(lotID: lot.id, quantity: try Money("1"))])
        let partiallyClosed = try optionEntrySnapshot(opening + closing)
        #expect(partiallyClosed.state.realizations[0].pnl == (try Money("138.7")))
        let remaining = try #require(partiallyClosed.state.lots.first)
        #expect(remaining.quantityRemaining == (try Money("1")))
        var expiration = try optionEntryFinish(remaining, action: .expiration, id: "expiry-one")
        expiration.legs[0].form.unitPrice = ""; expiration.legs[0].form.fee = "0.15"
        let expired = try expiration.events(in: partiallyClosed)
        guard case .optionSettlement(let settlement) = expired[0].payload else { Issue.record("Expected explicit expiration"); return }
        #expect(settlement.action == .expiration && settlement.side == .short)
        #expect(settlement.equitySelections.isEmpty && settlement.acquiredLotIDs.isEmpty)
        let final = try optionEntrySnapshot(opening + closing + expired)
        #expect(final.state.lots.allSatisfy(\.isClosed))
        #expect(final.state.realizations[1].pnl == (try Money("249.2")))
        #expect(final.state.cashByAccount["A"] == (try Money("387.9")))
    }

    @Test func oneClosingFillConsumesTwoLotsWithOneFeeAndRetainsLedgerDeduplication() async throws {
        let store = try LedgerStore(path: ":memory:"), fixture = try optionEntryTwoLots()
        let initial = try await store.snapshot()
        let created = try await store.createAccount(.init(id: "A", name: "Account A"), expectedRevision: initial.revision)
        let openingPlan = try await store.previewManual(events: fixture.events, expectedRevision: created.revision)
        #expect(openingPlan.canCommit)
        let opened = try await store.commit(planID: openingPlan.id, expectedRevision: created.revision)
        let lots = opened.state.lots.sorted { $0.acquiredAt < $1.acquiredAt }
        try #require(lots.count == 2)
        var draft = try optionEntryFinish(lots[0], action: .closing, id: "close-001", otherClosingLots: [lots[1]])
        draft.closingAllocations = [lots[0].id: "1", lots[1].id: "1"]
        draft.legs[0].form.quantity = "2"; draft.legs[0].form.unitPrice = "1"; draft.legs[0].form.fee = "1.30"
        let events = try draft.events(in: opened)
        try #require(events.count == 1)
        let event = events[0]
        #expect(event.source.externalTransactionID == "close-001")
        guard case .trade(let trade) = event.payload else { Issue.record("Expected one closing fill"); return }
        #expect(trade.quantity == (try Money("2")) && trade.fee == (try Money("1.30")))
        let expectedSelections = lots.sorted { $0.id < $1.id }.map { LedgerLotSelection(lotID: $0.id, quantity: $0.quantityRemaining) }
        #expect(trade.selections == expectedSelections)
        var changedDraft = draft; changedDraft.legs[0].form.fee = "1.31"
        let changedEvents = try changedDraft.events(in: opened)
        #expect(changedEvents[0].id == event.id && changedEvents[0].source == event.source)
        let closingPlan = try await store.previewManual(events: events, expectedRevision: opened.revision)
        #expect(closingPlan.canCommit && closingPlan.rows.count == 1 && closingPlan.rows[0].disposition == .new)
        let committed = try await store.commit(planID: closingPlan.id, expectedRevision: opened.revision)
        #expect(committed.state.lots.allSatisfy(\.isClosed))
        let realizations = committed.state.realizations.filter { $0.eventID == event.id }
        #expect(realizations.count == 2)
        #expect(realizations.first { $0.lotID == lots[0].id }?.pnl == (try Money("148.70")))
        #expect(realizations.first { $0.lotID == lots[1].id }?.pnl == (try Money("198.70")))
        #expect(committed.state.cashByAccount["A"] == (try Money("347.40")))
        let closingPostings = committed.state.postings.filter { $0.eventID == event.id }
        #expect(closingPostings.count == 1 && closingPostings.first?.transactionFee == (try Money("1.30")))
        // Retry the original real fill, rather than inventing another ID or
        // authorizing a fresh draft against the now-closed lots.
        let duplicate = try await store.previewManual(events: events, expectedRevision: committed.revision)
        #expect(duplicate.canCommit && duplicate.rows.count == 1 && duplicate.rows[0].disposition == .duplicate)
        let unchanged = try await store.commit(planID: duplicate.id, expectedRevision: committed.revision)
        #expect(unchanged.events == committed.events && unchanged.state == committed.state)
        let conflict = try await store.previewManual(events: changedEvents, expectedRevision: unchanged.revision)
        #expect(!conflict.canCommit && conflict.rows.contains { $0.disposition == .conflict })
    }

    @Test func closingCanSelectAnotherLotOrPartiallyConsumeMultipleLots() throws {
        let opened = try optionEntryTwoLots(quantity: "2"), lots = opened.state.lots.sorted { $0.acquiredAt < $1.acquiredAt }
        try #require(lots.count == 2)
        var draft = try optionEntryFinish(lots[0], action: .closing, id: "close-partial", otherClosingLots: [lots[1]])
        #expect(draft.closingCandidates == lots && draft.closingAllocations == [lots[0].id: "2"])
        draft.closingAllocations = [lots[1].id: "2"]
        draft.legs[0].form.quantity = "1"
        let subset = try draft.events(in: opened)
        guard case .trade(let subsetTrade) = subset[0].payload else { Issue.record("Expected selected-lot close"); return }
        #expect(subsetTrade.selections == [.init(lotID: lots[1].id, quantity: try Money("1"))])
        let subsetState = try optionEntrySnapshot(opened.events + subset).state
        #expect(subsetState.lots.first { $0.id == lots[0].id }?.quantityRemaining == (try Money("2")))
        #expect(subsetState.lots.first { $0.id == lots[1].id }?.quantityRemaining == (try Money("1")))
        draft.closingAllocations = [lots[0].id: "1", lots[1].id: "1"]
        draft.legs[0].form.quantity = "2"
        let partial = try draft.events(in: opened)
        let partialState = try optionEntrySnapshot(opened.events + partial).state
        let remaining = try Money("1")
        #expect(partialState.lots.count == 2 && partialState.lots.allSatisfy { $0.quantityRemaining == remaining })
        #expect(partialState.realizations.count == 2)
    }

    @Test func closingCandidatesRejectMixedAccountsFullContractTermsSidesAndRepeatedIDs() throws {
        let opened = try optionEntryTwoLots(), lots = opened.state.lots.sorted { $0.acquiredAt < $1.acquiredAt }
        try #require(lots.count == 2)
        let empty = try optionEntrySnapshot()
        var otherAccount = try optionEntryPrepared(externalID: "account-b-open"); otherAccount.accountID = "B"
        let accountLot = try #require(optionEntrySnapshot(otherAccount.events(in: empty)).state.lots.first)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: lots[0], action: .closing, otherClosingLots: [accountLot])
        }
        guard case .option(let contract) = lots[1].instrument,
              case .trade(let opening) = opened.events[1].payload else { Issue.record("Expected option fixtures"); return }
        var differentTerms = lots[1]
        differentTerms.instrument = .option(.init(occSymbol: contract.occSymbol, versionID: contract.versionID,
            effectiveFrom: contract.effectiveFrom, effectiveTo: contract.effectiveTo, quoteMultiplier: contract.quoteMultiplier,
            exerciseConsideration: contract.exerciseConsideration, deliverables: contract.deliverables,
            deliverableCash: contract.deliverableCash, settlementType: contract.settlementType, exerciseStyle: contract.exerciseStyle,
            tradingEndsAt: contract.tradingEndsAt, exerciseDeadline: contract.exerciseDeadline, settlementAt: contract.settlementAt,
            memoReferences: contract.memoReferences + ["Different contract evidence"]))
        // Even the same OCC and version spelling cannot substitute different frozen terms.
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: lots[0], action: .closing, otherClosingLots: [differentTerms])
        }
        let longEvent = LedgerEvent(id: "long-opening", accountID: "A", effectiveAt: opened.events[1].effectiveAt,
            source: .init(sourceSystem: "broker-record", externalTransactionID: "long-opening", evidence: "Long execution receipt"),
            payload: .trade(.init(instrument: opening.instrument, side: .buy, effect: .open, quantity: opening.quantity,
                unitPrice: opening.unitPrice, fee: opening.fee, openingLotID: "long-lot", strategy: opening.strategy)))
        let longLot = try #require(optionEntrySnapshot([longEvent]).state.lots.first)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: lots[0], action: .closing, otherClosingLots: [longLot])
        }
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: lots[0], action: .closing, otherClosingLots: [lots[0]])
        }
        let closeSecond = try optionEntryFinish(lots[1], action: .closing, id: "close-before-selection")
        let withClosedLot = try optionEntrySnapshot(opened.events + closeSecond.events(in: opened))
        let closedCandidate = try #require(withClosedLot.state.lots.first { $0.id == lots[1].id })
        #expect(closedCandidate.isClosed)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: lots[0], action: .closing, otherClosingLots: [closedCandidate])
        }
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: lots[0], action: .expiration, otherClosingLots: [lots[1]])
        }
    }

    @Test func closingAllocationsRejectUnknownEmptyFractionalExcessAndMismatchedTotals() throws {
        let opened = try optionEntryTwoLots(), lots = opened.state.lots.sorted { $0.acquiredAt < $1.acquiredAt }
        try #require(lots.count == 2)
        var draft = try optionEntryFinish(lots[0], action: .closing, id: "close-invalid", otherClosingLots: [lots[1]])
        draft.legs[0].form.quantity = "2"
        draft.closingAllocations = [:]
        #expect(throws: OptionTradeEntryError.invalidLot) { try draft.events(in: opened) }
        draft.closingAllocations = [lots[0].id: "1", "not-an-original-lot": "1"]
        #expect(throws: OptionTradeEntryError.invalidLot) { try draft.events(in: opened) }
        for allocation in ["0", "-1", "0.5", "2"] {
            draft.closingAllocations = [lots[0].id: allocation, lots[1].id: "1"]
            #expect(throws: OptionTradeEntryError.invalidQuantity) { try draft.events(in: opened) }
        }
        draft.closingAllocations = [lots[0].id: "1", lots[1].id: "1"]
        for total in ["1", "3", "1.5"] {
            draft.legs[0].form.quantity = total
            #expect(throws: OptionTradeEntryError.invalidQuantity) { try draft.events(in: opened) }
        }
    }

    @Test func closingRejectsChangesToEverySelectedLotWithoutBlockingUnselectedChanges() throws {
        let opened = try optionEntryTwoLots(quantity: "2"), lots = opened.state.lots.sorted { $0.acquiredAt < $1.acquiredAt }
        try #require(lots.count == 2)
        var draft = try optionEntryFinish(lots[0], action: .closing, id: "close-both", otherClosingLots: [lots[1]])
        draft.timestamp = "2026-10-27T15:00:00Z"
        draft.closingAllocations = [lots[0].id: "1", lots[1].id: "1"]; draft.legs[0].form.quantity = "2"
        var concurrent = try optionEntryFinish(lots[1], action: .closing, id: "other-close")
        concurrent.legs[0].form.quantity = "1"
        let changed = try optionEntrySnapshot(opened.events + concurrent.events(in: opened))
        #expect(throws: OptionTradeEntryError.changedLot) { try draft.events(in: changed) }
        draft.closingAllocations = [lots[0].id: "1"]; draft.legs[0].form.quantity = "1"
        #expect(try draft.events(in: changed).count == 1)
        draft.closingAllocations = [lots[1].id: "1"]
        #expect(throws: OptionTradeEntryError.changedLot) { try draft.events(in: changed) }
    }

    @Test func closingValidatesTheSourceOfEverySelectedLot() throws {
        let opened = try optionEntryTwoLots(), source = opened.events[1]
        let marked = LedgerEvent(id: source.id, accountID: source.accountID, effectiveAt: source.effectiveAt,
            source: .init(sourceSystem: "synthetic-loader", externalTransactionID: source.source.externalTransactionID,
                evidence: "Synthetic execution illustration"), payload: source.payload, multiLegGroupID: source.multiLegGroupID)
        let snapshot = try optionEntrySnapshot([opened.events[0], marked])
        let lots = snapshot.state.lots.sorted { $0.acquiredAt < $1.acquiredAt }
        try #require(lots.count == 2)
        var draft = try optionEntryFinish(lots[0], action: .closing, id: "close-sources", otherClosingLots: [lots[1]])
        draft.closingAllocations = [lots[0].id: "1", lots[1].id: "1"]; draft.legs[0].form.quantity = "2"
        #expect(throws: OptionTradeEntryError.syntheticEvidence) { try draft.events(in: snapshot) }
        draft.closingAllocations = [lots[0].id: "1"]; draft.legs[0].form.quantity = "1"
        #expect(try draft.events(in: snapshot).count == 1)
    }

    @Test func closeCannotChangeAccountsOversellUseFractionalContractsOrRebaseChangedLots() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryPrepared().events(in: empty)
        let opened = try optionEntrySnapshot(opening), lot = try #require(opened.state.lots.first)
        var draft = try optionEntryFinish(lot, action: .closing, id: "close-a")
        draft.accountID = "B"
        #expect(throws: OptionTradeEntryError.invalidAccount) { try draft.events(in: opened) }
        draft.accountID = "A"
        for quantity in ["3", "1.5", "0", "-1"] {
            draft.legs[0].form.quantity = quantity
            #expect(throws: OptionTradeEntryError.invalidQuantity) { try draft.events(in: opened) }
        }
        draft.legs[0].form.quantity = "1"
        let firstClose = try draft.events(in: opened), changed = try optionEntrySnapshot(opening + firstClose)
        #expect(throws: OptionTradeEntryError.changedLot) { try draft.events(in: changed) }
        let remaining = try #require(changed.state.lots.first)
        var finalDraft = try optionEntryFinish(remaining, action: .closing, id: "close-b")
        finalDraft.timestamp = "2026-10-27T15:00:00Z"
        let finalClose = try finalDraft.events(in: changed)
        let finished = try optionEntrySnapshot(opening + firstClose + finalClose)
        let closedLot = try #require(finished.state.lots.first)
        #expect(throws: OptionTradeEntryError.invalidLot) {
            try OptionTradeEntryDraft(lot: closedLot, action: .closing)
        }
    }

    @Test func expirationBeforeTheActualExerciseDeadlineIsRejected() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryPrepared().events(in: empty)
        let snapshot = try optionEntrySnapshot(opening), lot = try #require(snapshot.state.lots.first)
        var draft = try optionEntryFinish(lot, action: .expiration, id: "expiry-a")
        draft.timestamp = "2026-11-20T21:59:59.9999Z"
        #expect(throws: LedgerError.invalidContract) { try draft.events(in: snapshot) }
        draft.timestamp = "2026-11-20T22:00:00Z"
        #expect(try draft.events(in: snapshot).count == 1)
    }

    @Test func existingContractReuseIsExplicitAccountBoundAndRetainsFullOriginalTerms() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryPrepared().events(in: empty)
        let snapshot = try optionEntrySnapshot(opening)
        guard case .trade(let trade) = opening[0].payload, case .option(let contract) = trade.instrument else {
            Issue.record("Expected complete option contract"); return
        }
        var draft = try optionEntryPrepared(externalID: "execution-next")
        draft.legs[0].form.existingOption = contract
        #expect(throws: OptionTradeEntryError.unconfirmedContract) { try draft.events(in: snapshot) }
        try draft.legs[0].reuseContract(contract)
        draft.legs[0].form.memoReference = ""; draft.legs[0].form.effectiveFrom = ""
        let accepted = try draft.events(in: snapshot)
        guard case .trade(let actual) = accepted[0].payload else { Issue.record("Expected opening trade"); return }
        #expect(actual.instrument == .option(contract))
        draft.accountID = "B"
        #expect(throws: OptionTradeEntryError.invalidContract) { try draft.events(in: snapshot) }
        draft.legs[0].enterContractManually()
        #expect(draft.legs[0].form.existingOption == nil && !draft.legs[0].contractConfirmed)
    }

    @Test func closingChecksOriginalEventProvenanceEvenWhenTheLotHasNoMarker() throws {
        let empty = try optionEntrySnapshot(), opening = try optionEntryPrepared().events(in: empty)[0]
        let marked = LedgerEvent(id: opening.id, accountID: opening.accountID, effectiveAt: opening.effectiveAt,
            source: .init(sourceSystem: "synthetic-loader", externalTransactionID: opening.source.externalTransactionID,
                evidence: "Synthetic execution illustration"), payload: opening.payload)
        let snapshot = try optionEntrySnapshot([marked]), lot = try #require(snapshot.state.lots.first)
        let draft = try optionEntryFinish(lot, action: .closing, id: "close-marker")
        #expect(throws: OptionTradeEntryError.syntheticEvidence) { try draft.events(in: snapshot) }
        var newOpening = try optionEntryPrepared(externalID: "new-opening")
        if case .option(let contract) = lot.instrument { try newOpening.legs[0].reuseContract(contract) }
        #expect(throws: OptionTradeEntryError.syntheticEvidence) { try newOpening.events(in: snapshot) }
    }
}
