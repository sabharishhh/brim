import XCTest
import Foundation
@testable import BrimCore

final class StorageAccountantTests: XCTestCase {
    func testStorageAccountingWithoutShellout() async throws {
        let accountant = StorageAccountant()
        
        let emptyResult = await accountant.account(for: [])
        XCTAssertEqual(emptyResult.logical, 0)
        XCTAssertEqual(emptyResult.reclaimable, 0)
        XCTAssertEqual(emptyResult.pinned, 0)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let file1 = tempDir.appendingPathComponent("file1.bin")
        let file2 = tempDir.appendingPathComponent("file2.bin")
        
        try Data(count: 1024).write(to: file1)
        try Data(count: 2048).write(to: file2)
        
        let item1 = FootprintItem(
            evidence: Evidence(url: file1, tier: .A, mechanism: "test", humanSentence: "test"),
            sizeBytes: 1024,
            capability: .ok
        )
        let item2 = FootprintItem(
            evidence: Evidence(url: file2, tier: .A, mechanism: "test", humanSentence: "test"),
            sizeBytes: 2048,
            capability: .ok
        )
        
        let result = await accountant.account(for: [item1, item2])
        XCTAssertEqual(result.logical, 3072)
        XCTAssertEqual(result.reclaimable, 3072)
        XCTAssertEqual(result.pinned, 0, "Should not fabricate snapshot pinned bytes without verified extent evidence")
    }
}
