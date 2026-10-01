import Darwin
import Foundation

/// The child owns a new process group. Only that group is stopped, and
/// neither pipe can hold the child waiting for Brim to read it.
enum NativeCommandRunner {
    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut
        case cancelled
    }

    struct Result: Sendable {
        let termination: Termination
        let stdout: Data
        let stderr: Data
        let outputTruncated: Bool
    }

    enum Failure: Error, Equatable {
        case systemCall(String, Int32)
        case invalidConfiguration
        case terminationUnconfirmed
    }

    @concurrent
    static func run(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval = 120, outputLimit: Int = 64 * 1024,
        onSpawn: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> Result {
        try validate(executable, arguments, environment, timeout: timeout, outputLimit: outputLimit)
        if Task.isCancelled {
            return Result(termination: .cancelled, stdout: Data(), stderr: Data(), outputTruncated: false)
        }
        var output = try OutputPipe(limit: outputLimit)
        defer { output.close() }
        var errors = try OutputPipe(limit: outputLimit)
        defer { errors.close() }
        let pid = try spawn(executable, arguments, environment, output: output, errors: errors)
        onSpawn?(pid)
        output.closeWriter()
        errors.closeWriter()
        var reaped = false
        defer {
            if !reaped {
                // The PID remains reserved until reaped, so this cannot name
                // another execution. A rare OS refusal is reported above.
                reapAfterFailure(pid)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let termination: Termination
        while true {
            try output.drain()
            try errors.drain()
            var status: Int32 = 0
            let observed = waitpid(pid, &status, WNOHANG)
            if observed == pid {
                reaped = true
                termination = decode(status)
                break
            }
            if observed == -1, errno != EINTR {
                if errno == ECHILD {
                    reaped = true
                }
                throw Failure.systemCall("waitpid", errno)
            }
            if Task.isCancelled || clock.now >= deadline {
                termination = Task.isCancelled ? .cancelled : .timedOut
                try stop(pid, reaped: &reaped)
                break
            }
            // Cancellation wakes this sleep; the next loop stops the owned child.
            try? await Task.sleep(for: .milliseconds(10))
        }
        try output.drain()
        try errors.drain()
        return Result(termination: termination, stdout: output.data, stderr: errors.data,
                      outputTruncated: output.truncated || errors.truncated)
    }

    private static func reapAfterFailure(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    private static func validate(
        _ executable: String, _ arguments: [String], _ environment: [String: String],
        timeout: TimeInterval, outputLimit: Int
    ) throws {
        guard timeout.isFinite, timeout > 0, outputLimit >= 0,
              executable.hasPrefix("/"), !([executable] + arguments).contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.contains("=") || ($0.key + $0.value).contains("\0") })
        else { throw Failure.invalidConfiguration }
    }

    private static func spawn(
        _ executable: String, _ arguments: [String], _ environment: [String: String],
        output: OutputPipe, errors: OutputPipe
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions), "file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin")
        try checked(posix_spawn_file_actions_adddup2(&actions, output.writer, STDOUT_FILENO), "stdout")
        try checked(posix_spawn_file_actions_adddup2(&actions, errors.writer, STDERR_FILENO), "stderr")
        for descriptor in [output.reader, output.writer, errors.reader, errors.writer] {
            try checked(posix_spawn_file_actions_addclose(&actions, descriptor), "close pipe")
        }
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes), "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setpgroup(&attributes, 0), "process group")
        var mask = sigset_t()
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask), "signal mask")
        for signal in [SIGTERM, SIGINT, SIGQUIT, SIGPIPE] {
            sigaddset(&mask, signal)
        }
        try checked(posix_spawnattr_setsigdefault(&attributes, &mask), "signal defaults")
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        try checked(posix_spawnattr_setflags(&attributes, flags), "spawn flags")
        let strings = [executable] + arguments
        var argv = strings.map { strdup($0) }
        var envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard !argv.contains(where: { $0 == nil }), !envp.contains(where: { $0 == nil }) else {
            throw Failure.systemCall("arguments", ENOMEM)
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp), "spawn")
        return pid
    }

    private static func checked(_ code: Int32, _ operation: String) throws {
        if code != 0 {
            throw Failure.systemCall(operation, code)
        }
    }

    private static func decode(_ status: Int32) -> Termination {
        // Darwin's wait macros are not imported into Swift.
        let signal = status & 0x7F
        return signal == 0 ? .exited((status >> 8) & 0xFF) : .signalled(signal)
    }

    private static func stop(_ pid: pid_t, reaped: inout Bool) throws {
        kill(-pid, SIGTERM)
        // Do not reap during the grace period: the PID must remain reserved
        // until the final group signal has been sent, even if its leader exits.
        usleep(200_000)
        kill(-pid, SIGKILL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            var status: Int32 = 0
            let observed = waitpid(pid, &status, WNOHANG)
            if observed == pid {
                reaped = true; return
            }
            if observed == -1, errno == ECHILD {
                reaped = true
                throw Failure.terminationUnconfirmed
            }
            usleep(10000)
        }
        throw Failure.terminationUnconfirmed
    }

    private struct OutputPipe {
        var reader: Int32
        var writer: Int32
        let limit: Int
        var data = Data()
        var truncated = false

        init(limit: Int) throws {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw Failure.systemCall("pipe", errno) }
            reader = descriptors[0]
            writer = descriptors[1]
            self.limit = limit
            guard fcntl(reader, F_SETFL, O_NONBLOCK) != -1 else {
                let code = errno
                Darwin.close(reader)
                Darwin.close(writer)
                throw Failure.systemCall("pipe flags", code)
            }
        }

        mutating func closeWriter() {
            if writer >= 0 {
                Darwin.close(writer); writer = -1
            }
        }

        mutating func close() {
            if reader >= 0 {
                Darwin.close(reader); reader = -1
            }
            closeWriter()
        }

        mutating func drain() throws {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            // Fairness between streams and a chance to check the deadline,
            // even when a child writes continuously.
            for _ in 0 ..< 64 {
                let count = read(reader, &buffer, buffer.count)
                if count == 0 {
                    return
                }
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN {
                        return
                    }
                    throw Failure.systemCall("read output", errno)
                }
                let retained = min(count, max(0, limit - data.count))
                data.append(contentsOf: buffer.prefix(retained))
                truncated = truncated || retained < count
            }
        }
    }
}
