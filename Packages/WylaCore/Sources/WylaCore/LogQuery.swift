import Foundation

/// The system log events WYLA reads, and the `log` commands that read them. Indicators and TCC
/// requests come from one `log` process so that their relative order is the order macOS logged them.
public enum LogQuery {
    public static let predicate =
        #"(subsystem == "com.apple.controlcenter" AND category == "sensor-indicators") OR "#
        + #"(subsystem == "com.apple.TCC" AND category == "access")"#

    /// Arguments for `/usr/bin/log` to stream new events. TCC lines are Info level.
    public static let streamArguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate", predicate]

    /// Arguments for `/usr/bin/log` to show the stored events from `start` on. `log show` takes
    /// whole seconds, so this starts up to two seconds early. The recorder skips the overlap.
    public static func showArguments(from start: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return [
            "show", "--style", "ndjson", "--info", "--start", formatter.string(from: start.addingTimeInterval(-1)), "--predicate", predicate
        ]
    }
}

/// Turns events from the combined `log` stream into recorder inputs.
public struct LogRouter: Sendable {
    private var assembler = TCCRequestAssembler()
    /// TCC lines that look relevant but don't match a known format, for the Health view.
    public private(set) var unparsedTCCLines = 0

    public init() {}

    public mutating func route(_ event: LogEvent) -> RecorderInput? {
        switch (event.subsystem, event.category) {
        case ("com.apple.controlcenter", "sensor-indicators"):
            return .indicator(event)
        case ("com.apple.TCC", "access"):
            switch assembler.consume(event) {
            case .event(let request): return .tccRequest(request)
            case .ignored: return nil
            case .unparsed:
                unparsedTCCLines += 1
                return nil
            }
        default:
            return nil
        }
    }
}
