import BrimCore
@testable import BrimOps
import CryptoKit
import XCTest

/// What stands between a download and the installed application.
///
/// A catalogue or a feed only says where to download from. What is
/// accepted is decided here, against the installed copy, the same way
/// Sparkle's installer decides it: the download matches what was published,
/// and the application inside is the same application from the same
/// developer.
final class UpdateInstallerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testADownloadMustMatchWhatItsSourcePublished() throws {
        let file = folder.appendingPathComponent("download")
        let bytes = Data("the new version".utf8)
        try bytes.write(to: file)

        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(try UpdateInstaller.matches(file, .sha256(sha256)))
        XCTAssertFalse(try UpdateInstaller.matches(file, .sha256(String(repeating: "0", count: 64))))

        let sha512 = Data(SHA512.hash(data: bytes)).base64EncodedString()
        XCTAssertTrue(try UpdateInstaller.matches(file, .sha512(sha512)))

        // Sparkle's EdDSA, against the application's own public key.
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: bytes).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(try UpdateInstaller.matches(file, .edDSA(signature: signature, publicKey: publicKey)))
        let stranger = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(try UpdateInstaller.matches(file, .edDSA(signature: signature, publicKey: stranger)))
    }

    /// Visual Studio Code's download is called `stable`, so the kind of
    /// archive is read from its first bytes.
    func testArchivesAreRecognisedByContentNotName() throws {
        let zip = folder.appendingPathComponent("stable")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: zip)
        XCTAssertEqual(UpdateInstaller.kind(of: zip), .zip)
        let package = folder.appendingPathComponent("thing")
        try Data("xar!rest".utf8).write(to: package)
        XCTAssertEqual(UpdateInstaller.kind(of: package), .package)
    }

    /// Nothing replaces an application whose signature there is nothing
    /// to compare with, and nothing replaces one application with another.
    func testTheNewVersionIsCheckedAgainstTheInstalledOne() throws {
        let installed = try bundle("Installed", "com.example.app", "1.0")
        let newer = try bundle("Newer", "com.example.app", "2.0")
        let other = try bundle("Other", "com.example.other", "2.0")

        XCTAssertThrowsError(try UpdateInstaller.verify(other, replacing: installed)) { error in
            XCTAssertEqual(error as? UpdateInstaller.Failure, .differentApplication)
        }
        XCTAssertThrowsError(try UpdateInstaller.verify(newer, replacing: installed)) { error in
            XCTAssertEqual(error as? UpdateInstaller.Failure, .installedIsUnsigned)
        }
        XCTAssertTrue(UpdateInstaller.isNewer(newer, than: installed))
        XCTAssertFalse(UpdateInstaller.isNewer(installed, than: newer))
    }

    // MARK: - Cut off part way

    /// An update can stop at any point: Brim quits, the Mac sleeps, the
    /// power goes. The app must be there afterwards, old or new, and the
    /// next check settles whatever was left.
    func testAnUpdateCutOffPartWayIsSettledNextTime() throws {
        let workspace = folder.appendingPathComponent("workspace")
        let apps = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let otherRun: Int32 = getpid() + 1

        func intent(_ name: String, version: String) throws -> (URL, URL) {
            let installed = apps.appendingPathComponent("\(name).app")
            let staged = apps.appendingPathComponent(".\(UUID().uuidString)-\(name).app")
            _ = try UpdateInstaller.Intent(installed: installed.path, staged: staged.path, version: version,
                                           pid: otherRun).write(in: workspace)
            return (installed, staged)
        }
        func put(_ url: URL, version: String) throws {
            let made = try bundle(UUID().uuidString, "com.example.app", version)
            try FileManager.default.moveItem(at: made, to: url)
        }

        // The old version went to the Trash; the new one never moved in.
        let (missing, waiting) = try intent("Missing", version: "2.0")
        try put(waiting, version: "2.0")
        // The exchange happened; the old version was never cleared away.
        let (swapped, old) = try intent("Swapped", version: "2.0")
        try put(swapped, version: "2.0")
        try put(old, version: "1.0")
        // Staged, never exchanged.
        let (untouched, unused) = try intent("Untouched", version: "2.0")
        try put(untouched, version: "1.0")
        try put(unused, version: "2.0")
        // Another run's download, and one in use now.
        let stale = workspace.appendingPathComponent("\(otherRun)-download")
        let live = workspace.appendingPathComponent("\(getpid())-download")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)

        let interrupted = UpdateInstaller.recoverInterrupted(in: workspace)

        XCTAssertEqual(UpdateInstaller.shortVersion(of: missing), "2.0", "the checked new version is put in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: waiting.path))
        XCTAssertEqual(UpdateInstaller.shortVersion(of: swapped), "2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the old version is cleared away")
        XCTAssertEqual(UpdateInstaller.shortVersion(of: untouched), "1.0", "the installed app is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        XCTAssertEqual(Set(interrupted.keys), [untouched.path], "only the one that did not finish is reported")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a download in use now is kept")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path)
            .contains { $0.hasPrefix("intent-") })
    }

    private func bundle(_ name: String, _ identifier: String, _ version: String) throws -> URL {
        let url = folder.appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": version
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    /// A refusal from macOS is App Management's, and the row offers that
    /// setting. Anything else stays a plain failure with its own sentence,
    /// so a full disk is never sent to Privacy & Security.
    func testOnlyAPermissionRefusalAsksForAppManagement() {
        let folder = URL(fileURLWithPath: "/Applications")
        XCTAssertEqual(UpdateInstaller.refusal(POSIXError(.EPERM), folder: folder), .notAllowed(folder: "Applications"))
        XCTAssertEqual(UpdateInstaller.refusal(CocoaError(.fileWriteNoPermission), folder: folder),
                       .notAllowed(folder: "Applications"))
        guard case .replace = UpdateInstaller.refusal(POSIXError(.ENOSPC), folder: folder) else {
            return XCTFail("a full disk is not a permission")
        }
    }
}
