import Foundation
import GRDB

enum StoreError: Error, Equatable {
    case unknownValue(column: String, value: String)
}

/// JSON with sorted keys, so that the same value always produces the same text.
func canonicalJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let text = String(bytes: try encoder.encode(value), encoding: .utf8) else {
        throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "JSONEncoder output is not UTF-8"))
    }
    return text
}

extension Activation {
    init(row: Row) throws {
        let sensorValue: String = row["sensor"]
        guard let sensor = Sensor(rawValue: sensorValue) else {
            throw StoreError.unknownValue(column: "sensor", value: sensorValue)
        }
        self.init(sensor: sensor, client: row["client"], start: Date(microseconds: row["start_us"]))
        end = (row["end_us"] as Int64?).map(Date.init(microseconds:))
        if let reason: String = row["end_reason"] {
            guard let endReason = EndReason(rawValue: reason) else {
                throw StoreError.unknownValue(column: "end_reason", value: reason)
            }
            self.endReason = endReason
        }
        displayName = row["display_name"]
        if let identifier: String = row["responsible_client"] {
            responsible = TCCProcess(identifier: identifier, pid: row["responsible_pid"], binaryPath: row["responsible_path"])
        }
        deviceUse = try JSONDecoder().decode([String: TimeInterval].self, from: Data((row["device_use"] as String).utf8))
        deviceUseCountedUntil = Date(microseconds: row["device_use_until_us"])
        startEventID = row["start_event_id"]
        endEventID = row["end_event_id"]
        responsibleEventID = row["responsible_event_id"]
    }

    /// Inserts a started activation. Inserting one that is already stored does nothing.
    func insert(startEventID: Int64?, responsibleEventID: Int64?, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO activations (sensor, client, start_us, device_use_until_us, responsible_client,
                    responsible_pid, responsible_path, start_event_id, responsible_event_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sensor.rawValue, client, start.microseconds, deviceUseCountedUntil.microseconds, responsible?.identifier,
                responsible?.pid, responsible?.binaryPath, startEventID, responsibleEventID
            ])
        try save(endEventID: nil, in: db)
        if let client {
            try App.saw(client, name: displayName, path: nil, at: start, in: db)
        }
        if let responsible {
            try App.saw(responsible.identifier, name: nil, path: responsible.binaryPath, at: start, in: db)
        }
    }

    /// Saves the fields that change while an activation runs and when it ends.
    func save(endEventID: Int64?, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE activations SET end_us = ?, end_reason = ?, display_name = ?, device = ?, device_use = ?,
                    device_use_until_us = ?, end_event_id = ifnull(?, end_event_id)
                WHERE sensor = ? AND client IS ? AND start_us = ?
                """,
            arguments: [
                end?.microseconds, endReason?.rawValue, displayName, device,
                try canonicalJSON(deviceUse), deviceUseCountedUntil.microseconds,
                endEventID, sensor.rawValue, client, start.microseconds
            ])
        if let client, let end {
            try App.saw(client, name: displayName, path: nil, at: end, in: db)
        }
    }
}

/// Rows of `apps`: every client and responsible app WYLA has seen.
private enum App {
    static func saw(_ client: String, name: String?, path: String?, at time: Date, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO apps (client, name, path, first_seen_us, last_seen_us, command_line) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (client) DO UPDATE SET name = ifnull(excluded.name, name), path = ifnull(excluded.path, path),
                    first_seen_us = min(first_seen_us, excluded.first_seen_us),
                    last_seen_us = max(last_seen_us, excluded.last_seen_us)
                """,
            arguments: [
                client, name, path, time.microseconds, time.microseconds,
                Attribution(sensor: .camera, client: client).isExecutableName
            ])
    }
}
