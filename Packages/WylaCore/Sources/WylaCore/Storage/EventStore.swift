import Foundation
import GRDB

/// The SQLite database that the agent writes and the app reads, in WAL mode.
public final class EventStore: Sendable {
    public let url: URL
    let pool: DatabasePool

    /// The Darwin notification the agent posts after it writes, so that readers refresh.
    public static let changeNotification = "io.github.drawmeanelephant.wyla.changed"

    /// `~/Library/Application Support/io.github.drawmeanelephant.wyla/wyla.sqlite`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "io.github.drawmeanelephant.wyla", directoryHint: .isDirectory)
            .appending(path: "wyla.sqlite", directoryHint: .notDirectory)
    }

    /// Opens the database, creating it and its folder if needed, and migrates it to the current
    /// schema. Only the current user can read the folder and the database files.
    public init(url: URL = EventStore.defaultURL) throws {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        // SQLite creates the -wal and -shm files with the database file's permissions.
        if !files.fileExists(atPath: url.path(percentEncoded: false)) {
            files.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        self.url = url
        pool = try DatabasePool(path: url.path(percentEncoded: false))
        try Schema.migrator.migrate(pool)
    }

    /// Every stored activation, oldest first. With `from` or `to`, returns the activations that
    /// overlap the range; open activations count as still running.
    public func activations(from start: Date? = nil, to end: Date? = nil) throws -> [Activation] {
        var sql = "SELECT * FROM activations"
        var clauses: [String] = []
        var arguments: [Int64] = []
        if let start {
            clauses.append("(end_us IS NULL OR end_us >= ?)")
            arguments.append(start.microseconds)
        }
        if let end {
            clauses.append("start_us <= ?")
            arguments.append(end.microseconds)
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY start_us, sensor, client"
        return try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Activation.init(row:))
        }
    }

    /// The activations still running.
    public func openActivations() throws -> [Activation] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM activations WHERE end_us IS NULL ORDER BY start_us, sensor, client")
                .map(Activation.init(row:))
        }
    }

    /// Every client and responsible app WYLA has seen.
    public func apps() throws -> [StoredApp] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM apps ORDER BY client").map(StoredApp.init(row:))
        }
    }

    /// The raw events with the given ids, oldest first.
    public func rawEvents(withIDs ids: [Int64]) throws -> [RawEvent] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, time_us, source, message FROM raw_events WHERE id IN (\(placeholders)) ORDER BY time_us, id",
                arguments: StatementArguments(ids)
            ).map(RawEvent.init(row:))
        }
    }

    /// Saves what `AppResolver` found about a client. Keeps the name from the system log if there is one.
    public func save(_ info: AppInfo, for client: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE apps SET name = ifnull(name, ?), path = ?, team_id = ? WHERE client = ?",
                arguments: [info.name, info.path, info.teamID, client])
        }
    }

    /// The latest log timestamp from `source` that the agent processed, to resume backfill from.
    public func checkpoint(for source: RawEventSource) throws -> Date? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT time_us FROM checkpoints WHERE source = ?", arguments: [source.rawValue])
                .map(Date.init(microseconds:))
        }
    }

    /// Permission-check totals per client and service, summed over `tcc_requests_agg`'s
    /// one-minute buckets, most-checked first.
    public func tccRequestTotals() throws -> [TCCSummary] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT client, service,
                        ifnull(sum(CASE WHEN auth_value = 0 THEN count END), 0) AS denied,
                        ifnull(sum(CASE WHEN auth_value = 1 THEN count END), 0) AS unknown,
                        ifnull(sum(CASE WHEN auth_value = 2 THEN count END), 0) AS allowed,
                        ifnull(sum(CASE WHEN auth_value = 3 THEN count END), 0) AS limited,
                        min(minute_us) AS first_us, max(minute_us) AS last_us,
                        sum(count) AS total
                    FROM tcc_requests_agg GROUP BY client, service ORDER BY total DESC, client, service
                    """
            ).map(TCCSummary.init(row:))
        }
    }

<<<<<<< HEAD
    /// One day's checks of one kind for the Requests history chart.
    public struct TCCDailyCount: Sendable, Equatable, Hashable {
        /// Start of the local day the checks were counted in.
        public let day: Date
        /// "denied", "unknown", "allowed", or "limited".
        public let result: String
        public let count: Int

        public init(day: Date, result: String, count: Int) {
            self.day = day
            self.result = result
            self.count = count
        }
    }

    /// Per-day totals of one client and service's permission checks, summed from the one-minute
    /// buckets into local days, oldest first.
    public func tccRequestDaily(client: String, service: String) throws -> [TCCDailyCount] {
        let rows = try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT minute_us, auth_value, sum(count) AS count FROM tcc_requests_agg
                    WHERE client = ? AND service = ? GROUP BY minute_us, auth_value
                    """
                , arguments: [client, service])
        }
        let names = [0: "denied", 1: "unknown", 2: "allowed", 3: "limited"]
        var days: [Date: [String: Int]] = [:]
        for row in rows {
            let minute: Int64 = row["minute_us"]
            let day = Calendar.current.startOfDay(for: Date(microseconds: minute))
            let result = names[row["auth_value"] as Int] ?? "unknown"
            days[day, default: [:]][result, default: 0] += row["count"] as Int
        }
        return days.keys.sorted().flatMap { day in
            (days[day] ?? [:]).sorted { $0.key < $1.key }
                .map { TCCDailyCount(day: day, result: $0.key, count: $0.value) }
        }
    }

    /// The agent's coverage periods, oldest first: each agent run covers the time between its
    /// start and its last heartbeat. Gaps between them are times nothing was monitoring.
    public func coverage() throws -> [(start: Date, end: Date)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT started_us, last_heartbeat_us FROM coverage ORDER BY started_us").map {
                (Date(microseconds: $0["started_us"]), Date(microseconds: $0["last_heartbeat_us"]))
            }
        }
    }

    /// Every chained `raw_events` column for the rows at or between `start` and `end`, in chain
    /// order: what an export carries so the chain can be verified without the database.
    public func chainedEvents(from start: Date, to end: Date) throws -> [ExportedRow] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, time_us, source, message, dedup_key, prev_hash, hash
                    FROM raw_events WHERE time_us BETWEEN ? AND ? ORDER BY id
                    """,
                arguments: [start.microseconds, end.microseconds]
            ).map {
                ExportedRow(
                    id: $0["id"], timeMicros: $0["time_us"], source: $0["source"], dedupKey: $0["dedup_key"],
                    prevHash: $0["prev_hash"], hash: $0["hash"], message: $0["message"])
            }
        }
    }

    /// How many activations of `client` on `sensor` are stored; `nil` counts unattributed use.
    /// The agent alerts on the first use of a sensor by an app: the count is one when the
    /// activation that just started is the first recorded.
    public func activationCount(sensor: Sensor, client: String?) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM activations WHERE sensor = ? AND client IS ?",
                arguments: [sensor.rawValue, client]) ?? 0
        }
    }

    /// The stored indicator lines the parser rejects — a sign that a new macOS log format needs a
    /// fixture and a parser update.
    public func unparsedIndicatorCount() throws -> Int {
        let parser = IndicatorParser()
        return try pool.read { db in
            try String.fetchAll(db, sql: "SELECT message FROM raw_events WHERE source = 'indicator'")
                .filter { if case .unparsed = parser.parse($0) { true } else { false } }
                .count
        }
    }

    /// The last heartbeat the agent saved, or nil if it never ran. An old heartbeat means the
    /// agent is dead, so the viewer doesn't treat the open activations it left behind as live.
    public func lastHeartbeat() throws -> Date? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT max(last_heartbeat_us) FROM coverage").map(Date.init(microseconds:))
        }
    }

    /// The last row of the hash chain. Save it outside the database to detect later truncation or
    /// rewriting with `verifyIntegrity(anchor:)`.
    public func head() throws -> ChainAnchor? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT id, hash FROM raw_events ORDER BY id DESC LIMIT 1").map {
                ChainAnchor(id: $0["id"], hash: $0["hash"])
            }
        }
    }

    /// Recomputes the hash chain over `raw_events` and reports the first row that doesn't match.
    /// With an `anchor` saved earlier, also checks that the chain still contains that row unchanged.
    public func verifyIntegrity(anchor: ChainAnchor? = nil) throws -> IntegrityReport {
        try pool.read { db in
            var verifier = ChainVerifier(anchor: anchor)
            let rows = try Row.fetchCursor(
                db, sql: "SELECT id, time_us, source, message, dedup_key, prev_hash, hash FROM raw_events ORDER BY id")
            while let row = try rows.next() {
                if verifier.check(row) { break }
            }
            return verifier.report()
        }
    }

    struct Appended {
        let id: Int64
        let isNew: Bool
    }

    /// Appends a row to the hash chain, unless a row with the same dedup key exists. `identity`
    /// tells apart events with the same message; nil means the time.
    static func append(_ source: RawEventSource, time: Date, identity: String?, message: String, in db: Database) throws -> Appended {
        let timeMicros = time.microseconds
        let dedupKey = HashChain.dedupKey(source: source, identity: identity ?? String(timeMicros), message: message)
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM raw_events WHERE dedup_key = ?", arguments: [dedupKey]) {
            return Appended(id: existing, isNew: false)
        }
        let last = try Row.fetchOne(db, sql: "SELECT id, hash FROM raw_events ORDER BY id DESC LIMIT 1")
        let id = (last.map { $0["id"] as Int64 } ?? 0) + 1
        let prevHash = last.map { $0["hash"] as String } ?? HashChain.genesis
        let row = ChainedRow(
            id: id, timeMicros: timeMicros, source: source.rawValue, dedupKey: dedupKey, prevHash: prevHash, message: message)
        try db.execute(
            sql: """
                INSERT INTO raw_events (id, time_us, source, message, dedup_key, prev_hash, hash)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, timeMicros, source.rawValue, message, dedupKey, prevHash, row.hash])
        return Appended(id: id, isNew: true)
    }
}

/// A row of the hash chain, identified by its id and hash.
public struct ChainAnchor: Sendable, Equatable, Codable {
    public let id: Int64
    public let hash: String

    public init(id: Int64, hash: String) {
        self.id = id
        self.hash = hash
    }
}

public enum IntegrityProblem: Sendable, Equatable {
    /// Row ids skip from `after` to `next`: rows were deleted, or the chain doesn't start at 1.
    case missingRows(after: Int64, next: Int64)
    /// The row's `prev_hash` is not the previous row's hash: a row was inserted or replaced here.
    case brokenLink(id: Int64)
    /// The row's hash doesn't match its contents: the row was edited.
    case hashMismatch(id: Int64)
    /// The chain no longer contains the anchor row unchanged: rows were removed from the end, or
    /// the chain was rewritten from that row on.
    case anchorMismatch(ChainAnchor)

    /// The first row that failed, or for `missingRows` the first row after the gap.
    public var firstBadRow: Int64 {
        switch self {
        case .missingRows(_, let next): next
        case .brokenLink(let id), .hashMismatch(let id): id
        case .anchorMismatch(let anchor): anchor.id
        }
    }
}

public struct IntegrityReport: Sendable, Equatable {
    /// Rows checked before the first problem, or all rows when the chain is intact.
    public let verifiedRows: Int
    /// The last verified row.
    public let head: ChainAnchor?
    public let problem: IntegrityProblem?

    public var isIntact: Bool { problem == nil }
}

private struct ChainVerifier {
    let anchor: ChainAnchor?
    private var previous: ChainAnchor?
    private var verifiedRows = 0
    private var anchorFound = false
    private var problem: IntegrityProblem?

    init(anchor: ChainAnchor?) {
        self.anchor = anchor
    }

    /// Returns true when the row has a problem, which ends the check.
    mutating func check(_ row: Row) -> Bool {
        let id: Int64 = row["id"]
        let prevHash: String = row["prev_hash"]
        let hash: String = row["hash"]
        let expectedID = (previous?.id ?? 0) + 1
        if id != expectedID {
            problem = .missingRows(after: expectedID - 1, next: id)
        } else if prevHash != previous?.hash ?? HashChain.genesis {
            problem = .brokenLink(id: id)
        } else {
            let expected = ChainedRow(
                id: id, timeMicros: row["time_us"], source: row["source"], dedupKey: row["dedup_key"], prevHash: prevHash,
                message: row["message"])
            if hash != expected.hash { problem = .hashMismatch(id: id) }
        }
        if problem != nil { return true }
        previous = ChainAnchor(id: id, hash: hash)
        verifiedRows += 1
        if previous == anchor { anchorFound = true }
        return false
    }

    func report() -> IntegrityReport {
        var problem = problem
        if problem == nil, let anchor, !anchorFound {
            problem = .anchorMismatch(anchor)
        }
        return IntegrityReport(verifiedRows: verifiedRows, head: previous, problem: problem)
    }
}
