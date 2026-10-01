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
        Command(id: "pnpm.store", displayed: "pnpm store prune",
                executable: "/usr/bin/env", arguments: ["pnpm", "store", "prune"]),
        Command(id: "uv.cache", displayed: "uv cache clean",
                executable: "/usr/bin/env", arguments: ["uv", "cache", "clean"]),
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
        case signalled(String, signal: Int32)
        case timedOut(String)
        case cancelled(String)
        case executionFailed(String, operation: String, code: Int32)
        case terminationUnconfirmed(String)

        public var outcomeCode: String {
            switch self {
            case .unknownCleanup: "cleanup_unknown"
            case .toolMissing: "cleanup_missing"
            case .failed, .signalled: "cleanup_failed"
            case .timedOut: "cleanup_timed_out"
            case .cancelled: "cleanup_cancelled"
            case .executionFailed: "cleanup_execution_failed"
            case .terminationUnconfirmed: "cleanup_termination_unconfirmed"
            }
        }

        public var errorDescription: String? {
            switch self {
            case let .unknownCleanup(id):
                "Brim has no cleanup registered under \(id)."
            case let .toolMissing(displayed):
                "Could not run `\(displayed)`. The tool is not on this Mac, or not on "
                    + "the path Brim can see."
            case let .failed(displayed, code):
                "`\(displayed)` exited with status \(code)."
            case let .signalled(displayed, signal):
                "`\(displayed)` stopped with signal \(signal)."
            case let .timedOut(displayed):
                "`\(displayed)` exceeded the time limit and was stopped. It may have removed some items."
            case let .cancelled(displayed):
                "`\(displayed)` was cancelled. It may have removed some items."
            case let .executionFailed(displayed, operation, code):
                "Could not complete `\(displayed)` (\(operation), error \(code))."
            case let .terminationUnconfirmed(displayed):
                "Brim could not confirm that `\(displayed)` stopped. Check the tool before trying again."
            }
        }
    }

    /// Runs a cleanup by identifier. No command string crosses this
    /// boundary, and nothing reaches a shell.
    public static func run(
        id: String,
        runner: (@Sendable (String, [String]) async throws -> Int32)? = nil
    ) async throws {
        guard let command = command(id: id) else { throw CleanupError.unknownCleanup(id) }
        let invoke = runner ?? Self.execute
        let status: Int32
        do {
            status = try await invoke(command.executable, command.arguments)
        } catch let failure as NativeCommandRunner.Failure {
            throw mapped(failure, displayed: command.displayed)
        } catch let failure as ExecutionFailure {
            throw mapped(failure, displayed: command.displayed)
        }
        // `env` reports 127 when it cannot find what it was asked to run.
        if status == 127 {
            throw CleanupError.toolMissing(command.displayed)
        }
        guard status == 0 else { throw CleanupError.failed(command.displayed, code: status) }
    }

    private static func mapped(_ failure: NativeCommandRunner.Failure, displayed: String) -> CleanupError {
        switch failure {
        case let .systemCall(operation, code):
            if operation == "spawn", code == ENOENT {
                return .toolMissing(displayed)
            }
            return .executionFailed(displayed, operation: operation, code: code)
        case .terminationUnconfirmed:
            return .terminationUnconfirmed(displayed)
        case .invalidConfiguration:
            return .executionFailed(displayed, operation: "configuration", code: EINVAL)
        }
    }

    private static func mapped(_ failure: ExecutionFailure, displayed: String) -> CleanupError {
        switch failure {
        case .timedOut: .timedOut(displayed)
        case .cancelled: .cancelled(displayed)
        case let .signalled(signal): .signalled(displayed, signal: signal)
        }
    }

    /// An app opened from Finder gets only the system folders on its PATH,
    /// so `env` could not find npm, pnpm, brew or uv wherever Homebrew or
    /// the tool's own installer put them, and every cleanup that needed one
    /// said the tool was not on this Mac.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/.local/bin",
                     "\(home)/go/bin", "/usr/bin", "/bin"]
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return environment
    }

    private enum ExecutionFailure: Error {
        case timedOut, cancelled, signalled(Int32)
    }

    static func execute(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        let result = try await NativeCommandRunner.run(executable: executable, arguments: arguments,
                                                       environment: environment())
        switch result.termination {
        case let .exited(code): return code
        case let .signalled(signal): throw ExecutionFailure.signalled(signal)
        case .timedOut: throw ExecutionFailure.timedOut
        case .cancelled: throw ExecutionFailure.cancelled
        }
    }
}
