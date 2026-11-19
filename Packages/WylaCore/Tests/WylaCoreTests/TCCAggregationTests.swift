import Foundation
import GRDB
import Testing

@testable import WylaCore

private let main = "27.3-26C5035r"

private func request(
    _ identifier: String? = "com.example.app", service: String = "kTCCServiceCamera", authValue: Int = 2,
    messageID: String? = nil, at time: Date, entryID: String? = nil
) -> TCCRequest {
    TCCRequest(
        messageID: messageID ?? UUID().uuidString, time: time, service: service,
        responsible: identifier.map { TCCProcess(identifier: $0, pid: 1, binaryPath: nil) },
        accessing: nil, requesting: nil, authValue: authValue, entryID: entryID)
}

@Test func requestsAreCountedPerMinuteClientServiceAndResult() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(.tccRequest(request(at: start)))
    try recorder.record(.tccRequest(request(at: start)))
    // A different result and client each get their own bucket.
    try recorder.record(.tccRequest(request(authValue: 0, at: start)))
    try recorder.record(.tccRequest(request("com.example.other", at: start)))
    // And different minutes their own rows.
    try recorder.record(.tccRequest(request(at: start.addingTimeInterval(30))))
    try recorder.record(.tccRequest(request(at: start.addingTimeInterval(90))))

    let rows = try temporary.rows("SELECT * FROM tcc_requests_agg ORDER BY minute_us, client, auth_value")
    let minute = Int64((start.timeIntervalSince1970 / 60).rounded(.down)) * 60_000_000
    let summary = rows.map { "\($0["minute_us"] as Int64)|\($0["client"] as String)|\($0["auth_value"] as Int)=\($0["count"] as Int)" }
    #expect(rows.count == 4)
    #expect(summary[0] == "\(minute)|com.example.app|0=1")
    #expect(summary[1] == "\(minute)|com.example.app|2=3")
    #expect(summary[2] == "\(minute)|com.example.other|2=1")
    #expect(summary[3] == "\(minute + 60_000_000)|com.example.app|2=1")
}

@Test func requestWithoutAResponsibleAppCountsAsEmptyClient() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(.tccRequest(request(nil, at: start)))
    #expect(try temporary.store.tccRequestTotals().map(\.client) == [""])
}

@Test func theSameRequestFromBackfillAndTheLiveStreamCountsOnce() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    let delivered = request(messageID: "msg-42", at: start)
    try recorder.record(.tccRequest(delivered))
    // The request reaches the recorder again — `log show` backfill and `log stream` overlap.
    try recorder.record(.tccRequest(delivered))
    // And once more after a restart.
    let restarted = try Recorder(store: temporary.store, startingAt: start.addingTimeInterval(5))
    try restarted.record(.tccRequest(delivered))
    #expect(try temporary.rows("SELECT count FROM tcc_requests_agg").map { $0["count"] as Int } == [1])
}

@Test func aMessageIDReusedAfterARestartCountsEachRequest() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    // The log's msgID is `pid.counter`: a process that restarts, or a reboot, reuses it. The
    // request's time disambiguates, so the reused ID at a different time is a real request —
    // while the same ID at the same time is the duplicate it was deduplicated for.
    try recorder.record(.tccRequest(request(messageID: "1.2", at: start)))
    try recorder.record(.tccRequest(request(messageID: "1.2", at: start.addingTimeInterval(120))))
    try recorder.record(.tccRequest(request(messageID: "1.2", at: start.addingTimeInterval(130))))
    try recorder.record(.tccRequest(request(messageID: "1.2", at: start.addingTimeInterval(130))))
    #expect(
        try temporary.rows("SELECT count FROM tcc_requests_agg ORDER BY count")
            .map { $0["count"] as Int } == [1, 2])
}

@Test func aMigratedRequestClaimedByItsEntryIDCountsOnce() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    // A request stored before entryIDs existed dedups on its wall time…
    try recorder.record(.tccRequest(request(messageID: "1.2", at: start)))
    // …and its `log stream` replay carries the entry's mach time and a wall time ~1 ms off.
    try recorder.record(
        .tccRequest(request(messageID: "1.2", at: start.addingTimeInterval(0.001), entryID: "mach-9")))
    let rows = try temporary.rows("SELECT dedup_id FROM tcc_requests")
    #expect(rows.map { $0["dedup_id"] as String } == ["mach-9"])
    #expect(try temporary.rows("SELECT count FROM tcc_requests_agg").map { $0["count"] as Int } == [1])
}

@Test func requestsWithoutARawEventAreNotInTheChain() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(.tccRequest(request(at: start)))
    try recorder.record(.tccRequest(request(at: start.addingTimeInterval(30))))
    // Counted, but not chained: no activation linked to them.
    #expect(try temporary.rows("SELECT * FROM raw_events WHERE source = 'tcc'").isEmpty)
    #expect(try temporary.rows("SELECT * FROM tcc_requests").count == 2)
    #expect(try temporary.rows("SELECT * FROM tcc_requests WHERE raw_event_id IS NOT NULL").isEmpty)
}

@Test func theSameEntryWithADriftedWallTimeCountsOnce() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    // `log show` backfill and `log stream` report the same CTX entry ~1 ms apart in wall time
    // but with the same mach time: the entryID, not the wall time, is the dedup identity.
    try recorder.record(.tccRequest(request(messageID: "1.2", at: start, entryID: "mach-7")))
    try recorder.record(
        .tccRequest(request(messageID: "1.2", at: start.addingTimeInterval(0.001), entryID: "mach-7")))
    #expect(try temporary.rows("SELECT count FROM tcc_requests_agg").map { $0["count"] as Int } == [1])
}

@Test func aRequestCompletedLateIsStillCounted() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    // A newer event moves the applied-to point past the request's CTX timestamp before the
    // request's result arrives — the check is slow, its request is not a duplicate.
    try recorder.record(
        .indicator(
            LogEvent(timestamp: start.addingTimeInterval(10), message: "Active activity attributions changed to []", entryID: "1")))
    try recorder.record(.tccRequest(request(at: start)))
    #expect(try temporary.rows("SELECT count FROM tcc_requests_agg").map { $0["count"] as Int } == [1])
}

@Test func totalsGroupTheMinutesPerClientAndService() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(.tccRequest(request(at: start)))
    try recorder.record(.tccRequest(request(service: "kTCCServiceScreenCapture", at: start)))
    try recorder.record(.tccRequest(request(at: start.addingTimeInterval(30))))
    try recorder.record(.tccRequest(request(authValue: 0, at: start.addingTimeInterval(60))))

    let totals = try temporary.store.tccRequestTotals()
    #expect(totals.count == 2)
    let camera = try #require(totals.first { $0.service == "kTCCServiceCamera" })
    #expect(camera.allowed == 2)
    #expect(camera.denied == 1)
    #expect(camera.total == 3)
    #expect(camera.firstSeen == start)
    #expect(camera.lastSeen == start.addingTimeInterval(60))
    #expect(camera.sensor == .camera)
    #expect(totals.first { $0.service == "kTCCServiceScreenCapture" }?.total == 1)
}

@Test func v3BackfillIgnoresDuplicateRequestRows() throws {
    // A database at v2 holding tcc raw events: a real second request after the pid.counter
    // restarted (same msgID, different time), and a duplicate of it (same msgID and time, a
    // different pid in the stored JSON).
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "wyla-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "wyla.sqlite")
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    try Schema.migrator.migrate(queue, upTo: "v2")

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func json(messageID: String, at time: Date, pid: Int = 1) throws -> String {
        try canonicalJSON(
            TCCRequest(
                messageID: messageID, time: time, service: "kTCCServiceCamera",
                responsible: TCCProcess(identifier: "com.example.app", pid: pid, binaryPath: nil),
                accessing: nil, requesting: nil, authValue: 2))
    }
    try queue.write { db in
        _ = try EventStore.append(
            .tcc, time: start, identity: nil, message: json(messageID: "1.2", at: start), in: db)
        _ = try EventStore.append(
            .tcc, time: start.addingTimeInterval(60), identity: nil,
            message: json(messageID: "1.2", at: start.addingTimeInterval(60)), in: db)
        _ = try EventStore.append(
            .tcc, time: start.addingTimeInterval(60), identity: nil,
            message: json(messageID: "1.2", at: start.addingTimeInterval(60), pid: 2), in: db)
    }

    try Schema.migrator.migrate(queue)
    // Three source rows, two distinct requests: the same-time duplicate is ignored.
    let requests = try queue.read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM tcc_requests")
    }
    let counts = try queue.read { db in
        try Row.fetchAll(db, sql: "SELECT count FROM tcc_requests_agg ORDER BY count")
    }
    #expect(requests.count == 2)
    #expect(counts.map { $0["count"] as Int } == [1, 1])
}

@Test func aDatabaseMigratedWithTheFirstV3GainsDedupID() throws {
    // A database that ran the first pushed revision of v3 has tcc_requests keyed on
    // (message_id, time_us); v4 rebuilds it with dedup_id so counting keeps working.
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "wyla-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "wyla.sqlite")
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    try Schema.migrator.migrate(queue, upTo: "v2")
    try queue.write { db in
        try db.execute(
            sql: """
                CREATE TABLE tcc_requests (
                    message_id TEXT NOT NULL,
                    time_us INTEGER NOT NULL,
                    raw_event_id INTEGER REFERENCES raw_events(id),
                    PRIMARY KEY (message_id, time_us)
                ) WITHOUT ROWID;
                INSERT INTO tcc_requests (message_id, time_us) VALUES ('1.2', 1800000000000000);
                INSERT INTO grdb_migrations (identifier) VALUES ('v3');
                """)
    }
    try Schema.migrator.migrate(queue)
    let recorder = try Recorder(store: EventStore(url: url), startingAt: Date(timeIntervalSince1970: 1_800_000_000))
    try recorder.record(.tccRequest(request(messageID: "3.4", at: Date(timeIntervalSince1970: 1_800_000_010))))
    let rows = try queue.read { try Row.fetchAll($0, sql: "SELECT dedup_id FROM tcc_requests ORDER BY dedup_id") }
    #expect(rows.count == 2)
}

@Test func dailyTotalsBucketMinutesByLocalDay() throws {
    let temporary = try TemporaryStore()
    let noon = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
    let recorder = try Recorder(store: temporary.store, startingAt: noon)
    try recorder.record(.tccRequest(request(at: noon)))
    try recorder.record(.tccRequest(request(authValue: 0, at: noon)))
    try recorder.record(.tccRequest(request(at: noon.addingTimeInterval(-24 * 3600))))
    try recorder.record(.tccRequest(request("com.example.other", at: noon)))

    let daily = try temporary.store.tccRequestDaily(client: "com.example.app", service: "kTCCServiceCamera")
    let yesterday = Calendar.current.startOfDay(for: noon.addingTimeInterval(-24 * 3600))
    let today = Calendar.current.startOfDay(for: noon)
    #expect(
        daily.map { "\(Int($0.day.timeIntervalSince1970))|\($0.result)=\($0.count)" } == [
            "\(Int(yesterday.timeIntervalSince1970))|allowed=1",
            "\(Int(today.timeIntervalSince1970))|allowed=1",
            "\(Int(today.timeIntervalSince1970))|denied=1"
        ])
    // The other client's checks don't leak in.
    #expect(try temporary.store.tccRequestDaily(client: "com.example.other", service: "kTCCServiceCamera").count == 1)
}

@Test func captureRequestTotalsMatchTheCompletedRequests() throws {
    let capture = try CaptureFixture(main)
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)

    var expected: [String: Int] = [:]
    for input in capture.recorderInputs {
        guard case .tccRequest(let request) = input else { continue }
        let key = "\(request.responsibleApp?.identifier ?? "")|\(request.service)|\(request.authValue)"
        expected[key, default: 0] += 1
    }
    var stored: [String: Int] = [:]
    for summary in try temporary.store.tccRequestTotals() {
        stored["\(summary.client)|\(summary.service)|2"] = summary.allowed
        stored["\(summary.client)|\(summary.service)|0"] = summary.denied
        stored["\(summary.client)|\(summary.service)|1"] = summary.unknown
        stored["\(summary.client)|\(summary.service)|3"] = summary.limited
    }
    #expect(stored.filter { $0.value > 0 } == expected)
}
