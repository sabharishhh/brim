import XCTest
import Foundation
@testable import BrimFixtures

final class FixtureTests: XCTestCase {
    
    func testTreeGenerationIsDeterministic() throws {
        let root1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        defer {
            try? FileManager.default.removeItem(at: root1)
            try? FileManager.default.removeItem(at: root2)
        }
        
        let gen1 = FixtureTreeGenerator(rootURL: root1)
        try gen1.generate()
        
        let gen2 = FixtureTreeGenerator(rootURL: root2)
        try gen2.generate()
        
        // Ensure both directories have the same number of items and matching paths
        let enum1 = FileManager.default.enumerator(at: root1, includingPropertiesForKeys: nil)!
        let enum2 = FileManager.default.enumerator(at: root2, includingPropertiesForKeys: nil)!
        
        var paths1 = [String]()
        for case let url as URL in enum1 {
            let relative = url.path.replacingOccurrences(of: root1.path, with: "")
            paths1.append(relative)
        }
        
        var paths2 = [String]()
        for case let url as URL in enum2 {
            let relative = url.path.replacingOccurrences(of: root2.path, with: "")
            paths2.append(relative)
        }
        
        XCTAssertEqual(paths1.sorted(), paths2.sorted())
    }
    
    func testManifestRoundTrips() throws {
        guard let url = Bundle.module.url(forResource: "sandboxed", withExtension: "json", subdirectory: "Manifests") else {
            XCTFail("Missing sandboxed.json")
            return
        }
        
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ExpectedEvidenceManifest.self, from: data)
        XCTAssertEqual(manifest.bundleID, "com.brim.sandboxed")
        XCTAssertEqual(manifest.expectedItems.count, 3)
        
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ExpectedEvidenceManifest.self, from: encoded)
        
        XCTAssertEqual(manifest, decoded)
    }
}
