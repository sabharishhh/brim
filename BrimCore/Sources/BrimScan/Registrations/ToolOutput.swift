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
    public static func read(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 10
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A pipe filled before the process exits can stall both the tool
        // and our reader. File handles have no bounded buffer to fill.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-probe-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let stdout = folder.appendingPathComponent("stdout")
        let stderr = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: stdout.path),
              let errors = FileHandle(forWritingAtPath: stderr.path) else { return nil }
        defer { try? output.close(); try? errors.close() }
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: stdout) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
