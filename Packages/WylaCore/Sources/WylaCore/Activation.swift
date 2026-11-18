import Foundation

/// A camera or microphone device turning on or off, from CoreMediaIO or CoreAudio.
public struct HardwareChange: Sendable, Equatable {
    public let time: Date
    public let sensor: Sensor
    public let device: String
    public let isRunning: Bool

    public init(time: Date, sensor: Sensor, device: String, isRunning: Bool) {
        self.time = time
        self.sensor = sensor
        self.device = device
        self.isRunning = isRunning
    }
}

/// Raw values are stored in the database, so renaming a case requires a migration.
public enum EndReason: String, Codable, Sendable {
    /// The system log showed the activation end.
    case stopped
    /// The agent stopped during the activation and the system log no longer had its end.
    case agentRestart = "agent_restart"
}

/// One continuous use of a sensor by one client, or by no attributed client.
public struct Activation: Sendable, Equatable, Codable {
    public let sensor: Sensor
    /// The attributed client, or nil when hardware ran with no attribution (see `SessionBuilder`).
    public let client: String?
    public let start: Date
    public internal(set) var end: Date?
    public internal(set) var endReason: EndReason?
    public internal(set) var displayName: String?
    /// For command-line clients, the app that TCC held responsible for the access.
    public internal(set) var responsible: TCCProcess?
    /// Seconds each hardware device was running during the activation.
    public internal(set) var deviceUse: [String: TimeInterval] = [:]
    /// `deviceUse` covers the activation up to this time.
    var deviceUseCountedUntil: Date

    public init(sensor: Sensor, client: String?, start: Date) {
        self.sensor = sensor
        self.client = client
        self.start = start
        self.deviceUseCountedUntil = start
    }

    public var isAttributed: Bool { client != nil }

    /// The device that ran longest during the activation.
    public var device: String? {
        deviceUse.filter { $0.value > 0 }.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    var key: ActivationKey { ActivationKey(sensor: sensor, client: client) }
}

struct ActivationKey: Hashable, Sendable {
    let sensor: Sensor
    let client: String?
}

public enum ActivationEvent: Sendable, Equatable {
    case started(Activation)
    case ended(Activation)
}
