import Foundation
import GRDB

/// A row of `apps`: a client or responsible app WYLA has seen.
public struct StoredApp: Sendable, Equatable {
    public let client: String
    /// The app's name from Launch Services or the system log.
    public let name: String?
    /// Its `.app` path when Launch Services knows it, or the binary path TCC logged for a
    /// responsible app.
    public let path: String?
    /// The signing Team ID, when the app has one.
    public let teamID: String?
    public let firstSeen: Date
    public let lastSeen: Date
    /// True for command-line executables like `bash`, which have no bundle identifier.
    public let commandLine: Bool

    public init(client: String, name: String?, path: String?, teamID: String?, firstSeen: Date, lastSeen: Date, commandLine: Bool) {
        self.client = client
        self.name = name
        self.path = path
        self.teamID = teamID
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.commandLine = commandLine
    }

    init(row: Row) {
        self.init(
            client: row["client"], name: row["name"], path: row["path"], teamID: row["team_id"],
            firstSeen: Date(microseconds: row["first_seen_us"]), lastSeen: Date(microseconds: row["last_seen_us"]),
            commandLine: (row["command_line"] as Int64) != 0)
    }
}

/// A `raw_events` row, for the session detail view and exports.
public struct RawEvent: Sendable, Equatable {
    public let id: Int64
    public let time: Date
    /// A `RawEventSource` raw value. Kept as text so that unknown values still display.
    public let source: String
    /// The log line or stored message, as recorded.
    public let message: String

    public init(id: Int64, time: Date, source: String, message: String) {
        self.id = id
        self.time = time
        self.source = source
        self.message = message
    }

    init(row: Row) {
        self.init(id: row["id"], time: Date(microseconds: row["time_us"]), source: row["source"], message: row["message"])
    }
}

extension RawEvent: Identifiable {}
