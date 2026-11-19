import Foundation
import GRDB
import Testing
import WylaCore

/// A database in a new temporary folder, deleted when the value is released.
final class TemporaryStore {
    let directory: URL
    let url: URL
    let store: EventStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "wyla-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        url = directory.appending(path: "wyla.sqlite")
        store = try EventStore(url: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A second connection that bypasses the append-only triggers, the way someone editing the
    /// file with `sqlite3` would.
    func tamper(_ sql: String, arguments: StatementArguments = []) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
        try queue.write { db in
            try db.execute(
                sql: """
                    DROP TRIGGER IF EXISTS raw_events_no_update;
                    DROP TRIGGER IF EXISTS raw_events_no_delete;
                    DROP TRIGGER IF EXISTS raw_events_extend_chain;
                    """)
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    func rows(_ sql: String) throws -> [Row] {
        try DatabaseQueue(path: url.path(percentEncoded: false)).read { db in try Row.fetchAll(db, sql: sql) }
    }

    /// Every table the recorder writes, except `coverage`, which gains a row per agent run.
    func contents() throws -> [String: [Row]] {
        var contents: [String: [Row]] = [:]
        for table in ["raw_events", "activations", "apps", "checkpoints", "tcc_requests", "tcc_requests_agg"] {
            contents[table] = try rows("SELECT * FROM \(table) ORDER BY 1")
        }
        return contents
    }
}

extension Recorder {
    /// Records every input, then lets 10 s pass, like `CaptureFixture.activations()`.
    func record(_ inputs: [RecorderInput]) throws {
        for input in inputs {
            try record(input)
        }
        try advance(to: (inputs.last?.time ?? .distantPast).addingTimeInterval(10))
    }
}

/// The fields of an activation that the session rules define, for comparing runs.
struct Summary: Equatable, CustomStringConvertible {
    let text: String

    init(_ activation: Activation) {
        text = [
            activation.sensor.rawValue, activation.client ?? "-", clock(activation.start), clock(activation.end),
            activation.endReason?.rawValue ?? "-", activation.displayName ?? "-", activation.device ?? "-",
            activation.responsible?.identifier ?? "-"
        ].joined(separator: " ")
    }

    var description: String { text }
}

func summaries(_ activations: [Activation]) -> [Summary] {
    activations.sorted { ($0.start, $0.sensor.rawValue, $0.client ?? "") < ($1.start, $1.sensor.rawValue, $1.client ?? "") }
        .map(Summary.init)
}
