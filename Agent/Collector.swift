import CoreFoundation
import Foundation
import WylaCore
import os

/// Feeds the recorder from the system log and the hardware listeners.
///
/// The `log stream` process is supervised and restarted with backoff. Each time it starts, the
/// collector first backfills with `log show` from the last recorded log time, then records the
/// live events. On the first start it then reads the current hardware state. All inputs pass
/// through a `ReorderBuffer` so that backfilled, live, and hardware events reach the recorder in
/// time order. The buffer isn't released during a backfill, which can reach back past live inputs.
actor Collector {
    /// How long live inputs wait in the reorder buffer.
    static let reorderDelay: TimeInterval = 1
    static let tickInterval: Duration = .milliseconds(250)
    static let heartbeatInterval: Duration = .seconds(30)
    /// While an activation is open, heartbeats come this often, so that an agent that is killed
    /// loses little of the activation's device use.
    static let activeHeartbeatInterval: Duration = .seconds(5)
    /// The system keeps about a day of the log lines WYLA reads. After a longer gap, the ends of
    /// open activations are gone, so they end at the last heartbeat.
    static let logRetention: TimeInterval = 24 * 3600
    /// Backfill starts this long before the last recorded log time. The recorder skips events it
    /// already has, so the overlap costs only the reading.
    static let backfillOverlap: TimeInterval = 10

    private enum LiveItem: Sendable {
        /// The stream process started and is capturing; backfill the time before it.
        case started
        case line(String)
    }

    private let store: EventStore
    private let recorder: Recorder
    private let startedAt = Date.now
    private let logger = Logger(subsystem: "io.github.drawmeanelephant.wyla", category: "collector")
    private var router = LogRouter()
    private var buffer = ReorderBuffer(delay: Collector.reorderDelay)
    private var hardware = HardwareState()
    private var monitor: HardwareMonitor?
    private var backfilling = true
    private var resolvedApps: Set<String> = []
    private var notifiedWrites = -1
    private var appWrites = 0
    /// The shared settings, reloaded on each heartbeat so the app's Settings tab applies.
    private var settings = Settings()
    /// The longest time between a log event and its arrival on the live stream since the last heartbeat.
    private var maxLogDelay: TimeInterval = 0

    init(store: EventStore) throws {
        self.store = store
        recorder = try Recorder(store: store, startingAt: .now)
        // Load now as well as on each heartbeat, or a restart would notify with defaults until
        // the first heartbeat read the saved preferences.
        settings = Settings.load(from: Settings.url(near: store.url))
    }

    func run() async {
        if let previous = recorder.previousHeartbeat, Date.now.timeIntervalSince(previous) > Self.logRetention {
            logger.notice("Last heartbeat was over a day ago; ending open activations there")
            perform { try $0.closeOpenActivations(at: previous, reason: .agentRestart) }
        }
        let (items, continuation) = AsyncStream.makeStream(of: LiveItem.self)
        Task.detached { await Self.superviseStream(continuation) }
        Task { await self.tickLoop() }
        Task { await self.heartbeatLoop() }
        for await item in items {
            switch item {
            case .started: await backfill()
            case .line(let line): ingest(line, live: true)
            }
        }
    }

    /// Records the buffered inputs and saves a final heartbeat, for when the agent is asked to quit.
    func stop() {
        if !backfilling {
            for input in buffer.releaseAll() {
                record(input)
            }
        }
        perform { recorder -> [ActivationEvent] in
            try recorder.heartbeat(at: .now)
            return []
        }
        notifyIfChanged()
    }

    private static func superviseStream(_ continuation: AsyncStream<LiveItem>.Continuation) async {
        let logger = Logger(subsystem: "io.github.drawmeanelephant.wyla", category: "collector")
        var backoff = RestartBackoff()
        while !Task.isCancelled {
            let began = Date.now
            var announced = false
            do {
                // `log stream` prints its banner once it is capturing, so the backfill that
                // `.started` triggers leaves no gap before the stream.
                let status = try await LogProcess.run(LogQuery.streamArguments) { line in
                    if !announced {
                        announced = true
                        continuation.yield(.started)
                    }
                    continuation.yield(.line(line))
                }
                logger.error("log stream exited with status \(status, privacy: .public)")
            } catch {
                logger.error("log stream failed to start: \(error.localizedDescription, privacy: .public)")
            }
            let delay = backoff.delay(afterRunning: Date.now.timeIntervalSince(began))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func backfill() async {
        backfilling = true
        // Without a checkpoint, the previous run (on the first start) or this run (when the stream
        // restarts) recorded nothing after it began, so backfill from there.
        let firstStart = monitor == nil
        if let start = recorder.processedLogTime ?? (firstStart ? recorder.previousHeartbeat : startedAt) {
            let began = Date.now
            var lines = 0
            do {
                _ = try await LogProcess.run(LogQuery.showArguments(from: start.addingTimeInterval(-Self.backfillOverlap))) { line in
                    lines += 1
                    self.ingest(line, live: false)
                }
            } catch {
                logger.error("log show failed: \(error.localizedDescription, privacy: .public)")
            }
            let seconds = Date.now.timeIntervalSince(began)
            logger.notice("Backfilled \(lines, privacy: .public) log lines in \(seconds, format: .fixed(precision: 1), privacy: .public) s")
        }
        backfilling = false
        if firstStart {
            monitor = HardwareMonitor { Task { await self.hardwareChanged() } }
            hardwareChanged()
        }
        notifyIfChanged()
    }

    private func ingest(_ line: String, live: Bool) {
        guard case .event(let event) = LogLine(parsing: line) else { return }
        if live {
            maxLogDelay = max(maxLogDelay, Date.now.timeIntervalSince(event.timestamp))
        }
        if let input = router.route(event) {
            buffer.insert(input)
        }
    }

    private func hardwareChanged() {
        guard let monitor else { return }
        let now = Date.now
        for (sensor, running) in monitor.scan().sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for change in hardware.update(sensor, running: running, at: now) {
                buffer.insert(.hardware(change))
            }
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.tickInterval)
            guard !backfilling else { continue }
            let now = Date.now
            for input in buffer.release(at: now) {
                record(input)
            }
            perform { try $0.advance(to: now.addingTimeInterval(-Self.reorderDelay)) }
            notifyIfChanged()
        }
    }

    private func heartbeatLoop() async {
        var lastRegular = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.activeHeartbeatInterval)
            guard !backfilling else { continue }
            let regular = ContinuousClock.now - lastRegular >= Self.heartbeatInterval
            guard regular || recorder.hasOpenActivations else { continue }
            if regular {
                lastRegular = .now
                // A missed listener callback would leave a stale state; rescanning catches it.
                hardwareChanged()
                logger.info(
                    """
                    Heartbeat: max log delay \(self.maxLogDelay, format: .fixed(precision: 2), privacy: .public) s, \
                    late inputs \(self.recorder.lateInputs, privacy: .public), \
                    unparsed TCC lines \(self.router.unparsedTCCLines, privacy: .public)
                    """)
                maxLogDelay = 0
            }
            perform { recorder -> [ActivationEvent] in
                try recorder.heartbeat(at: .now)
                return []
            }
            settings = Settings.load(from: Settings.url(near: store.url))
            if settings.anchorExportEnabled, let head = try? store.head() {
                do {
                    if try AnchorLog.append(head: head, to: AnchorLog.url(near: store.url)) {
                        logger.info("Exported chain head \(head.id, privacy: .public)")
                    }
                } catch {
                    logger.error("Anchor export failed: \(String(describing: error), privacy: .public)")
                }
            }
            notifyIfChanged()
        }
    }

    private func record(_ input: RecorderInput) {
        perform { try $0.record(input) }
    }

    /// Runs a recorder operation and resolves the apps of activations it starts. A database error
    /// ends the agent: launchd restarts it, and the new recorder resumes from what was committed.
    private func perform(_ operation: (Recorder) throws -> [ActivationEvent]) {
        do {
            for case .started(let activation) in try operation(recorder) {
                resolveApps(of: activation)
                Notifier.notify(onStart: activation, store: store, settings: settings)
            }
        } catch {
            logger.fault("Database error, exiting: \(String(describing: error), privacy: .public)")
            exit(EXIT_FAILURE)
        }
    }

    private func resolveApps(of activation: Activation) {
        for client in [activation.client, activation.responsible?.identifier].compactMap(\.self)
        where resolvedApps.insert(client).inserted {
            guard let info = AppResolver.resolve(client) else { continue }
            do {
                try store.save(info, for: client)
                appWrites += 1
            } catch {
                logger.error("Could not save app info: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Posts the change notification that the app listens for, once per batch of writes.
    private func notifyIfChanged() {
        let writes = recorder.writeCount + appWrites
        guard writes != notifiedWrites else { return }
        notifiedWrites = writes
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(EventStore.changeNotification as CFString), nil, nil,
            true)
    }
}
