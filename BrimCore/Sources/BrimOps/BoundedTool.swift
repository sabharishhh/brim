import Darwin
import Foundation

/// One of Apple's tools, run with a deadline and its output written to
/// files.
///
/// Updates and installs ran `hdiutil`, `pkgutil`, `spctl` and `ditto`
/// through a pipe that was read only once the tool had exited, with no
/// time limit: a tool that wrote more than a pipe holds, or never finished,
/// held the update for ever. A file never fills, and a tool past its
/// deadline is stopped.
enum BoundedTool {
    struct Outcome: Equatable {
        let status: Int32
        let output: String
    }

    /// Nil when the tool could not start, ran out of time or said more than
    /// `limit` bytes.
    static func run(
        _ tool: String, _ arguments: [String], timeout: TimeInterval, input: String? = nil,
        limit: Int = 8 * 1024 * 1024
    ) -> Outcome? {
        guard timeout.isFinite, timeout > 0, FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-tool-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        let stdout = folder.appendingPathComponent("stdout")
        guard FileManager.default.createFile(atPath: stdout.path, contents: nil),
              let output = FileHandle(forWritingAtPath: stdout.path),
              let reader = standardInput(input, in: folder) else { return nil }
        defer {
            try? output.close()
            try? reader.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = reader
        guard (try? process.run()) != nil else { return nil }
        guard finishes(process, file: stdout, timeout: timeout, limit: limit) else {
            stop(process)
            return nil
        }
        guard let said = contents(of: stdout, upTo: limit + 1), said.count <= limit else { return nil }
        return Outcome(status: process.terminationStatus, output: String(bytes: said, encoding: .utf8) ?? "")
    }

    /// What the tool reads: the input, written to a file, or nothing.
    private static func standardInput(_ input: String?, in folder: URL) -> FileHandle? {
        guard let input else { return FileHandle.nullDevice }
        let file = folder.appendingPathComponent("stdin")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(input.utf8)) else { return nil }
        return FileHandle(forReadingAtPath: file.path)
    }

    private static func finishes(_ process: Process, file: URL, timeout: TimeInterval, limit: Int) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if size > limit {
                return false
            }
            usleep(20000)
        }
        return !process.isRunning
    }

    private static func stop(_ process: Process) {
        process.terminate()
        let grace = Date().addingTimeInterval(1)
        while process.isRunning, Date() < grace {
            usleep(10000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func contents(of file: URL, upTo count: Int) -> Data? {
        guard let reader = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? reader.close() }
        return try? reader.read(upToCount: count) ?? Data()
    }
}
