import SwiftUI
import WylaCore

struct MainWindow: View {
    static let id = "main"

    private var sensorList: String {
        Sensor.allCases.map { $0.displayName.lowercased() }.formatted(.list(type: .or))
    }

    var body: some View {
        ContentUnavailableView {
            Label("No activity recorded yet", systemImage: "eye.slash")
        } description: {
            Text("WYLA will log every app that uses your \(sensorList).")
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
