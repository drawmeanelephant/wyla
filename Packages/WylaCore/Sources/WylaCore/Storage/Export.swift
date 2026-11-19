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

    enum CodingKeys: String, CodingKey {
        case id, source, hash, message
        case timeMicros = "time_us"
        case dedupKey = "dedup_key"
        case prevHash = "prev_hash"
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
    /// Rows inside the exported id span that fell outside the requested range — usually
    /// events backfilled late. Their contents stay out of the export so a shared file
    /// doesn't leak history beyond the chosen range; their ids and hashes keep the chain
    /// verifiable end to end.
    public let skipped: [ChainAnchor]

    enum CodingKeys: String, CodingKey {
        case end, head, skipped
        case exportedAt = "exported_at"
        case from
        case rowCount = "row_count"
        case sessionCount = "session_count"
    }

    public init(
        exportedAt: Date, from: Date, end: Date, head: ChainAnchor?, rowCount: Int,
        sessionCount: Int, skipped: [ChainAnchor] = []
    ) {
        self.exportedAt = exportedAt
        self.from = from
        self.end = end
        self.head = head
        self.rowCount = rowCount
        self.sessionCount = sessionCount
        self.skipped = skipped
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        from = try container.decode(Date.self, forKey: .from)
        end = try container.decode(Date.self, forKey: .end)
        head = try container.decodeIfPresent(ChainAnchor.self, forKey: .head)
        rowCount = try container.decode(Int.self, forKey: .rowCount)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        skipped = try container.decodeIfPresent([ChainAnchor].self, forKey: .skipped) ?? []
    }
}

/// ISO 8601 with fractional seconds for the sessions files — whole-second output would show
/// a sub-second session as zero-length.
private func iso8601Fractional(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

enum CSV {
    /// CSV quoting: quote when the value can break a row, double the quotes inside it.
    static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        else { return value }
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

    /// Exports the raw events and sessions overlapping `[from, end]` into `directory` (created
    /// 0700, files 0600 — exports carry personal data). The directory gets `manifest.json` plus
    /// `raw_events` and `sessions` in both formats. `mergeWindow` is the user's session-merge
    /// setting so exported sessions match what the viewer shows.
    @discardableResult
    public static func write(
        store: EventStore, from: Date, to end: Date, to directory: URL,
        mergeWindow: TimeInterval = SessionMerger.defaultWindow
    ) throws -> ExportManifest {
        let rows = try store.chainedEvents(from: from, to: end)
        // Backfill can append rows with older timestamps after newer ones, so the
        // time-filtered set can skip ids inside its own span. The verifier requires the
        // span contiguous, so the skipped rows go in the manifest — ids and hashes only,
        // not contents: a shared export must not carry events outside the chosen range.
        var skipped: [ChainAnchor] = []
        if let first = rows.first, let last = rows.last {
            let kept = Set(rows.map(\.id))
            skipped = try store.chainedEvents(idsIn: first.id...last.id)
                .filter { !kept.contains($0.id) }
                .map { ChainAnchor(id: $0.id, hash: $0.hash) }
        }
        let hashes = Dictionary(rows.map { ($0.id, $0.hash) }, uniquingKeysWith: { first, _ in first })
        let sessions = SessionMerger.merge(try store.activations(from: from, to: end), window: mergeWindow)
        let manifest = ExportManifest(
            exportedAt: .now, from: from, end: end, head: rows.last.map { ChainAnchor(id: $0.id, hash: $0.hash) },
            rowCount: rows.count, sessionCount: sessions.count, skipped: skipped)

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Session timestamps need sub-second precision or short sessions read as zero-length.
        let sessionsEncoder = JSONEncoder()
        sessionsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        sessionsEncoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional(date))
        }
        let sessionsEncoded = sessions.map { ExportedSession(session: $0, hashes: hashes) }
        try writeFile(encoder.encode(manifest), to: directory.appending(path: "manifest.json"))
        try writeFile(encoder.encode(rows), to: directory.appending(path: "raw_events.json"))
        try writeFile(sessionsEncoder.encode(sessionsEncoded), to: directory.appending(path: "sessions.json"))

        let rawCSV = ([ExportedRow.csvHeader] + rows.map(\.csvRow)).joined(separator: "\n") + "\n"
        try writeFile(Data(rawCSV.utf8), to: directory.appending(path: "raw_events.csv"))
        let sessionsCSV =
            ([ExportedSession.csvHeader] + sessionsEncoded.map(\.csvRow)).joined(separator: "\n") + "\n"
        try writeFile(Data(sessionsCSV.utf8), to: directory.appending(path: "sessions.csv"))
        return manifest
    }

    /// Writes `data` to `url` with owner-only permissions; exports hold personal data. A failed
    /// write throws — reporting success for a missing file would produce a corrupt export.
    private static func writeFile(_ data: Data, to url: URL) throws {
        guard
            FileManager.default.createFile(
                atPath: url.path(percentEncoded: false), contents: data,
                attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Recomputes the hash chain of an exported `raw_events.json` (the CSV files are not
    /// verified) and checks the result against the manifest's head. Exported ids must be
    /// contiguous apart from the `skipped` rows the manifest declares — the chain links
    /// through those hashes — the first row's `prev_hash` must be the genesis value or, for a
    /// partial export, the hash `anchors` recorded for the row before it, and every anchor the
    /// range provably covers must appear unchanged; the newest missing one reports as
    /// truncation. `anchors` are the `(day, anchor)` pairs from `anchors.log`. A day strictly
    /// inside the range is covered; a boundary day only when the manifest covers it whole, so a
    /// partial-day export doesn't flag an anchor written later that day; and an anchor is only
    /// required from the first exported row on, so a carried-forward head earlier than the
    /// export isn't counted missing.
    public static func verify(
        directory: URL,
        anchors: [(day: String, anchor: ChainAnchor)] = []
    ) throws -> ExportReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            ExportManifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        let rows = try decoder.decode(
            [ExportedRow].self, from: Data(contentsOf: directory.appending(path: "raw_events.json")))

        let anchorsByID = Dictionary(anchors.map { ($0.anchor.id, $0.anchor.hash) }, uniquingKeysWith: { first, _ in first })
        let covered = coveredAnchors(anchors, manifest: manifest, firstID: rows.first?.id ?? 0)
        let skippedByID = Dictionary(
            manifest.skipped.map { ($0.id, $0.hash) }, uniquingKeysWith: { first, _ in first })
        var problem: IntegrityProblem?
        if rows.count != manifest.rowCount {
            let atRow =
                manifest.rowCount >= 0 && rows.count > manifest.rowCount
                ? rows[manifest.rowCount].id : (rows.last?.id ?? 0) + 1
            problem = .countMismatch(found: rows.count, manifest: manifest.rowCount, atRow: atRow)
        }
        let walk = problem == nil ? verifyChain(rows, skipped: skippedByID, anchors: anchorsByID) : ChainWalk()
        problem = problem ?? walk.problem
        // The newest covered anchor whose row is missing reports as truncation; a skipped row
        // is still present — the manifest carries its hash. The check runs even on an empty
        // export — clearing every row and the manifest must not pass — and is not bounded by
        // the manifest's head, which a forgery lowers after deleting the tail.
        if problem == nil {
            let knownIDs = Set(rows.map(\.id)).union(skippedByID.keys)
            let missing = covered.filter { !knownIDs.contains($0.id) }.max { $0.id < $1.id }
            if let missing {
                problem = .anchorMismatch(missing)
            }
        }
        let headMismatch = problem == nil && manifest.head != walk.head
        return ExportReport(verifiedRows: walk.verifiedRows, head: walk.head, problem: problem, headMismatch: headMismatch)
    }

    /// The anchors an export must contain. An anchor is written at its day's end, so a day is
    /// covered when the manifest's range reaches that end — days before the last always
    /// qualify, the last day only when the manifest covers it whole, or a partial-day export
    /// would flag an anchor written later that day. An anchor is only required from the first
    /// exported row on: a quiet day carries the previous head forward, so a covered day can
    /// legitimately anchor a row the export starts after.
    private static func coveredAnchors(
        _ anchors: [(day: String, anchor: ChainAnchor)], manifest: ExportManifest, firstID: Int64
    ) -> [ChainAnchor] {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let firstDay = dayFormatter.string(from: manifest.from)
        let lastDay = dayFormatter.string(from: manifest.end)
        let lastDayEnd = dayFormatter.date(from: lastDay).map { $0 + 86399 } ?? .distantFuture
        return anchors.filter { entry in
            guard entry.anchor.id >= firstID else { return false }
            guard entry.day >= firstDay && entry.day <= lastDay else { return false }
            return entry.day < lastDay || manifest.end >= lastDayEnd
        }.map(\.anchor)
    }

    /// The outcome of walking an export's chain.
    private struct ChainWalk {
        var problem: IntegrityProblem?
        var head: ChainAnchor?
        var verifiedRows = 0
    }

    /// Walks `rows` against the chain rules, stopping at the first problem. The chain links
    /// through `skipped` rows the manifest declares — their hashes verify the link and can be
    /// pinned by an anchor — so advance over them up to each row; a gap the manifest doesn't
    /// declare stays a `missingRows` problem.
    private static func verifyChain(
        _ rows: [ExportedRow], skipped: [Int64: String], anchors: [Int64: String]
    ) -> ChainWalk {
        var walk = ChainWalk()
        for (index, row) in rows.enumerated() {
            while let last = walk.head, last.id + 1 < row.id, let skippedHash = skipped[last.id + 1] {
                let skippedAnchor = ChainAnchor(id: last.id + 1, hash: skippedHash)
                walk.head = skippedAnchor
                if let pinned = anchors[skippedAnchor.id], pinned != skippedHash {
                    walk.problem = .anchorMismatch(skippedAnchor)
                    return walk
                }
            }
            guard let problem = check(row, at: index, after: walk.head, anchors: anchors) else {
                walk.head = ChainAnchor(id: row.id, hash: row.hash)
                walk.verifiedRows += 1
                continue
            }
            walk.problem = problem
            return walk
        }
        return walk
    }

    /// The problem with `row`, or nil when it extends the chain cleanly. The first row must
    /// chain to genesis or — for a partial export — to the anchor saved for the row before it;
    /// later rows must be contiguous and linked; anchored rows must carry the anchored hash.
    private static func check(
        _ row: ExportedRow, at index: Int, after previous: ChainAnchor?, anchors: [Int64: String]
    ) -> IntegrityProblem? {
        if index == 0 {
            if row.id == 1, row.prevHash != HashChain.genesis {
                return .brokenLink(id: row.id)
            } else if row.id > 1, let anchored = anchors[row.id - 1], row.prevHash != anchored {
                return .brokenLink(id: row.id)
            }
        } else if let last = previous, row.id != last.id + 1 {
            return .missingRows(after: last.id, next: row.id)
        } else if let last = previous, row.prevHash != last.hash {
            return .brokenLink(id: row.id)
        }
        if let anchored = anchors[row.id], row.hash != anchored {
            return .anchorMismatch(ChainAnchor(id: row.id, hash: anchored))
        }
        return row.hash == row.expectedHash ? nil : .hashMismatch(id: row.id)
    }
}

/// A chain row a session references: its event id and hash, so an exported session traces back
/// to rows the verifier checked. The hash is absent when the row falls outside the export.
struct ExportedEventRef: Codable {
    let id: Int64
    let hash: String?

    enum CodingKeys: String, CodingKey {
        case id = "event_id"
        case hash = "event_hash"
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
    let eventRefs: [ExportedEventRef]

    enum CodingKeys: String, CodingKey {
        case sensor, client, responsible, start, end
        case displayName = "display_name"
        case activationCount = "activation_count"
        case eventRefs = "event_refs"
    }

    init(session: Session, hashes: [Int64: String] = [:]) {
        sensor = session.sensor.rawValue
        client = session.client
        displayName = session.displayName
        responsible = session.responsible?.identifier
        start = session.start
        end = session.end
        activationCount = session.activations.count
        eventRefs = session.eventIDs.map { ExportedEventRef(id: $0, hash: hashes[$0]) }
    }

    static let csvHeader = "sensor,client,display_name,responsible,start,end,activation_count,event_refs"
    var csvRow: String {
        CSV.line([
            sensor, client, displayName, responsible, iso8601Fractional(start),
            end.map { iso8601Fractional($0) }, String(activationCount),
            eventRefs.map { "\($0.id):\($0.hash ?? "")" }.joined(separator: ";")
        ])
    }
}
