import Foundation
import Testing
import AppComposition
import DataContracts
import DataProviders
import FundamentalsEngine
import Persistence
import SecuritySupport

private actor OfflineCompositionCredentials: CredentialStorage {
    private(set) var checks = 0
    func contains(reference: String) -> Bool { checks += 1; return false }
    func save(_ secret: Data, reference: String) {}
    func delete(reference: String) {}
}

@Suite @MainActor struct OfflineIssuerCompositionTests {
    @Test func lazyOfflinePreparationDoesNotTouchCredentialsOrExistingDemoDatabase() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-composition-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("offline-issuer.sqlite").path
        let credentials = OfflineCompositionCredentials()
        let database = try DatabaseStore(path: folder.appendingPathComponent("foundation.sqlite").path)
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: database,
            credentials: credentials, offlineResearchDatabasePath: path)
        let revision = await environment.businessData.revision()
        let workspace = WorkspaceModel { _ in environment }
        #expect(!workspace.isPrepared)
        #expect(await workspace.refresh())
        #expect(workspace.isPrepared)
        #expect(!FileManager.default.fileExists(atPath: path))
        let page = try await workspace.makeOfflineIssuerWorkspace()
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(page.document == nil && page.saved.isEmpty && page.issuers.count == 10)
        #expect(await environment.businessData.revision() == revision)
        #expect(await credentials.checks == 0)
        #expect(workspace.quote?.quality.contains(.synthetic) == true)
    }

    @Test func independentPagesReopenTheSeparateStoreWithoutSharingSelectionOrReplay() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-pages-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = try AppEnvironment.mock(databasePath: folder.appendingPathComponent("foundation.sqlite").path)
        let first = try await environment.makeOfflineIssuerWorkspace()
        let second = try await environment.makeOfflineIssuerWorkspace()
        #expect(first !== second)
        await first.select("MSFT")
        #expect(first.document != nil && second.document == nil)
        await first.save()
        #expect(first.isSaved)
        let reopened = try await AppEnvironment.mock(databasePath: folder.appendingPathComponent("foundation.sqlite").path)
            .makeOfflineIssuerWorkspace()
        await reopened.load()
        let record = try #require(reopened.saved.first)
        await reopened.open(record.id)
        #expect(reopened.document?.id == first.document?.id)
        #expect(reopened.recomputationState == .notVerified)
        await reopened.recompute()
        #expect(reopened.recomputationState == .matched)
        #expect(first.recomputationState == .notVerified && second.document == nil)
        let demo = environment.makeResearchWorkspace()
        await demo.load()
        #expect(demo.saved.isEmpty)
    }

    @Test func wrongPurposeOfflinePathFailsWithoutBreakingDemoPreparation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-purpose-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let businessPath = folder.appendingPathComponent("foundation.sqlite").path
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: businessPath),
            credentials: OfflineCompositionCredentials(), offlineResearchDatabasePath: businessPath)
        let workspace = WorkspaceModel { _ in environment }
        #expect(await workspace.refresh())
        await #expect(throws: MigrationError.incompatiblePurpose) { try await workspace.makeOfflineIssuerWorkspace() }
        #expect(await workspace.refresh())
        #expect(workspace.initializationError == nil && workspace.research != nil)
    }

    @Test func cancelledOfflinePreparationCannotReturnAPageOrReadCredentials() async throws {
        let credentials = OfflineCompositionCredentials()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"), credentials: credentials)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await environment.makeOfflineIssuerWorkspace()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await credentials.checks == 0)
    }
}
