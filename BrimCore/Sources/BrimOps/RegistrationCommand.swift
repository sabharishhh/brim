import Foundation

/// Shared deadlines and bounded output for fixed macOS registration tools.
enum RegistrationCommand {
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                              "HOME": NSHomeDirectory()]

    static func run(_ executable: String, _ arguments: [String]) async throws -> NativeCommandRunner.Result {
        try await NativeCommandRunner.run(executable: executable, arguments: arguments,
                                          environment: environment, timeout: 10, outputLimit: 1024 * 1024)
    }

    static func status(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        let result = try await run(executable, arguments)
        guard case let .exited(status) = result.termination else {
            throw NSError(domain: "BrimRegistration", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The registration command did not finish."
            ])
        }
        return status
    }
}
