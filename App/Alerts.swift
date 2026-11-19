import Foundation
import UserNotifications
import WylaCore

/// Posts "first use" alerts for activations the store reloads, from the app's own bundle
/// identity (the agent's notifications show as its binary, not the app). Alerts track a
/// watermark so a run only reports activations newer than the ones it already reported;
/// activations backfilled after the fact are labelled with their real time instead of read as
/// live, and unattributed alerts are rate limited so a noisy sensor can't spam.
@MainActor
final class Alerts {
    private var watermark: Date?
    private var lastUnattributedAlert = Date.distantPast
    private let notified: UNUserNotificationCenter

    init() {
        notified = .current()
        notified.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func report(on activations: [Activation], settings: Settings) {
        guard settings.notificationsEnabled else { return }
        // The first read is history, not news: everything already recorded is older than the
        // watermark, and only activations newer than it can be new to the user.
        guard let watermarkBefore = watermark else {
            watermark = activations.map(\.start).max() ?? .now
            return
        }
        // First use of a sensor by an app is the earliest activation it has on record.
        var earliest: [String: Date] = [:]
        for activation in activations {
            let key = "\(activation.sensor.rawValue)/\(activation.client ?? "")"
            earliest[key] = min(earliest[key] ?? .distantFuture, activation.start)
        }
        for activation in activations where activation.start > watermarkBefore {
            watermark = max(watermark, activation.start)
            let firstUse =
                activation.client != nil
                && earliest["\(activation.sensor.rawValue)/\(activation.client ?? "")"] == activation.start
            post(for: activation, firstUse: firstUse)
        }
    }

    /// The first use of a sensor by an app, plus every unattributed use — those the user can't
    /// attribute any other way.
    private func post(for activation: Activation, firstUse: Bool) {
        guard activation.client == nil || firstUse else { return }
        if activation.client == nil {
            let gap = activation.start.timeIntervalSince(lastUnattributedAlert)
            guard gap > 15 * 60 else { return }
            lastUnattributedAlert = activation.start
        }
        let sensorName = activation.sensor.displayName
        // Backfilled activations read as live alerts without their time, so name when it was.
        let live = activation.start.timeIntervalSinceNow > -60
        let title = live ? "\(sensorName) in use" : "\(sensorName) was in use"
        let who = activation.displayName ?? activation.client ?? "An app"
        let body =
            live
            ? "\(who) is using the \(sensorName.lowercased())"
            : "\(who) used the \(sensorName.lowercased()) at \(activation.start.formatted(date: .omitted, time: .shortened))"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        notified.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
