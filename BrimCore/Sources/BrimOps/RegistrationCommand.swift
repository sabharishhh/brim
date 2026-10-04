import BrimProcess
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// Shared deadlines and bounded output for fixed macOS registration tools.
enum RegistrationCommand {
    typealias Runner = @Sendable (String, [String]) async throws -> NativeCommandRunner.Result

    enum Failure: Error, LocalizedError, Equatable {
        case didNotFinish(NativeCommandRunner.Termination)
        case unreadableOutput

        var errorDescription: String? {
            switch self {
            case .didNotFinish(.timedOut): "The registration command timed out."
            case .didNotFinish(.cancelled): "The registration command was cancelled."
            case .didNotFinish: "The registration command did not finish."
            case .unreadableOutput: "The registration command did not return a complete readable result."
            }
        }
    }

    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                              "HOME": NSHomeDirectory()]

    static func run(_ executable: String, _ arguments: [String]) async throws -> NativeCommandRunner.Result {
        try await NativeCommandRunner.run(executable: executable, arguments: arguments,
                                          environment: environment, timeout: 10, outputLimit: 1024 * 1024)
    }

    static func status(_ executable: String, _ arguments: [String],
                       runner: Runner = Self.run) async throws -> Int32 {
        let result = try await runner(executable, arguments)
        guard case let .exited(status) = result.termination else {
            throw Failure.didNotFinish(result.termination)
        }
        return status
    }

    static func read(_ executable: String, _ arguments: [String],
                     runner: Runner = Self.run) async throws -> String {
        let result = try await runner(executable, arguments)
        guard result.termination == .exited(0), !result.outputTruncated,
              let text = String(data: result.stdout, encoding: .utf8)
        else {
            throw Failure.unreadableOutput
        }
        return text
    }
}
