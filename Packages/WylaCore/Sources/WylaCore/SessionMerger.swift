import Foundation

/// Activations of one client on one sensor, joined when they are less than the merge window apart.
/// The viewer shows sessions; storage keeps every activation.
public struct Session: Sendable, Equatable {
    public let activations: [Activation]

    public var sensor: Sensor { activations[0].sensor }
    public var client: String? { activations[0].client }
    public var start: Date { activations[0].start }
    /// nil while the last activation is still open.
    public var end: Date? { activations[activations.count - 1].end }
    public var displayName: String? { activations.last { $0.displayName != nil }?.displayName }
    public var responsible: TCCProcess? { activations.last { $0.responsible != nil }?.responsible }
    /// The devices the activations used, in the order they were first used.
    public var devices: [String] {
        var seen = Set<String>()
        return activations.compactMap(\.device).filter { seen.insert($0).inserted }
    }

    /// Seconds from the session's start to its end, or to `now` while it is still running.
    public func duration(asOf now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }

    /// The `raw_events` rows behind the session's activations.
    public var eventIDs: [Int64] {
        activations.flatMap { [$0.startEventID, $0.endEventID, $0.responsibleEventID] }.compactMap(\.self)
    }

    /// Identified by its first activation.
    public var id: String { activations[0].id }
}

extension Session: Identifiable {}

public enum SessionMerger {
    public static let defaultWindow: TimeInterval = 2

    /// Groups activations into sessions, sorted by start time.
    public static func merge(_ activations: [Activation], window: TimeInterval = defaultWindow) -> [Session] {
        var groups: [ActivationKey: [[Activation]]] = [:]
        for activation in activations.sorted(by: { $0.start < $1.start }) {
            var sessions = groups[activation.key, default: []]
            if let previousEnd = sessions.last?.last?.end, activation.start.timeIntervalSince(previousEnd) < window {
                sessions[sessions.count - 1].append(activation)
            } else {
                sessions.append([activation])
            }
            groups[activation.key] = sessions
        }
        return groups.values.joined().map(Session.init(activations:)).sorted {
            ($0.start, $0.sensor.rawValue, $0.client ?? "") < ($1.start, $1.sensor.rawValue, $1.client ?? "")
        }
    }
}
