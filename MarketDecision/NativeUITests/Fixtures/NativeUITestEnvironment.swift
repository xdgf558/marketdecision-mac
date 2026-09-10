#if UI_TEST_HOST
import Foundation
import AppComposition
import DataProviders
import Persistence
import SecuritySupport

/// Compiled only into the independently identified UI test app, never the shipping app.
enum NativeUITestEnvironment {
    static func prepare(log: SafeLog) async throws -> AppEnvironment {
        AppEnvironment(quotes: MockQuoteProvider(), database: try DatabaseStore(path: ":memory:"),
            credentials: SyntheticUIStore(failFirstSave: CommandLine.arguments.contains("--synthetic-fail-first-save")), log: log)
    }
}

private actor SyntheticUIStore: CredentialStorage {
    private var present = false
    private var failFirstSave: Bool
    init(failFirstSave: Bool) { self.failFirstSave = failFirstSave }
    enum Failure: Error { case rejectedFixture, injected }
    func contains(reference: String) -> Bool { present }
    func save(_ secret: Data, reference: String) throws {
        guard let text = String(data: secret, encoding: .utf8), text.hasPrefix("SYNTHETIC-UI-") else {
            throw Failure.rejectedFixture
        }
        if failFirstSave { failFirstSave = false; throw Failure.injected }
        present = true // Do not retain credential bytes, even in this disposable test host.
    }
    func delete(reference: String) { present = false }
}
#endif
