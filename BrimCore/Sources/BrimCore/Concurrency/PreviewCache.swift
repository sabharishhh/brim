import Foundation

/// Bounded, process-local previews. A shared read survives one cancelled
/// waiter, while invalidation prevents an older read from repopulating it.
/// Executions must use a fresh read rather than this presentation cache.
public actor PreviewCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let value: Value
        let created: Date
        var used: UInt64
    }

    private struct Pending {
        let id: UUID
        let task: Task<Value, Error>
    }

    private let capacity: Int
    private let lifetime: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0

    public init(capacity: Int, lifetime: TimeInterval) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    public func cached(_ key: Key, now: Date = Date()) -> Value? {
        guard var entry = entries[key], now.timeIntervalSince(entry.created) < lifetime else {
            entries[key] = nil
            return nil
        }
        clock &+= 1
        entry.used = clock
        entries[key] = entry
        return entry.value
    }

    public func value(for key: Key, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let value = cached(key) {
            return value
        }
        let asked = generation
        let read: Pending
        if let existing = pending[key] {
            read = existing
        } else {
            read = Pending(id: UUID(), task: Task { try await load() })
            pending[key] = read
        }
        do {
            let value = try await read.task.value
            guard asked == generation else { throw CancellationError() }
            if pending[key]?.id == read.id {
                pending[key] = nil
                clock &+= 1
                entries[key] = Entry(value: value, created: Date(), used: clock)
                while entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                    entries[oldest] = nil
                }
            }
            try Task.checkCancellation()
            return value
        } catch {
            if pending[key]?.id == read.id {
                pending[key] = nil
            }
            throw error
        }
    }

    public func invalidate() {
        generation &+= 1
        entries.removeAll()
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }
}
