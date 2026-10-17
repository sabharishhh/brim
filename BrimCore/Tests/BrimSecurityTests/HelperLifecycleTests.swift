import XCTest
@testable import BrimPrivileged

/// The administrator process on the way in and on the way out.
final class HelperLifecycleTests: XCTestCase {

    /// Brim never asks Service Management about itself. Reading
    /// `SMAppService.status` makes macOS evaluate the bundled plist and ask
    /// Background Task Management about it, which posts a "(null) can run in
    /// the background" notification for an item it has no record of.
    @MainActor
    func testConstructingTheClientAsksMacOSNothing() {
        let client = PrivilegedHelperClient()
        XCTAssertEqual(
            client.state, .notAsked,
            "Constructing the client read SMAppService.status, which makes macOS evaluate "
            + "Brim's bundled daemon and surface it as a nameless background item"
        )
    }

    /// Brim declares nothing that can run in the background. A launchd plist in
    /// the bundle is a declaration whatever the code does, and calling
    /// `SMAppService.unregister` kept Brim listed under Background App Activity.
    func testBrimDeclaresAndRegistersNothingInTheBackground() throws {
        let root = Self.repositoryRoot()
        let project = try String(
            contentsOf: root.appendingPathComponent("Brim.xcodeproj/project.pbxproj"), encoding: .utf8
        )
        for folder in ["LaunchDaemons", "LaunchAgents", "LoginItems"] {
            XCTAssertFalse(project.contains("Contents/Library/\(folder)"),
                           "The app bundle embeds something in Contents/Library/\(folder)")
        }
        XCTAssertFalse(project.contains("jobhelper.plist in "),
                       "The helper's launchd plist is a build input again")

        let calls = ["import ServiceManagement", "SMAppService.", "SMLoginItemSetEnabled"]
        for directory in ["Brim", "BrimCore/Sources"] {
            let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil
            )
            while let file = walker?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for line in lines where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for call in calls where line.contains(call) {
                        XCTFail("\(file.lastPathComponent) uses \(call)")
                    }
                }
            }
        }
    }

    func testTheInterfaceCanAskTheDaemonToCleanUpAfterItself() {
        // `uninstallSelf` must be on the protocol for the app to call it.
        XCTAssertTrue(
            (Helper() as AnyObject).responds(to: #selector(BrimJobHelperProtocol.uninstallSelf(withReply:))),
            "The daemon cannot be asked to clear its quarantine"
        )
    }

    func testTheVersionMovedWhenTheInterfaceDid() {
        // The version moves with the interface, or an app would call a selector an
        // older administrator process does not implement.
        XCTAssertNotEqual(BrimJobHelper.version, "1",
                          "The interface gained uninstallSelf; the version did not move")
    }

    func testOnlyTheQuarantineIsNamedAsSomethingToDelete() throws {
        // The one deletion on the way out takes its path from a constant, never a
        // parameter, or the interface could be talked into deleting something
        // else.
        let source = Self.repositoryRoot()
            .appendingPathComponent("BrimCore/Sources/BrimPrivileged/JobHelperDaemon.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        guard let start = text.range(of: "func uninstallSelf") else {
            return XCTFail("uninstallSelf is not implemented")
        }
        // Up to the next method, not a fixed slice that could read the next
        // function's parameters.
        let rest = text[start.upperBound...]
        let body = rest.range(of: "\n    func ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        let firstRemoval = body.range(of: "removeItem")
        XCTAssertNotNil(firstRemoval, "uninstallSelf removes nothing")
        XCTAssertTrue(
            body.contains("BrimJobHelper.quarantineDirectory"),
            "The path being removed has to be the constant, not something passed in"
        )
        XCTAssertFalse(
            body.contains("domain:") || body.contains("name:"),
            "uninstallSelf takes no target and must not reach for one"
        )
    }

    func testTheQuarantineSitsInsideBrimsOwnFolder() {
        // The parent is removed too when empty, so it must be Brim's own folder.
        XCTAssertTrue(
            BrimJobHelper.quarantineDirectory.hasPrefix("/Library/Application Support/Brim/"),
            "Removing the parent of \(BrimJobHelper.quarantineDirectory) would take somebody else's data"
        )
    }

    func testEveryRequirementTheDaemonUsesCompiles() {
        // `setCodeSigningRequirement` raises on a string it cannot parse, and a
        // root process crashing on a connection is worse than refusing it.
        XCTAssertTrue(BrimJobHelper.isWellFormed(BrimJobHelper.clientRequirement()))
        XCTAssertTrue(BrimJobHelper.isWellFormed(BrimJobHelper.daemonRequirement()))
        XCTAssertFalse(BrimJobHelper.isWellFormed("anchor apple generic and and"))
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
