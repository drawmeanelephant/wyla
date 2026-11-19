import Foundation
import GRDB
import Testing
import WylaCore

private let main = "27.3-26C5035r"

/// The main capture recorded into a store, and its sessions.
private struct Recorded {
    let temporary: TemporaryStore
    let sessions: [Session]

    init() throws {
        let capture = try CaptureFixture(main)
        temporary = try TemporaryStore()
        try Recorder(store: temporary.store, startingAt: capture.recorderInputs[0].time).record(capture.recorderInputs)
        sessions = SessionMerger.merge(try temporary.store.activations())
    }
}

@Test func activationsOverlapTheTimeRange() throws {
    let recorded = try Recorded()
    let all = try recorded.temporary.store.activations()
    let start = all[2].start
    let end = all[all.count - 3].start

    let filtered = try recorded.temporary.store.activations(from: start, to: end)
    let expected = all.filter { $0.start <= end && ($0.end ?? .distantFuture) >= start }
    #expect(summaries(filtered) == summaries(expected))
    // An activation that starts before `from` but ends inside the range overlaps.
    let wrapping = try recorded.temporary.store.activations(from: all[0].start, to: all[0].start)
    #expect(summaries(wrapping) == summaries(all.filter { $0.start == all[0].start }))
}

@Test func openActivationsAreTheOnesWithoutAnEnd() throws {
    let temporary = try TemporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = try Recorder(store: temporary.store, startingAt: start)
    try recorder.record(
        .indicator(
            LogEvent(timestamp: start, message: #"Active activity attributions changed to ["cam:com.apple.PhotoBooth"]"#, entryID: "1")))
    #expect(try temporary.store.openActivations().map(\.client) == ["com.apple.PhotoBooth"])

    try recorder.record(
        .indicator(LogEvent(timestamp: start.addingTimeInterval(5), message: "Active activity attributions changed to []", entryID: "2")))
    #expect(try temporary.store.openActivations().isEmpty)
}

@Test func storedAppsCarryTheirResolvedFields() throws {
    let recorded = try Recorded()
    let apps = try recorded.temporary.store.apps()
    let photoBooth = try #require(apps.first { $0.client == "com.apple.PhotoBooth" })
    #expect(photoBooth.name == "Photo Booth")
    #expect(!photoBooth.commandLine)
    let bash = try #require(apps.first { $0.client == "bash" })
    #expect(bash.commandLine)
    let factory = try #require(apps.first { $0.client == "com.electron.factory" })
    #expect(factory.path == "/Applications/Factory.app/Contents/MacOS/Factory")
}

@Test func sessionDetailFindsTheRawEventsBehindIt() throws {
    let recorded = try Recorded()
    let session = try #require(recorded.sessions.first { $0.displayName == "Photo Booth" })
    let events = try recorded.temporary.store.rawEvents(withIDs: session.eventIDs)

    #expect(!events.isEmpty)
    #expect(Set(events.map(\.id)) == Set(session.eventIDs))
    #expect(events == events.sorted { ($0.time, $0.id) < ($1.time, $1.id) })
    #expect(events.contains { $0.source == "indicator" && $0.message.contains("cam:com.apple.PhotoBooth") })
}

@Test func queryFiltersBySensorClientAndText() throws {
    let recorded = try Recorded()

    let screens = SessionQuery(sensor: .screen).apply(to: recorded.sessions)
    #expect(!screens.isEmpty && screens.allSatisfy { $0.sensor == .screen })

    let photoBooth = SessionQuery(client: "com.apple.PhotoBooth").apply(to: recorded.sessions)
    #expect(!photoBooth.isEmpty && photoBooth.allSatisfy { $0.client == "com.apple.PhotoBooth" })

    // Text matches the display name and the responsible app as well as the client.
    #expect(SessionQuery(text: "photo booth").apply(to: recorded.sessions) == photoBooth)
    let factory = SessionQuery(text: "factory").apply(to: recorded.sessions)
    #expect(factory.allSatisfy { $0.responsible?.identifier == "com.electron.factory" })

    #expect(SessionQuery().apply(to: recorded.sessions).count == recorded.sessions.count)
}

@Test func queryRangeOverlapsSessions() throws {
    let recorded = try Recorded()
    let session = try #require(recorded.sessions.first { $0.displayName == "Photo Booth" })
    let end = try #require(session.end)

    let inside = SessionQuery(range: session.start..<end).apply(to: recorded.sessions)
    #expect(inside.contains(session))
    let before = SessionQuery(range: session.start.addingTimeInterval(-60)..<session.start).apply(to: recorded.sessions)
    #expect(!before.contains(session))
}

@Test func appSummariesCountSessionsAndTime() throws {
    let recorded = try Recorded()
    let now = recorded.sessions.compactMap(\.end).max() ?? .now
    let summaries = AppSummary.all(from: recorded.sessions, asOf: now)

    let photoBooth = try #require(summaries.first { $0.client == "com.apple.PhotoBooth" })
    let expectedSessions = recorded.sessions.filter { $0.client == "com.apple.PhotoBooth" }
    #expect(photoBooth.counts[.camera] == expectedSessions.count)
    #expect(photoBooth.counts[.microphone] == nil)
    #expect(photoBooth.duration == expectedSessions.reduce(0) { $0 + $1.duration(asOf: now) })
    #expect(photoBooth.firstUse == expectedSessions.map(\.start).min())
    #expect(photoBooth.lastUse == expectedSessions.compactMap(\.end).max())
    #expect(summaries.map(\.duration) == summaries.map(\.duration).sorted(by: >))
}

@Test func dailyUseBucketsSessionsByDayAndSensor() throws {
    let recorded = try Recorded()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: -5 * 3600))
    let uses = DailyUse.of(recorded.sessions, asOf: .now, calendar: calendar)

    // The whole capture is one afternoon, so there is one bucket per sensor.
    #expect(Set(uses.map(\.day)).count == 1)
    #expect(
        uses.map { "\($0.sensor.rawValue) \($0.sessions)" }.sorted()
            == recorded.sessions.reduce(into: [Sensor: Int]()) {
                $0[$1.sensor, default: 0] += 1
            }.map { "\($0.key.rawValue) \($0.value)" }.sorted())
}
