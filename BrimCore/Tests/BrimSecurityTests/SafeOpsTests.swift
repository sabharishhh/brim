import XCTest
import Foundation
@testable import BrimCore
@testable import BrimOps

final class SafeOpsTests: XCTestCase {
    
    func testSymlinkSwapFails() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let targetDir = tempDir.appendingPathComponent("TargetDir")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        let targetFile = targetDir.appendingPathComponent("File.txt")
        try "test".write(to: targetFile, atomically: true, encoding: .utf8)
        
        // Fingerprint the file
        var statBuf = stat()
        stat(targetFile.path, &statBuf)
        let expectedDev = statBuf.st_dev
        let expectedIno = statBuf.st_ino
        
        // Perform a symlink swap: targetDir becomes a symlink to another directory
        try FileManager.default.removeItem(at: targetDir)
        let secretDir = tempDir.appendingPathComponent("Secret")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        
        let secretFile = secretDir.appendingPathComponent("File.txt")
        try "secret".write(to: secretFile, atomically: true, encoding: .utf8)
        
        try FileManager.default.createSymbolicLink(at: targetDir, withDestinationURL: secretDir)
        
        // Attempting to trash the file using SafeOps should fail because:
        // 1. O_NOFOLLOW on the parent (targetDir) will fail since targetDir is now a symlink.
        
        XCTAssertThrowsError(try SafeOps.trashItem(targetPath: targetFile.path, expectedDev: expectedDev, expectedIno: expectedIno)) { error in
            guard let safeError = error as? SafeOpsError else {
                XCTFail("Unexpected error type")
                return
            }
            if case .failedToOpenParent(_) = safeError {
                // Expected, since it's a symlink
            } else {
                XCTFail("Unexpected SafeOpsError: \(safeError)")
            }
        }
    }
    
    func testSafeRemoveItemAppearsNowhereOutsideBrimOps() throws {
        // Find all .swift files in the project
        let projectURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // BrimSecurityTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BrimCore
            .appendingPathComponent("Sources")
        
        let enumerator = FileManager.default.enumerator(at: projectURL, includingPropertiesForKeys: nil)
        
        var violations = [String]()
        
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            
            // Allow BrimOps to use removeItem (e.g. defer { try? fm.removeItem(at: volumeURL) })
            if url.path.contains("/BrimOps/") { continue }
            
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                // Check if the line contains removeItem(
                if line.contains("removeItem(atPath:") || line.contains("removeItem(at:") {
                    // It could be a comment, but we strictly enforce no removeItem outside BrimOps
                    if !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                        violations.append("\(url.lastPathComponent):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Found removeItem calls outside BrimOps: \n\(violations.joined(separator: "\n"))")
    }
}
