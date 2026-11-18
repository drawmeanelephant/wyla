import Foundation
import Testing
import WylaCore

private let base = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

private func active(_ clients: [String], sensor: Sensor = .camera, at seconds: TimeInterval) -> BuilderInput {
    .indicator(.active(Set(clients.map { Attribution(sensor: sensor, client: $0) }), unrecognized: []), time: at(seconds))
}

private func camera(_ isRunning: Bool, at seconds: TimeInterval, device: String = "Built-in") -> BuilderInput {
    .hardware(HardwareChange(time: at(seconds), sensor: .camera, device: device, isRunning: isRunning))
}

private func run(_ inputs: [BuilderInput], until seconds: TimeInterval = 100) -> [ActivationEvent] {
    var builder = SessionBuilder()
    return inputs.flatMap { builder.consume($0) } + builder.advance(to: at(seconds))
}

private func summary(_ events: [ActivationEvent]) -> [String] {
    events.map { event in
        switch event {
        case .started(let activation): return "start \(activation.client ?? "unattributed") \(activation.start.timeIntervalSince(base))"
        case .ended(let activation):
            let end = activation.end.map { $0.timeIntervalSince(base) } ?? -1
            return "end \(activation.client ?? "unattributed") \(end) \(activation.device ?? "-")"
        }
    }
}

@Test func hardwareWithoutAttributionIsUnattributedEvenWhenBrief() {
    #expect(summary(run([camera(true, at: 0), camera(false, at: 1)])) == ["start unattributed 0.0", "end unattributed 1.0 Built-in"])
}

@Test func attributionWithinGraceExplainsHardware() {
    let events = run([camera(true, at: 0), active(["app.one"], at: 0.5), active([], at: 5), camera(false, at: 5.2)])
    #expect(summary(events) == ["start app.one 0.5", "end app.one 5.0 Built-in"])
}

@Test func longUncoveredUseStartsUnattributedRetroactivelyAndEndsWhenExplained() {
    let events = run([camera(true, at: 0), active(["app.one"], at: 5), active([], at: 8), camera(false, at: 8.1)])
    #expect(
        summary(events) == [
            "start unattributed 0.0", "end unattributed 5.0 Built-in", "start app.one 5.0", "end app.one 8.0 Built-in"
        ])
}

@Test func shutdownLagAfterAttributionRecordsNothing() {
    let events = run([active(["app.one"], at: 0), camera(true, at: 0.2), active([], at: 10), camera(false, at: 10.3)])
    #expect(summary(events) == ["start app.one 0.0", "end app.one 10.0 Built-in"])
}

@Test func hardwareStillRunningAfterAttributionEndsBecomesUnattributed() {
    let events = run([active(["app.one"], at: 0), camera(true, at: 0.2), active([], at: 10), camera(false, at: 20)])
    #expect(
        summary(events) == [
            "start app.one 0.0", "end app.one 10.0 Built-in", "start unattributed 10.0", "end unattributed 20.0 Built-in"
        ])
}

@Test func unattributedUseStillOpenIsReported() {
    var builder = SessionBuilder()
    _ = builder.consume(camera(true, at: 0))
    #expect(summary(builder.advance(to: at(2.9))).isEmpty)
    #expect(summary(builder.advance(to: at(3))) == ["start unattributed 0.0"])
    #expect(builder.snapshot(at: at(4)).map(\.isAttributed) == [false])
}

@Test func deviceIsTheOneThatRanLongest() {
    let events = run([
        active(["app.one"], at: 0), camera(true, at: 0.1, device: "A"), camera(true, at: 1, device: "B"),
        camera(false, at: 1.2, device: "A"), active([], at: 6), camera(false, at: 6.1, device: "B")
    ])
    #expect(summary(events).last == "end app.one 6.0 B")
}

@Test func repeatedHardwareStateIsIgnored() {
    let events = run([active(["app.one"], at: 0), camera(true, at: 0.1), camera(true, at: 3), active([], at: 6), camera(false, at: 6.1)])
    #expect(summary(events) == ["start app.one 0.0", "end app.one 6.0 Built-in"])
}

@Test func displayNameComesFromRecentEntry() {
    let attribution = Attribution(sensor: .camera, client: "app.one")
    let events = run([
        active(["app.one"], at: 0), .indicator(.ended(attribution, displayName: "App One"), time: at(4)), active([], at: 4)
    ])
    guard case .ended(let activation) = events.last else {
        Issue.record("no end event")
        return
    }
    #expect(activation.displayName == "App One")
}

private func request(_ service: String, app: String, at seconds: TimeInterval) -> BuilderInput {
    .tccRequest(
        TCCRequest(
            messageID: "1.\(seconds)", time: at(seconds), service: service,
            responsible: TCCProcess(identifier: app, pid: 1, binaryPath: nil), accessing: nil, requesting: nil, authValue: 2))
}

private func responsible(_ events: [ActivationEvent], client: String) -> String? {
    events.compactMap { event -> String? in
        guard case .started(let activation) = event, activation.client == client else { return nil }
        return activation.responsible?.identifier ?? "none"
    }.first
}

@Test func commandLineClientUsesLatestMatchingRequestInWindow() {
    let events = run([
        request("kTCCServiceScreenCapture", app: "too.early", at: 0),
        request("kTCCServiceScreenCapture", app: "the.app", at: 0.8),
        request("kTCCServiceCamera", app: "other.sensor", at: 0.9),
        active(["bash"], sensor: .screen, at: 1)
    ])
    #expect(responsible(events, client: "bash") == "the.app")
}

@Test func commandLineClientIgnoresRequestsFromAttributedApps() {
    let events = run([
        request("kTCCServiceScreenCapture", app: "app.one", at: 0.9),
        .indicator(
            .active([Attribution(sensor: .camera, client: "app.one"), Attribution(sensor: .screen, client: "bash")], unrecognized: []),
            time: at(1))
    ])
    #expect(responsible(events, client: "bash") == "none")
}

@Test func bundleClientsAreNotMatchedToRequests() {
    let events = run([request("kTCCServiceCamera", app: "the.app", at: 0.9), active(["app.one"], at: 1)])
    #expect(responsible(events, client: "app.one") == "none")
}

@Test func closeAllEndsNoEarlierThanStart() {
    var builder = SessionBuilder(restoring: [Activation(sensor: .microphone, client: "app.one", start: at(50))])
    let events = builder.closeAll(at: at(30), reason: .agentRestart)
    guard case .ended(let activation) = events.first else {
        Issue.record("no end event")
        return
    }
    #expect(activation.end == at(50))
    #expect(activation.endReason == .agentRestart)
}

@Test func snapshotReturnsRestoredActivationsInStartOrder() {
    var builder = SessionBuilder(restoring: [
        Activation(sensor: .screen, client: "app.two", start: at(5)), Activation(sensor: .camera, client: "app.one", start: at(0))
    ])
    #expect(builder.snapshot(at: at(10)).map(\.client) == ["app.one", "app.two"])
}

@Test func mergerKeepsClientsAndSensorsApart() {
    let events = run([
        active(["app.one"], at: 0), active([], at: 1), active(["app.two"], at: 1.5), active([], at: 2),
        active(["app.one"], at: 2.5), active([], at: 3)
    ])
    let sessions = SessionMerger.merge(events.compactMap { if case .ended(let activation) = $0 { activation } else { nil } })
    #expect(sessions.map { "\($0.client ?? "-") x\($0.activations.count)" } == ["app.one x2", "app.two x1"])
    #expect(sessions.first?.end == at(3))
}
