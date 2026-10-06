@testable import BrimCore
import Foundation
import XCTest

/// Removing Brim moved its files to the Trash, where they stayed, and wrote
/// a journal for the removal into the folder being removed. Brim now deletes
/// what it wrote after it quits. These hold what counts as Brim's, and that
/// the script deletes exactly that and itself.
final class BrimTracesTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimTraces-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var root: FileSystemRoot {
        FileSystemRoot(rootURL: rootURL, userName: "testuser")
    }

    @discardableResult
    private func make(_ domain: FileSystemRoot.Domain, _ name: String, folder: Bool = false) throws -> URL {
        let url = root.url(for: domain).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    func testEverythingBrimWroteIsFoundAndNothingElse() throws {
        let id = "com.sabharishhh.brim"
        let ours = try [
            make(.userApplicationSupport, "Brim", folder: true),
            make(.userCaches, id, folder: true),
            make(.userPreferences, "\(id).plist"),
            make(.userPreferencesByHost, "\(id).0A1B2C.plist"),
            make(.userHTTPStorages, "\(id).binarycookies"),
            make(.userSavedApplicationState, "\(id).savedState", folder: true),
            make(.userRecentDocuments, "\(id).sfl4"),
            make(.userDiagnosticReports, "brim-2026-10-05-081500.ips"),
            make(.userPreferences, "com.google.Brim.plist")
        ]
        let theirs = try [
            make(.userCaches, "com.sabharishhh.brimstone", folder: true),
            make(.userApplicationSupport, "Brimstone", folder: true),
            make(.userPreferences, "com.example.app.plist"),
            make(.userDiagnosticReports, "brimstone-2026-10-05-081500.ips")
        ]
        let found = Set(BrimTraces.paths(in: root, identifiers: [id, "com.google.Brim"]).map(\.path))
        XCTAssertEqual(found, Set(ours.map(\.path)))
        XCTAssertTrue(theirs.allSatisfy { !found.contains($0.path) })
    }

    /// The script waits until the pipe Brim holds closes, deletes exactly the
    /// paths, and leaves nothing of itself behind.
    func testTheScriptDeletesWhatItListsAndItself() throws {
        let gone = try [make(.userCaches, "com.sabharishhh.brim", folder: true),
                        make(.userApplicationSupport, "Brim's 'own' folder", folder: true)]
        let kept = try make(.userCaches, "com.example.app", folder: true)
        let script = rootURL.appendingPathComponent("removal.sh")
        try BrimTraces.removalScript(paths: gone, preferenceDomains: [], unregistering: nil)
            .write(to: script, atomically: true, encoding: .utf8)
        let lifeline = Pipe()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [script.path]
        shell.standardInput = lifeline
        try shell.run()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(gone.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                      "Deleted before Brim had gone")
        try lifeline.fileHandleForWriting.close()
        shell.waitUntilExit()

        XCTAssertTrue(gone.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }
}
