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

@Test func anEditedExportedRowIsFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    var rows = try JSONDecoder().decode(
        [ExportedRow].self, from: Data(contentsOf: directory.appending(path: "raw_events.json")))
    rows[10] = ExportedRow(
        id: rows[10].id, timeMicros: rows[10].timeMicros, source: rows[10].source, dedupKey: rows[10].dedupKey,
        prevHash: rows[10].prevHash, hash: rows[10].hash, message: rows[10].message + " tampered")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(rows).write(to: directory.appending(path: "raw_events.json"))

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem == .hashMismatch(id: rows[10].id))
    #expect(!report.isIntact)
}

@Test func aDroppedExportedRowIsFlagged() throws {
    let (temporary, directory) = try recorded()
    try AuditExport.write(store: temporary.store, from: .distantPast, to: .distantFuture, to: directory)

    var rows = try JSONDecoder().decode(
        [ExportedRow].self, from: Data(contentsOf: directory.appending(path: "raw_events.json")))
    rows.remove(at: 10)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(rows).write(to: directory.appending(path: "raw_events.json"))

    let report = try AuditExport.verify(directory: directory)
    #expect(report.problem != nil || report.headMismatch)
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
