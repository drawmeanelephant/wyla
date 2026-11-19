import SwiftUI

@main
struct WylaApp: App {
    @State private var registration: AgentRegistration
    @State private var store: Store

    var body: some Scene {
        MenuBarExtra("WYLA", systemImage: "eye") {
            MenuBarContent(registration: registration, store: store)
        }

        Window("WYLA", id: MainWindow.id) {
            MainWindow(store: store, registration: registration)
        }
        .defaultLaunchBehavior(.suppressed)
    }

    init() {
        // `scripts/uninstall.sh` calls this to drop the SMAppService registration while the
        // bundle still exists; it exits without starting the UI.
        if CommandLine.arguments.contains("--unregister-agent") {
            AgentRegistration.unregister()
            exit(EXIT_SUCCESS)
        }
        let registration = AgentRegistration()
        registration.register()
        _registration = State(initialValue: registration)
        _store = State(initialValue: Store())
        OnboardingWindow.showIfFirstRun(registration: registration)
    }
}
