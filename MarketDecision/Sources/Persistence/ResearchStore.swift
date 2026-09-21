import Foundation
import GRDB
import CoreDomain
import DataContracts
import FundamentalsEngine

public struct WatchlistEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: String { symbol }
    public let symbol: String
    public let targetPrice: Money?
    public let maximumAssignmentPrice: Money?
    public let riskNote: String
    public let revision: UUID
    public init(symbol: String, targetPrice: Money? = nil, maximumAssignmentPrice: Money? = nil, riskNote: String = "", revision: UUID = UUID()) throws {
        guard symbol.range(of: #"^[A-Z][A-Z0-9.-]{0,14}\z"#,options:.regularExpression) != nil,
              targetPrice.map({$0.amount > 0}) ?? true, maximumAssignmentPrice.map({$0.amount > 0}) ?? true,
              riskNote.count <= 500, !riskNote.contains("\0") else { throw ResearchError.invalidDocument }
        self.symbol = symbol; self.targetPrice = targetPrice; self.maximumAssignmentPrice = maximumAssignmentPrice
        self.riskNote = riskNote; self.revision = revision
    }
    func validate() throws { _ = try Self(symbol:symbol,targetPrice:targetPrice,maximumAssignmentPrice:maximumAssignmentPrice,riskNote:riskNote,revision:revision) }
}
public struct SavedResearch: Sendable, Identifiable {
    public var id: String { address.namespace.uuidString + "/" + address.identity.id + "/" + address.identity.version }
    public let address: ObjectAddress
    public let document: ResearchDocument
}
public protocol ResearchStorage: Sendable {
    func savedResearch() async throws -> [SavedResearch]
    func save(_ document: ResearchDocument) async throws
    func watchlist() async throws -> [WatchlistEntry]
    func setWatchlist(_ entry: WatchlistEntry, expectedRevision: UUID?) async throws
    func removeWatchlist(symbol: String, expectedRevision: UUID) async throws
}

public actor ResearchStore: ResearchStorage {
    private let database: DatabaseStore
    private let snapshots: BusinessDataStore
    public init(database: DatabaseStore, snapshots: BusinessDataStore) { self.database = database; self.snapshots = snapshots }
    public func save(_ document: ResearchDocument) async throws {
        try await document.validate()
        try Task.checkCancellation()
        let instant = document.report.executionAt
        let permission = RetentionPermission(mayStore:true,mayBackup:true,evidenceReference:"generated-demo.v1")
        func object(_ role: String, _ kind: FrozenObjectKind, _ bytes: Data) -> FrozenObject {
            FrozenObject(identity:.init(id:document.id.uuidString.lowercased()+"."+role,version:"v1"),kind:kind,
                payload:.string(bytes.base64EncodedString()),references:[],capturedAt:instant,permission:permission,synthetic:true)
        }
        let objects = try [object("document",.result,ResearchDocument.encoded(document)),
            object("sources",.input,document.rawData), object("capital",.input,document.capitalData), object("model",.model,ResearchDocument.encoded(document.model)),
            object("parameters",.parameters,ResearchDocument.encoded(document.parameters)),
            object("mapping",.mapping,ResearchDocument.encoded(document.dictionaryRules))]
        let roles = ["research-document","sources","capital","model","parameters","mapping"]
        let root = SnapshotRoot(identity:.init(id:document.id.uuidString.lowercased(),version:"v1"),kind:.researchRun,
            references:try zip(roles,objects).map { ObjectReference(role:$0,target:$1.identity,contentHash:try $1.contentHash()) })
        let bundle = SnapshotBundle(sourceNamespace:document.id,objects:objects,roots:[root])
        let revision = await snapshots.revision()
        try Task.checkCancellation()
        // A successful commit is final, even if the caller's view disappears immediately after it.
        try await snapshots.freeze(bundle,expectedRevision:revision)
    }
    public func savedResearch() async throws -> [SavedResearch] {
        let records = try await snapshots.researchRecords()
        var result: [SavedResearch] = []
        for record in records {
            try Task.checkCancellation()
            guard Set(record.objects.keys) == Set(["research-document","sources","capital","model","parameters","mapping"]) else {
                throw BusinessStoreError.corruptedStorage
            }
            func bytes(_ role: String, _ kind: FrozenObjectKind) throws -> Data {
                guard let object = record.objects[role], object.kind == kind, object.synthetic,
                      case let .string(text) = object.payload, let bytes = Data(base64Encoded:text) else { throw BusinessStoreError.corruptedStorage }
                return bytes
            }
            let doc = try JSONDecoder().decode(ResearchDocument.self,from:bytes("research-document",.result))
            guard record.address.identity.id == doc.id.uuidString.lowercased(),
                  try bytes("sources",.input) == doc.rawData,
                  try bytes("capital",.input) == doc.capitalData,
                  try bytes("model",.model) == ResearchDocument.encoded(doc.model),
                  try bytes("parameters",.parameters) == ResearchDocument.encoded(doc.parameters),
                  try bytes("mapping",.mapping) == ResearchDocument.encoded(doc.dictionaryRules) else { throw BusinessStoreError.corruptedStorage }
            try await doc.validate()
            result.append(SavedResearch(address:record.address,document:doc))
        }
        return result.sorted { a,b in
            a.document.report.executionAt == b.document.report.executionAt ? a.id < b.id : a.document.report.executionAt > b.document.report.executionAt
        }
    }
    public func watchlist() throws -> [WatchlistEntry] {
        try database.read { db in try Row.fetchAll(db,sql:"SELECT * FROM p1_watchlist ORDER BY symbol").map(Self.decode) }
    }
    private static func decode(_ row: Row) throws -> WatchlistEntry {
        let bytes: Data = row["entry_json"]
        guard digest(bytes) == row["content_hash"] else { throw BusinessStoreError.corruptedStorage }
        let entry = try JSONDecoder().decode(WatchlistEntry.self,from:bytes); try entry.validate()
        guard entry.symbol == row["symbol"], entry.revision.uuidString == row["revision"] else { throw BusinessStoreError.corruptedStorage }
        return entry
    }
    public func setWatchlist(_ entry: WatchlistEntry, expectedRevision: UUID?) throws {
        try entry.validate(); try Task.checkCancellation()
        let bytes = try ResearchDocument.encoded(entry)
        try database.transaction { db in
            let old = try Row.fetchOne(db,sql:"SELECT * FROM p1_watchlist WHERE symbol = ?",arguments:[entry.symbol]).map(Self.decode)
            guard old?.revision == expectedRevision, old?.revision != entry.revision else { throw ResearchError.staleWatchlist }
            try db.execute(sql:"INSERT OR REPLACE INTO p1_watchlist (symbol,revision,content_hash,entry_json) VALUES (?,?,?,?)",
                arguments:[entry.symbol,entry.revision.uuidString,digest(bytes),bytes])
        }
    }
    public func removeWatchlist(symbol: String, expectedRevision: UUID) throws {
        try Task.checkCancellation()
        try database.transaction { db in
            guard let row = try Row.fetchOne(db,sql:"SELECT * FROM p1_watchlist WHERE symbol = ?",arguments:[symbol]),
                  try Self.decode(row).revision == expectedRevision else { throw ResearchError.staleWatchlist }
            try db.execute(sql:"DELETE FROM p1_watchlist WHERE symbol = ?",arguments:[symbol])
        }
    }
}
