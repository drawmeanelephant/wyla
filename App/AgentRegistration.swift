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

    /// Registers the agent unless it is already enabled. macOS asks the user to allow it in Login
    /// Items the first time; until then the status is `requiresApproval`.
    func register() {
        // Tests launch the app from the build folder with `-WylaSkipAgentRegistration YES`, so
        // that they don't register a launchd agent for that copy.
        if service.status != .enabled, !UserDefaults.standard.bool(forKey: "WylaSkipAgentRegistration") {
            do {
                try service.register()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                logger.error("Agent registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
    }

    /// Registers or unregisters the launchd agent, for the launch-at-login setting.
    func setEnabled(_ enabled: Bool) {
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
