import CoreDomain
import DataProviders
import Persistence
import SecuritySupport

public struct AppEnvironment: Sendable {
    public let quotes: any QuoteProvider
    public let models: ModelRegistry
    public let database: DatabaseStore
    public let credentials: CredentialStore
    public init(quotes: any QuoteProvider, database: DatabaseStore, credentials: CredentialStore) {
        self.quotes = quotes; self.database = database; self.credentials = credentials; self.models = ModelRegistry()
    }
    public static func mock(databasePath: String) throws -> AppEnvironment {
        try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: databasePath), credentials: CredentialStore())
    }
}
