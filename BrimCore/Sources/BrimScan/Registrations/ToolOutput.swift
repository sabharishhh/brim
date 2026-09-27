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
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let stdout = folder.appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: stdout.path) else { return nil }
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        let limit = 8 * 1024 * 1024
        while process.isRunning, Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? Int) ?? 0
            if size > limit { break }
            usleep(20000)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < grace { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0,
              let reader = try? FileHandle(forReadingFrom: stdout) else { return nil }
        defer { try? reader.close() }
        guard let data = try? reader.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
