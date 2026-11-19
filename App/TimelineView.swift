import SwiftUI
import WylaCore

/// The session table, with filters for sensor, app, date range, and text.
struct TimelineView: View {
    let store: Store

    @State private var query = SessionQuery()
    @State private var rangeEnabled = false
    @State private var rangeFrom = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
    @State private var rangeTo = Date.now
    @State private var selection: Session.ID?

    private var filtered: [Session] {
        var query = query
        query.range = rangeEnabled ? rangeFrom..<rangeTo : nil
        return query.apply(to: store.sessions).sorted { $0.start > $1.start }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Sensor", selection: $query.sensor) {
                    Text("All sensors").tag(Sensor?.none)
                    ForEach(Sensor.allCases, id: \.self) { sensor in
                        Text(sensor.displayName).tag(Sensor?.some(sensor))
                    }
                }
                .fixedSize()
                Picker("App", selection: $query.client) {
                    Text("All apps").tag(String?.none)
                    ForEach(clients, id: \.self) { client in
                        Text(store.apps[client]?.name ?? client).tag(String?.some(client))
                    }
                }
                .fixedSize()
                Spacer()
                TextField("Search", text: $query.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
            }
            HStack(spacing: 8) {
                Toggle("Date range", isOn: $rangeEnabled)
                if rangeEnabled {
                    DatePicker("", selection: $rangeFrom, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Text("to")
                    DatePicker("", selection: $rangeTo, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Spacer()
                Text("\(filtered.count) of \(store.sessions.count) sessions")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Divider()
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No activity recorded yet", systemImage: "eye.slash")
                } description: {
                    Text("WYLA will log every app that uses your camera, microphone, or screen.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn("Time") { session in
                        Text(session.start, format: .dateTime.month().day().hour().minute().second())
                    }
                    .width(min: 140, ideal: 150)
                    TableColumn("Sensor") { session in
                        Label(session.sensor.displayName, systemImage: session.sensor.icon)
                    }
                    .width(100)
                    TableColumn("App") { session in
                        Label {
                            Text(store.name(of: session))
                        } icon: {
                            Image(nsImage: store.icon(of: session))
                        }
                    }
                    TableColumn("Duration") { session in
                        Text(Format.duration(session.duration(asOf: .now)))
                            .foregroundStyle(session.end == nil ? .primary : .secondary)
                    }
                    .width(70)
                    TableColumn("Device") { session in
                        Text(session.devices.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let session = filtered.first(where: { $0.id == selection }) {
                    Divider()
                    SessionDetailView(session: session, store: store)
                }
            }
        }
        .padding()
    }

    /// Every client that has a session, sorted by name.
    private var clients: [String] {
        let seen = Set(store.sessions.compactMap(\.client))
        return seen.sorted { (store.apps[$0]?.name ?? $0) < (store.apps[$1]?.name ?? $1) }
    }
}
