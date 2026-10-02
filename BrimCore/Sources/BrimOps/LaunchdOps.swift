import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
public extension SafeOps {
    /// Only an exact service target can be stopped. No bare launch domain.
    static func unloadLaunchdJobBounded(path: String) async throws {
        let definition = try LaunchdJobDefinition.read(path)
        let namespace = try launchNamespace(for: path)
        let before = await observeLaunchdService(label: definition.label, namespace: namespace)
        if before.isAbsent {
            return
        }
        guard before.isPresent else { throw launchFailure("The launchd service could not be checked.") }
        let loaded = try await RegistrationCommand.run("/bin/launchctl", ["print", namespace + "/" + definition.label])
        let declaredPath = (String(data: loaded.stdout, encoding: .utf8) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("path = ") }.map { String($0.dropFirst(7)) }
        guard loaded.termination == .exited(0), !loaded.outputTruncated,
              declaredPath.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
              == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        else {
            throw launchFailure("The loaded job does not match the reviewed declaration.")
        }
        let result = try await RegistrationCommand.run(
            "/bin/launchctl",
            ["bootout", namespace + "/" + definition.label]
        )
        guard result.termination == .exited(0) else {
            throw launchFailure("The background job could not be stopped.")
        }
        guard await observeLaunchdService(label: definition.label, namespace: namespace).isAbsent else {
            throw launchFailure("The background job still appears in launchd.")
        }
    }

    static func loadLaunchdJobBounded(path: String) async throws {
        let namespace = try launchNamespace(for: path)
        _ = try LaunchdJobDefinition.read(path)
        let status = try await RegistrationCommand.status("/bin/launchctl", ["bootstrap", namespace, path])
        guard status == 0 else { throw launchFailure("The background job could not be restored.") }
    }

    static func observeLaunchdService(label: String, namespace: String) async -> PathObservation {
        guard !label.isEmpty, !label.contains("/"), !label.contains("\0"),
              namespace == "system" || namespace == "gui/\(getuid())"
        else {
            return .unknown("The launchd service namespace is not available to this account.")
        }
        do {
            let domain = try await RegistrationCommand.run("/bin/launchctl", ["print", namespace])
            guard domain.termination == .exited(0) else {
                return .unknown("The launchd namespace could not be read.")
            }
            let result = try await RegistrationCommand.run("/bin/launchctl", ["print", namespace + "/" + label])
            if result.termination == .exited(0) {
                return .present
            }
            let diagnostic = (String(data: result.stderr, encoding: .utf8) ?? "")
            if result.termination == .exited(113), !result.outputTruncated,
               diagnostic.contains("Could not find service") {
                return .absent
            }
            return .unknown("The launchd service could not be checked.")
        } catch {
            return .unknown("The launchd service could not be checked.")
        }
    }

    internal static func launchNamespace(for path: String) throws -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        if parent == "/Library/LaunchDaemons" {
            return "system"
        }
        if parent == "/Library/LaunchAgents" || parent == NSHomeDirectory() + "/Library/LaunchAgents" {
            return "gui/\(getuid())"
        }
        throw launchFailure("The job is outside the supported launchd folders.")
    }

    private static func launchFailure(_ message: String) -> NSError {
        NSError(domain: "BrimLaunchd", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func unloadLaunchdJob(path: String) throws {
        // Run launchctl unload. In a real uninstaller, we might use SMAppService.daemon(plistName:).unregister()
        // if we are the app itself, but since we are an external uninstaller, we use launchctl.
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", path]

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        // A non-zero status is ignored on purpose: a job that was already
        // unloaded is the common case and is not a failure. The comment here
        // used to say "we log it", above an empty branch holding a
        // commented-out `print`, which said nothing was logged at all. It is
        // still nothing, and now it says so. Whether a genuine unload failure
        // should reach the journal is a real question, and a separate one
        // from removing debug output: launchd keeping a job alive after its
        // plist is gone is the B2 failure mode in `docs/deep-uninstall.md`.
    }

    static func loadLaunchdJob(path: String) throws {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["load", path]

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()
    }
}
