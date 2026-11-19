import AppKit
import SwiftUI
import WylaCore

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let registration: AgentRegistration
    let store: Store

    var body: some View {
        if !store.activeNow.isEmpty {
            ForEach(store.activeNow) { activation in
                Label {
                    Text(activeText(of: activation))
                } icon: {
                    Image(systemName: activation.sensor.icon)
                }
            }
            Divider()
        }
        Text(todayText)
        Divider()
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

    private func activeText(of activation: Activation) -> String {
        let client = activation.client.flatMap { store.apps[$0]?.name ?? activation.displayName ?? $0 } ?? "Unattributed"
        return "\(activation.sensor.displayName): \(client)"
    }

    private var todayText: String {
        let counts = store.todayCounts
        guard !counts.isEmpty else { return "Nothing recorded today" }
        let parts = Sensor.allCases.compactMap { sensor in
            counts[sensor].map { "\(sensor.displayName) × \($0)" }
        }
        return "Today: \(parts.joined(separator: " · "))"
    }
}
