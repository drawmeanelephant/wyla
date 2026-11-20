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
                To watch the sensors, WYLA installs a background agent, which needs an \
                administrator account to allow. If macOS asks, allow WYLA under System \
                Settings → General → Login Items & Extensions, or it stays off.
                """
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(registration.summary).foregroundStyle(.secondary)
            HStack {
                Button("Open Login Items & Extensions") { registration.openLoginItemsSettings() }
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
        // The status row follows the Login Items switch when the user comes back from it.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            registration.refresh()
        }
    }
}

/// Shows the onboarding window on the first run, in front of other apps.
@MainActor
enum OnboardingWindow {
    static let doneKey = "WylaOnboardingDone"

    private static var window: NSWindow?
    private static var closeObserver: (any NSObjectProtocol)?

    /// Shows onboarding unless it already ran, is already showing, or the run opts out (tests
    /// pass `-WylaOnboardingDone YES`, the same way they pass `-WylaSkipAgentRegistration YES`).
    static func showIfFirstRun(registration: AgentRegistration) {
        guard window == nil, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let view = OnboardingView(registration: registration) { close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to WYLA"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // Closing with the window's own button marks onboarding done the same as "Done".
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { didClose() }
        }
    }

    /// Closes the window; `didClose` then marks onboarding done — dismissing it counts as done
    /// either way.
    static func close() {
        window?.close()
    }

    private static func didClose() {
        UserDefaults.standard.set(true, forKey: doneKey)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }
}
