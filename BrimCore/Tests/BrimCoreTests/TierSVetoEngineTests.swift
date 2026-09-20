import XCTest
@testable import BrimCore

final class TierSVetoEngineTests: XCTestCase {
    func testVetoEngineExcludesSharedFiles() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = FileSystemRoot(rootURL: tempRoot)
        let vetoEngine = TierSVetoEngine(root: root)
        
        let identity = Identity(bundleID: "com.test.app", name: "TestApp")
        
        let safeURL = tempRoot.appendingPathComponent("SafeFile")
        let sharedURL = tempRoot.appendingPathComponent("SharedVendorFolder")
        
        let items = [
            EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(url: safeURL, tier: .A, mechanism: "Test", humanSentence: "Safe"), sizeBytes: 100, capability: .ok), selection: .selected, costOfError: .low),
            EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(url: sharedURL, tier: .A, mechanism: "Test", humanSentence: "Shared"), sizeBytes: 100, capability: .ok), selection: .selected, costOfError: .low)
        ]
        
        let footprint = EvaluatedFootprint(identity: identity, items: items)
        let vetted = await vetoEngine.applyVeto(to: footprint)
        
        XCTAssertEqual(vetted.items.count, 2)
        XCTAssertEqual(vetted.items[0].selection, .selected)
        
        if case let .excluded(reason) = vetted.items[1].selection {
            XCTAssertTrue(reason.contains("claimed by OtherApp"), "Expected exclusion reason to contain claimant name")
        } else {
            XCTFail("Expected shared file to be excluded")
        }
    }
}
