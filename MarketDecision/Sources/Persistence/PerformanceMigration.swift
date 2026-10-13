import GRDB

extension DatabaseStore {
    /// Append to MDL1 only. Existing ledger facts/revisions are unchanged and
    /// research archives still have no authority over this database.
    static let portfolioPerformanceMigration = DatabaseMigration(identifier:"portfolio-ledger.performance.v1") { db in
        try db.execute(sql:"""
            CREATE TABLE performance_metadata (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1), revision TEXT NOT NULL
            );
            INSERT INTO performance_metadata(singleton,revision) VALUES (1,'00000000-0000-0000-0000-000000000000');
            CREATE TABLE performance_inputs (
                input_hash TEXT PRIMARY KEY NOT NULL CHECK(length(input_hash) = 64),
                ledger_revision TEXT NOT NULL, engine_version TEXT NOT NULL, parameters_version TEXT NOT NULL,
                numeric_policy_version TEXT NOT NULL, input_json BLOB NOT NULL,
                request_hash TEXT NOT NULL CHECK(length(request_hash) = 64), request_json BLOB NOT NULL
            );
            CREATE TABLE performance_report_catalog (
                report_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, ledger_revision TEXT NOT NULL,
                input_hash TEXT NOT NULL UNIQUE, report_hash TEXT NOT NULL CHECK(length(report_hash) = 64),
                summary_hash TEXT NOT NULL CHECK(length(summary_hash) = 64), summary_json BLOB NOT NULL,
                FOREIGN KEY(account_id) REFERENCES ledger_accounts(account_id) ON DELETE RESTRICT,
                FOREIGN KEY(input_hash) REFERENCES performance_inputs(input_hash) ON DELETE RESTRICT
            ) WITHOUT ROWID;
            CREATE INDEX performance_report_account ON performance_report_catalog(account_id,report_id);
            CREATE TABLE performance_report_documents (
                report_id TEXT PRIMARY KEY NOT NULL, report_json BLOB NOT NULL,
                FOREIGN KEY(report_id) REFERENCES performance_report_catalog(report_id) ON DELETE RESTRICT
            );
            """)
    }
}
