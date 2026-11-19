import Foundation

/// A `raw_events` row as it appears in an export: every chained column, so the chain can be
/// verified from the file alone.
public struct ExportedRow: Sendable, Equatable, Codable {
    public let id: Int64
    public let timeMicros: Int64
    public let source: String
    public let dedupKey: String
    public let prevHash: String
    public let hash: String
    public let message: String

    public init(id: Int64, timeMicros: Int64, source: String, dedupKey: String, prevHash: String, hash: String, message: String) {
        self.id = id
        self.timeMicros = timeMicros
        self.source = source
        self.dedupKey = dedupKey
        self.prevHash = prevHash
        self.hash = hash
        self.message = message
    }

    /// The row's `hash` column if its contents are what they claim to be.
    var expectedHash: String {
        ChainedRow(
            id: id, timeMicros: timeMicros, source: source, dedupKey: dedupKey, prevHash: prevHash, message: message
        ).hash
    }

    static let csvHeader = "id,time_us,source,dedup_key,prev_hash,hash,message"
    var csvRow: String {
        "\(id),\(timeMicros),\(CSV.escape(source)),\(dedupKey),\(prevHash),\(hash),\(CSV.escape(message))"
    }
}

/// What the export says it contains; the verifier checks the files against it.
public struct ExportManifest: Sendable, Equatable, Codable {
    public let exportedAt: Date
    public let from: Date
    public let end: Date
    /// The last exported row; a chain that was tampered with no longer ends there.
    public let head: ChainAnchor?
    public let rowCount: Int
    public let sessionCount: Int

    public init(exportedAt: Date, from: Date, end: Date, head: ChainAnchor?, rowCount: Int, sessionCount: Int) {
        self.exportedAt = exportedAt
        self.from = from
        self.end = end
        self.head = head
        self.rowCount = rowCount
        self.sessionCount = sessionCount
    }
}

enum CSV {
    /// CSV quoting: quote when the value can break a row, double the quotes inside it.
    static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ values: [String?]) -> String {
        values.map { CSV.escape($0 ?? "") }.joined(separator: ",")
    }
}

/// The result of checking an export's hash chain, mirroring `IntegrityReport` for the database.
public struct ExportReport: Sendable, Equatable {
    /// Rows checked before the first problem, or all rows when the export is intact.
    public let verifiedRows: Int
    /// The last verified row.
    public let head: ChainAnchor?
    public let problem: IntegrityProblem?
    /// The manifest's head and the verified head differ: rows were removed or rewritten.
    public let headMismatch: Bool

    public var isIntact: Bool { problem == nil && !headMismatch }
}

/// Writes the raw events and sessions of a date range to a directory, as CSV and JSON, and
/// verifies such an export without the database.
public enum AuditExport {

    /// Exports the raw events and sessions overlapping `[from, end]` into `directory` (created).
    /// The directory gets `manifest.json` plus `raw_events` and `sessions` in both formats.
    @discardableResult
    public static func write(store: EventStore, from: Date, to end: Date, to directory: URL) throws -> ExportManifest {
        let rows = try store.chainedEvents(from: from, to: end)
        let sessions = SessionMerger.merge(try store.activations(from: from, to: end))
        let manifest = ExportManifest(
            exportedAt: .now, from: from, end: end, head: rows.last.map { ChainAnchor(id: $0.id, hash: $0.hash) },
            rowCount: rows.count, sessionCount: sessions.count)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        try encoder.encode(rows).write(to: directory.appending(path: "raw_events.json"), options: .atomic)
        try encoder.encode(sessions.map(ExportedSession.init(session:)))
            .write(to: directory.appending(path: "sessions.json"), options: .atomic)

        let rawCSV = ([ExportedRow.csvHeader] + rows.map(\.csvRow)).joined(separator: "\n") + "\n"
        try rawCSV.write(to: directory.appending(path: "raw_events.csv"), atomically: true, encoding: .utf8)
        let sessionsCSV =
            ([ExportedSession.csvHeader] + sessions.map { ExportedSession(session: $0).csvRow })
            .joined(separator: "\n") + "\n"
        try sessionsCSV.write(to: directory.appending(path: "sessions.csv"), atomically: true, encoding: .utf8)
        return manifest
    }

    /// Recomputes the hash chain of an exported `raw_events.json` and checks the result against
    /// the manifest's head. The first row's `prev_hash` is trusted — only the chain the file
    /// carries is verified; an anchor saved elsewhere covers the prefix before it.
    public static func verify(directory: URL) throws -> ExportReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            ExportManifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        let rows = try decoder.decode(
            [ExportedRow].self, from: Data(contentsOf: directory.appending(path: "raw_events.json")))

        var previous: ChainAnchor?
        var verifiedRows = 0
        var problem: IntegrityProblem?
        // A range export can legitimately skip ids when backfill stored rows whose time falls
        // outside the range between rows inside it, so the link is checked only where ids are
        // consecutive; the count against the manifest is what catches removed rows.
        if rows.count != manifest.rowCount {
            let atRow = rows.count > manifest.rowCount ? rows[manifest.rowCount].id : (rows.last?.id ?? 0) + 1
            problem = .countMismatch(found: rows.count, manifest: manifest.rowCount, atRow: atRow)
        }
        for row in rows where problem == nil {
            if let last = previous, row.id <= last.id {
                problem = .brokenLink(id: row.id)
            } else if let last = previous, row.id == last.id + 1, row.prevHash != last.hash {
                problem = .brokenLink(id: row.id)
            } else if row.hash != row.expectedHash {
                problem = .hashMismatch(id: row.id)
            } else {
                previous = ChainAnchor(id: row.id, hash: row.hash)
                verifiedRows += 1
            }
        }
        let headMismatch = problem == nil && manifest.head != previous
        return ExportReport(verifiedRows: verifiedRows, head: previous, problem: problem, headMismatch: headMismatch)
    }
}

/// A session as it appears in an export's `sessions` files.
struct ExportedSession: Codable {
    let sensor: String
    let client: String?
    let displayName: String?
    let responsible: String?
    let start: Date
    let end: Date?
    let activationCount: Int

    init(session: Session) {
        sensor = session.sensor.rawValue
        client = session.client
        displayName = session.displayName
        responsible = session.responsible?.identifier
        start = session.start
        end = session.end
        activationCount = session.activations.count
    }

    static let csvHeader = "sensor,client,display_name,responsible,start,end,activation_count"
    var csvRow: String {
        CSV.line([
            sensor, client, displayName, responsible, ISO8601DateFormatter().string(from: start),
            end.map { ISO8601DateFormatter().string(from: $0) }, String(activationCount)
        ])
    }
}
