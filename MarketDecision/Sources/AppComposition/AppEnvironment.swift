import Foundation
import CoreDomain
import DataProviders
import Persistence
import SecuritySupport

public struct AppEnvironment: Sendable {
    public let quotes: any QuoteProvider
    public let models: ModelRegistry
    public let database: DatabaseStore
    public let log: SafeLog
    public let credentials: any CredentialStorage
    public init(quotes: any QuoteProvider, database: DatabaseStore, credentials: any CredentialStorage, log: SafeLog = SafeLog()) {
        self.quotes = quotes; self.database = database; self.credentials = credentials; self.models = ModelRegistry(); self.log = log
    }
    @MainActor public func makeCredentialSettings() -> CredentialSettingsModel {
        CredentialSettingsModel(store: credentials, log: log)
    }
    public static func mock(databasePath: String, log: SafeLog = SafeLog()) throws -> AppEnvironment {
        try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: databasePath), credentials: CredentialStore(), log: log)
    }
    /// Directory override is for isolated integration fixtures. The app uses its own Application Support.
    /// Cancellation prevents publication; it cannot undo a filesystem operation already in progress.
    public static func prepareLocal(log: SafeLog, directory: URL? = nil) async throws -> AppEnvironment {
        try Task.checkCancellation()
        let preparation = Task.detached {
            try Task.checkCancellation()
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MarketDecision", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Task.checkCancellation()
            return try mock(databasePath: folder.appendingPathComponent("foundation.sqlite").path, log: log)
        }
        return try await withTaskCancellationHandler {
            let ready = try await preparation.value
            try Task.checkCancellation()
            return ready
        } onCancel: {
            preparation.cancel()
        }
    }
}
