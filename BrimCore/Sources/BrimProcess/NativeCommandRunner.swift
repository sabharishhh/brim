import Darwin
import Foundation

/// The child owns a new process group. Only that group is stopped, and
/// neither pipe can hold the child waiting for Brim to read it.
public enum NativeCommandRunner {
    public enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut
        case cancelled
    }

    public struct Result: Sendable {
        public let termination: Termination
        public let stdout: Data
        public let stderr: Data
        public let outputTruncated: Bool
    }

    public enum Failure: Error, Equatable {
        case systemCall(String, Int32)
        case invalidConfiguration
        case terminationUnconfirmed
    }

    @concurrent
    public static func run(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval = 120, outputLimit: Int = 64 * 1024,
        onSpawn: (@Sendable (pid_t) -> Void)? = nil, workingDirectory: String? = nil
    ) async throws -> Result {
        try validate(executable, arguments, environment, timeout: timeout, outputLimit: outputLimit)
        if Task.isCancelled {
            return Result(termination: .cancelled, stdout: Data(), stderr: Data(), outputTruncated: false)
        }
        var output = try OutputPipe(limit: outputLimit)
        defer { output.close() }
        var errors = try OutputPipe(limit: outputLimit)
        defer { errors.close() }
        let pid = try spawn(executable, arguments, environment, pipes: (output, errors),
                            workingDirectory: workingDirectory)
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
        var leaderTermination: Termination?
        while true {
            try output.drain()
            try errors.drain()
            if leaderTermination == nil {
                leaderTermination = try observeLeader(pid, reaped: &reaped)
            }
            if let leaderTermination, try !hasLiveDescendants(in: pid) {
                try reapLeader(pid, reaped: &reaped)
                termination = leaderTermination
                break
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
        pipes: (output: OutputPipe, errors: OutputPipe), workingDirectory: String?
    ) throws -> pid_t {
        let (output, errors) = pipes
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions), "file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let workingDirectory {
            guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0") else {
                throw Failure.invalidConfiguration
            }
            try checked(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory), "working directory")
        }
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
        guard code == 0 else { throw Failure.systemCall(operation, code) }
    }

    private static func observeLeader(_ pid: pid_t, reaped: inout Bool) throws -> Termination? {
        var information = siginfo_t()
        let status = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if status == -1 {
            if errno == EINTR {
                return nil
            }
            if errno == ECHILD {
                reaped = true
            }
            throw Failure.systemCall("waitid", errno)
        }
        guard information.si_pid == pid else { return nil }
        return information.si_code == CLD_EXITED
            ? .exited(information.si_status) : .signalled(information.si_status)
    }

    /// The leader stays waitable while this runs, reserving its PID and
    /// therefore the process group we are allowed to stop.
    private static func hasLiveDescendants(in group: pid_t) throws -> Bool {
        var members = [pid_t](repeating: 0, count: 4096)
        errno = 0
        let count = members.withUnsafeMutableBytes {
            proc_listpgrppids(group, $0.baseAddress, Int32($0.count))
        }
        guard count >= 0, count < members.count else { throw Failure.terminationUnconfirmed }
        if count == 0, errno != 0, errno != ESRCH {
            throw Failure.terminationUnconfirmed
        }
        for member in members.prefix(Int(count)) where member != group && member > 0 {
            var information = proc_bsdinfo()
            errno = 0
            let read = proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &information,
                                    Int32(MemoryLayout<proc_bsdinfo>.size))
            if read == 0, errno == ESRCH {
                continue
            }
            guard read == MemoryLayout<proc_bsdinfo>.size else { throw Failure.terminationUnconfirmed }
            if information.pbi_pgid == UInt32(group), information.pbi_status != SZOMB {
                return true
            }
        }
        return false
    }

    private static func reapLeader(_ pid: pid_t, reaped: inout Bool) throws {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        if result == pid {
            reaped = true
            return
        }
        if result == -1, errno == ECHILD {
            reaped = true
        }
        throw Failure.terminationUnconfirmed
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
            if try observeLeader(pid, reaped: &reaped) != nil, try !hasLiveDescendants(in: pid) {
                try reapLeader(pid, reaped: &reaped)
                return
            }
            kill(-pid, SIGKILL)
            usleep(10000)
        }
        throw Failure.terminationUnconfirmed
    }
}

private struct OutputPipe {
    var reader: Int32
    var writer: Int32
    let limit: Int
    var data = Data()
    var truncated = false

    init(limit: Int) throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw NativeCommandRunner.Failure.systemCall("pipe", errno) }
        reader = descriptors[0]
        writer = descriptors[1]
        self.limit = limit
        guard fcntl(reader, F_SETFL, O_NONBLOCK) != -1 else {
            let code = errno
            Darwin.close(reader)
            Darwin.close(writer)
            throw NativeCommandRunner.Failure.systemCall("pipe flags", code)
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
                throw NativeCommandRunner.Failure.systemCall("read output", errno)
            }
            let retained = min(count, max(0, limit - data.count))
            data.append(contentsOf: buffer.prefix(retained))
            truncated = truncated || retained < count
        }
    }
}
