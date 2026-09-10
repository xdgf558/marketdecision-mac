import Foundation
import GRDB

public enum MigrationError: Error, Equatable { case invalidCatalog, unsupportedHistory }
public struct DatabaseMigration: Sendable {
    public let identifier: String
    let migrate: @Sendable (Database) throws -> Void
    public init(identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
        self.identifier = identifier; self.migrate = migrate
    }
}

/// Phase 0 has no business tables. Each migration is transactional; earlier successful
/// migrations remain committed. No erase-on-schema-change or guessed compatibility.
public struct DatabaseStore: Sendable {
    private let queue: DatabaseQueue
    public init(path: String, migrations: [DatabaseMigration] = []) throws {
        let ids = ["foundation.v1"] + migrations.map(\.identifier)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw MigrationError.invalidCatalog
        }
        queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("foundation.v1") { _ in }
        for migration in migrations { migrator.registerMigration(migration.identifier, migrate: migration.migrate) }
        let catalog = migrator
        let applied = try queue.read { try catalog.appliedIdentifiers($0) }
        guard applied == Set(ids.prefix(applied.count)) else { throw MigrationError.unsupportedHistory }
        try migrator.migrate(queue)
    }
    public func migrationVersions() throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
    }
    /// One database transaction; throws rolls back all statements in the closure.
    public func transaction<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }
    public func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
}
