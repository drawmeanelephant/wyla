import CryptoKit
import Foundation
import GRDB
import Testing
import WylaCore

/// A store holding the main M0 capture.
private func recordedStore() throws -> TemporaryStore {
    let capture = try CaptureFixture("27.3-26C5035r")
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)
    return temporary
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test func defaultLocationIsTheAppSupportFolder() {
    #expect(
        EventStore.defaultURL.path(percentEncoded: false).hasSuffix(
            "/Library/Application Support/io.github.drawmeanelephant.wyla/wyla.sqlite"))
}

@Test func databaseIsPrivateAndUsesWAL() throws {
    let temporary = try recordedStore()
    let files = FileManager.default
    func permissions(_ url: URL) throws -> Int {
        try #require(files.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
    }
    #expect(try permissions(temporary.directory) == 0o700)
    #expect(try permissions(temporary.url) == 0o600)
    #expect(try permissions(URL(filePath: temporary.url.path(percentEncoded: false) + "-wal")) == 0o600)
    #expect(try temporary.rows("PRAGMA journal_mode").first?[0] == "wal")
}

@Test func reopeningKeepsTheDataAndSchema() throws {
    let temporary = try recordedStore()
    let before = try temporary.contents()
    let reopened = try EventStore(url: temporary.url)
    #expect(try temporary.contents() == before)
    #expect(try reopened.verifyIntegrity().isIntact)
    #expect(try reopened.head() == temporary.store.head())
}

@Test func chainFollowsTheDocumentedFormat() throws {
    let temporary = try recordedStore()
    // Indicator rows are identified by their log entry, which the row doesn't store.
    var entryIDs: [String: String] = [:]
    for case .indicator(let event) in try CaptureFixture("27.3-26C5035r").recorderInputs {
        entryIDs["\(Int64((event.timestamp.timeIntervalSince1970 * 1_000_000).rounded()))|\(event.message)"] = event.entryID
    }
    var previous = String(repeating: "0", count: 64)
    let rows = try temporary.rows("SELECT * FROM raw_events ORDER BY id")
    // Indicators and hardware changes are chained; of the TCC requests only the ones that
    // linked an activation to its responsible app are — the rest are counted, not stored.
    let linked =
        try temporary.rows(
            "SELECT count(DISTINCT responsible_event_id) AS n FROM activations WHERE responsible_event_id IS NOT NULL"
        )[0]["n"] as Int
    let chainedTCC = try temporary.rows("SELECT count(*) AS n FROM raw_events WHERE source = 'tcc'")[0]["n"] as Int
    let parser = IndicatorParser()
    let nonTCC = try CaptureFixture("27.3-26C5035r").recorderInputs.filter {
        switch $0 {
        case .indicator(let event):
            if case .ignored = parser.parse(event.message) { false } else { true }
        case .hardware: true
        case .tccRequest: false
        }
    }.count
    #expect(chainedTCC == linked)
    #expect(rows.count == nonTCC + linked)
    for (index, row) in rows.enumerated() {
        let id: Int64 = row["id"]
        let time: Int64 = row["time_us"]
        let source: String = row["source"]
        let message: String = row["message"]
        let identity = source == "indicator" ? try #require(entryIDs["\(time)|\(message)"]) : String(time)
        let dedupKey = sha256("\(source)\n\(identity)\n\(message)")
        #expect(id == Int64(index + 1))
        #expect(row["dedup_key"] == dedupKey)
        #expect(row["prev_hash"] == previous)
        previous = sha256("\(id)\n\(time)\n\(source)\n\(dedupKey)\n\(previous)\n\(message)")
        #expect(row["hash"] == previous)
    }
    #expect(try temporary.store.head() == ChainAnchor(id: Int64(rows.count), hash: previous))
}

@Test func triggersRejectUpdatesDeletesAndOutOfChainInserts() throws {
    let temporary = try recordedStore()
    let queue = try DatabaseQueue(path: temporary.url.path(percentEncoded: false))
    let attempts = [
        "UPDATE raw_events SET message = 'edited' WHERE id = 5",
        "DELETE FROM raw_events WHERE id = 5",
        "DELETE FROM raw_events",
        "INSERT INTO raw_events (time_us, source, message, dedup_key, prev_hash, hash) VALUES (0, 'hardware', 'x', 'k', 'p', 'h')"
    ]
    for sql in attempts {
        let error = #expect(throws: DatabaseError.self) { try queue.write { db in try db.execute(sql: sql) } }
        let message = error?.message ?? ""
        #expect(message.contains("append-only") || message.contains("must extend the hash chain"), "\(sql): \(message)")
    }
    #expect(try temporary.store.verifyIntegrity().isIntact)
}

@Test func editedRowIsDetected() throws {
    let temporary = try recordedStore()
    try temporary.tamper("UPDATE raw_events SET message = message || ' ' WHERE id = 5")
    let report = try temporary.store.verifyIntegrity()
    #expect(report.problem == .hashMismatch(id: 5))
    #expect(report.problem?.firstBadRow == 5)
    #expect(report.verifiedRows == 4)
}

@Test func editedRowWithRecomputedHashIsDetectedAtTheNextRow() throws {
    let temporary = try recordedStore()
    let row = try #require(try temporary.rows("SELECT * FROM raw_events WHERE id = 5").first)
    let message = "forged"
    let time: Int64 = row["time_us"]
    let source: String = row["source"]
    let dedupKey = sha256("\(source)\n\(time)\n\(message)")
    let hash = sha256("5\n\(time)\n\(source)\n\(dedupKey)\n\(row["prev_hash"] as String)\n\(message)")
    try temporary.tamper(
        "UPDATE raw_events SET message = ?, dedup_key = ?, hash = ? WHERE id = 5", arguments: [message, dedupKey, hash])
    #expect(try temporary.store.verifyIntegrity().problem == .brokenLink(id: 6))
}

@Test func deletedRowIsDetected() throws {
    let temporary = try recordedStore()
    try temporary.tamper("DELETE FROM raw_events WHERE id = 5")
    let report = try temporary.store.verifyIntegrity()
    #expect(report.problem == .missingRows(after: 4, next: 6))
    #expect(report.problem?.firstBadRow == 6)
}

@Test func deletedFirstRowIsDetected() throws {
    let temporary = try recordedStore()
    try temporary.tamper("DELETE FROM raw_events WHERE id = 1")
    #expect(try temporary.store.verifyIntegrity().problem == .missingRows(after: 0, next: 2))
}

@Test func insertedRowIsDetected() throws {
    let temporary = try recordedStore()
    // Make room at id 5 and insert a row that chains correctly onto row 4.
    let previous: String = try #require(try temporary.rows("SELECT hash FROM raw_events WHERE id = 4").first?["hash"])
    let (time, source, message) = (
        Int64(1_795_000_000_000_000), "indicator", #"Active activity attributions changed to ["cam:com.example.Forged"]"#
    )
    let dedupKey = sha256("\(source)\n\(time)\n\(message)")
    let hash = sha256("5\n\(time)\n\(source)\n\(dedupKey)\n\(previous)\n\(message)")
    try temporary.tamper(
        """
        UPDATE raw_events SET id = -id WHERE id >= 5;
        UPDATE raw_events SET id = 1 - id WHERE id < 0;
        INSERT INTO raw_events VALUES (5, ?, ?, ?, ?, ?, ?);
        """,
        arguments: [time, source, message, dedupKey, previous, hash])
    let report = try temporary.store.verifyIntegrity()
    #expect(report.problem == .brokenLink(id: 6))
    #expect(report.verifiedRows == 5)
}

@Test func appendedForgedRowIsDetected() throws {
    let temporary = try recordedStore()
    let head = try #require(try temporary.store.head())
    try temporary.tamper(
        "INSERT INTO raw_events VALUES (?, 0, 'hardware', 'camera Forged on', 'key', ?, 'hash')",
        arguments: [head.id + 1, String(repeating: "1", count: 64)])
    #expect(try temporary.store.verifyIntegrity().problem == .brokenLink(id: head.id + 1))
}

@Test func truncationIsDetectedWithASavedAnchor() throws {
    let temporary = try recordedStore()
    let head = try #require(try temporary.store.head())
    try temporary.tamper("DELETE FROM raw_events WHERE id > ?", arguments: [head.id - 3])

    let unanchored = try temporary.store.verifyIntegrity()
    #expect(unanchored.isIntact)
    #expect(unanchored.head?.id == head.id - 3)
    let anchored = try temporary.store.verifyIntegrity(anchor: head)
    #expect(anchored.problem == .anchorMismatch(head))
    #expect(anchored.problem?.firstBadRow == head.id)
    #expect(try temporary.store.verifyIntegrity(anchor: unanchored.head).isIntact)
}

@Test func emptyStoreIsIntact() throws {
    let temporary = try TemporaryStore()
    let report = try temporary.store.verifyIntegrity()
    #expect(report.isIntact)
    #expect(report.verifiedRows == 0)
    #expect(report.head == nil)
    #expect(try temporary.store.head() == nil)
    #expect(try temporary.store.checkpoint(for: .indicator) == nil)
}
