import SwiftUI
import WylaCore

/// The selected session: its metadata, merged activations, and the raw log lines behind it.
struct SessionDetailView: View {
    let session: Session
    let store: Store

    @State private var events: [RawEvent] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: store.icon(of: session))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text(store.name(of: session))
                        .font(.headline)
                    Text(summaryLine)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let responsible = session.responsible {
                    Label("via \(responsible.identifier)", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                }
            }
            if !session.devices.isEmpty {
                Text("Devices: \(session.devices.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if session.activations.count > 1 {
                Text("\(session.activations.count) activations merged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List {
                if let error {
                    Text("Could not load log lines: \(error)")
                        .foregroundStyle(.red)
                }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(event.time, format: .dateTime.hour().minute().second().secondFraction(.fractional(3))) · \(event.source)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(event.message)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 220)
            .task(id: session.id) {
                do {
                    events = try store.rawEvents(for: session)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                    events = []
                }
            }
        }
    }

    private var summaryLine: String {
        let end = session.end.map(Format.timestamp) ?? "now"
        let duration = Format.duration(session.duration(asOf: .now))
        return "\(session.sensor.displayName) · \(Format.timestamp(session.start)) – \(end) · \(duration)"
    }
}
