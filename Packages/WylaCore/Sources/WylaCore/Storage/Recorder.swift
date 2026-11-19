import Foundation
import GRDB

/// An event from one of the agent's sources.
public enum RecorderInput: Sendable, Equatable {
    /// A Control Center `sensor-indicators` log line.
    case indicator(LogEvent)
    /// A completed TCC access check. Only checks that link a command-line client to its
    /// responsible app are stored.
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
/// lines that overlap what was recorded changes nothing. Inputs must arrive in timestamp order.
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

    /// Starts an agent run at `time` and resumes the activations that were open when the previous
    /// run stopped. Record the current hardware state next, then the backfilled log events.
    public init(store: EventStore, startingAt time: Date) throws {
        self.store = store
        (previousHeartbeat, runID, builder) = try store.pool.write { db in
            let previous = try Int64.fetchOne(db, sql: "SELECT max(last_heartbeat_us) FROM coverage")
            try db.execute(
                sql: "INSERT INTO coverage (started_us, last_heartbeat_us) VALUES (?, ?)",
                arguments: [time.microseconds, time.microseconds])
            let open = try Row.fetchAll(db, sql: "SELECT * FROM activations WHERE end_us IS NULL").map(Activation.init(row:))
            return (previous.map(Date.init(microseconds:)), db.lastInsertedRowID, SessionBuilder(restoring: open))
        }
    }

    @discardableResult
    public func record(_ input: RecorderInput) throws -> [ActivationEvent] {
        let time = input.time
        prune(at: time)
        switch input {
        case .indicator(let event):
            checkpoints[.indicator] = max(checkpoints[.indicator] ?? time, time)
            let raw = RawInput(source: .indicator, time: time, message: event.message)
            switch parser.parse(event.message) {
            case .ignored: return []
            // Unparsed lines are kept for the Health view and for audit.
            case .unparsed: return try apply(raw, nil, at: time)
            case .event(let indicator): return try apply(raw, .indicator(indicator, time: time), at: time)
            }
        case .tccRequest(let request):
            checkpoints[.tcc] = max(checkpoints[.tcc] ?? time, time)
            recentRequests.append(request)
            return try apply(nil, .tccRequest(request), at: time)
        case .hardware(let change):
            return try apply(RawInput(source: .hardware, time: time, message: change.message), .hardware(change), at: time)
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
        try store.pool.write { db in
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
        try store.pool.write { db in try persist(events, currentEvent: nil, in: db) }
        builder = next
        return events
    }

    private struct RawInput {
        let source: RawEventSource
        let time: Date
        let message: String
    }

    /// Stores the raw event if it is new, runs the builder, and stores the activation changes, all
    /// in one transaction. The builder is updated only after the transaction commits.
    private func apply(_ raw: RawInput?, _ input: BuilderInput?, at time: Date) throws -> [ActivationEvent] {
        var next = builder
        var events: [ActivationEvent] = []
        var stored: EventStore.Appended?
        if let raw {
            try store.pool.write { db in
                let appended = try EventStore.append(raw.source, time: raw.time, message: raw.message, in: db)
                stored = appended
                guard appended.isNew else { return }
                events = input.map { next.consume($0) } ?? next.advance(to: time)
                try persist(events, currentEvent: (time.microseconds, appended.id), in: db)
            }
        } else {
            events = input.map { next.consume($0) } ?? next.advance(to: time)
            if !events.isEmpty {
                try store.pool.write { db in try persist(events, currentEvent: nil, in: db) }
            }
        }
        if let stored {
            recentEvents[time.microseconds] = stored.id
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

    /// Stores the TCC request that `SessionBuilder` took the activation's responsible app from.
    private func storeResponsibleRequest(of activation: Activation, in db: Database) throws -> Int64? {
        guard let responsible = activation.responsible,
            let request = recentRequests.last(where: {
                $0.sensor == activation.sensor && $0.responsibleApp == responsible && $0.time <= activation.start
                    && activation.start.timeIntervalSince($0.time) <= SessionBuilder.responsibleMatchWindow
            })
        else { return nil }
        return try EventStore.append(.tcc, time: request.time, message: try canonicalJSON(request), in: db).id
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
}
