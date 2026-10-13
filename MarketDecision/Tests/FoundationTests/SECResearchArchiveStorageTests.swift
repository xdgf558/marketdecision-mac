import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import DataProviders
import SECProvider
import FundamentalsEngine
@testable import Persistence

private let archiveConsent = SECLocalArchiveConsent.personalLocalBackup

private func archivePretty<T: Encodable>(_ value: T) throws -> Data {
    try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: ResearchDocument.encoded(value)),
                               options: [.prettyPrinted, .sortedKeys])
}

private func archiveVersion(_ value: SECResearchDocument, id: UUID = UUID()) throws -> SECResearchDocument {
    var object = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(value)) as? [String: Any])
    object["id"] = id.uuidString
    return try JSONDecoder().decode(SECResearchDocument.self, from: JSONSerialization.data(withJSONObject: object))
}

private func archiveRows(_ database: DatabaseStore) throws -> [Data] {
    try database.read { db in
        try Data.fetchAll(db, sql: "SELECT document_json FROM sec_research_documents ORDER BY document_id")
        + Data.fetchAll(db, sql: "SELECT report_json FROM sec_financial_report_documents ORDER BY report_id")
        + Data.fetchAll(db, sql: "SELECT supplement_json FROM sec_valuation_supplement_documents ORDER BY supplement_id")
    }
}

private func archiveLegacyBundle(_ document: SECResearchDocument) throws -> SnapshotBundle {
    let identity = ObjectIdentity(id: document.id.uuidString.lowercased(), version: "sec-research.v1")
    let object = FrozenObject(identity: identity, kind: .result,
        payload: .string(try archivePretty(document).base64EncodedString()), references: [],
        capturedAt: try MillisecondInstant(rounding: document.cutoff),
        permission: .init(mayStore: true, mayBackup: false, evidenceReference: "sec-research.local-only.v1"), synthetic: false)
    return SnapshotBundle(sourceNamespace: document.id, objects: [object], roots: [
        .init(identity: identity, kind: .analysisRun,
              references: [.init(role: "sec-research", target: identity, contentHash: try object.contentHash())]),
    ])
}

private func archiveForeignBundle(namespace: UUID = UUID()) throws -> SnapshotBundle {
    let capturedAt = try MillisecondInstant(iso8601: "2026-09-10T01:02:03.123Z")
    let permission = RetentionPermission(mayStore: true, mayBackup: true, evidenceReference: "synthetic.other-workspace")
    let input = FrozenObject(identity: .init(id: "other-input", version: "v1"), kind: .input,
        payload: .string("retained external input"), references: [], capturedAt: capturedAt, permission: permission, synthetic: true)
    let result = FrozenObject(identity: .init(id: "other-result", version: "v1"), kind: .result,
        payload: .string("retained external result"),
        references: [.init(role: "input", target: input.identity, contentHash: try input.contentHash())],
        capturedAt: capturedAt, permission: permission, synthetic: true)
    let root = SnapshotRoot(identity: .init(id: "other-research", version: "v1"), kind: .researchRun,
        references: [.init(role: "result", target: result.identity, contentHash: try result.contentHash())])
    return SnapshotBundle(sourceNamespace: namespace, objects: [input, result], roots: [root])
}

/// Include every SQL field, including source addresses, original JSON bytes and both
/// kinds of resolved edges. A count-only check would miss a rewritten or retargeted graph.
private func archiveSnapshotRows(_ database: DatabaseStore, namespace: UUID? = nil) throws -> [[Row]] {
    try database.read { db in
        try ["p1_snapshot_objects", "p1_snapshot_roots", "p1_snapshot_object_edges", "p1_snapshot_root_edges"].map { table in
            let condition = namespace == nil ? "" : " WHERE namespace = ?"
            let arguments: StatementArguments = namespace.map { [$0.uuidString.lowercased()] } ?? []
            return try Row.fetchAll(db, sql: "SELECT * FROM " + table + condition + " ORDER BY 1, 2, 3", arguments: arguments)
        }
    }
}

private func archiveFamilyRows(_ database: DatabaseStore) throws -> [[Row]] {
    try database.read { db in
        try ["sec_research_catalog", "sec_research_documents", "sec_financial_report_catalog",
             "sec_financial_report_documents", "sec_valuation_supplement_catalog", "sec_valuation_supplement_documents"].map {
            try Row.fetchAll(db, sql: "SELECT * FROM " + $0 + " ORDER BY 1")
        }
    }
}

/// Persist an internally valid cross-namespace reference while deliberately keeping
/// the business revision. Restore must recheck ownership/dependencies at commit too.
private func archiveAttachForeignReference(_ database: DatabaseStore, foreign: SnapshotBundle,
                                          legacy: SnapshotBundle, fromRoot: Bool, revision: UUID) throws {
    let target = try #require(legacy.objects.first)
    let result = try #require(foreign.objects.first { $0.kind == .result })
    let root = try #require(foreign.roots.first)
    let targetAddress = ObjectAddress(namespace: legacy.sourceNamespace, identity: target.identity)
    let resultAddress = ObjectAddress(namespace: foreign.sourceNamespace, identity: result.identity)
    let rootAddress = ObjectAddress(namespace: foreign.sourceNamespace, identity: root.identity)
    let link = ObjectReference(role: "retained-sec-input", target: target.identity, contentHash: try target.contentHash())
    try database.transaction { db in
        var graph = try BusinessDataStore.loadGraph(db)
        let storedResult = try #require(graph.objects[resultAddress]), storedRoot = try #require(graph.roots[rootAddress])
        let updated = FrozenObject(identity: result.identity, kind: result.kind, payload: result.payload,
            references: result.references + (fromRoot ? [] : [link]), capturedAt: result.capturedAt,
            permission: result.permission, synthetic: result.synthetic)
        var objectTargets = storedResult.targets
        if !fromRoot { objectTargets[link.role] = targetAddress }
        graph.objects[resultAddress] = PersistedObject(object: updated, source: storedResult.source, targets: objectTargets)
        let updatedRoot = SnapshotRoot(identity: root.identity, kind: root.kind,
            references: [.init(role: "result", target: result.identity, contentHash: try updated.contentHash())] + (fromRoot ? [link] : []))
        var rootTargets = storedRoot.targets
        if fromRoot { rootTargets[link.role] = targetAddress }
        graph.roots[rootAddress] = PersistedRoot(root: updatedRoot, source: storedRoot.source, targets: rootTargets)
        try BusinessDataStore.validate(graph)
        try BusinessDataStore.save(graph, revision: revision, db: db)
        _ = try BusinessDataStore.loadGraph(db)
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
}

/// Deliberately noncanonical encodings at all three levels make accidental re-encoding
/// observable. Parent bindings are constructed from those exact retained encodings.
private func archiveStorageFixture(filingHTML: String = "<p>QA</p>") async throws
    -> (database: DatabaseStore, store: SECResearchStore, research: SECResearchDocument,
        report: SECFinancialReportDocument, supplement: SECValuationSupplementDocument) {
    let database = try DatabaseStore(path: ":memory:", purpose: .secResearch)
    let store = try SECResearchStore(database: database), research = try await secFinancialReportFixtureParent(filingHTML: filingHTML)
    let researchBytes = try archivePretty(research)
    try database.transaction { db in
        try SECResearchStorage.insert(research, bytes: researchBytes, db: db)
        try BusinessDataStore.writeRevision(UUID(), db: db)
    }
    let report = try await store.prepareFinancialReport(parentID: research.id, executionDate: research.cutoff.addingTimeInterval(1)).document
    try database.transaction { db in
        try SECFinancialReportStorage.insert(report, bytes: archivePretty(report), db: db)
        try BusinessDataStore.writeRevision(UUID(), db: db)
    }
    let supplement = try await store.prepareValuationSupplement(parentReportID: report.id, evidence: .init(),
        executionDate: research.cutoff.addingTimeInterval(2)).document
    try database.transaction { db in
        try SECValuationSupplementStorage.insert(supplement, bytes: archivePretty(supplement), db: db)
        try BusinessDataStore.writeRevision(UUID(), db: db)
    }
    return (database, store, research, report, supplement)
}

private struct ArchiveIdentityTransport: HTTPTransport {
    let body: Data
    func send(_ request: URLRequest) async throws -> HTTPPayload { .init(statusCode: 200, mediaType: "application/json", body: body) }
}
private struct ArchiveIdentityGate: SECRequestGate { func wait() async throws {} }

private func archiveAcceptedIdentity(_ document: SECResearchDocument) async throws -> AcceptedProviderPayload<SECCompanyIdentityRecord> {
    let body = try #require(document.sources.first { $0.endpoint == .companyIdentity }).bytes
    let provider = try SECEdgarProvider(userAgent: "ArchiveTests/1.0 synthetic@example.invalid", transport: ArchiveIdentityTransport(body: body),
        gate: ArchiveIdentityGate(), evidenceRef: "synthetic-archive-cache", licenseRef: "synthetic-archive-cache", now: { document.cutoff })
    let rights = EntitlementSnapshot(providerID: "sec-edgar", feedID: "public-edgar", version: "synthetic.archive.v1",
        evidenceRef: "synthetic-archive-cache", licenseRef: "synthetic-archive-cache", capabilities: [.companyIdentity], usages: [.replay],
        validFrom: document.cutoff.addingTimeInterval(-60), validThrough: document.cutoff.addingTimeInterval(60))
    let request = ProviderRequest(providerID: "sec-edgar", feedID: "public-edgar", resourceID: document.ticker,
        capability: .companyIdentity, mode: .latest, usage: .replay, configurationVersion: provider.capabilitySnapshot.version,
        entitlementVersion: rights.version, requestedAt: document.cutoff)
    return try await FundamentalsDataClient(provider: provider, entitlement: rights).companyIdentity(request)
}

/// A real SQLite trigger signals arrival and waits for an explicit release. Cancelling
/// the Swift task must reach the transaction even though GRDB's callback has no task.
private final class SECArchiveSQLGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func holdQueue() {
        condition.lock(); entered = true
        let current = waiters; waiters = []; condition.unlock()
        current.forEach { $0.resume() }
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitForQueue() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { condition.unlock(); continuation.resume(); return }
            waiters.append(continuation); condition.unlock()
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private actor SECArchiveEntryGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            pending = continuation; entered = true
            let current = waiters; waiters = []; current.forEach { $0.resume() }
        }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
    func release() { let current = pending; pending = nil; current?.resume() }
}

@Suite struct SECResearchArchiveStorageTests {
    @Test func exactThreeLevelBytesSurviveNewDatabaseReopenAndExplicitReplay() async throws {
        let original = try await archiveStorageFixture()
        let before = try archiveRows(original.database)
        let bytes = try await original.store.exportArchive(researchID: original.research.id, consent: archiveConsent)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try DatabaseStore(path: path.path, purpose: .secResearch), restored = try SECResearchStore(database: database)
        let plan = try await restored.prepareArchiveRestore(bytes, mode: .merge, consent: archiveConsent)
        #expect(plan.researchCount == 1 && plan.reportCount == 1 && plan.supplementCount == 1 && plan.removedResearchCount == 0)
        try await restored.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try archiveRows(database) == before)
        let reopened = try SECResearchStore(path: path.path)
        let research = try await reopened.open(id: original.research.id)
        #expect(try research.recompute() == original.research.normalization)
        let report = try await reopened.openFinancialReport(id: original.report.id)
        let financialReplay = try await report.financials.recompute()
        #expect(try report.financials.cachedReportsMatch(financialReplay))
        let supplement = try await reopened.openValuationSupplement(id: original.supplement.id)
        let valuationReplay = try await supplement.valuation.recompute()
        #expect(try supplement.valuation.cachedReportMatches(valuationReplay))
        #expect(!research.mayRunValuation && !supplement.valuation.assessment.productionEligible)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 0)
        #expect(try archiveRows(original.database) == before)
    }

    @Test func replaceRepairsDamagedBodiesAndPreservesRawAndTypedCaches() async throws {
        let incoming = try await archiveStorageFixture(), target = try await archiveStorageFixture()
        let bytes = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        let accepted = try await archiveAcceptedIdentity(target.research)
        _ = try await target.store.business.ingestSECIdentities(accepted, expectedRevision: target.store.writeRevision())
        let cacheBefore = try target.database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM p1_source_documents ORDER BY reference")
            + Data.fetchAll(db, sql: "SELECT record_json FROM p1_sec_identities ORDER BY record_id, version_id")
        }
        try target.database.transaction { db in
            for (table, field) in [("sec_research_documents", "document_json"), ("sec_financial_report_documents", "report_json"),
                                   ("sec_valuation_supplement_documents", "supplement_json")] {
                try db.execute(sql: "UPDATE " + table + " SET " + field + " = ?", arguments: [Data("damaged".utf8)])
            }
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await target.store.prepareArchiveRestore(bytes, mode: .merge, consent: archiveConsent)
        }
        let plan = try await target.store.prepareArchiveRestore(bytes, mode: .replace, consent: archiveConsent)
        #expect(plan.removedResearchCount == 1)
        #expect(plan.details.contains { $0.contains("1 份财务报告、1 份估值补充") })
        try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try await target.store.savedResearch().map(\.id) == [incoming.research.id])
        #expect(try archiveRows(target.database) == archiveRows(incoming.database))
        let cacheAfter = try target.database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM p1_source_documents ORDER BY reference")
            + Data.fetchAll(db, sql: "SELECT record_json FROM p1_sec_identities ORDER BY record_id, version_id")
        }
        #expect(cacheAfter == cacheBefore && cacheBefore.count == 2)
        #expect(try await target.store.business.secIdentity(ticker: target.research.ticker, asOf: target.research.cutoff).cik == target.research.identity.cik)
    }

    @Test func replaceKeepsOtherSnapshotGraphsWhileRemovingHealthyAndDamagedSECLegacy() async throws {
        let incoming = try await archiveStorageFixture()
        let archive = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        for damagedLegacy in [false, true] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: path) }
            let database = try DatabaseStore(path: path.path, purpose: .secResearch), store = try SECResearchStore(database: database)
            let legacyDocument = try archiveVersion(incoming.research), foreign = try archiveForeignBundle()
            let legacy = try archiveLegacyBundle(legacyDocument)
            try await store.business.freeze(foreign, expectedRevision: store.writeRevision())
            try await store.business.freeze(legacy, expectedRevision: store.writeRevision())
            // Exercise both unindexed legacy metadata and an indexed record whose
            // body is unusable. Neither makes the unrelated namespace disposable.
            if damagedLegacy { #expect(try await store.savedResearch().map(\.id) == [legacyDocument.id]) }
            try database.transaction { db in
                for object in foreign.objects {
                    try db.execute(sql: "UPDATE p1_snapshot_objects SET object_json = ? WHERE namespace = ? AND object_id = ?",
                        arguments: [try archivePretty(object), foreign.sourceNamespace.uuidString.lowercased(), object.identity.id])
                }
                for root in foreign.roots {
                    try db.execute(sql: "UPDATE p1_snapshot_roots SET root_json = ? WHERE namespace = ? AND root_id = ?",
                        arguments: [try archivePretty(root), foreign.sourceNamespace.uuidString.lowercased(), root.identity.id])
                }
                _ = try BusinessDataStore.loadGraph(db)
                if damagedLegacy {
                    try db.execute(sql: "UPDATE p1_snapshot_objects SET object_json = ?, content = ? WHERE namespace = ?",
                        arguments: [Data("broken legacy JSON".utf8), Data("broken legacy content".utf8), legacyDocument.id.uuidString.lowercased()])
                    try db.execute(sql: "UPDATE p1_snapshot_roots SET root_json = ? WHERE namespace = ?",
                        arguments: [Data("broken legacy root".utf8), legacyDocument.id.uuidString.lowercased()])
                }
            }
            let retained = try archiveSnapshotRows(database, namespace: foreign.sourceNamespace)
            #expect(retained.map(\.count) == [2, 1, 1, 1])
            let plan = try await store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
            #expect(plan.removedResearchCount == 1)
            try await store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
            #expect(try archiveSnapshotRows(database, namespace: foreign.sourceNamespace) == retained)
            #expect(try archiveSnapshotRows(database, namespace: legacyDocument.id).allSatisfy(\.isEmpty))
            #expect(try archiveRows(database) == archiveRows(incoming.database))
            #expect(try await store.savedResearch().map(\.id) == [incoming.research.id])
            let reopened = try SECResearchStore(path: path.path)
            #expect(try await reopened.open(id: incoming.research.id).sources == incoming.research.sources)
            #expect(try await reopened.savedResearch().map(\.id) == [incoming.research.id])
            let merge = try await reopened.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent)
            #expect(merge.removedResearchCount == 0)
            try await reopened.commitArchiveRestore(.init(planID: merge.id, digest: merge.digest))
            #expect(try archiveSnapshotRows(database, namespace: foreign.sourceNamespace) == retained)
            let graph = try database.read(BusinessDataStore.loadGraph)
            #expect(graph.objects.count == 2 && graph.roots.count == 1)
        }
    }

    @Test func replacePreviewRejectsForeignRootAndObjectReferencesWithoutChangingAnyRows() async throws {
        let incoming = try await archiveStorageFixture()
        let archive = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        for fromRoot in [false, true] {
            let target = try await archiveStorageFixture()
            let legacy = try archiveLegacyBundle(archiveVersion(target.research)), foreign = try archiveForeignBundle()
            try await target.store.business.freeze(legacy, expectedRevision: target.store.writeRevision())
            try await target.store.business.freeze(foreign, expectedRevision: target.store.writeRevision())
            let revision = try await target.store.writeRevision()
            try archiveAttachForeignReference(target.database, foreign: foreign, legacy: legacy, fromRoot: fromRoot, revision: revision)
            let snapshots = try archiveSnapshotRows(target.database), family = try archiveFamilyRows(target.database)
            await #expect(throws: SECArchiveError.scopeDenied) {
                try await target.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
            }
            #expect(try archiveSnapshotRows(target.database) == snapshots)
            #expect(try archiveFamilyRows(target.database) == family)
            #expect(try await target.store.writeRevision() == revision)
        }
    }

    @Test func replaceCommitRechecksLateForeignRootAndObjectReferencesWithoutRevisionChange() async throws {
        let incoming = try await archiveStorageFixture()
        let archive = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        for fromRoot in [false, true] {
            let target = try await archiveStorageFixture()
            let legacy = try archiveLegacyBundle(archiveVersion(target.research)), foreign = try archiveForeignBundle()
            try await target.store.business.freeze(legacy, expectedRevision: target.store.writeRevision())
            try await target.store.business.freeze(foreign, expectedRevision: target.store.writeRevision())
            let plan = try await target.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
            #expect(plan.removedResearchCount == 2)
            let revision = try await target.store.writeRevision()
            try archiveAttachForeignReference(target.database, foreign: foreign, legacy: legacy, fromRoot: fromRoot, revision: revision)
            let snapshots = try archiveSnapshotRows(target.database), family = try archiveFamilyRows(target.database)
            #expect(try await target.store.writeRevision() == plan.baseRevision)
            await #expect(throws: SECArchiveError.scopeDenied) {
                try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
            }
            #expect(try archiveSnapshotRows(target.database) == snapshots)
            #expect(try archiveFamilyRows(target.database) == family)
            #expect(try await target.store.writeRevision() == revision)
            _ = try target.database.read(BusinessDataStore.loadGraph)
        }
    }

    @Test func replaceRejectsMixedSECNamespaceInsteadOfDeletingUnownedSnapshotRows() async throws {
        let incoming = try await archiveStorageFixture(), target = try await archiveStorageFixture()
        let archive = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        let legacy = try archiveLegacyBundle(archiveVersion(target.research))
        let foreign = try archiveForeignBundle(namespace: legacy.sourceNamespace)
        try await target.store.business.freeze(legacy, expectedRevision: target.store.writeRevision())
        try await target.store.business.freeze(foreign, expectedRevision: target.store.writeRevision())
        let graph = try target.database.read(BusinessDataStore.loadGraph)
        #expect(graph.objects.count == 3 && graph.roots.count == 2)
        let snapshots = try archiveSnapshotRows(target.database), family = try archiveFamilyRows(target.database)
        let revision = try await target.store.writeRevision()
        await #expect(throws: SECArchiveError.scopeDenied) {
            try await target.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        }
        #expect(try archiveSnapshotRows(target.database) == snapshots)
        #expect(try archiveFamilyRows(target.database) == family)
        #expect(try await target.store.writeRevision() == revision)
    }

    @Test func identicalMergeKeepsBytesAndDifferentEncodingUnderSameIDConflicts() async throws {
        let f = try await archiveStorageFixture(), before = try archiveRows(f.database)
        let archive = try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
        let revision = try await f.store.writeRevision()
        let plan = try await f.store.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent)
        try await f.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try archiveRows(f.database) == before)
        #expect(try await f.store.writeRevision() != revision)
        await #expect(throws: SnapshotError.unknownPlan) { try await f.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest)) }
        let different = SECArchiveState(research: try ResearchDocument.encoded(f.research), reports: [], supplements: [])
        let conflicting = try SECResearchArchiveCodec.encode(different, consent: archiveConsent)
        await #expect(throws: SECArchiveError.identifierConflict) {
            try await f.store.prepareArchiveRestore(conflicting, mode: .merge, consent: archiveConsent)
        }
        #expect(try archiveRows(f.database) == before)
    }

    @Test func restoreRevisionRejectsLateReportDraftAndAcceptedImportWithoutRepinning() async throws {
        let f = try await archiveStorageFixture(), incoming = try await archiveStorageFixture()
        let oldDraft = try await f.store.prepareFinancialReport(parentID: f.research.id, executionDate: f.research.cutoff.addingTimeInterval(3))
        let oldSupplement = try await f.store.prepareValuationSupplement(parentReportID: f.report.id, evidence: .init(),
            executionDate: f.research.cutoff.addingTimeInterval(4))
        let oldRevision = oldDraft.expectedRevision, accepted = try await archiveAcceptedIdentity(f.research)
        let oldResearch = try archiveVersion(f.research)
        let archive = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        let plan = try await f.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        try await f.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        let restoredRevision = try await f.store.writeRevision()
        await #expect(throws: SnapshotError.stalePlan) { try await f.store.save(oldResearch, expectedRevision: oldRevision) }
        await #expect(throws: SnapshotError.stalePlan) { try await f.store.saveFinancialReport(oldDraft.document, expectedRevision: oldRevision) }
        await #expect(throws: SnapshotError.stalePlan) { try await f.store.saveValuationSupplement(oldSupplement.document, expectedRevision: oldSupplement.expectedRevision) }
        await #expect(throws: SnapshotError.stalePlan) { try await f.store.business.ingestSECIdentities(accepted, expectedRevision: oldRevision) }
        #expect(try await f.store.writeRevision() == restoredRevision)
        #expect(try f.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_source_documents") } == 0)
        #expect(try archiveRows(f.database) == archiveRows(incoming.database))
    }

    @Test func competingConnectionConsumesStalePlanAndApprovalIsBoundToExactPreview() async throws {
        let f = try await archiveStorageFixture()
        let archive = try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let first = try SECResearchStore(path: path.path), second = try SECResearchStore(path: path.path)
        let plan = try await first.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent)
        await #expect(throws: SnapshotError.approvalMismatch) { try await first.commitArchiveRestore(.init(planID: plan.id, digest: "wrong")) }
        await #expect(throws: SnapshotError.resourceLimit) { try await first.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent) }
        let competing = try archiveVersion(f.research)
        try await second.save(competing, expectedRevision: second.writeRevision())
        await #expect(throws: SnapshotError.stalePlan) { try await first.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest)) }
        await #expect(throws: SnapshotError.unknownPlan) { try await first.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest)) }
        let retry = try await first.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent)
        let revision = try await first.writeRevision()
        await first.cancelArchiveRestore(retry.id)
        #expect(try await first.writeRevision() == revision)
        await #expect(throws: SnapshotError.unknownPlan) { try await first.commitArchiveRestore(.init(planID: retry.id, digest: retry.digest)) }
        #expect(try await first.savedResearch().map(\.id) == [competing.id])
    }

    @Test func transactionFailureAfterAllInsertsRollsBackAndSameApprovalCanRetry() async throws {
        let f = try await archiveStorageFixture(), target = try await archiveStorageFixture()
        let archive = try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
        let oldRows = try archiveRows(target.database), oldRevision = try await target.store.writeRevision()
        let plan = try await target.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        try target.database.transaction { db in
            try db.execute(sql: "CREATE TRIGGER archive_abort BEFORE UPDATE ON p1_store_metadata BEGIN SELECT RAISE(ABORT, 'synthetic rollback'); END")
        }
        await #expect(throws: (any Error).self) { try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest)) }
        #expect(try archiveRows(target.database) == oldRows)
        #expect(try await target.store.writeRevision() == oldRevision)
        try target.database.transaction { db in try db.execute(sql: "DROP TRIGGER archive_abort") }
        try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try archiveRows(target.database) == archiveRows(f.database))
        #expect(try await target.store.writeRevision() != oldRevision)
    }

    @Test func legacyExportKeepsOriginalPermissionAndRestoresExactBytesAsBlob() async throws {
        let database = try DatabaseStore(path: ":memory:", purpose: .secResearch), store = try SECResearchStore(database: database)
        let document = try await secFinancialReportFixtureParent(), bytes = try archivePretty(document)
        let id = ObjectIdentity(id: document.id.uuidString.lowercased(), version: "sec-research.v1")
        let object = FrozenObject(identity: id, kind: .result, payload: .string(bytes.base64EncodedString()), references: [],
            capturedAt: try MillisecondInstant(rounding: document.cutoff),
            permission: .init(mayStore: true, mayBackup: false, evidenceReference: "sec-research.local-only.v1"), synthetic: false)
        let root = SnapshotRoot(identity: id, kind: .analysisRun,
            references: [.init(role: "sec-research", target: id, contentHash: try object.contentHash())])
        try await store.business.freeze(.init(sourceNamespace: document.id, objects: [object], roots: [root]), expectedRevision: store.writeRevision())
        let frozenBefore = try #require(database.read { try Data.fetchOne($0, sql: "SELECT object_json FROM p1_snapshot_objects") })
        await #expect(throws: SnapshotError.retentionDenied) { try await ResearchTransferStore(database: database).exportBackup() }
        let archive = try await store.exportArchive(researchID: document.id, consent: archiveConsent)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT object_json FROM p1_snapshot_objects") } == frozenBefore)
        #expect(!object.permission.mayBackup)
        let restoredDB = try DatabaseStore(path: ":memory:", purpose: .secResearch), restored = try SECResearchStore(database: restoredDB)
        let plan = try await restored.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent)
        try await restored.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try restoredDB.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == bytes)
        #expect(try restoredDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM p1_snapshot_objects") } == 0)
    }

    @Test func pricedExistingFamilyRemainsDuringMergeButItsExportIsDenied() async throws {
        let current = try await archiveStorageFixture(filingHTML: secArchiveShareDisclosure), incoming = try await archiveStorageFixture()
        let evidence = try secArchivePricedEvidence(research: current.research, origin: .syntheticFixture)
        let priced = try await current.store.prepareValuationSupplement(parentReportID: current.report.id, evidence: evidence,
            executionDate: current.research.cutoff.addingTimeInterval(10))
        try await current.store.saveValuationSupplement(priced.document, expectedRevision: priced.expectedRevision)
        await #expect(throws: SECArchiveError.scopeDenied) { try await current.store.exportArchive(researchID: current.research.id, consent: archiveConsent) }
        let retained = try #require(current.database.read { try Data.fetchOne($0,
            sql: "SELECT supplement_json FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [priced.document.id.uuidString.lowercased()]) })
        let archive = try await incoming.store.exportArchive(researchID: incoming.research.id, consent: archiveConsent)
        let plan = try await current.store.prepareArchiveRestore(archive, mode: .merge, consent: archiveConsent)
        try await current.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try current.database.read { try Data.fetchOne($0,
            sql: "SELECT supplement_json FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [priced.document.id.uuidString.lowercased()]) } == retained)
        #expect(try await current.store.savedResearch().count == 2)
        #expect(try await current.store.openValuationSupplement(id: priced.document.id).valuation.evidence.prices.count == 1)
    }

    @Test func aReopenedStoreDoesNotInheritAnUncommittedApproval() async throws {
        let original = try await archiveStorageFixture()
        let archive = try await original.store.exportArchive(researchID: original.research.id, consent: archiveConsent)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let first = try SECResearchStore(path: path.path)
        let plan = try await first.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        let revision = try await first.writeRevision()
        let reopened = try SECResearchStore(path: path.path)
        await #expect(throws: SnapshotError.unknownPlan) {
            try await reopened.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        }
        #expect(try await reopened.writeRevision() == revision)
        #expect(try await reopened.savedResearch().isEmpty)
        let fresh = try await reopened.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        #expect(fresh.id != plan.id && fresh.digest != plan.digest)
        try await reopened.commitArchiveRestore(.init(planID: fresh.id, digest: fresh.digest))
        await #expect(throws: SnapshotError.stalePlan) {
            try await first.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        }
    }

    @Test func changedCatalogParentCannotHideSelectedChildrenFromExport() async throws {
        let f = try await archiveStorageFixture()
        let otherResearch = try archiveVersion(f.research)
        try await f.store.save(otherResearch, expectedRevision: f.store.writeRevision())
        let otherReport = try await f.store.prepareFinancialReport(parentID: otherResearch.id,
            executionDate: otherResearch.cutoff.addingTimeInterval(3))
        try await f.store.saveFinancialReport(otherReport.document, expectedRevision: otherReport.expectedRevision)
        let cases = [
            ("sec_financial_report_catalog", "report_id", f.report.id, "parent_document_id", otherResearch.id, f.research.id),
            ("sec_valuation_supplement_catalog", "supplement_id", f.supplement.id, "parent_research_id", otherResearch.id, f.research.id),
            ("sec_valuation_supplement_catalog", "supplement_id", f.supplement.id, "parent_report_id", otherReport.document.id, f.report.id),
        ]
        let before = try archiveRows(f.database)
        for (table, key, id, column, wrong, correct) in cases {
            let update = "UPDATE " + table + " SET " + column + " = ? WHERE " + key + " = ?"
            try f.database.transaction { db in
                try db.execute(sql: update, arguments: [wrong.uuidString.lowercased(), id.uuidString.lowercased()])
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) {
                try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
            }
            try f.database.transaction { try $0.execute(sql: update, arguments: [correct.uuidString.lowercased(), id.uuidString.lowercased()]) }
        }
        let archive = try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
        let restored = try SECResearchArchiveCodec.decode(archive, consent: archiveConsent)
        #expect(restored.documentCount == 3)
        #expect(try archiveRows(f.database) == before)
    }

    @Test func cancelledBeforeCommitEntryLeavesTheReviewedPlanAvailable() async throws {
        let f = try await archiveStorageFixture(), target = try await archiveStorageFixture()
        let archive = try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
        let plan = try await target.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        let before = try archiveRows(target.database), revision = try await target.store.writeRevision()
        let gate = SECArchiveEntryGate()
        let operation = Task {
            await gate.pause()
            try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        }
        await gate.waitForEntry(); operation.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try archiveRows(target.database) == before)
        #expect(try await target.store.writeRevision() == revision)
        try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try archiveRows(target.database) == archiveRows(f.database))
    }

    @Test func cancellationInsideSQLiteRollsBackDeletedRowsAndPermitsExactApprovalRetry() async throws {
        let f = try await archiveStorageFixture(), target = try await archiveStorageFixture()
        let archive = try await f.store.exportArchive(researchID: f.research.id, consent: archiveConsent)
        let plan = try await target.store.prepareArchiveRestore(archive, mode: .replace, consent: archiveConsent)
        let before = try archiveRows(target.database), revision = try await target.store.writeRevision()
        let gate = SECArchiveSQLGate()
        try target.database.transaction { db in
            db.add(function: DatabaseFunction("synthetic_archive_gate", argumentCount: 0) { _ in gate.holdQueue(); return 0 })
            try db.execute(sql: """
                CREATE TRIGGER synthetic_archive_pause BEFORE INSERT ON sec_research_catalog
                BEGIN SELECT synthetic_archive_gate(); END
                """)
        }
        let operation = Task { try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest)) }
        await gate.waitForQueue(); operation.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try archiveRows(target.database) == before)
        #expect(try await target.store.writeRevision() == revision)
        try target.database.transaction { try $0.execute(sql: "DROP TRIGGER synthetic_archive_pause") }
        try await target.store.commitArchiveRestore(.init(planID: plan.id, digest: plan.digest))
        #expect(try archiveRows(target.database) == archiveRows(f.database))
    }
}
