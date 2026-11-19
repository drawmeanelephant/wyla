import Charts
import SwiftUI
import WylaCore

/// The TCC permission-check totals, filterable by service and searchable by app, with a
/// per-day history for the selected row.
struct RequestsView: View {
    let store: Store

    @State private var service: String?
    @State private var search = ""
    @State private var selection: TCCSummary.ID?
    @State private var history: [EventStore.TCCDailyCount] = []

    private var filtered: [TCCSummary] {
        store.requests.filter { request in
            (service == nil || request.service == service)
                && (search.isEmpty || store.name(of: request).localizedCaseInsensitiveContains(search)
                    || request.service.localizedCaseInsensitiveContains(search))
        }
        // Rows come back ordered by total; the table reads by app name, so sort by what the
        // first column shows.
        .sorted { store.name(of: $0).localizedCaseInsensitiveCompare(store.name(of: $1)) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Service", selection: $service) {
                    Text("All services").tag(String?.none)
                    ForEach(services, id: \.self) { service in
                        Text(Self.serviceName(service)).tag(String?.some(service))
                    }
                }
                .fixedSize()
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
            }
            .padding(.vertical, 6)
            Divider()
            if store.requests.isEmpty {
                ContentUnavailableView {
                    Label("No permission requests yet", systemImage: "lock.shield")
                } description: {
                    Text("WYLA counts every camera, microphone, and screen access check apps make.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn("App") { request in
                        Label {
                            Text(store.name(of: request))
                        } icon: {
                            Image(nsImage: store.icon(of: request))
                        }
                    }
                    TableColumn("Service") { request in
                        if let sensor = request.sensor {
                            Label(Self.serviceName(request.service), systemImage: sensor.icon)
                        } else {
                            Text(Self.serviceName(request.service))
                        }
                    }
                    .width(120)
                    TableColumn("Allowed") { request in
                        Text("\(request.allowed)")
                    }
                    .width(60)
                    TableColumn("Denied") { request in
                        Text("\(request.denied)")
                            .foregroundStyle(request.denied > 0 ? .primary : .secondary)
                    }
                    .width(60)
                    TableColumn("Limited") { request in
                        Text("\(request.limited)")
                            .foregroundStyle(request.limited > 0 ? .primary : .secondary)
                    }
                    .width(60)
                    TableColumn("Unknown") { request in
                        Text("\(request.unknown)")
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                    TableColumn("Total") { request in
                        Text("\(request.total)")
                    }
                    .width(60)
                    TableColumn("Last seen") { request in
                        Text(Format.timestamp(request.lastSeen))
                            .foregroundStyle(.secondary)
                    }
                    .width(140)
                }
                if let selected = filtered.first(where: { $0.id == selection }) {
                    Divider()
                    historyChart(of: selected)
                        // The whole row is the task's identity so new checks — which change its
                        // totals and lastSeen — refresh the chart too.
                        .task(id: selected) {
                            history =
                                (try? await store.requestDaily(client: selected.client, service: selected.service))
                                ?? []
                        }
                }
            }
        }
        .padding()
    }

    /// Checks per day for the selected app and service, stacked by result.
    private func historyChart(of request: TCCSummary) -> some View {
        VStack(alignment: .leading) {
            Text("\(store.name(of: request)) — \(Self.serviceName(request.service)) checks per day")
                .font(.headline)
            Chart(history, id: \.self) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Checks", day.count)
                )
                .foregroundStyle(by: .value("Result", day.result))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .chartYAxisLabel("Checks")
            .frame(minHeight: 140, maxHeight: 200)
        }
    }

    /// The services that have requests, sorted by name.
    private var services: [String] {
        Set(store.requests.map(\.service)).sorted()
    }

    /// `kTCCServiceScreenCapture` → `ScreenCapture`.
    static func serviceName(_ service: String) -> String {
        service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
    }
}
