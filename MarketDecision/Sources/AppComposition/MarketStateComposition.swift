import Foundation
import Persistence

actor MarketStateStoreFactory {
    private let path: String
    private var cached: (MarketStateStore, MarketStateArchiveStore)?
    init(path: String) { self.path = path }
    func stores() throws -> (MarketStateStore, MarketStateArchiveStore) {
        try Task.checkCancellation()
        if let cached { return cached }
        let database = try DatabaseStore(path: path, purpose: .marketState)
        let stores = (try MarketStateStore(database: database), try MarketStateArchiveStore(database: database))
        try Task.checkCancellation(); cached = stores; return stores
    }
}
extension AppEnvironment {
    @MainActor public func makeMarketStateWorkspaceModel() async throws -> MarketStateWorkspaceModel {
        let (storage, archive) = try await marketStateStoreFactory.stores()
        try Task.checkCancellation()
        return MarketStateWorkspaceModel(storage: storage, archive: archive, coordinator: marketStateTransferCoordinator)
    }
}
