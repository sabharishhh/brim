import XCTest
@testable import BrimUI

/// The watcher is what makes the app notice the user emptying the Trash in
/// Finder. If it silently stops firing, the UI goes stale and nothing else
/// catches it, so the contract is pinned here against a real directory.
final class TrashWatcherTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Counts handler invocations across actor boundaries.
    private actor Counter {
        private(set) var count = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var awaited = 0

        func increment() {
            count += 1
            if count >= awaited, let c = continuation {
                continuation = nil
                c.resume()
            }
        }

        /// Waits until at least `target` calls have landed.
        func wait(for target: Int) async {
            awaited = target
            if count >= target { return }
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func testFiresWhenTheWatchedDirectoryLosesAnItem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let victim = dir.appendingPathComponent("item.txt")
        try "x".write(to: victim, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = TrashWatcher(url: dir, coalescingWindow: .milliseconds(50))
        await watcher.start { await counter.increment() }
        defer { Task { await watcher.stop() } }

        try FileManager.default.removeItem(at: victim)

        await withTimeout(seconds: 5) { await counter.wait(for: 1) }
        let count = await counter.count
        XCTAssertGreaterThanOrEqual(count, 1, "Removing an item should wake the watcher")
    }

    func testABurstOfChangesCoalescesIntoOneNotification() async throws {
        // Emptying the Trash removes many items at once. The UI wants the
        // settled state, not one refresh per file.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = (0..<25).map { dir.appendingPathComponent("item-\($0).txt") }
        for f in files { try "x".write(to: f, atomically: true, encoding: .utf8) }

        let counter = Counter()
        let watcher = TrashWatcher(url: dir, coalescingWindow: .milliseconds(200))
        await watcher.start { await counter.increment() }
        defer { Task { await watcher.stop() } }

        for f in files { try FileManager.default.removeItem(at: f) }

        await withTimeout(seconds: 5) { await counter.wait(for: 1) }
        try await Task.sleep(for: .milliseconds(600))

        let count = await counter.count
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertLessThanOrEqual(count, 3, "25 removals should coalesce, not fan out (got \(count))")
    }

    func testStopEndsNotifications() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = Counter()
        let watcher = TrashWatcher(url: dir, coalescingWindow: .milliseconds(50))
        await watcher.start { await counter.increment() }
        await watcher.stop()

        let f = dir.appendingPathComponent("after-stop.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: f)
        try await Task.sleep(for: .milliseconds(400))

        let count = await counter.count
        XCTAssertEqual(count, 0, "A stopped watcher must not keep firing")
    }

    func testStartingTwiceDoesNotStackWatchers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = Counter()
        let watcher = TrashWatcher(url: dir, coalescingWindow: .milliseconds(100))
        await watcher.start { await counter.increment() }
        await watcher.start { await counter.increment() }
        defer { Task { await watcher.stop() } }

        let f = dir.appendingPathComponent("once.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: f)

        await withTimeout(seconds: 5) { await counter.wait(for: 1) }
        try await Task.sleep(for: .milliseconds(400))

        let count = await counter.count
        XCTAssertLessThanOrEqual(count, 2, "Restarting replaced the source rather than adding one (got \(count))")
    }

    func testAMissingDirectoryDoesNotCrashOrBlock() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watcher = TrashWatcher(url: missing, coalescingWindow: .milliseconds(50))
        await watcher.start { }
        await watcher.stop()
    }

    private func withTimeout(seconds: Double, _ body: @escaping @Sendable () async -> Void) async {
        let work = Task { await body() }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        await work.value
        timeout.cancel()
    }
}
