import Foundation

/// A daily record of the hash chain's head, kept outside the database so that a later
/// `verifyIntegrity(anchor:)` can tell whether the chain still contains that row unchanged.
/// One JSON line per UTC day, in `anchors.log` next to the database.
public enum AnchorLog {
    public static func url(near databaseURL: URL = EventStore.defaultURL) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: "anchors.log")
    }

    /// Appends the head for `date`, once per UTC day. Returns false when today's anchor already
    /// exists — the same head is expected, and a different one means the chain was rewritten.
    @discardableResult
    public static func append(head: ChainAnchor, at date: Date = .now, to url: URL = AnchorLog.url()) throws -> Bool {
        let day = Self.dayFormatter.string(from: date)
        if try read(from: url).contains(where: { $0.day == day }) { return false }
        let line = "\(day) \(head.id) \(head.hash)\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// Every saved anchor, oldest first.
    public static func read(from url: URL = AnchorLog.url()) throws -> [(day: String, anchor: ChainAnchor)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 3, let id = Int64(parts[1]) else { return nil }
            return (String(parts[0]), ChainAnchor(id: id, hash: String(parts[2])))
        }
    }

    /// The most recent saved anchor, for display.
    public static func latest(from url: URL = AnchorLog.url()) throws -> ChainAnchor? {
        try read(from: url).last?.anchor
    }

    /// The oldest saved anchor, for `verifyIntegrity(anchor:)`. Verifying against the newest
    /// would let a database rewrite be adopted silently by the next day's anchor; the oldest
    /// can only stay valid while the chain still reaches back to it unchanged.
    public static func earliest(from url: URL = AnchorLog.url()) throws -> ChainAnchor? {
        try read(from: url).first?.anchor
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
