import XCTest
import Foundation
import Darwin
@testable import BrimScan

final class DuplicateScannerTests: XCTestCase {
    func testAPFSCloneAndHardlinkRecoverableAccounting() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testData = Data(repeating: 0x5A, count: 8192)
        
        let fileA = tempDir.appendingPathComponent("fileA.bin")
        let fileB = tempDir.appendingPathComponent("fileB.bin") // clone of A
        let fileC = tempDir.appendingPathComponent("fileC.bin") // independent duplicate of A
        
        try testData.write(to: fileA)
        let cloneRet = clonefile(fileA.path, fileB.path, 0)
        guard cloneRet == 0 else {
            print("Filesystem does not support clonefile (not APFS), skipping clone test")
            return
        }
        try testData.write(to: fileC)
        
        let scanner = DuplicateScanner()
        let results = try await scanner.scan(directory: tempDir)
        
        XCTAssertEqual(results.count, 1)
        guard let group = results.first else { return }
        
        XCTAssertEqual(group.paths.count, 3)
        XCTAssertEqual(group.size, 8192)
        // fileA and fileB share storage via APFS clone. fileC is an independent copy.
        // Therefore, exactly 1 copy (8192 bytes) is recoverable, NOT 2 copies (16384 bytes)!
        XCTAssertEqual(group.recoverableBytes, 8192, "APFS clone-linked pair should not be double-counted as recoverable savings")
    }
    
    func testClonedPairOnlyHasZeroRecoverableBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testData = Data(repeating: 0x42, count: 4096)
        
        let fileA = tempDir.appendingPathComponent("pairA.bin")
        let fileB = tempDir.appendingPathComponent("pairB.bin")
        
        try testData.write(to: fileA)
        let cloneRet = clonefile(fileA.path, fileB.path, 0)
        guard cloneRet == 0 else {
            return
        }
        
        let scanner = DuplicateScanner()
        let results = try await scanner.scan(directory: tempDir)
        
        XCTAssertEqual(results.count, 1)
        guard let group = results.first else { return }
        
        XCTAssertEqual(group.paths.count, 2)
        // Since both files are already clones sharing physical blocks, deleting one yields 0 net disk recovery
        XCTAssertEqual(group.recoverableBytes, 0, "Pair of pure APFS clones should report 0 recoverable bytes")
    }
}
