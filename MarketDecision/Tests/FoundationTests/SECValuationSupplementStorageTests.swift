import Foundation
import Testing
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine
@testable import Persistence

func secValuationStorageFixture(path: String = ":memory:") async throws
    -> (DatabaseStore, SECResearchStore, SECResearchDocument, SECFinancialReportDocument, SECValuationSupplementDraft) {
    let database = try DatabaseStore(path: path, purpose: .secResearch)
    let store = try SECResearchStore(database: database)
    let research = try await secFinancialReportFixtureParent()
    try await store.save(research, expectedRevision: store.writeRevision())
    let report = try await store.prepareFinancialReport(parentID: research.id, executionDate: research.cutoff.addingTimeInterval(1))
    try await store.saveFinancialReport(report.document, expectedRevision: report.expectedRevision)
    let draft = try await store.prepareValuationSupplement(parentReportID: report.document.id, evidence: .init(),
        executionDate: research.cutoff.addingTimeInterval(2))
    return (database, store, research, report.document, draft)
}

private func valuationStorageCopy(_ supplement: SECValuationSupplementDocument) throws -> SECValuationSupplementDocument {
    var json = try #require(JSONSerialization.jsonObject(with: ResearchDocument.encoded(supplement)) as? [String: Any])
    json["id"] = UUID().uuidString
    return try JSONDecoder().decode(SECValuationSupplementDocument.self, from: JSONSerialization.data(withJSONObject: json))
}

/// Projection-only inputs reuse the synthetic parent's filing/provenance shape.
/// Production construction remains behind validatedParentChain and exact raw-byte checks.
private func shareCountCandidateFact(_ template: SECCompanyFactRecord, value: String,
                                    taxonomy: String = "us-gaap", concept: String = "CommonStockSharesOutstanding",
                                    unit: String = "shares", dimensions: [String: String] = [:],
                                    version: String = "synthetic-shares.v1", availability: AvailabilityEvidence? = nil) throws
    -> SECCompanyFactRecord {
    let p = template.provenance
    let factID = "synthetic-share/" + taxonomy + "/" + concept + "/" + unit + "/" + template.endDate.iso8601
    let provenance = Provenance(providerID: p.providerID, feedID: p.feedID, sourceEventAt: p.sourceEventAt,
        receivedAt: p.receivedAt, availableAt: p.availableAt, evidenceRef: p.evidenceRef, origin: p.origin,
        endpointDescriptor: p.endpointDescriptor, requestedAt: p.requestedAt, requestID: p.requestID,
        observationDate: template.endDate, versionID: version, versionKind: .sourceVersion,
        availability: availability ?? p.availability, rawObjectRef: p.rawObjectRef, rawHash: p.rawHash,
        normalizationVersion: p.normalizationVersion, licenseRef: p.licenseRef, attribution: p.attribution)
    return try SECCompanyFactRecord(recordID: factID + "/" + version, factID: factID,
        cik: template.cik, taxonomy: taxonomy, concept: concept, label: "Synthetic actual-share candidate",
        description: "Projection regression only; not a complete share-class review", unit: unit,
        sourceValue: value, value: Money(value), startDate: nil, endDate: template.endDate, periodKind: .instant,
        accessionNumber: template.accessionNumber, form: template.form, filedDate: template.filedDate,
        fiscalYear: template.fiscalYear, fiscalPeriod: template.fiscalPeriod, frame: nil,
        dimensions: dimensions, provenance: provenance)
}

@Suite struct SECValuationSupplementStorageTests {
    @Test func sourceLoadingChecksExactAccountingBindingEvenWhenSameIDResearchIsValid() async throws {
        let (database, store, research, report, draft) = try await secValuationStorageFixture()
        let loaded = try await store.valuationSourceDocument(parentReportID: report.id)
        #expect(loaded.id == research.id && loaded.ticker == research.ticker && loaded.cutoff == research.cutoff)
        #expect(loaded.parentResearchHash == report.parentDocumentHash && loaded.sources == research.sources)
        #expect(loaded.shareCountCandidates.status == .missing && loaded.shareCountCandidates.candidate == nil)
        let original = try #require(database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") })
        let replacement = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: original),
            options: [.prettyPrinted, .sortedKeys])
        #expect(original != replacement)
        // Preserve a semantically valid same-ID document and rebuild its own catalog.
        // Its canonical re-encoding would equal the old object, but the retained bytes
        // no longer match the accounting report's immutable source binding.
        let decoded = try JSONDecoder().decode(SECResearchDocument.self, from: replacement)
        try decoded.validate()
        #expect(decoded.id == research.id && decoded.ticker == report.ticker && decoded.cutoff == report.cutoff)
        try database.transaction { db in
            let fetched = try Data.fetchOne(db, sql: "SELECT summary_json FROM sec_research_catalog")
            let bytes = try #require(fetched)
            var catalog = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            catalog["documentHash"] = digest(replacement)
            let updated = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
            try db.execute(sql: "UPDATE sec_research_documents SET document_json = ?", arguments: [replacement])
            try db.execute(sql: "UPDATE sec_research_catalog SET document_hash = ?, summary_hash = ?, summary_json = ?",
                arguments: [digest(replacement), digest(updated), updated])
        }
        #expect(try await store.open(id: research.id).id == research.id)
        #expect(try await store.savedResearch().map(\.id) == [research.id])
        await #expect(throws: BusinessStoreError.corruptedStorage) {
            try await store.valuationSourceDocument(parentReportID: report.id)
        }
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openFinancialReport(id: report.id) }
        #expect(try await store.reportWriteRevision() == draft.expectedRevision)
    }

    @Test func actualShareCandidatePreservesLatestObservationAndSourceBinding() async throws {
        let research = try await secFinancialReportFixtureParent()
        let latestTemplate = try #require(research.facts.first { $0.endDate.iso8601 == "2024-12-31" })
        let olderTemplate = try #require(research.facts.first { $0.endDate.iso8601 == "2024-09-30" })
        let latest = try shareCountCandidateFact(latestTemplate, value: "120")
        let older = try shareCountCandidateFact(olderTemplate, value: "100")
        let weightedAverage = try shareCountCandidateFact(latestTemplate, value: "9999",
            concept: "WeightedAverageNumberOfDilutedSharesOutstanding")
        let projection = SECShareCountCandidateProjection(cik: research.identity.cik,
            facts: [older, weightedAverage, latest], submissions: research.submissions, cutoff: research.cutoff)
        let candidate = try #require(projection.candidate)
        #expect(projection.status == .available && projection.candidates.count == 1)
        #expect(candidate.outstandingShares == (try Money("120")) && candidate.asOfDate == latest.endDate)
        #expect(candidate.taxonomy == latest.taxonomy && candidate.concept == latest.concept)
        #expect(candidate.accessionNumber == latest.accessionNumber && candidate.filedDate == latest.filedDate)
        #expect(candidate.recordID == latest.recordID && candidate.factID == latest.factID)
        #expect(candidate.sourceReference == latest.provenance.rawObjectRef)
        #expect(candidate.sourceVersion == latest.provenance.versionID && candidate.sourceHash == latest.provenance.rawHash)
        let submission = try #require(research.submissions.first { $0.accessionNumber == latest.accessionNumber })
        #expect(candidate.submissionRecordID == submission.recordID)
        #expect(candidate.submissionSourceReference == submission.provenance.rawObjectRef)
        #expect(candidate.submissionSourceVersion == submission.provenance.versionID)
    }

    @Test func actualShareCandidateUsesExactCutoffForSameMillisecondRevision() async throws {
        let research = try await secFinancialReportFixtureParent()
        let template = try #require(research.facts.first { $0.endDate.iso8601 == "2024-12-31" })
        let base = research.cutoff
        let earlier = try shareCountCandidateFact(template, value: "100", version: "shares-earlier",
            availability: .instant(base.addingTimeInterval(-1), evidence: "synthetic exact availability"))
        let later = try shareCountCandidateFact(template, value: "120", version: "shares-later",
            availability: .instant(base.addingTimeInterval(0.0004), evidence: "synthetic exact availability"))
        let before = SECShareCountCandidateProjection(cik: research.identity.cik, facts: [earlier, later],
            submissions: research.submissions, cutoff: base.addingTimeInterval(0.0002))
        let after = SECShareCountCandidateProjection(cik: research.identity.cik, facts: [later, earlier],
            submissions: research.submissions, cutoff: base.addingTimeInterval(0.0006))
        #expect(before.candidate?.outstandingShares == (try Money("100")))
        #expect(after.candidate?.outstandingShares == (try Money("120")))
        #expect(after.candidate?.availableAt == base.addingTimeInterval(0.0004))
    }

    @Test func actualShareCandidateRejectsCompetingConceptsAndEqualTimeRevisions() async throws {
        let research = try await secFinancialReportFixtureParent()
        let template = try #require(research.facts.first { $0.endDate.iso8601 == "2024-12-31" })
        let gaap = try shareCountCandidateFact(template, value: "120")
        let dei = try shareCountCandidateFact(template, value: "120", taxonomy: "dei",
            concept: "EntityCommonStockSharesOutstanding")
        let revision = try shareCountCandidateFact(template, value: "130", version: "competing-revision")
        for facts in [[gaap, dei], [gaap, revision]] {
            let projection = SECShareCountCandidateProjection(cik: research.identity.cik,
                facts: facts, submissions: research.submissions, cutoff: research.cutoff)
            #expect(projection.status == .conflicting && projection.candidate == nil)
        }
    }

    @Test func actualShareCandidateDoesNotSubstituteWeightedAverageOrOlderUnsupportedCount() async throws {
        let research = try await secFinancialReportFixtureParent()
        let template = try #require(research.facts.first { $0.endDate.iso8601 == "2024-12-31" })
        let olderTemplate = try #require(research.facts.first { $0.endDate.iso8601 == "2024-09-30" })
        let weightedAverage = try shareCountCandidateFact(template, value: "120",
            concept: "WeightedAverageNumberOfDilutedSharesOutstanding")
        let missing = SECShareCountCandidateProjection(cik: research.identity.cik, facts: [weightedAverage],
            submissions: research.submissions, cutoff: research.cutoff)
        #expect(missing.status == .missing && missing.candidate == nil)
        let older = try shareCountCandidateFact(olderTemplate, value: "100")
        let unsupported = try [shareCountCandidateFact(template, value: "120.5"),
            shareCountCandidateFact(template, value: "120", unit: "USD"),
            shareCountCandidateFact(template, value: "120", dimensions: ["class": "A"])]
        for latest in unsupported {
            let projection = SECShareCountCandidateProjection(cik: research.identity.cik, facts: [older, latest],
                submissions: research.submissions, cutoff: research.cutoff)
            #expect(projection.status == .unsupported && projection.candidate == nil)
        }
        let valid = try shareCountCandidateFact(template, value: "120")
        let unbound = SECShareCountCandidateProjection(cik: research.identity.cik, facts: [valid],
            submissions: research.submissions.filter { $0.accessionNumber != valid.accessionNumber }, cutoff: research.cutoff)
        #expect(unbound.status == .unsupported && unbound.candidate == nil)
    }

    @Test func supplementRoundTripRetainsBothParentEncodingsAndReplaysOffline() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let (database, store, research, report, draft) = try await secValuationStorageFixture(path: path.path)
        let researchBytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") })
        let reportBytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") })
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        #expect(try await store.savedValuationSupplements(parentReportID: report.id) == [.init(document: draft.document)])
        #expect(try await store.savedValuationSupplements(parentReportID: UUID()).isEmpty)
        #expect(draft.document.parentFinancialReportHash == digest(reportBytes))
        #expect(draft.document.parentResearchHash == digest(researchBytes))
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == researchBytes)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") } == reportBytes)
        let body = try #require(database.read { try Data.fetchOne($0, sql: "SELECT supplement_json FROM sec_valuation_supplement_documents") })
        for source in research.sources where source.bytes.count > 100 {
            #expect(body.range(of: Data(source.bytes.base64EncodedString().utf8)) == nil)
        }
        let reopened = try SECResearchStore(path: path.path)
        let opened = try await reopened.openValuationSupplement(id: draft.document.id)
        #expect(try ResearchDocument.encoded(opened) == body)
        let pair = try await reopened.openValuationSupplementWithParent(id: draft.document.id)
        #expect(try ResearchDocument.encoded(pair.supplement) == body)
        #expect(try ResearchDocument.encoded(pair.parent) == reportBytes)
        #expect(pair.supplement.parentFinancialReportID == pair.parent.id)
        #expect(pair.supplement.parentFinancialReportHash == digest(reportBytes))
        let replay = try await opened.valuation.recompute()
        #expect(try opened.valuation.cachedReportMatches(replay))
        #expect(!opened.valuation.assessment.historicalPITQualified)
        #expect(!opened.valuation.assessment.productionEligible)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_research_documents") } == 1)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_financial_report_documents") } == 1)
        #expect(throws: MigrationError.incompatiblePurpose) { try DatabaseStore(path: path.path) }
    }

    @Test func originalRevisionAndDuplicateIDCannotBeRetargetedOrOverwrite() async throws {
        let (_, store, _, _, draft) = try await secValuationStorageFixture()
        let next = try valuationStorageCopy(draft.document)
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        let committed = try await store.reportWriteRevision()
        await #expect(throws: SnapshotError.stalePlan) {
            try await store.saveValuationSupplement(next, expectedRevision: draft.expectedRevision)
        }
        await #expect(throws: SnapshotError.duplicateObject) {
            try await store.saveValuationSupplement(draft.document, expectedRevision: committed)
        }
        #expect(try await store.reportWriteRevision() == committed)
        #expect(try await store.savedValuationSupplements().map(\.id) == [draft.document.id])
    }

    @Test func preparationBindsOriginalAccountingEncodingInsteadOfReencoding() async throws {
        let (database, store, research, report, _) = try await secValuationStorageFixture()
        let original = try ResearchDocument.encoded(report)
        let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: original), options: [.prettyPrinted, .sortedKeys])
        #expect(original != pretty)
        // Model another valid retained JSON encoding, including a catalog that was
        // generated from those exact bytes. No accounting field or source is changed.
        try database.transaction { db in
            let fetched = try Data.fetchOne(db, sql: "SELECT summary_json FROM sec_financial_report_catalog")
            let summaryBytes = try #require(fetched)
            var summary = try #require(JSONSerialization.jsonObject(with: summaryBytes) as? [String: Any])
            summary["reportHash"] = digest(pretty)
            let changedSummary = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            try db.execute(sql: "UPDATE sec_financial_report_documents SET report_json = ?", arguments: [pretty])
            try db.execute(sql: "UPDATE sec_financial_report_catalog SET report_hash = ?, summary_hash = ?, summary_json = ?",
                arguments: [digest(pretty), digest(changedSummary), changedSummary])
        }
        let draft = try await store.prepareValuationSupplement(parentReportID: report.id, evidence: .init(),
            executionDate: research.cutoff.addingTimeInterval(2))
        #expect(draft.document.parentFinancialReportHash == digest(pretty))
        #expect(draft.document.parentFinancialReportHash != digest(original))
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        #expect(try await store.openValuationSupplement(id: draft.document.id).parentFinancialReportHash == digest(pretty))
        let pair = try await store.openValuationSupplementWithParent(id: draft.document.id)
        #expect(pair.parent.id == report.id && pair.supplement.parentFinancialReportHash == digest(pretty))
        #expect(try digest(ResearchDocument.encoded(pair.parent)) != pair.supplement.parentFinancialReportHash)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") } == pretty)
    }

    @Test func reviewRequiresExactRetainedSourceBytesBeforeDraftCanBeProduced() async throws {
        let (_, store, research, report, draft) = try await secValuationStorageFixture()
        let source = try #require(research.sources.first { $0.endpoint == .filingDocument })
        let badAnchor = try SECValuationSourceAnchor(sourceReference: source.reference, sourceHash: source.contentHash,
            byteOffset: 0, excerpt: Data("This text is absent from the retained response".utf8))
        let badReview = try SECIndustryReview(applicability: .generalNonFinancial, reviewedAt: report.createdAt,
            rationale: "Synthetic byte-binding regression, not issuer qualification", anchors: [badAnchor])
        await #expect(throws: SECValuationError.sourceMismatch) {
            try await store.prepareValuationSupplement(parentReportID: report.id, evidence: .init(industryReview: badReview),
                executionDate: draft.document.createdAt)
        }
        #expect(try await store.reportWriteRevision() == draft.expectedRevision)
        #expect(try await store.savedValuationSupplements().isEmpty)
        let anchor = try SECValuationSourceAnchor(sourceReference: source.reference, sourceHash: source.contentHash,
            byteOffset: 0, excerpt: source.bytes)
        let review = try SECIndustryReview(applicability: .generalNonFinancial, reviewedAt: report.createdAt,
            rationale: "Synthetic byte-binding regression, not issuer qualification", anchors: [anchor])
        let prepared = try await store.prepareValuationSupplement(parentReportID: report.id, evidence: .init(industryReview: review),
            executionDate: draft.document.createdAt)
        try await store.saveValuationSupplement(prepared.document, expectedRevision: prepared.expectedRevision)
        let reopened = try await store.openValuationSupplement(id: prepared.document.id)
        #expect(reopened.valuation.evidence.industryReview?.anchors == [anchor])
        #expect(!reopened.valuation.assessment.productionEligible)
    }

    @Test func summaryAndSelectedOpenNeverDecodeUnrelatedSupplementBodies() async throws {
        let (database, store, _, _, draft) = try await secValuationStorageFixture()
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        let healthy = try valuationStorageCopy(draft.document)
        try await store.saveValuationSupplement(healthy, expectedRevision: store.reportWriteRevision())
        try database.transaction { db in
            try db.execute(sql: "UPDATE sec_valuation_supplement_documents SET supplement_json = ? WHERE supplement_id = ?",
                arguments: [Data("damaged-unselected-body".utf8), draft.document.id.uuidString.lowercased()])
            for table in ["sec_valuation_supplement_documents", "sec_valuation_supplement_catalog", "sec_financial_report_documents", "sec_research_documents"] {
                for operation in ["UPDATE", "DELETE"] {
                    try db.execute(sql: "CREATE TRIGGER preserve_\(operation)_\(table) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'immutable'); END")
                }
            }
        }
        #expect(try await store.savedValuationSupplements().count == 2)
        #expect(try await store.openValuationSupplement(id: healthy.id).id == healthy.id)
        await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openValuationSupplement(id: draft.document.id) }
        let additional = try valuationStorageCopy(healthy)
        try await store.saveValuationSupplement(additional, expectedRevision: store.reportWriteRevision())
        #expect(try await store.savedValuationSupplements().count == 3)
    }

    @Test func eitherDamagedParentBodyRejectsOpenAndNewSaveWithoutChangingRevision() async throws {
        for table in ["sec_financial_report_documents", "sec_research_documents"] {
            let (database, store, _, _, draft) = try await secValuationStorageFixture()
            try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
            let before = try await store.reportWriteRevision(), additional = try valuationStorageCopy(draft.document)
            try database.transaction { db in
                let column = table == "sec_financial_report_documents" ? "report_json" : "document_json"
                try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [Data("damaged-parent".utf8)])
            }
            #expect(try await store.savedValuationSupplements().count == 1)
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openValuationSupplement(id: draft.document.id) }
            await #expect(throws: BusinessStoreError.corruptedStorage) {
                try await store.openValuationSupplementWithParent(id: draft.document.id)
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) {
                try await store.saveValuationSupplement(additional, expectedRevision: before)
            }
            #expect(try await store.reportWriteRevision() == before)
            #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_catalog") } == 1)
        }
    }

    @Test func bodyInsertFailureRollsBackCatalogAndRevisionThenSameDraftCanRetry() async throws {
        let (database, store, _, _, draft) = try await secValuationStorageFixture()
        try database.transaction { db in
            try db.execute(sql: "CREATE TRIGGER reject_supplement BEFORE INSERT ON sec_valuation_supplement_documents BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        await #expect(throws: (any Error).self) { try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision) }
        #expect(try await store.reportWriteRevision() == draft.expectedRevision)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_catalog") } == 0)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sec_valuation_supplement_documents") } == 0)
        try database.transaction { db in try db.execute(sql: "DROP TRIGGER reject_supplement") }
        try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        #expect(try await store.savedValuationSupplements().count == 1)
    }

    @Test func missingBodyOrChangedSummaryIsReportedWithoutBreakingParentReports() async throws {
        for missingBody in [true, false] {
            let (database, store, _, report, draft) = try await secValuationStorageFixture()
            try await store.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
            try database.transaction { db in
                if missingBody { try db.execute(sql: "DELETE FROM sec_valuation_supplement_documents") }
                else { try db.execute(sql: "UPDATE sec_valuation_supplement_catalog SET summary_hash = ?", arguments: [String(repeating: "a", count: 64)]) }
            }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.savedValuationSupplements() }
            await #expect(throws: BusinessStoreError.corruptedStorage) { try await store.openValuationSupplement(id: draft.document.id) }
            #expect(try await store.savedFinancialReports().map(\.id) == [report.id])
            #expect(try await store.openFinancialReport(id: report.id).id == report.id)
        }
    }

    @Test func v4UpgradePreservesBothParentBytesAndRevisionWithCoveringBodyLookup() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let (database, store, _, report, draft) = try await secValuationStorageFixture(path: path.path)
        let researchBytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") })
        let reportBytes = try #require(database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") })
        try database.transaction { db in
            try db.execute(sql: "DROP TABLE sec_valuation_supplement_documents")
            try db.execute(sql: "DROP TABLE sec_valuation_supplement_catalog")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'sec-research.storage.v4'")
            for table in ["sec_financial_report_documents", "sec_financial_report_catalog", "sec_research_documents", "sec_research_catalog"] {
                for operation in ["UPDATE", "DELETE"] {
                    try db.execute(sql: "CREATE TRIGGER keep_\(operation)_\(table) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'preserve'); END")
                }
            }
        }
        let reopened = try SECResearchStore(path: path.path)
        #expect(try await reopened.reportWriteRevision() == draft.expectedRevision)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT document_json FROM sec_research_documents") } == researchBytes)
        #expect(try database.read { try Data.fetchOne($0, sql: "SELECT report_json FROM sec_financial_report_documents") } == reportBytes)
        #expect(try await reopened.openFinancialReport(id: report.id).id == report.id)
        try await reopened.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        let details = try database.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + SECValuationSupplementStorage.catalogQuery).map { row -> String in row["detail"] }
        }
        #expect(details.contains { $0.contains("COVERING INDEX sqlite_autoindex_sec_valuation_supplement_documents_") })
        #expect(try await store.savedValuationSupplements().count == 1)
    }

    @Test func cancelledAndConcurrentSavesHonorOneStartingRevision() async throws {
        let (database, first, _, _, draft) = try await secValuationStorageFixture()
        let second = try SECResearchStore(database: database)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await first.saveValuationSupplement(draft.document, expectedRevision: draft.expectedRevision)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await first.savedValuationSupplements().isEmpty)
        let competing = try valuationStorageCopy(draft.document)
        func attempt(_ store: SECResearchStore, _ document: SECValuationSupplementDocument) async throws -> Bool {
            do { try await store.saveValuationSupplement(document, expectedRevision: draft.expectedRevision); return true }
            catch SnapshotError.stalePlan { return false }
        }
        async let a = attempt(first, draft.document)
        async let b = attempt(second, competing)
        let results = try await [a, b]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await first.savedValuationSupplements().count == 1)
    }
}
