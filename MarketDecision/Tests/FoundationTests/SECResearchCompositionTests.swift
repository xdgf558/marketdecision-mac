import Foundation
import Testing
import AppComposition
import Persistence

@Suite @MainActor struct SECResearchCompositionTests {
    @Test func startupKeepsSECStoreLazyAndPagesUseIsolatedState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = try AppEnvironment.mock(databasePath: folder.appendingPathComponent("foundation.sqlite").path)
        #expect(!FileManager.default.fileExists(atPath: environment.secResearchDatabasePath))
        #expect(!FileManager.default.fileExists(atPath: environment.offlineResearchDatabasePath))
        let first = try await environment.makeSECResearchWorkspace(networkAvailable: false)
        #expect(FileManager.default.fileExists(atPath: environment.secResearchDatabasePath))
        #expect(!FileManager.default.fileExists(atPath: environment.offlineResearchDatabasePath))
        let second = try await environment.makeSECResearchWorkspace(networkAvailable: false)
        first.chooseTicker("AAPL")
        #expect(second.ticker == "MSFT")
        await first.load(); await second.load()
        #expect(first.saved.isEmpty && second.saved.isEmpty)
        #expect(first.startImport(email: "researcher@example.invalid") == nil)
        #expect(first.document == nil)
        #expect(throws: MigrationError.incompatiblePurpose) {
            _ = try DatabaseStore(path: environment.secResearchDatabasePath)
        }
    }
}
