import Foundation
import Testing

private func fixtureFiles() throws -> [URL] {
    let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func fixturesAreNamedWithSourceMacOSVersionAndBuild() throws {
    let files = try fixtureFiles()
    #expect(!files.isEmpty)
    for file in files {
        let name = file.lastPathComponent
        #expect(name.wholeMatch(of: /[a-z]+(-[a-z]+)*-\d+(\.\d+)+-[0-9A-Za-z]+\.(ndjson|log)/) != nil, "\(name)")
    }
}

@Test func ndjsonFixturesAreUnmodifiedLogStreamOutput() throws {
    for file in try fixtureFiles() where file.pathExtension == "ndjson" {
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        // `log stream` writes this banner to stdout before the first event, so parsers must skip it.
        #expect(lines.first?.hasPrefix("Filtering the log data") == true, "\(file.lastPathComponent)")
        let events = lines.dropFirst().compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        #expect(events.count == lines.count - 1, "\(file.lastPathComponent) has lines that are not JSON objects")
        #expect(events.allSatisfy { $0["eventMessage"] is String && $0["timestamp"] is String })
    }
}

@Test func fixturesContainNoHomeDirectoryPaths() throws {
    for file in try fixtureFiles() {
        let text = try String(contentsOf: file, encoding: .utf8).replacing("\\/", with: "/")
        #expect(!text.contains("/Users/"), "\(file.lastPathComponent) contains a home directory path. Scrub it before committing.")
    }
}
