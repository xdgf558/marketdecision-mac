import Foundation
import Testing
import AppComposition
import SecuritySupport
import Persistence
import DataProviders

private actor MemoryCredentials: CredentialStorage {
    var value: Data?
    var fails = false
    var writes = 0
    func setFailure(_ flag: Bool) { fails = flag }
    func contains(reference: String) throws -> Bool {
        if fails { throw CredentialError.invalidReference }
        return value != nil
    }
    func save(_ secret: Data, reference: String) throws {
        if fails { throw CredentialError.invalidReference }
        value = secret; writes += 1
    }
    func delete(reference: String) throws {
        if fails { throw CredentialError.invalidReference }
        value = nil
    }
}

@Suite @MainActor struct CredentialSettingsTests {
    @Test func environmentInjectsTheSameStoreAcrossSettingsModels() async throws {
        let store = MemoryCredentials()
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"), credentials: store)
        let first = environment.makeCredentialSettings()
        let second = environment.makeCredentialSettings()
        await first.refresh()
        #expect(await first.save("synthetic-injected", expectedRevision: first.revision))
        #expect(await store.value == Data("synthetic-injected".utf8))
        await second.refresh()
        #expect(second.presence == .saved)
        await second.delete(expectedRevision: second.revision)
        await first.refresh()
        #expect(first.presence == .absent)
        #expect(await store.value == nil)
    }
    @Test func lifecycleAndRestart() async {
        let store = MemoryCredentials()
        let model = CredentialSettingsModel(store: store)
        #expect(await model.save("synthetic", expectedRevision: model.revision) == false)
        await model.refresh()
        #expect(model.presence == .absent)
        #expect(await model.save(" synthetic-one ", expectedRevision: model.revision))
        #expect(await store.value == Data(" synthetic-one ".utf8))
        let restarted = CredentialSettingsModel(store: store)
        await restarted.refresh()
        #expect(restarted.presence == .saved)
        #expect(await restarted.save("synthetic-two", expectedRevision: restarted.revision))
        #expect(await store.value == Data("synthetic-two".utf8))
        await restarted.delete(expectedRevision: restarted.revision)
        #expect(restarted.presence == .absent)
        #expect(await store.value == nil)
    }
    @Test func rejectsWhitespaceWithoutWriting() async {
        let store = MemoryCredentials()
        let model = CredentialSettingsModel(store: store)
        await model.refresh()
        #expect(await model.save(" \n\t", expectedRevision: model.revision) == false)
        #expect(model.hasError)
        #expect(await store.writes == 0)
    }
    @Test func failuresNeverClaimSuccessAndCanRecover() async {
        let store = MemoryCredentials()
        let model = CredentialSettingsModel(store: store)
        await store.setFailure(true)
        await model.refresh()
        #expect(model.presence == .unknown && model.hasError && !model.isBusy)
        await store.setFailure(false)
        await model.refresh()
        await store.setFailure(true)
        #expect(await model.save("synthetic", expectedRevision: model.revision) == false)
        #expect(model.presence == .unknown && model.hasError && !model.isBusy)
        await store.setFailure(false)
        await model.refresh()
        #expect(await model.save("synthetic", expectedRevision: model.revision))
        await store.setFailure(true)
        await model.delete(expectedRevision: model.revision)
        #expect(model.presence == .unknown && model.hasError && !model.isBusy)
        #expect(await store.value != nil)
        await store.setFailure(false)
        await model.refresh()
        #expect(model.presence == .saved && !model.hasError)
        await model.delete(expectedRevision: model.revision)
    }
}
