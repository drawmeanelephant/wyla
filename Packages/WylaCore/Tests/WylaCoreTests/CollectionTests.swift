import Foundation
import GRDB
import Testing
import WylaCore

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func hardware(_ seconds: TimeInterval, _ device: String = "Cam") -> RecorderInput {
    .hardware(HardwareChange(time: base.addingTimeInterval(seconds), sensor: .camera, device: device, isRunning: true))
}

@Test func logLinesCarryTheirSourceAndEntryID() throws {
    let line = try String(contentsOf: CaptureFixture.url("sensor-indicators-27.3-26C5035r", "ndjson"), encoding: .utf8)
        .split(separator: "\n").first { $0.hasPrefix("{") }
    guard case .event(let event) = LogLine(parsing: try #require(line)) else {
        Issue.record("first JSON line did not parse")
        return
    }
    #expect(event.subsystem == "com.apple.controlcenter")
    #expect(event.category == "sensor-indicators")
    #expect(try #require(event.entryID).wholeMatch(of: /\d+/) != nil)
}

@Test func routerSplitsTheCombinedStream() throws {
    let indicator = LogEvent(
        timestamp: base, message: #"Active activity attributions changed to []"#, subsystem: "com.apple.controlcenter",
        category: "sensor-indicators")
    let tcc = { (message: String) in
        LogEvent(timestamp: base, message: message, subsystem: "com.apple.TCC", category: "access")
    }
    var router = LogRouter()
    #expect(router.route(indicator) == .indicator(indicator))
    #expect(router.route(LogEvent(timestamp: base, message: "x", subsystem: "com.apple.other", category: "access")) == nil)
    #expect(router.route(tcc("AUTHREQ_CTX: msgID=1.2, function=f, service=kTCCServiceCamera, preflight=no")) == nil)
    guard case .unparsedTCC = router.route(tcc("AUTHREQ_RESULT: garbage")) else {
        Issue.record("unparsed TCC line was not routed as unparsedTCC")
        return
    }
    guard case .tccRequest(let request) = router.route(tcc("AUTHREQ_RESULT: msgID=1.2, authValue=2, authReason=4")) else {
        Issue.record("completed request was not routed")
        return
    }
    #expect(request.service == "kTCCServiceCamera")
    #expect(request.authValue == 2)
}

@Test func routedFixtureLinesRecordTheSameActivations() throws {
    var events: [LogEvent] = []
    for name in ["sensor-indicators-27.3-26C5035r", "tcc-access-27.3-26C5035r"] {
        for line in try String(contentsOf: CaptureFixture.url(name, "ndjson"), encoding: .utf8).split(separator: "\n") {
            if case .event(let event) = LogLine(parsing: line) { events.append(event) }
        }
    }
    let capture = try CaptureFixture("27.3-26C5035r")
    var router = LogRouter()
    var inputs = events.sorted { $0.timestamp < $1.timestamp }.compactMap { router.route($0) }
    inputs += capture.recorderInputs.filter { if case .hardware = $0 { true } else { false } }
    inputs = inputs.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)

    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: base).record(inputs)
    #expect(summaries(try temporary.store.activations()) == summaries(capture.activations()))
}

@Test func showArgumentsStartAtTheLocalSecondBefore() {
    let zone = TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt
    let arguments = LogQuery.showArguments(from: Date(timeIntervalSince1970: 1_795_000_000.5), timeZone: zone)
    #expect(arguments.prefix(5) == ["show", "--style", "ndjson", "--info", "--start"])
    #expect(arguments[5] == "2026-11-18 06:06:39-0500")
    #expect(arguments.last == LogQuery.predicate)
    #expect(LogQuery.streamArguments.contains("--level"))
}

@Test func reorderBufferReleasesInTimeOrderAfterTheDelay() {
    var buffer = ReorderBuffer(delay: 1)
    buffer.insert(hardware(2.0, "B"))
    buffer.insert(hardware(1.5, "A"))
    buffer.insert(hardware(2.0, "C"))
    #expect(buffer.release(at: base.addingTimeInterval(2.5)).map(\.time) == [base.addingTimeInterval(1.5)])
    #expect(buffer.release(at: base.addingTimeInterval(3.0)) == [hardware(2.0, "B"), hardware(2.0, "C")])
    #expect(buffer.isEmpty)
    buffer.insert(hardware(5.0))
    buffer.insert(hardware(1.0))
    #expect(buffer.releaseAll() == [hardware(1.0), hardware(5.0)])
}

@Test func hardwareStateReportsStartsStopsAndRemovedDevices() {
    var state = HardwareState()
    let time = base
    #expect(
        state.update(.camera, running: ["Cam"], at: time) == [HardwareChange(time: time, sensor: .camera, device: "Cam", isRunning: true)])
    #expect(state.update(.camera, running: ["Cam"], at: time).isEmpty)
    #expect(state.update(.microphone, running: [], at: time).isEmpty)
    // The camera was unplugged while running, and another one started.
    #expect(
        state.update(.camera, running: ["iPhone Camera"], at: time) == [
            HardwareChange(time: time, sensor: .camera, device: "Cam", isRunning: false),
            HardwareChange(time: time, sensor: .camera, device: "iPhone Camera", isRunning: true)
        ])
}

@Test func backoffDoublesUpToAMinuteAndResetsAfterAHealthyRun() {
    var backoff = RestartBackoff()
    #expect((0..<8).map { _ in backoff.delay(afterRunning: 0.1) } == [1, 2, 4, 8, 16, 32, 60, 60])
    #expect(backoff.delay(afterRunning: 120) == 1)
    #expect(backoff.delay(afterRunning: 5) == 2)
}

@Test func resolverFindsInstalledAppsOnly() throws {
    let finder = try #require(AppResolver.resolve("com.apple.finder"))
    #expect(finder.path.hasSuffix("/Finder.app"))
    #expect(finder.name == "Finder")
    #expect(finder.teamID == nil)
    #expect(AppResolver.resolve("bash") == nil)
    #expect(AppResolver.resolve("com.example.not-installed") == nil)
}

@Test func theSameLogEntryFromStreamAndShowIsRecordedOnce() throws {
    let temporary = try TemporaryStore()
    let recorder = try Recorder(store: temporary.store, startingAt: base)
    let message = #"Active activity attributions changed to ["cam:com.apple.PhotoBooth"]"#
    let streamed = LogEvent(timestamp: base.addingTimeInterval(0.001), message: message, entryID: "123")
    let shown = LogEvent(timestamp: base, message: message, entryID: "123")
    #expect(try recorder.record(.indicator(streamed)).count == 1)
    #expect(try recorder.record(.indicator(shown)).isEmpty)
    #expect(try temporary.rows("SELECT id FROM raw_events").count == 1)
    #expect(try temporary.store.activations().count == 1)
}

@Test func recorderCountsWritesAndKnowsWhereToResumeBackfill() throws {
    let temporary = try TemporaryStore()
    let recorder = try Recorder(store: temporary.store, startingAt: base)
    #expect(recorder.processedLogTime == nil)
    #expect(recorder.writeCount == 0)
    let line = LogEvent(timestamp: base.addingTimeInterval(5), message: "Active activity attributions changed to []", entryID: "1")
    try recorder.record(.indicator(line))
    try recorder.record(.indicator(line))
    #expect(recorder.writeCount == 1)
    #expect(recorder.processedLogTime == base.addingTimeInterval(5))
    try recorder.heartbeat(at: base.addingTimeInterval(6))
    #expect(recorder.writeCount == 2)

    let restarted = try Recorder(store: temporary.store, startingAt: base.addingTimeInterval(60))
    #expect(restarted.processedLogTime == base.addingTimeInterval(5))
    #expect(restarted.previousHeartbeat == base.addingTimeInterval(6))
}

@Test func appsAreMarkedAsCommandLineAndKeepResolvedInfo() throws {
    let capture = try CaptureFixture("27.3-26C5035r")
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: base).record(capture.recorderInputs)
    try temporary.store.save(
        AppInfo(name: "Ignored", path: "/Applications/Photo Booth.app", teamID: "TEAM123456"), for: "com.apple.PhotoBooth")

    let apps = try temporary.rows("SELECT client, name, path, team_id, command_line FROM apps ORDER BY client")
    #expect(apps.filter { $0["command_line"] == true }.map { $0["client"] as String } == ["bash"])
    let booth = try #require(apps.first { $0["client"] == "com.apple.PhotoBooth" })
    #expect(booth["name"] == "Photo Booth")
    #expect(booth["path"] == "/Applications/Photo Booth.app")
    #expect(booth["team_id"] == "TEAM123456")
}
