import Foundation
import DataContracts
import DataProviders
import SECProvider
import SECNetworkBroker
import Persistence

extension AppEnvironment {
    /// Opt-in page preparation opens only a separately marked store. The lazy importer
    /// below constructs a session after the explicit button action and contact validation.
    @MainActor public func makeSECResearchWorkspace(networkAvailable: Bool) async throws -> SECResearchWorkspaceModel {
        let path = secResearchDatabasePath
        let preparation = Task.detached {
            try Task.checkCancellation()
            return try SECResearchStore(path: path)
        }
        let store = try await withTaskCancellationHandler {
            let store = try await preparation.value
            try Task.checkCancellation()
            return store
        } onCancel: { preparation.cancel() }
        let gate = secRequestGate
        let coordinator = secImportCoordinator
        return SECResearchWorkspaceModel(storage: store, networkAvailable: networkAvailable, importer: { ticker, contact, progress in
            guard networkAvailable else { throw SECResearchConfigurationError.networkDisabled }
            return try await coordinator.perform {
                try Task.checkCancellation()
                let transport = try SECXPCTransport()
                do {
                    // SEC's public-access policy permits identified automated access. This short-lived
                    // request grant is confined to local replay, never live prices/PIT/trading/redistribution.
                    let now = Date()
                    let evidence = "https://www.sec.gov/search-filings/edgar-application-programming-interfaces"
                    let license = "sec-public-edgar-identified-local-research.v1"
                    let provider = try SECEdgarProvider(userAgent: contact.userAgent, transport: transport,
                        gate: gate, evidenceRef: evidence, licenseRef: license)
                    let entitlement = EntitlementSnapshot(providerID: provider.id, feedID: "public-edgar",
                        version: "sec-local-replay.v1", evidenceRef: evidence, licenseRef: license,
                        capabilities: provider.capabilitySnapshot.capabilities, usages: [.replay],
                        validFrom: now, validThrough: now.addingTimeInterval(3600))
                    let service = SECResearchService(client: FundamentalsDataClient(provider: provider, entitlement: entitlement), store: store)
                    let document = try await service.importCompany(ticker: ticker, progress: progress)
                    await transport.close()
                    return document
                } catch {
                    await transport.close()
                    throw error
                }
            }
        }, financialStorage: store, valuationStorage: store)
    }
}
