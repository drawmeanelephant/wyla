/// The app or process that macOS attributes a sensor activation to, as Control Center names it.
public struct Attribution: Hashable, Sendable, Codable {
    public let sensor: Sensor
    /// A bundle identifier, or an executable name for command-line tools such as `bash`.
    public let client: String

    public init(sensor: Sensor, client: String) {
        self.sensor = sensor
        self.client = client
    }

    /// Control Center falls back to the executable name when the process has no bundle. Bundle
    /// identifiers always contain a dot.
    public var isExecutableName: Bool { !client.contains(".") }
}
