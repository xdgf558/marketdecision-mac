import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

struct SECArchiveRestoreCandidate: Sendable {
    let plan: SECArchiveRestorePlan
    let incoming: SECArchiveValidatedState
    let targetSignature: String
}

private struct SECArchiveInventory: Sendable {
    let research: [String]
    let reports: [String]
    let supplements: [String]
    func signature() throws -> String {
        // Replace deliberately inventories damaged IDs without decoding old bodies.
        // Array boundaries must therefore remain unambiguous even for arbitrary text.
        digest(try ResearchDocument.encoded([research, reports, supplements]))
    }
}

private struct SECArchiveMergeState {
    let inventory: SECArchiveInventory
    let signature: String
}

/// Carry cancellation across GRDB's serial dispatch; the callback has no Swift task context.
private final class SECArchiveWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

extension SECResearchStore: SECArchiveStorage {
    public func exportArchive(researchID: UUID, consent: SECLocalArchiveConsent) async throws -> Data {
        try Task.checkCancellation()
        _ = try writeRevision()
        let state = try database.read { db in
            _ = try Self.revision(db)
            try Self.rejectOrphanArchiveBodies(db)
            // Selection follows validated catalogs. Check every small metadata envelope
            // so a changed parent column cannot silently hide a selected child. This is
            // not an audit of unrelated bodies against completely reconstructed catalogs.
            _ = try SECResearchStorage.summaries(db)
            _ = try SECFinancialReportStorage.summaries(parentID: nil, db: db)
            _ = try SECValuationSupplementStorage.summaries(parentReportID: nil, db: db)
            let summaries = try SECFinancialReportStorage.summaries(parentID: researchID, db: db)
            guard summaries.count <= SECResearchArchiveCodec.maximumReports else { throw SnapshotError.resourceLimit }
            // Either link makes a supplement part of this family. A malformed second
            // link must fail validation, rather than silently excluding that supplement.
            let supplementIDs = try String.fetchAll(db, sql: """
                SELECT supplement_id FROM sec_valuation_supplement_catalog
                WHERE parent_research_id = ? OR parent_report_id IN
                    (SELECT report_id FROM sec_financial_report_catalog WHERE parent_document_id = ?)
                ORDER BY supplement_id
                """, arguments: [researchID.uuidString.lowercased(), researchID.uuidString.lowercased()])
            guard supplementIDs.count <= SECResearchArchiveCodec.maximumSupplements else { throw SnapshotError.resourceLimit }
            // Check the whole selected family's small count/length inventory before
            // loading any document body. These are payload limits, not an RSS promise.
            var remaining = SECResearchArchiveCodec.maximumRawBytes
            for summary in summaries {
                let size = try Int.fetchOne(db, sql: "SELECT length(report_json) FROM sec_financial_report_documents WHERE report_id = ?", arguments: [summary.id.uuidString.lowercased()])
                try Self.reserveArchiveChild(size, remaining: &remaining)
            }
            for text in supplementIDs {
                let size = try Int.fetchOne(db, sql: "SELECT length(supplement_json) FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [text])
                try Self.reserveArchiveChild(size, remaining: &remaining)
            }
            try Self.validateArchiveResearchSize(researchID, remaining: remaining, db: db)
            let research = try SECResearchStorage.validatedRecord(id: researchID, db: db)
            guard research.bytes.count <= remaining else { throw SnapshotError.resourceLimit }
            let reports = try summaries.map { try SECFinancialReportStorage.validatedRecord(id: $0.id, db: db).bytes }
            let supplements = try supplementIDs.map { text -> Data in
                guard let id = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
                _ = try SECValuationSupplementStorage.open(id: id, db: db)
                guard let bytes = try Data.fetchOne(db, sql: "SELECT supplement_json FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [text])
                else { throw BusinessStoreError.corruptedStorage }
                return bytes
            }
            return SECArchiveState(research: research.bytes, reports: reports, supplements: supplements)
        }
        try Task.checkCancellation()
        // The codec enforces the separate consent and denies an entire selected family
        // containing captured-price evidence. Existing frozen permissions are not edited.
        return try SECResearchArchiveCodec.encode(state, consent: consent)
    }

    public func cancelArchiveRestore(_ id: UUID) { archiveCandidates.removeValue(forKey: id) }

    private static func reserveArchiveChild(_ size: Int?, remaining: inout Int) throws {
        guard let size else { throw BusinessStoreError.corruptedStorage }
        guard size > 0, size <= SECResearchArchiveCodec.maximumChildBytes, size <= remaining else { throw SnapshotError.resourceLimit }
        remaining -= size
    }

    private static func validateArchiveResearchSize(_ id: UUID, remaining: Int, db: Database) throws {
        guard remaining > 0 else { throw SnapshotError.resourceLimit }
        let key = id.uuidString.lowercased()
        if let size = try Int.fetchOne(db, sql: "SELECT length(document_json) FROM sec_research_documents WHERE document_id = ?", arguments: [key]) {
            guard size > 0, size <= remaining else { throw SnapshotError.resourceLimit }
            return
        }
        // A legacy envelope stores the source encoding as base64. Bound both encodings
        // before reading them; its exact decoded size is checked against the shared
        // budget immediately after full frozen-object validation.
        let legacyLimit = remaining * 2 + 16 * 1_024
        guard let row = try Row.fetchOne(db, sql: "SELECT length(object_json) AS object_size, length(content) AS content_size FROM p1_snapshot_objects WHERE namespace = ?", arguments: [key])
        else { throw SnapshotError.missingReference }
        let objectSize: Int = row["object_size"], contentSize: Int = row["content_size"]
        guard objectSize > 0, contentSize > 0, objectSize <= legacyLimit, contentSize <= legacyLimit
        else { throw SnapshotError.resourceLimit }
    }

    public func prepareArchiveRestore(_ bytes: Data, mode: RestoreMode,
                                      consent: SECLocalArchiveConsent) async throws -> SECArchiveRestorePlan {
        try Task.checkCancellation()
        // A decoded real issuer can be large. A second window must cancel/finish the
        // existing preview before retaining another complete package in this store.
        guard archiveCandidates.isEmpty else { throw SnapshotError.resourceLimit }
        let incoming = try SECResearchArchiveCodec.decode(bytes, consent: consent)
        let target = try database.read { db -> (UUID, SECArchiveInventory, String) in
            let revision = try Self.revision(db)
            if mode == .merge {
                let checked = try Self.mergeState(incoming, db: db)
                return (revision, checked.inventory, checked.signature)
            }
            let inventory = try Self.archiveInventory(db)
            return (revision, inventory, try inventory.signature())
        }
        try Task.checkCancellation()
        let current = target.1
        let identicalResearch = mode == .merge && current.research.contains(incoming.research.document.id.uuidString.lowercased()) ? 1 : 0
        let identicalReports = mode == .merge ? incoming.reports.filter { current.reports.contains($0.document.id.uuidString.lowercased()) }.count : 0
        let identicalSupplements = mode == .merge ? incoming.supplements.filter { current.supplements.contains($0.document.id.uuidString.lowercased()) }.count : 0
        var details = ["本包包含 1 份 SEC 研究、\(incoming.reports.count) 份财务报告、\(incoming.supplements.count) 份无行情估值补充。",
                       "来源原字节随研究保留；恢复不会访问网络、读取凭据或恢复独立行情缓存。"]
        if mode == .replace {
            details.append("替换当前全部 \(current.research.count) 份 SEC 研究、\(current.reports.count) 份财务报告、\(current.supplements.count) 份估值补充；包括其中损坏的记录。")
        } else {
            details.append("保留当前 \(current.research.count) 份研究、\(current.reports.count) 份财务报告、\(current.supplements.count) 份补充；新增 \(1 - identicalResearch) 份研究、\(incoming.reports.count - identicalReports) 份报告、\(incoming.supplements.count - identicalSupplements) 份补充。")
            details.append("相同标识且原字节相同的 \(identicalResearch + identicalReports + identicalSupplements) 份记录保持原样；不同内容同标识不会覆盖。")
        }
        details.append("原 SEC 来源与解析缓存保留；其他工作区不变。恢复后需要显式重算，缓存结果不自动成为可信展示。")
        let id = UUID()
        let binding = try ResearchDocument.encoded([id.uuidString, target.0.uuidString, mode.rawValue,
            consent.rawValue, digest(bytes), target.2] + details)
        let plan = SECArchiveRestorePlan(id: id, digest: digest(binding), baseRevision: target.0, mode: mode,
            details: details, researchCount: 1, reportCount: incoming.reports.count,
            supplementCount: incoming.supplements.count, removedResearchCount: mode == .replace ? current.research.count : 0)
        archiveCandidates[id] = .init(plan: plan, incoming: incoming, targetSignature: target.2)
        return plan
    }

    public func commitArchiveRestore(_ approval: PlanApproval) async throws {
        guard let candidate = archiveCandidates[approval.planID] else { throw SnapshotError.unknownPlan }
        guard approval.digest == candidate.plan.digest else { throw SnapshotError.approvalMismatch }
        try Task.checkCancellation()
        let cancellation = SECArchiveWriteCancellation()
        do {
            try await withTaskCancellationHandler {
                try cancellation.check()
                try database.transaction { db in
                    try cancellation.check()
                    let revision = try Self.revision(db)
                    guard revision == candidate.plan.baseRevision else { throw SnapshotError.stalePlan }
                    let current: SECArchiveInventory
                    if candidate.plan.mode == .merge {
                        let checked = try Self.mergeState(candidate.incoming, db: db)
                        guard checked.signature == candidate.targetSignature else { throw SnapshotError.stalePlan }
                        current = checked.inventory
                    } else {
                        let checked = try Self.archiveInventory(db)
                        guard try checked.signature() == candidate.targetSignature else { throw SnapshotError.stalePlan }
                        for table in Self.archiveReplacementTables {
                            try cancellation.check()
                            try db.execute(sql: "DELETE FROM " + table)
                        }
                        current = .init(research: [], reports: [], supplements: [])
                    }
                    try cancellation.check()
                    let incoming = candidate.incoming
                    if current.research.contains(incoming.research.document.id.uuidString.lowercased()) {
                        try SECResearchStorage.ensureCatalog(document: incoming.research.document, bytes: incoming.research.bytes, db: db)
                    } else {
                        try SECResearchStorage.insert(incoming.research.document, bytes: incoming.research.bytes, db: db)
                    }
                    for report in incoming.reports where !current.reports.contains(report.document.id.uuidString.lowercased()) {
                        try cancellation.check()
                        try SECFinancialReportStorage.insert(report.document, bytes: report.bytes, db: db)
                    }
                    for supplement in incoming.supplements where !current.supplements.contains(supplement.document.id.uuidString.lowercased()) {
                        try cancellation.check()
                        try SECValuationSupplementStorage.insert(supplement.document, bytes: supplement.bytes, db: db)
                    }
                    try cancellation.check()
                    // Even an identical merge is an explicitly committed restore. A new
                    // revision prevents pre-restore report drafts/imports from writing late.
                    try BusinessDataStore.writeRevision(UUID(), db: db)
                    try cancellation.check()
                }
            } onCancel: { cancellation.cancel() }
        } catch {
            if error as? SnapshotError == .stalePlan { archiveCandidates.removeValue(forKey: approval.planID) }
            // Transaction failures leave the exact reviewed plan available for retry.
            throw error
        }
        archiveCandidates.removeValue(forKey: approval.planID)
    }

    /// A metadata-only inventory deliberately includes orphan bodies/legacy namespaces.
    /// Replace can repair them without decoding the bytes that are about to be removed.
    private static func archiveInventory(_ db: Database) throws -> SECArchiveInventory {
        let research = try String.fetchAll(db, sql: """
            SELECT document_id AS id FROM sec_research_catalog
            UNION SELECT document_id FROM sec_research_documents INDEXED BY sec_research_document_ids
            UNION SELECT namespace FROM p1_snapshot_roots
            UNION SELECT namespace FROM p1_snapshot_objects INDEXED BY sec_research_legacy_object_metadata
            UNION SELECT namespace FROM p1_snapshot_root_edges
            UNION SELECT namespace FROM p1_snapshot_object_edges ORDER BY id
            """)
        let reports = try String.fetchAll(db, sql: """
            SELECT report_id AS id FROM sec_financial_report_catalog
            UNION SELECT report_id FROM sec_financial_report_documents ORDER BY id
            """)
        let supplements = try String.fetchAll(db, sql: """
            SELECT supplement_id AS id FROM sec_valuation_supplement_catalog
            UNION SELECT supplement_id FROM sec_valuation_supplement_documents ORDER BY id
            """)
        return .init(research: research, reports: reports, supplements: supplements)
    }

    private static func rejectOrphanArchiveBodies(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: SECResearchStorage.catalogShapeQuery) == 0,
              try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sec_financial_report_documents d WHERE NOT EXISTS
                    (SELECT 1 FROM sec_financial_report_catalog c WHERE c.report_id = d.report_id)
                """) == 0,
              try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sec_valuation_supplement_documents d WHERE NOT EXISTS
                    (SELECT 1 FROM sec_valuation_supplement_catalog c WHERE c.supplement_id = d.supplement_id)
                """) == 0 else { throw BusinessStoreError.corruptedStorage }
    }

    /// Validate retained content with its original contracts, not the archive's consent
    /// scope. A legitimate existing captured-price supplement may remain during merge.
    private static func mergeState(_ incoming: SECArchiveValidatedState, db: Database) throws -> SECArchiveMergeState {
        try rejectOrphanArchiveBodies(db)
        let inventory = try archiveInventory(db)
        _ = try SECResearchStorage.summaries(db)
        _ = try SECFinancialReportStorage.summaries(parentID: nil, db: db)
        _ = try SECValuationSupplementStorage.summaries(parentReportID: nil, db: db)
        var hashes: [String] = []
        let incomingKinds = Dictionary(uniqueKeysWithValues: [(incoming.research.document.id, "research")]
            + incoming.reports.map { ($0.document.id, "report") }
            + incoming.supplements.map { ($0.document.id, "supplement") })
        let reports = Dictionary(uniqueKeysWithValues: incoming.reports.map { ($0.document.id, $0.bytes) })
        let supplements = Dictionary(uniqueKeysWithValues: incoming.supplements.map { ($0.document.id, $0.bytes) })
        for text in inventory.research {
            guard let id = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
            if let kind = incomingKinds[id], kind != "research" { throw SECArchiveError.identifierConflict }
            let retained = try SECResearchStorage.validatedRecord(id: id, db: db)
            if id == incoming.research.document.id, retained.bytes != incoming.research.bytes { throw SECArchiveError.identifierConflict }
            hashes.append("research/" + text + "/" + digest(retained.bytes))
        }
        for text in inventory.reports {
            guard let id = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
            if let kind = incomingKinds[id], kind != "report" { throw SECArchiveError.identifierConflict }
            let retained = try SECFinancialReportStorage.validatedRecord(id: id, db: db)
            if let bytes = reports[id], bytes != retained.bytes { throw SECArchiveError.identifierConflict }
            hashes.append("report/" + text + "/" + digest(retained.bytes))
        }
        for text in inventory.supplements {
            guard let id = UUID(uuidString: text) else { throw BusinessStoreError.corruptedStorage }
            if let kind = incomingKinds[id], kind != "supplement" { throw SECArchiveError.identifierConflict }
            _ = try SECValuationSupplementStorage.open(id: id, db: db)
            guard let retained = try Data.fetchOne(db, sql: "SELECT supplement_json FROM sec_valuation_supplement_documents WHERE supplement_id = ?", arguments: [text])
            else { throw BusinessStoreError.corruptedStorage }
            if let bytes = supplements[id], bytes != retained { throw SECArchiveError.identifierConflict }
            hashes.append("supplement/" + text + "/" + digest(retained))
        }
        return .init(inventory: inventory, signature: digest(try ResearchDocument.encoded(hashes)))
    }

    private static let archiveReplacementTables = [
        "sec_valuation_supplement_documents", "sec_valuation_supplement_catalog",
        "sec_financial_report_documents", "sec_financial_report_catalog",
        "sec_research_documents", "sec_research_catalog", "p1_snapshot_root_edges",
        "p1_snapshot_object_edges", "p1_snapshot_roots", "p1_snapshot_objects",
    ]
}
