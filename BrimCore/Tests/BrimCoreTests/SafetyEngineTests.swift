import XCTest
@testable import BrimCore
import Foundation

final class SafetyEngineTests: XCTestCase {
    func testSafetyEngineEvaluation() async {
        let rootURL = URL(fileURLWithPath: "/var/folders/xyz/root")
        let root = FileSystemRoot(rootURL: rootURL)
        let checker = SafetyChecker(root: root, brimAppURL: rootURL.appendingPathComponent("Brim.app"))
        let vetoEngine = TierSVetoEngine(root: root)
        let engine = SafetyEngine(safetyChecker: checker, vetoEngine: vetoEngine)
        
        let identity = Identity(name: "Test")
        let items: [FootprintItem] = [
            FootprintItem(
                evidence: Evidence(url: rootURL.appendingPathComponent("System/Library/CoreServices"), tier: .A, mechanism: "test", humanSentence: "test"),
                sizeBytes: 100,
                capability: .ok
            ),
            FootprintItem(
                evidence: Evidence(url: rootURL.appendingPathComponent("Library/Application Support/Test"), tier: .S, mechanism: "test", humanSentence: "test"),
                sizeBytes: 100,
                capability: .ok
            ),
            FootprintItem(
                evidence: Evidence(url: rootURL.appendingPathComponent("Library/Preferences/Test.plist"), tier: .B, mechanism: "test", humanSentence: "test"),
                sizeBytes: 100,
                capability: .ok
            ),
            FootprintItem(
                evidence: Evidence(url: rootURL.appendingPathComponent("Library/Caches/Test"), tier: .C, mechanism: "test", humanSentence: "test"),
                sizeBytes: 100,
                capability: .ok
            )
        ]
        
        let footprint = Footprint(identity: identity, items: items)
        let evaluated = await engine.evaluate(footprint: footprint)
        
        XCTAssertEqual(evaluated.items.count, 4)
        
        // 0: System -> Excluded by checker
        guard case .excluded(let reasonSystem) = evaluated.items[0].selection else {
            XCTFail("Expected excluded")
            return
        }
        XCTAssertTrue(reasonSystem.contains("strictly protected"))
        XCTAssertEqual(evaluated.items[0].costOfError, .high)
        
        // 1: Tier S -> Excluded by engine default
        guard case .excluded(let reasonS) = evaluated.items[1].selection else {
            XCTFail("Expected excluded")
            return
        }
        XCTAssertTrue(reasonS.contains("Shared/System tier evidence is excluded until M3"))
        
        // 2: Tier B -> Selected
        XCTAssertEqual(evaluated.items[2].selection, .selected)
        XCTAssertEqual(evaluated.items[2].costOfError, .medium)
        
        // 3: Tier C -> Unselected, but cost of error should be low because it's a Cache
        XCTAssertEqual(evaluated.items[3].selection, .unselected)
        XCTAssertEqual(evaluated.items[3].costOfError, .low)
    }
}
