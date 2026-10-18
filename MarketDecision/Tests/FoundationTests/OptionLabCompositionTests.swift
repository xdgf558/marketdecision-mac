import Foundation
import Testing
import CoreDomain
import DataProviders
import Persistence
import SecuritySupport
@testable import AppComposition

private actor OptionLabCredentialProbe: CredentialStorage {
    private(set) var calls = 0
    func contains(reference: String) -> Bool { calls += 1; return false }
    func save(_ secret: Data, reference: String) { calls += 1 }
    func delete(reference: String) { calls += 1 }
}

@Suite @MainActor struct OptionLabCompositionTests {
    @Test func openingLabIsLazyIsolatedAndDoesNotTouchCredentialsOrLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let optionsPath = folder.appendingPathComponent("options-lab.sqlite").path
        let ledgerPath = folder.appendingPathComponent("portfolio-ledger.sqlite").path
        let credentials = OptionLabCredentialProbe()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"),
            credentials: credentials, offlineResearchDatabasePath: folder.appendingPathComponent("offline-issuer.sqlite").path)
        #expect(!FileManager.default.fileExists(atPath: optionsPath))
        let first = try await environment.makeOptionLabWorkspaceModel()
        let second = try await environment.makeOptionLabWorkspaceModel()
        await first.load(); await second.load()
        let history = try #require(first.history), transfer = try #require(first.transfer)
        await history.load(); await transfer.load()
        #expect(history.revision == first.revision && transfer.status?.revision == first.revision)
        #expect(history.dailySummaries.isEmpty && history.historySummaries.isEmpty)
        #expect(history.dailyReport == nil && history.historyReport == nil)
        #expect(first.revision == second.revision && first.revision != nil)
        #expect(first.report == nil && first.saved.isEmpty && first.ledgerSnapshot == nil)
        #expect(FileManager.default.fileExists(atPath: optionsPath))
        #expect(!FileManager.default.fileExists(atPath: ledgerPath))
        #expect(await credentials.calls == 0)
        #expect(try DatabaseStore(path: optionsPath, purpose: .optionsLab).migrationVersions() == ["foundation.v1", "options-lab.v1", "options-lab.v2"])
        #expect(throws: MigrationError.incompatiblePurpose) {
            try DatabaseStore(path: optionsPath, purpose: .portfolioLedger)
        }
    }

    @Test func brokenLedgerDoesNotDisableIndependentLabOrDemo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("portfolio-ledger.sqlite").path
        _ = try DatabaseStore(path: path)
        let credentials = OptionLabCredentialProbe()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"),
            credentials: credentials, offlineResearchDatabasePath: folder.appendingPathComponent("offline.sqlite").path)
        let lab = try await environment.makeOptionLabWorkspaceModel()
        await lab.load()
        #expect(lab.revision != nil && lab.ledgerError == nil)
        await lab.readLedger()
        #expect(lab.ledgerError != nil && lab.ledgerSnapshot == nil)
        #expect(lab.revision != nil)
        #expect(try await environment.quotes.quote(for: "DEMO").symbol == "DEMO")
        #expect(await credentials.calls == 0)
        #expect(try !DatabaseStore(path: path).migrationVersions().contains("portfolio-ledger.v1"))
    }

    @Test func wrongPurposeOptionsFileIsRefusedWithoutChangingLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("options-lab.sqlite").path
        let original = try DatabaseStore(path: path, purpose: .portfolioLedger)
        let history = try original.migrationVersions()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"),
            credentials: OptionLabCredentialProbe(), offlineResearchDatabasePath: folder.appendingPathComponent("offline.sqlite").path)
        await #expect(throws: MigrationError.incompatiblePurpose) { try await environment.makeOptionLabWorkspaceModel() }
        #expect(try DatabaseStore(path: path, purpose: .portfolioLedger).migrationVersions() == history)
        #expect(try await environment.quotes.quote(for: "DEMO").symbol == "DEMO")
    }
}
