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
              let output = FileHandle(forWritingAtPath: stdout.path) else { return nil }
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var reader: FileHandle?
        if let input {
            let file = folder.appendingPathComponent("stdin")
            guard FileManager.default.createFile(atPath: file.path, contents: Data(input.utf8)),
                  let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
            reader = handle
        }
        defer { try? reader?.close() }
        process.standardInput = reader ?? FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? Int) ?? 0
            if size > limit {
                break
            }
            usleep(20000)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning, Date() < grace {
                usleep(10000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return nil
        }
        guard let reader = try? FileHandle(forReadingFrom: stdout) else { return nil }
        defer { try? reader.close() }
        guard let said = try? reader.read(upToCount: limit + 1) ?? Data(), said.count <= limit else { return nil }
        return Outcome(status: process.terminationStatus, output: String(decoding: said, as: UTF8.self))
    }
}
