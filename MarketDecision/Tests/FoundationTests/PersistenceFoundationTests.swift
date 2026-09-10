import Foundation
import Testing
import CoreDomain
import DataContracts
import Persistence
import GRDB

private let snapshotTime = try! MillisecondInstant(iso8601: "2026-09-10T01:02:03.123Z")
private let snapshotNamespace = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private func object(_ id: String = "input", value: String = "1", refs: [ObjectReference] = [], mayStore: Bool = true, mayBackup: Bool = true) -> FrozenObject {
    FrozenObject(identity: .init(id: id, version: "1"), kind: .input, payload: .object([.init("value", .string(value))]), references: refs,
                 capturedAt: snapshotTime, permission: .init(mayStore: mayStore, mayBackup: mayBackup, evidenceReference: "synthetic.permission"), synthetic: true)
}
private func ref(_ object: FrozenObject, role: String = "input") throws -> ObjectReference {
    ObjectReference(role: role, target: object.identity, contentHash: try object.contentHash())
}
private func bundle(value: String = "1", rooted: Bool = true) throws -> SnapshotBundle {
    let input = object(value: value), result = try object("result", refs: [ref(input)])
    return try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [result, input],
        roots: rooted ? [SnapshotRoot(identity: .init(id: "research", version: "1"), kind: .researchRun, references: [ref(result)])] : [])
}
private func inventory(_ bundle: SnapshotBundle) throws -> BackupInventory {
    try BackupInventory(entries: bundle.objects.map {
        let size = Int64(try $0.contentBytes().count)
        return BackupObjectEntry(identity: $0.identity, path: "objects/\($0.identity.id).json", contentHash: try $0.contentHash(), bytes: size, compressedBytes: size)
    })
}
private func address(_ id: String) -> ObjectAddress { .init(namespace: snapshotNamespace, identity: .init(id: id, version: "1")) }
private func approve(_ plan: StoragePlan) -> PlanApproval { .init(planID: plan.id, digest: plan.digest) }

private final class CodecTestBundleAnchor: NSObject {}

@Suite struct StableTimeTests {
    @Test(arguments: ["0001-01-01T00:00:00.000Z", "1969-12-31T23:59:59.999Z", "1970-01-01T00:00:00.000Z", "2000-02-29T12:34:56.123Z", "2026-09-10T01:02:03.987Z", "9999-12-31T23:59:59.999Z"])
    func stringAndIntegerRemainStable(_ input: String) throws {
        let time = try MillisecondInstant(iso8601: input)
        #expect(time.iso8601 == input)
        #expect(try JSONDecoder().decode(MillisecondInstant.self, from: JSONEncoder().encode(time)) == time)
        #expect(try MillisecondInstant(milliseconds: time.milliseconds) == time)
    }
    @Test func rejectsNoncanonicalDatesAndExplicitlyRoundsDateBoundary() throws {
        #expect(try MillisecondInstant(milliseconds: -1).iso8601 == "1969-12-31T23:59:59.999Z")
        #expect(try MillisecondInstant(rounding: Date(timeIntervalSince1970: 100.1234)).milliseconds == 100123)
        #expect(try MillisecondInstant(rounding: Date(timeIntervalSince1970: 100.1236)).milliseconds == 100124)
        for input in ["2026-02-30T00:00:00.000Z", "2026-09-10T01:02:03Z", "2026-09-10T01:02:03.123+00:00", "2026-09-10T01:02:03.1234Z", "2026-09-10T01:02:60.000Z"] {
            #expect(throws: (any Error).self) { try MillisecondInstant(iso8601: input) }
        }
        #expect(throws: InstantError.outOfRange) { try MillisecondInstant(rounding: Date(timeIntervalSince1970: .nan)) }
        #expect(throws: InstantError.outOfRange) { try MillisecondInstant(milliseconds: Int64.max) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MillisecondInstant.self, from: Data("123.4".utf8)) }
    }
    @Test func modelFingerprintSurvivesFractionalTimeAndSeparateProcesses() throws {
        let parameters = sampleParameters(), original = sampleModel(parameters: sampleParameters())
        var modelJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        modelJSON["introducedAt"] = "2026-09-10T01:02:03.123Z"
        modelJSON["deprecatedAt"] = "2026-09-10T01:02:04.987Z"
        let model = try JSONDecoder().decode(ModelDefinition.self, from: JSONSerialization.data(withJSONObject: modelJSON))
        struct Fixture: Codable { let parameters: ParameterSet; let model: ModelDefinition; let reference: RegistryReference }
        var bytes = try JSONEncoder().encode(Fixture(parameters: parameters, model: model, reference: model.reference))
        var executable: URL?
        // Xcode's runner executable lives in its toolchain; the test bundle lives beside products.
        for location in [Bundle(for: CodecTestBundleAnchor.self).bundleURL,
                         URL(fileURLWithPath: CommandLine.arguments[0])] {
            var parent = location.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = parent.appendingPathComponent("FoundationCodecProbe")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
                parent.deleteLastPathComponent()
            }
            if executable != nil { break }
        }
        let program = try #require(executable, "The SwiftPM test-only codec executable must be built alongside tests")
        for _ in 0..<3 {
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = program; process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run(); input.fileHandleForWriting.write(bytes); try input.fileHandleForWriting.close()
            bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let decoded = try JSONDecoder().decode(Fixture.self, from: bytes)
            #expect(decoded.model.reference == model.reference && decoded.reference == model.reference)
            #expect(decoded.model.introducedAt.iso8601 == "2026-09-10T01:02:03.123Z")
            #expect(decoded.model.deprecatedAt?.iso8601 == "2026-09-10T01:02:04.987Z")
        }
        #expect(model.reference.fingerprintVersion == "model.v2.utc-ms")
        modelJSON["introducedAt"] = 123.456
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelDefinition.self, from: JSONSerialization.data(withJSONObject: modelJSON)) }
        var oldReference = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.reference)) as? [String: Any])
        oldReference.removeValue(forKey: "fingerprintVersion")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RegistryReference.self, from: JSONSerialization.data(withJSONObject: oldReference)) }
    }
}

@Suite struct CanonicalSnapshotTests {
    @Test func canonicalPropertiesUseUTF16AndDoNotNormalizeUnicodeOrArrays() throws {
        let first = CanonicalValue.object([.init("z", .integer(9007199254740993)), .init("a", .array([.boolean(true), .null, .decimal(try Money("1.230"))]))])
        #expect(String(decoding: try first.canonicalData(), as: UTF8.self) == "{\"a\":[true,null,\"1.23\"],\"z\":\"9007199254740993\"}")
        let ordered = CanonicalValue.object([.init("\u{E000}", .null), .init("😀", .null), .init("\r", .string("\u{000f}\n\"\\/"))])
        #expect(String(decoding: try ordered.canonicalData(), as: UTF8.self) == "{\"\\r\":\"\\u000f\\n\\\"\\\\/\",\"😀\":null,\"\u{E000}\":null}")
        // Swift Strings compare these keys canonically equal; JCS must preserve both spellings.
        let unicode = CanonicalValue.object([.init("é", .string("é")), .init("e\u{301}", .string("e\u{301}"))])
        let bytes = try unicode.canonicalData()
        #expect(String(decoding: bytes, as: UTF8.self).utf8.elementsEqual("{\"e\u{301}\":\"e\u{301}\",\"é\":\"é\"}".utf8))
        #expect(try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(unicode)).canonicalData() == bytes)
        #expect(throws: SnapshotError.duplicateProperty) { try CanonicalValue.object([.init("a", .null), .init("a", .null)]).canonicalData() }
    }
    @Test func contentIncludesReferencesAndRoundTripsWithoutLosingDecimalSpellingRules() throws {
        let original = try bundle(), encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SnapshotBundle.self, from: encoded)
        try decoded.validate()
        for (a, b) in zip(original.objects, decoded.objects) { #expect(try a.contentBytes() == b.contentBytes()) }
        let other = try bundle(value: "2")
        #expect(try original.objects[0].contentHash() != other.objects[0].contentHash())
    }
    @Test func missingHashOnlyCyclesDuplicateIDsAndDeniedRetentionAreRejected() throws {
        let original = try bundle(), input = object()
        #expect(throws: SnapshotError.missingReference) { try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [original.objects[0]], roots: original.roots).validate() }
        let wrong = object("result", refs: [.init(role: "input", target: input.identity, contentHash: String(repeating: "0", count: 64))])
        #expect(throws: SnapshotError.hashMismatch) { try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [wrong, input], roots: []).validate() }
        let a = object("a", refs: [.init(role: "b", target: .init(id: "b", version: "1"), contentHash: String(repeating: "0", count: 64))])
        let b = object("b", refs: [.init(role: "a", target: a.identity, contentHash: String(repeating: "0", count: 64))])
        #expect(throws: SnapshotError.cycle) { try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [a,b], roots: []).validate() }
        #expect(throws: SnapshotError.duplicateObject) { try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [input,input], roots: []).validate() }
        #expect(throws: SnapshotError.retentionDenied) { try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [object(mayStore: false)], roots: []).validate() }
        #expect(throws: SnapshotError.retentionDenied) { try SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [object(mayBackup: false)], roots: []).validate(forBackup: true) }
    }
    @Test func malformedDecodedFormatsAndExcessiveDepthFail() throws {
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(try bundle())) as? [String: Any])
        encoded["schemaVersion"] = "future"
        let unknown = try JSONDecoder().decode(SnapshotBundle.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(throws: SnapshotError.unsupportedFormat) { try unknown.validate() }
        var nested = CanonicalValue.null
        for _ in 0..<66 { nested = .array([nested]) }
        #expect(throws: SnapshotError.resourceLimit) { try nested.canonicalData() }
    }
}

@Suite struct SnapshotStorageTests {
    @Test func freezeProtectsTransitiveDependenciesAndRejectsOverwrite() async throws {
        let store = MockSnapshotStore(), data = try bundle()
        try await store.freeze(data, expectedRevision: store.revision())
        let input = try #require(data.objects.first { $0.identity.id == "input" })
        #expect(try await store.content(at: address("input"), expectedHash: input.contentHash()) == input.contentBytes())
        await #expect(throws: SnapshotError.protectedObject) { try await store.prepareDeletion(.unreferencedCache([address("input")]), expectedRevision: store.revision()) }
        await #expect(throws: SnapshotError.duplicateObject) { try await store.freeze(bundle(value: "2"), expectedRevision: store.revision()) }
        #expect(try await store.content(at: address("input"), expectedHash: input.contentHash()) == input.contentBytes())
    }
    @Test func newReferenceInvalidatesCleanupBeforeDeletion() async throws {
        let store = MockSnapshotStore(), unrooted = try bundle(rooted: false)
        try await store.freeze(unrooted, expectedRevision: store.revision())
        let plan = try await store.prepareDeletion(.unreferencedCache([address("input"),address("result")]), expectedRevision: store.revision())
        try await store.freeze(bundle(), expectedRevision: store.revision())
        await #expect(throws: SnapshotError.stalePlan) { try await store.commit(approve(plan)) }
        #expect(await store.counts().objects == 2)
        await #expect(throws: SnapshotError.protectedObject) { try await store.prepareDeletion(.unreferencedCache([address("input"),address("result")]), expectedRevision: store.revision()) }
    }
    @Test func conflictMergeRemapsWholeGraphWithoutChangingFrozenHashes() async throws {
        let store = MockSnapshotStore(), original = try bundle(), incoming = try bundle(value: "2")
        try await store.freeze(original, expectedRevision: store.revision())
        let before = await store.revision()
        let plan = try await store.prepareRestore(incoming, inventory: inventory(incoming), mode: .merge, expectedRevision: before)
        #expect(await store.revision() == before)
        #expect(await store.counts().objects == 2)
        #expect(plan.objectCount == 4 && plan.rootCount == 2)
        let importedInput = try #require(plan.importedAddresses[.init(id: "input", version: "1")])
        let importedResult = try #require(plan.importedAddresses[.init(id: "result", version: "1")])
        #expect(importedInput.namespace != snapshotNamespace)
        _ = try await store.commit(approve(plan))
        #expect(try await store.resolvedTargets(at: importedResult)["input"] == importedInput)
        for item in incoming.objects { #expect(try await store.content(at: plan.importedAddresses[item.identity]!, expectedHash: item.contentHash()) == item.contentBytes()) }
        for item in original.objects { #expect(try await store.content(at: .init(namespace: snapshotNamespace, identity: item.identity), expectedHash: item.contentHash()) == item.contentBytes()) }
        await #expect(throws: SnapshotError.unknownPlan) { try await store.commit(approve(plan)) }
    }
    @Test func repeatedConflictingImportDeduplicatesItsPreviouslyRemappedGraph() async throws {
        let store = MockSnapshotStore(), old = try bundle(), incoming = try bundle(value: "2")
        try await store.freeze(old, expectedRevision: store.revision())
        let first = try await store.prepareRestore(incoming, inventory: inventory(incoming), mode: .merge, expectedRevision: store.revision())
        _ = try await store.commit(approve(first))
        let again = try await store.prepareRestore(incoming, inventory: inventory(incoming), mode: .merge, expectedRevision: store.revision())
        #expect(again.deduplicatedObjects == 2 && again.objectCount == 4 && again.rootCount == 2)
        #expect(again.importedAddresses == first.importedAddresses && again.importedRoots == first.importedRoots)
        _ = try await store.commit(approve(again))
        await #expect(throws: SnapshotError.protectedObject) {
            try await store.prepareDeletion(.unreferencedCache(Set(first.importedAddresses.values)), expectedRevision: store.revision())
        }
    }
    @Test func identicalMergeReusesIdentityAndRoots() async throws {
        let store = MockSnapshotStore(), data = try bundle()
        try await store.freeze(data, expectedRevision: store.revision())
        let plan = try await store.prepareRestore(data, inventory: inventory(data), mode: .merge, expectedRevision: store.revision())
        #expect(plan.deduplicatedObjects == 2 && plan.objectCount == 2 && plan.rootCount == 1)
        #expect(plan.importedRoots[.init(id: "research", version: "1")] == address("research"))
        _ = try await store.commit(approve(plan))
    }
    @Test func cancellationWrongApprovalAndFailurePreserveOriginalState() async throws {
        let store = MockSnapshotStore(), data = try bundle(), incoming = try bundle(value: "2")
        try await store.freeze(data, expectedRevision: store.revision())
        let before = await store.revision()
        let plan = try await store.prepareRestore(incoming, inventory: inventory(incoming), mode: .replace, expectedRevision: before)
        await #expect(throws: SnapshotError.approvalMismatch) { try await store.commit(.init(planID: plan.id, digest: "wrong")) }
        await store.cancel(planID: plan.id)
        await #expect(throws: SnapshotError.unknownPlan) { try await store.commit(approve(plan)) }
        let fail = try await store.prepareRestore(incoming, inventory: inventory(incoming), mode: .replace, expectedRevision: before)
        await store.injectFailureOnNextCommit()
        await #expect(throws: MockCommitError.injectedFailure) { try await store.commit(approve(fail)) }
        #expect(await store.revision() == before)
        #expect(await store.counts().objects == 2)
        for item in data.objects { #expect(try await store.content(at: .init(namespace: snapshotNamespace, identity: item.identity), expectedHash: item.contentHash()) == item.contentBytes()) }
        let retried = try await store.commit(approve(fail))
        #expect(retried.operation == .replace && retried.revision != before)
        for item in incoming.objects {
            #expect(try await store.content(at: fail.importedAddresses[item.identity]!, expectedHash: item.contentHash()) == item.contentBytes())
        }
        await #expect(throws: SnapshotError.unknownPlan) { try await store.commit(approve(fail)) }
    }
    @Test func replacementRemovesPriorGraphOnlyOnSuccessfulCommit() async throws {
        let store = MockSnapshotStore(), data = try bundle(), incoming = try bundle(value: "2")
        try await store.freeze(data, expectedRevision: store.revision())
        let plan = try await store.prepareRestore(incoming, inventory: inventory(incoming), mode: .replace, expectedRevision: store.revision())
        #expect(plan.objectCount == 2 && plan.rootCount == 1)
        #expect(plan.removedObjects == [address("input"), address("result")] && plan.removedRoots == [address("research")])
        let result = try await store.commit(approve(plan)); #expect(result.credentialAction == .untouched)
        await #expect(throws: SnapshotError.missingReference) { try await store.content(at: address("input"), expectedHash: data.objects[1].contentHash()) }
        #expect(try await store.content(at: plan.importedAddresses[incoming.objects[1].identity]!, expectedHash: incoming.objects[1].contentHash()) == incoming.objects[1].contentBytes())
    }
    @Test func rootDeletionCacheCleanupAndBusinessClearAreSeparate() async throws {
        let store = MockSnapshotStore(), data = try bundle()
        try await store.freeze(data, expectedRevision: store.revision())
        let root = try await store.prepareDeletion(.roots([address("research")]), expectedRevision: store.revision())
        _ = try await store.commit(approve(root))
        let afterRootDeletion = await store.counts()
        #expect(afterRootDeletion.objects == 2 && afterRootDeletion.roots == 0)
        await #expect(throws: SnapshotError.protectedObject) { try await store.prepareDeletion(.unreferencedCache([address("input")]), expectedRevision: store.revision()) }
        let cleanup = try await store.prepareDeletion(.unreferencedCache([address("input"),address("result")]), expectedRevision: store.revision())
        _ = try await store.commit(approve(cleanup)); #expect(await store.counts().objects == 0)
        try await store.freeze(data, expectedRevision: store.revision())
        let clear = try await store.prepareDeletion(.allBusiness, expectedRevision: store.revision())
        let done = try await store.commit(approve(clear))
        #expect(done.credentialAction == .untouched && done.operation == .clearBusiness)
        let afterClear = await store.counts()
        #expect(afterClear.objects == 0 && afterClear.roots == 0)
    }
}

@Suite struct BackupBoundaryTests {
    private func entry(path: String = "objects/a.json", bytes: Int64 = 100, compressed: Int64 = 100,
                       kind: ArchiveEntryKind = .regularFile, contentClass: ArchiveContentClass = .business, id: String = "a") -> BackupObjectEntry {
        .init(identity: .init(id: id, version: "1"), path: path, contentHash: String(repeating: "a", count: 64),
              bytes: bytes, compressedBytes: compressed, kind: kind, contentClass: contentClass)
    }
    @Test func rejectsPathTraversalLinksDuplicatePathsAndCredentialDeclarations() throws {
        for path in ["../a", "/a", "a/../b", "a//b", "a/./b", "C:/a", "a\\b", "a/", "a\n"] {
            #expect(throws: SnapshotError.unsafeArchive) { try BackupInventory(entries: [entry(path: path)]).validateDeclarations() }
        }
        for kind: ArchiveEntryKind in [.directory, .symbolicLink] {
            #expect(throws: SnapshotError.unsafeArchive) { try BackupInventory(entries: [entry(kind: kind)]).validateDeclarations() }
        }
        #expect(throws: SnapshotError.unsafeArchive) { try BackupInventory(entries: [entry(path: "a.json"), entry(path: "A.json", id: "b")]).validateDeclarations() }
        for kind: ArchiveContentClass in [.credential, .deviceCredentialReference] {
            #expect(throws: SnapshotError.credentialMaterial) { try BackupInventory(entries: [entry(contentClass: kind)]).validateDeclarations() }
        }
    }
    @Test func resourceLimitsRejectOversizeAndImpossibleCompressionWithoutAllocatingPayloads() throws {
        try BackupInventory(entries: [entry(bytes: 100, compressed: 1)]).validateDeclarations()
        for values in [(Int64(101),Int64(1)), (1,0), (-1,1), (1_073_741_825,20_000_000), (1,Int64.max)] {
            #expect(throws: SnapshotError.resourceLimit) { try BackupInventory(entries: [entry(bytes: values.0, compressed: values.1)]).validateDeclarations() }
        }
        #expect(throws: SnapshotError.resourceLimit) {
            try BackupInventory(entries: (0..<9).map { entry(path: "a\($0).json", bytes: 1_073_741_824, compressed: 20_000_000, id: "a\($0)") }).validateDeclarations()
        }
        #expect(throws: SnapshotError.resourceLimit) {
            try BackupInventory(entries: (0..<3).map { entry(path: "a\($0).json", bytes: 1, compressed: 1_073_741_824, id: "a\($0)") }).validateDeclarations()
        }
        #expect(throws: SnapshotError.resourceLimit) { try BackupInventory(entries: Array(repeating: entry(), count: 100001)).validateDeclarations() }
    }
    @Test func inventoryMustDescribeTheActualCanonicalObjectBytes() throws {
        let data = try bundle(), valid = try inventory(data)
        try valid.validate(bundle: data)
        #expect(throws: SnapshotError.missingReference) { try BackupInventory(entries: []).validate(bundle: data) }
        let changed = try bundle(value: "2")
        #expect(throws: SnapshotError.hashMismatch) { try valid.validate(bundle: changed) }
        let denied = SnapshotBundle(sourceNamespace: snapshotNamespace, objects: [object(mayBackup: false)], roots: [])
        #expect(throws: SnapshotError.retentionDenied) { try inventory(denied).validate(bundle: denied) }
    }
    @Test func malformedRestoreCannotChangeExistingStateAndStalePlansAreRejected() async throws {
        let store = MockSnapshotStore(), data = try bundle()
        try await store.freeze(data, expectedRevision: store.revision())
        let before = await store.revision()
        await #expect(throws: SnapshotError.missingReference) {
            try await store.prepareRestore(data, inventory: .init(entries: []), mode: .replace, expectedRevision: before)
        }
        #expect(await store.revision() == before)
        let a = try await store.prepareDeletion(.allBusiness, expectedRevision: before)
        let b = try await store.prepareRestore(data, inventory: inventory(data), mode: .merge, expectedRevision: before)
        _ = try await store.commit(approve(a))
        await #expect(throws: SnapshotError.stalePlan) { try await store.commit(approve(b)) }
        #expect(await store.counts().objects == 0)
    }
}

@Suite struct MigrationFoundationTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
    @Test func migrationFailurePreservesPriorRowsAndSuccessfulHistoryThenCanRetry() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("fixture.sqlite").path
        let first = DatabaseMigration(identifier: "synthetic.v1") { db in
            try db.execute(sql: "CREATE TABLE fixture (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO fixture VALUES ('original')")
        }
        _ = try DatabaseStore(path: path, migrations: [first])
        enum Failure: Error { case injected }
        let failing = DatabaseMigration(identifier: "synthetic.v2") { db in
            try db.execute(sql: "CREATE TABLE transient_fixture (value TEXT)")
            try db.execute(sql: "DELETE FROM fixture")
            throw Failure.injected
        }
        #expect(throws: Failure.injected) { try DatabaseStore(path: path, migrations: [first, failing]) }
        let reopened = try DatabaseStore(path: path, migrations: [first])
        #expect(try reopened.migrationVersions() == ["foundation.v1","synthetic.v1"])
        #expect(try reopened.read { try String.fetchOne($0, sql: "SELECT value FROM fixture") } == "original")
        #expect(try reopened.read { try !$0.tableExists("transient_fixture") })
        let successful = DatabaseMigration(identifier: "synthetic.v2") { try $0.execute(sql: "ALTER TABLE fixture ADD COLUMN note TEXT") }
        #expect(try DatabaseStore(path: path, migrations: [first, successful]).migrationVersions() == ["foundation.v1","synthetic.v1","synthetic.v2"])
    }
    @Test func transactionsRollbackWithoutErasureAndKeepDecimalTextExact() throws {
        let store = try DatabaseStore(path: ":memory:")
        try store.transaction { try $0.execute(sql: "CREATE TABLE fixture (amount TEXT NOT NULL)") }
        let money = try Money("12345678901234567890.123456789012345678")
        try store.transaction { try $0.execute(sql: "INSERT INTO fixture VALUES (?)", arguments: [money.decimalString]) }
        enum Failure: Error { case injected }
        #expect(throws: Failure.injected) {
            try store.transaction { db in
                try db.execute(sql: "DELETE FROM fixture")
                try db.execute(sql: "INSERT INTO fixture VALUES ('replacement')")
                throw Failure.injected
            }
        }
        #expect(try store.read { try String.fetchOne($0, sql: "SELECT amount FROM fixture") } == money.decimalString)
        #expect(try store.read { try String.fetchOne($0, sql: "SELECT typeof(amount) FROM fixture") } == "text")
    }
    @Test func unknownOrNonprefixMigrationHistoryIsRejectedBeforeUpgrading() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("fixture.sqlite").path
        let store = try DatabaseStore(path: path)
        try store.transaction { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('future.v9')") }
        #expect(throws: MigrationError.unsupportedHistory) { try DatabaseStore(path: path) }
        #expect(try store.migrationVersions() == ["foundation.v1","future.v9"])
        let plan = [DatabaseMigration(identifier: "missing.v1") { _ in }, DatabaseMigration(identifier: "future.v9") { _ in }]
        #expect(throws: MigrationError.unsupportedHistory) { try DatabaseStore(path: path, migrations: plan) }
        #expect(throws: MigrationError.invalidCatalog) { try DatabaseStore(path: ":memory:", migrations: [.init(identifier: "foundation.v1") { _ in }]) }
        #expect(throws: MigrationError.invalidCatalog) { try DatabaseStore(path: ":memory:", migrations: [.init(identifier: " ") { _ in }]) }
    }
}
