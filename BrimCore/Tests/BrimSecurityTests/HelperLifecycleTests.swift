import XCTest
@testable import BrimPrivileged

/// What the root daemon does on the way in and on the way out.
///
/// Two gaps, both of them things the code already claimed in a comment and
/// did not do. `BrimJobHelper.version` said it existed "so the app can tell
/// whether the installed daemon is the one that shipped with it", and
/// nothing ever asked. And uninstalling Brim took the daemon away while
/// leaving its quarantine, a root-owned directory nothing left on the disk
/// could then remove, which is precisely the failure the product exists to
/// point at in other people's software.
final class HelperLifecycleTests: XCTestCase {

    /// Brim must not ask macOS about its own daemon until somebody wants it.
    ///
    /// Reading `SMAppService.status` is not a local lookup. It makes `smd`
    /// open the bundle, build a background-item configuration out of the
    /// daemon plist inside it, and ask Background Task Management for that
    /// item's disposition. On a Mac where the daemon has never been
    /// registered BTM answers "record not found", and being asked about an
    /// item it has no record of is what makes macOS announce a new
    /// background item. With no record there is no stored name, so the
    /// notification reads "(null) can run in the background".
    ///
    /// Brim was doing this three times on every launch, from two separate
    /// clients each polling in `init()` plus one more during the background
    /// scan, before anybody had asked for the helper. Measured in the log:
    /// nine `com.sabharishhh.brim.jobhelper.plist` evaluations per launch
    /// before, none after.
    ///
    /// A utility whose entire subject is unexplained background
    /// registrations cannot be the thing putting one in front of you.
    @MainActor
    func testConstructingTheClientAsksMacOSNothing() {
        let client = PrivilegedHelperClient()
        XCTAssertEqual(
            client.state, .notAsked,
            "Constructing the client read SMAppService.status, which makes macOS evaluate "
            + "Brim's bundled daemon and surface it as a nameless background item"
        )
    }

    func testTheInterfaceCanAskTheDaemonToCleanUpAfterItself() {
        // `uninstallSelf` has to be on the protocol for the app to be able
        // to call it at all. A protocol method is a small thing to assert,
        // and its absence was the whole bug.
        XCTAssertTrue(
            (Helper() as AnyObject).responds(to: #selector(BrimJobHelperProtocol.uninstallSelf(withReply:))),
            "The daemon cannot be asked to clear its quarantine"
        )
    }

    func testTheVersionMovedWhenTheInterfaceDid() {
        // Adding a method changes what the daemon is. An app talking to a
        // daemon that predates the method would hang on a selector it does
        // not implement, so the version has to move with the interface.
        XCTAssertNotEqual(BrimJobHelper.version, "1",
                          "The interface gained uninstallSelf; the version did not move")
    }

    func testOnlyTheQuarantineIsNamedAsSomethingToDelete() throws {
        // The daemon sets things aside rather than deleting them, with one
        // exception: on the way out there is nowhere left to set anything
        // aside to. That exception must take its path from a constant in
        // the binary and never from a parameter, or the interface can be
        // talked into deleting something else.
        let source = Self.repositoryRoot()
            .appendingPathComponent("BrimCore/Sources/BrimPrivileged/JobHelperDaemon.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        guard let start = text.range(of: "func uninstallSelf") else {
            return XCTFail("uninstallSelf is not implemented")
        }
        // Up to the next method, not a fixed slice: a window that runs on
        // reads the next function's parameters and fails on those.
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
        // The parent is taken away too when it is empty, so it had better
        // be Brim's folder rather than something shared.
        XCTAssertTrue(
            BrimJobHelper.quarantineDirectory.hasPrefix("/Library/Application Support/Brim/"),
            "Removing the parent of \(BrimJobHelper.quarantineDirectory) would take somebody else's data"
        )
    }

    func testEveryRequirementTheDaemonUsesCompiles() {
        // setCodeSigningRequirement raises rather than returns on a string
        // it cannot parse, and a root daemon crashing on an incoming
        // connection is worse than one refusing it.
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
