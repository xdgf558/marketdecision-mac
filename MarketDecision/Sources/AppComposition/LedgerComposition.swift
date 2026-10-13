import Foundation
import Persistence

/// One connection per environment, including the synthetic in-memory host. Page
/// interaction state stays separate; opening a page never reads credentials or networks.
actor LedgerStoreFactory {
    private let path: String
    private var cached: LedgerStore?
    private var performance: Task<PerformanceStore, Error>?
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

}

extension AppEnvironment {
    /// Lazy isolated file: a damaged ledger cannot disable research or the DEMO workspace.
    @MainActor public func makeLedgerWorkspaceModel() async throws -> LedgerWorkspaceModel {
        let store = try await ledgerStoreFactory.store()
        try Task.checkCancellation()
        return LedgerWorkspaceModel(storage: store)
    }
    @MainActor public func makePortfolioWorkspaceModel() async throws -> PortfolioWorkspaceModel {
        let store = try await ledgerStoreFactory.performanceStore()
        try Task.checkCancellation()
        return PortfolioWorkspaceModel(storage: store)
    }

}
