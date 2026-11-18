import SwiftUI

@main
struct WylaApp: App {
    var body: some Scene {
        MenuBarExtra("WYLA", systemImage: "eye") {
            MenuBarContent()
        }

        Window("WYLA", id: MainWindow.id) {
            MainWindow()
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
