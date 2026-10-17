import XCTest
@testable import BrimCore

/// Which application Brim thinks it is. `isSelfRemoval` decides whether
/// "Uninstall Brim" can do anything at all. It once compared against two
/// hardcoded identifiers that matched neither the shipping app nor anything
/// else, so every one of Brim's files was protected and the plan was empty.
final class SelfRemovalIdentityTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("self-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a bundle whose Info.plist declares `bundleID`.
    private func makeBundle(named name: String, bundleID: String) throws -> URL {
        let bundle = directory.appendingPathComponent(name)
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    private func checker(brimAppURL: URL) -> SafetyChecker {
        SafetyChecker(root: FileSystemRoot(rootURL: directory), brimAppURL: brimAppURL)
    }

    func testBrimRecognisesTheIdentifierItActuallyShipsUnder() throws {
        let bundle = try makeBundle(named: "Brim.app", bundleID: "com.sabharishhh.brim")
        let checker = checker(brimAppURL: bundle)

        XCTAssertEqual(checker.brimBundleID, "com.sabharishhh.brim")
        XCTAssertTrue(
            checker.isBrimItself("com.sabharishhh.brim"),
            "Brim did not recognise itself, so it cannot uninstall itself"
        )
    }

    func testTheIdentityComesFromTheBundleRatherThanAList() throws {
        // A renamed product keeps working: the identifier comes from the bundle.
        let bundle = try makeBundle(named: "Brim.app", bundleID: "com.example.renamed")
        XCTAssertTrue(checker(brimAppURL: bundle).isBrimItself("com.example.renamed"))
    }

    func testSomethingElseIsNotBrim() throws {
        let bundle = try makeBundle(named: "Brim.app", bundleID: "com.sabharishhh.brim")
        let checker = checker(brimAppURL: bundle)

        XCTAssertFalse(checker.isBrimItself("com.apple.Safari"))
        XCTAssertFalse(checker.isBrimItself(nil))
        XCTAssertFalse(checker.isBrimItself(""))
    }

    func testAnUpgradeCanStillRemoveWhatAnOlderBrimLeft() throws {
        // Those two identifiers really shipped, so their leftovers may be cleared.
        let bundle = try makeBundle(named: "Brim.app", bundleID: "com.sabharishhh.brim")
        let checker = checker(brimAppURL: bundle)

        XCTAssertTrue(checker.isBrimItself("devplaceholder.PJ52YXEB.brim"))
        XCTAssertTrue(checker.isBrimItself("com.google.Brim"))
    }

    func testAnUnreadableBundleDoesNotMakeEverythingBrim() throws {
        // With no bundle there is no identifier to compare. Failing open would let
        // anything claim to be Brim.
        let checker = checker(brimAppURL: directory.appendingPathComponent("Absent.app"))

        XCTAssertNil(checker.brimBundleID)
        XCTAssertFalse(checker.isBrimItself("com.sabharishhh.brim"))
        XCTAssertFalse(checker.isBrimItself("anything.at.all"))
    }

    func testBrimsOwnFilesAreProtectedFromEveryoneElse() throws {
        let bundle = try makeBundle(named: "Brim.app", bundleID: "com.sabharishhh.brim")
        let checker = checker(brimAppURL: bundle)
        let inside = bundle.appendingPathComponent("Contents/Info.plist")

        XCTAssertFalse(
            checker.isSafeToRemove(url: inside, isSelfRemoval: false),
            "Another application's uninstall reached into Brim"
        )
        XCTAssertTrue(
            checker.isSafeToRemove(url: inside, isSelfRemoval: true),
            "Brim could not remove its own file while uninstalling itself"
        )
    }
}
