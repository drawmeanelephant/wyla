import Foundation

/// How one client used the sensors, summed over its sessions.
public struct AppSummary: Sendable, Equatable {
    /// The client, or nil for hardware use no app was attributed to.
    public let client: String?
    /// Sessions per sensor.
    public var counts: [Sensor: Int] = [:]
    /// Activations per sensor: the raw on/off events before `SessionMerger` joins them.
    public var activationCounts: [Sensor: Int] = [:]
    /// Total session time in seconds.
    public var duration: TimeInterval = 0
    public var firstUse: Date
    public var lastUse: Date

    /// The client, or a marker for unattributed hardware use.
    public var id: String { client ?? "(unattributed)" }

    init(client: String?, firstUse: Date) {
        self.client = client
        self.firstUse = firstUse
        self.lastUse = firstUse
    }

    /// One summary per client, ordered by total time descending then name. `activations` are
    /// the pre-merge units `sessions` were built from, for the per-sensor activation counts.
    public static func all(from sessions: [Session], activations: [Activation] = [], asOf now: Date) -> [AppSummary] {
        var byClient: [String?: AppSummary] = [:]
        for session in sessions {
            var summary = byClient[session.client] ?? AppSummary(client: session.client, firstUse: session.start)
            summary.counts[session.sensor, default: 0] += 1
            summary.duration += session.duration(asOf: now)
            summary.firstUse = min(summary.firstUse, session.start)
            summary.lastUse = max(summary.lastUse, session.end ?? max(session.start, now))
            byClient[session.client] = summary
        }
        for activation in activations {
            if var summary = byClient[activation.client] {
                summary.activationCounts[activation.sensor, default: 0] += 1
                byClient[activation.client] = summary
            }
        }
        return byClient.values.sorted {
            ($0.duration, $0.client ?? "") > ($1.duration, $1.client ?? "")
        }
    }
}

extension AppSummary: Identifiable {}

/// One client's use of a sensor on one day, for the history chart.
public struct DailyUse: Sendable, Equatable, Hashable {
    /// Start of the day the sessions began in.
    public let day: Date
    public let sensor: Sensor
    public var sessions = 0
    public var duration: TimeInterval = 0

    /// Buckets `sessions` by the day and sensor they started on, ordered by day.
    public static func of(_ sessions: [Session], asOf now: Date, calendar: Calendar = .current) -> [DailyUse] {
        var buckets: [Date: [Sensor: DailyUse]] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.start)
            var use = buckets[day, default: [:]][session.sensor] ?? DailyUse(day: day, sensor: session.sensor)
            use.sessions += 1
            use.duration += session.duration(asOf: now)
            buckets[day, default: [:]][session.sensor] = use
        }
        return buckets.sorted { $0.key < $1.key }.flatMap(\.value.values).sorted {
            ($0.day, $0.sensor.rawValue) < ($1.day, $1.sensor.rawValue)
        }
    }
}
