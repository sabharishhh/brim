import BrimCore
@testable import BrimUI
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces

/// The queue in front of the on-device model, run against a stand-in so
/// every path is exercised without one.
struct IntelligenceEngineTests {
    private func cacheFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("brim-intelligence-\(UUID().uuidString).json")
    }

    private func engine(
        _ reader: StandInReader, file: URL? = nil, timeout: Duration = .seconds(5)
    ) -> IntelligenceEngine {
        IntelligenceEngine(reader: reader, cacheFile: file, timeout: timeout, retryDelays: [.milliseconds(1)])
    }

    @Test func `a release is read once, even after Brim opens again`() async {
        let file = cacheFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = StandInReader()
        let first = engine(reader, file: file)
        _ = await first.highlights(notes: "Long notes", version: "2.0")
        _ = await first.highlights(notes: "Long notes", version: "2.0")
        let reopened = engine(reader, file: file)
        guard case let .done(reading) = await reopened.highlights(notes: "Long notes", version: "2.0") else {
            Issue.record("The kept answer should be used")
            return
        }
        #expect(reading.highlights == ["Adds a thing"])
        #expect(await reader.calls == 1)
    }

    @Test func `the same question asked twice at once is asked once`() async {
        let reader = StandInReader(delay: .milliseconds(100))
        let engine = engine(reader)
        async let first = engine.highlights(notes: "Notes", version: "1")
        async let second = engine.highlights(notes: "Notes", version: "1")
        _ = await (first, second)
        #expect(await reader.calls == 1)
    }

    @Test func `a refusal is remembered, a timeout is not`() async {
        let refusing = StandInReader(failure: .refused)
        let refused = engine(refusing)
        _ = await refused.highlights(notes: "Notes", version: "1")
        _ = await refused.highlights(notes: "Notes", version: "1")
        #expect(await refusing.calls == 1)

        let slow = StandInReader(delay: .seconds(2))
        let timed = engine(slow, timeout: .milliseconds(50))
        guard case .failed = await timed.highlights(notes: "Notes", version: "1") else {
            Issue.record("A request past its time should fail")
            return
        }
        _ = await timed.highlights(notes: "Notes", version: "1")
        #expect(await slow.calls == 2)
    }

    @Test func `a rate limit is waited out and asked again`() async {
        let reader = StandInReader(failure: .rateLimited, failures: 1)
        guard case .done = await engine(reader).highlights(notes: "Notes", version: "1") else {
            Issue.record("A rate limit should be retried")
            return
        }
        #expect(await reader.calls == 2)
    }

    @Test func `nothing is asked when the model is not there`() async {
        let reader = StandInReader(availability: .appleIntelligenceOff)
        guard case .unavailable = await engine(reader).highlights(notes: "Notes", version: "1") else {
            Issue.record("An unavailable model should say so")
            return
        }
        #expect(await reader.calls == 0)
    }

    /// Short notes and a CVE need no model at all.
    @MainActor
    @Test func `short notes are shown as written without the model`() async {
        let model = WhatsNewModel()
        let notes = "Fixes a crash when exporting. Addresses CVE-2026-1234."
        let short = AppUpdate(bundleID: "com.example.demo", name: "Demo",
                              appURL: URL(fileURLWithPath: "/Applications/Demo.app"),
                              installedVersion: "1.0", latestVersion: "1.1",
                              origin: .sparkle(feed: "https://example.com/appcast.xml"), route: .replace,
                              releaseNotes: notes)
        await model.read(short, engine: nil)
        #expect(model.state(for: short) == .ready(WhatsNew(
            highlights: [notes], fixesSecurity: true, isGenerated: false
        )))
    }
}

private actor StandInReader: LanguageReader {
    private(set) var calls = 0
    private let delay: Duration
    private let failure: ModelFailure?
    private var failuresLeft: Int
    private let state: ModelAvailability

    init(delay: Duration = .zero, failure: ModelFailure? = nil, failures: Int = .max,
         availability: ModelAvailability = .ready) {
        self.delay = delay
        self.failure = failure
        failuresLeft = failures
        state = availability
    }

    func availability() async -> ModelAvailability {
        state
    }

    func prewarm() async {}

    func highlights(notes _: String, version _: String) async throws -> ReleaseHighlights {
        calls += 1
        try await Task.sleep(for: delay)
        if let failure, failuresLeft > 0 {
            failuresLeft -= 1
            throw failure
        }
        return ReleaseHighlights(highlights: ["Adds a thing"], fixesSecurity: false)
    }

    func describe(lines: [Int], of _: String) async throws -> [Int: String] {
        calls += 1
        return Dictionary(uniqueKeysWithValues: lines.map { ($0, "Does a thing") })
    }
}
