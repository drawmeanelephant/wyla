import Charts
import SwiftUI
import WylaCore

/// The Apps tab: per-app counts per sensor, total time, first and last use, and a daily history.
struct AppsView: View {
    let store: Store
    @State private var selection: AppSummary.ID?

    private var summaries: [AppSummary] {
        AppSummary.all(from: store.sessions, activations: store.activations, asOf: store.liveAsOf)
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No activity recorded yet", systemImage: "eye.slash")
                } description: {
                    Text("WYLA will log every app that uses your camera, microphone, or screen.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Text("Cam / Mic / Scr: sessions · activations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Table(summaries, selection: $selection) {
                    TableColumn("App") { summary in
                        Label {
                            Text(name(of: summary))
                        } icon: {
                            Image(nsImage: store.icon(of: summary))
                        }
                    }
                    TableColumn("Cam") { summary in
                        Text(count(summary, .camera))
                    }
                    .width(52)
                    TableColumn("Mic") { summary in
                        Text(count(summary, .microphone))
                    }
                    .width(52)
                    TableColumn("Scr") { summary in
                        Text(count(summary, .screen))
                    }
                    .width(52)
                    TableColumn("Total") { summary in
                        Text(Format.duration(summary.duration))
                    }
                    .width(60)
                    TableColumn("First use") { summary in
                        Text(Format.timestamp(summary.firstUse))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Last use") { summary in
                        Text(Format.timestamp(summary.lastUse))
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary = summaries.first(where: { $0.id == selection }) {
                    Divider()
                    history(of: summary)
                }
            }
        }
        .padding()
    }

    private func name(of summary: AppSummary) -> String {
        summary.client.flatMap { store.apps[$0]?.name ?? $0 } ?? "Unattributed"
    }

    /// `sessions · activations` for the sensor, a dash when the app used neither.
    private func count(_ summary: AppSummary, _ sensor: Sensor) -> String {
        let sessions = summary.counts[sensor] ?? 0
        let activations = summary.activationCounts[sensor] ?? 0
        return sessions == 0 && activations == 0 ? "–" : "\(sessions) · \(activations)"
    }

    /// Total time per day for the selected app, stacked by sensor.
    private func history(of summary: AppSummary) -> some View {
        let uses = DailyUse.of(store.sessions.filter { $0.client == summary.client }, asOf: store.liveAsOf)
        return VStack(alignment: .leading) {
            Text("\(name(of: summary)) — daily total")
                .font(.headline)
            Chart(uses, id: \.self) { use in
                BarMark(
                    x: .value("Day", use.day, unit: .day),
                    y: .value("Minutes", use.duration / 60)
                )
                .foregroundStyle(by: .value("Sensor", use.sensor.displayName))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .chartYAxisLabel("Minutes")
            .frame(minHeight: 140, maxHeight: 200)
        }
    }
}
