import AppKit
import CoreFoundation
import Foundation
import WylaCore

/// The `CFNotificationCenter` observer's context object: forwards the Darwin notification to a
/// Swift closure.
private final class NotificationRelay: @unchecked Sendable {
    var onChange: (() -> Void)?
}

private func darwinChange(
    _ center: CFNotificationCenter?, _ observer: UnsafeMutableRawPointer?, _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?, _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    Unmanaged<NotificationRelay>.fromOpaque(observer).takeUnretainedValue().onChange?()
}

/// What the viewer shows, read from the agent's database and reloaded when the agent posts the
/// Darwin change notification.
@MainActor @Observable
final class Store {
    private(set) var activations: [Activation] = []
    private(set) var sessions: [Session] = []
    private(set) var apps: [String: StoredApp] = [:]
    /// Set when the database can't be opened or read.
    private(set) var loadError: String?

    private var store: EventStore?
    /// The agent's last heartbeat; a stale one means it died leaving activations open.
    private(set) var lastHeartbeat: Date?
    /// The object the Darwin notification callback is registered for.
    private let relay = NotificationRelay()

    /// The agent heartbeats every 30 s while idle and every 5 s while an activation is open, so a
    /// heartbeat older than this belongs to a dead agent.
    static let livenessWindow: TimeInterval = 45

    /// Tests set `WYLA_DATABASE` to view a database other than the agent's.
    static func databaseURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["WYLA_DATABASE"] {
            return URL(fileURLWithPath: path)
        }
        return EventStore.defaultURL
    }

    init() {
        do {
            store = try EventStore(url: Self.databaseURL())
        } catch {
            store = nil
            loadError = error.localizedDescription
            lastHeartbeat = nil
        }
        reload()
        relay.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(relay).toOpaque(),
            darwinChange,
            EventStore.changeNotification as CFString,
            nil,
            .deliverImmediately)
    }

    isolated deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(relay).toOpaque(),
            CFNotificationName(EventStore.changeNotification as CFString),
            nil)
    }

    func reload() {
        // Retry opening: on first launch the agent can still be creating the database.
        if store == nil {
            do {
                store = try EventStore(url: Self.databaseURL())
            } catch {
                loadError = error.localizedDescription
            }
        }
        guard let store else { return }
        do {
            activations = try store.activations()
            sessions = SessionMerger.merge(activations)
            apps = Dictionary(try store.apps().map { ($0.client, $0) }, uniquingKeysWith: { first, _ in first })
            lastHeartbeat = try store.lastHeartbeat()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Whether the agent reported itself alive recently.
    var monitoringLive: Bool {
        guard let lastHeartbeat else { return false }
        return Date.now.timeIntervalSince(lastHeartbeat) < Self.livenessWindow
    }

    /// What "now" means to the viewer: the present while the agent runs, its last heartbeat once
    /// it is dead, so a session it left open stops growing. Never earlier than the newest open
    /// activation's start, which the agent recorded after that heartbeat.
    var liveAsOf: Date {
        if monitoringLive { return .now }
        let lastStart = activations.filter { $0.end == nil }.map(\.start).max() ?? .distantPast
        return max(lastHeartbeat ?? .now, lastStart)
    }

    /// The activations still running, latest first. Empty when the agent is dead: the open
    /// activations it left behind ended no later than its last heartbeat.
    var activeNow: [Activation] {
        guard monitoringLive else { return [] }
        return activations.filter { $0.end == nil }.sorted { $0.start > $1.start }
    }

    /// Sessions that started today, per sensor.
    var todayCounts: [Sensor: Int] {
        let today = Calendar.current.startOfDay(for: .now)
        var counts: [Sensor: Int] = [:]
        for session in sessions where session.start >= today {
            counts[session.sensor, default: 0] += 1
        }
        return counts
    }

    func rawEvents(for session: Session) throws -> [RawEvent] {
        guard let store else { return [] }
        return try store.rawEvents(withIDs: session.eventIDs)
    }

    /// The name to show for a client: its `apps` name, the name the system log saw, or its
    /// bundle identifier or executable name.
    func name(of session: Session) -> String {
        if let client = session.client {
            return apps[client]?.name ?? session.displayName ?? client
        }
        return "Unattributed"
    }

    func icon(of session: Session) -> NSImage {
        Self.icon(for: session.client.flatMap { apps[$0] })
    }

    func icon(of app: AppSummary) -> NSImage {
        Self.icon(for: app.client.flatMap { apps[$0] })
    }

    /// The app's icon when its path is known, a generic app icon otherwise.
    static func icon(for app: StoredApp?) -> NSImage {
        if let path = app?.path.flatMap(Self.bundlePath) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }

    /// The `.app` bundle a path belongs to, if any: `/X/Y.app/Contents/MacOS/Y` → `/X/Y.app`.
    static func bundlePath(_ path: String) -> String? {
        guard let range = path.range(of: ".app", options: .backwards) else { return nil }
        return String(path[path.startIndex..<range.upperBound])
    }
}

extension Sensor {
    /// The symbol the menu bar and tables show for the sensor.
    var icon: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screen: "display"
        }
    }
}
