import Foundation

/// The timeline's filters. A nil field matches everything.
public struct SessionQuery: Sendable, Equatable {
    public var sensor: Sensor?
    /// Only sessions attributed to this client.
    public var client: String?
    /// Only sessions with no attributed client. Overrides `client`.
    public var unattributedOnly = false
    /// Free text, matched case-insensitively against the client, its display name, its devices,
    /// its responsible app, and its resolved app name.
    public var text = ""
    /// Only sessions overlapping this range. Open sessions count as still running at `now`.
    public var range: Range<Date>?
    /// Resolved names by client (`EventStore.apps()`), so text also matches the name the table
    /// shows, not only the raw identifier the log recorded.
    public var resolvedNames: [String: String] = [:]

    public init(
        sensor: Sensor? = nil, client: String? = nil, unattributedOnly: Bool = false, text: String = "",
        range: Range<Date>? = nil, resolvedNames: [String: String] = [:]
    ) {
        self.sensor = sensor
        self.client = client
        self.unattributedOnly = unattributedOnly
        self.text = text
        self.range = range
        self.resolvedNames = resolvedNames
    }

    public var isEmpty: Bool { sensor == nil && client == nil && !unattributedOnly && text.isEmpty && range == nil }

    public func matches(_ session: Session, asOf now: Date = .now) -> Bool {
        if let sensor, session.sensor != sensor { return false }
        if unattributedOnly {
            if session.client != nil { return false }
        } else if let client, session.client != client {
            return false
        }
        if let range {
            // Clamp like `Session.duration(asOf:)`: `now` can precede the session's start when it
            // is a dead agent's last heartbeat.
            let sessionEnd = max(session.start, session.end ?? now)
            guard session.start < range.upperBound, sessionEnd >= range.lowerBound else { return false }
        }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            let fields =
                [
                    session.client, session.displayName, session.responsible?.identifier,
                    session.client.flatMap { resolvedNames[$0] }
                ] + session.devices
            guard fields.contains(where: { $0?.lowercased().contains(needle) == true }) else { return false }
        }
        return true
    }

    public func apply(to sessions: [Session], asOf now: Date = .now) -> [Session] {
        sessions.filter { matches($0, asOf: now) }
    }
}
