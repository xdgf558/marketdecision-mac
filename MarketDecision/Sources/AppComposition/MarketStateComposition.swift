import Foundation
import Persistence

actor MarketStateStoreFactory {
    private let path: String
    private var cached: (MarketStateStore, MarketStateArchiveStore, MacroSourceStore)?
    init(path: String) { self.path = path }
    func stores() throws -> (MarketStateStore, MarketStateArchiveStore, MacroSourceStore) {
        try Task.checkCancellation()
        if let cached { return cached }
        let database = try DatabaseStore(path: path, purpose: .marketState)
        let stores = (try MarketStateStore(database: database), try MarketStateArchiveStore(database: database),
                      try MacroSourceStore(database: database))
        try Task.checkCancellation(); cached = stores; return stores
    }
}
extension AppEnvironment {
    @MainActor public func makeMarketStateWorkspaceModel() async throws -> MarketStateWorkspaceModel {
        let (storage, archive, sources) = try await marketStateStoreFactory.stores()
        try Task.checkCancellation()
        let model = MarketStateWorkspaceModel(storage: storage, archive: archive, coordinator: marketStateTransferCoordinator)
        model.installSources(MacroSourceWorkspaceModel(storage: sources, coordinator: marketStateTransferCoordinator))
        return model
    }
}
