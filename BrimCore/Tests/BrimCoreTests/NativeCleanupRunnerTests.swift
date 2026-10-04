@testable import BrimOps
import Foundation
import Synchronization
import Testing

/// Controlled subprocesses only. No developer cache or catalogue cleanup runs.
struct NativeCleanupRunnerTests {
    @Test func leaderExitDoesNotLeaveAnOwnedChildWorking() async throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["20"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let started = Mutex<pid_t?>(nil)
        let result = try await NativeCommandRunner.run(executable: "/bin/sh", arguments: [
            "-c", "/bin/sleep 20 & exit 0"
        ], environment: ToolCleanup.environment(), timeout: 0.1,
        onSpawn: { pid in started.withLock { $0 = pid } })
        #expect(result.termination == .timedOut)
        #expect(unrelated.isRunning)
        let pid = try #require(started.withLock { $0 })
        await expectGroupGone(pid)
    }

    @Test func successfulLeaderWaitsForItsShortLivedChild() async throws {
        let clock = ContinuousClock()
        let began = clock.now
        let result = try await NativeCommandRunner.run(executable: "/bin/sh", arguments: [
            "-c", "/bin/sleep 0.2 & exit 0"
        ], environment: ToolCleanup.environment(), timeout: 2)
        #expect(result.termination == .exited(0))
        #expect(clock.now - began >= .milliseconds(150))
    }

    @Test func cancellationStillStopsChildrenAfterTheirLeaderExits() async throws {
        let started = Mutex<pid_t?>(nil)
        let task = Task {
            try await NativeCommandRunner.run(executable: "/bin/sh", arguments: [
                "-c", "/bin/sleep 20 & exit 0"
            ], environment: ToolCleanup.environment(), timeout: 5,
            onSpawn: { pid in started.withLock { $0 = pid } })
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var leaderExited = false
        while clock.now < deadline {
            if let pid = started.withLock({ $0 }) {
                var information = siginfo_t()
                _ = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if information.si_pid == pid {
                    leaderExited = true; break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(leaderExited)
        task.cancel()
        let result = try await task.value
        #expect(result.termination == .cancelled)
        let pid = try #require(started.withLock { $0 })
        await expectGroupGone(pid)
    }

    @Test func outputBeyondPipeCapacityCompletes() async throws {
        let script = #"BEGIN { for (i = 0; i < 20000; i++) { print "brim runner stdout";"#
            + #" print "brim runner stderr" > "/dev/stderr" } }"#
        let status = try await ToolCleanup.execute("/usr/bin/awk", [script])
        #expect(status == 0)
    }

    @Test func largeOutputRetainsOnlyBoundedDiagnostics() async throws {
        let result = try await NativeCommandRunner.run(executable: "/usr/bin/awk", arguments: [
            #"BEGIN { for (i = 0; i < 20000; i++) { print "stdout data"; print "stderr data" > "/dev/stderr" } }"#
        ], environment: ToolCleanup.environment(), outputLimit: 128)
        #expect(result.termination == .exited(0))
        #expect(result.stdout.count == 128)
        #expect(result.stderr.count == 128)
        #expect(result.outputTruncated)
    }

    @Test func timeoutStopsItsWholeGroupWithoutStoppingAnotherSleep() async throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["20"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let started = Mutex<pid_t?>(nil)
        let clock = ContinuousClock()
        let began = clock.now
        let result = try await NativeCommandRunner.run(executable: "/bin/sh", arguments: [
            "-c", "trap '' TERM; sleep 20 & wait"
        ], environment: ToolCleanup.environment(), timeout: 0.1, onSpawn: { pid in started.withLock { $0 = pid } })
        #expect(result.termination == .timedOut)
        #expect(clock.now - began < .seconds(3))
        #expect(unrelated.isRunning)
        let pid = try #require(started.withLock { $0 })
        #expect(waitpid(pid, nil, WNOHANG) == -1 && errno == ECHILD, "The direct child must be reaped.")
        await expectGroupGone(pid)
    }

    @Test func cancellationStopsAnAlreadyStartedChild() async throws {
        let started = Mutex<pid_t?>(nil)
        let task = Task {
            try await NativeCommandRunner.run(executable: "/bin/sleep", arguments: ["20"],
                                              environment: ToolCleanup.environment(),
                                              onSpawn: { pid in started.withLock { $0 = pid } })
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while started.withLock({ $0 }) == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let result = try await task.value
        #expect(result.termination == .cancelled)
        let pid = try #require(started.withLock { $0 })
        await expectGroupGone(pid)
    }

    @Test func spawnNonzeroAndSignalFailuresRemainDistinct() async throws {
        do {
            _ = try await NativeCommandRunner.run(executable: "/fixture/missing", arguments: [], environment: [:])
            Issue.record("A missing executable was accepted.")
        } catch {
            #expect(error as? NativeCommandRunner.Failure == .systemCall("spawn", ENOENT))
        }
        let nonzero = try await NativeCommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "exit 23"],
            environment: [:]
        )
        #expect(nonzero.termination == .exited(23))
        let signalled = try await NativeCommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "kill -TERM $$"],
            environment: [:]
        )
        #expect(signalled.termination == .signalled(SIGTERM))
    }

    @Test func catalogueFailuresRemainSpecificAndUnknownIdsNeverInvokeARunner() async throws {
        let invoked = Mutex(false)
        do {
            try await ToolCleanup.run(id: "unknown", runner: { _, _ in invoked.withLock { $0 = true }; return 0 })
            Issue.record("An unknown cleanup was accepted.")
        } catch {
            #expect(error as? ToolCleanup.CleanupError == .unknownCleanup("unknown"))
        }
        #expect(!invoked.withLock { $0 })
        do {
            try await ToolCleanup.run(id: "npm.cache", runner: { _, _ in 127 })
            Issue.record("A missing tool was accepted.")
        } catch {
            #expect((error as? ToolCleanup.CleanupError)?.outcomeCode == "cleanup_missing")
        }
        do {
            try await ToolCleanup.run(id: "npm.cache", runner: { _, _ in 23 })
            Issue.record("A nonzero result was accepted.")
        } catch {
            #expect(error as? ToolCleanup.CleanupError == .failed("npm cache clean --force", code: 23))
        }
    }

    private func expectGroupGone(_ pid: pid_t) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while kill(-pid, 0) == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(-pid, 0) == -1 && errno == ESRCH, "No child in the owned group may keep running.")
    }
}
