import Foundation

/// The cleanup commands build tools provide for themselves.
///
/// Some stores should not be deleted from underneath the tool that owns
/// them. Removing `~/go/pkg/mod` by hand leaves read-only directories and
/// a confused module cache; `go clean -modcache` does the same job and
/// leaves Go in a state it understands. Same for npm, pip and Homebrew.
///
/// The commands live here, keyed by a stable identifier, because the step
/// vocabulary forbids a caller-supplied command string. A plan names which
/// cleanup to run. It cannot describe one.
public enum ToolCleanup {

    public struct Command: Sendable, Equatable {
        public let id: String
        /// What the user sees before approving, exactly as it would be
        /// typed. The spec is explicit that this is shown first.
        public let displayed: String
        let executable: String
        let arguments: [String]
    }

    private static let catalogue: [Command] = [
        Command(id: "npm.cache", displayed: "npm cache clean --force",
                executable: "/usr/bin/env", arguments: ["npm", "cache", "clean", "--force"]),
        Command(id: "go.modcache", displayed: "go clean -modcache",
                executable: "/usr/bin/env", arguments: ["go", "clean", "-modcache"]),
        Command(id: "pip.cache", displayed: "pip cache purge",
                executable: "/usr/bin/env", arguments: ["pip", "cache", "purge"]),
        Command(id: "homebrew.cleanup", displayed: "brew cleanup --prune=all",
                executable: "/usr/bin/env", arguments: ["brew", "cleanup", "--prune=all"]),
        Command(id: "cargo.cache", displayed: "cargo cache --autoclean",
                executable: "/usr/bin/env", arguments: ["cargo", "cache", "--autoclean"]),
        Command(id: "pnpm.store", displayed: "pnpm store prune",
                executable: "/usr/bin/env", arguments: ["pnpm", "store", "prune"]),
        Command(id: "gradle.cache", displayed: "gradle --stop", // stops daemons before pruning
                executable: "/usr/bin/env", arguments: ["gradle", "--stop"]),
        Command(id: "xcode.simulators", displayed: "xcrun simctl delete unavailable",
                executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
    ]

    public static func command(id: String) -> Command? {
        catalogue.first { $0.id == id }
    }

    public enum CleanupError: Error, LocalizedError, Equatable {
        case unknownCleanup(String)
        case toolMissing(String)
        case failed(String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .unknownCleanup(let id):
                return "Brim has no cleanup registered under \(id)."
            case .toolMissing(let displayed):
                return "Could not run `\(displayed)`. The tool is not on this Mac, or not on "
                     + "the path Brim can see."
            case .failed(let displayed, let code):
                return "`\(displayed)` exited with status \(code)."
            }
        }
    }

    /// Runs a cleanup by identifier. No command string crosses this
    /// boundary, and nothing reaches a shell.
    public static func run(
        id: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) throws {
        guard let command = command(id: id) else { throw CleanupError.unknownCleanup(id) }
        let invoke = runner ?? Self.execute
        let status = try invoke(command.executable, command.arguments)
        // `env` reports 127 when it cannot find what it was asked to run.
        if status == 127 { throw CleanupError.toolMissing(command.displayed) }
        guard status == 0 else { throw CleanupError.failed(command.displayed, code: status) }
    }

    static func execute(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
