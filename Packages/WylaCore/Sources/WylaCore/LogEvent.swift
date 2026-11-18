import Foundation

/// One event from `log stream --style ndjson` or `log show --style ndjson`.
public struct LogEvent: Sendable, Equatable {
    public let timestamp: Date
    public let message: String

    public init(timestamp: Date, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

/// What one line of `log` ndjson output contains.
public enum LogLine: Sendable, Equatable {
    case event(LogEvent)
    /// The `Filtering the log data using ...` line that `log stream` prints before the first event.
    case banner
    case malformed
}

extension LogLine {
    public init(parsing line: some StringProtocol) {
        if line.hasPrefix("Filtering the log data") {
            self = .banner
            return
        }
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: Data(line.utf8)),
            let timestamp = LogTimestamp.parse(raw.timestamp)
        else {
            self = .malformed
            return
        }
        self = .event(LogEvent(timestamp: timestamp, message: raw.eventMessage))
    }
}

private struct RawEvent: Decodable {
    let timestamp: String
    let eventMessage: String
}

/// Parses the `log` ndjson timestamp format, `2026-11-18 13:55:46.482710-0500`, keeping microseconds.
enum LogTimestamp {
    static func parse(_ text: String) -> Date? {
        let pattern = /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(\.\d+)?([+-])(\d{2})(\d{2})/
        guard let match = text.wholeMatch(of: pattern) else { return nil }
        let fields = [match.1, match.2, match.3, match.4, match.5, match.6, match.9, match.10].compactMap { Int($0) }
        let sign = match.8 == "-" ? -1 : 1
        guard fields.count == 8, let zone = TimeZone(secondsFromGMT: sign * (fields[6] * 3600 + fields[7] * 60)) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            year: fields[0], month: fields[1], day: fields[2], hour: fields[3], minute: fields[4], second: fields[5])
        guard let whole = calendar.date(from: components) else { return nil }
        return whole.addingTimeInterval(match.7.flatMap { Double("0" + $0) } ?? 0)
    }
}
