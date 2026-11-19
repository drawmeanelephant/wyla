import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let registration: AgentRegistration

    var body: some View {
        Text(registration.summary)
            .onAppear { registration.refresh() }
        if registration.status == .requiresApproval {
            Button("Open Login Items Settings…") {
                registration.openLoginItemsSettings()
            }
        }
        Divider()
        Button("Open WYLA") {
            NSApp.activate()
            openWindow(id: MainWindow.id)
        }
        Button("Quit WYLA") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
