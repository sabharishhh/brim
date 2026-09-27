@testable import BrimCore
@testable import BrimScan
import XCTest

final class EvidenceEngineTests: XCTestCase {
    struct MockSource1: EvidenceSource {
        func evidence(for _: Identity, in _: FileSystemRoot) async throws -> [Evidence] {
            [
                Evidence(url: URL(fileURLWithPath: "/tmp/A"), tier: .B, mechanism: "M1", humanSentence: "H1"),
                Evidence(url: URL(fileURLWithPath: "/tmp/B"), tier: .C, mechanism: "M1", humanSentence: "H1")
            ]
        }
    }

    struct MockSource2: EvidenceSource {
        func evidence(for _: Identity, in _: FileSystemRoot) async throws -> [Evidence] {
            [
                // Upgrades tier for A
                Evidence(url: URL(fileURLWithPath: "/tmp/A"), tier: .S, mechanism: "M2", humanSentence: "H2"),
                // New evidence
                Evidence(url: URL(fileURLWithPath: "/tmp/C"), tier: .A, mechanism: "M2", humanSentence: "H2")
            ]
        }
    }

    func testEngineAggregationAndDeduplication() async throws {
        let engine = EvidenceEngine(sources: [MockSource1(), MockSource2()])
        let identity = Identity(bundleID: "com.test", name: "Test")
        let root = FileSystemRoot()

        let app = try await engine.discover(identity: identity, in: root)

        XCTAssertEqual(app.bundleID, "com.test")
        XCTAssertEqual(app.engineVersion, EvidenceEngineRevision)
        XCTAssertEqual(app.evidence.count, 3)

        // Ensure deterministic sorting by path
        XCTAssertEqual(app.evidence[0].url.path, "/tmp/A")
        XCTAssertEqual(app.evidence[1].url.path, "/tmp/B")
        XCTAssertEqual(app.evidence[2].url.path, "/tmp/C")

        // Ensure tier conflict resolution took the strongest (S > B)
        XCTAssertEqual(app.evidence[0].tier, .S)
        XCTAssertEqual(app.evidence[0].mechanism, "M2")
    }

    private actor Probe {
        var active = 0
        var peak = 0
        var started = 0
        func enter() {
            active += 1
            started += 1
            peak = max(peak, active)
        }

        func leave() {
            active -= 1
        }
    }

    private struct DelayedSource: EvidenceSource {
        let index: Int
        let probe: Probe
        func evidence(for _: Identity, in _: FileSystemRoot) async throws -> [Evidence] {
            await probe.enter()
            do {
                try await Task.sleep(for: .milliseconds(index == 0 ? 80 : 10))
            } catch {
                await probe.leave()
                throw error
            }
            await probe.leave()
            return [Evidence(url: URL(fileURLWithPath: "/tmp/brim-source-order"), tier: .B,
                             mechanism: "source-\(index)", humanSentence: "Recorded match")]
        }
    }

    func testParallelSourcesAreBoundedAndTiesKeepSourceOrder() async throws {
        let probe = Probe()
        let engine = EvidenceEngine(sources: (0 ..< 12).map { DelayedSource(index: $0, probe: probe) })
        let result = try await engine.discover(identity: Identity(bundleID: nil, name: "Test"),
                                               in: FileSystemRoot())
        let peak = await probe.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(result.evidence.first?.mechanism, "source-0")
    }

    func testCancelledDiscoveryDoesNotStartMoreSourcesOrReturnPartialSuccess() async {
        let probe = Probe()
        let engine = EvidenceEngine(sources: (0 ..< 100).map { DelayedSource(index: $0, probe: probe) })
        let task = Task {
            try await engine.discover(identity: Identity(bundleID: nil, name: "Test"), in: FileSystemRoot())
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a complete footprint")
        } catch { XCTAssertTrue(error is CancellationError) }
        let started = await probe.started
        XCTAssertLessThanOrEqual(started, 4)
    }
}
