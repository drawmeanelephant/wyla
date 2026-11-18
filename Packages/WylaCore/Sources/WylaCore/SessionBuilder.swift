import Foundation

/// An input to `SessionBuilder`. Inputs must arrive in timestamp order.
public enum BuilderInput: Sendable, Equatable {
    case indicator(IndicatorEvent, time: Date)
    case hardware(HardwareChange)
    case tccRequest(TCCRequest)

    public var time: Date {
        switch self {
        case .indicator(_, let time): time
        case .hardware(let change): change.time
        case .tccRequest(let request): request.time
        }
    }
}

/// Turns attribution sets, hardware changes, and TCC requests into activations.
///
/// - Each attribution set is diffed against the open activations: new entries start activations
///   and missing entries end them.
/// - Camera or microphone hardware running with no attributed activation of that sensor is
///   uncovered. Uncovered time becomes an unattributed activation once it lasts
///   `unattributedGrace`, or immediately if the hardware turns off before any attribution arrives.
///   Uncovered time that follows an attributed activation and ends with the hardware turning off
///   within the grace period is the normal shutdown lag and records nothing.
/// - A command-line client is linked to the app TCC held responsible for the most recent matching
///   TCC request in the `responsibleMatchWindow` before it started.
public struct SessionBuilder: Sendable {
    public static let unattributedGrace: TimeInterval = 3
    public static let responsibleMatchWindow: TimeInterval = 0.5

    private struct Uncovered: Sendable {
        var activation: Activation
        /// True when the hardware turned on with no attribution, false when an attribution ended
        /// while the hardware kept running.
        let leading: Bool
    }

    private var open: [ActivationKey: Activation] = [:]
    private var uncovered: [Sensor: Uncovered] = [:]
    private var runningSince: [Sensor: [String: Date]] = [:]
    private var recentRequests: [TCCRequest] = []

    public init() {}

    /// Resumes after a restart with the activations that were open when the agent stopped.
    /// Replay the current hardware state next, then the backfilled log events.
    public init(restoring activations: [Activation]) {
        for activation in activations where activation.end == nil {
            open[activation.key] = activation
        }
    }

    /// The activations in progress, with device use counted up to `time`. Store these so a
    /// restarted builder can resume them.
    public mutating func snapshot(at time: Date) -> [Activation] {
        for sensor in Sensor.allCases {
            countDeviceUse(of: sensor, until: time)
        }
        return open.values.sorted { ($0.start, $0.sensor.rawValue) < ($1.start, $1.sensor.rawValue) }
    }

    public mutating func consume(_ input: BuilderInput) -> [ActivationEvent] {
        var events = advance(to: input.time)
        switch input {
        case .indicator(.active(let attributions, _), let time):
            events += applyAttributions(attributions, at: time)
        case .indicator(.ended(let attribution, let displayName), _):
            open[ActivationKey(sensor: attribution.sensor, client: attribution.client)]?.displayName = displayName
        case .hardware(let change):
            events += applyHardware(change)
        case .tccRequest(let request):
            recentRequests.append(request)
        }
        return events
    }

    /// Lets time pass without input, so that uncovered hardware use past the grace period starts
    /// an unattributed activation.
    public mutating func advance(to time: Date) -> [ActivationEvent] {
        recentRequests.removeAll { time.timeIntervalSince($0.time) > Self.responsibleMatchWindow }
        var events: [ActivationEvent] = []
        for (sensor, pending) in uncovered.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where time.timeIntervalSince(pending.activation.start) >= Self.unattributedGrace {
            uncovered[sensor] = nil
            open[pending.activation.key] = pending.activation
            events.append(.started(pending.activation))
        }
        return events
    }

    /// Ends every open activation, for when the agent restarted and the system log no longer has
    /// the activations' ends. Use the agent's last heartbeat as `time`.
    public mutating func closeAll(at time: Date, reason: EndReason) -> [ActivationEvent] {
        let keys = open.values.sorted { $0.start < $1.start }.map(\.key)
        uncovered = [:]
        return keys.compactMap { finish($0, at: time, reason: reason) }
    }

    private mutating func applyAttributions(_ attributions: Set<Attribution>, at time: Date) -> [ActivationEvent] {
        let current = Set(attributions.map { ActivationKey(sensor: $0.sensor, client: $0.client) })
        let ended = open.values.filter { $0.isAttributed && !current.contains($0.key) }.sorted { $0.start < $1.start }
        var events = ended.compactMap { finish($0.key, at: time, reason: .stopped) }
        let started = attributions.filter { open[ActivationKey(sensor: $0.sensor, client: $0.client)] == nil }
        var startedEvents: [ActivationEvent] = []
        for attribution in started.sorted(by: { ($0.sensor.rawValue, $0.client) < ($1.sensor.rawValue, $1.client) }) {
            var activation = Activation(sensor: attribution.sensor, client: attribution.client, start: time)
            if attribution.isExecutableName {
                activation.responsible = responsibleApp(for: attribution, at: time, current: attributions)
            }
            countDeviceUse(of: attribution.sensor, until: time)
            open[activation.key] = activation
            startedEvents.append(.started(activation))
        }
        // Coverage changes end unattributed use, which comes before the starts that explain it.
        for sensor in Set(ended.map(\.sensor)).union(started.map(\.sensor)).sorted(by: { $0.rawValue < $1.rawValue }) {
            events += updateCoverage(of: sensor, at: time, cause: .attributionChange)
        }
        return events + startedEvents
    }

    private mutating func applyHardware(_ change: HardwareChange) -> [ActivationEvent] {
        let wasRunning = runningSince[change.sensor]?[change.device] != nil
        guard wasRunning != change.isRunning else { return [] }
        countDeviceUse(of: change.sensor, until: change.time)
        runningSince[change.sensor, default: [:]][change.device] = change.isRunning ? change.time : nil
        return updateCoverage(of: change.sensor, at: change.time, cause: change.isRunning ? .hardwareOn : .hardwareOff)
    }

    private enum CoverageChange { case attributionChange, hardwareOn, hardwareOff }

    private mutating func updateCoverage(of sensor: Sensor, at time: Date, cause: CoverageChange) -> [ActivationEvent] {
        let hardwareRunning = !(runningSince[sensor] ?? [:]).isEmpty
        let attributed = open.values.contains { $0.sensor == sensor && $0.isAttributed }
        let unattributedKey = ActivationKey(sensor: sensor, client: nil)
        if hardwareRunning && !attributed {
            if open[unattributedKey] == nil && uncovered[sensor] == nil {
                uncovered[sensor] = Uncovered(
                    activation: Activation(sensor: sensor, client: nil, start: time), leading: cause == .hardwareOn)
            }
            return []
        }
        if open[unattributedKey] != nil {
            return [finish(unattributedKey, at: time, reason: .stopped)].compactMap { $0 }
        }
        guard let pending = uncovered.removeValue(forKey: sensor), pending.leading, !hardwareRunning else { return [] }
        var activation = pending.activation
        activation.end = time
        activation.endReason = .stopped
        return [.started(pending.activation), .ended(activation)]
    }

    private mutating func finish(_ key: ActivationKey, at time: Date, reason: EndReason) -> ActivationEvent? {
        countDeviceUse(of: key.sensor, until: time)
        guard var activation = open.removeValue(forKey: key) else { return nil }
        // The last heartbeat can precede an activation that started after it.
        activation.end = max(time, activation.start)
        activation.endReason = reason
        return .ended(activation)
    }

    /// Adds the running time of each device of `sensor` to the open and uncovered activations of that sensor.
    private mutating func countDeviceUse(of sensor: Sensor, until time: Date) {
        let running = runningSince[sensor] ?? [:]
        for key in open.keys where key.sensor == sensor {
            open[key]?.countDeviceUse(running, until: time)
        }
        uncovered[sensor]?.activation.countDeviceUse(running, until: time)
    }

    private func responsibleApp(for attribution: Attribution, at time: Date, current: Set<Attribution>) -> TCCProcess? {
        let attributedClients = Set(current.map(\.client))
        return recentRequests.last { request in
            request.sensor == attribution.sensor && time.timeIntervalSince(request.time) <= Self.responsibleMatchWindow
                && request.time <= time && !attributedClients.contains(request.responsibleApp?.identifier ?? "")
        }?.responsibleApp
    }
}

extension Activation {
    fileprivate mutating func countDeviceUse(_ running: [String: Date], until time: Date) {
        for (device, since) in running {
            let from = max(since, deviceUseCountedUntil)
            if time > from {
                deviceUse[device, default: 0] += time.timeIntervalSince(from)
            }
        }
        deviceUseCountedUntil = max(deviceUseCountedUntil, time)
    }
}
