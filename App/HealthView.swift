import SwiftUI
import WylaCore

/// The collector's health: whether it runs, when it was not monitoring, and the log quality it
/// left — plus the audit actions: verify the chain and export a range.
struct HealthView: View {
    let store: Store

    @State private var health: HealthInfo?
    @State private var report: IntegrityReport?
    @State private var verifying = false
    @State private var exported: String?
    @State private var exportFrom = Calendar.current.startOfDay(for: .now)
    @State private var exportTo = Date.now
    @State private var error: String?

    var body: some View {
        List {
            Section("Collector") {
                LabeledContent("Status") {
                    Text(store.monitoringLive ? "Monitoring" : "Not monitoring")
                        .foregroundStyle(store.monitoringLive ? .green : .red)
                }
                LabeledContent("Last heartbeat") {
                    Text(store.lastHeartbeat.map(Format.timestamp) ?? "Never")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Unparsed log lines") {
                    Text(health.map { "\($0.unparsedLines)" } ?? "—")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Coverage gaps") {
                if let health, health.gaps.isEmpty {
                    Text("No gaps: every run covers the time up to the next one's start.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array((health?.gaps ?? []).enumerated()), id: \.offset) { _, gap in
                    Text("Not monitoring \(Format.timestamp(gap.start)) – \(Format.timestamp(gap.end))")
                }
            }

            Section("Audit") {
                LabeledContent("Latest anchor") {
                    Text(health?.lastAnchor.map { "row \($0.id)" } ?? "None (enable in Settings)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(verifying ? "Verifying…" : "Verify integrity") { verify() }
                        .disabled(verifying)
                    Spacer()
                    if let report {
                        Text(result(report)).foregroundStyle(report.isIntact ? .green : .red)
                    }
                }
                DatePicker("From", selection: $exportFrom, displayedComponents: [.date])
                DatePicker("To", selection: $exportTo, displayedComponents: [.date])
                HStack {
                    Button("Export…") { export() }
                    Spacer()
                    if let exported {
                        Text(exported).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { reload() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in reload() }
    }

    private func reload() {
        Task.detached(priority: .userInitiated) { [store] in
            let health = try? store.health()
            await MainActor.run { self.health = health }
        }
    }

    private func verify() {
        verifying = true
        report = nil
        Task.detached(priority: .userInitiated) { [store] in
            do {
                let report = try store.verifyIntegrity()
                await MainActor.run {
                    self.report = report
                    self.verifying = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.verifying = false
                }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wyla-export-\(exportFrom.formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task.detached(priority: .userInitiated) { [store] in
            do {
                let manifest = try store.export(
                    from: exportFrom, to: exportTo.addingTimeInterval(86_400).addingTimeInterval(-1), into: directory)
                await MainActor.run {
                    self.exported = "\(manifest.rowCount) events, \(manifest.sessionCount) sessions → \(directory.lastPathComponent)"
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    private func result(_ report: IntegrityReport) -> String {
        if let problem = report.problem {
            return "Broken at row \(problem.firstBadRow) (\(report.verifiedRows) verified)"
        }
        return "Intact: \(report.verifiedRows) rows"
    }
}
