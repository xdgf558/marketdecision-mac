import GRDB

extension DatabaseStore {
    /// The ledger has a separate application_id and file. Research clears/archives
    /// do not acquire authority over these rows, and this is not a product backup.
    static let portfolioLedgerMigration = DatabaseMigration(identifier: "portfolio-ledger.v1") { db in
        try db.execute(sql: """
            CREATE TABLE ledger_metadata (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), revision TEXT NOT NULL);
            INSERT INTO ledger_metadata(singleton, revision) VALUES (1, '00000000-0000-0000-0000-000000000000');
            CREATE TABLE ledger_accounts (
                account_id TEXT PRIMARY KEY NOT NULL, currency TEXT NOT NULL CHECK(currency = 'USD'),
                content_hash TEXT NOT NULL CHECK(length(content_hash) = 64), account_json BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE ledger_sources (
                source_id TEXT PRIMARY KEY NOT NULL, raw_hash TEXT NOT NULL CHECK(length(raw_hash) = 64),
                metadata_hash TEXT NOT NULL CHECK(length(metadata_hash) = 64), metadata_json BLOB NOT NULL, raw_bytes BLOB NOT NULL
            );
            CREATE TABLE ledger_batches (
                batch_id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL, content_hash TEXT NOT NULL CHECK(length(content_hash) = 64),
                batch_json BLOB NOT NULL, FOREIGN KEY(source_id) REFERENCES ledger_sources(source_id) ON DELETE RESTRICT
            ) WITHOUT ROWID;
            CREATE TABLE ledger_events (
                event_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, identity_key TEXT NOT NULL UNIQUE,
                audit_sequence INTEGER NOT NULL UNIQUE CHECK(audit_sequence > 0),
                effective_at_json BLOB NOT NULL, source_id TEXT NOT NULL, source_row INTEGER NOT NULL CHECK(source_row > 0),
                batch_id TEXT NOT NULL, content_hash TEXT NOT NULL CHECK(length(content_hash) = 64),
                comparison_hash TEXT NOT NULL CHECK(length(comparison_hash) = 64), event_json BLOB NOT NULL,
                FOREIGN KEY(account_id) REFERENCES ledger_accounts(account_id) ON DELETE RESTRICT,
                FOREIGN KEY(source_id) REFERENCES ledger_sources(source_id) ON DELETE RESTRICT,
                FOREIGN KEY(batch_id) REFERENCES ledger_batches(batch_id) ON DELETE RESTRICT
            ) WITHOUT ROWID;
            CREATE INDEX ledger_event_account_time ON ledger_events(account_id, effective_at_json, event_id);
            """)
    }
}
