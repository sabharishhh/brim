import XCTest
@testable import BrimScan
@testable import BrimCore
@testable import BrimFixtures
import Foundation

final class BrimScannerTests: XCTestCase {
    
    func testScannerOnFixtureTree() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gen = FixtureTreeGenerator(rootURL: tempRoot)
        defer { gen.destroy() }
        
        try gen.generate()
        
        let scanner = BrimScanner()
        let stream = scanner.enumerate(url: tempRoot)
        
        var filesFound = 0
        var foundSymlink = false
        
        for try await entry in stream {
            filesFound += 1
            if entry.isSymlink {
                foundSymlink = true
            }
        }
        
        XCTAssertTrue(filesFound > 0, "Scanner should find files in the fixture tree")
        XCTAssertTrue(foundSymlink, "Scanner should detect the symlink without traversing it")
    }
}
