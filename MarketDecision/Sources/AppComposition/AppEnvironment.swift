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
    public static func mock(databasePath: String) throws -> AppEnvironment {
        try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: databasePath), credentials: CredentialStore())
    }
}
