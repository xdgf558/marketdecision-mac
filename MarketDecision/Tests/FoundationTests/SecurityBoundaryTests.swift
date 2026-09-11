import Foundation
import Testing
import SecuritySupport
import AppComposition
import DataProviders
import Persistence

// Lock protects all mutable state; the sink is synchronous so logging adds no suspension point.
private final class LogCapture: SecurityEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SafeLogRecord] = []
    private var formattingCount = 0
    func record(_ record: SafeLogRecord) { lock.lock(); defer { lock.unlock() }; records.append(record) }
    func formattedError() { lock.lock(); defer { lock.unlock() }; formattingCount += 1 }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return records.map(\.message) }
    var formattedErrors: Int { lock.lock(); defer { lock.unlock() }; return formattingCount }
}
private let privateFixture = "SYNTHETIC-ONLY Authorization: Bearer example-secret; https://example.invalid/?key=example-secret; account=example-account; {\"password\":\"example-secret\"}"
private struct SensitiveFailure: LocalizedError, CustomStringConvertible {
    let capture: LogCapture
    var description: String { capture.formattedError(); return privateFixture }
    var errorDescription: String? { capture.formattedError(); return privateFixture }
}
private actor BoundaryCredentials: CredentialStorage {
    enum Operation: Sendable { case check, save, delete }
    var value: Data?
    var failure: Operation?
    var mutateBeforeFailure = false
    let error: any Error
    var writes = 0
    init(error: any Error) { self.error = error }
    func fail(_ operation: Operation?, afterMutation: Bool = false) { failure = operation; mutateBeforeFailure = afterMutation }
    func contains(reference: String) throws -> Bool {
        if failure == .check { throw error }; return value != nil
    }
    func save(_ secret: Data, reference: String) throws {
        writes += 1
        if failure == .save {
            if mutateBeforeFailure { value = secret }
            throw error
        }
        value = secret
    }
    func delete(reference: String) throws {
        if failure == .delete {
            if mutateBeforeFailure { value = nil }
            throw error
        }
        value = nil
    }
}

@Suite @MainActor struct SecurityBoundaryTests {
    @Test func loggerEmitsOnlyClosedEventsThroughItsOutputBoundary() {
        let capture = LogCapture(), log = SafeLog(sink: capture)
        for event in SecurityEvent.allCases { log.write(event) }
        #expect(capture.messages == ["credentialSaved", "credentialDeleted", "credentialReadFailed", "providerRequestFailed",
            "credentialCheckSucceeded", "credentialSaveFailed", "credentialDeleteFailed", "credentialInputRejected",
            "localPreparationFailed", "providerRequestCancelled", "localPreparationCancelled"])
    }
    @Test func sensitiveErrorsNeverEnterLogsOrDisplayAndCheckCanRecover() async {
        let capture = LogCapture(), store = BoundaryCredentials(error: SensitiveFailure(capture: capture))
        let model = CredentialSettingsModel(store: store, log: SafeLog(sink: capture))
        await store.fail(.check)
        #expect(await model.refresh() == false)
        #expect(model.hasError && model.presence == .unknown && !model.isBusy)
        #expect(model.message == "无法检查钥匙串状态。请解锁设备后重试。")
        #expect(capture.messages == ["credentialReadFailed"] && capture.formattedErrors == 0)
        await store.fail(nil)
        #expect(await model.refresh())
        #expect(model.message == nil && !model.hasError && model.presence == .absent)
        #expect(capture.messages == ["credentialReadFailed", "credentialCheckSucceeded"])
    }
    @Test func ambiguousSaveFailureNeverClaimsSuccessOrLogsSubmittedBytes() async {
        let capture = LogCapture(), store = BoundaryCredentials(error: SensitiveFailure(capture: capture))
        let model = CredentialSettingsModel(store: store, log: SafeLog(sink: capture))
        await model.refresh(); await store.fail(.save, afterMutation: true)
        #expect(await model.save(privateFixture, expectedRevision: model.revision) == false)
        #expect(await store.value == Data(privateFixture.utf8)) // Simulates an error after a write may have occurred.
        #expect(model.presence == .unknown && model.hasError && !model.isBusy)
        #expect(model.message == "保存失败，未确认凭据是否已保存。请检查钥匙串状态后重试。")
        #expect(capture.messages == ["credentialCheckSucceeded", "credentialSaveFailed"] && capture.formattedErrors == 0)
        #expect(await model.save(privateFixture, expectedRevision: model.revision) == false)
        #expect(await store.writes == 1) // A fresh status check is required before retrying.
        await store.fail(nil); await model.refresh()
        #expect(model.presence == .saved && model.message == nil)
    }
    @Test func ambiguousDeleteFailureRequiresRecheckAndNeverFormatsNSError() async {
        let capture = LogCapture()
        let error = NSError(domain: privateFixture, code: 1, userInfo: [NSLocalizedDescriptionKey: privateFixture, NSUnderlyingErrorKey: SensitiveFailure(capture: capture)])
        let store = BoundaryCredentials(error: error)
        let model = CredentialSettingsModel(store: store, log: SafeLog(sink: capture))
        await model.refresh(); #expect(await model.save(privateFixture, expectedRevision: model.revision))
        await store.fail(.delete, afterMutation: true)
        #expect(await model.delete(expectedRevision: model.revision) == false)
        #expect(await store.value == nil)
        #expect(model.presence == .unknown && model.hasError && !model.isBusy)
        #expect(model.message == "删除失败，未确认凭据是否已删除。请检查钥匙串状态后重试。")
        #expect(capture.messages == ["credentialCheckSucceeded", "credentialSaved", "credentialDeleteFailed"])
        #expect(!capture.messages.joined().contains(privateFixture) && capture.formattedErrors == 0)
        await store.fail(nil); await model.refresh()
        #expect(model.presence == .absent && model.message == nil)
    }
    @Test func emptyAndStaleSubmissionsDoNotProduceStorageSuccessEvents() async {
        let capture = LogCapture(), store = BoundaryCredentials(error: SensitiveFailure(capture: capture))
        let model = CredentialSettingsModel(store: store, log: SafeLog(sink: capture))
        await model.refresh()
        #expect(await model.save(" \t\n", expectedRevision: model.revision) == false)
        #expect(await model.save(privateFixture, expectedRevision: UUID()) == false)
        #expect(await store.writes == 0)
        #expect(capture.messages == ["credentialCheckSucceeded", "credentialInputRejected"])
    }
    @Test func environmentSharesInjectedLogWithoutExposingSecretOrReference() async throws {
        let capture = LogCapture(), store = BoundaryCredentials(error: SensitiveFailure(capture: capture))
        let environment = try AppEnvironment(quotes: MockQuoteProvider(), database: DatabaseStore(path: ":memory:"), credentials: store, log: SafeLog(sink: capture))
        let first = environment.makeCredentialSettings(), second = environment.makeCredentialSettings()
        await first.refresh(); #expect(await first.save(privateFixture, expectedRevision: first.revision))
        await second.refresh(); #expect(await second.delete(expectedRevision: second.revision))
        #expect(capture.messages == ["credentialCheckSucceeded", "credentialSaved", "credentialCheckSucceeded", "credentialDeleted"])
        #expect(!capture.messages.joined().contains("reserved-data-service"))
        #expect(await store.value == nil)
    }
}
