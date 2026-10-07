import XCTest
@testable import BrimService
import BrimProtocol
import BrimCore
import BrimOps
@testable import BrimScan

final class SecurityRegressionSuiteTests: XCTestCase {
    
    // (a) an unauthorised client attempting to drive the service and the helper
    func testUnauthorizedClientRejection() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let root = FileSystemRoot(rootURL: tempRoot)
        let brimAppURL = tempRoot.appendingPathComponent("Brim.app")
        let planStoreDir = tempRoot.appendingPathComponent("Plans")
        let journalStoreDir = tempRoot.appendingPathComponent("Journal")
        
        let service = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planStoreDir, journalStoreDirectory: journalStoreDir)
        
        // Create a real plan first
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.test", name: "Test"))
        let plan = try await service.plan(intent: intent)
        let fakeToken = ApprovalToken.forged()
        
        do {
            try await service.apply(planId: plan.planId, token: fakeToken)
            XCTFail("Should have rejected unauthorized client")
        } catch TokenStore.TokenError.notFound {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testSymlinkSwapIntermediateComponent() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Setup: /tempDir/A/B/File.txt
        let pathA = tempDir.appendingPathComponent("A")
        let pathB = pathA.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: pathB, withIntermediateDirectories: true)
        let targetFile = pathB.appendingPathComponent("File.txt")
        try "test".write(to: targetFile, atomically: true, encoding: .utf8)
        
        var statBuf = stat()
        stat(targetFile.path, &statBuf)
        let expectedDev = statBuf.st_dev
        let expectedIno = statBuf.st_ino
        
        // Swap: Replace /tempDir/A with a symlink to /tempDir/Secret
        let secretDir = tempDir.appendingPathComponent("Secret")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secretPathB = secretDir.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: secretPathB, withIntermediateDirectories: true)
        let secretFile = secretPathB.appendingPathComponent("File.txt")
        try "secret".write(to: secretFile, atomically: true, encoding: .utf8)
        
        try FileManager.default.removeItem(at: pathA)
        try FileManager.default.createSymbolicLink(at: pathA, withDestinationURL: secretDir)
        
        // Now try to trash the targetFile (which is actually inside Secret via symlink A)
        XCTAssertThrowsError(try SafeOps.trashItem(targetPath: targetFile.path, expectedDev: expectedDev, expectedIno: expectedIno)) { error in
            guard let safeError = error as? SafeOpsError else {
                XCTFail("Unexpected error type")
                return
            }
            if case .failedToOpenParent(let err) = safeError, err == ELOOP || err == ENOTDIR {
                // Success, caught intermediate symlink!
            } else {
                XCTFail("Unexpected SafeOpsError: \(safeError)")
            }
        }
    }

    func testRestoreItemRejectsIntermediateSymlink() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = tempDir.appendingPathComponent("TrashedFile.txt")
        try "payload".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        // Setup original target: /tempDir/A/B/Restored.txt
        let pathA = tempDir.appendingPathComponent("A")
        let pathB = pathA.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: pathB, withIntermediateDirectories: true)
        let destFile = pathB.appendingPathComponent("Restored.txt")
        
        // Swap: Replace /tempDir/A with a symlink to /tempDir/Secret
        let secretDir = tempDir.appendingPathComponent("Secret")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secretPathB = secretDir.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: secretPathB, withIntermediateDirectories: true)
        
        try FileManager.default.removeItem(at: pathA)
        try FileManager.default.createSymbolicLink(at: pathA, withDestinationURL: secretDir)
        
        // Attempt to restore through intermediate symlink
        XCTAssertThrowsError(try SafeOps.restoreItem(from: sourceFile.path, to: destFile.path)) { error in
            guard let safeError = error as? SafeOpsError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            if case .failedToOpenParent(let err) = safeError, err == ELOOP || err == ENOTDIR {
                // Success, caught intermediate symlink in restoreItem!
            } else {
                XCTFail("Unexpected SafeOpsError: \(safeError)")
            }
        }
    }

    // (c) a symlink swapped between plan and execution
    func testSymlinkSwapBetweenPlanAndExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let targetDir = tempDir.appendingPathComponent("TargetDir")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetFile = targetDir.appendingPathComponent("File.txt")
        try "test".write(to: targetFile, atomically: true, encoding: .utf8)
        
        // Fingerprint
        var statBuf = stat()
        stat(targetFile.path, &statBuf)
        let expectedDev = statBuf.st_dev
        let expectedIno = statBuf.st_ino
        
        // Symlink swap!
        try FileManager.default.removeItem(at: targetDir)
        let secretDir = tempDir.appendingPathComponent("Secret")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secretFile = secretDir.appendingPathComponent("File.txt")
        try "secret".write(to: secretFile, atomically: true, encoding: .utf8)
        
        try FileManager.default.createSymbolicLink(at: targetDir, withDestinationURL: secretDir)
        
        XCTAssertThrowsError(try SafeOps.trashItem(targetPath: targetFile.path, expectedDev: expectedDev, expectedIno: expectedIno)) { error in
            guard let safeError = error as? SafeOpsError else {
                XCTFail("Unexpected error type")
                return
            }
            if case .failedToOpenParent(_) = safeError {
                // Caught the symlink!
            } else {
                XCTFail("Unexpected SafeOpsError: \(safeError)")
            }
        }
    }
    
    // Plus a malformed-message fuzz pass over the service's inputs.
    func testMalformedMessageFuzzPass() async throws {
        // Send absolute garbage plan intent data
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = FileSystemRoot(rootURL: tempRoot)
        let brimAppURL = tempRoot.appendingPathComponent("Brim.app")
        
        let service = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: tempRoot.appendingPathComponent("Plans"), journalStoreDirectory: tempRoot.appendingPathComponent("Journal"))
        
        // Fuzz verify
        do {
            _ = try await service.verify(planId: UUID())
            XCTFail("Should fail for non-existent plan")
        } catch { }
        
        // Fuzz apply with nonsense ID and token
        do {
            try await service.apply(planId: UUID(), token: ApprovalToken.forged())
            XCTFail("Should fail for invalid plan/token")
        } catch { }
        
        // Fuzz undo with nonsense ID
        do {
            try await service.undo(planId: UUID())
            XCTFail("Should fail for non-existent plan")
        } catch { }
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
            if url.path.contains("/BrimOps/") { continue }
            
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                if line.contains("removeItem(atPath:") || line.contains("removeItem(at:") {
                    if !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                        violations.append("\(url.lastPathComponent):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Found removeItem calls outside BrimOps: \n\(violations.joined(separator: "\n"))")
    }
}

/// What the Trash actually shows after Brim puts something there.
///
/// `trashItem` renames the target into an isolated directory before trashing
/// it, which is what makes the operation TOCTOU-safe. Done naively that
/// rename is what reaches the Trash, so the user opens the bin and finds a
/// list of UUIDs. "Recoverable" then means nothing in practice.
final class TrashNamingTests: XCTestCase {

    func testATrashedItemKeepsItsOwnName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimTrashNaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("BrimTestApp-DELETE-ME.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let dev = attrs[.systemNumber] as! Int32
        let ino = attrs[.systemFileNumber] as! UInt64

        guard let trashed = try SafeOps.trashItem(targetPath: target.path, expectedDev: dev, expectedIno: ino) else {
            throw XCTSkip("Trashing is unavailable in this environment")
        }
        defer { try? FileManager.default.removeItem(at: trashed) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(
            trashed.lastPathComponent.hasPrefix("BrimTestApp-DELETE-ME"),
            "Trash shows \"\(trashed.lastPathComponent)\", a name nobody can recognise or restore"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trashed.appendingPathComponent("marker").path),
            "The contents must survive the round trip"
        )
    }

    /// Deleting a removal's items from the Trash must reach only the Trash:
    /// a recorded URL that points anywhere else is refused and left alone.
    func testDeletingFromTheTrashReachesOnlyTheTrash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimTrashDelete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Removed.app")
        let kept = dir.appendingPathComponent("Kept.txt")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: kept, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let dev = try XCTUnwrap(attrs[.systemNumber] as? Int32)
        let ino = try XCTUnwrap(attrs[.systemFileNumber] as? UInt64)
        let trashed = try XCTUnwrap(SafeOps.trashItem(targetPath: target.path, expectedDev: dev, expectedIno: ino))

        try SafeOps.deleteFromTrash(trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNoThrow(try SafeOps.deleteFromTrash(trashed), "Already gone is not an error")

        XCTAssertThrowsError(try SafeOps.deleteFromTrash(kept))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testANameThatWouldEscapeTheIsolationDirectoryIsRejected() {
        // The rename back to the original name happens inside a directory we
        // control, so a basename that is not a plain name must not be used.
        XCTAssertFalse(SafeOps.isUsableTrashName(""))
        XCTAssertFalse(SafeOps.isUsableTrashName("."))
        XCTAssertFalse(SafeOps.isUsableTrashName(".."))
        XCTAssertFalse(SafeOps.isUsableTrashName("../../etc/passwd"))
        XCTAssertTrue(SafeOps.isUsableTrashName("Photoshop.app"))
    }
}
