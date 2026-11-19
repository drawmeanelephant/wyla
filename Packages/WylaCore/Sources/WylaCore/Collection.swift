import Foundation

/// Holds inputs from the log stream and the hardware listeners briefly, and releases them in
/// timestamp order. The log stream delivers an event some time after it happened, while the
/// hardware listeners see a change as it happens.
public struct ReorderBuffer: Sendable {
    public let delay: TimeInterval
    private var pending: [(sequence: Int, input: RecorderInput)] = []
    private var sequence = 0

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func insert(_ input: RecorderInput) {
        pending.append((sequence, input))
        sequence += 1
    }

    /// Releases the inputs that happened at least `delay` before `now`, oldest first. Inputs with
    /// the same time keep their arrival order.
    public mutating func release(at now: Date) -> [RecorderInput] {
        let cutoff = now.addingTimeInterval(-delay)
        return take { $0.input.time <= cutoff }
    }

    /// Releases every input, for when a source restarts.
    public mutating func releaseAll() -> [RecorderInput] {
        take { _ in true }
    }

    private mutating func take(where shouldRelease: ((sequence: Int, input: RecorderInput)) -> Bool) -> [RecorderInput] {
        let released = pending.filter(shouldRelease)
        pending.removeAll(where: shouldRelease)
        return released.sorted { ($0.input.time, $0.sequence) < ($1.input.time, $1.sequence) }.map(\.input)
    }
}

/// The camera and microphone devices that are running, compared between scans.
public struct HardwareState: Sendable {
    private var running: [Sensor: Set<String>] = [:]

    public init() {}

    /// Takes the names of the devices of `sensor` that are running now, and returns a change for
    /// each device that started or stopped. A running device that disappears counts as stopped.
    public mutating func update(_ sensor: Sensor, running now: Set<String>, at time: Date) -> [HardwareChange] {
        let before = running[sensor] ?? []
        running[sensor] = now
        let stopped = before.subtracting(now).sorted().map {
            HardwareChange(time: time, sensor: sensor, device: $0, isRunning: false)
        }
        let started = now.subtracting(before).sorted().map {
            HardwareChange(time: time, sensor: sensor, device: $0, isRunning: true)
        }
        return stopped + started
    }
}

/// The delay before restarting a child process that exited.
public struct RestartBackoff: Sendable {
    public static let initialDelay: TimeInterval = 1
    public static let maximumDelay: TimeInterval = 60
    /// A process that ran at least this long was healthy, so the delay starts over.
    public static let healthyRun: TimeInterval = 60

    private var next = initialDelay

    public init() {}

    public mutating func delay(afterRunning duration: TimeInterval) -> TimeInterval {
        if duration >= Self.healthyRun {
            next = Self.initialDelay
        }
        let delay = next
        next = min(next * 2, Self.maximumDelay)
        return delay
    }
}
