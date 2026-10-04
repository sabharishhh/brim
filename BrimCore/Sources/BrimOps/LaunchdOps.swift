import BrimCore
import Foundation

/// Command completion and its later observation are different receipts.
public enum LaunchdStopError: Error, LocalizedError, Equatable, Sendable {
    case verificationFailedAfterStop(String)

    public var errorDescription: String? {
        switch self {
        case let .verificationFailedAfterStop(message): message
        }
    }
}

// swiftformat:disable wrapMultilineStatementBraces
public extension SafeOps {
    /// Only an exact service target can be stopped. No bare launch domain.
    static func unloadLaunchdJobBounded(path: String) async throws -> Bool {
        try await stopLaunchdJob(path: path, namespace: launchNamespace(for: path), runner: RegistrationCommand.run)
    }

    static func loadLaunchdJobBounded(path: String) async throws {
        try await restoreLaunchdJob(path: path, namespace: launchNamespace(for: path), runner: RegistrationCommand.run)
    }

    static func observeLaunchdService(label: String, namespace: String) async -> PathObservation {
        await observeLaunchdService(label: label, namespace: namespace, runner: RegistrationCommand.run)
    }

    /// Rechecks the reviewed job, rather than any job that later reused its label.
    static func observeLoadedReviewedJob(_ record: Registration) async -> PathObservation {
        await observeLoadedReviewedJob(record, runner: RegistrationCommand.run)
    }

    static func unloadLaunchdJob(path: String) async throws {
        _ = try await unloadLaunchdJobBounded(path: path)
    }

    static func loadLaunchdJob(path: String) async throws {
        try await loadLaunchdJobBounded(path: path)
    }
}

extension SafeOps {
    static func stopLaunchdJob(
        path: String, namespace: String, runner: RegistrationCommand.Runner
    ) async throws -> Bool {
        let declaration = try DeclarationIdentity.read(path)
        let definition = try LaunchdJobDefinition.read(path)
        try declaration.requireUnchanged(path)
        let before = await observeLaunchdService(label: definition.label, namespace: namespace, runner: runner)
        if before.isAbsent {
            try declaration.requireUnchanged(path)
            return false
        }
        guard before.isPresent else { throw launchFailure("The launchd service could not be checked.") }
        let loaded = try await runner("/bin/launchctl", ["print", namespace + "/" + definition.label])
        guard matchesDefinition(definition, path: path, loaded: loaded) else {
            throw launchFailure("The loaded job does not match the reviewed declaration.")
        }
        try declaration.requireUnchanged(path)
        let result = try await runner("/bin/launchctl", ["bootout", namespace + "/" + definition.label])
        guard result.termination == .exited(0) else {
            throw launchFailure("The background job could not be stopped.")
        }
        let after = await observeLaunchdService(label: definition.label, namespace: namespace, runner: runner)
        guard after.isAbsent else {
            throw LaunchdStopError.verificationFailedAfterStop(
                "The stop command completed, but the background job's absence could not be verified."
            )
        }
        do {
            try declaration.requireUnchanged(path)
        } catch {
            throw LaunchdStopError.verificationFailedAfterStop(
                "The stop command completed, but the job declaration changed before verification finished."
            )
        }
        return true
    }

    static func restoreLaunchdJob(path: String, namespace: String, runner: RegistrationCommand.Runner) async throws {
        let declaration = try DeclarationIdentity.read(path)
        let definition = try LaunchdJobDefinition.read(path)
        try declaration.requireUnchanged(path)
        let before = await observeLaunchdService(label: definition.label, namespace: namespace, runner: runner)
        if before.isPresent {
            let loaded = try await runner("/bin/launchctl", ["print", namespace + "/" + definition.label])
            guard matchesDefinition(definition, path: path, loaded: loaded) else {
                throw launchFailure("A different or unreadable background job is already loaded. It was kept.")
            }
            try declaration.requireUnchanged(path)
            // A previous bootstrap may have succeeded before its check failed.
            return
        }
        guard before.isAbsent else {
            throw launchFailure("The background job could not be checked before restoration.")
        }
        try declaration.requireUnchanged(path)
        let status = try await RegistrationCommand.status(
            "/bin/launchctl", ["bootstrap", namespace, path], runner: runner
        )
        guard status == 0 else { throw launchFailure("The background job could not be restored.") }
        let loaded = try await runner("/bin/launchctl", ["print", namespace + "/" + definition.label])
        guard matchesDefinition(definition, path: path, loaded: loaded) else {
            throw launchFailure("The restored background job could not be verified.")
        }
        try declaration.requireUnchanged(path)
    }

    static func observeLaunchdService(label: String, namespace: String,
                                      runner: RegistrationCommand.Runner) async -> PathObservation {
        guard validService(label: label, namespace: namespace) else {
            return .unknown("The launchd service namespace is not available to this account.")
        }
        do {
            let domain = try await runner("/bin/launchctl", ["print", namespace])
            guard domain.termination == .exited(0) else {
                return .unknown("The launchd namespace could not be read.")
            }
            return try await servicePresence(runner("/bin/launchctl", ["print", namespace + "/" + label]))
        } catch {
            return .unknown("The launchd service could not be checked.")
        }
    }

    static func observeLoadedReviewedJob(_ record: Registration,
                                         runner: RegistrationCommand.Runner) async -> PathObservation {
        guard let namespace = record.namespace, validService(label: record.identifier, namespace: namespace) else {
            return .unknown("The reviewed background job has no supported namespace.")
        }
        do {
            let domain = try await runner("/bin/launchctl", ["print", namespace])
            guard domain.termination == .exited(0) else {
                return .unknown("The launchd namespace could not be read.")
            }
            let result = try await runner("/bin/launchctl", ["print", namespace + "/" + record.identifier])
            let presence = servicePresence(result)
            guard presence.isPresent else { return presence }
            guard let declaration = loadedField("path", in: result), let reviewedPath = record.recordPath else {
                return .unknown("The loaded job declaration could not be matched to the reviewed job.")
            }
            guard samePath(declaration, reviewedPath) else { return .absent }
            guard let program = loadedField("program", in: result), let reviewedProgram = record.programPath else {
                return .unknown("The loaded job program could not be matched to the reviewed job.")
            }
            return samePath(program, reviewedProgram) ? .present : .absent
        } catch {
            return .unknown("The reviewed background job could not be checked.")
        }
    }

    static func launchNamespace(for path: String) throws -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        if parent == "/Library/LaunchDaemons" {
            return "system"
        }
        if parent == "/Library/LaunchAgents" || parent == NSHomeDirectory() + "/Library/LaunchAgents" {
            return "gui/\(getuid())"
        }
        throw launchFailure("The job is outside the supported launchd folders.")
    }

    private static func validService(label: String, namespace: String) -> Bool {
        !label.isEmpty && !label.contains("/") && !label.contains("\0")
            && (namespace == "system" || namespace == "gui/\(getuid())")
    }

    private static func loadedField(_ field: String, in result: NativeCommandRunner.Result) -> String? {
        guard result.termination == .exited(0), !result.outputTruncated,
              let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        let prefix = field + " = "
        let values = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        guard values.count == 1, let value = values.first,
              value.hasPrefix("/"), !value.contains("\0") else { return nil }
        return value
    }

    private static func matchesDefinition(_ definition: LaunchdJobDefinition, path: String,
                                          loaded: NativeCommandRunner.Result) -> Bool {
        guard let declaration = loadedField("path", in: loaded), samePath(declaration, path),
              let expectedProgram = definition.resolvedProgram(plistPath: path),
              let program = loadedField("program", in: loaded) else { return false }
        return samePath(program, expectedProgram)
    }

    private static func samePath(_ first: String, _ second: String) -> Bool {
        guard first.hasPrefix("/"), second.hasPrefix("/"), !second.contains("\0") else { return false }
        return URL(fileURLWithPath: first).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: second).resolvingSymlinksInPath().path
    }

    private static func servicePresence(_ result: NativeCommandRunner.Result) -> PathObservation {
        if result.termination == .exited(0) {
            return .present
        }
        let diagnostic = String(data: result.stderr, encoding: .utf8) ?? ""
        if result.termination == .exited(113), !result.outputTruncated,
           diagnostic.contains("Could not find service") {
            return .absent
        }
        return .unknown("The launchd service could not be checked.")
    }

    private static func launchFailure(_ message: String) -> NSError {
        NSError(domain: "BrimLaunchd", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Keep the declaration bound across the suspension points before a mutation.
    private struct DeclarationIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        static func read(_ path: String) throws -> Self {
            var metadata = stat()
            guard lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw SafeOps.launchFailure("The job declaration is not a readable regular file.")
            }
            return Self(device: metadata.st_dev, inode: metadata.st_ino, size: metadata.st_size,
                        modifiedSeconds: metadata.st_mtimespec.tv_sec,
                        modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
                        changedSeconds: metadata.st_ctimespec.tv_sec,
                        changedNanoseconds: metadata.st_ctimespec.tv_nsec)
        }

        func requireUnchanged(_ path: String) throws {
            guard try Self.read(path) == self else {
                throw SafeOps.launchFailure("The job declaration changed. Review it again.")
            }
        }
    }
}
