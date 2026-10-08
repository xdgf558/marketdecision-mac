import Foundation
import CoreDomain
import DataProviders
import Persistence
import SecuritySupport
import SECProvider

public struct AppEnvironment: Sendable {
    public let quotes: any QuoteProvider
    public let models: ModelRegistry
    public let database: DatabaseStore
    public let businessData: BusinessDataStore
    public let log: SafeLog
    public let credentials: any CredentialStorage
    public let offlineResearchDatabasePath: String
    public let secResearchDatabasePath: String
    let secRequestGate: SECRateLimiter
    let secImportCoordinator: SECResearchImportCoordinator
    let equityAcquisition: EquityResearchAcquisition
    public init(quotes: any QuoteProvider, database: DatabaseStore, credentials: any CredentialStorage,
                log: SafeLog = SafeLog(), offlineResearchDatabasePath: String = ":memory:") throws {
        self.quotes = quotes; self.database = database; self.businessData = try BusinessDataStore(database: database)
        self.credentials = credentials; self.models = ModelRegistry(); self.log = log
        self.offlineResearchDatabasePath = offlineResearchDatabasePath
        self.secResearchDatabasePath = offlineResearchDatabasePath == ":memory:" ? ":memory:"
            : URL(fileURLWithPath: offlineResearchDatabasePath).deletingLastPathComponent()
                .appendingPathComponent("sec-research.sqlite").path
        self.secRequestGate = try SECRateLimiter(requestsPerSecond: 5)
        self.secImportCoordinator = SECResearchImportCoordinator()
        self.equityAcquisition = Self.makeEquityAcquisition(database: self.businessData)
    }
    @MainActor public func makeResearchWorkspace() -> ResearchWorkspaceModel {
        ResearchWorkspaceModel(storage: ResearchStore(database: database, snapshots: businessData), transfer: ResearchTransferModel(store: ResearchTransferStore(database: database)))
    }
    @MainActor public func makeCredentialSettings() -> CredentialSettingsModel {
        CredentialSettingsModel(store: credentials, log: log)
    }
    /// Each page owns its interaction state. The separate SQLite file is opened only
    /// on explicit navigation; a broken offline archive cannot disable the DEMO workspace.
    @MainActor public func makeOfflineIssuerWorkspace() async throws -> OfflineIssuerWorkspaceModel {
        try Task.checkCancellation()
        let path = offlineResearchDatabasePath
        let preparation = Task.detached {
            try Task.checkCancellation()
            let catalog = try OfflineIssuerCatalog.bundled()
            let store = try OfflineIssuerResearchStore(path: path)
            try Task.checkCancellation()
            return (store, catalog)
        }
        return try await withTaskCancellationHandler {
            let (store, catalog) = try await preparation.value
            try Task.checkCancellation()
            return OfflineIssuerWorkspaceModel(storage: store, catalog: catalog)
        } onCancel: {
            preparation.cancel()
        }
    }
    public static func mock(databasePath: String, log: SafeLog = SafeLog()) throws -> AppEnvironment {
        let offlinePath = databasePath == ":memory:" ? ":memory:" : URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent().appendingPathComponent("offline-issuer.sqlite").path
        return try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: databasePath),
            credentials: CredentialStore(), log: log, offlineResearchDatabasePath: offlinePath)
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
