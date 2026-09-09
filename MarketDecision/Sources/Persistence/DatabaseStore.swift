import Foundation
import GRDB

/// Phase 0 has no business tables. Migration history is owned by GRDB.
public struct DatabaseStore: Sendable {
    private let queue: DatabaseQueue
    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("foundation.v1") { _ in }
        try migrator.migrate(queue)
    }
    public func migrationVersions() throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
    }
}
