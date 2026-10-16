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
        return OptionLabWorkspaceModel(storage: store, ledgerReader: {
            let ledger = try await ledgerFactory.store()
            try Task.checkCancellation()
            return try await ledger.snapshot()
        })
    }
}
