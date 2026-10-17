import BrimCore
@testable import BrimScan
import XCTest

/// A command on the path that is a link into an application bundle, such as
/// `/usr/local/bin/code`. Removing the app without it leaves a command that
/// reports "no such file or directory".
final class SymlinkIntoBundleTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symlink-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: rootURL)
    }

    /// Where a per-user install puts its bundle.
    private var userApplications: URL {
        root.url(for: .userLibrary).deletingLastPathComponent().appendingPathComponent("Applications")
    }

    /// An application bundle with something runnable inside it.
    @discardableResult
    private func makeBundle(named name: String, inUserApplications: Bool = false) throws -> URL {
        let folder = inUserApplications ? userApplications : root.url(for: .applications)
        let bundle = folder.appendingPathComponent("\(name).app")
        let binDirectory = bundle.appendingPathComponent("Contents/Resources/app/bin")
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binDirectory.appendingPathComponent("tool"))
        let identifier = name == "Visual Studio Code"
            ? "com.microsoft.VSCode" : "com.example.\(name)"
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    @discardableResult
    private func makeLink(named name: String, to destination: String) throws -> URL {
        let directory = root.url(for: .usrLocalBin)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(name)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return link
    }

    private var identity: Identity {
        Identity(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundleName: "Code")
    }

    private func evidence() async throws -> [Evidence] {
        try await SymlinkIntoBundleSource().evidence(for: identity, in: root)
    }

    /// The link is the application's and goes with it.
    func testALinkIntoTheBundleIsFound() async throws {
        let bundle = try makeBundle(named: "Visual Studio Code")
        let link = try makeLink(
            named: "code",
            to: bundle.appendingPathComponent("Contents/Resources/app/bin/tool").path
        )

        let found = try await evidence()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.url.path, link.path)
    }

    /// A link names the bundle outright, so it is not floored to Tier C the way
    /// a bare binary sharing a name is.
    func testFollowingALinkIsStrongerThanSharingAName() async throws {
        let bundle = try makeBundle(named: "Visual Studio Code")
        try makeLink(
            named: "code",
            to: bundle.appendingPathComponent("Contents/Resources/app/bin/tool").path
        )

        let found = try await evidence()
        XCTAssertEqual(
            found.first?.tier, .B,
            "A link that names the bundle is stronger evidence than a shared word."
        )
    }

    /// A link into somebody else's application is somebody else's.
    func testALinkIntoAnotherApplicationIsLeftAlone() async throws {
        try makeBundle(named: "Visual Studio Code")
        let other = try makeBundle(named: "Docker")
        try makeLink(
            named: "kubectl",
            to: other.appendingPathComponent("Contents/Resources/app/bin/tool").path
        )

        let found = try await evidence()
        XCTAssertTrue(found.isEmpty, "Docker's link was claimed for Visual Studio Code.")
    }

    /// `resolvingSymlinksInPath` on a file returns the file, so a lazy reading
    /// would treat every binary as a link to itself.
    func testAPlainBinaryIsNotMistakenForALink() async throws {
        try makeBundle(named: "Visual Studio Code")
        let directory = root.url(for: .usrLocalBin)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: directory.appendingPathComponent("code"))

        let found = try await evidence()
        XCTAssertTrue(found.isEmpty, "A plain file was read as a link into the bundle.")
    }

    /// A relative link lands in the same place an absolute one does.
    func testARelativeLinkIsResolvedBeforeItIsJudged() async throws {
        try makeBundle(named: "Visual Studio Code")
        let link = try makeLink(
            named: "code",
            to: "../../../Applications/Visual Studio Code.app/Contents/Resources/app/bin/tool"
        )

        let found = try await evidence()
        XCTAssertEqual(found.first?.url.path, link.path, "A relative link was not followed.")
    }

    /// A link pointing outside every bundle is not this application's.
    func testALinkPointingSomewhereElseEntirelyIsIgnored() async throws {
        try makeBundle(named: "Visual Studio Code")
        let elsewhere = rootURL.appendingPathComponent("opt/tool")
        try fm.createDirectory(
            at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: elsewhere)
        try makeLink(named: "code", to: elsewhere.path)

        let found = try await evidence()
        XCTAssertTrue(found.isEmpty)
    }

    /// What the link points at leaves with the bundle, so it is not listed twice.
    func testWhatTheLinkPointsAtIsNotListedSeparately() async throws {
        let bundle = try makeBundle(named: "Visual Studio Code")
        let target = bundle.appendingPathComponent("Contents/Resources/app/bin/tool")
        try makeLink(named: "code", to: target.path)

        let found = try await evidence()
        XCTAssertFalse(
            found.contains { $0.url.path == target.path },
            "The file inside the bundle was listed as though it were separate residue."
        )
    }

    /// An application with no bundle on disk has nothing to link into.
    func testAnApplicationThatIsNotInstalledClaimsNoLinks() async throws {
        try makeLink(named: "code", to: "/Applications/Visual Studio Code.app/Contents/tool")
        let found = try await evidence()
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Where the bundle lives

    /// The bundle is looked for under its file name. `CFBundleName` names
    /// support folders, not where the bundle sits, so an unrelated `Code.app`
    /// must not lend its links to Visual Studio Code.
    func testALinkIntoAnotherApplicationNamedLikeTheBundleNameIsLeftAlone() async throws {
        try makeBundle(named: "Visual Studio Code")
        let other = try makeBundle(named: "Code")
        try makeLink(
            named: "othertool",
            to: other.appendingPathComponent("Contents/Resources/app/bin/tool").path
        )

        let found = try await evidence()
        XCTAssertTrue(
            found.isEmpty,
            "A link into Code.app, a different application, was claimed for Visual Studio Code "
                + "because its CFBundleName is \"Code\"."
        )
    }

    /// A link into a per-user install is just as much the application's.
    func testALinkIntoAPerUserInstallIsFound() async throws {
        let bundle = try makeBundle(named: "Visual Studio Code", inUserApplications: true)
        let link = try makeLink(
            named: "code",
            to: bundle.appendingPathComponent("Contents/Resources/app/bin/tool").path
        )

        let found = try await evidence()
        XCTAssertEqual(found.map(\.url.path), [link.path])
    }

    /// The same candidates `AppBundleSource` claims at Tier A, so a link and the
    /// bundle mean the same application.
    func testTheBundleIsLookedForUnderItsFileNameInBothApplicationsFolders() async throws {
        let locations = SymlinkIntoBundleSource.bundleLocations(for: identity, in: root)
            .map(\.standardizedFileURL.path)
        XCTAssertEqual(
            Set(locations),
            [
                root.url(for: .applications)
                    .appendingPathComponent("Visual Studio Code.app").standardizedFileURL.path,
                userApplications
                    .appendingPathComponent("Visual Studio Code.app").standardizedFileURL.path
            ],
            "The bundle is being looked for somewhere other than its file name in the two "
                + "Applications folders."
        )

        let direct = try makeBundle(named: "Visual Studio Code")
        let claimedAsTheBundle = try await AppBundleSource().evidence(for: identity, in: root)
            .map(\.url.standardizedFileURL.path)
        XCTAssertEqual(claimedAsTheBundle, [direct.standardizedFileURL.path])
        XCTAssertTrue(
            Set(claimedAsTheBundle).isSubset(of: Set(locations)),
            "AppBundleSource calls a bundle this application that the link check would not."
        )
    }
}
