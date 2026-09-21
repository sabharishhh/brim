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
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting. A tool that fills the pipe buffer while
        // nobody is draining it blocks forever, and `pluginkit` prints
        // five hundred lines.
        let data = output.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            // One unresponsive probe must not hang the scan.
            process.terminate()
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
