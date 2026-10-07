import Foundation

// swiftformat:disable wrapMultilineStatementBraces

/// Every request Brim makes of the on-device model goes through here.
///
/// - One at a time, in the order asked. The model serves one request at a
///   time anyway; queueing here keeps each answer's wait predictable and
///   lets a request nobody is waiting for leave before it runs.
/// - The same question asked twice while it is running is asked once.
/// - Answers are kept (`IntelligenceCache`), so each release or script is
///   read once.
/// - A rate limit is retried after a pause, a refusal is remembered for a
///   day, and a request that runs past its time is given up and not kept.
public actor IntelligenceEngine {
    public enum Outcome<Value: Sendable>: Sendable {
        case done(Value)
        /// The model cannot be asked; nothing was queued.
        case unavailable
        case failed
    }

    /// What a queued request came to, before decoding.
    private enum Result: Sendable {
        case done(Data)
        case unavailable
        case failed
    }

    private let reader: any LanguageReader
    private var cache: IntelligenceCache
    private let timeout: Duration
    private let retryDelays: [Duration]
    private var running: [String: Task<Result, Never>] = [:]
    /// Who is still waiting for each request; a request with nobody
    /// waiting by the time its turn comes is skipped.
    private var waiting: [String: Set<UUID>] = [:]
    /// The last request queued; each new one starts after it.
    private var tail: Task<Void, Never>?

    public init(reader: any LanguageReader, cacheFile: URL?, timeout: Duration = .seconds(20),
                retryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]) {
        self.reader = reader
        cache = IntelligenceCache(file: cacheFile)
        self.timeout = timeout
        self.retryDelays = retryDelays
    }

    public func availability() async -> ModelAvailability {
        await reader.availability()
    }

    public func prewarm() async {
        guard await reader.availability() == .ready else { return }
        await reader.prewarm()
    }

    // MARK: - Questions

    public func highlights(notes: String, version: String) async -> Outcome<ReleaseHighlights> {
        let key = IntelligenceCache.key("release-highlights", version: 1, notes, version)
        return await ask(key) { reader in
            try await reader.highlights(notes: notes, version: version)
        }
    }

    public func describe(lines: [Int], of script: String) async -> Outcome<[Int: String]> {
        let numbers = lines.map(String.init).joined(separator: ",")
        let key = IntelligenceCache.key("script-lines", version: 1, script, numbers)
        return await ask(key) { reader in
            try await reader.describe(lines: lines, of: script)
        }
    }

    // MARK: - The queue

    private func ask<Value: Codable & Sendable>(
        _ key: String, _ work: @escaping @Sendable (any LanguageReader) async throws -> Value
    ) async -> Outcome<Value> {
        if let data = cache.value(for: key), let value = try? JSONDecoder().decode(Value.self, from: data) {
            return .done(value)
        }
        guard !cache.refused(key) else { return .failed }
        let token = UUID()
        waiting[key, default: []].insert(token)
        let request = running[key] ?? enqueue(key) { reader in
            try await JSONEncoder().encode(work(reader))
        }
        let result = await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            Task { await self.stopWaiting(key, token) }
        }
        stopWaiting(key, token)
        switch result {
        case let .done(data):
            guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return .failed }
            return .done(value)
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }

    private func enqueue(
        _ key: String, _ work: @escaping @Sendable (any LanguageReader) async throws -> Data
    ) -> Task<Result, Never> {
        let previous = tail
        let request = Task {
            await previous?.value
            return await self.perform(key, work)
        }
        running[key] = request
        tail = Task { _ = await request.value }
        return request
    }

    private func stopWaiting(_ key: String, _ token: UUID) {
        waiting[key]?.remove(token)
        if waiting[key]?.isEmpty == true {
            waiting[key] = nil
        }
    }

    private func perform(_ key: String, _ work: @escaping @Sendable (any LanguageReader) async throws -> Data)
        async -> Result {
        defer { running[key] = nil }
        guard waiting[key] != nil else { return .failed }
        guard await reader.availability() == .ready else { return .unavailable }
        let reader = reader
        for attempt in 0 ... retryDelays.count {
            do {
                let data = try await Self.within(timeout) { try await work(reader) }
                cache.store(data, for: key)
                return .done(data)
            } catch ModelFailure.rateLimited where attempt < retryDelays.count {
                try? await Task.sleep(for: retryDelays[attempt])
            } catch ModelFailure.refused, ModelFailure.unreadable, ModelFailure.tooLong {
                cache.markRefused(key)
                return .failed
            } catch ModelFailure.unavailable {
                return .unavailable
            } catch {
                return .failed
            }
        }
        return .failed
    }

    /// Runs `work`, or throws `timedOut` once `limit` has passed, cancelling
    /// whichever is left.
    private static func within(_ limit: Duration, _ work: @escaping @Sendable () async throws -> Data)
        async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let data = first else { throw ModelFailure.timedOut }
            return data
        }
    }
}
