import Foundation
import Observation
import ServiceManagement
import os

/// Registers the collector agent with launchd through `SMAppService`, and tracks whether it runs.
@MainActor @Observable
final class AgentRegistration {
    static let plistName = "io.github.drawmeanelephant.wyla.agent.plist"

    private let service = SMAppService.agent(plistName: AgentRegistration.plistName)
    private let logger = Logger(subsystem: "io.github.drawmeanelephant.wyla", category: "app")
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    init() {
        status = service.status
    }

    /// Registers the agent unless it is already enabled for this bundle. macOS asks the user to
    /// allow it in Login Items the first time; until then the status is `requiresApproval`. When
    /// the bundle moved or was replaced since the registration that is on file, the agent is
    /// re-registered so launchd doesn't keep launching the stale copy.
    func register() {
        // Tests launch the app from the build folder with `-WylaSkipAgentRegistration YES`, so
        // that they don't register a launchd agent for that copy. `launchAtLoginOptOut` is the
        // Settings toggle's saved answer: turning launch at login off must stay off after a
        // relaunch, so the automatic registration leaves an opted-out service alone.
        let skipped = UserDefaults.standard.bool(forKey: "WylaSkipAgentRegistration")
        let optedOut = UserDefaults.standard.bool(forKey: Self.launchAtLoginOptOut)
        guard !skipped, !optedOut else {
            refresh()
            return
        }
        do {
            if service.status == .enabled, Self.registeredSignature != Self.bundleSignature {
                // Re-register: the bundle moved or was replaced since the saved signature, and
                // the status read after unregister is stale, so register unconditionally.
                try service.unregister()
                try service.register()
            } else if service.status != .enabled {
                try service.register()
            }
            Self.registeredSignature = Self.bundleSignature
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("Agent registration failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Which bundle the launchd registration was made from, so a moved or replaced bundle can
    /// be re-registered instead of silently launching the stale copy.
    private static var registeredSignature: String? {
        get { UserDefaults.standard.string(forKey: "WylaRegisteredBundle") }
        set { UserDefaults.standard.set(newValue, forKey: "WylaRegisteredBundle") }
    }

    private static var bundleSignature: String {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(Bundle.main.bundlePath)@\(version)"
    }

    /// Drops the registration; `scripts/uninstall.sh` runs the app binary with
    /// `--unregister-agent` for this before it deletes the bundle.
    static func unregister() {
        do {
            try SMAppService.agent(plistName: plistName).unregister()
        } catch {
            FileHandle.standardError.write(Data("unregister failed: \(error.localizedDescription)\n".utf8))
        }
        registeredSignature = nil
    }

    /// The user default that records an explicit launch-at-login choice, so a disabled agent
    /// is not re-registered on the next launch.
    private static let launchAtLoginOptOut = "WylaLaunchAtLoginDisabled"

    /// Registers or unregisters the launchd agent, for the launch-at-login setting.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: Self.launchAtLoginOptOut)
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("Agent \(enabled ? "registration" : "unregistration") failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var summary: String {
        switch status {
        case .enabled: "Monitoring camera, microphone, and screen"
        case .requiresApproval: "Allow WYLA in Login Items to start monitoring"
        // An agent that was never registered reports `notFound` as well as `notRegistered`.
        case .notFound, .notRegistered: lastError.map { "Not monitoring: \($0)" } ?? "Not monitoring"
        @unknown default: "Monitoring status unknown"
        }
    }
}
