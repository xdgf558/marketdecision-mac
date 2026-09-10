import Foundation
import Testing
import CoreDomain
import DataContracts
import DataProviders
import Persistence
@testable import SecuritySupport
import Security
import AppComposition
import GRDB

@Suite struct MoneyTests {
    @Test(arguments: [("1.005", "1"), ("1.015", "1.02"), ("-1.005", "-1")])
    func halfEven(_ pair: (String, String)) throws { #expect(try Money(pair.0).posted() == Money(pair.1)) }
    @Test(arguments: ["0.01", "-0.01", "10.01", "-10.01"])
    func allocationConservesCents(_ input: String) throws {
        let value = try Money(input); let result = try value.allocatedEqually(to: ["c", "b", "a"])
        let sum = try result.values.reduce(Money("0")) { try $0.adding($1) }
        #expect(sum == value)
        if input == "0.01" || input == "-0.01" { #expect(try result["a"] == Money("0")); #expect(result["c"] == value) }
    }
    @Test func exactStringRoundTrip() throws {
        let value = try Money("12345678901234567890.123456789012345678")
        #expect(try JSONDecoder().decode(Money.self, from: JSONEncoder().encode(value)) == value)
        #expect(value.decimalString == "12345678901234567890.123456789012345678")
    }
    @Test(arguments: ["NaN", "Infinity", "1junk", "01", "1e2", "123456789012345678901234567890123456789"])
    func refusesInvalidInput(_ input: String) { #expect(throws: (any Error).self) { try Money(input) } }
    @Test func refusesDuplicateLotIDs() throws { #expect(throws: MoneyError.invalidLots) { try Money("1").allocatedEqually(to: ["a", "a"]) } }
    @Test func decoderRejectsNumber() { #expect(throws: (any Error).self) { try JSONDecoder().decode(Money.self, from: Data("1.25".utf8)) } }
}

@Suite struct ContractTests {
    let now = Date(timeIntervalSince1970: 1_783_000_000)
    func quote(tier: Timeliness = .realtime, flags: Set<QualityFlag> = [], age: Double? = 0, bid: String = "1", ask: String = "2") throws -> Quote {
        Quote(symbol: "TEST", bid: try Money(bid), ask: try Money(ask), provenance: Provenance(providerID: "test", feedID: "qualified-fixture", sourceEventAt: age.map { now.addingTimeInterval(-$0) }, receivedAt: now, availableAt: nil, evidenceRef: "synthetic-test-contract", origin: .provider, endpointDescriptor: EndpointDescriptor.quote.rawValue, requestedAt: now, requestID: UUID(), versionID: "v1", versionKind: .sourceVersion, rawObjectRef: "fixture.raw", rawHash: String(repeating: "a", count: 64), normalizationVersion: "fixture.v1", licenseRef: "fixture.license"), timeliness: tier, quality: flags, qualifiedUsages: [.liveAnalysis])
    }
    func reason(_ quote: Quote, usage: Usage = .liveAnalysis) -> UnavailableReason? {
        if case let .failure(reason) = quote.eligibility(for: usage, at: now, entitlement: EntitlementSnapshot(providerID: "test", feedID: "qualified-fixture", version: "fixture.v1", evidenceRef: "synthetic-rights", licenseRef: "fixture.license", capabilities: [.quote], usages: [.liveAnalysis], validFrom: now, validThrough: now)) { return reason }; return nil
    }
    @Test func sixtySecondBoundary() throws {
        #expect(try reason(quote(age: 60)) == nil)
        #expect(try reason(quote(age: 60.001)) == .staleQuote)
    }
    @Test func delayedNeverPromoted() throws { #expect(try reason(quote(tier: .delayed)) == .unsuitableTier) }
    @Test func indicativeNeverPromoted() throws { #expect(try reason(quote(flags: [.indicative])) == .unsuitableTier) }
    @Test func staleFlagCannotBeHidden() throws { #expect(try reason(quote(flags: [.stale])) == .staleQuote) }
    @Test func missingAndFutureTimeFail() throws {
        #expect(try reason(quote(age: nil)) == .missingSourceTime)
        #expect(try reason(quote(age: -1)) == .futureSourceTime)
    }
    @Test func crossedQuoteFails() throws { #expect(try reason(quote(bid: "3", ask: "2")) == .invalidQuote) }
    @Test func realtimeDoesNotQualifyHistoricalFill() throws { #expect(try reason(quote(), usage: .historicalFill) == .unqualifiedUsage) }
    @Test func mockCannotBeUsedAsRealInput() async throws {
        let mock = MockQuoteProvider(); let first = try await mock.quote(for: "DEMO"); let second = try await mock.quote(for: "DEMO")
        #expect(first.bid == second.bid); #expect(first.provenance.sourceEventAt == second.provenance.sourceEventAt)
        #expect(reason(first) == .syntheticData)
        await #expect(throws: ProviderError.symbolUnavailable) { try await mock.quote(for: "REAL") }
    }
}

@Suite struct RegistryTests {
    @Test func versionCannotBeOverwritten() async throws {
        let registry = ModelRegistry(); let parameters = sampleParameters(); let item = sampleModel(parameters: parameters)
        try await registry.register(parameters)
        try await registry.register(item)
        await #expect(throws: RegistryError.duplicateVersion) { try await registry.register(item) }
        #expect(try await registry.definition(id: item.id, version: "1") == item)
        await #expect(throws: RegistryError.unknownVersion) { try await registry.definition(id: item.id, version: "latest") }
    }
}

@Suite struct PersistenceTests {
    @Test func migrationReopensWithoutErasing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite").path
        #expect(try DatabaseStore(path: path).migrationVersions() == ["foundation.v1"])
        #expect(try DatabaseStore(path: path).migrationVersions() == ["foundation.v1"])
    }
    @Test func failedMigrationRollsBack() throws {
        let db = try DatabaseQueue(); var migrator = DatabaseMigrator()
        enum Injected: Error { case failure }
        migrator.registerMigration("failed") { database in
            try database.execute(sql: "CREATE TABLE sentinel (value TEXT)")
            try database.execute(sql: "INSERT INTO sentinel VALUES ('test')")
            throw Injected.failure
        }
        #expect(throws: Injected.failure) { try migrator.migrate(db) }
        #expect(try db.read { try !$0.tableExists("sentinel") })
    }
    @Test func injectedEnvironmentIsOffline() async throws {
        let environment = try AppEnvironment.mock(databasePath: ":memory:")
        let quote = try await environment.quotes.quote(for: "DEMO")
        #expect(quote.quality.contains(.synthetic))
    }
}

@Suite struct SafeLoggingTests {
    @Test func onlyAllowlistedEventsAreRendered() {
        #expect(SecuritySupport.SafeLog.message(for: .providerRequestFailed) == "providerRequestFailed")
        #expect(SecuritySupport.SafeLog.message(for: .credentialReadFailed) == "credentialReadFailed")
    }
}

@Suite struct CredentialIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARKETDECISION_TEST_KEYCHAIN"] == "1"))
    func temporaryCredentialRoundTrip() async throws {
        let store = CredentialStore(service: "local.marketdecision.test." + UUID().uuidString)
        let reference = "disposable-synthetic-fixture"
        do {
            try await store.save(Data("synthetic-not-a-real-key".utf8), reference: reference)
            #expect(try await store.isDeviceOnlyWhileUnlocked(reference: reference))
            #expect(try await store.protection(reference: reference).synchronizable == false)
            #expect(try await store.read(reference: reference) == Data("synthetic-not-a-real-key".utf8))
            try await store.save(Data("replacement-synthetic".utf8), reference: reference)
            #expect(try await store.read(reference: reference) == Data("replacement-synthetic".utf8))
            try await store.delete(reference: reference)
            #expect(try await store.read(reference: reference) == nil)
        } catch {
            try? await store.delete(reference: reference)
            throw error
        }
    }
}


@Suite struct CredentialAttributeTests {
    func decode(_ sync: Any?, accessibility: Any? = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws -> CredentialProtection {
        var attributes: [String: Any] = [:]
        attributes[kSecAttrSynchronizable as String] = sync
        attributes[kSecAttrAccessible as String] = accessibility
        return try CredentialProtection(attributes: attributes)
    }
    @Test func acceptsBooleanAndBinaryIntegerRepresentations() throws {
        #expect(try decode(kCFBooleanFalse).synchronizable == false)
        #expect(try decode(kCFBooleanTrue).synchronizable == true)
        #expect(try decode(false).deviceOnlyWhileUnlocked)
        #expect(try !decode(NSNumber(value: 0)).synchronizable)
        #expect(try decode(NSNumber(value: 1)).synchronizable)
    }
    @Test func rejectsNumericAndTextCoercion() {
        let values: [Any] = [NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: 0.5), "false", "0", NSNull()]
        for value in values {
            #expect(throws: (any Error).self) { try decode(value) }
        }
    }
    @Test func rejectsMissingOrMalformedAttributes() {
        #expect(throws: (any Error).self) { try decode(nil) }
        #expect(throws: (any Error).self) { try decode(false, accessibility: nil) }
        #expect(throws: (any Error).self) { try decode(false, accessibility: NSNumber(value: 1)) }
    }
    @Test func otherAccessibilityIsNotDeviceOnly() throws {
        #expect(try !decode(false, accessibility: kSecAttrAccessibleAfterFirstUnlock).deviceOnlyWhileUnlocked)
    }
}
