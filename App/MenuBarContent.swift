import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Not monitoring yet")
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
