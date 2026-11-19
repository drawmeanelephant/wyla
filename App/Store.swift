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
    private(set) var requests: [TCCSummary] = []
    /// The shared settings, also read by the agent; the Settings tab edits them.
    private(set) var settings: Settings
    /// Set when the database can't be opened or read.
    private(set) var loadError: String?

    private var store: EventStore?
    /// Where the settings file lives: next to the database, so the agent reads the same file.
    private let settingsURL: URL
    /// The agent's last heartbeat; a stale one means it died leaving activations open.
    private(set) var lastHeartbeat: Date?
    /// Whether the agent reported itself alive recently.
    private(set) var monitoringLive = false
    /// The object the Darwin notification callback is registered for.
    private let relay = NotificationRelay()
    /// Re-evaluates heartbeat staleness while nothing is writing: a dead agent posts no
    /// notification, so without it "in use" would never clear.
    private var livenessTimer: Timer?
    /// One reload at a time; notifications that arrive while one runs fold into a single
    /// trailing reload, so heartbeat writes don't queue up merge work.
    private var reloadInFlight = false
    private var reloadPending = false

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
        settingsURL = Settings.url(near: Self.databaseURL())
        settings = Settings.load(from: settingsURL)
        do {
            store = try EventStore(url: Self.databaseURL())
        } catch {
            store = nil
            loadError = error.localizedDescription
            lastHeartbeat = nil
        }
        reload()
        refreshLiveness()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveness() }
        }
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
        livenessTimer?.invalidate()
    }

    /// What one read of the database produces. Sendable so it can cross back to the main actor.
    private struct Snapshot: Sendable {
        let activations: [Activation]
        let sessions: [Session]
        let apps: [String: StoredApp]
        let requests: [TCCSummary]
        let heartbeat: Date?
    }

    /// Reads the database and merges sessions off the main actor; with ~50k rows that takes
    /// ~0.7 s, which would otherwise stall the window on every heartbeat write.
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
        guard !reloadInFlight else {
            reloadPending = true
            return
        }
        reloadInFlight = true
        let mergeWindow = settings.mergeWindow
        Task.detached { [weak self] in
            let snapshot: Snapshot
            do {
                let activations = try store.activations()
                snapshot = Snapshot(
                    activations: activations,
                    sessions: SessionMerger.merge(activations, window: mergeWindow),
                    apps: Dictionary(try store.apps().map { ($0.client, $0) }, uniquingKeysWith: { first, _ in first }),
                    requests: try store.tccRequestTotals(),
                    heartbeat: try store.lastHeartbeat())
            } catch {
                await self?.finishReload(result: .failure(error))
                return
            }
            await self?.finishReload(result: .success(snapshot))
        }
    }

    private func finishReload(result: Result<Snapshot, Error>) {
        reloadInFlight = false
        switch result {
        case .success(let snapshot):
            activations = snapshot.activations
            sessions = snapshot.sessions
            apps = snapshot.apps
            requests = snapshot.requests
            lastHeartbeat = snapshot.heartbeat
            loadError = nil
            refreshLiveness()
        case .failure(let error):
            loadError = error.localizedDescription
        }
        if reloadPending {
            reloadPending = false
            reload()
        }
    }

    private func refreshLiveness() {
        monitoringLive = lastHeartbeat.map { Date.now.timeIntervalSince($0) < Self.livenessWindow } ?? false
    }

    /// What "now" means to the viewer: the present while the agent runs, its last heartbeat once
    /// it is dead, so a session it left open stops growing. A session that started after the last
    /// heartbeat clamps itself to its own start instead of going negative or stretching the
    /// sessions that were already open.
    var liveAsOf: Date {
        monitoringLive ? .now : lastHeartbeat ?? .now
    }

    /// The activations still running, latest first. Empty when the agent is dead: the open
    /// activations it left behind ended no later than its last heartbeat.
    var activeNow: [Activation] {
        guard monitoringLive else { return [] }
        return Array(activations.filter { $0.end == nil }.reversed())
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

    /// Per-day check totals for one client's service, for the Requests history chart; reads off
    /// the main actor.
    func requestDaily(client: String, service: String) async throws -> [EventStore.TCCDailyCount] {
        guard let store else { return [] }
        return try await Task.detached {
            try store.tccRequestDaily(client: client, service: service)
        }.value
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

    /// The name to show for a requesting client: its `apps` name when resolved, else the raw
    /// identifier or "Unknown" when TCC named no process.
    func name(of request: TCCSummary) -> String {
        if request.client.isEmpty { return "Unknown" }
        return apps[request.client]?.name ?? request.client
    }

    func icon(of request: TCCSummary) -> NSImage {
        Self.icon(for: apps[request.client])
    }

    /// Saves the settings the Settings tab edited, next to the database where the agent reads
    /// them, and re-merges the sessions when the merge window changed.
    func updateSettings(_ edited: Settings) throws {
        try edited.save(to: settingsURL)
        settings = edited
        sessions = SessionMerger.merge(activations, window: edited.mergeWindow)
    }

    /// What the Health tab shows: the collector's coverage and the log quality it left.
    func health() throws -> HealthInfo {
        guard let store else { throw StoreError.noDatabase }
        let coverage = try store.coverage()
        var gaps: [(start: Date, end: Date)] = []
        for index in coverage.indices.dropFirst() {
            let previous = coverage[index - 1]
            let current = coverage[index]
            if current.start > previous.end {
                gaps.append((previous.end, current.start))
            }
        }
        return HealthInfo(
            coverage: coverage, gaps: gaps, unparsedLines: try store.unparsedIndicatorCount(),
            lastAnchor: try AnchorLog.latest(from: AnchorLog.url(near: Self.databaseURL())))
    }

    /// Recomputes the hash chain and checks it against the latest exported anchor.
    func verifyIntegrity() throws -> IntegrityReport {
        guard let store else { throw StoreError.noDatabase }
        return try store.verifyIntegrity(anchor: try AnchorLog.latest(from: AnchorLog.url(near: Self.databaseURL())))
    }

    /// Writes the range's raw events and sessions into `directory`, as CSV and JSON.
    func export(from: Date, to end: Date, into directory: URL) throws -> ExportManifest {
        guard let store else { throw StoreError.noDatabase }
        return try AuditExport.write(store: store, from: from, to: end, to: directory)
    }

    enum StoreError: LocalizedError {
        case noDatabase
        var errorDescription: String? { "The log database is not open" }
    }

    /// The app's icon when its bundle resolves to the client, a generic app icon otherwise.
    /// The bundle identifier is checked because an `.app` suffix in the path does not prove the
    /// bundle is the client's.
    static func icon(for app: StoredApp?) -> NSImage {
        let bundlePath = app?.path.flatMap(Self.bundlePath)
        let resolvesToClient = bundlePath.map { Bundle(path: $0)?.bundleIdentifier == app?.client } ?? false
        if let path = bundlePath, resolvesToClient {
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

/// The data behind the Health tab.
struct HealthInfo {
    /// Each agent run's monitored span, oldest first.
    var coverage: [(start: Date, end: Date)]
    /// Spans between runs when nothing was monitoring.
    var gaps: [(start: Date, end: Date)]
    /// Stored log lines the parser rejects.
    var unparsedLines: Int
    /// The newest chain head the agent exported, if anchor export is on.
    var lastAnchor: ChainAnchor?
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
