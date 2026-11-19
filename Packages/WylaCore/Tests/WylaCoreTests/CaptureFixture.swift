import Foundation
import Testing
import WylaCore

/// The builder inputs from one M0 capture: indicator lines, TCC requests, and the hardware probe
/// log, merged in time order the way the agent will merge its live sources.
struct CaptureFixture {
    let inputs: [BuilderInput]
    /// The same capture as recorder inputs, including the indicator lines the parser ignores.
    let recorderInputs: [RecorderInput]
    let unparsed: [String]

    /// `name` is the fixture suffix after the source, for example `27.3-26C5035r` or
    /// `continuity-27.3-26C5035r`.
    init(_ name: String) throws {
        var entries: [(recorded: RecorderInput, built: BuilderInput?)] = []
        var unparsed: [String] = []
        let parser = IndicatorParser()
        for event in try Self.events("sensor-indicators-\(name)") {
            switch parser.parse(event.message) {
            case .event(let indicator): entries.append((.indicator(event), .indicator(indicator, time: event.timestamp)))
            case .ignored: entries.append((.indicator(event), nil))
            case .unparsed(let reason):
                entries.append((.indicator(event), nil))
                unparsed.append(reason)
            }
        }
        var assembler = TCCRequestAssembler()
        for event in try Self.events("tcc-access-\(name)") {
            switch assembler.consume(event) {
            case .event(let request): entries.append((.tccRequest(request), .tccRequest(request)))
            case .ignored: break
            case .unparsed(let reason): unparsed.append(reason)
            }
        }
        entries += try Self.hardwareChanges("hardware-probe-\(name)").map { (.hardware($0), .hardware($0)) }
        let sorted = entries.enumerated().sorted { ($0.element.recorded.time, $0.offset) < ($1.element.recorded.time, $1.offset) }
        self.inputs = sorted.compactMap(\.element.built)
        self.recorderInputs = sorted.map(\.element.recorded)
        self.unparsed = unparsed
    }

    /// Runs every input through a new builder and returns the finished activations.
    func activations() -> [Activation] {
        var builder = SessionBuilder()
        var events = inputs.flatMap { builder.consume($0) }
        events += builder.advance(to: (inputs.last?.time ?? .distantPast).addingTimeInterval(10))
        return Self.ended(events)
    }

    static func ended(_ events: [ActivationEvent]) -> [Activation] {
        events.compactMap {
            if case .ended(let activation) = $0 { activation } else { nil }
        }
    }

    static func url(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private static func events(_ name: String) throws -> [LogEvent] {
        try String(contentsOf: url(name, "ndjson"), encoding: .utf8).split(separator: "\n").compactMap {
            if case .event(let event) = LogLine(parsing: $0) { event } else { nil }
        }
    }

    /// Parses `scripts/hwprobe.swift` output: `<ISO 8601 time> camera 35 MacBook Pro Camera [model] = on`.
    private static func hardwareChanges(_ name: String) throws -> [HardwareChange] {
        let line = /(\S+) (camera|mic) \d+ (.+?)( \[[^\]]*\])? = (on|off)/
        return try String(contentsOf: url(name, "log"), encoding: .utf8).split(separator: "\n").compactMap { text in
            guard let match = text.wholeMatch(of: line) else { return nil }
            let time = try Date(
                String(match.1),
                strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
            return HardwareChange(
                time: time, sensor: match.2 == "camera" ? .camera : .microphone, device: String(match.3), isRunning: match.5 == "on")
        }
    }
}

/// Formats a time as the capture's local clock time, `HH:mm:ss.SSS` in UTC-5, to compare with log timestamps.
func clock(_ date: Date?) -> String {
    guard let date else { return "open" }
    let seconds = date.timeIntervalSince1970 - 5 * 3600
    let millis = Int((seconds * 1000).rounded(.down))
    let day = millis % 86_400_000
    return String(
        format: "%02d:%02d:%02d.%03d", day / 3_600_000, day / 60000 % 60, day / 1000 % 60, day % 1000)
}
