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

/// Each migration is transactional; earlier successful migrations remain committed.
/// No erase-on-schema-change or guessed compatibility.
public struct DatabaseStore: Sendable {
    private let queue: DatabaseQueue
    public init(path: String, migrations: [DatabaseMigration] = []) throws {
        let coreMigrations = [Self.phase1BusinessMigration]
        let ids = ["foundation.v1"] + coreMigrations.map(\.identifier) + migrations.map(\.identifier)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw MigrationError.invalidCatalog
        }
        queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("foundation.v1") { _ in }
        for migration in coreMigrations { migrator.registerMigration(migration.identifier, migrate: migration.migrate) }
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

    private static let phase1BusinessMigration = DatabaseMigration(identifier: "business.p1.v1") { db in
        try db.execute(sql: """
            CREATE TABLE p1_store_metadata (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                revision TEXT NOT NULL
            )
            """)
        try db.execute(sql: "INSERT INTO p1_store_metadata (singleton, revision) VALUES (1, '00000000-0000-0000-0000-000000000000')")
        try db.execute(sql: """
            CREATE TABLE p1_source_documents (
                reference TEXT PRIMARY KEY NOT NULL,
                metadata_hash TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                feed_id TEXT NOT NULL,
                endpoint_descriptor TEXT NOT NULL,
                received_at_ms INTEGER NOT NULL,
                available_at_ms INTEGER NOT NULL,
                media_type TEXT NOT NULL,
                evidence_ref TEXT NOT NULL,
                license_ref TEXT NOT NULL,
                payload BLOB NOT NULL,
                CHECK (length(content_hash) = 64),
                CHECK (length(metadata_hash) = 64)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE p1_observations (
                series_id TEXT NOT NULL,
                record_id TEXT NOT NULL,
                version_id TEXT NOT NULL,
                observation_date TEXT NOT NULL,
                available_at_ms INTEGER NOT NULL,
                state TEXT NOT NULL,
                unit TEXT NOT NULL,
                currency TEXT,
                raw_value TEXT,
                canonical_value TEXT,
                numeric_policy_ref TEXT NOT NULL,
                source_reference TEXT NOT NULL,
                record_hash TEXT NOT NULL,
                record_json BLOB NOT NULL,
                PRIMARY KEY (series_id, record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_observations_asof ON p1_observations (series_id, observation_date, available_at_ms, record_id)")
        try db.execute(sql: """
            CREATE TABLE p1_snapshot_objects (
                namespace TEXT NOT NULL,
                object_id TEXT NOT NULL,
                object_version TEXT NOT NULL,
                source_namespace TEXT NOT NULL,
                source_object_id TEXT NOT NULL,
                source_object_version TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                object_json BLOB NOT NULL,
                content BLOB NOT NULL,
                PRIMARY KEY (namespace, object_id, object_version),
                CHECK (length(content_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE p1_snapshot_object_edges (
                namespace TEXT NOT NULL,
                object_id TEXT NOT NULL,
                object_version TEXT NOT NULL,
                role TEXT NOT NULL,
                target_namespace TEXT NOT NULL,
                target_id TEXT NOT NULL,
                target_version TEXT NOT NULL,
                PRIMARY KEY (namespace, object_id, object_version, role),
                FOREIGN KEY (namespace, object_id, object_version)
                    REFERENCES p1_snapshot_objects(namespace, object_id, object_version) ON DELETE CASCADE,
                FOREIGN KEY (target_namespace, target_id, target_version)
                    REFERENCES p1_snapshot_objects(namespace, object_id, object_version) ON DELETE RESTRICT
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE p1_snapshot_roots (
                namespace TEXT NOT NULL,
                root_id TEXT NOT NULL,
                root_version TEXT NOT NULL,
                source_namespace TEXT NOT NULL,
                source_root_id TEXT NOT NULL,
                source_root_version TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                root_json BLOB NOT NULL,
                PRIMARY KEY (namespace, root_id, root_version),
                CHECK (length(content_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE p1_snapshot_root_edges (
                namespace TEXT NOT NULL,
                root_id TEXT NOT NULL,
                root_version TEXT NOT NULL,
                role TEXT NOT NULL,
                target_namespace TEXT NOT NULL,
                target_id TEXT NOT NULL,
                target_version TEXT NOT NULL,
                PRIMARY KEY (namespace, root_id, root_version, role),
                FOREIGN KEY (namespace, root_id, root_version)
                    REFERENCES p1_snapshot_roots(namespace, root_id, root_version) ON DELETE CASCADE,
                FOREIGN KEY (target_namespace, target_id, target_version)
                    REFERENCES p1_snapshot_objects(namespace, object_id, object_version) ON DELETE RESTRICT
            ) WITHOUT ROWID
            """)
    }
}
