import SwiftUI

@main
struct WylaApp: App {
    @State private var registration: AgentRegistration

    var body: some Scene {
        MenuBarExtra("WYLA", systemImage: "eye") {
            MenuBarContent(registration: registration)
        }

        Window("WYLA", id: MainWindow.id) {
            MainWindow()
        }
        .defaultLaunchBehavior(.suppressed)
    }

    init() {
        let registration = AgentRegistration()
        registration.register()
        _registration = State(initialValue: registration)
    }
}
