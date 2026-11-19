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

/// `--verify` checks the hash chain, prints the result, and exits with status 1 if it is broken.
func verify(_ url: URL) -> Never {
    do {
        let report = try EventStore(url: url).verifyIntegrity()
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

let url = databaseURL()
if CommandLine.arguments.contains("--verify") {
    verify(url)
}
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
