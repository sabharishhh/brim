import BrimProcess
import Darwin
import Foundation

/// One socket and one owned authorization task. Requests use a dedicated serial
/// queue; shutdown never waits behind a request, so quitting can interrupt it.
final class TemporaryAdminSession: @unchecked Sendable {
    private let descriptor: Int32
    private let listener: TemporaryAdminChannel.Listener
    private let launch: Task<NativeCommandRunner.Result, Error>
    private let queue = DispatchQueue(label: "com.sabharishhh.brim.administrator")

    private init(
        descriptor: Int32, listener: TemporaryAdminChannel.Listener,
        launch: Task<NativeCommandRunner.Result, Error>
    ) {
        self.descriptor = descriptor
        self.listener = listener
        self.launch = launch
    }

    deinit {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        TemporaryAdminChannel.cleanup(listener)
    }

    @concurrent
    static func start(executable: URL) async throws -> TemporaryAdminSession {
        let listener = try TemporaryAdminChannel.makeListener()
        let launch = launchAdministrator(executable: executable, socketPath: listener.path)
        let acceptance = PendingAcceptance(descriptor: listener.descriptor)
        Task {
            do { try await acceptance.launchEnded(.success(launch.value)) } catch {
                acceptance.launchEnded(.failure(error))
            }
        }
        var transferred = false
        do {
            let descriptor = try await withTaskCancellationHandler {
                try await accept(listener)
            } onCancel: {
                acceptance.interrupt()
                launch.cancel()
            }
            acceptance.disarm()
            guard !Task.isCancelled else {
                Darwin.close(descriptor)
                throw CancellationError()
            }
            let session = TemporaryAdminSession(descriptor: descriptor, listener: listener, launch: launch)
            transferred = true
            let response = try await session.request(.version)
            guard response.data == Data(BrimJobHelper.version.utf8), response.complaint == nil else {
                session.stop()
                throw TemporaryAdminChannel.Failure("The administrator process does not match this copy of Brim.")
            }
            return session
        } catch {
            // Disarm before the listener can close. A late launcher callback
            // must never shut down a descriptor subsequently reused by the app.
            acceptance.disarm()
            launch.cancel()
            if !transferred {
                TemporaryAdminChannel.cleanup(listener)
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            if let launchFailure = acceptance.failure {
                throw launchFailure
            }
            throw error
        }
    }

    private static func launchAdministrator(
        executable: URL, socketPath: String
    ) -> Task<NativeCommandRunner.Result, Error> {
        // Copy before checking the signature. The root-owned staging directory
        // prevents a replaced app bundle changing what executes after verification.
        let command = "umask 077; admin_work=$(/usr/bin/mktemp -d /private/tmp/brim-admin.XXXXXXXX) || exit 1; "
            + "trap '/bin/rm -rf \"$admin_work\"' EXIT HUP INT TERM; "
            + "/bin/cp -L " + shellQuote(executable.path) + " \"$admin_work/BrimJobHelper\" && "
            + "[ -f \"$admin_work/BrimJobHelper\" ] && [ ! -L \"$admin_work/BrimJobHelper\" ] && "
            + "/usr/bin/codesign --verify --strict -R=" + shellQuote(BrimJobHelper.daemonRequirement())
            + " \"$admin_work/BrimJobHelper\" && "
            // Security inspects the peer's executable from the app process.
            // Only root can change the copy; the app can traverse and read it.
            + "/bin/chmod 0711 \"$admin_work\" && /bin/chmod 0755 \"$admin_work/BrimJobHelper\" && "
            + "\"$admin_work/BrimJobHelper\" --temporary " + shellQuote(socketPath)
        let script = "do shell script " + appleScriptQuote(command) + " with administrator privileges"
        return Task {
            try await NativeCommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script],
                                              environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                                              timeout: 15 * 60, outputLimit: 4096)
        }
    }

    @concurrent private static func accept(_ listener: TemporaryAdminChannel.Listener) async throws -> Int32 {
        try TemporaryAdminChannel.acceptHelper(listener, timeoutSeconds: 120)
    }

    func request(_ command: TemporaryAdminRequest) async throws -> TemporaryAdminResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try TemporaryAdminChannel.send(request: command, to: descriptor)
                    try continuation.resume(returning: TemporaryAdminChannel.receiveResponse(from: descriptor))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    func finish() async {
        stop()
        // The socket disconnect ends the helper. A grace period allows its root
        // shell to remove the signed staging copy before stopping a stuck launcher.
        let timer = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                launch.cancel()
            }
        }
        _ = try? await launch.value
        timer.cancel()
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}

/// The launch watcher and accept cancellation handler share only this lock-held
/// descriptor lifetime. Every mutable field is accessed under the same lock.
private final class PendingAcceptance: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var active = true
    private var launchFailure: Error?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    var failure: Error? {
        lock.withLock { launchFailure }
    }

    func disarm() {
        lock.withLock { active = false }
    }

    func interrupt() {
        lock.withLock {
            if active {
                Darwin.shutdown(descriptor, SHUT_RDWR)
            }
        }
    }

    func launchEnded(_ result: Result<NativeCommandRunner.Result, Error>) {
        lock.withLock {
            guard active else { return }
            switch result {
            case let .failure(error): launchFailure = error
            case let .success(response):
                switch response.termination {
                case .cancelled: launchFailure = CancellationError()
                case .timedOut: launchFailure = TemporaryAdminChannel.Failure.timedOut
                case .exited, .signalled:
                    let detail = (String(data: response.stderr, encoding: .utf8) ?? "Invalid administrator response.")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    launchFailure = TemporaryAdminChannel.Failure(detail.isEmpty
                        ? "Administrator cleanup stopped before connecting." : detail)
                }
            }
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }
}
