import XCTest
@testable import BrimCore
import Foundation

final class SafetyCheckerTests: XCTestCase {
    
    func testSafetyCheckerRejectsForbiddenPaths() {
        let fakeRootURL = URL(fileURLWithPath: "/private/var/folders/xyz/temp")
        let root = FileSystemRoot(rootURL: fakeRootURL)
        
        let brimAppURL = fakeRootURL.appendingPathComponent("Applications/Brim.app")
        let checker = SafetyChecker(root: root, brimAppURL: brimAppURL)
        
        // Allowed path
        let allowed = fakeRootURL.appendingPathComponent("Users/test/Library/Preferences/com.example.app.plist")
        XCTAssertTrue(checker.isSafeToRemove(url: allowed))
        
        // Path outside the root (e.g. attempting to escape the fixture)
        let outside = URL(fileURLWithPath: "/Users/test/Library/Preferences/com.example.app.plist")
        XCTAssertFalse(checker.isSafeToRemove(url: outside), "Paths outside root should be rejected")
        
        // /System path
        let systemPath = fakeRootURL.appendingPathComponent("System/Library/CoreServices")
        XCTAssertFalse(checker.isSafeToRemove(url: systemPath), "/System paths must be rejected")
        
        // Mobile Documents (iCloud)
        let icloudPath = fakeRootURL.appendingPathComponent("Users/test/Library/Mobile Documents/com~apple~CloudDocs/File.txt")
        XCTAssertFalse(checker.isSafeToRemove(url: icloudPath), "Mobile Documents paths must be rejected")
        
        // The Brim App itself
        XCTAssertFalse(checker.isSafeToRemove(url: brimAppURL), "Brim app itself must be rejected")
        
        // A child of the Brim App
        let insideBrimApp = brimAppURL.appendingPathComponent("Contents/MacOS/Brim")
        XCTAssertFalse(checker.isSafeToRemove(url: insideBrimApp), "Contents of Brim app must be rejected")
        
        // A parent of the Brim App
        let applicationsFolder = fakeRootURL.appendingPathComponent("Applications")
        XCTAssertFalse(checker.isSafeToRemove(url: applicationsFolder), "Parents of Brim app must be rejected")
    }
}
