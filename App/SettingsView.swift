import SwiftUI
import WylaCore

/// Edits the settings shared with the agent: the merge window the viewer joins sessions with,
/// whether the agent alerts on new and unattributed use, and whether it saves a daily chain
/// anchor. The agent picks changes up on its next heartbeat.
struct SettingsView: View {
    let store: Store
    let registration: AgentRegistration

    @State private var mergeWindow: Double = 0
    @State private var notifications = true
    @State private var anchors = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Sessions") {
                LabeledContent("Merge window") {
                    HStack {
                        Slider(value: $mergeWindow, in: 1...30, step: 1) { editing in
                            if !editing { save() }
                        }
                        Text("\(Int(mergeWindow))s").monospacedDigit().frame(width: 32)
                    }
                }
                Text("Activations of one app on one sensor join into one session when they start less than this far apart.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Agent") {
                Toggle("Notifications", isOn: $notifications)
                    .onChange(of: notifications) { save() }
                Text("Alert on the first use of a sensor by an app, and on unattributed camera or microphone use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Daily chain anchor", isOn: $anchors)
                    .onChange(of: anchors) { save() }
                Text("Save the hash chain's head once a day, so a later verification can tell whether the chain still contains it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Start monitoring at login") {
                    HStack {
                        Text(registration.summary).foregroundStyle(.secondary)
                        Spacer()
                        Button(registration.status == .enabled ? "Disable" : "Enable") {
                            registration.setEnabled(registration.status != .enabled)
                        }
                    }
                }
                Text(
                    "This toggles the background collector that records sensor use — disabling it stops all monitoring. "
                        + "The app itself doesn't use a login item; reopen it manually."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mergeWindow = store.settings.mergeWindow
            notifications = store.settings.notificationsEnabled
            anchors = store.settings.anchorExportEnabled
            registration.refresh()
        }
    }

    private func save() {
        var edited = store.settings
        edited.mergeWindow = mergeWindow
        edited.notificationsEnabled = notifications
        edited.anchorExportEnabled = anchors
        do {
            try store.updateSettings(edited)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
