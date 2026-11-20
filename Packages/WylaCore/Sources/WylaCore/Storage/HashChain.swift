import CryptoKit
import Foundation

/// Where a `raw_events` row came from.
///
/// Raw values are stored in the database, so renaming a case requires a migration.
public enum RawEventSource: String, CaseIterable, Sendable {
    /// A Control Center `sensor-indicators` log line, stored as logged.
    case indicator
    /// A TCC access check that linked a command-line client to its responsible app, stored as JSON.
    case tcc
    /// A camera or microphone device turning on or off: `<sensor> <device> on|off`.
    case hardware
}

/// The SHA-256 chain over `raw_events`. Each row's hash covers its own columns and the previous
/// row's hash, so editing, removing, or inserting a row breaks every hash after it.
///
/// Hashes and dedup keys are lowercase hex SHA-256 of UTF-8 text:
/// - `dedup_key = sha256("<source>\n<identity>\n<message>")`, where the identity of an
///   `indicator` row is its log entry's `machTimestamp` in decimal, and of other rows `<time_us>`
/// - `hash = sha256("<id>\n<time_us>\n<source>\n<dedup_key>\n<prev_hash>\n<message>")`
///
/// The first row's `prev_hash` is 64 zeros. The message comes last because it is the only field
/// that can contain a newline.
enum HashChain {
    static let genesis = String(repeating: "0", count: 64)

    static func dedupKey(source: RawEventSource, identity: String, message: String) -> String {
        sha256("\(source.rawValue)\n\(identity)\n\(message)")
    }

    fileprivate static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The columns of a `raw_events` row that its hash covers.
struct ChainedRow {
    let id: Int64
    let timeMicros: Int64
    /// A `RawEventSource` raw value. Kept as text so that verification also covers unknown values.
    let source: String
    let dedupKey: String
    let prevHash: String
    let message: String

    var hash: String { HashChain.sha256("\(id)\n\(timeMicros)\n\(source)\n\(dedupKey)\n\(prevHash)\n\(message)") }
}

extension Date {
    /// Times are stored as integer microseconds since 1970, the precision of `log` timestamps.
    var microseconds: Int64 { Int64((timeIntervalSince1970 * 1_000_000).rounded()) }

    init(microseconds: Int64) {
        self.init(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    /// The last representable instant of the local calendar day containing `self`: the next
    /// day's local midnight minus a microsecond. A daylight-saving day is not 24 hours, so a
    /// fixed `+ 86399` lands an hour early on fall-back days and an hour into the next day on
    /// spring-forward days.
    public var localDayEnd: Date {
        Calendar.current
            .date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: self))?
            .addingTimeInterval(-0.000_001) ?? .distantFuture
    }
}
