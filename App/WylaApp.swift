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
        let registration = AgentRegistration()
        registration.register()
        _registration = State(initialValue: registration)
        _store = State(initialValue: Store())
        OnboardingWindow.showIfFirstRun(registration: registration)
    }
}
