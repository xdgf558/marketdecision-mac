import Foundation
import Persistence

/// One connection per environment, including the synthetic in-memory host. Page
/// interaction state stays separate; opening a page never reads credentials or networks.
actor LedgerStoreFactory {
    private let path: String
    private var cached: LedgerStore?
    init(path: String) { self.path = path }
    func store() throws -> LedgerStore {
        try Task.checkCancellation()
        if let cached { return cached }
        let prepared = try LedgerStore(path: path)
        try Task.checkCancellation()
        cached = prepared
        return prepared
    }
}

extension AppEnvironment {
    /// Lazy isolated file: a damaged ledger cannot disable research or the DEMO workspace.
    @MainActor public func makeLedgerWorkspaceModel() async throws -> LedgerWorkspaceModel {
        let store = try await ledgerStoreFactory.store()
        try Task.checkCancellation()
        return LedgerWorkspaceModel(storage: store)
    }
}
