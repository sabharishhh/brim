import Foundation

/// Running one of Apple's own tools and reading what it says.
///
/// Several registration surfaces have no API and only a command: PluginKit
/// and the system extension list among them. The rule from the step
/// vocabulary holds here too, even though nothing is being mutated: a
/// fixed executable and fixed arguments, never a string somebody else
/// composed.
///
/// Returns nil when the tool is missing or fails, which is how a surface
/// tells `coverage` that it could not look. An empty string would mean
/// "nothing registered", and those are different answers.
public enum ToolOutput {
    /// What a tool said, whatever its exit status. Some tools answer with
    /// a status: `pkgutil --check-signature` exits 1 for an unsigned
    /// package and `spctl` 3 for a rejected one, and both of those are
    /// answers rather than failures to look.
    public struct Outcome: Sendable, Equatable {
        public let status: Int32
        public let output: String
        public let errors: String
    }

    public static func read(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 10
    ) -> String? {
        guard let outcome = run(executable, arguments, timeout: timeout), outcome.status == 0 else { return nil }
        return outcome.output
    }

    /// Nil when the tool is missing, could not start, ran out of time or
    /// said more than `limit` bytes.
    public static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 10,
        limit: Int = 8 * 1024 * 1024
    ) -> Outcome? {
        guard !Task.isCancelled, timeout.isFinite, timeout > 0,
              FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A pipe filled before the process exits can stall both the tool
        // and our reader. File handles have no bounded buffer to fill.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-probe-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil
        else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let stdout = folder.appendingPathComponent("stdout")
        let stderr = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: stdout.path),
              let errors = FileHandle(forWritingAtPath: stderr.path) else { return nil }
        defer {
            try? output.close()
            try? errors.close()
        }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            let size = (try? FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? Int) ?? 0
            if size > limit {
                break
            }
            usleep(20000)
        }
        if process.isRunning {
            stop(process)
            return nil
        }
        // Output past the limit, or that is not text, is not an answer.
        guard let said = data(of: stdout, upTo: limit + 1), said.count <= limit,
              let text = String(data: said, encoding: .utf8) else { return nil }
        // Errors are only ever a sentence or two; the start is enough.
        let complaint = data(of: stderr, upTo: 64 * 1024).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return Outcome(status: process.terminationStatus, output: text, errors: complaint)
    }

    private static func data(of file: URL, upTo count: Int) -> Data? {
        guard let reader = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? reader.close() }
        return try? reader.read(upToCount: count) ?? Data()
    }

    private static func stop(_ process: Process) {
        process.terminate()
        let grace = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < grace {
            usleep(10000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
