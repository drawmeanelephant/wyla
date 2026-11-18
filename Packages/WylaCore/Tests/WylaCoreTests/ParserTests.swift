import Foundation
import Testing
import WylaCore

private let parser = IndicatorParser()

@Test func parsesActiveAttributionSet() {
    let result = parser.parse(#"Active activity attributions changed to ["cam:com.apple.PhotoBooth", "scr:bash", "loc:com.example"]"#)
    let expected: Set = [Attribution(sensor: .camera, client: "com.apple.PhotoBooth"), Attribution(sensor: .screen, client: "bash")]
    #expect(result == .event(.active(expected, unrecognized: ["loc:com.example"])))
}

@Test func parsesEmptyAttributionSet() {
    #expect(parser.parse("Active activity attributions changed to []") == .event(.active([], unrecognized: [])))
}

@Test func reportsMalformedAttributionList() {
    #expect(
        parser.parse("Active activity attributions changed to [cam:com.apple.PhotoBooth]")
            == .unparsed(reason: "attribution list is not a JSON array of strings"))
}

@Test func parsesRecentEntryWithBundleAndCommandLineClients() {
    #expect(
        parser.parse("added to recent: [[mic] Voice Memos (com.apple.VoiceMemos)]")
            == .event(.ended(Attribution(sensor: .microphone, client: "com.apple.VoiceMemos"), displayName: "Voice Memos")))
    #expect(
        parser.parse("added to recent: [[scr] bash ()]")
            == .event(.ended(Attribution(sensor: .screen, client: "bash"), displayName: "bash")))
    #expect(
        parser.parse("added to recent: [[cam] Zoom (Beta) (us.zoom.xos)]")
            == .event(.ended(Attribution(sensor: .camera, client: "us.zoom.xos"), displayName: "Zoom (Beta)")))
}

@Test func reportsUnknownRecentEntry() {
    #expect(
        parser.parse("added to recent: [[gps] Maps (com.apple.Maps)]") == .unparsed(reason: "recent activity entry has an unknown format"))
}

@Test func ignoresOtherIndicatorLines() {
    #expect(parser.parse("Pausing sensor indicator popover requests") == .ignored)
    #expect(parser.parse(#"Recent activity attributions changed to ["scr:bash"]"#) == .ignored)
}

@Test func verifiedOnlyOnCapturedMajorVersions() {
    #expect(IndicatorParser.isVerified(on: OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0)))
    #expect(!IndicatorParser.isVerified(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
}

@Test func executableNamesHaveNoDot() {
    #expect(Attribution(sensor: .screen, client: "bash").isExecutableName)
    #expect(!Attribution(sensor: .screen, client: "com.apple.systemuiserver").isExecutableName)
}

@Test func parsesLogLines() throws {
    #expect(LogLine(parsing: #"Filtering the log data using "subsystem == \"x\"""#) == .banner)
    #expect(LogLine(parsing: "{not json") == .malformed)
    #expect(LogLine(parsing: #"{"timestamp":"yesterday","eventMessage":"x"}"#) == .malformed)
    let line = LogLine(parsing: #"{"timestamp":"2026-11-18 13:55:46.482710-0500","eventMessage":"hello"}"#)
    guard case .event(let event) = line else {
        Issue.record("expected an event, got \(line)")
        return
    }
    #expect(event.message == "hello")
    #expect(abs(event.timestamp.timeIntervalSince1970 - 1_795_028_146.482710) < 0.000_001)
}

@Test func parsesTimestampsWithoutFractionAndWithPositiveOffset() {
    let line = LogLine(parsing: #"{"timestamp":"2026-11-19 00:25:46+0530","eventMessage":"x"}"#)
    #expect(line == .event(LogEvent(timestamp: Date(timeIntervalSince1970: 1_795_028_146), message: "x")))
}

private func tccEvent(_ seconds: TimeInterval, _ message: String) -> LogEvent {
    LogEvent(timestamp: Date(timeIntervalSince1970: seconds), message: message)
}

@Test func assemblesTCCRequestFromItsLines() {
    var assembler = TCCRequestAssembler()
    let ctx = "AUTHREQ_CTX: msgID=1271.1, function=TCCAccessRequest, service=kTCCServiceScreenCapture, preflight=yes, query=1,"
    let attribution =
        "AUTHREQ_ATTRIBUTION: msgID=1271.1, attribution={responsible={TCCDProcess: identifier=com.example.app, pid=10, auid=501, "
        + "euid=501, responsible_path=/Applications/Example.app/Contents/MacOS/Example, "
        + "binary_path=/Applications/Example.app/Contents/MacOS/Example}, accessing={TCCDProcess: identifier=tool, pid=11, "
        + "auid=501, euid=501, binary_path=/usr/local/bin/tool}, requesting={TCCDProcess: identifier=com.apple.replayd, pid=12, "
        + "auid=501, euid=501, binary_path=/usr/libexec/replayd},},"
    #expect(assembler.consume(tccEvent(1, ctx)) == .ignored)
    #expect(assembler.consume(tccEvent(1, attribution)) == .ignored)
    #expect(assembler.consume(tccEvent(1, "REPLY: (0) function=TCCAccessRequest, msgID=1271.1")) == .ignored)
    let result = assembler.consume(tccEvent(1.1, "AUTHREQ_RESULT: msgID=1271.1, authValue=2, authReason=4, authVersion=1,"))
    guard case .event(let request) = result else {
        Issue.record("expected a request, got \(result)")
        return
    }
    #expect(request.sensor == .screen)
    #expect(request.authValue == 2)
    #expect(request.time == Date(timeIntervalSince1970: 1))
    #expect(
        request.responsibleApp
            == TCCProcess(identifier: "com.example.app", pid: 10, binaryPath: "/Applications/Example.app/Contents/MacOS/Example"))
    #expect(request.accessing?.binaryPath == "/usr/local/bin/tool")
    #expect(request.requesting?.identifier == "com.apple.replayd")
}

@Test func tccRequestFallsBackToAccessingThenRequestingProcess() {
    let process = TCCProcess(identifier: "com.example.app", pid: 1, binaryPath: nil)
    let accessing = TCCRequest(
        messageID: "1", time: .distantPast, service: "kTCCServiceCamera", responsible: nil, accessing: process, requesting: nil,
        authValue: 2)
    let requesting = TCCRequest(
        messageID: "2", time: .distantPast, service: "kTCCServiceMicrophone", responsible: nil, accessing: nil, requesting: process,
        authValue: 2)
    let other = TCCRequest(
        messageID: "3", time: .distantPast, service: "kTCCServicePhotos", responsible: nil, accessing: nil, requesting: nil, authValue: 2)
    #expect(accessing.responsibleApp == process && accessing.sensor == .camera)
    #expect(requesting.responsibleApp == process && requesting.sensor == .microphone)
    #expect(other.responsibleApp == nil && other.sensor == nil)
}

@Test func tccAssemblerIgnoresOrphansAndReportsMalformedLines() {
    var assembler = TCCRequestAssembler()
    #expect(assembler.consume(tccEvent(0, "AUTHREQ_RESULT: msgID=9.9, authValue=2,")) == .ignored)
    #expect(assembler.consume(tccEvent(0, "AUTHREQ_CTX: garbled")) == .unparsed(reason: "AUTHREQ_CTX line has an unknown format"))
    #expect(
        assembler.consume(tccEvent(0, "AUTHREQ_ATTRIBUTION: garbled"))
            == .unparsed(reason: "AUTHREQ_ATTRIBUTION line has an unknown format"))
    #expect(assembler.consume(tccEvent(0, "AUTHREQ_RESULT: garbled")) == .unparsed(reason: "AUTHREQ_RESULT line has an unknown format"))
}

@Test func tccAssemblerDropsRequestsThatNeverComplete() {
    var assembler = TCCRequestAssembler()
    _ = assembler.consume(tccEvent(0, "AUTHREQ_CTX: msgID=5.1, function=f, service=kTCCServiceCamera, preflight=yes"))
    #expect(assembler.consume(tccEvent(20, "AUTHREQ_RESULT: msgID=5.1, authValue=2,")) == .ignored)
}
