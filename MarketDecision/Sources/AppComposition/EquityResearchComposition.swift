import Foundation
import Persistence
import SecuritySupport
import MarketDataProviders
import EquityNetworkBroker

extension AppEnvironment {
    // Construction stores a lazy factory; it opens neither Keychain nor an XPC connection.
    // All windows in this environment share the same capture and credential revision gate.
    static func makeEquityAcquisition(database: BusinessDataStore, workspaceLock: WorkspaceImportLock) -> EquityResearchAcquisition {
        EquityResearchAcquisition(database: database, factory: { credentials, rights in
            try credentials.validate()
            let transport = try EquityXPCTransport()
            let provider = try AlpacaIEXProvider(apiKey: credentials.apiKey, secret: credentials.secret,
                evidenceRef: rights.evidenceReference, licenseRef: rights.licenseReference,
                transport: transport)
            return EquityResearchProviderSession(provider: provider, close: { await transport.close() })
        }, workspaceLock: workspaceLock)
    }

    @MainActor public func makeEquityResearchWorkspace() throws -> EquityResearchWorkspaceModel {
        guard let reader = credentials as? any CredentialReadingStorage else {
            throw EquityResearchError.missingCredentials
        }
        // Read-only inspection of the current package. The factory repeats the signature
        // verification at use time; neither inspection reads Keychain nor opens XPC.
        return EquityResearchWorkspaceModel(store: reader, acquisition: equityAcquisition,
            networkAvailable: EquityNetworkServiceAvailability.isAvailable)
    }
}
