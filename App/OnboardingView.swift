import AppKit
import SwiftUI

/// The first-run window: what WYLA logs, the background agent it needs, and where to allow
/// that agent when macOS asks. Shown once, the first time the app runs; `WylaOnboardingDone`
/// in the user defaults keeps it from reappearing (tests and `scripts/qa-drive.sh` set it).
struct OnboardingView: View {
    let registration: AgentRegistration
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to WYLA").font(.title)
            Text(
                """
                WYLA keeps a local, tamper-evident log of which apps use your camera, \
                microphone, and screen recording. Everything stays on this Mac, and WYLA \
                never connects to the network.
                """
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(
                """
                To watch the sensors, WYLA installs a background agent. If macOS asks, \
                allow WYLA under System Settings → General → Login Items, or it stays off.
                """
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(registration.summary).foregroundStyle(.secondary)
            HStack {
                Button("Open Login Items Settings") { registration.openLoginItemsSettings() }
                Spacer()
                Button("Done") {
                    UserDefaults.standard.set(true, forKey: OnboardingWindow.doneKey)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Shows the onboarding window on the first run, in front of other apps.
enum OnboardingWindow {
    static let doneKey = "WylaOnboardingDone"

    private static var window: NSWindow?

    /// Shows onboarding unless it already ran or the run opts out (tests pass
    /// `-WylaOnboardingDone YES`, the same way they pass `-WylaSkipAgentRegistration YES`).
    static func showIfFirstRun(registration: AgentRegistration) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: OnboardingView(registration: registration) { window?.close() }))
        window.title = "Welcome to WYLA"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
