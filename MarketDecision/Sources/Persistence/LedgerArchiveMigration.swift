import GRDB

extension DatabaseStore {
    static let portfolioArchiveMigration = DatabaseMigration(identifier:"portfolio-ledger.archive.v1") { db in
        try db.execute(sql:"""
            CREATE TABLE ledger_archive_origins (
                archive_hash TEXT PRIMARY KEY NOT NULL CHECK(length(archive_hash) = 64), archive_bytes BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE ledger_archive_batch_links (
                batch_id TEXT PRIMARY KEY NOT NULL, archive_hash TEXT NOT NULL, original_batch_id TEXT NOT NULL,
                FOREIGN KEY(batch_id) REFERENCES ledger_batches(batch_id) ON DELETE RESTRICT,
                FOREIGN KEY(archive_hash) REFERENCES ledger_archive_origins(archive_hash) ON DELETE RESTRICT
            ) WITHOUT ROWID;
            CREATE TABLE ledger_archive_conflicts (
                conflict_id TEXT PRIMARY KEY NOT NULL, archive_hash TEXT NOT NULL UNIQUE CHECK(length(archive_hash) = 64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash) = 64), summary_json BLOB NOT NULL, archive_bytes BLOB NOT NULL
            ) WITHOUT ROWID;
            """)
    }
}
