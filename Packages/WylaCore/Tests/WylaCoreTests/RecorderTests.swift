import Foundation
import GRDB
import Testing
import WylaCore

private let main = "27.3-26C5035r"
private let continuity = "continuity-27.3-26C5035r"

/// Columns ending in `_us` hold microseconds since 1970.
private func storedTime(_ microseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
}

@Test(arguments: [main, continuity])
func recordedActivationsMatchSessionBuilder(capture name: String) throws {
    let capture = try CaptureFixture(name)
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)

    let stored = try temporary.store.activations()
    #expect(summaries(stored) == summaries(capture.activations()))
    #expect(stored.count == capture.activations().count)
    let report = try temporary.store.verifyIntegrity()
    #expect(report.isIntact)
    #expect(report.verifiedRows == (try temporary.rows("SELECT id FROM raw_events")).count)
}

@Test func onlyUsedEventsAreStored() throws {
    let capture = try CaptureFixture(main)
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)

    let counts = try temporary.rows("SELECT source, count(*) AS n FROM raw_events GROUP BY source ORDER BY source")
    let indicatorLines = capture.inputs.filter { if case .indicator = $0 { true } else { false } }.count
    let hardwareChanges = capture.inputs.filter { if case .hardware = $0 { true } else { false } }.count
    // TCC requests are stored only when they link a command-line client to its responsible app.
    #expect(
        counts.map { "\($0["source"] as String) \($0["n"] as Int)" } == [
            "hardware \(hardwareChanges)", "indicator \(indicatorLines)", "tcc 1"
        ])
}

@Test func everyActivationLinksToTheEventsBehindIt() throws {
    let capture = try CaptureFixture(main)
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)

    let links = try temporary.rows(
        """
        SELECT a.client, a.start_us, a.end_us, s.time_us AS start_time, s.source AS start_source,
            e.time_us AS end_time, e.source AS end_source, r.source AS responsible_source, r.message AS responsible_message
        FROM activations a
        LEFT JOIN raw_events s ON s.id = a.start_event_id
        LEFT JOIN raw_events e ON e.id = a.end_event_id
        LEFT JOIN raw_events r ON r.id = a.responsible_event_id
        """)
    #expect(links.count == capture.activations().count)
    for link in links {
        #expect(link["start_time"] as Int64? == link["start_us"] as Int64)
        #expect(link["end_time"] as Int64? == link["end_us"] as Int64?)
        #expect(link["start_source"] as String? == "indicator")
        #expect(link["end_source"] as String? == "indicator")
    }
    let traced = links.filter { $0["responsible_source"] != nil }
    #expect(traced.map { $0["client"] as String } == ["bash"])
    #expect(traced.first?["responsible_source"] == "tcc")
    let message: String = try #require(traced.first?["responsible_message"])
    #expect(message.contains("\"identifier\":\"com.electron.factory\""))
}

@Test func appsRecordNamesPathsAndFirstAndLastUse() throws {
    let capture = try CaptureFixture(main)
    let temporary = try TemporaryStore()
    try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)

    let apps = try temporary.rows("SELECT * FROM apps ORDER BY client")
    let photoBooth = try #require(apps.first { $0["client"] == "com.apple.PhotoBooth" })
    #expect(photoBooth["name"] == "Photo Booth")
    #expect(clock(storedTime(photoBooth["first_seen_us"])) == "13:56:49.616")
    #expect(clock(storedTime(photoBooth["last_seen_us"])) == "13:58:44.694")
    let factory = try #require(apps.first { $0["client"] == "com.electron.factory" })
    #expect(factory["path"] == "/Applications/Factory.app/Contents/MacOS/Factory")
    #expect(Set(apps.map { $0["client"] as String }).isSuperset(of: ["bash", "com.apple.FaceTime", "com.apple.VoiceMemos"]))
}

@Test func ingestingTheSameEventsTwiceChangesNothing() throws {
    let capture = try CaptureFixture(main)
    let temporary = try TemporaryStore()
    let start = capture.recorderInputs[0].time
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(capture.recorderInputs)
    try recorder.heartbeat(at: start.addingTimeInterval(600))
    let once = try temporary.contents()

    try recorder.record(capture.recorderInputs)
    #expect(try temporary.contents() == once)

    // A restarted agent backfilling the whole capture again.
    let restarted = try Recorder(store: temporary.store, startingAt: start.addingTimeInterval(700))
    try restarted.record(capture.recorderInputs)
    try restarted.heartbeat(at: start.addingTimeInterval(700))
    #expect(try temporary.contents() == once)
    #expect(try temporary.store.verifyIntegrity().isIntact)
}

/// The main capture recorded up to 13:58:25, while Photo Booth uses the camera, with a heartbeat
/// then, as if the agent was killed at that moment.
private struct InterruptedRun {
    let capture: CaptureFixture
    let temporary: TemporaryStore
    let split: Date

    init() throws {
        capture = try CaptureFixture(main)
        split = try #require(capture.recorderInputs.first { clock($0.time) >= "13:58:25.000" }?.time)
        temporary = try TemporaryStore()
        let first = try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time)
        for input in capture.recorderInputs where input.time < split {
            try first.record(input)
        }
        try first.heartbeat(at: split)
    }
}

@Test func restartedAgentResumesOpenActivationsFromTheStore() throws {
    let run = try InterruptedRun()
    let (capture, temporary, split) = (run.capture, run.temporary, run.split)
    let uninterrupted = try TemporaryStore()
    try Recorder(store: uninterrupted.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)

    let open = try temporary.store.activations().filter { $0.end == nil }
    #expect(
        open.map { "\($0.client ?? "-") \(clock($0.start)) \($0.device ?? "-")" } == [
            "com.apple.PhotoBooth 13:58:22.013 MacBook Pro Camera"
        ])
    let lastIndicator = try #require(capture.recorderInputs.last { if case .indicator = $0, $0.time < split { true } else { false } })
    #expect(clock(try temporary.store.checkpoint(for: .indicator)) == clock(lastIndicator.time))

    // Backfill starts before the checkpoint, so it overlaps what the first run stored.
    let resumed = try Recorder(store: temporary.store, startingAt: split)
    #expect(clock(resumed.previousHeartbeat) == clock(split))
    try resumed.record(.hardware(HardwareChange(time: split, sensor: .camera, device: "MacBook Pro Camera", isRunning: true)))
    try resumed.record(capture.recorderInputs.filter { $0.time >= split.addingTimeInterval(-10) })

    #expect(summaries(try temporary.store.activations()) == summaries(try uninterrupted.store.activations()))
    #expect(try temporary.store.verifyIntegrity().isIntact)
}

@Test func restartedAgentEndsActivationsAtTheLastHeartbeatWithoutBackfill() throws {
    let run = try InterruptedRun()
    let (temporary, split) = (run.temporary, run.split)
    let resumed = try Recorder(store: temporary.store, startingAt: split.addingTimeInterval(3600))
    let heartbeat = try #require(resumed.previousHeartbeat)
    let closed = try resumed.closeOpenActivations(at: heartbeat, reason: .agentRestart)
    #expect(closed.count == 1)

    let photoBooth = try #require(try temporary.store.activations().last { $0.client == "com.apple.PhotoBooth" })
    #expect(clock(photoBooth.end) == clock(split))
    #expect(photoBooth.endReason == .agentRestart)
    #expect(photoBooth.device == "MacBook Pro Camera")
    let rows = try temporary.rows("SELECT client, start_us, end_event_id, end_reason FROM activations WHERE end_reason = 'agent_restart'")
    #expect(
        rows.map { "\($0["client"] as String) \(($0["end_event_id"] as Int64?).map(String.init) ?? "nil")" } == ["com.apple.PhotoBooth nil"]
    )
}

@Test func killedAgentKeepsTheDeviceUseItSawBeforeItsFirstHeartbeat() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let photoBooth = #"Active activity attributions changed to ["cam:com.apple.PhotoBooth"]"#
    let first = try Recorder(store: temporary.store, startingAt: start)
    for device in ["Desk View Camera", "MacBook Pro Camera"] {
        try first.record(.hardware(HardwareChange(time: start.addingTimeInterval(1), sensor: .camera, device: device, isRunning: true)))
    }
    try first.record(.indicator(LogEvent(timestamp: start.addingTimeInterval(1.5), message: photoBooth, entryID: "1")))
    try first.record(
        .hardware(HardwareChange(time: start.addingTimeInterval(2), sensor: .camera, device: "Desk View Camera", isRunning: false)))
    try first.record(.indicator(LogEvent(timestamp: start.addingTimeInterval(4), message: photoBooth, entryID: "2")))

    // Killed before its first heartbeat, so the open activation's device use was never saved.
    let second = try Recorder(store: temporary.store, startingAt: start.addingTimeInterval(10))
    try second.record(.indicator(LogEvent(timestamp: start.addingTimeInterval(6), message: "Active activity attributions changed to []")))

    let activation = try #require(try temporary.store.activations().first)
    #expect(activation.end == start.addingTimeInterval(6))
    #expect(activation.device == "MacBook Pro Camera")
    #expect(activation.deviceUse.mapValues { ($0 * 10).rounded() / 10 } == ["Desk View Camera": 0.5, "MacBook Pro Camera": 2.5])
}

@Test func backfillFromBeforeThePreviousRunStoresOlderEventsWithoutEndingActivations() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let photoBooth = LogEvent(
        timestamp: start.addingTimeInterval(5), message: #"Active activity attributions changed to ["cam:com.apple.PhotoBooth"]"#,
        entryID: "2")
    let empty = { (seconds: TimeInterval, entry: String) in
        RecorderInput.indicator(
            LogEvent(timestamp: start.addingTimeInterval(seconds), message: "Active activity attributions changed to []", entryID: entry))
    }
    try Recorder(store: temporary.store, startingAt: start).record(.indicator(photoBooth))

    // The previous run was killed before its first heartbeat, so the backfill starts before it began.
    let second = try Recorder(store: temporary.store, startingAt: start.addingTimeInterval(10))
    try second.record([empty(-5, "1"), .indicator(photoBooth), empty(8, "3")])

    let activations = try temporary.store.activations()
    #expect(
        activations.map { "\($0.client ?? "-") \(clock($0.start)) \(clock($0.end)) \($0.endReason?.rawValue ?? "-")" } == [
            "com.apple.PhotoBooth 03:00:05.000 03:00:08.000 stopped"
        ])
    #expect(try temporary.rows("SELECT id FROM raw_events").count == 3)
    #expect(second.lateInputs == 1)
}

@Test func unattributedHardwareUseIsStoredWithItsHardwareEvents() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(.hardware(HardwareChange(time: start, sensor: .microphone, device: "Mic", isRunning: true)))
    #expect(try recorder.advance(to: start.addingTimeInterval(1)).isEmpty)
    #expect(try recorder.advance(to: start.addingTimeInterval(5)).count == 1)
    try recorder.heartbeat(at: start.addingTimeInterval(6))
    #expect(try temporary.store.activations().map(\.deviceUse) == [["Mic": 6]])
    try recorder.record(.hardware(HardwareChange(time: start.addingTimeInterval(8), sensor: .microphone, device: "Mic", isRunning: false)))

    let activation = try #require(try temporary.store.activations().first)
    #expect(activation.client == nil)
    #expect(activation.end == start.addingTimeInterval(8))
    #expect(activation.device == "Mic")
    let links = try temporary.rows(
        """
        SELECT s.message AS started, e.message AS ended FROM activations a
        JOIN raw_events s ON s.id = a.start_event_id JOIN raw_events e ON e.id = a.end_event_id
        """)
    #expect(links.map { "\($0["started"] as String) / \($0["ended"] as String)" } == ["microphone Mic on / microphone Mic off"])
}
