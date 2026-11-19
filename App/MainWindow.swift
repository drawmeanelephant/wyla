import SwiftUI

struct MainWindow: View {
    static let id = "main"
    let store: Store

    var body: some View {
        if let error = store.loadError {
            ContentUnavailableView {
                Label("Could not read the log database", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .frame(minWidth: 640, minHeight: 400)
        } else {
            TabView {
                TimelineView(store: store)
                    .tabItem { Label("Timeline", systemImage: "list.bullet.rectangle") }
                AppsView(store: store)
                    .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                RequestsView(store: store)
                    .tabItem { Label("Requests", systemImage: "lock.shield") }
            }
            .frame(minWidth: 760, minHeight: 480)
        }
    }
}
