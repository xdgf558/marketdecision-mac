import Foundation
import Testing
import AppComposition
import SecuritySupport

private actor PausedCredentials: CredentialStorage {
    var value: Data? = Data("synthetic-original".utf8)
    var writes = 0
    var deletes = 0
    private var held = false
    private var started = false
    private var operation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() { held = true; started = false }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { held = false; operation?.resume(); operation = nil }
    private func barrier() async {
        guard held else { return }
        await withCheckedContinuation { continuation in
            operation = continuation
            started = true
            observer?.resume(); observer = nil
        }
    }
    func contains(reference: String) -> Bool { value != nil }
    func save(_ secret: Data, reference: String) async {
        await barrier(); value = secret; writes += 1
    }
    func delete(reference: String) async {
        await barrier(); value = nil; deletes += 1
    }
}

@Suite @MainActor struct CredentialInteractionTests {
    @Test func cancellationRequestsFocusOnceWithoutWriting() async {
        let store = PausedCredentials()
        let model = CredentialSettingsModel(store: store)
        await model.refresh()
        let page = CredentialInteractionFlow(); page.appear()
        page.present(.replace, revision: model.revision)
        #expect(page.focusRequest == nil)
        page.cancel()
        let request = page.focusRequest
        #expect(request != nil && page.confirmation == nil)
        page.cancel()
        #expect(page.focusRequest == request)
        #expect(await store.writes == 0)
    }
    @Test func slowSaveOnlyRequestsFocusAfterCompletion() async throws {
        let store = PausedCredentials()
        let model = CredentialSettingsModel(store: store)
        await model.refresh()
        let page = CredentialInteractionFlow(); page.appear()
        page.present(.replace, revision: model.revision)
        let op = try #require(page.confirm(.replace, revision: model.revision))
        #expect(page.confirmation == nil && page.focusRequest == nil)
        await store.pause()
        let task = Task {
            let saved = await model.save("synthetic-new", expectedRevision: op.revision)
            page.completed(op, succeeded: saved)
        }
        await store.waitUntilStarted()
        #expect(model.isBusy && page.focusRequest == nil)
        #expect(await model.save("synthetic-overlap", expectedRevision: op.revision) == false)
        await store.resume(); await task.value
        #expect(!model.isBusy && page.focusRequest != nil)
        #expect(await store.writes == 1)
    }
    @Test func closedAndReopenedPageRejectsOldDeleteCompletion() async throws {
        let store = PausedCredentials()
        let model = CredentialSettingsModel(store: store)
        await model.refresh()
        let page = CredentialInteractionFlow(); page.appear()
        page.present(.delete, revision: model.revision)
        let op = try #require(page.confirm(.delete, revision: model.revision))
        await store.pause()
        let task = Task {
            let deleted = await model.delete(expectedRevision: op.revision)
            page.completed(op, succeeded: deleted)
        }
        await store.waitUntilStarted()
        #expect(page.focusRequest == nil)
        page.disappear(); page.appear()
        await store.resume(); await task.value
        #expect(model.presence == .absent && page.focusRequest == nil)
        #expect(await store.deletes == 1)
    }
    @Test func anotherPageInvalidatesEvenSamePresenceReplacement() async {
        let store = PausedCredentials()
        let model = CredentialSettingsModel(store: store)
        await model.refresh()
        let first = CredentialInteractionFlow(); first.appear()
        first.present(.delete, revision: model.revision)
        let old = model.revision
        #expect(await model.save("synthetic-other-page"))
        #expect(model.presence == .saved && model.revision != old)
        #expect(first.invalidate(revision: model.revision))
        #expect(first.confirmation == nil && first.focusRequest == nil)
        #expect(await model.delete(expectedRevision: old) == false)
        #expect(await store.deletes == 0)
    }
    @Test func staleReplacementCannotRecreateDeletedCredential() async throws {
        let store = PausedCredentials()
        let model = CredentialSettingsModel(store: store)
        await model.refresh()
        let page = CredentialInteractionFlow(); page.appear()
        page.present(.replace, revision: model.revision)
        let op = try #require(page.confirm(.replace, revision: model.revision))
        #expect(await model.delete())
        let saved = await model.save("synthetic-stale", expectedRevision: op.revision)
        page.completed(op, succeeded: saved)
        #expect(!saved && model.presence == .absent && page.focusRequest == nil)
        #expect(await store.writes == 0)
    }
    @Test func checkingStateInvalidatesUnsubmittedConfirmation() async {
        let model = CredentialSettingsModel(store: PausedCredentials())
        await model.refresh()
        let page = CredentialInteractionFlow(); page.appear()
        page.present(.replace, revision: model.revision)
        await model.refresh()
        #expect(page.confirm(.replace, revision: model.revision) == nil)
        #expect(page.focusRequest == nil)
    }
}
