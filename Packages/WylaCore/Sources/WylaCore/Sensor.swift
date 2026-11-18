/// A privacy-sensitive input that macOS shows a menu bar indicator for.
///
/// Raw values are stored in the database, so renaming a case requires a migration.
public enum Sensor: String, CaseIterable, Codable, Sendable {
    case camera
    case microphone
    case screen

    public var displayName: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screen: "Screen"
        }
    }
}
