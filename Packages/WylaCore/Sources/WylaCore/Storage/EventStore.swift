import Foundation
import GRDB

/// The SQLite database that the agent writes and the app reads, in WAL mode.
public final class EventStore: Sendable {
    public let url: URL
    let pool: DatabasePool

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

    /// Every stored activation, oldest first.
    public func activations() throws -> [Activation] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM activations ORDER BY start_us, sensor, client").map(Activation.init(row:))
        }
    }

    /// The latest log timestamp from `source` that the agent processed, to resume backfill from.
    public func checkpoint(for source: RawEventSource) throws -> Date? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT time_us FROM checkpoints WHERE source = ?", arguments: [source.rawValue])
                .map(Date.init(microseconds:))
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

    /// Appends a row to the hash chain, unless a row with the same dedup key exists.
    static func append(_ source: RawEventSource, time: Date, message: String, in db: Database) throws -> Appended {
        let timeMicros = time.microseconds
        let dedupKey = HashChain.dedupKey(source: source, timeMicros: timeMicros, message: message)
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
