import Foundation

/// Settings the app and the agent share, stored as JSON next to the database so both processes
/// read the same values without a shared defaults domain.
public struct Settings: Sendable, Equatable, Codable {
    /// Activations of one app on one sensor join into one session when they are less than this
    /// many seconds apart.
    public var mergeWindow: TimeInterval
    /// Post a notification on the first use of a sensor by an app, and on unattributed camera or
    /// microphone use.
    public var notificationsEnabled: Bool
    /// Save the hash chain's head to `anchors.log` next to the database, once a day, so the chain
    /// can later be verified against it.
    public var anchorExportEnabled: Bool

    public init(
        mergeWindow: TimeInterval = SessionMerger.defaultWindow,
        notificationsEnabled: Bool = true,
        anchorExportEnabled: Bool = false
    ) {
        self.mergeWindow = mergeWindow
        self.notificationsEnabled = notificationsEnabled
        self.anchorExportEnabled = anchorExportEnabled
    }

    /// The settings file next to `databaseURL`, or the default location.
    public static func url(near databaseURL: URL = EventStore.defaultURL) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: "settings.json")
    }

    /// The saved settings, or the defaults when the file is absent or unreadable.
    public static func load(from url: URL = Settings.url()) -> Settings {
        (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))) ?? Settings()
    }

    public func save(to url: URL = Settings.url()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
