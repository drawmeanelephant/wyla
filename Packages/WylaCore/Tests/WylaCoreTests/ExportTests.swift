import CryptoKit
import Foundation
import GRDB
import Testing
import WylaCore

/// A store holding the main M0 capture plus a temp directory for exports.
private let captureName = "27.3-26C5035r"

private func recorded() throws -> (TemporaryStore, URL) {
    let capture = try CaptureFixture(captureName)
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)
    return (temporary, temporary.directory.appending(path: "export"))
}

@Test func anExportVerifiesAgainstItsManifest() throws {
    let (temporary, directory) = try recorded()
    let manifest = try AuditExport.write(
        store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    let rows = try temporary.rows("SELECT count(*) AS n FROM raw_events")
    #expect(manifest.rowCount == (rows[0]["n"] as Int))
    #expect(manifest.head != nil)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "raw_events.csv").path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "sessions.json").path(percentEncoded: false)))

    let report = try AuditExport.verify(directory: directory)
    #expect(report.isIntact)
    #expect(report.verifiedRows == manifest.rowCount)
}

@Test func anExportCoversOnlyTheGivenRange() throws {
    let (temporary, directory) = try recorded()
    let rows = try temporary.rows("SELECT min(time_us) AS lo, max(time_us) AS hi FROM raw_events")
    let midpoint = ((rows[0]["lo"] as Int64) + (rows[0]["hi"] as Int64)) / 2
    let manifest = try AuditExport.write(
        store: temporary.store, from: .distantPast,
        to: Date(timeIntervalSince1970: Double(midpoint) / 1_000_000), to: directory)

    let expected = try temporary.rows("SELECT count(*) AS n FROM raw_events WHERE time_us <= \(midpoint)")
    #expect(manifest.rowCount == (expected[0]["n"] as Int))
    #expect(try AuditExport.verify(directory: directory).isIntact)
}

/// Rewrites `raw_events.json` in `directory` after `edit` changes the rows, then updates
/// `manifest.json` to the edited count and head — the forgery a tamperer must produce.
private func rewriteExport(
    in directory: URL, rows edit: (inout [ExportedRow]) -> Void
) throws {
    var rows = try JSONDecoder().decode(
        [ExportedRow].self, from: Data(contentsOf: directory.appending(path: "raw_events.json")))
    edit(&rows)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(rows).write(to: directory.appending(path: "raw_events.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var manifest = try decoder.decode(
        ExportManifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    manifest = ExportManifest(
        exportedAt: manifest.exportedAt, from: manifest.from, end: manifest.end,
        head: rows.last.map { ChainAnchor(id: $0.id, hash: $0.hash) }, rowCount: rows.count,
        sessionCount: manifest.sessionCount)
    try encoder.encode(manifest).write(to: directory.appending(path: "manifest.json"))
}

/// Re-links `rows` after rows were deleted: the row after a removed one chains to the row
/// before it, and every hash from there on is recomputed — a consistent chain with a gap.
/// The SHA-256 of a chain row, per the format in docs/SPEC.md (the hash builder itself is
/// internal to WylaCore, so the test recomputes it).
private func forgeHash(_ row: ExportedRow, prevHash: String) -> String {
    let text = "\(row.id)\n\(row.timeMicros)\n\(row.source)\n\(row.dedupKey)\n\(prevHash)\n\(row.message)"
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func relink(_ rows: inout [ExportedRow]) {
    var previous: ChainAnchor?
    for index in rows.indices {
        let prevHash = previous?.hash ?? String(repeating: "0", count: 64)
        let row = rows[index]
        let hash = forgeHash(row, prevHash: prevHash)
        rows[index] = ExportedRow(
            id: row.id, timeMicros: row.timeMicros, source: row.source, dedupKey: row.dedupKey,
            prevHash: prevHash, hash: hash, message: row.message)
        previous = ChainAnchor(id: row.id, hash: hash)
    }
}

@Test func anEditedExportedRowIsFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    var editedID: Int64 = 0
    try rewriteExport(in: directory) { rows in
        rows[10] = ExportedRow(
            id: rows[10].id, timeMicros: rows[10].timeMicros, source: rows[10].source, dedupKey: rows[10].dedupKey,
            prevHash: rows[10].prevHash, hash: rows[10].hash, message: rows[10].message + " tampered")
        editedID = rows[10].id
    }

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem == .hashMismatch(id: editedID))
    #expect(!report.isIntact)
}

@Test func aDroppedExportedRowIsFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    try rewriteExport(in: directory) { $0.remove(at: 10) }

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem != nil || report.headMismatch)
    #expect(!report.isIntact)
}

@Test func aRelinkedMiddleGapIsFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    var after: Int64 = 0
    var next: Int64 = 0
    try rewriteExport(in: directory) { rows in
        after = rows[9].id
        next = rows[11].id
        rows.remove(at: 10)
        relink(&rows)
    }

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem == .missingRows(after: after, next: next))
    #expect(!report.isIntact)
}

@Test func aDeletedTailWithAnEditedManifestIsFlaggedByTheAnchor() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)
    let head = try #require(try temporary.store.head())
    // A day inside the exported range anchors the last row; the day names are arbitrary here
    // because the export covers all days.
    let anchors = [("2000-01-01", head), ("2999-01-01", head)]

    try rewriteExport(in: directory) { $0.removeLast() }

    let report = try AuditExport.verify(directory: directory, anchors: anchors)
    #expect(report.problem == .anchorMismatch(head))
    #expect(!report.isIntact)
}

@Test func anEmptiedExportIsFlaggedByTheAnchor() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)
    let head = try #require(try temporary.store.head())
    let anchors = [("2000-01-01", head)]

    try rewriteExport(in: directory) { $0.removeAll() }

    let report = try AuditExport.verify(directory: directory, anchors: anchors)
    #expect(report.problem == .anchorMismatch(head))
    #expect(!report.isIntact)
}

@Test func aBackfilledRowOutsideTheRangeIsSkippedNotLeaked() throws {
    let temporary = try TemporaryStore()
    let day = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: day)
    let indicator = { (time: Date) in
        LogEvent(
            timestamp: time, message: "Active activity attributions changed to [\"scr:com.apple.Safari\"]",
            entryID: UUID().uuidString)
    }
    try recorder.record(.indicator(indicator(day)))
    // A late-arriving line gets a new id between the in-range rows but an older timestamp.
    try recorder.record(
        .unparsedTCC(
            LogEvent(
                timestamp: day - 86_400, message: "AUTHREQ_RESULT: garbage", entryID: UUID().uuidString)))
    try recorder.record(.indicator(indicator(day.addingTimeInterval(10))))

    let manifest = try AuditExport.write(
        store: temporary.store, from: day - 3600, to: day + 3600, to: temporary.directory.appending(path: "export"))

    #expect(manifest.rowCount == 2)
    #expect(manifest.skipped.count == 1)
    let rows = try JSONDecoder().decode(
        [ExportedRow].self,
        from: Data(contentsOf: temporary.directory.appending(path: "export/raw_events.json")))
    #expect(!rows.contains(where: { $0.id == manifest.skipped[0].id }))
    #expect(try AuditExport.verify(directory: temporary.directory.appending(path: "export")).isIntact)
}

@Test func rowsAddedToAnEmptiedManifestAreFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var rows = try decoder.decode(
        [ExportedRow].self, from: Data(contentsOf: directory.appending(path: "raw_events.json")))
    let manifest = try decoder.decode(
        ExportManifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    rows = Array(rows.prefix(1))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(rows).write(to: directory.appending(path: "raw_events.json"))
    // The forged manifest claims the export is empty; the count mismatch must survive the walk.
    let emptied = ExportManifest(
        exportedAt: manifest.exportedAt, from: manifest.from, end: manifest.end,
        head: nil, rowCount: 0, sessionCount: 0)
    try encoder.encode(emptied).write(to: directory.appending(path: "manifest.json"))

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem == .countMismatch(found: 1, manifest: 0, atRow: rows[0].id))
    #expect(!report.isIntact)
}

@Test func aSameDayExportDoesNotFlagItsOwnAnchor() throws {
    let (temporary, directory) = try recorded()
    let rows = try temporary.rows("SELECT min(time_us) AS lo FROM raw_events")
    let start = Date(timeIntervalSince1970: Double(try #require(rows[0]["lo"] as Int64?)) / 1_000_000)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    let from = try #require(formatter.date(from: formatter.string(from: start)))
    // The export starts at UTC midnight of its day but ends before the day does, so the day's
    // own anchor — written at day end — is legitimately missing.
    try AuditExport.write(
        store: temporary.store, from: from, to: from.addingTimeInterval(43_200), to: directory)
    let head = try #require(try temporary.store.head())
    let anchors = [(formatter.string(from: from), head)]

    #expect(try AuditExport.verify(directory: directory, anchors: anchors).isIntact)
}

@Test func anAnchorPointingBeforeTheExportDoesNotFlagIt() throws {
    let (temporary, directory) = try recorded()
    let rows = try temporary.rows("SELECT min(time_us) AS lo, max(time_us) AS hi FROM raw_events")
    let midpoint = ((rows[0]["lo"] as Int64) + (rows[0]["hi"] as Int64)) / 2
    let from = Date(timeIntervalSince1970: Double(midpoint) / 1_000_000)
    try AuditExport.write(store: temporary.store, from: from, to: .distantFuture, to: directory)
    let head = try #require(try temporary.store.head())
    // A quiet day carries the previous head forward, so a covered day's anchor can point to a
    // row before the first exported one.
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    let anchors = [(formatter.string(from: from.addingTimeInterval(86_400)), ChainAnchor(id: 1, hash: head.hash))]

    #expect(try AuditExport.verify(directory: directory, anchors: anchors).isIntact)
}

@Test func aPartialDayExportDoesNotFlagALaterSameDayAnchor() throws {
    let (temporary, directory) = try recorded()
    let rows = try temporary.rows("SELECT min(time_us) AS lo, max(time_us) AS hi FROM raw_events")
    let midpoint = ((rows[0]["lo"] as Int64) + (rows[0]["hi"] as Int64)) / 2
    let end = Date(timeIntervalSince1970: Double(midpoint) / 1_000_000)
    try AuditExport.write(store: temporary.store, from: .distantPast, to: end, to: directory)
    let head = try #require(try temporary.store.head())
    // An anchor written the same UTC day but after the export's end is legitimately missing.
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    let anchors = [(formatter.string(from: end), head)]

    #expect(try AuditExport.verify(directory: directory, anchors: anchors).isIntact)
}

@Test func aForgedFirstRowIsFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    try rewriteExport(in: directory) { rows in
        rows[0] = ExportedRow(
            id: rows[0].id, timeMicros: rows[0].timeMicros, source: rows[0].source, dedupKey: rows[0].dedupKey,
            prevHash: String(repeating: "f", count: 64), hash: rows[0].hash, message: rows[0].message)
    }

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem == .brokenLink(id: 1))
    #expect(!report.isIntact)
}

@Test func anchorsSaveOnceADayAndTheLatestOneIsReadBack() throws {
    let (temporary, directory) = try recorded()
    let url = directory.appending(path: "anchors.log")
    let head = try #require(try temporary.store.head())
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(try AnchorLog.append(head: head, at: day, to: url))
    // The same day doesn't append twice.
    #expect(try !AnchorLog.append(head: head, at: day.addingTimeInterval(3600), to: url))
    #expect(try AnchorLog.append(head: head, at: day.addingTimeInterval(90_000), to: url))
    #expect(try AnchorLog.read(from: url).count == 2)
    #expect(try AnchorLog.latest(from: url) == head)
}

@Test func settingsRoundTripThroughTheFile() throws {
    let temporary = try TemporaryStore()
    let url = temporary.directory.appending(path: "settings.json")
    var settings = Settings()
    settings.mergeWindow = 7
    settings.anchorExportEnabled = true
    try settings.save(to: url)
    #expect(Settings.load(from: url) == settings)
    #expect(Settings.load(from: temporary.directory.appending(path: "absent.json")) == Settings())
}

@Test func theFirstUseOfASensorByAnAppHasCountOne() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    let indicator = { (time: Date, clients: String) in
        LogEvent(
            timestamp: time, message: "Active activity attributions changed to [\(clients)]",
            entryID: UUID().uuidString)
    }
    try recorder.record(.indicator(indicator(start, "\"scr:com.apple.Safari\"")))
    #expect(try temporary.store.activationCount(sensor: .screen, client: "com.apple.Safari") == 1)
    try recorder.record(.indicator(indicator(start.addingTimeInterval(10), "")))
    try recorder.record(.indicator(indicator(start.addingTimeInterval(20), "\"scr:com.apple.Safari\"")))
    #expect(try temporary.store.activationCount(sensor: .screen, client: "com.apple.Safari") == 2)
}

@Test func coverageReportsTheRunsAndLeavesGapsBetweenThem() throws {
    let temporary = try TemporaryStore()
    let day = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try Recorder(store: temporary.store, startingAt: day)
    _ = try Recorder(store: temporary.store, startingAt: day.addingTimeInterval(100))
    let coverage = try temporary.store.coverage()
    #expect(coverage.count == 2)
    #expect(coverage[0].end == day)
    #expect(coverage[1].start == day.addingTimeInterval(100))
}
