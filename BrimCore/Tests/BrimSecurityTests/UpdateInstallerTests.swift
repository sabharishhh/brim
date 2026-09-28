import CryptoKit
import XCTest
import BrimCore
@testable import BrimOps

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

    private func bundle(_ name: String, _ identifier: String, _ version: String) throws -> URL {
        let url = folder.appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": version
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
