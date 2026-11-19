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

/// `--verify` checks the hash chain against the latest anchor exported by `anchorExportEnabled`,
/// prints the result, and exits with status 1 if it is broken.
func verify(_ url: URL) -> Never {
    do {
        let anchor = try AnchorLog.earliest(from: AnchorLog.url(near: url))
        let report = try EventStore(url: url).verifyIntegrity(anchor: anchor)
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

/// `--export <from> <to> <directory>` writes the date range's raw events and sessions as CSV and
/// JSON into the directory, and `--verify-export <directory>` checks such an export's chain.
/// Dates are ISO 8601 (for example `2026-11-19` or `2026-11-19T12:30:00Z`).
func exportIfAsked(_ url: URL) {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--export"), arguments.indices.contains(flag + 3) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        guard let from = day.date(from: arguments[flag + 1]) ?? iso.date(from: arguments[flag + 1]),
            let end = day.date(from: arguments[flag + 2]) ?? iso.date(from: arguments[flag + 2])
        else {
            print("ERROR: dates are ISO 8601 (for example 2026-11-19 or 2026-11-19T12:30:00Z)")
            exit(EXIT_FAILURE)
        }
        do {
            let directory = URL(filePath: arguments[flag + 3])
            let manifest = try AuditExport.write(store: EventStore(url: url), from: from, to: end, to: directory)
            print("Exported \(manifest.rowCount) events and \(manifest.sessionCount) sessions to \(directory.path(percentEncoded: false))")
            exit(EXIT_SUCCESS)
        } catch {
            print("ERROR: \(error)")
            exit(EXIT_FAILURE)
        }
    }
    if let flag = arguments.firstIndex(of: "--verify-export"), arguments.indices.contains(flag + 1) {
        do {
            let report = try AuditExport.verify(directory: URL(filePath: arguments[flag + 1]))
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
