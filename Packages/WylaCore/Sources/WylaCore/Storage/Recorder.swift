import Foundation
import GRDB

/// An event from one of the agent's sources.
public enum RecorderInput: Sendable, Equatable {
    /// A Control Center `sensor-indicators` log line.
    case indicator(LogEvent)
    /// A completed TCC access check. Every request is counted in `tcc_requests_agg`; only one
    /// that links an activation to its responsible app also joins the hash chain as a raw event.
    case tccRequest(TCCRequest)
    case hardware(HardwareChange)

    public var time: Date {
        switch self {
        case .indicator(let event): event.timestamp
        case .tccRequest(let request): request.time
        case .hardware(let change): change.time
        }
    }
}

/// Stores raw events and the activations that `SessionBuilder` derives from them, one transaction
/// per input. An input whose raw event is already stored is skipped, so replaying backfilled log
/// lines that overlap what was recorded changes nothing. Inputs must arrive in timestamp order:
/// a new input older than one already applied is stored but doesn't change activations. That
/// happens when the backfill reaches before the time the previous run began recording.
public final class Recorder {
    public let store: EventStore
    /// The last heartbeat of the previous agent run, or nil on the first run.
    public let previousHeartbeat: Date?
    private let runID: Int64
    private let parser = IndicatorParser()
    private var builder: SessionBuilder
    private var checkpoints: [RawEventSource: Date] = [:]
    /// Ids of recently stored raw events by time, to link activations to the events that started
    /// and ended them.
    private var recentEvents: [Int64: Int64] = [:]
    private var recentRequests: [TCCRequest] = []
    /// Committed write transactions, so that the caller can tell readers when the database changed.
    public private(set) var writeCount = 0
    /// The time of the latest input applied to the builder, in this run or a previous one.
    private var appliedUntil: Date?
    /// New inputs that were older than `appliedUntil`, so stored without changing activations.
    public private(set) var lateInputs = 0

    /// Starts an agent run at `time` and resumes the activations that were open when the previous
    /// run stopped. Record the backfilled log events next, then the current hardware state.
    public init(store: EventStore, startingAt time: Date) throws {
        self.store = store
        let (previous, runID, builder, checkpoints, applied) = try store.pool.write { db in
            let previous = try Int64.fetchOne(db, sql: "SELECT max(last_heartbeat_us) FROM coverage")
            let applied = try Int64.fetchOne(db, sql: "SELECT max(time_us) FROM raw_events")
            let open = try Row.fetchAll(db, sql: "SELECT * FROM activations WHERE end_us IS NULL").map(Activation.init(row:))
            var builder = SessionBuilder(restoring: open)
            if !open.isEmpty {
                try Self.replayPreviousRunHardware(into: &builder, in: db)
            }
            try db.execute(
                sql: "INSERT INTO coverage (started_us, last_heartbeat_us) VALUES (?, ?)",
                arguments: [time.microseconds, time.microseconds])
            let runID = db.lastInsertedRowID
            var checkpoints: [RawEventSource: Date] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT source, time_us FROM checkpoints") {
                if let source = RawEventSource(rawValue: row["source"]) {
                    checkpoints[source] = Date(microseconds: row["time_us"])
                }
            }
            return (previous.map(Date.init(microseconds:)), runID, builder, checkpoints, applied.map(Date.init(microseconds:)))
        }
        (self.previousHeartbeat, self.runID, self.builder, self.checkpoints) = (previous, runID, builder, checkpoints)
        appliedUntil = applied
    }

    /// Counts the device use that the previous run saw after its last heartbeat, which it didn't
    /// save if it was killed. Its hardware changes are replayed up to the last time it is known to
    /// have been running: its last heartbeat or the last event stored. The hardware state while no
    /// agent ran is unknown, so it isn't counted.
    private static func replayPreviousRunHardware(into builder: inout SessionBuilder, in db: Database) throws {
        guard let run = try Row.fetchOne(db, sql: "SELECT started_us, last_heartbeat_us FROM coverage ORDER BY id DESC LIMIT 1")
        else { return }
        let lastEvent = try Int64.fetchOne(db, sql: "SELECT max(time_us) FROM raw_events") ?? 0
        let lastSeen = Date(microseconds: max(run["last_heartbeat_us"], lastEvent))
        let changes = try Row.fetchAll(
            db, sql: "SELECT time_us, message FROM raw_events WHERE source = 'hardware' AND time_us >= ? ORDER BY id",
            arguments: [run["started_us"] as Int64]
        ).compactMap { HardwareChange(message: $0["message"], time: Date(microseconds: $0["time_us"])) }
        builder.countDeviceUse(replaying: changes, until: lastSeen)
    }

    public var hasOpenActivations: Bool { builder.hasOpenActivations }

    /// The latest log timestamp recorded, in this run or saved by an earlier one. Backfill resumes from it.
    public var processedLogTime: Date? { checkpoints.values.max() }

    @discardableResult
    public func record(_ input: RecorderInput) throws -> [ActivationEvent] {
        let time = input.time
        prune(at: time)
        switch input {
        case .indicator(let event):
            checkpoints[.indicator] = max(checkpoints[.indicator] ?? time, time)
            let raw = RawInput(source: .indicator, time: time, identity: event.entryID, message: event.message)
            switch parser.parse(event.message) {
            case .ignored: return []
            // Unparsed lines are kept for the Health view and for audit.
            case .unparsed: return try apply(raw, nil, at: time)
            case .event(let indicator): return try apply(raw, .indicator(indicator, time: time), at: time)
            }
        case .tccRequest(let request):
            checkpoints[.tcc] = max(checkpoints[.tcc] ?? time, time)
            // Requests are counted, not chained: `tcc_requests` dedups them by (messageID,
            // entry's mach time) — the msgID is `pid.counter`, reused across restarts, and the
            // wall time drifts ~1 ms between `log stream` and `log show`, so the mach time is
            // the request's identity — and the per-minute totals grow from there. Only a
            // request that later links an activation to its responsible app joins the hash
            // chain, in `persist`.
            recentRequests.append(request)
            return try apply(nil, .tccRequest(request), at: time) { db in
                try Self.count(request, in: db)
            }
        case .hardware(let change):
            return try apply(RawInput(source: .hardware, time: time, identity: nil, message: change.message), .hardware(change), at: time)
        }
    }

    /// Lets time pass without input, so that uncovered hardware use past the grace period starts
    /// an unattributed activation.
    @discardableResult
    public func advance(to time: Date) throws -> [ActivationEvent] {
        try apply(nil, nil, at: time)
    }

    /// Saves the agent's heartbeat, the backfill checkpoints, and the progress of open activations.
    public func heartbeat(at time: Date) throws {
        var next = builder
        let open = next.snapshot(at: time)
        try write { db in
            try db.execute(
                sql: "UPDATE coverage SET last_heartbeat_us = ? WHERE id = ?", arguments: [time.microseconds, runID])
            for (source, checkpoint) in checkpoints {
                try db.execute(
                    sql: """
                        INSERT INTO checkpoints (source, time_us) VALUES (?, ?)
                        ON CONFLICT (source) DO UPDATE SET time_us = max(time_us, excluded.time_us)
                        """,
                    arguments: [source.rawValue, checkpoint.microseconds])
            }
            for activation in open {
                try activation.save(endEventID: nil, in: db)
            }
        }
        builder = next
    }

    /// Ends every open activation, for when the system log no longer has their ends. Use
    /// `previousHeartbeat` as `time`.
    @discardableResult
    public func closeOpenActivations(at time: Date, reason: EndReason) throws -> [ActivationEvent] {
        var next = builder
        let events = next.closeAll(at: time, reason: reason)
        try write { db in try persist(events, currentEvent: nil, in: db) }
        builder = next
        return events
    }

    private struct RawInput {
        let source: RawEventSource
        let time: Date
        let identity: String?
        let message: String
    }

    /// Stores the raw event if it is new, runs the builder, and stores the activation changes, all
    /// in one transaction. The builder is updated only after the transaction commits. `sideEffect`
    /// adds derived data (the TCC per-minute totals) to the same transaction; with a raw input it
    /// runs only when the raw event is new, without one it runs whenever there is work to write.
    private func apply(
        _ raw: RawInput?, _ input: BuilderInput?, at time: Date,
        sideEffect: ((Database) throws -> Void)? = nil
    ) throws -> [ActivationEvent] {
        var next = builder
        var events: [ActivationEvent] = []
        var stored: EventStore.Appended?
        let isLate = appliedUntil.map { time < $0 } ?? false
        func build() -> [ActivationEvent] {
            isLate ? [] : input.map { next.consume($0) } ?? next.advance(to: time)
        }
        if let raw {
            try store.pool.write { db in
                let appended = try EventStore.append(
                    raw.source, time: raw.time, identity: raw.identity, message: raw.message, in: db)
                stored = appended
                guard appended.isNew else { return }
                events = build()
                try persist(events, currentEvent: (time.microseconds, appended.id), in: db)
                try sideEffect?(db)
            }
        } else {
            events = build()
            if !events.isEmpty || sideEffect != nil {
                try write { db in
                    try persist(events, currentEvent: nil, in: db)
                    try sideEffect?(db)
                }
            }
        }
        if let stored {
            recentEvents[time.microseconds] = stored.id
            guard stored.isNew else { return [] }
            writeCount += 1
        }
        if isLate {
            lateInputs += 1
        } else {
            appliedUntil = time
        }
        builder = next
        return events
    }

    private func persist(_ events: [ActivationEvent], currentEvent: (time: Int64, id: Int64)?, in db: Database) throws {
        func eventID(at time: Date) -> Int64? {
            let micros = time.microseconds
            return micros == currentEvent?.time ? currentEvent?.id : recentEvents[micros]
        }
        for event in events {
            switch event {
            case .started(let activation):
                try activation.insert(
                    startEventID: eventID(at: activation.start),
                    responsibleEventID: try storeResponsibleRequest(of: activation, in: db), in: db)
            case .ended(let activation):
                let endEventID = activation.endReason == .stopped ? activation.end.flatMap(eventID(at:)) : nil
                try activation.save(endEventID: endEventID, in: db)
            }
        }
    }

    /// How far apart `log stream` and `log show` report the same entry's wall time at most;
    /// the documented drift is about 1 ms.
    private static let streamDriftMicros: Int64 = 10_000

    /// Counts the request in its one-minute bucket in `tcc_requests_agg`, deduplicated on
    /// (message_id, dedup_id): the log's msgID is `pid.counter`, which a process restart or
    /// reboot reuses, and its wall time drifts ~1 ms between `log stream` and `log show`, so
    /// the CTX entry's mach time is the request's identity — its wall time when it has none.
    /// The client is the app TCC held responsible, so the totals name the app behind the check
    /// rather than a daemon such as `replayd` that made it on the app's behalf.
    private static func count(_ request: TCCRequest, in db: Database) throws {
        // Requests stored before entryIDs existed dedup on their wall time (`dedup_id` equals
        // `time_us` as text). Claim such a row for the same request — same msgID, wall time
        // within the stream/show drift — so its replay upgrades to the mach time instead of
        // inserting a second row and counting twice.
        if request.entryID != nil {
            try db.execute(
                sql: """
                    UPDATE tcc_requests SET dedup_id = ?
                    WHERE message_id = ? AND dedup_id = CAST(time_us AS TEXT)
                    AND abs(time_us - ?) <= ?
                    """,
                arguments: [request.dedupID, request.messageID, request.time.microseconds, Self.streamDriftMicros])
        }
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO tcc_requests (message_id, dedup_id, time_us, raw_event_id)
                VALUES (?, ?, ?, NULL)
                """,
            arguments: [request.messageID, request.dedupID, request.time.microseconds])
        guard db.changesCount > 0 else { return }
        let minute = request.time.microseconds / 60_000_000 * 60_000_000
        try db.execute(
            sql: """
                INSERT INTO tcc_requests_agg (minute_us, client, service, auth_value, count) VALUES (?, ?, ?, ?, 1)
                ON CONFLICT (minute_us, client, service, auth_value) DO UPDATE SET count = count + 1
                """,
            arguments: [minute, request.responsibleApp?.identifier ?? "", request.service, request.authValue])
    }

    /// Stores the TCC request that `SessionBuilder` took the activation's responsible app from.
    /// Only these requests join the hash chain: the rest live in `tcc_requests`/`tcc_requests_agg`
    /// as dedup rows and totals. The dedup row recorded at count time gets its `raw_event_id` here.
    private func storeResponsibleRequest(of activation: Activation, in db: Database) throws -> Int64? {
        guard let responsible = activation.responsible,
            let request = recentRequests.last(where: {
                $0.sensor == activation.sensor && $0.responsibleApp == responsible && $0.time <= activation.start
                    && activation.start.timeIntervalSince($0.time) <= SessionBuilder.responsibleMatchWindow
            })
        else { return nil }
        let storedID = try Int64.fetchOne(
            db,
            sql: "SELECT raw_event_id FROM tcc_requests WHERE message_id = ? AND dedup_id = ?",
            arguments: [request.messageID, request.dedupID])
        if let storedID { return storedID }
        let appended = try EventStore.append(
            .tcc, time: request.time, identity: nil, message: try canonicalJSON(request), in: db)
        try db.execute(
            sql: """
                UPDATE tcc_requests SET raw_event_id = ?
                WHERE message_id = ? AND dedup_id = ? AND raw_event_id IS NULL
                """,
            arguments: [appended.id, request.messageID, request.dedupID])
        return appended.id
    }

    private func write(_ updates: (Database) throws -> Void) throws {
        try store.pool.write(updates)
        writeCount += 1
    }

    private func prune(at time: Date) {
        let eventCutoff = time.addingTimeInterval(-(SessionBuilder.unattributedGrace + 1)).microseconds
        recentEvents = recentEvents.filter { $0.key >= eventCutoff }
        recentRequests.removeAll { time.timeIntervalSince($0.time) > SessionBuilder.responsibleMatchWindow }
    }
}

extension HardwareChange {
    /// The `raw_events` message for a hardware change: `camera MacBook Pro Camera on`.
    var message: String { "\(sensor.rawValue) \(device) \(isRunning ? "on" : "off")" }

    init?(message: String, time: Date) {
        let words = message.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count >= 3, let sensor = Sensor(rawValue: String(words[0])), ["on", "off"].contains(words.last) else { return nil }
        self.init(time: time, sensor: sensor, device: words.dropFirst().dropLast().joined(separator: " "), isRunning: words.last == "on")
    }
}
