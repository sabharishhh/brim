import BrimCore
@testable import BrimScan
import XCTest

/// A launchd job whose program runs from inside the application's bundle is
/// the application's, whatever its label says. That is the fallback the
/// label boundary relies on, so it has to look in the right bundles.
///
/// The check looked only in `/Applications/<file name>.app`, while
/// `AppBundleSource` has always claimed `~/Applications/<file name>.app` as
/// the application itself at Tier A as well. A per-user install is a real
/// install, so a helper running from inside it is exactly as proven. The
/// bundle is now located in one place, `SymlinkIntoBundleSource.bundleLocations`,
/// which uses the file name only: `CFBundleName` says nothing about where a
/// bundle sits, and looking under it would make an unrelated `Code.app` part
/// of Visual Studio Code.
///
/// The check also compared with `hasPrefix` and no boundary, the same
/// mistake the label had, so `/Applications/App.app` would have claimed a
/// program in `/Applications/App.apple.app`. A path inside a bundle is the
/// bundle followed by a slash.
final class LaunchdProgramPathTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launchd-program-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: rootURL)
    }

    private var userApplications: URL {
        root.url(for: .userLibrary).deletingLastPathComponent().appendingPathComponent("Applications")
    }

    /// A job whose label proves nothing, so only the program can.
    @discardableResult
    private func makeJob(label: String = "com.unrelated.label", program: String) throws -> URL {
        let directory = root.url(for: .userLaunchAgents)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(label).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": program], format: .xml, options: 0
        )
        try data.write(to: url)
        return url
    }

    private func claimed(by identity: Identity) async throws -> [Evidence] {
        try await LaunchdSource().evidence(for: identity, in: root)
    }

    private var app: Identity {
        Identity(bundleID: "com.example.app", name: "App")
    }

    /// **A per-user install is a real install.** The bundle sits in the
    /// Applications folder inside the home folder, which `AppBundleSource`
    /// already calls this application at Tier A, and its helper runs from
    /// inside it.
    func testAPerUserInstallsHelperIsProvenByWhereItRunsFrom() async throws {
        let bundle = userApplications.appendingPathComponent("App.app")
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.app"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let program = userApplications
            .appendingPathComponent("App.app/Contents/Library/LaunchServices/helper").path
        try makeJob(program: program)

        let found = try await claimed(by: app)
        XCTAssertEqual(
            found.first?.tier, .A,
            "A helper running from inside the per-user install of this application was not "
                + "proven, because only /Applications was looked in."
        )
    }

    /// **The same missing boundary the label had.** `App.apple.app` is a
    /// different bundle that happens to start with the same letters.
    func testAProgramInABundleThatMerelyStartsWithTheSameNameIsNotProof() async throws {
        let program = root.url(for: .applications)
            .appendingPathComponent("App.apple.app/Contents/MacOS/helper").path
        try makeJob(program: program)

        let found = try await claimed(by: app)
        XCTAssertTrue(
            found.isEmpty,
            "A program inside App.apple.app was taken as proof that the job belongs to App."
        )
    }

    /// **`Code.app` is not Visual Studio Code**, here as in the link check.
    /// Locating the bundle in one shared place must not bring the
    /// `CFBundleName` with it.
    func testAProgramInsideAnApplicationNamedLikeTheBundleNameIsNotProof() async throws {
        let program = root.url(for: .applications)
            .appendingPathComponent("Code.app/Contents/MacOS/helper").path
        try makeJob(program: program)

        let vsCode = Identity(
            bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundleName: "Code"
        )
        let found = try await claimed(by: vsCode)
        XCTAssertTrue(
            found.isEmpty,
            "A job running from Code.app, a different application, was claimed for Visual "
                + "Studio Code because its CFBundleName is \"Code\"."
        )
    }
}
