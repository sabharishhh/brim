import BrimCore
import Foundation
import Testing

struct PreviewCacheTests {
    @Test func concurrentWaitersShareOneReadAndCancellingOneDoesNotCancelAnother() async throws {
        let cache = PreviewCache<String, Int>(capacity: 2, lifetime: 120)
        let gate = PreviewGate()
        let first = Task { try await cache.value(for: "app") { try await gate.read() } }
        try await gate.waitForRead()
        let second = Task { try await cache.value(for: "app") { try await gate.read() } }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        await gate.release(7)
        #expect(try await second.value == 7)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await gate.count == 1)
        #expect(await cache.cached("app") == 7)
    }

    @Test func invalidatedReadCannotReplaceOrReturnOlderEvidence() async throws {
        let cache = PreviewCache<String, Int>(capacity: 2, lifetime: 120)
        let gate = PreviewGate()
        let old = Task { try await cache.value(for: "app") { try await gate.read() } }
        try await gate.waitForRead()
        await cache.invalidate()
        #expect(try await cache.value(for: "app") { 2 } == 2)
        await gate.release(1)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await cache.cached("app") == 2)
    }

    @Test func cacheExpiresAndEvictsTheLeastRecentlyUsedEntry() async throws {
        let cache = PreviewCache<String, Int>(capacity: 2, lifetime: 120)
        _ = try await cache.value(for: "a") { 1 }
        _ = try await cache.value(for: "b") { 2 }
        #expect(await cache.cached("a") == 1)
        _ = try await cache.value(for: "c") { 3 }
        #expect(await cache.cached("b") == nil)
        #expect(await cache.cached("a", now: .distantFuture) == nil)
        #expect(try await cache.value(for: "a") { 4 } == 4)
    }

    @Test func failuresAreRetriedRatherThanCachedAsEmptyResults() async throws {
        let cache = PreviewCache<String, Int>(capacity: 2, lifetime: 120)
        await #expect(throws: CocoaError.self) {
            _ = try await cache.value(for: "app") { throw CocoaError(.fileReadNoPermission) }
        }
        #expect(try await cache.value(for: "app") { 3 } == 3)
    }
}

private actor PreviewGate {
    private(set) var count = 0
    private var continuations: [CheckedContinuation<Int, Error>] = []

    func read() async throws -> Int {
        count += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func release(_ value: Int) {
        continuations.forEach { $0.resume(returning: value) }
        continuations = []
    }

    func waitForRead() async throws {
        for _ in 0 ..< 200 {
            if count > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The shared read did not start.")
        throw CancellationError()
    }
}
