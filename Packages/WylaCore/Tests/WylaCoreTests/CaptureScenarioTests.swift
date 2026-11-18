import Foundation
import Testing
import WylaCore

private let main = "27.3-26C5035r"
private let continuity = "continuity-27.3-26C5035r"

private struct Expected: Equatable, CustomStringConvertible {
    let sensor: Sensor
    let client: String
    let start: String
    let end: String
    let name: String
    let device: String?

    init(_ sensor: Sensor, _ client: String, _ start: String, _ end: String, _ name: String, _ device: String?) {
        (self.sensor, self.client, self.start, self.end, self.name, self.device) = (sensor, client, start, end, name, device)
    }

    init(_ activation: Activation) {
        self.init(
            activation.sensor, activation.client ?? "-", clock(activation.start), clock(activation.end),
            activation.displayName ?? "-", activation.device)
    }

    var description: String { "\(sensor) \(client) \(start)-\(end) \(name) \(device ?? "-")" }
}

private func appActivations(_ capture: String) throws -> [Expected] {
    try CaptureFixture(capture).activations().filter { $0.client != "bash" }.sorted { $0.start < $1.start }.map(Expected.init)
}

@Test func everyRelevantLineParses() throws {
    for name in [main, continuity] {
        #expect(try CaptureFixture(name).unparsed.isEmpty, "\(name)")
    }
}

@Test func singleAppsOnEachSensor() throws {
    let activations = try appActivations(main).filter { $0.client != "com.apple.FaceTime" && $0.start < "13:58:10" }
    #expect(
        activations == [
            Expected(.camera, "com.apple.PhotoBooth", "13:56:49.616", "13:57:00.628", "Photo Booth", "MacBook Pro Camera"),
            Expected(.microphone, "com.apple.VoiceMemos", "13:57:28.442", "13:57:34.742", "Voice Memos", "MacBook Pro Microphone"),
            Expected(.screen, "com.apple.systemuiserver", "13:57:52.800", "13:58:01.150", "Screenshot", nil)
        ])
}

@Test func twoAppsOnOneCameraFlapIndependently() throws {
    let activations = try appActivations(main).filter { $0.start >= "13:58:10" }
    #expect(
        activations == [
            Expected(.camera, "com.apple.PhotoBooth", "13:58:12.994", "13:58:20.130", "Photo Booth", "MacBook Pro Camera"),
            Expected(.camera, "com.apple.FaceTime", "13:58:18.172", "13:58:21.998", "FaceTime", "MacBook Pro Camera"),
            Expected(.camera, "com.apple.PhotoBooth", "13:58:22.013", "13:58:30.857", "Photo Booth", "MacBook Pro Camera"),
            Expected(.camera, "com.apple.FaceTime", "13:58:28.763", "13:58:49.135", "FaceTime", "MacBook Pro Camera"),
            Expected(.camera, "com.apple.PhotoBooth", "13:58:38.871", "13:58:44.694", "Photo Booth", "MacBook Pro Camera")
        ])
}

@Test func mergeWindowJoinsOnlyShortGaps() throws {
    let sessions = SessionMerger.merge(try CaptureFixture(main).activations()).filter { $0.start > Date(timeIntervalSince1970: 0) }
    let camera = sessions.filter { $0.sensor == .camera && clock($0.start) >= "13:58:10" }
    // Photo Booth's 1.9 s gap merges; its 8 s gap and FaceTime's 6.8 s gap don't.
    #expect(
        camera.map { "\($0.client ?? "-") \(clock($0.start))-\(clock($0.end)) x\($0.activations.count)" } == [
            "com.apple.PhotoBooth 13:58:12.994-13:58:30.857 x2",
            "com.apple.FaceTime 13:58:18.172-13:58:21.998 x1",
            "com.apple.FaceTime 13:58:28.763-13:58:49.135 x1",
            "com.apple.PhotoBooth 13:58:38.871-13:58:44.694 x1"
        ])
}

@Test func commandLineClientIsTracedToResponsibleApp() throws {
    let bash = try CaptureFixture(main).activations().filter { $0.client == "bash" }
    #expect(bash.count == 16)
    #expect(bash.allSatisfy { ($0.end ?? .distantFuture).timeIntervalSince($0.start) < 0.05 })
    #expect(bash.allSatisfy { $0.sensor == .screen && $0.displayName == "bash" })
    // The fixture keeps the TCC lines of the first activation only.
    let traced = bash.filter { $0.responsible != nil }
    #expect(traced.map { clock($0.start) } == ["13:56:23.624"])
    #expect(traced.first?.responsible?.identifier == "com.electron.factory")
    #expect(traced.first?.responsible?.binaryPath == "/Applications/Factory.app/Contents/MacOS/Factory")
    let session = SessionMerger.merge(bash).first
    #expect(session?.responsible?.identifier == "com.electron.factory")
}

@Test func continuityCameraSwitchKeepsOneSessionWithBothDevices() throws {
    let activations = try appActivations(continuity)
    #expect(
        activations == [
            Expected(.camera, "com.apple.PhotoBooth", "14:09:51.138", "14:09:55.057", "Photo Booth", "MacBook Pro Camera"),
            Expected(.camera, "com.apple.PhotoBooth", "14:09:55.113", "14:10:10.394", "Photo Booth", "iPhone Camera")
        ])
    let sessions = SessionMerger.merge(try CaptureFixture(continuity).activations()).filter { $0.sensor == .camera }
    #expect(sessions.count == 1)
    #expect(sessions.first?.devices == ["MacBook Pro Camera", "iPhone Camera"])
    #expect(sessions.first?.displayName == "Photo Booth")
}

@Test func capturesHaveNoUnattributedUse() throws {
    for name in [main, continuity] {
        #expect(try CaptureFixture(name).activations().allSatisfy(\.isAttributed), "\(name)")
    }
}

@Test func openActivationsSurviveRestartWithBackfill() throws {
    let capture = try CaptureFixture(main)
    let split = try #require(capture.inputs.first { clock($0.time) >= "13:58:25.000" }?.time)
    var first = SessionBuilder()
    var events = capture.inputs.filter { $0.time < split }.flatMap { first.consume($0) }
    let stored = first.snapshot(at: split)
    #expect(stored.map { "\($0.client ?? "-") \(clock($0.start))" } == ["com.apple.PhotoBooth 13:58:22.013"])

    var resumed = SessionBuilder(restoring: stored)
    let running = HardwareChange(time: split, sensor: .camera, device: "MacBook Pro Camera", isRunning: true)
    events += resumed.consume(.hardware(running))
    events += capture.inputs.filter { $0.time >= split }.flatMap { resumed.consume($0) }

    let uninterrupted = capture.activations().map(Expected.init)
    #expect(CaptureFixture.ended(events).map(Expected.init) == uninterrupted)
}

@Test func openActivationsEndAtHeartbeatWithoutBackfill() throws {
    let capture = try CaptureFixture(main)
    let split = try #require(capture.inputs.first { clock($0.time) >= "13:58:25.000" }?.time)
    var first = SessionBuilder()
    _ = capture.inputs.filter { $0.time < split }.flatMap { first.consume($0) }
    let heartbeat = split.addingTimeInterval(-1)

    var resumed = SessionBuilder(restoring: first.snapshot(at: heartbeat))
    let closed = CaptureFixture.ended(resumed.closeAll(at: heartbeat, reason: .agentRestart))
    #expect(closed.map(\.client) == ["com.apple.PhotoBooth"])
    #expect(closed.first?.end == heartbeat)
    #expect(closed.first?.endReason == .agentRestart)
    #expect(closed.first?.device == "MacBook Pro Camera")
}
