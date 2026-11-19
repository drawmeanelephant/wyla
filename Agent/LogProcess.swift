import Foundation

/// Runs `/usr/bin/log` and passes each line it prints to a handler.
enum LogProcess {
    /// Runs `log` with `arguments` until it exits, and returns its exit status. Runs on the
    /// caller's actor, so `handle` can use the caller's state.
    nonisolated(nonsending) static func run(_ arguments: [String], lines handle: (String) async -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        for await line in lines(of: output.fileHandleForReading) {
            await handle(line)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Splits the output into lines on a GCD thread, reading whatever the pipe holds each time.
    /// `FileHandle.bytes` delivers one byte per await, which is too slow for the TCC stream (about
    /// 100 KB/s), and `read(upToCount:)` waits for the full count, which delays live lines.
    private static func lines(of file: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .utility).async {
                var pending = Data()
                while case let chunk = file.availableData, !chunk.isEmpty {
                    pending.append(chunk)
                    guard let last = pending.lastIndex(of: 0x0A) else { continue }
                    for line in pending[..<last].split(separator: 0x0A, omittingEmptySubsequences: true) {
                        if let text = String(bytes: line, encoding: .utf8) {
                            continuation.yield(text)
                        }
                    }
                    pending = Data(pending[pending.index(after: last)...])
                }
                if !pending.isEmpty, let text = String(bytes: pending, encoding: .utf8) {
                    continuation.yield(text)
                }
                continuation.finish()
            }
        }
    }
}
