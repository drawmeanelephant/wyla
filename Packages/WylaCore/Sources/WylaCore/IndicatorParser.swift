import Foundation

/// A Control Center `sensor-indicators` log line that WYLA uses.
public enum IndicatorEvent: Sendable, Equatable {
    /// Every activation in progress. Control Center logs the whole set after each change.
    /// `unrecognized` holds entries whose sensor code WYLA doesn't know, for the Health view.
    case active(Set<Attribution>, unrecognized: [String])
    /// An activation ended. Carries the display name that Control Center shows for the client.
    case ended(Attribution, displayName: String)
}

public enum ParseResult<Event: Sendable & Equatable>: Sendable, Equatable {
    case event(Event)
    /// A line that WYLA doesn't need.
    case ignored
    /// A line that looks relevant but doesn't match a known format. The Health view counts these.
    case unparsed(reason: String)
}

/// Parses Control Center `sensor-indicators` messages.
public struct IndicatorParser: Sendable {
    /// macOS major versions whose indicator format is covered by fixture tests. On other versions
    /// the parser still runs, and the Health view warns that the format is unverified.
    public static let verifiedMajorVersions: Set<Int> = [27]

    public static func isVerified(on version: OperatingSystemVersion) -> Bool {
        verifiedMajorVersions.contains(version.majorVersion)
    }

    private static let activePrefix = "Active activity attributions changed to "
    private static let endedPrefix = "added to recent: "

    public init() {}

    public func parse(_ message: String) -> ParseResult<IndicatorEvent> {
        if message.hasPrefix(Self.activePrefix) {
            return parseActive(message.dropFirst(Self.activePrefix.count))
        }
        if message.hasPrefix(Self.endedPrefix) {
            return parseEnded(message.dropFirst(Self.endedPrefix.count))
        }
        return .ignored
    }

    /// `["cam:com.apple.PhotoBooth", "scr:bash"]`
    private func parseActive(_ list: Substring) -> ParseResult<IndicatorEvent> {
        guard let entries = try? JSONDecoder().decode([String].self, from: Data(list.utf8)) else {
            return .unparsed(reason: "attribution list is not a JSON array of strings")
        }
        var attributions = Set<Attribution>()
        var unrecognized: [String] = []
        for entry in entries {
            let parts = entry.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let sensor = Sensor(indicatorCode: parts[0]), !parts[1].isEmpty {
                attributions.insert(Attribution(sensor: sensor, client: String(parts[1])))
            } else {
                unrecognized.append(entry)
            }
        }
        return .event(.active(attributions, unrecognized: unrecognized))
    }

    /// `[[cam] Photo Booth (com.apple.PhotoBooth)]`, or `[[scr] bash ()]` for a command-line tool.
    private func parseEnded(_ entry: Substring) -> ParseResult<IndicatorEvent> {
        guard let match = entry.wholeMatch(of: /\[\[(\w+)\] (.+) \(([^()]*)\)\]/),
            let sensor = Sensor(indicatorCode: match.1)
        else {
            return .unparsed(reason: "recent activity entry has an unknown format")
        }
        let name = String(match.2)
        let client = match.3.isEmpty ? name : String(match.3)
        return .event(.ended(Attribution(sensor: sensor, client: client), displayName: name))
    }
}

extension Sensor {
    /// The sensor codes Control Center uses in attribution entries.
    init?(indicatorCode: Substring) {
        switch indicatorCode {
        case "cam": self = .camera
        case "mic": self = .microphone
        case "scr": self = .screen
        default: return nil
        }
    }
}
