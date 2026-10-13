import Foundation
import Persistence

/// One connection per environment, including the synthetic in-memory host. Page
/// interaction state stays separate; opening a page never reads credentials or networks.
actor LedgerStoreFactory {
    private let path: String
    private var cached: LedgerStore?
    private var performance: Task<PerformanceStore, Error>?
    private var archive: Task<LedgerArchiveStore, Error>?
    init(path: String) { self.path = path }
    func store() throws -> LedgerStore {
        try Task.checkCancellation()
        if let cached { return cached }
        let prepared = try LedgerStore(path: path)
        try Task.checkCancellation()
        cached = prepared
        return prepared
    }
    func performanceStore() async throws -> PerformanceStore {
        try Task.checkCancellation()
        if let performance { return try await performance.value }
        let ledger = try store()
        let pending = Task { try await ledger.makePerformanceStore() }
        performance = pending
        do { return try await pending.value }
        catch { performance = nil; throw error }
    }
    func archiveStore() async throws -> LedgerArchiveStore {
        try Task.checkCancellation()
        if let archive { return try await archive.value }
        let ledger = try store()
        let pending = Task { try await ledger.makeArchiveStore() }
        archive = pending
        do { return try await pending.value }
        catch { archive = nil; throw error }
    }


}

extension AppEnvironment {
    /// Lazy isolated file: a damaged ledger cannot disable research or the DEMO workspace.
    @MainActor public func makeLedgerWorkspaceModel() async throws -> LedgerWorkspaceModel {
        let store = try await ledgerStoreFactory.store()
        try Task.checkCancellation()
        let model = LedgerWorkspaceModel(storage: store)
        let transfer = try await makeLedgerTransferModel()
        try Task.checkCancellation()
        model.installTransfer(transfer, coordinator: ledgerTransferCoordinator)
        return model
    }
    @MainActor public func makePortfolioWorkspaceModel() async throws -> PortfolioWorkspaceModel {
        let store = try await ledgerStoreFactory.performanceStore()
        try Task.checkCancellation()
        let model = PortfolioWorkspaceModel(storage: store)
        let transfer = try await makeLedgerTransferModel()
        try Task.checkCancellation()
        model.installTransfer(transfer, coordinator: ledgerTransferCoordinator)
        return model
    }
    @MainActor private func makeLedgerTransferModel() async throws -> LedgerTransferModel {
        let ledger = try await ledgerStoreFactory.store()
        let performance = try await ledgerStoreFactory.performanceStore()
        let archive = try await ledgerStoreFactory.archiveStore()
        try Task.checkCancellation()
        return LedgerTransferModel(store: archive, ledger: ledger, performance: performance, coordinator: ledgerTransferCoordinator)
    }

}
