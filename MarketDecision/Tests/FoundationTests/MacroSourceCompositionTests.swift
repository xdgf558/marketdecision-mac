import Foundation
import Testing
import DataContracts
import DataProviders
import SecuritySupport
import MarketAnalytics
import MacroProviders
import Persistence
@testable import AppComposition

private actor MacroCredentialProbe: CredentialStorage {
    private(set) var calls = 0
    func contains(reference: String) -> Bool { calls += 1; return false }
    func save(_ secret: Data, reference: String) { calls += 1 }
    func delete(reference: String) { calls += 1 }
}
private actor MacroQuoteProbe: QuoteProvider {
    nonisolated let id = "SYNTHETIC-macro-quote-probe"
    private(set) var calls = 0
    func quote(for symbol: String) throws -> Quote { calls += 1; throw MarketStateStorageError.notFound }
}

@Suite @MainActor struct MacroSourceCompositionTests {
    @Test func dataCenterNavigationNeverReadsCredentialsOrCallsQuoteProvider() async throws {
        let keys = MacroCredentialProbe(), quotes = MacroQuoteProbe()
        let environment = try AppEnvironment(quotes: quotes, database: DatabaseStore(path: ":memory:"), credentials: keys)
        let page = try await environment.makeMarketStateWorkspaceModel()
        let sources = try #require(page.sources)
        await page.load(); await sources.load()
        #expect(sources.saved.isEmpty && sources.report == nil)
        #expect(await keys.calls == 0)
        #expect(await quotes.calls == 0)
    }

    @Test func pagesShareSourceStoreAndMarketRevisionWithoutRecreatingDatabase() async throws {
        let environment = try AppEnvironment.mock(databasePath: ":memory:")
        let first = try await environment.makeMarketStateWorkspaceModel()
        let second = try await environment.makeMarketStateWorkspaceModel()
        let a = try #require(first.sources), b = try #require(second.sources)
        let market = try MarketStateDemo.input(sessionCount: 5)
        let text = String(decoding: try JSONEncoder().encode(market), as: UTF8.self)
        await first.calculateJSON(text, kind: .marketState)
        #expect(first.canSave)
        try await importSource(a)
        await b.load()
        #expect(b.saved.count == 1)
        #expect(b.saved.first?.id == a.savedID)
        #expect(await first.save() == false)
        #expect(first.hasError && first.savedID == nil)
    }

    @Test func confirmedMarketClearAlsoInvalidatesSourcePageSelectionAndPreview() async throws {
        let environment = try AppEnvironment.mock(databasePath: ":memory:")
        let parent = try await environment.makeMarketStateWorkspaceModel()
        let other = try await environment.makeMarketStateWorkspaceModel()
        let sources = try #require(other.sources)
        try await importSource(sources)
        sources.selectCurrentSource()
        #expect(sources.selectedSources.count == 1)
        let example = try MacroSourceWorkspaceModel.demo(.cboeIndexHistoryCSV)
        await sources.prepare(manifestJSON: example.manifest) { Data(example.raw.utf8) }
        let old = try #require(sources.preview)
        await parent.prepareClear()
        let plan = try #require(parent.plan)
        let approval = MarketStateTransferApproval(plan: plan)
        #expect(await parent.confirm(approval))
        #expect(sources.preview == nil && sources.report == nil && sources.bridge == nil)
        #expect(sources.selectedSources.isEmpty && sources.saved.isEmpty)
        #expect(await sources.confirm(id: old.id, expectedRevision: old.revision) == false)
    }

    private func importSource(_ model: MacroSourceWorkspaceModel) async throws {
        let example = try MacroSourceWorkspaceModel.demo(.cboeIndexHistoryCSV)
        await model.prepare(manifestJSON: example.manifest) { Data(example.raw.utf8) }
        let preview = try #require(model.preview)
        #expect(await model.confirm(id: preview.id, expectedRevision: preview.revision))
        #expect(model.savedID != nil)
    }
}
