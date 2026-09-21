import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

struct ArchiveObject: Sendable, Codable {
    let address: ObjectAddress, origin: ObjectAddress
    let object: FrozenObject
    let targets: [String:ObjectAddress]
}
struct ArchiveRoot: Sendable, Codable {
    let address: ObjectAddress, origin: ObjectAddress
    let root: SnapshotRoot
    let targets: [String:ObjectAddress]
}
struct ResearchArchiveState: Sendable, Codable {
    let format: String
    let objects: [ArchiveObject]
    let roots: [ArchiveRoot]
    let watchlist: [WatchlistEntry]
    let conflicts: [WatchlistEntry]
    init(graph: SnapshotGraph, watchlist: [WatchlistEntry], conflicts: [WatchlistEntry]) {
        format = "research-state.v1"
        objects = graph.objects.map { ArchiveObject(address:$0.key,origin:$0.value.source,object:$0.value.object,targets:$0.value.targets) }.sorted { key($0.address) < key($1.address) }
        roots = graph.roots.map { ArchiveRoot(address:$0.key,origin:$0.value.source,root:$0.value.root,targets:$0.value.targets) }.sorted { key($0.address) < key($1.address) }
        self.watchlist = watchlist.sorted { $0.symbol < $1.symbol }
        self.conflicts = conflicts.sorted { ($0.symbol,$0.revision.uuidString,$0.riskNote,$0.targetPrice?.decimalString ?? "",$0.maximumAssignmentPrice?.decimalString ?? "") < ($1.symbol,$1.revision.uuidString,$1.riskNote,$1.targetPrice?.decimalString ?? "",$1.maximumAssignmentPrice?.decimalString ?? "") }
    }
    func graph() throws -> SnapshotGraph {
        guard format == "research-state.v1", objects.count + roots.count + watchlist.count + conflicts.count <= 100_000,
              Set(objects.map(\.address)).count == objects.count, Set(roots.map(\.address)).count == roots.count,
              Set(watchlist.map(\.symbol)).count == watchlist.count else { throw SnapshotError.unsupportedFormat }
        let graph = SnapshotGraph(objects:Dictionary(uniqueKeysWithValues:objects.map { ($0.address,PersistedObject(object:$0.object,source:$0.origin,targets:$0.targets)) }),
            roots:Dictionary(uniqueKeysWithValues:roots.map { ($0.address,PersistedRoot(root:$0.root,source:$0.origin,targets:$0.targets)) }))
        try BusinessDataStore.validate(graph)
        for entry in watchlist + conflicts { try entry.validate() }
        guard try Set(conflicts.map { digest(try ResearchDocument.encoded($0)) }).count == conflicts.count else { throw SnapshotError.unsupportedFormat }
        for item in objects {
            // v1 includes exactly the six leaf objects owned by synthetic research runs.
            guard item.object.synthetic, item.object.permission.mayStore, item.object.permission.mayBackup,
                  item.object.references.isEmpty, item.targets.isEmpty,
                  item.origin.identity == item.address.identity else { throw SnapshotError.retentionDenied }
        }
        var referenced = Set<ObjectAddress>()
        for item in roots {
            guard item.root.kind == .researchRun, item.origin.identity == item.address.identity else { throw SnapshotError.unsupportedFormat }
            for reference in item.root.references {
                guard item.targets[reference.role]?.identity == reference.target else { throw SnapshotError.missingReference }
            }
            referenced.formUnion(item.targets.values)
        }
        guard referenced == Set(graph.objects.keys) else { throw SnapshotError.missingReference }
        return graph
    }
    func validate() async throws {
        let graph = try graph()
        _ = try await ResearchStore.decodeRecords(graph.roots.map { address, item in
            StoredResearchRecord(address:address,objects:item.targets.mapValues { graph.objects[$0]!.object })
        })
    }
}
private func key(_ address: ObjectAddress) -> String { address.namespace.uuidString+"/"+address.identity.id+"/"+address.identity.version }
private struct ArchiveManifest: Codable {
    let format: String, schema: String, scope: String, application: String
    let file: String, sha256: String
    let size: Int
    let objects: Int, roots: Int, watchlist: Int, conflicts: Int
}
public enum ResearchArchiveCodec {
    static func encode(_ state: ResearchArchiveState) throws -> Data {
        let bytes = try ResearchDocument.encoded(state)
        let manifest = ArchiveManifest(format:"research-backup.v1",schema:"business.p1.v6",scope:"synthetic-research-and-watchlist",application:"MarketDecision",
            file:"research-state.json",sha256:digest(bytes),size:bytes.count,objects:state.objects.count,roots:state.roots.count,watchlist:state.watchlist.count,conflicts:state.conflicts.count)
        return try ResearchZIP.encode(["manifest.json":ResearchDocument.encoded(manifest),"research-state.json":bytes])
    }
    static func decode(_ data: Data) async throws -> ResearchArchiveState {
        let files = try ResearchZIP.decode(data), manifest = try JSONDecoder().decode(ArchiveManifest.self,from:files["manifest.json"]!)
        let bytes = files["research-state.json"]!
        guard manifest.format == "research-backup.v1", manifest.schema == "business.p1.v6",
              manifest.scope == "synthetic-research-and-watchlist", manifest.application == "MarketDecision",
              manifest.file == "research-state.json" else { throw SnapshotError.unsupportedFormat }
        guard manifest.size == bytes.count, manifest.sha256 == digest(bytes) else { throw SnapshotError.hashMismatch }
        let state = try JSONDecoder().decode(ResearchArchiveState.self,from:bytes)
        guard state.objects.count == manifest.objects, state.roots.count == manifest.roots,
              state.watchlist.count == manifest.watchlist, state.conflicts.count == manifest.conflicts else { throw SnapshotError.hashMismatch }
        try await state.validate(); return state
    }
}
public struct WatchlistConflict: Sendable, Identifiable {
    public let id: String
    public let entry: WatchlistEntry
}
public enum ResearchTransferOperation: String, Sendable { case merge, replace, clearBusiness }
public struct ResearchTransferPlan: Sendable, Identifiable {
    public let id: UUID
    public let digest: String
    public let operation: ResearchTransferOperation
    public let details: [String]
    public let researchCount: Int, watchlistCount: Int, conflictCount: Int
}
public protocol ResearchTransferStorage: Sendable {
    func exportBackup() async throws -> Data
    func prepare(_ data: Data, mode: RestoreMode) async throws -> ResearchTransferPlan
    func prepareClear() async throws -> ResearchTransferPlan
    func commit(_ approval: PlanApproval) async throws
    func cancel(_ id: UUID) async
    func conflicts() async throws -> [WatchlistConflict]
}
public actor ResearchTransferStore: ResearchTransferStorage {
    private let database: DatabaseStore
    private struct Candidate {
        let plan: ResearchTransferPlan
        let revision: UUID
        let state: ResearchArchiveState?
    }
    private var plans: [UUID:Candidate] = [:]
    public init(database: DatabaseStore) { self.database = database }
    static func readConflicts(_ db: Database) throws -> [WatchlistEntry] {
        try Row.fetchAll(db,sql:"SELECT * FROM p1_watchlist_conflicts ORDER BY content_hash").map { row in
            let data: Data = row["entry_json"]
            guard digest(data) == row["content_hash"] else { throw BusinessStoreError.corruptedStorage }
            let entry = try JSONDecoder().decode(WatchlistEntry.self,from:data); try entry.validate(); return entry
        }
    }
    private static func state(_ db: Database) throws -> ResearchArchiveState {
        ResearchArchiveState(graph:try BusinessDataStore.loadGraph(db),watchlist:try Row.fetchAll(db,sql:"SELECT * FROM p1_watchlist").map(ResearchStore.decode),conflicts:try readConflicts(db))
    }
    public func conflicts() throws -> [WatchlistConflict] {
        try database.read(Self.readConflicts).map { .init(id:digest(try ResearchDocument.encoded($0)),entry:$0) }
    }
    public func exportBackup() async throws -> Data {
        let frozen = try database.read(Self.state)
        try await frozen.validate(); try Task.checkCancellation()
        return try ResearchArchiveCodec.encode(frozen)
    }
    public func prepare(_ data: Data, mode: RestoreMode) async throws -> ResearchTransferPlan {
        let incoming = try await ResearchArchiveCodec.decode(data)
        try Task.checkCancellation()
        let (current, revision) = try database.read { db in
            (try Self.state(db), try Self.revision(db))
        }
        try await current.validate(); try Task.checkCancellation()
        let next: ResearchArchiveState
        var details = ["范围：冻结合成研究、自选目标及冲突副本；源缓存不在恢复范围内。", "API Key 不导入、不删除；恢复不会连接供应商。"]
        if mode == .replace {
            next = ResearchArchiveState(graph:try incoming.graph(),watchlist:try incoming.watchlist.map(Self.freshEntry),conflicts:incoming.conflicts)
            details.append("覆盖当前 \(current.roots.count) 份研究、\(current.watchlist.count) 条自选、\(current.conflicts.count) 份冲突；仅保留包内记录。")
            details += current.roots.map { "将移除当前研究：" + key($0.address) }
            details += current.watchlist.map { "将替换自选："+$0.symbol }
        } else {
            let graph = try Self.merge(incoming, into:current.graph())
            var entries = Dictionary(uniqueKeysWithValues:current.watchlist.map { ($0.symbol,$0) })
            var alternatives = current.conflicts
            for entry in incoming.watchlist {
                if let existing = entries[entry.symbol] {
                    if !Self.sameValues(existing,entry) {
                        alternatives.append(entry); details.append("自选冲突保留两份："+entry.symbol)
                    }
                } else { entries[entry.symbol] = try Self.freshEntry(entry); details.append("新增自选："+entry.symbol) }
            }
            alternatives += incoming.conflicts
            var seen = Set<String>()
            alternatives = try alternatives.filter { seen.insert(digest(try ResearchDocument.encoded($0))).inserted }
            next = ResearchArchiveState(graph:graph,watchlist:Array(entries.values),conflicts:alternatives)
        }
        details += incoming.roots.map { "导入研究："+key($0.address) }
        details.append("导入的可编辑自选将获得新版本；恢复前的旧草稿不能覆盖恢复结果。")
        details.append("提交后：\(next.roots.count) 份研究、\(next.watchlist.count) 条自选、\(next.conflicts.count) 份冲突副本。")
        try await next.validate(); try Task.checkCancellation()
        return try retain(state:next,revision:revision,operation:mode == .merge ? .merge:.replace,details:details)
    }
    // Restored mutable entries receive a fresh edit token. A backup must not revive an old draft.
    private static func freshEntry(_ entry: WatchlistEntry) throws -> WatchlistEntry {
        try .init(symbol:entry.symbol,targetPrice:entry.targetPrice,maximumAssignmentPrice:entry.maximumAssignmentPrice,riskNote:entry.riskNote)
    }
    private static func sameValues(_ a: WatchlistEntry, _ b: WatchlistEntry) -> Bool {
        a.symbol == b.symbol && a.targetPrice == b.targetPrice && a.maximumAssignmentPrice == b.maximumAssignmentPrice && a.riskNote == b.riskNote
    }
    // All addresses are mapped first; frozen object/root bytes are never rewritten.
    private static func merge(_ incoming: ResearchArchiveState, into current: SnapshotGraph) throws -> SnapshotGraph {
        var graph = current, mapping: [ObjectAddress:ObjectAddress] = [:]
        let namespaceMap = Dictionary(uniqueKeysWithValues:Set(incoming.objects.map { $0.address.namespace } + incoming.roots.map { $0.address.namespace }).map { ($0,UUID()) })
        for item in incoming.objects {
            let hash = try item.object.contentHash()
            let match = try graph.objects.keys.sorted { key($0)<key($1) }.first { address in
                let old = graph.objects[address]!
                let oldHash = try old.object.contentHash()
                return (old.source == item.origin || address == item.address) && oldHash == hash
            }
            mapping[item.address] = match ?? ObjectAddress(namespace:namespaceMap[item.address.namespace]!,identity:item.address.identity)
        }
        for item in incoming.objects {
            let address = mapping[item.address]!
            if graph.objects[address] == nil { graph.objects[address] = .init(object:item.object,source:item.origin,targets:item.targets.mapValues { mapping[$0]! }) }
        }
        for item in incoming.roots {
            let hash = try item.root.contentHash(), targets = item.targets.mapValues { mapping[$0]! }
            let match = try graph.roots.contains { address, old in
                let oldHash = try old.root.contentHash()
                return (old.source == item.origin || address == item.address) && oldHash == hash && old.targets == targets
            }
            if !match {
                let address = ObjectAddress(namespace:namespaceMap[item.address.namespace]!,identity:item.address.identity)
                graph.roots[address] = .init(root:item.root,source:item.origin,targets:targets)
            }
        }
        try BusinessDataStore.validate(graph); return graph
    }
    private static func revision(_ db: Database) throws -> UUID {
        guard let text = try String.fetchOne(db,sql:"SELECT revision FROM p1_store_metadata WHERE singleton = 1"),let value = UUID(uuidString:text) else { throw BusinessStoreError.corruptedStorage }; return value
    }
    // Cache tables are intentionally excluded from ordinary research backup/replace,
    // but explicit clear-business removes every current business table in FK order.
    static let clearTables = ["p1_normalized_financial_facts","p1_financial_normalization_runs","p1_financial_dictionaries",
        "p1_sec_identity_listings","p1_sec_identities","p1_sec_filing_documents","p1_sec_filing_indexes","p1_sec_submissions","p1_sec_facts",
        "p1_equity_pages","p1_equity_records","p1_market_sessions","p1_company_events","p1_observations","p1_source_documents",
        "p1_snapshot_root_edges","p1_snapshot_object_edges","p1_snapshot_roots","p1_snapshot_objects","p1_watchlist_conflicts","p1_watchlist"]
    public func prepareClear() throws -> ResearchTransferPlan {
        try Task.checkCancellation()
        let (revision, details) = try database.read { db in
            let tables = try String.fetchAll(db,sql:"SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'p1_%'")
            guard Set(tables) == Set(Self.clearTables + ["p1_store_metadata"]) else { throw SnapshotError.unsupportedFormat }
            let groups: [(String,[String])] = [
                ("研究快照",["p1_snapshot_roots"]), ("冻结内容",["p1_snapshot_objects"]),
                ("自选目标",["p1_watchlist"]), ("冲突副本",["p1_watchlist_conflicts"]),
                ("源文档缓存",["p1_source_documents"]), ("行情与观察缓存",["p1_equity_pages","p1_equity_records","p1_observations"]),
                ("日历与事件",["p1_market_sessions","p1_company_events"]),
                ("财报与归一化数据",["p1_normalized_financial_facts","p1_financial_normalization_runs","p1_financial_dictionaries","p1_sec_identity_listings","p1_sec_identities","p1_sec_filing_documents","p1_sec_filing_indexes","p1_sec_submissions","p1_sec_facts"])]
            let counts = try groups.map { name, tables in
                let count = try tables.reduce(0) { try $0 + Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($1)")! }
                return "\(name)：\(count) 条"
            }
            return (try Self.revision(db), counts)
        }
        return try retain(state:nil,revision:revision,operation:.clearBusiness,details:["清空本机全部业务记录与源缓存；不删除 Keychain 或外部备份文件。不承诺 SSD 物理擦除。"]+details)
    }
    private func retain(state: ResearchArchiveState?, revision: UUID, operation: ResearchTransferOperation, details: [String]) throws -> ResearchTransferPlan {
        guard plans.count < 16 else { throw SnapshotError.resourceLimit }
        let id = UUID(), content = try state.map(ResearchDocument.encoded) ?? Data()
        let bytes = Data((id.uuidString+revision.uuidString+operation.rawValue+details.joined(separator:"\n")).utf8)+content
        let plan = ResearchTransferPlan(id:id,digest:digest(bytes),operation:operation,details:details,
            researchCount:state?.roots.count ?? 0,watchlistCount:state?.watchlist.count ?? 0,conflictCount:state?.conflicts.count ?? 0)
        plans[id] = .init(plan:plan,revision:revision,state:state); return plan
    }
    public func commit(_ approval: PlanApproval) throws {
        guard let candidate = plans[approval.planID] else { throw SnapshotError.unknownPlan }
        guard approval.digest == candidate.plan.digest else { throw SnapshotError.approvalMismatch }
        try Task.checkCancellation()
        do {
            try database.transaction { db in
                try BusinessDataStore.checkRevision(candidate.revision,db:db)
                if let state = candidate.state {
                    try BusinessDataStore.save(state.graph(),revision:UUID(),db:db)
                    try db.execute(sql:"DELETE FROM p1_watchlist"); try db.execute(sql:"DELETE FROM p1_watchlist_conflicts")
                    for entry in state.watchlist {
                        let bytes = try ResearchDocument.encoded(entry)
                        try db.execute(sql:"INSERT INTO p1_watchlist VALUES (?,?,?,?)",arguments:[entry.symbol,entry.revision.uuidString,digest(bytes),bytes])
                    }
                    for entry in state.conflicts {
                        let bytes = try ResearchDocument.encoded(entry)
                        try db.execute(sql:"INSERT OR IGNORE INTO p1_watchlist_conflicts VALUES (?,?)",arguments:[digest(bytes),bytes])
                    }
                } else {
                    for table in Self.clearTables { try db.execute(sql:"DELETE FROM \(table)") }
                    try BusinessDataStore.writeRevision(UUID(),db:db)
                }
                try Task.checkCancellation()
            }
        } catch {
            if error as? SnapshotError == .stalePlan { plans.removeValue(forKey:approval.planID) }
            throw error
        }
        plans.removeValue(forKey:approval.planID)
    }
    public func cancel(_ id: UUID) { plans.removeValue(forKey:id) }
}
