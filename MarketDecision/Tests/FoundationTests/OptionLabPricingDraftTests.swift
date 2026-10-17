import Foundation
import Testing
import CoreDomain
import OptionsAnalytics
import Persistence
@testable import AppComposition

@Suite("Optional option pricing input and snapshot workflow")
struct OptionLabPricingDraftTests {
    @Test func manualAndSyntheticDraftsDoNotImplicitlyEnablePricing() throws {
        let manual = OptionLabInputDraft(), synthetic = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        #expect(!manual.pricing.enabled && manual.pricing.rate.isEmpty && manual.pricing.dividendYield.isEmpty)
        #expect(manual.pricing.volatility.isEmpty && manual.pricing.sourceReference.isEmpty)
        #expect(!synthetic.pricing.enabled)
        #expect(try synthetic.build().pricing == nil)
    }
    @Test func syntheticAssumptionsRequireExplicitSyntheticDraftAndRemainSyntheticAfterEdits() throws {
        var manual = OptionLabInputDraft()
        #expect(throws: OptionLabDraftError.missingField) { try manual.useSyntheticPricingAssumptions() }
        #expect(!manual.pricing.enabled && manual.pricing.rate.isEmpty)
        var synthetic = try OptionLabInputDraft.synthetic(strategy: .putCreditSpread)
        try synthetic.useSyntheticPricingAssumptions()
        synthetic.pricing.volatility = "0.31"
        let input = try synthetic.build(), pricing = try #require(input.pricing)
        #expect(pricing.rate == (try Money("0.05")))
        #expect(pricing.dividendYield == (try Money("0.01")))
        #expect(pricing.volatility == (try Money("0.31")))
        #expect(pricing.source.origin == .synthetic)
        #expect(pricing.source.reference.contains("SYNTHETIC"))
    }
    @Test(arguments: ["rate", "dividendYield", "volatility", "source"])
    func enabledPricingRejectsEachMissingInputWithoutZeroOrSourceFallback(_ missing: String) throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .coveredCall)
        try draft.useSyntheticPricingAssumptions()
        switch missing {
        case "rate": draft.pricing.rate = ""
        case "dividendYield": draft.pricing.dividendYield = ""
        case "volatility": draft.pricing.volatility = ""
        default: draft.pricing.sourceReference = "  "
        }
        #expect(throws: (any Error).self) { try draft.build() }
    }
    @Test func explicitZeroDividendAndExactRatesArePreserved() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        try draft.useSyntheticPricingAssumptions()
        draft.pricing.rate = "0.052345678901234567"; draft.pricing.dividendYield = "0"
        let pricing = try #require(draft.build().pricing)
        #expect(pricing.rate.decimalString == "0.052345678901234567")
        #expect(pricing.dividendYield.decimalString == "0")
    }
    @Test func copyingEnabledPricingPreservesModeAndFullModelInput() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .callCreditSpread)
        try draft.useSyntheticPricingAssumptions()
        draft.pricing.sourceReference = "SYNTHETIC exact reference"
        let original = try draft.build(), copiedDraft = OptionLabInputDraft(input: original)
        let copied = try copiedDraft.build(createdAt: original.createdAt)
        #expect(copiedDraft.pricing.enabled && copied.id != original.id)
        #expect(copied.pricing == original.pricing)
        #expect(copied.underlying.source.origin == .synthetic)
    }
    @Test func disabledPricingExcludesRetainedDraftFieldsInsteadOfUpgradingPayoffResult() throws {
        var draft = try OptionLabInputDraft.synthetic(strategy: .cashSecuredPut)
        try draft.useSyntheticPricingAssumptions(); draft.pricing.enabled = false
        draft.pricing.rate = "invalid retained edit"
        let input = try draft.build()
        #expect(input.pricing == nil)
        #expect(try OptionLabEngine.calculate(input).pricing == nil)
        draft.pricing.enabled = true
        #expect(throws: MoneyError.invalidDecimal) { try draft.build() }
    }
    @Test func oldEncodedInputWithoutPricingStaysPayoffOnlyWhenCopied() throws {
        let original = try OptionLabDemo.input(), data = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pricing")
        let decoded = try JSONDecoder().decode(OptionLabInput.self, from: JSONSerialization.data(withJSONObject: object))
        let copied = OptionLabInputDraft(input: decoded)
        #expect(decoded.pricing == nil && !copied.pricing.enabled && copied.pricing.rate.isEmpty)
        #expect(try copied.build(createdAt: original.createdAt).pricing == nil)
    }
    @Test @MainActor func pricingSnapshotSavesAndReopensOnlyItsFrozenCompleteInputs() async throws {
        let storage = try OptionLabStore(path: ":memory:"), model = OptionLabWorkspaceModel(storage: storage)
        var draft = try OptionLabInputDraft.synthetic(strategy: .putCreditSpread)
        try draft.useSyntheticPricingAssumptions()
        let input = try draft.build()
        await model.load(); await model.calculate(input)
        let calculated = try #require(model.report)
        #expect(calculated.input.pricing == input.pricing && calculated.pricing != nil)
        #expect(await model.save())
        model.disappear(); await model.load()
        #expect(model.report == nil)
        await model.open(input.id)
        #expect(model.report == calculated && model.savedID == input.id)
        #expect(model.report?.pricing?.input == input.pricing)
        model.draftChanged()
        #expect(model.report == nil && !model.canSave)
    }
    @Test func syntheticPricingAloneMakesCopiedDraftSynthetic() throws {
        let base = try OptionLabDemo.input()
        let manual = OptionLabSource(origin: .manual, reference: "explicit manual assumption", enteredAt: base.asOf)
        let leg = base.shortLeg
        let input = OptionLabInput(createdAt: base.createdAt, asOf: base.asOf, strategy: base.strategy,
            shortLeg: .init(contractID: leg.contractID, symbol: leg.symbol, right: leg.right, strike: leg.strike,
                quantity: leg.quantity, expirationDate: leg.expirationDate, bid: leg.bid, ask: leg.ask,
                bidSize: leg.bidSize, askSize: leg.askSize, tick: leg.tick, quotedAt: leg.quotedAt,
                receivedAt: leg.receivedAt, source: manual), longLeg: nil,
            underlying: .init(symbol: base.underlying.symbol, bid: base.underlying.bid, ask: base.underlying.ask,
                quotedAt: base.asOf, receivedAt: base.asOf, source: manual),
            capital: .init(origin: .manual, reference: "manual capital", asOf: base.asOf,
                cashBeforeTrade: base.capital.cashBeforeTrade, committedCash: base.capital.committedCash,
                availableShares: base.capital.availableShares, committedShares: base.capital.committedShares),
            policy: base.policy, expiry: .init(date: base.expiry.date, settlementAt: base.expiry.settlementAt, source: manual),
            scenarioPrices: base.scenarioPrices,
            pricing: .init(rate: try Money("0.05"), dividendYield: try Money("0.01"), volatility: try Money("0.25"),
                source: .init(origin: .synthetic, reference: "SYNTHETIC pricing only", enteredAt: base.asOf)))
        let draft = OptionLabInputDraft(input: input)
        #expect(draft.origin == .synthetic && draft.pricing.enabled)
        #expect(try draft.build(createdAt: base.createdAt).pricing?.source.origin == .synthetic)
    }
    @Test @MainActor func failedLocalIVKeepsIndependentTheoryButNeverSuppliesCanonicalDistribution() async throws {
        let storage = try OptionLabStore(path: ":memory:"), model = OptionLabWorkspaceModel(storage: storage)
        var draft = try OptionLabInputDraft.synthetic(strategy: .coveredCall)
        try draft.useSyntheticPricingAssumptions()
        draft.shortLeg.bid = "100"; draft.shortLeg.ask = "100"
        let input = try draft.build()
        await model.load(); await model.calculate(input)
        let report = try #require(model.report), pricing = try #require(report.pricing)
        let short = try #require(pricing.legs.first)
        #expect(short.theoreticalPrice != nil)
        #expect(short.impliedVolatility.state == .arbitrageViolation)
        #expect(short.impliedVolatility.volatility == nil && short.canonicalGreeks == nil)
        #expect(pricing.distribution == nil && pricing.aggregateGreeks == nil)
        #expect(await model.save())
        model.disappear(); await model.load(); await model.open(input.id)
        #expect(model.report == report && model.report?.pricing?.distribution == nil)
    }

}
