@testable import BrimCore
@testable import BrimScan
import Darwin
import Foundation
import XCTest

/// `Microsoft` in Application Support was only looked at whole: the one
/// Microsoft app installed, Visual Studio Code, has a name that does not
/// begin with the developer's, so the sweep never opened the folder, and
/// Teams' data inside it was never offered.
final class DeveloperFolderTests: XCTestCase {
    func testADevelopersFolderIsOpenedWhenItsAppsNamesDoNotBeginWithIt() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let root = FileSystemRoot(rootURL: raw.resolvingSymlinksInPath(), userName: "testuser")
        let app = root.url(for: .applications).appendingPathComponent("Visual Studio Code.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.microsoft.VSCode", "CFBundleName": "Code"],
            format: .xml, options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let teams = root.url(for: .userApplicationSupport).appendingPathComponent("Microsoft/Teams")
        try FileManager.default.createDirectory(at: teams, withIntermediateDirectories: true)
        try "left behind".write(to: teams.appendingPathComponent("state"), atomically: true, encoding: .utf8)

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers(
            knownPastBundleIDs: ["com.microsoft.teams2"], knownNames: ["com.microsoft.teams2": "Microsoft Teams"]
        )
        let names = leftovers.map(\.url.lastPathComponent)
        XCTAssertFalse(names.contains("Microsoft"), "A developer's folder is never offered whole")
        XCTAssertTrue(names.contains("Teams"), "What a removed product kept inside it is")
    }
}
