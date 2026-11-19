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

    /// Every completed TCC request, deduplicated on (message_id, dedup_id): `dedup_id` is the
    /// CTX entry's mach time — `log stream` and `log show` report the same entry ~1 ms apart in
    /// wall time but identical mach time — falling back to the request's wall time when the
    /// entry carried no id. `raw_event_id` is NULL until the request links an activation to its
    /// responsible app — only linking requests join the hash chain; the rest exist here only as
    /// dedup rows feeding `tcc_requests_agg`. Existing request events backfill the table: their
    /// stored JSON carries the messageID and `time` (JSONEncoder's seconds since 2001).
    private static let version3 = """
        CREATE TABLE tcc_requests (
            message_id TEXT NOT NULL,
            dedup_id TEXT NOT NULL,
            time_us INTEGER NOT NULL,
            raw_event_id INTEGER REFERENCES raw_events(id),
            PRIMARY KEY (message_id, dedup_id)
        ) WITHOUT ROWID;
        INSERT OR IGNORE INTO tcc_requests (message_id, dedup_id, time_us, raw_event_id)
            SELECT json_extract(message, '$.messageID'),
                ifnull(json_extract(message, '$.entryID'),
                    CAST(CAST((json_extract(message, '$.time') + 978307200) * 1000000 + 0.5 AS INTEGER) AS TEXT)),
                CAST((json_extract(message, '$.time') + 978307200) * 1000000 + 0.5 AS INTEGER),
                id FROM raw_events
            WHERE source = 'tcc' AND json_extract(message, '$.messageID') IS NOT NULL;
        -- Databases that predate the Requests totals stored request events without counting
        -- them; rebuild their totals too, through the deduplicated tcc_requests rows.
        INSERT OR IGNORE INTO tcc_requests_agg (minute_us, client, service, auth_value, count)
            SELECT CAST(r.time_us / 60000000 AS INTEGER) * 60000000,
                ifnull(coalesce(json_extract(e.message, '$.responsible.identifier'),
                    json_extract(e.message, '$.accessing.identifier'),
                    json_extract(e.message, '$.requesting.identifier')), ''),
                json_extract(e.message, '$.service'), json_extract(e.message, '$.authValue'), count(*)
            FROM tcc_requests r JOIN raw_events e ON e.id = r.raw_event_id
            GROUP BY 1, 2, 3, 4;
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
