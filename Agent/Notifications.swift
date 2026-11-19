import Foundation
import UserNotifications
import WylaCore
import os

/// Posts user notifications for use WYLA records: the first use of a sensor by an app, and any
/// camera or microphone use it could not attribute to an app. Posts only when the shared
/// settings allow it; macOS asks the user for notification permission on the first post.
enum Notifier {
    private static let logger = Logger(subsystem: "io.github.drawmeanelephant.wyla", category: "notifications")
    private static var requested = false

    /// Posts a notification for the activation that just started, if one is due.
    static func notify(onStart activation: Activation, store: EventStore, settings: Settings) {
        guard settings.notificationsEnabled else { return }
        if let client = activation.client {
            // The activation is already stored, so a count of one means this is the app's first
            // recorded use of the sensor — the check survives agent restarts.
            guard let count = try? store.activationCount(sensor: activation.sensor, client: client), count == 1
            else { return }
            post(
                title: "First \(activation.sensor.rawValue) use",
                body: "\(activation.displayName ?? client) is using the \(activation.sensor.rawValue) for the first time",
                identifier: "first-\(activation.sensor.rawValue)-\(client)")
        } else if activation.sensor != .screen {
            post(
                title: "Unattributed \(activation.sensor.rawValue) use",
                body: "The \(activation.sensor.rawValue) is on but WYLA cannot see which app is using it",
                identifier: "unattributed-\(activation.sensor.rawValue)-\(activation.start.timeIntervalSince1970)")
        }
    }

    private static func post(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        if !requested {
            requested = true
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                if granted {
                    post(title: title, body: body, identifier: identifier)
                }
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                logger.error("Notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
