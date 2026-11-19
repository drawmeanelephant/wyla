import Foundation
import GRDB
import Testing
import WylaCore

private let main = "27.3-26C5035r"

private func request(
    _ identifier: String? = "com.example.app", service: String = "kTCCServiceCamera", authValue: Int = 2,
    messageID: String? = nil, at time: Date
) -> TCCRequest {
    TCCRequest(
        messageID: messageID ?? UUID().uuidString, time: time, service: service,
        responsible: identifier.map { TCCProcess(identifier: $0, pid: 1, binaryPath: nil) },
        accessing: nil, requesting: nil, authValue: authValue)
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
