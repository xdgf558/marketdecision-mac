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
        let coreMigrations = [Self.phase1BusinessMigration, Self.phase1CalendarMigration, Self.phase1SECMigration]
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

    private static let phase1CalendarMigration = DatabaseMigration(identifier: "business.p1.v2") { db in
        try db.execute(sql: """
            CREATE TABLE p1_market_sessions (
                market TEXT NOT NULL,
                session_date TEXT NOT NULL,
                record_id TEXT NOT NULL,
                version_id TEXT NOT NULL,
                available_at_ms INTEGER NOT NULL,
                state TEXT NOT NULL,
                opens_at_ms INTEGER,
                closes_at_ms INTEGER,
                source_reference TEXT NOT NULL,
                record_hash TEXT NOT NULL,
                record_json BLOB NOT NULL,
                PRIMARY KEY (market, session_date, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_market_sessions_asof ON p1_market_sessions (market, session_date, available_at_ms)")
        try db.execute(sql: """
            CREATE TABLE p1_company_events (
                record_id TEXT NOT NULL,
                version_id TEXT NOT NULL,
                symbol TEXT NOT NULL,
                kind TEXT NOT NULL,
                event_date TEXT,
                availability_known INTEGER NOT NULL CHECK (availability_known IN (0, 1)),
                available_at_ms INTEGER,
                source_reference TEXT NOT NULL,
                record_hash TEXT NOT NULL,
                record_json BLOB NOT NULL,
                PRIMARY KEY (record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(record_hash) = 64),
                CHECK ((availability_known = 0 AND available_at_ms IS NULL) OR
                       (availability_known = 1 AND available_at_ms IS NOT NULL))
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_company_events_lookup ON p1_company_events (symbol, kind, event_date, availability_known, available_at_ms)")
    }

    private static let phase1SECMigration = DatabaseMigration(identifier: "business.p1.v3") { db in
        try db.execute(sql: """
            CREATE TABLE p1_sec_identities (
                record_id TEXT NOT NULL, version_id TEXT NOT NULL, cik TEXT NOT NULL,
                available_at_ms INTEGER NOT NULL, source_reference TEXT NOT NULL,
                record_hash TEXT NOT NULL, record_json BLOB NOT NULL,
                PRIMARY KEY (record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(cik) = 10), CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_sec_identities_cik ON p1_sec_identities (cik, available_at_ms)")
        try db.execute(sql: """
            CREATE TABLE p1_sec_identity_listings (
                record_id TEXT NOT NULL, version_id TEXT NOT NULL, ticker TEXT NOT NULL, exchange TEXT NOT NULL,
                PRIMARY KEY (record_id, version_id, ticker, exchange),
                FOREIGN KEY (record_id, version_id) REFERENCES p1_sec_identities(record_id, version_id) ON DELETE CASCADE
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_sec_identity_listings_ticker ON p1_sec_identity_listings (ticker, record_id, version_id)")
        try db.execute(sql: """
            CREATE TABLE p1_sec_submissions (
                record_id TEXT NOT NULL, version_id TEXT NOT NULL, cik TEXT NOT NULL,
                accession_number TEXT NOT NULL, filing_date TEXT NOT NULL, accepted_at_ms INTEGER,
                available_at_ms INTEGER NOT NULL, source_reference TEXT NOT NULL,
                record_hash TEXT NOT NULL, record_json BLOB NOT NULL,
                PRIMARY KEY (record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(cik) = 10), CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_sec_submissions_cik ON p1_sec_submissions (cik, filing_date, available_at_ms)")
        try db.execute(sql: """
            CREATE TABLE p1_sec_filing_indexes (
                record_id TEXT NOT NULL, version_id TEXT NOT NULL, cik TEXT NOT NULL,
                accession_number TEXT NOT NULL, available_at_ms INTEGER NOT NULL,
                source_reference TEXT NOT NULL, record_hash TEXT NOT NULL, record_json BLOB NOT NULL,
                PRIMARY KEY (record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(cik) = 10), CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE p1_sec_filing_documents (
                record_id TEXT NOT NULL, version_id TEXT NOT NULL, cik TEXT NOT NULL,
                accession_number TEXT NOT NULL, file_name TEXT NOT NULL, available_at_ms INTEGER NOT NULL,
                source_reference TEXT NOT NULL, record_hash TEXT NOT NULL, record_json BLOB NOT NULL,
                PRIMARY KEY (record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(cik) = 10), CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE p1_sec_facts (
                record_id TEXT NOT NULL, fact_id TEXT NOT NULL, version_id TEXT NOT NULL, cik TEXT NOT NULL,
                taxonomy TEXT NOT NULL, concept TEXT NOT NULL, source_unit TEXT NOT NULL,
                period_start TEXT, period_end TEXT NOT NULL, accession_number TEXT NOT NULL,
                filed_date TEXT NOT NULL, available_at_ms INTEGER NOT NULL, canonical_value TEXT NOT NULL,
                source_reference TEXT NOT NULL, record_hash TEXT NOT NULL, record_json BLOB NOT NULL,
                PRIMARY KEY (record_id, version_id),
                FOREIGN KEY (source_reference) REFERENCES p1_source_documents(reference) ON DELETE RESTRICT,
                CHECK (length(cik) = 10), CHECK (length(record_hash) = 64)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX p1_sec_facts_asof ON p1_sec_facts (cik, fact_id, available_at_ms, period_end)")
        try db.execute(sql: """
            CREATE TABLE p1_financial_dictionaries (
                version TEXT PRIMARY KEY NOT NULL, content_hash TEXT NOT NULL, rules_json BLOB NOT NULL,
                CHECK (length(content_hash) = 64)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE p1_financial_normalization_runs (
                run_id TEXT PRIMARY KEY NOT NULL, dictionary_version TEXT NOT NULL, cutoff_ms INTEGER NOT NULL,
                result_hash TEXT NOT NULL, result_json BLOB NOT NULL,
                FOREIGN KEY (dictionary_version) REFERENCES p1_financial_dictionaries(version) ON DELETE RESTRICT,
                CHECK (length(result_hash) = 64)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE p1_normalized_financial_facts (
                run_id TEXT NOT NULL, normalized_id TEXT NOT NULL, field_id TEXT NOT NULL,
                period_type TEXT NOT NULL, period_end TEXT NOT NULL, available_at_ms INTEGER NOT NULL,
                canonical_value TEXT NOT NULL, fact_json BLOB NOT NULL, fact_hash TEXT NOT NULL,
                PRIMARY KEY (run_id, normalized_id),
                FOREIGN KEY (run_id) REFERENCES p1_financial_normalization_runs(run_id) ON DELETE CASCADE,
                CHECK (length(fact_hash) = 64)
            ) WITHOUT ROWID
            """)
    }
}
