import XCTest
import BrimCore
@testable import BrimScan

/// A command on the path that is really a link into an application bundle.
///
/// The leftovers sweep already reads links the other way: a link whose target
/// has gone is dangling, and a dangling link is residue. Run forwards, the
/// same fact answers something the uninstall path could not. Visual Studio
/// Code installs `/usr/local/bin/code` pointing into its own bundle, and
/// removing the application without the link leaves a `code` command that
/// reports "no such file or directory". Docker does the same with `kubectl`.
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

    /// An application bundle with something runnable inside it.
    @discardableResult
    private func makeBundle(named name: String) throws -> URL {
        let bundle = root.url(for: .applications).appendingPathComponent("\(name).app")
        let binDirectory = bundle.appendingPathComponent("Contents/Resources/app/bin")
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binDirectory.appendingPathComponent("tool"))
        return bundle
    }

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

    /// **`/usr/local/bin/code`.** The link is the application's and goes with
    /// it.
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

    /// Following a link is proof, not inference, so it is not floored to
    /// Tier C the way everything else in `/usr/local/bin` is. The flooring
    /// exists because a bare binary is tied to an application by nothing but
    /// a shared name; a link names the bundle outright.
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

    /// A plain binary sitting in the same directory is not a link and is not
    /// claimed. `resolvingSymlinksInPath` on a file returns the file, so
    /// reading the target the lazy way would treat every binary there as a
    /// link to itself.
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

    /// A link pointing outside every bundle is nothing to do with this
    /// application, however it is named.
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

    /// The link is evidence. What it points at is inside the bundle and
    /// leaves with the bundle, so it is never listed twice.
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

    /// An application with no bundle on disk has nothing for a link to point
    /// into, and the source stops before listing anything.
    func testAnApplicationThatIsNotInstalledClaimsNoLinks() async throws {
        try makeLink(named: "code", to: "/Applications/Visual Studio Code.app/Contents/tool")
        let found = try await evidence()
        XCTAssertTrue(found.isEmpty)
    }
}
