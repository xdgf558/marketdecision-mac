import Foundation
import Persistence

/// One isolated store per environment, shared across page-local sessions. Opening
/// the laboratory does not open the ledger, access credentials or create transport.
actor OptionLabStoreFactory {
    private let path: String
    private var cached: OptionLabStore?
    init(path: String) { self.path = path }
    func store() throws -> OptionLabStore {
        try Task.checkCancellation()
        if let cached { return cached }
        let store = try OptionLabStore(path: path)
        try Task.checkCancellation()
        cached = store
        return store
    }
}

extension AppEnvironment {
    @MainActor public func makeOptionLabWorkspaceModel() async throws -> OptionLabWorkspaceModel {
        let store = try await optionLabStoreFactory.store()
        try Task.checkCancellation()
        let ledgerFactory = ledgerStoreFactory
        let model = OptionLabWorkspaceModel(storage: store, ledgerReader: {
            let ledger = try await ledgerFactory.store()
            try Task.checkCancellation()
            return try await ledger.snapshot()
        })
        let daily = try await store.makeDailyStore()
        let archive = try await store.makeArchiveStore()
        try Task.checkCancellation()
        let history = OptionHistoryWorkspaceModel(storage: daily, coordinator: optionTransferCoordinator)
        let transfer = OptionArchiveTransferModel(store: archive, coordinator: optionTransferCoordinator)
        model.install(history: history, transfer: transfer, coordinator: optionTransferCoordinator)
        let chains = try await store.makeChainStore()
        try Task.checkCancellation()
        model.installChain(OptionChainWorkspaceModel(storage: chains, coordinator: optionTransferCoordinator))
        let portfolio = try await store.makePortfolioGreeksStore()
        try Task.checkCancellation()
        model.installPortfolioGreeks(PortfolioGreeksWorkspaceModel(storage: portfolio, experiments: store, ledgerReader: {
            let ledger = try await ledgerFactory.store()
            try Task.checkCancellation()
            return try await ledger.snapshot()
        }, coordinator: optionTransferCoordinator))
        let evidenceStore = try await store.makeEvidenceStore()
        try Task.checkCancellation()
        model.installEvidence(OptionEvidenceWorkspaceModel(storage: evidenceStore, coordinator: optionTransferCoordinator))
        model.installPersonalHistory(OptionPersonalHistoryWorkspaceModel(storageFactory: {
            try await ledgerFactory.performanceStore()
        }, coordinator: ledgerTransferCoordinator))
        return model
    }
}
