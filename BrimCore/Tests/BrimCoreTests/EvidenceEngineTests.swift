import XCTest
@testable import BrimScan
@testable import BrimCore

final class EvidenceEngineTests: XCTestCase {
    
    struct MockSource1: EvidenceSource {
        func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
            return [
                Evidence(url: URL(fileURLWithPath: "/tmp/A"), tier: .B, mechanism: "M1", humanSentence: "H1"),
                Evidence(url: URL(fileURLWithPath: "/tmp/B"), tier: .C, mechanism: "M1", humanSentence: "H1")
            ]
        }
    }
    
    struct MockSource2: EvidenceSource {
        func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
            return [
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
        XCTAssertEqual(app.engineVersion, "1.0.0")
        XCTAssertEqual(app.evidence.count, 3)
        
        // Ensure deterministic sorting by path
        XCTAssertEqual(app.evidence[0].url.path, "/tmp/A")
        XCTAssertEqual(app.evidence[1].url.path, "/tmp/B")
        XCTAssertEqual(app.evidence[2].url.path, "/tmp/C")
        
        // Ensure tier conflict resolution took the strongest (S > B)
        XCTAssertEqual(app.evidence[0].tier, .S)
        XCTAssertEqual(app.evidence[0].mechanism, "M2")
    }
}
