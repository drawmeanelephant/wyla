import Foundation

/// The timeline's filters. A nil field matches everything.
public struct SessionQuery: Sendable, Equatable {
    public var sensor: Sensor?
    /// Only sessions attributed to this client.
    public var client: String?
    /// Free text, matched case-insensitively against the client, its display name, its devices,
    /// and its responsible app.
    public var text = ""
    /// Only sessions overlapping this range. Open sessions count as still running at `now`.
    public var range: Range<Date>?

    public init(sensor: Sensor? = nil, client: String? = nil, text: String = "", range: Range<Date>? = nil) {
        self.sensor = sensor
        self.client = client
        self.text = text
        self.range = range
    }

    public var isEmpty: Bool { sensor == nil && client == nil && text.isEmpty && range == nil }

    public func matches(_ session: Session, asOf now: Date = .now) -> Bool {
        if let sensor, session.sensor != sensor { return false }
        if let client, session.client != client { return false }
        if let range {
            // Clamp like `Session.duration(asOf:)`: `now` can precede the session's start when it
            // is a dead agent's last heartbeat.
            let sessionEnd = max(session.start, session.end ?? now)
            guard session.start < range.upperBound, sessionEnd >= range.lowerBound else { return false }
        }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            let fields = [session.client, session.displayName, session.responsible?.identifier] + session.devices
            guard fields.contains(where: { $0?.lowercased().contains(needle) == true }) else { return false }
        }
        return true
    }

    public func apply(to sessions: [Session], asOf now: Date = .now) -> [Session] {
        sessions.filter { matches($0, asOf: now) }
    }
}
