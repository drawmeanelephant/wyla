import GRDB

/// The database schema. Table and column names are part of the on-disk format: change them only
/// through a new migration, never by editing a registered one.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: version1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: version2)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: version3)
        }
        return migrator
    }

    /// The messageID of every completed TCC request, linked to its raw event. A request reaches
    /// the recorder twice when `log show` backfill and `log stream` overlap, so the recorder
    /// counts a request only when its messageID is new. Existing request events backfill the
    /// table: their stored JSON carries the messageID.
    private static let version3 = """
        CREATE TABLE tcc_requests (
            message_id TEXT PRIMARY KEY,
            raw_event_id INTEGER NOT NULL REFERENCES raw_events(id)
        ) WITHOUT ROWID;
        INSERT INTO tcc_requests (message_id, raw_event_id)
            SELECT json_extract(message, '$.messageID'), id FROM raw_events
            WHERE source = 'tcc' AND json_extract(message, '$.messageID') IS NOT NULL;
        """

    /// Marks clients that Control Center names by executable name, such as `bash`.
    private static let version2 = """
        ALTER TABLE apps ADD COLUMN command_line INTEGER NOT NULL DEFAULT 0;
        UPDATE apps SET command_line = 1 WHERE instr(client, '.') = 0;
        """

    private static let version1 = """
        CREATE TABLE raw_events (
            id INTEGER PRIMARY KEY,
            time_us INTEGER NOT NULL,
            source TEXT NOT NULL,
            message TEXT NOT NULL,
            dedup_key TEXT NOT NULL UNIQUE,
            prev_hash TEXT NOT NULL,
            hash TEXT NOT NULL
        );
        CREATE TRIGGER raw_events_no_update BEFORE UPDATE ON raw_events
        BEGIN SELECT RAISE(ABORT, 'raw_events is append-only'); END;
        CREATE TRIGGER raw_events_no_delete BEFORE DELETE ON raw_events
        BEGIN SELECT RAISE(ABORT, 'raw_events is append-only'); END;
        CREATE TRIGGER raw_events_extend_chain BEFORE INSERT ON raw_events
        WHEN NEW.id IS NOT (SELECT ifnull(max(id), 0) + 1 FROM raw_events)
            OR NEW.prev_hash IS NOT ifnull((SELECT hash FROM raw_events ORDER BY id DESC LIMIT 1), '\(HashChain.genesis)')
        BEGIN SELECT RAISE(ABORT, 'raw_events rows must extend the hash chain'); END;

        CREATE TABLE activations (
            id INTEGER PRIMARY KEY,
            sensor TEXT NOT NULL,
            client TEXT,
            start_us INTEGER NOT NULL,
            end_us INTEGER,
            end_reason TEXT,
            display_name TEXT,
            device TEXT,
            device_use TEXT NOT NULL DEFAULT '{}',
            device_use_until_us INTEGER NOT NULL,
            responsible_client TEXT,
            responsible_pid INTEGER,
            responsible_path TEXT,
            start_event_id INTEGER REFERENCES raw_events(id),
            end_event_id INTEGER REFERENCES raw_events(id),
            responsible_event_id INTEGER REFERENCES raw_events(id)
        );
        CREATE UNIQUE INDEX activations_identity ON activations(sensor, ifnull(client, ''), start_us);
        CREATE INDEX activations_start ON activations(start_us);
        CREATE INDEX activations_open ON activations(end_us) WHERE end_us IS NULL;

        CREATE TABLE apps (
            client TEXT PRIMARY KEY,
            name TEXT,
            path TEXT,
            team_id TEXT,
            first_seen_us INTEGER NOT NULL,
            last_seen_us INTEGER NOT NULL
        );

        CREATE TABLE tcc_requests_agg (
            minute_us INTEGER NOT NULL,
            client TEXT NOT NULL,
            service TEXT NOT NULL,
            auth_value INTEGER NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY (minute_us, client, service, auth_value)
        ) WITHOUT ROWID;

        CREATE TABLE coverage (
            id INTEGER PRIMARY KEY,
            started_us INTEGER NOT NULL,
            last_heartbeat_us INTEGER NOT NULL
        );

        CREATE TABLE checkpoints (
            source TEXT PRIMARY KEY,
            time_us INTEGER NOT NULL
        ) WITHOUT ROWID;
        """
}
