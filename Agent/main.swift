import Foundation
import WylaCore
import os

let logger = Logger(subsystem: "io.github.drawmeanelephant.wyla", category: "agent")

/// `--database <path>` uses another database, for tests. The default is `EventStore.defaultURL`.
func databaseURL() -> URL {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--database"), arguments.indices.contains(flag + 1) else {
        return EventStore.defaultURL
    }
    return URL(filePath: arguments[flag + 1])
}

/// Holds an exclusive lock next to the database for the life of the process, so that two agents
/// never record into one database. A second agent waits until the first one exits.
func lockDatabase(at url: URL) {
    let descriptor = open(url.path(percentEncoded: false) + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
        logger.fault("Cannot open the database lock file (errno \(errno, privacy: .public))")
        exit(EXIT_FAILURE)
    }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        logger.notice("Another agent is recording into this database; waiting for it to exit")
        flock(descriptor, LOCK_EX)
    }
}

/// `--verify` checks the hash chain against every anchor exported by `anchorExportEnabled`,
/// prints the result, and exits with status 1 if it is broken.
func verify(_ url: URL) -> Never {
    do {
        let anchors = try AnchorLog.read(from: AnchorLog.url(near: url)).map(\.anchor)
        let report = try EventStore(url: url).verifyIntegrity(anchors: anchors)
        if let problem = report.problem {
            print("BROKEN at row \(problem.firstBadRow): \(problem) (\(report.verifiedRows) rows verified before it)")
            exit(EXIT_FAILURE)
        }
        print("OK: \(report.verifiedRows) rows, head \(report.head.map { "\($0.id) \($0.hash)" } ?? "none")")
        exit(EXIT_SUCCESS)
    } catch {
        print("ERROR: \(error)")
        exit(EXIT_FAILURE)
    }
}

/// Parses a `--export` date: `yyyy-MM-dd` (a day in the local timezone) or full ISO 8601.
private func exportDate(_ argument: String) -> (date: Date, isDay: Bool)? {
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    if let date = day.date(from: argument) { return (date, true) }
    if let date = ISO8601DateFormatter().date(from: argument) { return (date, false) }
    return nil
}

/// `--export <from> <to> <directory>` writes the date range's raw events and sessions as CSV and
/// JSON into the directory, and `--verify-export <directory>` checks such an export's chain.
/// Dates are `yyyy-MM-dd` (days in the local timezone; `to` includes that whole day) or ISO 8601.
func exportIfAsked(_ url: URL) {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--export"), arguments.indices.contains(flag + 3) {
        guard let from = exportDate(arguments[flag + 1]), let end = exportDate(arguments[flag + 2])
        else {
            print("ERROR: dates are yyyy-MM-dd (local days) or ISO 8601 (for example 2026-11-19T12:30:00Z)")
            exit(EXIT_FAILURE)
        }
        do {
            let directory = URL(filePath: arguments[flag + 3])
            // A bare day means "through the end of that day"; an instant is used as given.
            let inclusiveEnd = end.isDay ? end.date.localDayEnd : end.date
            let settings = Settings.load(from: Settings.url(near: url))
            let manifest = try AuditExport.write(
                store: EventStore(url: url), from: from.date, to: inclusiveEnd, to: directory,
                mergeWindow: settings.mergeWindow)
            let outside =
                manifest.skipped.isEmpty
                ? "" : " (\(manifest.skipped.count) rows outside the range, ids in manifest.skipped)"
            print(
                "Exported \(manifest.rowCount) events and \(manifest.sessionCount) sessions to "
                    + "\(directory.path(percentEncoded: false))\(outside)")
            exit(EXIT_SUCCESS)
        } catch {
            print("ERROR: \(error)")
            exit(EXIT_FAILURE)
        }
    }
    if let flag = arguments.firstIndex(of: "--verify-export"), arguments.indices.contains(flag + 1) {
        do {
            let anchors = try AnchorLog.read(from: AnchorLog.url(near: url))
            let report = try AuditExport.verify(directory: URL(filePath: arguments[flag + 1]), anchors: anchors)
            if let problem = report.problem {
                print("BROKEN at row \(problem.firstBadRow): \(problem) (\(report.verifiedRows) rows verified before it)")
                exit(EXIT_FAILURE)
            }
            if report.headMismatch {
                print("BROKEN: the chain ends at a different head than the manifest records")
                exit(EXIT_FAILURE)
            }
            print("OK: \(report.verifiedRows) rows")
            exit(EXIT_SUCCESS)
        } catch {
            print("ERROR: \(error)")
            exit(EXIT_FAILURE)
        }
    }
}

let url = databaseURL()
if CommandLine.arguments.contains("--verify") {
    verify(url)
}
exportIfAsked(url)
logger.notice("WylaAgent started (database \(url.path(percentEncoded: false), privacy: .private))")
let collector: Collector
do {
    let store = try EventStore(url: url)
    lockDatabase(at: url)
    collector = try Collector(store: store)
} catch {
    logger.fault("Cannot open the database: \(String(describing: error), privacy: .public)")
    exit(EXIT_FAILURE)
}

signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        await collector.stop()
        exit(EXIT_SUCCESS)
    }
}
termination.resume()

await collector.run()
