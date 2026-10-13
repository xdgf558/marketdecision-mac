import Foundation
import Testing
import CoreDomain
import DataProviders
import PortfolioEngine
import Persistence
import SecuritySupport
@testable import AppComposition

private actor LedgerCredentialProbe: CredentialStorage {
    private(set) var calls = 0
    func contains(reference: String) -> Bool { calls += 1; return false }
    func save(_ secret: Data, reference: String) { calls += 1 }
    func delete(reference: String) { calls += 1 }
}

@Suite @MainActor struct LedgerCompositionTests {
    @Test func lazyIsolatedFileOpensWithoutCredentialsAndSurvivesPageRecreation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("portfolio-ledger.sqlite").path
        let credentials = LedgerCredentialProbe()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"),
            credentials: credentials, offlineResearchDatabasePath: folder.appendingPathComponent("offline-issuer.sqlite").path)
        #expect(!FileManager.default.fileExists(atPath: path))
        let page = try await environment.makeLedgerWorkspaceModel()
        #expect(FileManager.default.fileExists(atPath: path))
        await page.load()
        await page.createAccount(.init(id: "local-a", name: "合成账户"))
        let event = LedgerEvent(id: "deposit", accountID: "local-a", effectiveAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .init(sourceSystem: "synthetic", externalTransactionID: "deposit", evidence: "fixture"),
            payload: .cash(.init(kind: .deposit, amount: try Money("125.25"))))
        await page.prepareManual(events: [event])
        let preview = try #require(page.preview)
        #expect(await page.confirm(id: preview.id, expectedRevision: preview.targetRevision))
        page.disappear()
        let reopened = try await environment.makeLedgerWorkspaceModel()
        await reopened.load()
        #expect(reopened.snapshot?.state.cashByAccount["local-a"]?.decimalString == "125.25")
        #expect(reopened.preview == nil && reopened.message == nil)
        #expect(await credentials.calls == 0)
        let database = try DatabaseStore(path: path, purpose: .portfolioLedger)
        #expect(try database.migrationVersions() == ["foundation.v1", "portfolio-ledger.v1"])
    }

    @Test func memoryPagesShareRecordsButNotInteractionState() async throws {
        let environment = try AppEnvironment.mock(databasePath: ":memory:")
        let first = try await environment.makeLedgerWorkspaceModel()
        let second = try await environment.makeLedgerWorkspaceModel()
        await first.load(); await second.load()
        await first.createAccount(.init(id: "a", name: "A"))
        // Second page cannot silently rebase an old write onto the new revision.
        await second.createAccount(.init(id: "b", name: "B"))
        #expect(second.hasError)
        await second.load()
        #expect(second.snapshot?.accounts.map(\.id) == ["a"])
        #expect(first.message != second.message && second.preview == nil)
    }

    @Test func wrongPurposeLedgerDoesNotOpenOrDisableDemo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("portfolio-ledger.sqlite").path
        _ = try DatabaseStore(path: path)
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"),
            credentials: LedgerCredentialProbe(), offlineResearchDatabasePath: folder.appendingPathComponent("offline.sqlite").path)
        await #expect(throws: MigrationError.incompatiblePurpose) { try await environment.makeLedgerWorkspaceModel() }
        #expect(try await environment.quotes.quote(for: "DEMO").symbol == "DEMO")
        let original = try DatabaseStore(path: path)
        #expect(try !original.migrationVersions().contains("portfolio-ledger.v1"))
    }
}
