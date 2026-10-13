import Foundation
import GRDB
import CoreDomain
import PortfolioEngine

public enum LedgerStoreError: Error, Equatable, Sendable {
    case incompatiblePurpose, corruptedStorage, stalePlan, invalidPlan, missingAccount, duplicateAccount, injectedFailure
}
public enum LedgerImportDisposition: String, Sendable, Equatable {
    case new, duplicate, conflict, invalid, excluded
}
public struct LedgerImportRow: Sendable, Equatable, Identifiable {
    public var id: Int { rowIndex }
    public let rowIndex: Int
    public let event: LedgerEvent?
    public let disposition: LedgerImportDisposition
    public let message: String
    public init(rowIndex: Int, event: LedgerEvent?, disposition: LedgerImportDisposition, message: String) {
        self.rowIndex = rowIndex; self.event = event; self.disposition = disposition; self.message = message
    }
}
public struct LedgerImportPreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let targetRevision: UUID
    public let sourceHash: String
    public let rows: [LedgerImportRow]
    public let projectedState: LedgerState?
    public let validationMessage: String?
    public var canCommit: Bool {
        projectedState != nil && validationMessage == nil && rows.contains { $0.disposition != .excluded }
        && rows.allSatisfy { [.new, .duplicate, .excluded].contains($0.disposition) }
    }
    public init(id: UUID, targetRevision: UUID, sourceHash: String, rows: [LedgerImportRow], projectedState: LedgerState?, validationMessage: String?) {
        self.id = id; self.targetRevision = targetRevision; self.sourceHash = sourceHash; self.rows = rows
        self.projectedState = projectedState; self.validationMessage = validationMessage
    }
}
public struct LedgerSnapshot: Sendable, Equatable {
    public let revision: UUID
    public let accounts: [LedgerAccount]
    /// Append order is retained for correction audit; calculation sorts active economic events.
    public let events: [LedgerEvent]
    public let state: LedgerState
    public let batches: [LedgerBatchSummary]
    public init(revision: UUID, accounts: [LedgerAccount], events: [LedgerEvent], state: LedgerState, batches: [LedgerBatchSummary] = []) {
        self.revision = revision; self.accounts = accounts; self.events = events; self.state = state
        self.batches = batches
    }
}
public struct LedgerBatchSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceHash: String
    public let newEventIDs: [String]
    public let excludedRowCount: Int
    public let duplicateRowCount: Int
    public init(id:String,sourceHash:String,newEventIDs:[String],excludedRowCount:Int,duplicateRowCount:Int) {
        self.id = id; self.sourceHash = sourceHash; self.newEventIDs = newEventIDs
        self.excludedRowCount = excludedRowCount; self.duplicateRowCount = duplicateRowCount
    }
}
public protocol LedgerStorage: Sendable {
    func snapshot() async throws -> LedgerSnapshot
    func createAccount(_ account: LedgerAccount, expectedRevision: UUID) async throws -> LedgerSnapshot
    func previewCSV(data: Data, accountID: String, sourceSystem: String, mapping: LedgerCSVMapping,
                    excludedRows: Set<Int>, expectedRevision: UUID) async throws -> LedgerImportPreview
    func previewManual(events: [LedgerEvent], expectedRevision: UUID) async throws -> LedgerImportPreview
    func previewCorrection(originalEventID: String, replacement: LedgerEvent, reason: String,
                           expectedRevision: UUID) async throws -> LedgerImportPreview
    func previewBatchReversal(batchID: String, effectiveAt: Date, reason: String,
                              expectedRevision: UUID) async throws -> LedgerImportPreview
    func commit(planID: UUID, expectedRevision: UUID) async throws -> LedgerSnapshot
    func cancel(planID: UUID) async
}

/// Append-only ledger in a dedicated SQLite file. All entry points verify the
/// same raw-source, index and event contracts; dedup never trusts a narrow index.
public actor LedgerStore: LedgerStorage {
    private let database: DatabaseStore
    private var plans: [UUID: Plan] = [:]
    private var failNextCommit = false
    public init(database: DatabaseStore) throws {
        guard database.purpose == .portfolioLedger else { throw LedgerStoreError.incompatiblePurpose }
        self.database = database
    }
    public init(path: String) throws { database = try DatabaseStore(path:path,purpose:.portfolioLedger) }
    public func snapshot() throws -> LedgerSnapshot { try database.read(Self.load) }
    public func createAccount(_ account: LedgerAccount, expectedRevision: UUID) throws -> LedgerSnapshot {
        try account.validate(); try Task.checkCancellation()
        return try database.transaction { db in
            let current = try Self.load(db); guard current.revision == expectedRevision else { throw LedgerStoreError.stalePlan }
            guard !current.accounts.contains(where: { $0.id == account.id }) else { throw LedgerStoreError.duplicateAccount }
            let data = try Self.encode(account)
            try db.execute(sql: "INSERT INTO ledger_accounts(account_id,currency,content_hash,account_json) VALUES (?,?,?,?)",
                           arguments: [account.id,account.currency,LedgerCSV.hash(data),data])
            try Self.writeRevision(UUID(),db); return try Self.load(db)
        }
    }
    public func previewCSV(data: Data, accountID: String, sourceSystem: String, mapping: LedgerCSVMapping,
                           excludedRows: Set<Int> = [], expectedRevision: UUID) throws -> LedgerImportPreview {
        try Task.checkCancellation()
        let table = try LedgerCSV.parse(data); try mapping.validate(headers: table.headers)
        guard excludedRows.allSatisfy({ $0 > 0 && $0 <= table.rows.count }) else { throw LedgerStoreError.invalidPlan }
        let source = Source(metadata: .init(kind: .csv, rawHash: table.fileHash, accountID: accountID,
            sourceSystem: sourceSystem, mapping: mapping, excludedRows: excludedRows.sorted()), bytes: data)
        return try preview(source: source, expectedRevision: expectedRevision)
    }
    public func previewManual(events: [LedgerEvent], expectedRevision: UUID) throws -> LedgerImportPreview {
        try Task.checkCancellation()
        guard !events.isEmpty, events.count <= LedgerCSV.maximumRows else { throw LedgerStoreError.invalidPlan }
        let data = try Self.encode(events)
        guard data.count <= LedgerCSV.maximumBytes else { throw LedgerCSVError.budgetExceeded }
        let source = Source(metadata: .init(kind: .manual, rawHash: LedgerCSV.hash(data), accountID: nil,
            sourceSystem: nil, mapping: nil, excludedRows: []), bytes: data)
        return try preview(source: source, expectedRevision: expectedRevision)
    }

    /// Corrections append a distinct reversal and replacement. Replay rejects any
    /// surviving downstream dependency that no longer has a valid lot/contract.
    public func previewCorrection(originalEventID: String, replacement: LedgerEvent, reason: String,
                                  expectedRevision: UUID) throws -> LedgerImportPreview {
        let current = try snapshot(); guard current.revision == expectedRevision else { throw LedgerStoreError.stalePlan }
        guard let original = current.events.first(where: { $0.id == originalEventID }),
              original.accountID == replacement.accountID, replacement.id != original.id else { throw LedgerStoreError.invalidPlan }
        let id = "correction-" + UUID().uuidString.lowercased()
        // Audit time is the actual correction preparation time. The replacement's
        // economic timestamp remains exactly the user's corrected timestamp.
        let reversal = LedgerEvent(id:id,accountID:original.accountID,effectiveAt:Date(),
            source:.init(sourceSystem:"manual-correction",externalTransactionID:id,evidence:reason),
            payload:.reversal(.init(originalEventID:original.id,reason:reason)))
        return try previewManual(events:[reversal,replacement],expectedRevision:expectedRevision)
    }
    public func previewBatchReversal(batchID:String,effectiveAt:Date,reason:String,expectedRevision:UUID) throws -> LedgerImportPreview {
        let current = try snapshot(); guard current.revision == expectedRevision else { throw LedgerStoreError.stalePlan }
        guard let batch = current.batches.first(where: { $0.id == batchID }),!batch.newEventIDs.isEmpty else { throw LedgerStoreError.invalidPlan }
        let reversals = try batch.newEventIDs.reversed().map { eventID in
            guard let original = current.events.first(where: { $0.id == eventID }) else { throw LedgerStoreError.corruptedStorage }
            let id = "batch-reversal-" + UUID().uuidString.lowercased()
            return LedgerEvent(id:id,accountID:original.accountID,effectiveAt:effectiveAt,
                source:.init(sourceSystem:"manual-batch-reversal",externalTransactionID:id,evidence:reason),
                payload:.reversal(.init(originalEventID:original.id,reason:reason)))
        }
        return try previewManual(events:reversals,expectedRevision:expectedRevision)
    }
    public func cancel(planID: UUID) { plans.removeValue(forKey: planID) }
    // Same plan may retry an ordinary failed transaction. Stale plans are consumed.
    public func commit(planID: UUID, expectedRevision: UUID) throws -> LedgerSnapshot {
        guard let plan = plans[planID], plan.preview.targetRevision == expectedRevision, plan.preview.canCommit else { throw LedgerStoreError.invalidPlan }
        try Task.checkCancellation()
        let injected = failNextCommit; failNextCommit = false
        do {
            let result = try database.transaction { db in
                let current = try Self.load(db)
                guard current.revision == expectedRevision else { throw LedgerStoreError.stalePlan }
                let candidates = try Self.candidates(source:plan.source)
                let fresh = try Self.classify(candidates, current:current)
                guard fresh.rows == plan.preview.rows, fresh.message == nil, fresh.state == plan.preview.projectedState else { throw LedgerStoreError.invalidPlan }
                let newEvents = fresh.rows.filter { $0.disposition == .new }.compactMap(\.event)
                let sourceID = try plan.source.id()
                let sourceExists = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ledger_sources WHERE source_id = ?)",arguments:[sourceID]) ?? false
                if sourceExists && newEvents.isEmpty { return current }
                if !sourceExists { try Self.saveSource(plan.source,db) }
                let batch = Batch(id:plan.preview.id.uuidString.lowercased(),sourceID:sourceID,appendBaseCount:current.events.count,
                                  rows:fresh.rows.map { BatchRow(rowIndex:$0.rowIndex,eventID:$0.event?.id,disposition:$0.disposition.rawValue) })
                let bytes = try Self.encode(batch)
                try db.execute(sql:"INSERT INTO ledger_batches(batch_id,source_id,content_hash,batch_json) VALUES (?,?,?,?)",
                               arguments:[batch.id,sourceID,LedgerCSV.hash(bytes),bytes])
                var sequence = current.events.count
                for row in fresh.rows where row.disposition == .new {
                    try Task.checkCancellation()
                    guard let event = row.event else { throw LedgerStoreError.invalidPlan }
                    let bytes = try Self.encode(event)
                    sequence += 1
                    try db.execute(sql:"""
                        INSERT INTO ledger_events(event_id,account_id,identity_key,audit_sequence,effective_at_json,source_id,source_row,batch_id,content_hash,comparison_hash,event_json)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        """,arguments:[event.id,event.accountID,try event.idempotencyKey,sequence,try Self.encode(event.effectiveAt),
                                       sourceID,row.rowIndex,batch.id,LedgerCSV.hash(bytes),try Self.comparisonHash(event),bytes])
                }
                if injected { throw LedgerStoreError.injectedFailure }
                try Task.checkCancellation(); try Self.writeRevision(UUID(),db)
                return try Self.load(db)
            }
            plans.removeValue(forKey:planID); return result
        } catch LedgerStoreError.stalePlan {
            plans.removeValue(forKey:planID); throw LedgerStoreError.stalePlan
        }
    }
    func injectFailureOnNextCommit() { failNextCommit = true }

    private func preview(source: Source, expectedRevision: UUID) throws -> LedgerImportPreview {
        try Task.checkCancellation()
        let current = try snapshot(); guard current.revision == expectedRevision else { throw LedgerStoreError.stalePlan }
        if let id = source.metadata.accountID, !current.accounts.contains(where: { $0.id == id }) { throw LedgerStoreError.missingAccount }
        let classified = try Self.classify(Self.candidates(source:source),current:current)
        let preview = LedgerImportPreview(id:UUID(),targetRevision:expectedRevision,sourceHash:source.metadata.rawHash,
            rows:classified.rows,projectedState:classified.state,validationMessage:classified.message)
        // Bounded pending plans, released explicitly or on stale/success. No disk approval token.
        guard plans.count < 16 else { throw LedgerStoreError.invalidPlan }
        plans[preview.id] = Plan(preview:preview,source:source); return preview
    }

    private struct Plan: Sendable { let preview: LedgerImportPreview; let source: Source }
    private enum SourceKind: String, Codable, Sendable { case csv, manual }
    private struct SourceMetadata: Codable, Equatable, Sendable {
        let kind: SourceKind
        let rawHash: String
        let accountID: String?
        let sourceSystem: String?
        let mapping: LedgerCSVMapping?
        let excludedRows: [Int]
        let mappingVersion: String
        let normalizationVersion: String
        let engineVersion: String
        let parametersVersion: String
        let numericPolicyVersion: String
        init(kind:SourceKind,rawHash:String,accountID:String?,sourceSystem:String?,mapping:LedgerCSVMapping?,excludedRows:[Int]) {
            self.kind = kind; self.rawHash = rawHash; self.accountID = accountID; self.sourceSystem = sourceSystem
            self.mapping = mapping; self.excludedRows = excludedRows; mappingVersion = LedgerCSVMapping.version
            normalizationVersion = LedgerCSVMapping.normalizationVersion
            engineVersion = LedgerEngine.version; parametersVersion = "PARAMETERS_V1"; numericPolicyVersion = Money.numericPolicyVersion
        }
    }
    private struct Source: Sendable {
        let metadata: SourceMetadata
        let bytes: Data
        func id() throws -> String { LedgerCSV.hash(try LedgerStore.encode(metadata)) }
    }
    private struct BatchRow: Codable, Equatable { let rowIndex: Int; let eventID: String?; let disposition: String }
    private struct Batch: Codable, Equatable { let id: String; let sourceID: String; let appendBaseCount: Int; let rows: [BatchRow] }

    private static func encode<T: Encodable>(_ value:T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func comparisonHash(_ event: LedgerEvent) throws -> String {
        // Same broker ID in another file is allowed only for the identical economic
        // event. The retained original source stays bound to the first accepted row.
        let source = event.source.externalTransactionID == nil ? event.source : LedgerSource(
            sourceSystem:event.source.sourceSystem,externalTransactionID:event.source.externalTransactionID,evidence:event.source.evidence)
        return LedgerCSV.hash(try encode(LedgerEvent(id:event.id,accountID:event.accountID,effectiveAt:event.effectiveAt,
            providerSequence:event.providerSequence,source:source,payload:event.payload,rollGroupID:event.rollGroupID,
            multiLegGroupID:event.multiLegGroupID,notes:event.notes)))
    }
    private static func candidates(source:Source) throws -> [LedgerImportRow] {
        guard LedgerCSV.hash(source.bytes) == source.metadata.rawHash,
              source.metadata.mappingVersion == LedgerCSVMapping.version,
              source.metadata.normalizationVersion == LedgerCSVMapping.normalizationVersion,
              source.metadata.engineVersion == LedgerEngine.version, source.metadata.parametersVersion == "PARAMETERS_V1",
              source.metadata.numericPolicyVersion == Money.numericPolicyVersion,
              source.bytes.count <= LedgerCSV.maximumBytes else { throw LedgerStoreError.corruptedStorage }
        switch source.metadata.kind {
        case .manual:
            guard source.metadata.mapping == nil, source.metadata.accountID == nil, source.metadata.sourceSystem == nil,
                  source.metadata.excludedRows.isEmpty else { throw LedgerStoreError.corruptedStorage }
            let events = try JSONDecoder().decode([LedgerEvent].self,from:source.bytes)
            guard !events.isEmpty, events.count <= LedgerCSV.maximumRows else { throw LedgerStoreError.invalidPlan }
            return events.enumerated().map { index,event in
                do { try event.validate(); return LedgerImportRow(rowIndex:index + 1,event:event,disposition:.new,message:"待写入") }
                catch { return LedgerImportRow(rowIndex:index + 1,event:nil,disposition:.invalid,message:"事件字段或证据无效") }
            }
        case .csv:
            guard let account = source.metadata.accountID, let system = source.metadata.sourceSystem,
                  let mapping = source.metadata.mapping else { throw LedgerStoreError.corruptedStorage }
            let table = try LedgerCSV.parse(source.bytes); try mapping.validate(headers:table.headers)
            let excluded = Set(source.metadata.excludedRows)
            guard excluded.count == source.metadata.excludedRows.count,
                  excluded.allSatisfy({ $0 > 0 && $0 <= table.rows.count }) else { throw LedgerStoreError.corruptedStorage }
            return try table.rows.indices.map { offset in
                try Task.checkCancellation()
                let index = offset + 1
                if excluded.contains(index) { return LedgerImportRow(rowIndex:index,event:nil,disposition:.excluded,message:"用户明确排除；原始行保留") }
                do {
                    let event = try LedgerCSV.event(table:table,rowIndex:index,accountID:account,sourceSystem:system,mapping:mapping)
                    return LedgerImportRow(rowIndex:index,event:event,disposition:.new,message:"待写入")
                } catch LedgerError.missingFee { return LedgerImportRow(rowIndex:index,event:nil,disposition:.invalid,message:"缺实际费用，不能按零处理") }
                catch { return LedgerImportRow(rowIndex:index,event:nil,disposition:.invalid,message:"日期、金额、映射或事件证据无效") }
            }
        }
    }
    private static func classify(_ rows:[LedgerImportRow],current:LedgerSnapshot) throws -> (rows:[LedgerImportRow],state:LedgerState?,message:String?) {
        var known: [String:LedgerEvent] = [:]
        for event in current.events { known[try event.idempotencyKey] = event }
        var ids = Set(current.events.map(\.id)), additions:[LedgerEvent] = [], result:[LedgerImportRow] = []
        for row in rows {
            guard row.disposition == .new, let event = row.event else { result.append(row); continue }
            let key = try event.idempotencyKey
            if let old = known[key] {
                let equal = try comparisonHash(old) == comparisonHash(event)
                result.append(.init(rowIndex:row.rowIndex,event:event,disposition:equal ? .duplicate:.conflict,
                    message:equal ? "同一来源交易已存在":"相同交易身份内容不同，需明确排除此行或修正来源"))
            } else if ids.contains(event.id) {
                result.append(.init(rowIndex:row.rowIndex,event:event,disposition:.conflict,message:"事件标识已由另一笔交易使用"))
            } else {
                known[key] = event; ids.insert(event.id); additions.append(event); result.append(row)
            }
        }
        guard result.allSatisfy({ [.new,.duplicate,.excluded].contains($0.disposition) }) else { return (result,nil,"存在未解决行；不会写入部分批次") }
        do { return (result,try LedgerEngine.replay(accounts:current.accounts,events:current.events + additions),nil) }
        catch { return (result,nil,"整批对账失败：请核对账户、持仓批次、费用、事件顺序或交割证据") }
    }
    private static func revision(_ db:Database) throws -> UUID {
        guard let text = try String.fetchOne(db,sql:"SELECT revision FROM ledger_metadata WHERE singleton = 1"),let revision = UUID(uuidString:text),revision.uuidString == text else { throw LedgerStoreError.corruptedStorage }
        return revision
    }
    private static func writeRevision(_ value:UUID,_ db:Database) throws {
        try db.execute(sql:"UPDATE ledger_metadata SET revision = ? WHERE singleton = 1",arguments:[value.uuidString])
        guard db.changesCount == 1 else { throw LedgerStoreError.corruptedStorage }
    }
    private static func saveSource(_ source:Source,_ db:Database) throws {
        let metadata = try encode(source.metadata)
        try db.execute(sql:"INSERT INTO ledger_sources(source_id,raw_hash,metadata_hash,metadata_json,raw_bytes) VALUES (?,?,?,?,?)",
                       arguments:[try source.id(),source.metadata.rawHash,LedgerCSV.hash(metadata),metadata,source.bytes])
    }
    private static func load(_ db:Database) throws -> LedgerSnapshot {
        do { return try checkedLoad(db) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LedgerStoreError.corruptedStorage }
    }
    private static func checkedLoad(_ db:Database) throws -> LedgerSnapshot {
        let revision = try revision(db)
        let accounts = try Row.fetchAll(db,sql:"SELECT * FROM ledger_accounts ORDER BY account_id").map { row in
            let bytes:Data = row["account_json"]
            guard LedgerCSV.hash(bytes) == row["content_hash"] else { throw LedgerStoreError.corruptedStorage }
            let account = try JSONDecoder().decode(LedgerAccount.self,from:bytes); try account.validate()
            guard account.id == row["account_id"],account.currency == row["currency"] else { throw LedgerStoreError.corruptedStorage }
            return account
        }
        var sources:[String:[LedgerImportRow]] = [:], sourceHashes:[String:String] = [:]
        for row in try Row.fetchAll(db,sql:"SELECT * FROM ledger_sources") {
            try Task.checkCancellation()
            let bytes:Data = row["raw_bytes"], metadataBytes:Data = row["metadata_json"]
            guard LedgerCSV.hash(metadataBytes) == row["metadata_hash"] else { throw LedgerStoreError.corruptedStorage }
            let metadata = try JSONDecoder().decode(SourceMetadata.self,from:metadataBytes)
            let source = Source(metadata:metadata,bytes:bytes), id = try source.id()
            guard id == row["source_id"],metadata.rawHash == row["raw_hash"] else { throw LedgerStoreError.corruptedStorage }
            sources[id] = try candidates(source:source)
            sourceHashes[id] = source.metadata.rawHash
        }
        var batches:[String:Batch] = [:]
        let batchRows = try Row.fetchAll(db,sql:"SELECT * FROM ledger_batches ORDER BY batch_id")
        for row in batchRows {
            let bytes:Data = row["batch_json"]
            guard LedgerCSV.hash(bytes) == row["content_hash"] else { throw LedgerStoreError.corruptedStorage }
            let batch = try JSONDecoder().decode(Batch.self,from:bytes)
            guard batch.id == row["batch_id"],batch.sourceID == row["source_id"],let source = sources[batch.sourceID],
                  batch.appendBaseCount >= 0,batch.rows.count == source.count,
                  Set(batch.rows.map(\.rowIndex)).count == batch.rows.count else { throw LedgerStoreError.corruptedStorage }
            for item in batch.rows {
                guard let sourceRow = source.first(where: { $0.rowIndex == item.rowIndex }),sourceRow.event?.id == item.eventID,
                      let disposition = LedgerImportDisposition(rawValue:item.disposition),
                      [.new,.duplicate,.excluded].contains(disposition) else { throw LedgerStoreError.corruptedStorage }
                if item.disposition == LedgerImportDisposition.excluded.rawValue {
                    guard sourceRow.disposition == .excluded else { throw LedgerStoreError.corruptedStorage }
                }
            }
            batches[batch.id] = batch
        }
        var events:[LedgerEvent] = []
        var eventBindings:[String:(batchID:String,rowIndex:Int,sequence:Int)] = [:]
        for row in try Row.fetchAll(db,sql:"SELECT * FROM ledger_events ORDER BY audit_sequence") {
            try Task.checkCancellation()
            let bytes:Data = row["event_json"]
            guard LedgerCSV.hash(bytes) == row["content_hash"] else { throw LedgerStoreError.corruptedStorage }
            let event = try JSONDecoder().decode(LedgerEvent.self,from:bytes); try event.validate()
            let sourceID:String = row["source_id"],sourceRow:Int = row["source_row"],batchID:String = row["batch_id"]
            guard event.id == row["event_id"],event.accountID == row["account_id"],
                  try event.idempotencyKey == row["identity_key"], try encode(event.effectiveAt) == row["effective_at_json"],
                  try comparisonHash(event) == row["comparison_hash"],
                  let candidates = sources[sourceID],let candidate = candidates.first(where: { $0.rowIndex == sourceRow }),
                  candidate.event == event,candidate.disposition == .new,
                  let batch = batches[batchID],batch.sourceID == sourceID,
                  let offset = batch.rows.filter({ $0.disposition == LedgerImportDisposition.new.rawValue }).firstIndex(of:
                    .init(rowIndex:sourceRow,eventID:event.id,disposition:LedgerImportDisposition.new.rawValue)),
                  batch.appendBaseCount + offset + 1 == row["audit_sequence"],events.count + 1 == row["audit_sequence"] else { throw LedgerStoreError.corruptedStorage }
            events.append(event)
            eventBindings[event.id] = (batchID,sourceRow,row["audit_sequence"])
        }
        // Every batch NEW entry must have its row, even if an external SQLite writer
        // deleted the row while leaving a still-valid source and batch hash.
        for batch in batches.values { for row in batch.rows where row.disposition == LedgerImportDisposition.new.rawValue {
            guard let id = row.eventID,let binding = eventBindings[id],binding.batchID == batch.id,
                  binding.rowIndex == row.rowIndex else { throw LedgerStoreError.corruptedStorage }
        } }
        for batch in batches.values {
            guard let source = sources[batch.sourceID] else { throw LedgerStoreError.corruptedStorage }
            for row in batch.rows where row.disposition == LedgerImportDisposition.duplicate.rawValue {
                guard let candidate = source.first(where: { $0.rowIndex == row.rowIndex })?.event,
                      let original = events.first(where: { $0.id == candidate.id }),
                      let binding = eventBindings[original.id],
                      binding.sequence <= batch.appendBaseCount || (binding.batchID == batch.id && binding.rowIndex < row.rowIndex),
                      try comparisonHash(original) == comparisonHash(candidate) else { throw LedgerStoreError.corruptedStorage }
            }
        }
        let summaries = try batches.values.sorted { $0.id < $1.id }.map { batch in
            guard let hash = sourceHashes[batch.sourceID] else { throw LedgerStoreError.corruptedStorage }
            return LedgerBatchSummary(id:batch.id,sourceHash:hash,newEventIDs:batch.rows.filter { $0.disposition == LedgerImportDisposition.new.rawValue }.compactMap(\.eventID),
                excludedRowCount:batch.rows.filter { $0.disposition == LedgerImportDisposition.excluded.rawValue }.count,
                duplicateRowCount:batch.rows.filter { $0.disposition == LedgerImportDisposition.duplicate.rawValue }.count)
        }
        return LedgerSnapshot(revision:revision,accounts:accounts,events:events,state:try LedgerEngine.replay(accounts:accounts,events:events),batches:summaries)
    }
}
