import Foundation
import Testing
import AppComposition
import DataContracts
import DataProviders
import Persistence
import SecuritySupport

private let sensitiveText = "SYNTHETIC-ONLY Bearer fixture-secret https://example.invalid/?key=fixture-secret password=fixture-secret"
private final class RuntimeLog: SecurityEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var descriptions = 0
    func record(_ record: SafeLogRecord) { lock.lock(); defer { lock.unlock() }; values.append(record.message) }
    func didDescribe() { lock.lock(); defer { lock.unlock() }; descriptions += 1 }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var formatted: Int { lock.lock(); defer { lock.unlock() }; return descriptions }
}
private struct RuntimeFailure: LocalizedError, CustomStringConvertible {
    let log: RuntimeLog
    var description: String { log.didDescribe(); return sensitiveText }
    var errorDescription: String? { log.didDescribe(); return sensitiveText }
}
private final class RuntimeNSError: NSError, @unchecked Sendable {
    let log: RuntimeLog
    init(log: RuntimeLog) { self.log = log; super.init(domain: sensitiveText, code: 1, userInfo: [NSLocalizedDescriptionKey: sensitiveText]) }
    required init?(coder: NSCoder) { return nil }
    override var description: String { log.didDescribe(); return sensitiveText }
    override var localizedDescription: String { log.didDescribe(); return sensitiveText }
}
private actor RuntimeCredentials: CredentialStorage {
    var checks = 0
    func contains(reference: String) -> Bool { checks += 1; return false }
    func save(_ secret: Data, reference: String) {}
    func delete(reference: String) {}
}
/// Explicit handshakes: no scheduler sleeps or polling to stage cancellation/reentry.
private actor RuntimeGate {
    var calls = 0
    private var blocked: Bool
    private var entered: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    init(blocked: Bool = false) { self.blocked = blocked }
    func enter() async {
        calls += 1
        entered?.resume(); entered = nil
        if blocked { await withCheckedContinuation { held = $0 } }
    }
    func waitUntilEntered() async {
        if calls == 0 { await withCheckedContinuation { entered = $0 } }
    }
    func release() { blocked = false; held?.resume(); held = nil }
}
private actor RuntimeQuotes: QuoteProvider {
    nonisolated let id = "synthetic.runtime"
    let gate: RuntimeGate
    let value: Quote
    private var failure: (any Error)?
    init(value: Quote, gate: RuntimeGate = RuntimeGate()) { self.value = value; self.gate = gate }
    func fail(with failure: (any Error)?) { self.failure = failure }
    func quote(for symbol: String) async throws -> Quote {
        let captured = failure
        await gate.enter() // Deliberately ignores cancellation; the application must reject late output.
        if let captured { throw captured }
        return value
    }
}
private actor RuntimePreparation {
    let gate: RuntimeGate
    let quotes: RuntimeQuotes
    let store = RuntimeCredentials()
    private var firstError: (any Error)?
    init(quotes: RuntimeQuotes, gate: RuntimeGate = RuntimeGate(), firstError: (any Error)? = nil) {
        self.quotes = quotes; self.gate = gate; self.firstError = firstError
    }
    func make(log: SafeLog) async throws -> AppEnvironment {
        await gate.enter()
        if let firstError { self.firstError = nil; throw firstError }
        return try AppEnvironment(quotes: quotes, database: DatabaseStore(path: ":memory:"), credentials: store, log: log)
    }
}

@Suite @MainActor struct WorkspaceRuntimeTests {
    @Test func preparationFailureUsesClosedLogAndRetriesWithSharedSettingsSink() async throws {
        let capture = RuntimeLog()
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"))
        let prepare = RuntimePreparation(quotes: quotes, firstError: RuntimeFailure(log: capture))
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        #expect(await model.refresh() == false)
        #expect(model.credentials == nil && model.quote == nil && !model.isLoading && !model.isPreparing)
        #expect(model.initializationError == "本地数据暂时不可用，请重试。")
        #expect(model.message == model.initializationError)
        #expect(await quotes.gate.calls == 0)
        #expect(capture.messages == ["localPreparationFailed"] && capture.formatted == 0)
        #expect(await model.refresh())
        #expect(model.initializationError == nil && model.quote?.quality.contains(.synthetic) == true)
        let settings = try #require(model.credentials)
        #expect(await settings.refresh())
        #expect(capture.messages == ["localPreparationFailed", "credentialCheckSucceeded"])
        #expect(await prepare.gate.calls == 2)
    }
    @Test func providerErrorClearsPriorSuccessWithoutDescribingNSErrorAndCanRetry() async throws {
        let capture = RuntimeLog()
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"))
        let prepare = RuntimePreparation(quotes: quotes)
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        #expect(await model.refresh())
        await quotes.fail(with: RuntimeNSError(log: capture))
        #expect(await model.refresh() == false)
        #expect(model.quote == nil && model.credentials != nil && !model.isLoading)
        #expect(model.message == "演示数据暂时不可用，请重试。")
        #expect(capture.messages == ["providerRequestFailed"] && capture.formatted == 0)
        await quotes.fail(with: nil)
        #expect(await model.refresh())
        #expect(model.message == "演示数据已刷新" && model.quote != nil)
        #expect(await prepare.gate.calls == 1)
    }
    @Test func providerReportedCancellationWithoutTaskCancellationIsFailure() async throws {
        let capture = RuntimeLog()
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"))
        await quotes.fail(with: CancellationError())
        let prepare = RuntimePreparation(quotes: quotes)
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        #expect(await model.refresh() == false)
        #expect(model.message == "演示数据暂时不可用，请重试。" && model.quote == nil)
        #expect(capture.messages == ["providerRequestFailed"])
    }
    @Test func preparationReportedCancellationWithoutTaskCancellationIsFailure() async throws {
        let capture = RuntimeLog()
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"))
        let prepare = RuntimePreparation(quotes: quotes, firstError: CancellationError())
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        #expect(await model.refresh() == false)
        #expect(model.initializationError == "本地数据暂时不可用，请重试。")
        #expect(model.message == model.initializationError && model.credentials == nil)
        #expect(capture.messages == ["localPreparationFailed"])
    }
    @Test func cancelledProviderCannotPublishItsLateSuccess() async throws {
        let capture = RuntimeLog(), gate = RuntimeGate(blocked: true)
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"), gate: gate)
        let prepare = RuntimePreparation(quotes: quotes)
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        let refresh = Task { await model.refresh() }
        await gate.waitUntilEntered()
        refresh.cancel()
        await gate.release()
        #expect(await refresh.value == false)
        #expect(model.quote == nil && !model.isLoading && model.message == "刷新已取消")
        #expect(capture.messages == ["providerRequestCancelled"])
        #expect(await model.refresh())
    }
    @Test func cancelledPreparationCannotPublishEnvironmentOrFetchQuotes() async throws {
        let capture = RuntimeLog(), gate = RuntimeGate(blocked: true)
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"))
        let prepare = RuntimePreparation(quotes: quotes, gate: gate)
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        let refresh = Task { await model.refresh() }
        await gate.waitUntilEntered()
        #expect(model.isPreparing && model.isLoading)
        refresh.cancel()
        await gate.release()
        #expect(await refresh.value == false)
        #expect(model.credentials == nil && model.quote == nil && !model.isPreparing && !model.isLoading)
        #expect(capture.messages == ["localPreparationCancelled"])
        #expect(await quotes.gate.calls == 0)
        #expect(await model.refresh())
        #expect(model.initializationError == nil)
    }
    @Test func overlappingRefreshReturnsFalseWithoutExtraFactoryOrProviderCalls() async throws {
        let gate = RuntimeGate(blocked: true)
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"), gate: gate)
        let prepare = RuntimePreparation(quotes: quotes)
        let model = WorkspaceModel { try await prepare.make(log: $0) }
        let refresh = Task { await model.refresh() }
        await gate.waitUntilEntered()
        #expect(await model.refresh() == false)
        #expect(await gate.calls == 1)
        #expect(await prepare.gate.calls == 1)
        await gate.release()
        #expect(await refresh.value)
        #expect(await prepare.store.checks == 0) // App initialization does not read credentials.
    }
    @Test func alreadyCancelledRefreshDoesNotInvokeTheFactory() async throws {
        let capture = RuntimeLog()
        let quotes = RuntimeQuotes(value: try await MockQuoteProvider().quote(for: "DEMO"))
        let prepare = RuntimePreparation(quotes: quotes)
        let model = WorkspaceModel(log: SafeLog(sink: capture)) { try await prepare.make(log: $0) }
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.refresh()
        }
        #expect(await refresh.value == false)
        #expect(await prepare.gate.calls == 0)
        #expect(capture.messages == ["localPreparationCancelled"])
    }
    @Test func localFactoryBuildsOnlyFoundationDatabaseAndSyntheticProvider() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = RuntimeLog()
        let ready = try await AppEnvironment.prepareLocal(log: SafeLog(sink: capture), directory: folder)
        #expect(try ready.database.migrationVersions() == ["business.p1.v1", "business.p1.v2", "business.p1.v3", "foundation.v1"])
        #expect(try await ready.businessData.counts() == .init(sourceDocuments: 0, observations: 0, snapshotObjects: 0, snapshotRoots: 0))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("foundation.sqlite").path))
        let quote = try await ready.quotes.quote(for: "DEMO")
        #expect(quote.quality.contains(.synthetic))
        ready.log.write(.localPreparationFailed)
        #expect(capture.messages == ["localPreparationFailed"])
        // CredentialStore construction is not a Keychain operation or qualification.
    }
}
